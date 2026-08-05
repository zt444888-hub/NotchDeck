import Foundation

// Mirror of Sources/CodeIslandCore/RemoteConversationModels.swift for the
// iOS companion target (kept in sync manually; Foundation-only).

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

public enum RemoteConversationStatus: String, Codable, Sendable {
    case pending, running, done, error
    public var isActive: Bool { self == .pending || self == .running }
}

public struct RemoteConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionId: String
    public var tool: String
    public var title: String
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

    public static let recordType = "RemoteConversation"
}
