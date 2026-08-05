import Foundation

// MARK: - Remote AI conversation (v1.2.0)
//
// Shared model between the Mac app (executes the agent) and the iPhone
// companion (drives the conversation). Persisted in CloudKit private
// database: data lives in the user's own iCloud, developer can't read it.

/// One message in a remote conversation.
public struct RemoteConversationMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String   // "user" | "assistant" | "system"
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, role: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// Lifecycle of a remote conversation/task.
public enum RemoteConversationStatus: String, Codable, Sendable {
    case pending    // user sent the first message; Mac hasn't picked it up yet
    case running    // agent executing
    case done       // agent finished the turn
    case error      // agent failed

    public var isActive: Bool { self == .pending || self == .running }
}

/// A remote conversation record (CloudKit record type `RemoteConversation`).
public struct RemoteConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String            // record ID
    public var sessionId: String     // stable agent session id (claude --resume)
    public var tool: String          // "claude" | "codex" | ...
    public var title: String         // first user message snippet
    public var messages: [RemoteConversationMessage]
    public var status: RemoteConversationStatus
    public var updatedAt: Date
    public var errorMessage: String?

    public init(id: String = UUID().uuidString,
                sessionId: String = UUID().uuidString,
                tool: String = "claude",
                title: String = "New conversation",
                messages: [RemoteConversationMessage] = [],
                status: RemoteConversationStatus = .pending,
                updatedAt: Date = Date(),
                errorMessage: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.tool = tool
        self.title = title
        self.messages = messages
        self.status = status
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    /// CloudKit record type name.
    public static let recordType = "RemoteConversation"
}
