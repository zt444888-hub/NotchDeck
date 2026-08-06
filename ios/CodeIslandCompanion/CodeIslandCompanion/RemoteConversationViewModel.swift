import Foundation
import CloudKit
import Combine

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

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Read

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await fetchZoneChanges()
            let convs = records
                .filter { $0.recordType == RemoteConversation.recordType }
                .compactMap { Self.conversation(from: $0) }

            // Merge: first fetch (conversations empty) → just add all;
            // subsequent fetches → update existing, add new.
            var merged = conversations
            for conv in convs {
                if let idx = merged.firstIndex(where: { $0.id == conv.id }) {
                    merged[idx] = conv
                } else {
                    merged.append(conv)
                }
            }
            conversations = merged.sorted { $0.updatedAt > $1.updatedAt }
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
    private func fetchZoneChanges() async throws -> [CKRecord] {
        let zoneID = CKRecordZone.default().zoneID
        let tokenKey = "RemoteConv.zoneToken"

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

        // Fail fast with a clear, actionable message instead of a silent save.
        guard await accountIsReady() else { return }

        let message = RemoteConversationMessage(role: "user", text: trimmed)
        do {
            if var conv = conversation {
                // Append to existing conversation (multi-turn).
                conv.messages.append(message)
                conv.status = .pending
                conv.updatedAt = Date()
                try await db.save(Self.record(from: conv))
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
        return raw
    }

    // MARK: - Record mapping (kept in sync with the Mac service)

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
