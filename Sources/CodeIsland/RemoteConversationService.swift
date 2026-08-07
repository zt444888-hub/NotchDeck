import Foundation
import CloudKit
import os
import CodeIslandCore

private let log = Logger(subsystem: "com.notchdeck.mac", category: "RemoteConversation")

/// CloudKit-backed remote AI conversation service (v1.2.0).
///
/// The Mac side executes agent turns and writes results back; the iPhone
/// companion creates conversations and sends user messages. Everything lives
/// in the user's CloudKit PRIVATE database — only their own devices can read
/// it, the developer never sees the data.
///
/// Synchronization model:
///   - CKDatabaseSubscription pushes a silent notification when any record
///     changes → we sync zone changes and execute pending conversations.
///   - A 5s poll timer is the fallback (push can be delayed/dropped by APNs).
///   - Data sync uses CKFetchRecordZoneChangesOperation (Apple's recommended
///     incremental sync API) — requires ZERO query indexes, completely
///     avoiding the "recordName is not marked queryable" error.
@MainActor
final class RemoteConversationService: ObservableObject {

    static let shared = RemoteConversationService()

    /// Nonisolated so it can be used as a default argument (default-arg
    /// evaluation happens in a nonisolated context under Swift 6 checks).
    nonisolated static let containerIdentifier = "iCloud.com.notchdeck"

    @Published private(set) var conversations: [RemoteConversation] = []
    @Published private(set) var runningCount = 0
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine

    // MARK: - Remote commands (P1: drive the Mac over CloudKit)

    /// Commands written by the phone, claimed/executed by this Mac. Merged
    /// from the same zone-changes stream as conversations.
    @Published private(set) var commands: [RemoteCommand] = []
    /// App-layer bridge that actually executes a claimed command (focus,
    /// approve, answer...). Assigned in AppDelegate, reusing the exact same
    /// handlers as the MPC path (AppleCompanionPublisher).
    var onRemoteCommandExecution: ((RemoteCommand) -> Void)?

