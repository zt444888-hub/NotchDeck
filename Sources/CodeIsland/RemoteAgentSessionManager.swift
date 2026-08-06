import Foundation
import os
import CodeIslandCore

private let sessionLog = Logger(subsystem: "com.notchdeck.mac", category: "RemoteAgent")

/// Executes remote conversation turns with a headless CLI agent on the Mac.
///
/// Uses `claude -p <message> --resume <sessionId>` (multi-turn: the same
/// session id keeps context across messages) or `codex exec --session`.
/// Turns run on a serial queue — one agent task at a time.
final class RemoteAgentSessionManager {

    /// Called when a turn completes with the updated conversation.
    var onTurnFinished: ((RemoteConversation) -> Void)?

    private var queue: [RemoteConversation] = []
    private var isExecuting = false
    private let lock = NSLock()

    /// Convenience: enqueue + callback on finish.
    func enqueue(_ conversation: RemoteConversation,
                 completion: @escaping (RemoteConversation) -> Void) {
        lock.lock()
        queue.append(conversation)
        lock.unlock()
        pump()
        // NOTE: completion wiring is handled by callers via onTurnFinished in
        // the service; this signature exists for a clean swap to async/await.
    }

    private func pump() {
        lock.lock()
        guard !isExecuting, !queue.isEmpty else { lock.unlock(); return }
        let next = queue.removeFirst()
        isExecuting = true
        lock.unlock()

        Task {
            let result = await execute(next)
            lock.lock()
            isExecuting = false
            lock.unlock()
            onTurnFinished?(result)
            pump()
        }
    }

    /// Run one turn: send the latest user message to the agent, collect the
    /// reply, return the updated conversation.
    func execute(_ conversation: RemoteConversation) async -> RemoteConversation {
        guard let userMessage = conversation.messages.last(where: { $0.role == "user" }) else {
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "No user message to execute"
            return failed
        }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // Locate the agent binary (claude / codex) — resolved from PATH or
        // common install locations. macOS GUI apps have a minimal PATH, so we
        // build an explicit candidate list.
        guard let agentPath = Self.agentBinaryPath(for: conversation.tool) else {
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "Agent '\(conversation.tool)' not found in PATH"
            return failed
        }

        switch conversation.tool {
        case "claude":
            process.executableURL = URL(fileURLWithPath: agentPath)
            process.arguments = [
                "-p", userMessage.text,
                "--resume", conversation.sessionId,
                "--output-format", "stream-json",
                "--verbose",
            ]
        case "codex":
            process.executableURL = URL(fileURLWithPath: agentPath)
            process.arguments = ["exec", userMessage.text, "--session", conversation.sessionId]
        default:
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "Unsupported tool '\(conversation.tool)'"
            return failed
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        do {
            try process.run()
        } catch {
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "Failed to launch agent: \(error.localizedDescription)"
            return failed
        }

        // Collect stdout; stream-json emits one JSON event per line.
        let fileHandle = pipe.fileHandleForReading
        var output = ""
        let data = fileHandle.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8) ?? ""

        process.waitUntilExit()

        var updated = conversation
        updated.status = process.terminationStatus == 0 ? .done : .error
        if process.terminationStatus != 0 {
            updated.errorMessage = String(output.suffix(500))
        }
        // Extract the assistant text from stream-json lines (type:"assistant").
        let assistantText = Self.extractAssistantText(from: output)
        if !assistantText.isEmpty {
            updated.messages.append(RemoteConversationMessage(role: "assistant", text: assistantText))
        } else {
            updated.messages.append(RemoteConversationMessage(role: "assistant", text: String(output.suffix(2000))))
        }
        updated.updatedAt = Date()
        return updated
    }

    // MARK: - Helpers

    // MARK: - Agent detection & install guidance

    /// Supported agent tools.
    static let supportedTools = ["claude", "codex"]

    /// One agent's installation state, used by the settings readiness panel.
    struct AgentInstallation {
        let tool: String
        let path: String?
        let installCommand: String
        var isInstalled: Bool { path != nil }
    }

    /// Probe every supported agent and report installation state.
    static func detectAgents() -> [AgentInstallation] {
        supportedTools.map { tool in
            AgentInstallation(tool: tool,
                              path: agentBinaryPath(for: tool),
                              installCommand: installCommand(for: tool))
        }
    }

    /// Copy-paste install command for a tool that is missing.
    static func installCommand(for tool: String) -> String {
        switch tool {
        case "claude":
            return "npm install -g @anthropic-ai/claude-code"
        case "codex":
            return "npm install -g @openai/codex"
        default:
            return ""
        }
    }

    private static func agentBinaryPath(for tool: String) -> String? {
        let candidates: [String]
        switch tool {
        case "claude":
            candidates = ["claude"]
        case "codex":
            candidates = ["codex"]
        default:
            return nil
        }
        // Codex.app (and Codex++) install the CLI under ~/.codex; the plugin
        // appserver path is a real, current location on some setups.
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                           "/Users/\(NSUserName())/.local/bin",
                           "/Users/\(NSUserName())/.codex/bin",
                           "/Users/\(NSUserName())/.codex/plugins/.plugin-appserver",
                           "/Users/\(NSUserName())/.npm-global/bin",
                           "/Users/\(NSUserName())/.yarn/bin"]
        for name in candidates {
            if name.contains("/") && FileManager.default.isExecutableFile(atPath: name) {
                return name
            }
            for dir in searchPaths {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            // PATH fallback
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                for dir in path.split(separator: ":") {
                    let p = "\(dir)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: p) { return p }
                }
            }
        }
        return nil
    }

    /// Extract assistant text from `claude --output-format stream-json`.
    /// Each line is a JSON object; assistant messages carry type:"assistant".
    private static func extractAssistantText(from output: String) -> String {
        var text = ""
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? String {
                text += content
            }
        }
        return text
    }
}
