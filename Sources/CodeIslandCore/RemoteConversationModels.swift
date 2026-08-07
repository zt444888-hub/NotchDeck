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
    /// Which Mac claimed this pending turn (multi-Mac execution lock).
    /// nil = unclaimed; set while a Mac executes, cleared on completion.
    public var executor: String?
    /// When the executor claimed it; used for stale-lock takeover (TTL).
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

    /// CloudKit record type name.
    public static let recordType = "RemoteConversation"
}

// MARK: - Remote status beacon (v1.3.0)
//
// The Mac upserts ONE status record per device (stable record name) every
// few seconds so the iPhone can show whether the Mac is reachable and what
// it is doing — over ANY network (the record travels through the same
// CloudKit private zone as conversations, so no MPC/local-network needed).

/// A remote status beacon (CloudKit record type `RemoteStatus`).
public struct RemoteStatus: Codable, Equatable, Identifiable, Sendable {
    /// Record ID — stable per device, derived from the Mac's name so
    /// multiple Macs on the same iCloud account don't overwrite each other.
    public var id: String
    /// Mac display name (lock owner name).
    public var deviceName: String
    /// App is running and Remote AI is enabled on this Mac.
    public var isRunning: Bool
    /// Number of conversations currently pending + running.
    public var activeCount: Int
    /// Latest activity summary (running turn text, or last message).
    public var activityText: String?
    /// Heartbeat timestamp (updated on content change or keep-alive).
    public var updatedAt: Date
    /// Payload schema version (bump on incompatible field changes).
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

    /// CloudKit record type name.
    public static let recordType = "RemoteStatus"

    /// Stable per-device record name: hex hash of the Mac name (safe for
    /// CloudKit record names, which reject characters like `/` and `:`).
    public static func recordName(forDevice deviceName: String) -> String {
        let hex = deviceName.utf8.map { String(format: "%02x", $0) }.joined()
        return "status-" + String(hex.prefix(16))
    }

    /// Equality over everything EXCEPT the heartbeat timestamp — used by the
    /// Mac to decide whether a content change warrants a CloudKit write.
    public func contentEquals(_ other: RemoteStatus) -> Bool {
        id == other.id
            && deviceName == other.deviceName
            && isRunning == other.isRunning
            && activeCount == other.activeCount
            && activityText == other.activityText
            && version == other.version
    }
}

// MARK: - Remote command (v1.3.0, P1)
//
// A control command the iPhone sends through CloudKit so it can drive the
// Mac even when MPC (local network) isn't reachable. The Mac polls pending
// commands, claims one (write + verify, same pattern as the execution lock),
// executes the action through the app bridge, and writes the result back.

/// Lifecycle of a remote command.
public enum RemoteCommandStatus: String, Codable, Sendable {
    case pending    // phone wrote it; no Mac claimed it yet
    case consumed   // a Mac claimed it and is executing
    case done       // executed successfully
    case error      // execution failed (result carries the message)
}

/// A remote command record (CloudKit record type `RemoteCommand`).
public struct RemoteCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Command type — matches `AppleCompanionCommandType` raw values
    /// ("focus", "answerQuestion", "approveCurrentPermission", ...) so the
    /// Mac can reuse the exact same app-bridge handlers as the MPC path.
    public var type: String
    /// Target session id (e.g. focus a specific session).
    public var sessionId: String?
    /// Source agent name (focus target resolution).
    public var source: String?
    /// Answer payload for `.answerQuestion`.
    public var answer: String?
    public var status: RemoteCommandStatus
    public var createdAt: Date
    /// When a Mac claimed it (execution lock owner).
    public var consumedAt: Date?
    /// Which Mac consumed/executed this command.
    public var executor: String?
    /// Outcome: success note or error message.
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

    /// CloudKit record type name.
    public static let recordType = "RemoteCommand"
}
