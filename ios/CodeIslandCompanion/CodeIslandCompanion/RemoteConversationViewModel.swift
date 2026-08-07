import Foundation
import CloudKit
import Combine
import UserNotifications

/// Drives the remote AI conversation from the iPhone side (v1.2.0).
/// Conversations live in the user's CloudKit private database; the Mac
/// watches for pending ones and executes the agent turn.
@MainActor
final class RemoteConversationViewModel: ObservableObject {

    @Published private(set) var conversations: [RemoteConversation] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.notchdeck")
    private var db: CKDatabase { container.privateCloudDatabase }
    private var pollTimer: Timer?

    /// Custom zone required by CKFetchRecordZoneChangesOperation —
    /// the DEFAULT zone does NOT support zone-change sync semantics
    /// (Apple: "Syncing the default zone is not supported"), so it would
    /// silently return 0 records forever. All reads/writes use this zone.
    static let recordZoneID = CKRecordZone.ID(zoneName: "RemoteConversations")

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Create the custom zone if it doesn't exist yet. CloudKit does NOT
    /// auto-create custom zones; saving to a missing zone fails. This is
    /// idempotent — saving an existing zone throws but is harmless.
    private func ensureZone() async {
        do {
            _ = try await db.save(CKRecordZone(zoneID: Self.recordZoneID))
        } catch {
            // zoneAlreadyExists (or any other error) is fine — we just need
            // the zone to exist; the actual save below will surface real
            // failures.
        }
    }

    // MARK: - Read

