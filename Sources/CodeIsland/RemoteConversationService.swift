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

    private let container: CKContainer
    private let db: CKDatabase
    private let sessionManager = RemoteAgentSessionManager()
    private var pollTimer: Timer?
    private(set) var isRunning = false

    /// Poll interval: pushed silent notifications aren't available to
    /// Developer ID–distributed Mac apps, so keep the fallback snappy.
    static let pollInterval: TimeInterval = 5

    init(containerIdentifier: String = RemoteConversationService.containerIdentifier) {
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        self.db = container.privateCloudDatabase
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionManager.onTurnFinished = { [weak self] conversation in
            Task { @MainActor in
                self?.updateStatus(conversation)
            }
        }
        registerSubscription()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
        Task { await refreshAccountStatus() }
    }

    /// Check whether the signed-in iCloud account can use this container.
    /// `.available` means the whole chain can work.
    func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
        } catch {
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
            let records = try await fetchZoneChanges()
            let convs = records
                .filter { $0.recordType == RemoteConversation.recordType }
                .compactMap { Self.conversation(from: $0) }

            var merged = conversations
            for conv in convs {
                if let idx = merged.firstIndex(where: { $0.id == conv.id }) {
                    merged[idx] = conv
                } else {
                    merged.append(conv)
                }
            }
            conversations = merged.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            log.error("syncZoneChanges failed: \(error.localizedDescription)")
        }
    }

    private static let zoneTokenKey = "RemoteConv.zoneToken"

    private func fetchZoneChanges() async throws -> [CKRecord] {
        let zoneID = CKRecordZone.default().zoneID
        let tokenKey = Self.zoneTokenKey

        var currentToken: CKServerChangeToken? = {
            guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }()

        var allRecords: [CKRecord] = []
        var hasMore = true

        while hasMore {
            let (records, newToken, more) = try await fetchZoneChangesPage(
                zoneID: zoneID, token: currentToken)
            allRecords.append(contentsOf: records)
            if let newToken {
                currentToken = newToken
                if let data = try? NSKeyedArchiver.archivedData(
                    withRootObject: newToken, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: tokenKey)
                }
            }
            hasMore = more
        }

        return allRecords
    }

    private func fetchZoneChangesPage(
        zoneID: CKRecordZone.ID, token: CKServerChangeToken?
    ) async throws -> (records: [CKRecord],
                        newToken: CKServerChangeToken?, moreComing: Bool) {
        try await withCheckedThrowingContinuation { (continuation:
            CheckedContinuation<(records: [CKRecord],
                newToken: CKServerChangeToken?, moreComing: Bool), Error>) in
            var records: [CKRecord] = []
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
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let zoneResult) = result {
                    newToken = zoneResult.serverChangeToken
                    moreComing = zoneResult.moreComing
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: (records, newToken, moreComing))
                case .failure(let error):
                    if let ckError = error as? CKError,
                       ckError.code == .changeTokenExpired {
                        UserDefaults.standard.removeObject(forKey: Self.zoneTokenKey)
                    }
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
            let pending = conversations.filter { $0.status == .pending }
            for conv in pending { enqueueExecution(conv) }
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
            try await db.save(Self.record(from: updated))
        } catch {
            log.error("appendMessage failed: \(error.localizedDescription)")
        }
    }

    func updateStatus(_ conversation: RemoteConversation) {
        Task {
            do {
                try await db.save(Self.record(from: conversation))
            } catch {
                log.error("updateStatus failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Execution

    func enqueueExecution(_ conversation: RemoteConversation) {
        runningCount += 1
        sessionManager.enqueue(conversation) { [weak self] updated in
            Task { @MainActor in
                self?.runningCount = max(0, (self?.runningCount ?? 1) - 1)
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
                              recordID: CKRecord.ID(recordName: conversation.id))
        record["sessionId"] = conversation.sessionId as CKRecordValue
        record["tool"] = conversation.tool as CKRecordValue
        record["title"] = conversation.title as CKRecordValue
        record["messages"] = (try? JSONEncoder().encode(conversation.messages)) as CKRecordValue?
        record["status"] = conversation.status.rawValue as CKRecordValue
        record["updatedAt"] = conversation.updatedAt as CKRecordValue
        if let errorMessage = conversation.errorMessage {
            record["errorMessage"] = errorMessage as CKRecordValue
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
            errorMessage: record["errorMessage"] as? String
        )
    }
}
