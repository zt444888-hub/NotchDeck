import Foundation
import os
import CodeIslandCore

private let sessionLog = Logger(subsystem: "com.notchdeck.mac", category: "RemoteAgent")

/// One agent CLI adapter: how to drive this tool headlessly.
///
/// NotchDeck drives whatever AI CLI is installed on the Mac — Claude Code,
/// Codex, OpenCode, Gemini CLI, ... — through a small registry. Each adapter
/// knows how to build the process arguments and how to extract the assistant
/// reply from stdout. The `demo` adapter is a local, credential-free
/// stand-in used to validate the end-to-end chain before a real agent is
/// configured.
struct RemoteAgentAdapter {
    let tool: String            // stable id stored in CloudKit ("claude" | "demo" | ...)
    let binaryName: String?     // CLI name to probe on disk; nil for demo
    let displayName: String
    let installCommand: String
    let isDemo: Bool

    /// Process arguments for one headless turn.
    ///
    /// NOTE: session-resume flags (--resume / --session) are deliberately
    /// omitted. The sessionId stored in CloudKit is the iPhone conversation
    /// UUID, which is NOT a Claude/Codex session ID — those CLIs validate
    /// the resume ID strictly and exit immediately with an error for unknown
    /// IDs. Each turn starts a fresh agent session instead; conversation
    /// continuity is tracked by CloudKit, not by the CLI.
    func arguments(message: String, sessionId: String) -> [String] {
        switch tool {
        case "claude":
            return ["-p", message, "--output-format", "stream-json", "--verbose"]
        case "codex":
            return ["exec", message]
        case "opencode":
            return ["run", message]
        case "gemini":
            return ["-p", message]
        default:
            return []
        }
    }

