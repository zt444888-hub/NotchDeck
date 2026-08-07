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
    public var executor: String?
    public var executorAt: Date?

    public init(id: String = UUID().uuidString,
                sessionId: String = UUID().uuidString,
                tool: String = "claude",
                title: String = "New conversation",
                messages: [RemoteConversationMessage] = [],
                status: RemoteConversationStatus = .pending,
                updatedAt: Date = Date(),
                errorMessage: String? = nil,
                executor: String? = nil,
                executorAt: Date? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.tool = tool
        self.title = title
        self.messages = messages
        self.status = status
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.executor = executor
        self.executorAt = executorAt
    }

    public static let recordType = "RemoteConversation"
}

// Mirror of the Mac's RemoteStatus beacon model (kept in sync manually).
public struct RemoteStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceName: String
    public var isRunning: Bool
    public var activeCount: Int
    public var activityText: String?
    public var updatedAt: Date
    public var version: Int

    public init(id: String = UUID().uuidString,
                deviceName: String,
                isRunning: Bool,
                activeCount: Int = 0,
                activityText: String? = nil,
                updatedAt: Date = Date(),
                version: Int = 1) {
        self.id = id
        self.deviceName = deviceName
        self.isRunning = isRunning
        self.activeCount = activeCount
        self.activityText = activityText
        self.updatedAt = updatedAt
        self.version = version
    }

    public static let recordType = "RemoteStatus"

    public static func recordName(forDevice deviceName: String) -> String {
        let hex = deviceName.utf8.map { String(format: "%02x", $0) }.joined()
        return "status-" + String(hex.prefix(16))
    }

    public func contentEquals(_ other: RemoteStatus) -> Bool {
        id == other.id
            && deviceName == other.deviceName
            && isRunning == other.isRunning
            && activeCount == other.activeCount
            && activityText == other.activityText
            && version == other.version
    }
}

// Mirror of the Mac's RemoteCommand model (kept in sync manually).
public enum RemoteCommandStatus: String, Codable, Sendable {
    case pending, consumed, done, error
}

public struct RemoteCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var sessionId: String?
    public var source: String?
    public var answer: String?
    public var status: RemoteCommandStatus
    public var createdAt: Date
    public var consumedAt: Date?
    public var executor: String?
    public var result: String?

    public init(id: String = UUID().uuidString,
                type: String,
                sessionId: String? = nil,
                source: String? = nil,
                answer: String? = nil,
                status: RemoteCommandStatus = .pending,
                createdAt: Date = Date(),
                consumedAt: Date? = nil,
                executor: String? = nil,
                result: String? = nil) {
        self.id = id
        self.type = type
        self.sessionId = sessionId
        self.source = source
        self.answer = answer
        self.status = status
        self.createdAt = createdAt
        self.consumedAt = consumedAt
        self.executor = executor
        self.result = result
    }

    public static let recordType = "RemoteCommand"
}
