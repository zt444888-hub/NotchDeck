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
///   - Subscription (CKQuerySubscription) pushes a silent notification when a
///     pending conversation appears → we fetch and execute.
///   - A 30s poll timer is the fallback (push can be delayed/dropped by APNs).
@MainActor
final class RemoteConversationService: ObservableObject {

    static let shared = RemoteConversationService()
    static let containerIdentifier = "iCloud.com.notchdeck"

    @Published private(set) var conversations: [RemoteConversation] = []
    @Published private(set) var runningCount = 0

    private let container: CKContainer
    private let db: CKDatabase
    private let sessionManager = RemoteAgentSessionManager()
    private var pollTimer: Timer?
    private(set) var isRunning = false

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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Read

    func fetchConversations() async {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: RemoteConversation.recordType, predicate: predicate)
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
            log.error("fetchConversations failed: \(error.localizedDescription)")
        }
    }

    /// Poll: fetch pending conversations and execute them (subscription fallback).
    func poll() {
        let predicate = NSPredicate(format: "status IN %@", [RemoteConversationStatus.pending.rawValue])
        let query = CKQuery(recordType: RemoteConversation.recordType, predicate: predicate)
        Task {
            do {
                let (results, _) = try await db.records(matching: query, resultsLimit: 20)
                for (_, result) in results {
                    guard case .success(let record) = result,
                          let conv = Self.conversation(from: record) else { continue }
                    enqueueExecution(conv)
                }
            } catch {
                log.error("poll failed: \(error.localizedDescription)")
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

    private func registerSubscription() {
        let predicate = NSPredicate(format: "status == %@", RemoteConversationStatus.pending.rawValue)
        let sub = CKQuerySubscription(recordType: RemoteConversation.recordType,
                                      predicate: predicate,
                                      subscriptionID: "notchdeck-pending-conversations",
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate])
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
