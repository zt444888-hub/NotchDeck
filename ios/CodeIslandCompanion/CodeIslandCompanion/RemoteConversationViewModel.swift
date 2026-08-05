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
        let query = CKQuery(recordType: RemoteConversation.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 50)
            var items: [RemoteConversation] = []
            for (_, result) in results {
                if case .success(let record) = result,
                   let conv = Self.conversation(from: record) { items.append(conv) }
            }
            conversations = items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Write

    /// Send a user message. Creates a conversation if it's the first message.
    func send(_ text: String, in conversation: RemoteConversation? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = RemoteConversationMessage(role: "user", text: trimmed)
        do {
            if var conv = conversation {
                // Append to existing conversation (multi-turn).
                conv.messages.append(message)
                conv.status = .pending
                conv.updatedAt = Date()
                try await db.save(Self.record(from: conv))
            } else {
                // New conversation.
                let conv = RemoteConversation(title: String(trimmed.prefix(40)), messages: [message])
                try await db.save(Self.record(from: conv))
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
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