    /// Extract the assistant reply from the process stdout.
    func extractReply(from output: String) -> String? {
        switch tool {
        case "claude":
            return Self.extractClaudeReply(from: output)
        default:
            // codex / opencode / gemini print plain-text replies on stdout.
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// `claude --output-format stream-json` emits one JSON event per line;
    /// assistant messages carry type:"assistant".
    private static func extractClaudeReply(from output: String) -> String? {
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Executes remote conversation turns with a headless CLI agent on the Mac.
///
/// Turns run on a serial queue — one agent task at a time. The conversation's
/// `tool` selects the adapter; `"auto"` picks the first installed agent
/// (falling back to the built-in `demo` when none is configured), so an
/// iPhone user never needs to know what the Mac has installed.
final class RemoteAgentSessionManager {

    /// Called when a turn completes with the updated conversation.
    var onTurnFinished: ((RemoteConversation) -> Void)?

    private var queue: [RemoteConversation] = []
    private var isExecuting = false
    private let lock = NSLock()

    // MARK: - Adapter registry

    static let adapters: [RemoteAgentAdapter] = [
        RemoteAgentAdapter(tool: "claude", binaryName: "claude", displayName: "Claude Code",
                           installCommand: "npm install -g @anthropic-ai/claude-code", isDemo: false),
        RemoteAgentAdapter(tool: "codex", binaryName: "codex", displayName: "Codex",
                           installCommand: "npm install -g @openai/codex", isDemo: false),
        RemoteAgentAdapter(tool: "opencode", binaryName: "opencode", displayName: "OpenCode",
                           installCommand: "npm install -g opencode-ai", isDemo: false),
        RemoteAgentAdapter(tool: "gemini", binaryName: "gemini", displayName: "Gemini CLI",
                           installCommand: "npm install -g @google/gemini-cli", isDemo: false),
        RemoteAgentAdapter(tool: "demo", binaryName: nil, displayName: "Demo (local)",
                           installCommand: "", isDemo: true),
    ]

    static func adapter(for tool: String) -> RemoteAgentAdapter? {
        adapters.first { $0.tool == tool }
    }

    /// Non-demo adapters only — shown in the settings readiness panel.
    static func realAdapters() -> [RemoteAgentAdapter] {
        adapters.filter { !$0.isDemo }
    }

    /// Resolve "auto": first installed real agent; `demo` if none at all.
    static func preferredTool() -> String {
        for adapter in realAdapters() {
            if let binary = adapter.binaryName, agentBinaryPath(for: binary) != nil {
                return adapter.tool
            }
        }
        return "demo"
    }

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

        // Detached so the agent process (which may block for up to the
        // timeout) never stalls the MainActor the queue callers run on.
        Task.detached { [self] in
            let result = await self.execute(next)
            // NSLock is unavailable from async contexts under Swift 6
            // checks, so route the post-execution state change through a
            // synchronous helper on the main actor.
            await MainActor.run {
                self.finishTurn(result)
            }
        }
    }

    /// Synchronous post-execution bookkeeping: flip the running flag under
    /// the lock, notify, and kick the next queued turn.
    private func finishTurn(_ result: RemoteConversation) {
        lock.lock()
        isExecuting = false
        lock.unlock()
        onTurnFinished?(result)
        pump()
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

        let tool = conversation.tool == "auto" ? Self.preferredTool() : conversation.tool
        guard let adapter = Self.adapter(for: tool) else {
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "Unsupported tool '\(tool)'"
            return failed
        }

        // Demo adapter: local simulated reply — validates the whole chain
        // (iPhone → CloudKit → Mac → reply) with zero credentials.
        if adapter.isDemo {
            var updated = conversation
            updated.status = .done
            let reply = """
            [Demo] Mac 收到: "\(userMessage.text)"

            这是本地模拟回复——端到端链路验证通过(手机 → CloudKit → Mac → 回传)。
            未连接真实 AI;安装 Claude Code / Codex / OpenCode / Gemini 任一 CLI 后,auto 会自动切换。
            \(Date())
            """
            updated.messages.append(RemoteConversationMessage(role: "assistant", text: reply))
            updated.updatedAt = Date()
            return updated
        }

        // Locate the agent binary — resolved from PATH or common install
        // locations. macOS GUI apps have a minimal PATH, so we build an
        // explicit candidate list.
        guard let binaryName = adapter.binaryName,
              let agentPath = Self.agentBinaryPath(for: binaryName) else {
            var failed = conversation
            failed.status = .error
            failed.errorMessage = "Agent '\(tool)' not found in PATH"
            return failed
        }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = adapter.arguments(message: userMessage.text, sessionId: conversation.sessionId)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        do {
            try process.run()
        } catch {
            return Self.demoFallback(conversation: conversation, tool: tool,
                                     userMessage: userMessage,
                                     reason: "Failed to launch agent: \(error.localizedDescription)")
        }

        // Hard timeout: a hung agent (e.g. claude waiting for OAuth login)
        // must never wedge the serial queue forever.
        let timeout: TimeInterval = 45
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return Self.demoFallback(conversation: conversation, tool: tool,
                                     userMessage: userMessage,
                                     reason: "timed out after \(Int(timeout))s (not logged in?)")
        }

        // Process exited — collect output and finalize.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        process.waitUntilExit()

        // Real agent failed (not logged in, missing key, bad args, ...):
        // fall back to the local demo reply so the end-to-end chain stays
        // verifiable, while surfacing the real error to the user.
        guard process.terminationStatus == 0,
              let reply = adapter.extractReply(from: output), !reply.isEmpty else {
            let reason = String(output.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.demoFallback(conversation: conversation, tool: tool,
                                     userMessage: userMessage,
                                     reason: reason.isEmpty ? "exit code \(process.terminationStatus)" : reason)
        }

        var updated = conversation
        updated.status = .done
        updated.messages.append(RemoteConversationMessage(role: "assistant", text: reply))
        updated.updatedAt = Date()
        return updated
    }

    /// Build a local demo reply when the real agent is unavailable, keeping
    /// the chain verifiable and the failure reason visible.
    private static func demoFallback(conversation: RemoteConversation, tool: String,
                                     userMessage: RemoteConversationMessage,
                                     reason: String) -> RemoteConversation {
        var fallback = conversation
        fallback.status = .done
        fallback.errorMessage = "Agent '\(tool)' unavailable: \(reason)"
        let reply = """
        [Demo] Mac 收到: "\(userMessage.text)"

        真实 Agent '\(tool)' 暂不可用（\(reason)），已回退到本地 Demo 回复——端到端链路验证通过（手机 → CloudKit → Mac → 回传）。
        安装并登录对应 CLI 后 auto 会自动切换。
        \(Date())
        """
        fallback.messages.append(RemoteConversationMessage(role: "assistant", text: reply))
        fallback.updatedAt = Date()
        return fallback
    }

    // MARK: - Agent detection & install guidance

    /// One agent's installation state, used by the settings readiness panel.
    struct AgentInstallation {
        let tool: String
        let path: String?
        let installCommand: String
        var isInstalled: Bool { path != nil }
    }

    /// Probe every real (non-demo) agent and report installation state.
    static func detectAgents() -> [AgentInstallation] {
        realAdapters().map { adapter in
            AgentInstallation(tool: adapter.tool,
                              path: adapter.binaryName.flatMap { agentBinaryPath(for: $0) },
                              installCommand: adapter.installCommand)
        }
    }

    private static func agentBinaryPath(for binary: String) -> String? {
        // Codex.app (and Codex++) install the CLI under ~/.codex; the plugin
        // appserver path is a real, current location on some setups.
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                           "/Users/\(NSUserName())/.local/bin",
                           "/Users/\(NSUserName())/.codex/bin",
                           "/Users/\(NSUserName())/.codex/plugins/.plugin-appserver",
                           "/Users/\(NSUserName())/.npm-global/bin",
                           "/Users/\(NSUserName())/.yarn/bin"]
        if binary.contains("/") && FileManager.default.isExecutableFile(atPath: binary) {
            return binary
        }
        for dir in searchPaths {
            let p = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // PATH fallback
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = "\(dir)/\(binary)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }
}