    func refresh() async {
        // Guard against overlapping fetches: the 10s poll timer can fire
        // while a slow CloudKit fetch (or a burst of deletes) is still in
        // flight. Without this, requests pile up and the UI appears frozen.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await ensureZone()
        do {
            // Fresh view model (page re-entered) must do a FULL fetch — the
            // stored zone token was advanced by a previous session, so an
            // incremental fetch would return nothing and history appears
            // lost. Reset the token when we have no local conversations.
            if conversations.isEmpty {
                UserDefaults.standard.removeObject(forKey: "RemoteConv.zoneToken")
            }
            let (records, deletedIDs) = try await fetchZoneChanges()
            let convs = records
                .filter { $0.recordType == RemoteConversation.recordType }
                .compactMap { Self.conversation(from: $0) }

            // Merge: first fetch (conversations empty) → just add all;
            // subsequent fetches → update existing, add new, drop deleted
            // (deletes made on another device arrive as zone deletions).
            let wasActive = Set(conversations.filter { $0.status.isActive }.map(\.id))
            var merged = conversations
            merged.removeAll { deletedIDs.contains($0.id) }
            for conv in convs {
                if let idx = merged.firstIndex(where: { $0.id == conv.id }) {
                    merged[idx] = conv
                } else {
                    merged.append(conv)
                }
            }
            conversations = merged.sorted { $0.updatedAt > $1.updatedAt }
            errorMessage = nil
            // Notify on active → done transitions (skipped on the first
            // load, so history doesn't spam a notification per conversation).
            if hasLoadedOnce {
                notifyReplyIfNeeded(wasActive: wasActive, in: conversations)
            }
            hasLoadedOnce = true
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    // MARK: - Reply notifications

    private var hasLoadedOnce = false

    /// Post a local notification when a conversation the user sent a message
    /// to transitions from pending/running to done (Mac finished replying).
    private func notifyReplyIfNeeded(wasActive: Set<String>, in current: [RemoteConversation]) {
        for conv in current where conv.status == .done && conv.errorMessage == nil && !wasActive.contains(conv.id) {
            postLocalNotification(title: L10n.t(zh: "Mac 已回复", en: "Mac replied"),
                                  body: conv.title)
        }
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Delete

    /// Delete a conversation from CloudKit and drop it from local state.
    /// The Mac picks the deletion up via zone-change sync and stops showing
    /// it too.
    func delete(_ conversation: RemoteConversation) async {
        let recordID = CKRecord.ID(recordName: conversation.id, zoneID: Self.recordZoneID)
        do {
            // CKDatabase has no async delete(withRecordID:) overload — route
            // through modifyRecords(deleting:), which is async (iOS 15+).
            _ = try await db.modifyRecords(saving: [], deleting: [recordID])
            conversations.removeAll { $0.id == conversation.id }
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Delete every conversation (batch, single CloudKit round-trip).
    func deleteAll() async {
        let ids = conversations.map {
            CKRecord.ID(recordName: $0.id, zoneID: Self.recordZoneID)
        }
        guard !ids.isEmpty else { return }
        do {
            _ = try await db.modifyRecords(saving: [], deleting: ids)
            conversations.removeAll()
            // Drop the zone token so the next refresh does a clean full fetch
            // (no lingering change-token pointing at now-deleted records).
            UserDefaults.standard.removeObject(forKey: "RemoteConv.zoneToken")
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    // MARK: - Actions (rename / cancel / retry)

    /// Rename a conversation (title is user-facing only; safe to edit).
    func rename(_ conversation: RemoteConversation, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.title else { return }
        var updated = conversation
        updated.title = String(trimmed.prefix(60))
        updated.updatedAt = Date()
        do {
            try await db.modifyRecords(saving: [Self.record(from: updated)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
            if let idx = conversations.firstIndex(where: { $0.id == updated.id }) {
                conversations[idx] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Cancel a turn the user no longer wants executed: mark done with a
    /// "cancelled" note. Effective for turns the Mac hasn't started yet;
    /// one already executing keeps running (a hard kill would need an
    /// out-of-band cancel channel).
    func cancel(_ conversation: RemoteConversation) async {
        guard conversation.status.isActive else { return }
        var updated = conversation
        updated.status = .done
        updated.errorMessage = "cancelled by user"
        updated.updatedAt = Date()
        do {
            try await db.modifyRecords(saving: [Self.record(from: updated)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
            if let idx = conversations.firstIndex(where: { $0.id == updated.id }) {
                conversations[idx] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Retry a failed turn: flip back to pending so the Mac picks it up
    /// again (the last user message is already in `messages`).
    func retry(_ conversation: RemoteConversation) async {
        guard conversation.status == .error else { return }
        var updated = conversation
        updated.status = .pending
        updated.errorMessage = nil
        updated.updatedAt = Date()
        do {
            try await db.modifyRecords(saving: [Self.record(from: updated)],
                                       deleting: [],
                                       savePolicy: .changedKeys)
            if let idx = conversations.firstIndex(where: { $0.id == updated.id }) {
                conversations[idx] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    // MARK: - Zone Changes (no query indexes needed)

    /// Fetch all record changes in the default zone since the last token.
    /// Uses CKFetchRecordZoneChangesOperation — Apple's recommended sync
    /// API that requires ZERO query indexes.  This completely sidesteps the
    /// "Field recordName is not marked queryable" error that plagues
    /// CKQueryOperation and CKQuery in the development environment.
    private func fetchZoneChanges() async throws -> (records: [CKRecord], deletedIDs: [String]) {
        let zoneID = Self.recordZoneID
        let tokenKey = "RemoteConv.zoneToken"

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
                        UserDefaults.standard.removeObject(forKey: "RemoteConv.zoneToken")
                    }
                    continuation.resume(throwing: error)
                }
            }

            db.add(op)
        }
    }

    // MARK: - Write

    /// Send a user message. Creates a conversation if it's the first message.
    func send(_ text: String, in conversation: RemoteConversation? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ask for notification permission on the first send, so the user
        // gets a "Mac replied" banner instead of polling manually.
        requestNotificationPermissionIfNeeded()

        // Fail fast with a clear, actionable message instead of a silent save.
        guard await accountIsReady() else { return }
        await ensureZone()

        let message = RemoteConversationMessage(role: "user", text: trimmed)
        do {
            if var conv = conversation {
                // Append to existing conversation (multi-turn).
                conv.messages.append(message)
                conv.status = .pending
                conv.updatedAt = Date()
                // modifyRecords (not save): the record already exists, and
                // save() attempts an INSERT → "record to insert already
                // exists". This is why multi-turn replies never landed.
                try await db.modifyRecords(saving: [Self.record(from: conv)],
                                           deleting: [],
                                           savePolicy: .changedKeys)
                // Optimistic update: reflect the new message locally right away.
                // Zone-changes reads can lag behind a just-completed save, so
                // never depend on a fetch to show what the user just typed.
                if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                    conversations[idx] = conv
                }
            } else {
                // New conversation. tool = "auto": the Mac picks whichever
                // agent CLI it has installed (falls back to Demo mode).
                let conv = RemoteConversation(tool: "auto",
                                              title: String(trimmed.prefix(40)),
                                              messages: [message])
                try await db.save(Self.record(from: conv))
                // Optimistic update so the new conversation is visible
                // immediately, even if the zone-changes fetch lags.
                conversations.insert(conv, at: 0)
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Returns false (and sets a guidance message) when CloudKit can't work.
    private func accountIsReady() async -> Bool {
        do {
            switch try await container.accountStatus() {
            case .available:
                return true
            case .noAccount:
                errorMessage = L10n.t(zh: "未登录 iCloud：请到 设置 → 你的头像 → iCloud 登录。远程对话需要同一账号的 iCloud 同步。",
                                      en: "Not signed in to iCloud: sign in at Settings → your name → iCloud. Remote conversations need iCloud sync on the same account.")
            case .restricted:
                errorMessage = L10n.t(zh: "iCloud 在此设备上被限制（可能为组织管理设备）。",
                                      en: "iCloud is restricted on this device (e.g. managed device).")
            case .temporarilyUnavailable:
                errorMessage = L10n.t(zh: "iCloud 暂时不可用，请稍后重试。",
                                      en: "iCloud temporarily unavailable, try again later.")
            @unknown default:
                errorMessage = L10n.t(zh: "iCloud 状态未知，请稍后重试。",
                                      en: "iCloud status unknown, try again later.")
            }
        } catch {
            errorMessage = L10n.t(zh: "无法检测 iCloud 状态：\(error.localizedDescription)",
                                  en: "Couldn't check iCloud status: \(error.localizedDescription)")
        }
        return false
    }

    /// Translate an error into an actionable message.
    static func friendlyError(_ error: Error) -> String {
        let raw = error.localizedDescription
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return L10n.t(zh: "iCloud 未登录或未授权。请在系统设置中登录 iCloud。",
                              en: "Not authenticated with iCloud. Sign in in System Settings.")
            case .networkUnavailable:
                return L10n.t(zh: "网络不可用，请检查连接后重试。",
                              en: "Network unavailable. Check your connection and retry.")
            case .quotaExceeded:
                return L10n.t(zh: "iCloud 存储空间不足。请到 设置 → 你的 Apple ID → iCloud → 管理账户存储 清理照片/备份后重试。",
                              en: "iCloud storage is full. Free up space at Settings → your name → iCloud → Manage Account Storage, then retry.")
            default:
                break
            }
        }
        return raw
    }

    /// Map an agent error written back by the Mac into an actionable hint.
    static func friendlyAgentError(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if lowered.contains("not found in path") || lowered.contains("failed to launch agent") || lowered.contains("unsupported tool") {
            return L10n.t(zh: "Mac 未安装可用的 AI 执行器（Claude Code 或 Codex）。请在 Mac 端打开 NotchDeck 设置 → Remote AI Conversation，按提示安装后重试。",
                          en: "The Mac has no AI agent installed (Claude Code or Codex). Open NotchDeck settings on the Mac → Remote AI Conversation and follow the install guide, then retry.")
        }
        if lowered.contains("sign in") || lowered.contains("authentication") || lowered.contains("logged in") {
            return L10n.t(zh: "Mac 上的 AI 执行器未登录。请先在 Mac 的终端里登录对应账号（claude / codex 的登录流程）。",
                          en: "The AI agent on the Mac isn't signed in. Sign in from a Mac terminal first (claude / codex login).")
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return L10n.t(zh: "Mac 端执行超时。可能是 cc-switch（DeepSeek 代理）未运行或响应较慢，请稍后重试。",
                          en: "The Mac agent timed out. The cc-switch (DeepSeek proxy) may not be running or may be slow — try again later.")
        }
        if lowered.contains("connection refused") || lowered.contains("proxy") || lowered.contains("ecode") {
            return L10n.t(zh: "Mac 无法连接 AI 代理。请在 Mac 上确认 cc-switch（DeepSeek 代理）已启动。",
                          en: "The Mac can't reach the AI proxy. Make sure cc-switch (DeepSeek proxy) is running on the Mac.")
        }
        if lowered.contains("unavailable") {
            return L10n.t(zh: "Mac 上的 AI 执行器暂不可用，请确认对应 CLI 已登录、代理已启动后重试。",
                          en: "The Mac's AI agent is unavailable — check the CLI is signed in and the proxy is running, then retry.")
        }
        return raw
    }

    // MARK: - Record mapping (kept in sync with the Mac service)

    private static func record(from conversation: RemoteConversation) -> CKRecord {
        let record = CKRecord(recordType: RemoteConversation.recordType,
                              recordID: CKRecord.ID(recordName: conversation.id,
                                                    zoneID: RemoteConversationViewModel.recordZoneID))
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