    /// Opt-in gate for executing remote commands. Default OFF — executing
    /// commands sent from the phone over the internet is an explicit,
    /// deliberate security choice (separate from the Remote AI conversation
    /// switch).
    static var remoteCommandsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.remoteCommandsEnabled)
    }

    private let container: CKContainer
    private let db: CKDatabase
    private let sessionManager = RemoteAgentSessionManager()
    private var pollTimer: Timer?
    private(set) var isRunning = false

    // MARK: - Remote status beacon (P0: remote visibility without MPC)

    /// Last published beacon snapshot (content comparison, timestamp ignored).
    private var lastStatusSnapshot: RemoteStatus?
    /// Wall-clock of the last CloudKit write, for throttling.
    private var lastStatusWriteAt: Date = .distantPast
    /// Minimum interval between CloudKit writes (request budget: a private
    /// database allows ~40k requests/day; 5s polls would burn half of it).
    static let statusMinInterval: TimeInterval = 5
    /// Keep-alive heartbeat when nothing changed, so the iPhone can still
    /// tell "online, idle" from "Mac asleep / app quit".
    static let statusHeartbeat: TimeInterval = 30

    /// Custom zone required by CKFetchRecordZoneChangesOperation —
    /// the DEFAULT zone does NOT support zone-change sync semantics
    /// (Apple: "Syncing the default zone is not supported"), so it would
    /// silently return 0 records forever. All reads/writes use this zone.
    static let recordZoneID = CKRecordZone.ID(zoneName: "RemoteConversations")

    /// Poll interval: pushed silent notifications aren't available to
    /// Developer ID–distributed Mac apps, so keep the fallback snappy.
    static let pollInterval: TimeInterval = 5

    init(containerIdentifier: String = RemoteConversationService.containerIdentifier) {
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        self.db = container.privateCloudDatabase
    }

    // MARK: - Diagnostic (debug aid; logs are not readable from the
    // WorkBuddy sandbox, so CloudKit failures are also written to a file)

    private static let diagPath = "/tmp/notchdeck-remote-diag.log"

    static func diag(_ msg: String) {
        // Diagnostics are opt-in (Settings → Remote AI → 诊断日志) to avoid
        // file I/O on every 5s poll in production.
        guard UserDefaults.standard.bool(forKey: SettingsKey.remoteDiagEnabled) else { return }
        let line = "\(Date()) \(msg)\n"
        if let handle = FileHandle(forWritingAtPath: diagPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(toFile: diagPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // The old single-global codex session key is superseded by the
        // per-conversation binding map; drop it so no phone conversation
        // accidentally resumes a shared session.
        RemoteAgentSessionManager.migrateLegacyCodexSession()
        Self.diag("start() called, remoteConversationEnabled=1, container=\(Self.containerIdentifier)")
        sessionManager.onTurnFinished = { [weak self] conversation in
            Task { @MainActor in
                Self.diag("turn finished: id=\(conversation.id), status=\(conversation.status.rawValue), msgs=\(conversation.messages.count), err=\(conversation.errorMessage ?? "nil")")
                self?.updateStatus(conversation)
            }
        }
        Task { @MainActor in await ensureZone() }
        // Mirror the Mac's local codex sessions into CloudKit so the phone
        // can see and drive the existing agent tasks.
        Task { await CodexSessionImporter.syncImportedSessions(db: db) }
        registerSubscription()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
        Task { await refreshAccountStatus() }
    }

    /// Create the custom zone if it doesn't exist yet. CloudKit does NOT
    /// auto-create custom zones; saving to a missing zone fails. This is
    /// idempotent — saving an existing zone throws but is harmless.
    func ensureZone() async {
        do {
            _ = try await db.save(CKRecordZone(zoneID: Self.recordZoneID))
            Self.diag("ensureZone: saved/verified zone RemoteConversations")
        } catch {
            Self.diag("ensureZone: \(error.localizedDescription) (expected if zone exists)")
        }
    }

    /// Check whether the signed-in iCloud account can use this container.
    /// `.available` means the whole chain can work.
    func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
            Self.diag("accountStatus = \(accountStatus.rawValue) (\(accountStatus))")
        } catch {
            accountStatus = .couldNotDetermine
            Self.diag("accountStatus FAILED: \(error.localizedDescription)")
            log.error("accountStatus failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Read

    /// Sync incremental zone changes and merge into local state.
    /// Uses CKFetchRecordZoneChangesOperation — Apple's recommended sync
    /// API that requires ZERO query indexes.  This completely sidesteps the
    /// "Field recordName is not marked queryable" error that plagues
    /// CKQueryOperation and CKQuery in the development environment.
    private func syncZoneChanges() async {
        do {
            let (records, deletedIDs) = try await fetchZoneChanges()
            let convs = records
                .filter { $0.recordType == RemoteConversation.recordType }
                .compactMap { Self.conversation(from: $0) }
            let cmds = records
                .filter { $0.recordType == RemoteCommand.recordType }
                .compactMap { Self.command(from: $0) }
            // Only log when something actually changed — the 5s poll would
            // otherwise flood the diag file with identical "raw=0" lines.
            if !records.isEmpty || !deletedIDs.isEmpty {
                Self.diag("syncZoneChanges: raw=\(records.count), parsed=\(convs.count), deleted=\(deletedIDs.joined(separator: ","))")
                for r in records {
                    Self.diag("  record \(r.recordID.recordName): type=\(r.recordType), keys=\(r.allKeys().sorted().joined(separator: ",")), status=\(String(describing: r["status"])), updatedAt=\(String(describing: r["updatedAt"]))")
                }
            }

            var merged = conversations
            // Phone-side deletes land here as zone-change deletions — drop
            // them so a deleted conversation doesn't linger in memory (and
            // never gets re-enqueued). Imported codex tasks are blacklisted
            // so the next CodexSessionImporter run doesn't resurrect them.
            for id in deletedIDs {
                if CodexSessionImporter.isCodexSessionId(id) {
                    CodexSessionImporter.markDeleted(id)
                }
            }
            merged.removeAll { deletedIDs.contains($0.id) }
            for conv in convs {
                if let idx = merged.firstIndex(where: { $0.id == conv.id }) {
                    merged[idx] = conv
                } else {
                    merged.append(conv)
                }
            }
            conversations = merged.sorted { $0.updatedAt > $1.updatedAt }

            // Remote commands ride the same zone-changes stream.
            var mergedCommands = commands
            mergedCommands.removeAll { deletedIDs.contains($0.id) }
            for cmd in cmds {
                if let idx = mergedCommands.firstIndex(where: { $0.id == cmd.id }) {
                    mergedCommands[idx] = cmd
                } else {
                    mergedCommands.append(cmd)
                }
            }
            commands = mergedCommands.sorted { $0.createdAt > $1.createdAt }
        } catch {
            Self.diag("syncZoneChanges FAILED: \(error.localizedDescription)")
            log.error("syncZoneChanges failed: \(error.localizedDescription)")
        }
    }

    private static let zoneTokenKey = "RemoteConv.zoneToken"

    private func fetchZoneChanges() async throws -> (records: [CKRecord], deletedIDs: [String]) {
        let zoneID = Self.recordZoneID
        let tokenKey = Self.zoneTokenKey

        var currentToken: CKServerChangeToken? = {
            guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }()

        var allRecords: [CKRecord] = []
        var allDeletedIDs: [String] = []
        var hasMore = true

        while hasMore {
            let (records, deletedIDs, newToken, more) = try await fetchZoneChangesPage(
                zoneID: zoneID, token: currentToken)
            allRecords.append(contentsOf: records)
            allDeletedIDs.append(contentsOf: deletedIDs)
            if let newToken {
                currentToken = newToken
                if let data = try? NSKeyedArchiver.archivedData(
                    withRootObject: newToken, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: tokenKey)
                }
            }
            hasMore = more
        }

        return (allRecords, allDeletedIDs)
    }

    private func fetchZoneChangesPage(
        zoneID: CKRecordZone.ID, token: CKServerChangeToken?
    ) async throws -> (records: [CKRecord],
                        deletedIDs: [String],
                        newToken: CKServerChangeToken?, moreComing: Bool) {
        try await withCheckedThrowingContinuation { (continuation:
            CheckedContinuation<(records: [CKRecord],
                deletedIDs: [String],
                newToken: CKServerChangeToken?, moreComing: Bool), Error>) in
            var records: [CKRecord] = []
            var deletedIDs: [String] = []
            var newToken: CKServerChangeToken?
            var moreComing = false

            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID])
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            op.configurationsByRecordZoneID = [zoneID: config]

            op.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    records.append(record)
                }
            }
            op.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedIDs.append(recordID.recordName)
            }
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let zoneResult) = result {
                    newToken = zoneResult.serverChangeToken
                    moreComing = zoneResult.moreComing
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: (records, deletedIDs, newToken, moreComing))
                case .failure(let error):
                    if let ckError = error as? CKError,
                       ckError.code == .changeTokenExpired {
                        UserDefaults.standard.removeObject(forKey: Self.zoneTokenKey)
                    }
                    Self.diag("fetchZoneChangesPage FAILED: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }

            db.add(op)
        }
    }

    func fetchConversations() async {
        await syncZoneChanges()
    }

    /// Poll: sync incremental changes, then enqueue any pending conversations.
    func poll() {
        Task { @MainActor in
            await syncZoneChanges()
            // Beacon: keep the iPhone's "Mac status" row fresh (throttled
            // content changes + heartbeat keep-alive).
            publishStatusIfNeeded()
            // Remote commands (P1): claim + execute any pending command the
            // phone wrote — gated by the explicit opt-in switch.
            if Self.remoteCommandsEnabled {
                await consumePendingCommands()
            }
            let pending = conversations.filter { $0.status == .pending }
            // Log only when there's actual work — keeps the 5s heartbeat quiet.
            if !pending.isEmpty {
                Self.diag("poll: total=\(conversations.count), pending=\(pending.count)")
            }
            for conv in pending {
                // Multi-Mac execution lock: only the claiming Mac executes a
                // pending turn, so several Macs on the same iCloud account
                // never run (and reply to) the same conversation twice.
                if await tryClaimExecution(for: conv) {
                    enqueueExecution(conv)
                }
            }
        }
    }

    // MARK: - Multi-Mac execution lock

    /// How long a claimed pending turn stays locked before another Mac may
    /// take it over (stale-lock takeover, e.g. the claiming Mac crashed).
    static let executionLockTTL: TimeInterval = 300 // 5 min

    /// This Mac's identity used as the lock owner.
    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Claim a pending turn for THIS Mac. Returns true when this Mac should
    /// execute it.
    ///
    /// Locking is optimistic: write `executor = self` with .changedKeys,
    /// then RE-READ the record and verify we're still the owner. Two Macs
    /// claiming simultaneously may both write, but only the one whose write
    /// lands last (and verifies) proceeds — the loser sees another owner and
    /// skips, so a turn is never executed twice.
    private func tryClaimExecution(for conversation: RemoteConversation) async -> Bool {
        let now = Date()
        // Already claimed by this Mac → proceed.
        if conversation.executor == Self.deviceName { return true }
        // Claimed by another Mac with a fresh lock → skip this poll round.
        if let executorAt = conversation.executorAt,
           now.timeIntervalSince(executorAt) < Self.executionLockTTL {
            return false
        }
        // Unclaimed or stale → write our claim.
        var claim = conversation
        claim.executor = Self.deviceName
        claim.executorAt = now
        do {
            try await db.modifyRecords(saving: [Self.record(from: claim)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
        } catch {
            Self.diag("claim write FAILED \(conversation.id): \(error.localizedDescription)")
            return false
        }
        // Verify we won the race — re-read and check ownership.
        let recordID = CKRecord.ID(recordName: conversation.id, zoneID: Self.recordZoneID)
        guard let fresh = try? await fetchRecord(recordID),
              let reRead = Self.conversation(from: fresh),
              reRead.executor == Self.deviceName else {
            Self.diag("claim LOST for \(conversation.id) (another Mac won)")
            return false
        }
        Self.diag("claim OK: \(conversation.id) → '\(Self.deviceName)'")
        return true
    }

    private func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            let op = CKFetchRecordsOperation(recordIDs: [recordID])
            var found: CKRecord?
            // New SDK: per-record results arrive here; the operation-level
            // block only reports overall success/failure (Result<Void>).
            op.perRecordResultBlock = { _, recordResult in
                if case .success(let record) = recordResult {
                    found = record
                }
            }
            op.fetchRecordsResultBlock = { operationResult in
                switch operationResult {
                case .success:
                    continuation.resume(returning: found)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    // MARK: - Status beacon publish

    /// Build the beacon content for THIS Mac right now.
    private static func statusSnapshot(conversations: [RemoteConversation],
                                       deviceName: String) -> RemoteStatus {
        let active = conversations.filter { $0.status.isActive }
        // Prefer the currently-executing turn's last message; otherwise the
        // most recent conversation's last message. Truncate — the iPhone row
        // renders 2 lines at most.
        var text: String?
        if let running = conversations.first(where: { $0.status == .running }) {
            text = running.messages.last?.text ?? running.title
        } else if let latest = conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            text = latest.messages.last?.text ?? latest.title
        }
        return RemoteStatus(id: RemoteStatus.recordName(forDevice: deviceName),
                            deviceName: deviceName,
                            isRunning: true,
                            activeCount: active.count,
                            activityText: text.map { String($0.prefix(120)) },
                            updatedAt: Date())
    }

    /// Write the beacon when its content changed, or when the heartbeat
    /// expired (keeps the iPhone's "online" indicator honest without burning
    /// the CloudKit request budget on every 5s poll).
    private func publishStatusIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastStatusWriteAt) >= Self.statusMinInterval else { return }
        var snapshot = Self.statusSnapshot(conversations: conversations,
                                           deviceName: Self.deviceName)
        if let last = lastStatusSnapshot, last.contentEquals(snapshot) {
            // Nothing changed — heartbeat only if the stored timestamp is
            // getting stale.
            guard now.timeIntervalSince(last.updatedAt) >= Self.statusHeartbeat else { return }
            snapshot.updatedAt = now
        }
        lastStatusSnapshot = snapshot
        lastStatusWriteAt = now
        let record = Self.statusRecord(from: snapshot)
        Task {
            do {
                try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            } catch {
                Self.diag("status publish FAILED: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Remote commands

    /// Claim and execute every pending command (one round, called from poll).
    /// Claiming is write + verify (same optimistic pattern as the execution
    /// lock): two Macs may both attempt, but only the one whose claim lands
    /// last (and verifies) proceeds.
    private func consumePendingCommands() async {
        let pending = commands.filter { $0.status == .pending }
        for command in pending {
            guard await claimCommand(command) else { continue }
            Self.diag("command execute: id=\(command.id) type=\(command.type) by '\(Self.deviceName)'")
            onRemoteCommandExecution?(command)
        }
    }

    private func claimCommand(_ command: RemoteCommand) async -> Bool {
        var claim = command
        claim.status = .consumed
        claim.consumedAt = Date()
        claim.executor = Self.deviceName
        do {
            try await db.modifyRecords(saving: [Self.commandRecord(from: claim)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
        } catch {
            Self.diag("command claim write FAILED \(command.id): \(error.localizedDescription)")
            return false
        }
        // Verify we won the race — re-read and check ownership.
        let recordID = CKRecord.ID(recordName: command.id, zoneID: Self.recordZoneID)
        guard let fresh = try? await fetchRecord(recordID),
              let reRead = Self.command(from: fresh),
              reRead.status == .consumed, reRead.executor == Self.deviceName else {
            Self.diag("command claim LOST \(command.id) (another Mac won)")
            return false
        }
        Self.diag("command claim OK: \(command.id) type=\(command.type)")
        return true
    }

    /// Write the command outcome after the app layer executed it. Called by
    /// the AppDelegate bridge (or the app bridge itself on failure).
    func finishCommand(_ command: RemoteCommand, result: String? = nil, error: String? = nil) {
        var final = command
        if let error {
            final.status = .error
            final.result = error
        } else {
            final.status = .done
            final.result = result
        }
        if let idx = commands.firstIndex(where: { $0.id == command.id }) {
            commands[idx] = final
        }
        Task {
            do {
                try await db.modifyRecords(saving: [Self.commandRecord(from: final)],
                                           deleting: [],
                                           savePolicy: .changedKeys)
                Self.diag("command finish OK: id=\(command.id) status=\(final.status.rawValue)")
            } catch {
                Self.diag("command finish FAILED: id=\(command.id) err=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Write

    /// Create a conversation record (normally created by the iPhone, but kept
    /// here so the Mac can create test/demo conversations too).
    func createConversation(_ conversation: RemoteConversation) async throws {
        try await db.save(Self.record(from: conversation))
    }

    /// Append a user/assistant message and mark the conversation running.
    func appendMessage(_ message: RemoteConversationMessage, to conversation: RemoteConversation) async {
        var updated = conversation
        updated.messages.append(message)
        updated.status = .running
        updated.updatedAt = Date()
        do {
            // modifyRecords (not save) so updating an existing record works.
            try await db.modifyRecords(saving: [Self.record(from: updated)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
            Self.diag("appendMessage OK: id=\(conversation.id), status=\(updated.status.rawValue)")
        } catch {
            Self.diag("appendMessage FAILED: id=\(conversation.id), err=\(error.localizedDescription)")
        }
    }

    func updateStatus(_ conversation: RemoteConversation) {
        // Always update the in-memory model first — the poll loop re-enqueues
        // anything still .pending every 5s, so a slow/failed CloudKit write
        // would otherwise retrigger the same turn forever.
        var final = conversation
        if !conversation.status.isActive {
            // Turn finished (done/error) — release the execution lock so the
            // next pending message can be claimed again.
            final.executor = nil
            final.executorAt = nil
        }
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = final
        }
        Task {
            do {
                // CKDatabase.save() on an EXISTING recordName tries an insert
                // and fails with "record to insert already exists". Use
                // modifyRecords with .changedKeys for a true update.
                try await db.modifyRecords(saving: [Self.record(from: final)],
                                           deleting: [],
                                           savePolicy: .changedKeys)
                Self.diag("updateStatus OK: id=\(conversation.id), status=\(conversation.status.rawValue)")
            } catch {
                Self.diag("updateStatus FAILED: id=\(conversation.id), err=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Execution

    func enqueueExecution(_ conversation: RemoteConversation) {
        runningCount += 1
        Self.diag("enqueueExecution: id=\(conversation.id), tool=\(conversation.tool), status=\(conversation.status.rawValue), msgs=\(conversation.messages.count)")
        sessionManager.enqueue(conversation) { [weak self] updated in
            Task { @MainActor in
                self?.runningCount = max(0, (self?.runningCount ?? 1) - 1)
                Self.diag("turn finished: id=\(updated.id), status=\(updated.status.rawValue), msgs=\(updated.messages.count), err=\(updated.errorMessage ?? "nil")")
                self?.updateStatus(updated)
                await self?.fetchConversations()
            }
        }
    }

    // MARK: - Subscription

    /// Register a database-level subscription (not a query subscription).
    /// CKDatabaseSubscription fires on ANY record change in the database,
    /// requiring ZERO query indexes — unlike CKQuerySubscription which
    /// triggers the "recordName is not marked queryable" error.
    private func registerSubscription() {
        let sub = CKDatabaseSubscription(subscriptionID: "notchdeck-remote-conv-db")
        sub.notificationInfo = CKSubscription.NotificationInfo()
        sub.notificationInfo?.shouldSendContentAvailable = true // silent push wakes the app
        Task {
            do {
                try await db.save(sub)
            } catch {
                log.error("registerSubscription failed (may already exist): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Record mapping

    private static func record(from conversation: RemoteConversation) -> CKRecord {
        let record = CKRecord(recordType: RemoteConversation.recordType,
                              recordID: CKRecord.ID(recordName: conversation.id,
                                                    zoneID: RemoteConversationService.recordZoneID))
        record["sessionId"] = conversation.sessionId as CKRecordValue
        record["tool"] = conversation.tool as CKRecordValue
        record["title"] = conversation.title as CKRecordValue
        record["messages"] = (try? JSONEncoder().encode(conversation.messages)) as CKRecordValue?
        record["status"] = conversation.status.rawValue as CKRecordValue
        record["updatedAt"] = conversation.updatedAt as CKRecordValue
        if let errorMessage = conversation.errorMessage {
            record["errorMessage"] = errorMessage as CKRecordValue
        }
        if let executor = conversation.executor {
            record["executor"] = executor as CKRecordValue
        }
        if let executorAt = conversation.executorAt {
            record["executorAt"] = executorAt as CKRecordValue
        }
        return record
    }

    private static func conversation(from record: CKRecord) -> RemoteConversation? {
        guard let sessionId = record["sessionId"] as? String,
              let tool = record["tool"] as? String,
              let statusRaw = record["status"] as? String,
              let status = RemoteConversationStatus(rawValue: statusRaw),
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        let messagesData = record["messages"] as? Data
        let messages = messagesData.flatMap { try? JSONDecoder().decode([RemoteConversationMessage].self, from: $0) } ?? []
        return RemoteConversation(
            id: record.recordID.recordName,
            sessionId: sessionId,
            tool: tool,
            title: (record["title"] as? String) ?? "Conversation",
            messages: messages,
            status: status,
            updatedAt: updatedAt,
            errorMessage: record["errorMessage"] as? String,
            executor: record["executor"] as? String,
            executorAt: record["executorAt"] as? Date
        )
    }

    // MARK: - Status record mapping

    private static func statusRecord(from status: RemoteStatus) -> CKRecord {
        let record = CKRecord(recordType: RemoteStatus.recordType,
                              recordID: CKRecord.ID(recordName: status.id,
                                                    zoneID: RemoteConversationService.recordZoneID))
        record["deviceName"] = status.deviceName as CKRecordValue
        record["isRunning"] = status.isRunning as CKRecordValue
        record["activeCount"] = status.activeCount as CKRecordValue
        if let activityText = status.activityText {
            record["activityText"] = activityText as CKRecordValue
        }
        record["updatedAt"] = status.updatedAt as CKRecordValue
        record["version"] = status.version as CKRecordValue
        return record
    }

    /// Parse a RemoteStatus record (used by the iPhone; kept here symmetric).
    static func status(from record: CKRecord) -> RemoteStatus? {
        guard let deviceName = record["deviceName"] as? String,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        return RemoteStatus(id: record.recordID.recordName,
                            deviceName: deviceName,
                            isRunning: (record["isRunning"] as? Bool) ?? false,
                            activeCount: (record["activeCount"] as? Int) ?? 0,
                            activityText: record["activityText"] as? String,
                            updatedAt: updatedAt,
                            version: (record["version"] as? Int) ?? 1)
    }

    // MARK: - Command record mapping

    static func commandRecord(from command: RemoteCommand) -> CKRecord {
        let record = CKRecord(recordType: RemoteCommand.recordType,
                              recordID: CKRecord.ID(recordName: command.id,
                                                    zoneID: RemoteConversationService.recordZoneID))
        record["type"] = command.type as CKRecordValue
        if let sessionId = command.sessionId { record["sessionId"] = sessionId as CKRecordValue }
        if let source = command.source { record["source"] = source as CKRecordValue }
        if let answer = command.answer { record["answer"] = answer as CKRecordValue }
        record["status"] = command.status.rawValue as CKRecordValue
        record["createdAt"] = command.createdAt as CKRecordValue
        if let consumedAt = command.consumedAt { record["consumedAt"] = consumedAt as CKRecordValue }
        if let executor = command.executor { record["executor"] = executor as CKRecordValue }
        if let result = command.result { record["result"] = result as CKRecordValue }
        return record
    }

    static func command(from record: CKRecord) -> RemoteCommand? {
        guard let type = record["type"] as? String,
              let statusRaw = record["status"] as? String,
              let status = RemoteCommandStatus(rawValue: statusRaw),
              let createdAt = record["createdAt"] as? Date else { return nil }
        return RemoteCommand(id: record.recordID.recordName,
                             type: type,
                             sessionId: record["sessionId"] as? String,
                             source: record["source"] as? String,
                             answer: record["answer"] as? String,
                             status: status,
                             createdAt: createdAt,
                             consumedAt: record["consumedAt"] as? Date,
                             executor: record["executor"] as? String,
                             result: record["result"] as? String)
    }
}
