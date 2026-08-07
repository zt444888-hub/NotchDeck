import Foundation
import os
import Darwin
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
    let timeout: TimeInterval   // per-agent hard timeout for one headless turn

    /// Process arguments for one headless turn.
    ///
    /// NOTE: session-resume flags (--resume / --session) are deliberately
    /// scoped. The sessionId stored in CloudKit is the iPhone conversation
    /// UUID, which is NOT a Claude/Codex session ID — those CLIs validate
    /// the resume ID strictly and exit immediately with an error for unknown
    /// IDs. Codex turns resume either the REAL imported task this
    /// conversation maps to, or the codex session this conversation owns
    /// (per-conversation binding, see RemoteAgentSessionManager); everything
    /// else starts fresh. Conversation continuity is tracked by CloudKit,
    /// not by the CLI.
    func arguments(message: String, sessionId: String, conversationId: String) -> [String] {
        switch tool {
        case "claude":
            return ["-p", message, "--output-format", "stream-json", "--verbose"]
        case "codex":
            // --skip-git-repo-check: the app's cwd isn't a git repo and
            // codex would refuse to run without it.
            var args = ["exec", "--skip-git-repo-check"]
            if let sid = Self.codexResumeSessionId(sessionId: sessionId, conversationId: conversationId) {
                args += ["--session", sid]
            }
            args.append(message)
            return args
        case "opencode":
            return ["run", message]
        case "gemini":
            return ["-p", message]
        default:
            return []
        }
    }

    /// Decide which codex session to resume for this turn, if any:
    /// 1. The conversation maps to a real imported codex task → resume it.
    /// 2. The conversation owns a codex session (created on its first turn)
    ///    → resume it for continuity.
    /// Otherwise nil → fresh exec (new session, bound on success).
    private static func codexResumeSessionId(sessionId: String, conversationId: String) -> String? {
        if CodexSessionImporter.isCodexSessionId(sessionId) { return sessionId }
        return RemoteAgentSessionManager.boundCodexSession(for: conversationId)
    }

    /// Extract the assistant reply from the process stdout.
    func extractReply(from output: String) -> String? {
        switch tool {
        case "claude":
            return Self.extractClaudeReply(from: output)
        case "codex":
            return Self.extractCodexReply(from: output)
        default:
            // opencode / gemini print plain-text replies on stdout.
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// `codex exec` prints a banner, then the turn transcript, then a
    /// "tokens used" footer. The assistant reply is the text after the last
    /// "codex" marker and before "tokens used".
    private static func extractCodexReply(from output: String) -> String? {
        var reply: String
        if let marker = output.range(of: "\ncodex\n", options: .backwards) ?? output.range(of: "codex\n", options: .backwards) {
            reply = String(output[marker.upperBound...])
        } else {
            reply = output
        }
        if let tokens = reply.range(of: "\ntokens used") {
            reply = String(reply[..<tokens.lowerBound])
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
                           installCommand: "npm install -g @anthropic-ai/claude-code", isDemo: false,
                           timeout: 20),
        RemoteAgentAdapter(tool: "codex", binaryName: "codex", displayName: "Codex",
                           installCommand: "npm install -g @openai/codex", isDemo: false,
                           timeout: 60),
        RemoteAgentAdapter(tool: "opencode", binaryName: "opencode", displayName: "OpenCode",
                           installCommand: "npm install -g opencode-ai", isDemo: false,
                           timeout: 60),
        RemoteAgentAdapter(tool: "gemini", binaryName: "gemini", displayName: "Gemini CLI",
                           installCommand: "npm install -g @google/gemini-cli", isDemo: false,
                           timeout: 30),
        RemoteAgentAdapter(tool: "demo", binaryName: nil, displayName: "Demo (local)",
                           installCommand: "", isDemo: true,
                           timeout: 5),
    ]

    static func adapter(for tool: String) -> RemoteAgentAdapter? {
        adapters.first { $0.tool == tool }
    }

    // MARK: - Per-conversation codex session binding
    //
    // Each iPhone conversation owns ONE codex session, created on its first
    // turn and resumed on later turns. This isolates contexts: two phone
    // conversations never share a codex task, so one can't pollute the
    // other's context. (Replaces the old single global RemoteConv.codexSessionId.)

    private static let codexSessionIdsKey = "RemoteConv.codexSessionIds"

    /// The codex session owned by this conversation, if any.
    static func boundCodexSession(for conversationId: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: codexSessionIdsKey) as? [String: String]
        return map?[conversationId]
    }

    /// Bind a codex session to this conversation (idempotent; called on every
    /// successful codex turn so resume failures that fall back to fresh exec
    /// automatically rebind to the new session).
    static func bindCodexSession(_ sessionId: String, to conversationId: String) {
        var map = UserDefaults.standard.dictionary(forKey: codexSessionIdsKey) as? [String: String] ?? [:]
        map[conversationId] = sessionId
        UserDefaults.standard.set(map, forKey: codexSessionIdsKey)
    }

    /// Remove the legacy single-session key; superseded by the mapping above.
    static func migrateLegacyCodexSession() {
        UserDefaults.standard.removeObject(forKey: "RemoteConv.codexSessionId")
    }

    /// Non-demo adapters only — shown in the settings readiness panel.
    static func realAdapters() -> [RemoteAgentAdapter] {
        adapters.filter { !$0.isDemo }
    }

    /// Resolve "auto": first installed AND usable real agent; `demo` if
    /// none. Usable means credentials are present — an installed-but-not-
    /// logged-in CLI (claude without /login) would otherwise be picked,
    /// fail, and force a demo fallback with a scary error on every turn.
    static func preferredTool() -> String {
        for adapter in realAdapters() {
            if let binary = adapter.binaryName,
               agentBinaryPath(for: binary) != nil,
               agentIsUsable(adapter.tool) {
                return adapter.tool
            }
        }
        return "demo"
    }

    /// Cheap credential check per agent, so auto skips CLIs that are
    /// installed but not authenticated. (A real login always wins — once
    /// `claude /login` completes, auto switches to claude automatically.)
    private static func agentIsUsable(_ tool: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        switch tool {
        case "claude":
            if env["ANTHROPIC_API_KEY"] != nil { return true }
            // `claude /login` writes oauthAccount into ~/.claude.json.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["oauthAccount"] != nil { return true }
            return FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json")
        case "codex":
            if env["OPENAI_API_KEY"] != nil { return true }
            guard FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json") else { return false }
            // Codex is often routed through a LOCAL proxy (cc-switch etc.,
            // base_url = http://127.0.0.1:PORT). auth.json existing doesn't
            // mean the proxy is up — verify the port is actually listening,
            // else every turn hangs 20s then falls back with a scary error.
            return Self.codexProxyReachable()
        default:
            // opencode / gemini: binary presence is the cheapest signal we
            // have; their auth is configured via the CLI itself.
            return true
        }
    }

    /// Parse codex config.toml's base_url; if it points at localhost,
    /// require the TCP port to actually be open.
    private static func codexProxyReachable() -> Bool {
        let configPath = "\(NSHomeDirectory())/.codex/config.toml"
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8),
              let line = config.split(separator: "\n").first(where: { $0.contains("base_url") }) else {
            return true // no local proxy config → trust auth.json
        }
        guard let urlStart = line.range(of: "\""),
              let urlEnd = line[urlStart.upperBound...].range(of: "\"") else { return true }
        let url = String(line[urlStart.upperBound..<urlEnd.lowerBound])
        guard url.contains("127.0.0.1") || url.contains("localhost") else { return true }
        // url = http://127.0.0.1:15721/v1 → port 15721
        let comps = url.split(separator: ":")
        guard comps.count >= 3,
              let port = Int(comps[2].split(separator: "/").first ?? "") else { return false }
        return Self.tcpPortOpen(host: "127.0.0.1", port: port)
    }

    /// 1s-timeout TCP connect probe (blocking; only used at agent selection).
    private static func tcpPortOpen(host: String, port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
        addr.sin_addr.s_addr = inet_addr(host)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var to = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &to, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok
    }

    /// Convenience: enqueue + callback on finish.
    func enqueue(_ conversation: RemoteConversation,
                 completion: @escaping (RemoteConversation) -> Void) {
        lock.lock()
        // Deduplicate: poll() re-enqueues every pending conversation every 5s;
        // without this the queue balloons while a turn is executing.
        if queue.contains(where: { $0.id == conversation.id }) {
            lock.unlock()
            return
        }
        queue.append(conversation)
        lock.unlock()
        pump()
        // NOTE: completion wiring is handled by callers via onTurnFinished in
        // the service; this signature exists for a clean swap to async/await.
    }

    /// Append a line to the shared /tmp diag log (os_log is unreadable in
    /// the dev sandbox, so CloudKit/agent failures are persisted to a file).
    private static func diag(_ msg: String) {
        // Opt-in, same key as the service: Settings → Remote AI → 诊断日志.
        guard UserDefaults.standard.bool(forKey: SettingsKey.remoteDiagEnabled) else { return }
        let path = "/tmp/notchdeck-remote-diag.log"
        let line = "\(Date()) \(msg)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
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

        var tool = conversation.tool == "auto" ? Self.preferredTool() : conversation.tool
        // Legacy conversations (created before "auto" existed) carry an
        // explicit tool — "claude" was the default then, and it's not
        // logged in on most Macs. If the requested CLI is missing or not
        // authenticated, degrade gracefully to auto instead of failing the
        // turn; the user's intent is "use the Mac's agent", not "claude or
        // nothing".
        if tool != "auto", let requested = Self.adapter(for: tool), !requested.isDemo {
            let binaryOk = requested.binaryName.map { Self.agentBinaryPath(for: $0) != nil } ?? true
            if !binaryOk || !Self.agentIsUsable(tool) {
                Self.diag("execute: requested tool '\(tool)' unavailable, degrading to auto")
                tool = Self.preferredTool()
            }
        }
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
            updated.errorMessage = nil
            let reply = """
            [Demo] Mac 收到: "\(userMessage.text)"

            这是本地模拟回复——端到端链路验证通过(手机 → CloudKit → Mac → 回传)。
            未连接真实 AI;安装并登录 Claude Code / Codex / OpenCode / Gemini 任一 CLI 后,auto 会自动切换。
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

        // Codex: resume the mapped REAL task first (full context from the
        // original Mac-side session). DeepSeek rejects some tool schemas on
        // old Codex Desktop sessions, so on failure fall back to a fresh
        // exec instead of erroring out.
        if tool == "codex", CodexSessionImporter.isCodexSessionId(conversation.sessionId) {
            let resumeArgs = ["exec", "resume", conversation.sessionId,
                              userMessage.text, "--skip-git-repo-check"]
            let (resumed, _) = await runAgentProcess(agentPath: agentPath, args: resumeArgs,
                                                     tool: tool, conversation: conversation,
                                                     userMessage: userMessage)
            if let resumed { return resumed }
            Self.diag("execute: codex resume failed → plain exec fallback")
        }

        // Normal path (adapter args; codex = fresh exec, claude = -p, ...).
        // If this conversation maps to a real codex session whose resume
        // just failed above, never retry the same dead session — the adapter
        // args would happily re-add `--session` and fail identically. Force a
        // truly fresh exec instead.
        var args = adapter.arguments(message: userMessage.text,
                                     sessionId: conversation.sessionId,
                                     conversationId: conversation.id)
        if tool == "codex", CodexSessionImporter.isCodexSessionId(conversation.sessionId) {
            args = ["exec", "--skip-git-repo-check", userMessage.text]
        }
        let (result, reason) = await runAgentProcess(
            agentPath: agentPath, args: args,
            tool: tool, conversation: conversation, userMessage: userMessage)
        if let result { return result }
        return Self.demoFallback(conversation: conversation, tool: tool,
                                 userMessage: userMessage,
                                 reason: reason.isEmpty ? "agent failed (not logged in?)" : reason)
    }

    /// Run the agent binary headless and collect the reply.
    /// Returns (nil, errorText) on failure so callers can fall back.
    private func runAgentProcess(agentPath: String,
                                 args: [String],
                                 tool: String,
                                 conversation: RemoteConversation,
                                 userMessage: RemoteConversationMessage) async -> (RemoteConversation?, String) {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        Self.diag("execute: tool=\(tool), path=\(agentPath), args=\(args.joined(separator: " "))")

        do {
            try process.run()
        } catch {
            Self.diag("execute: process.run FAILED: \(error.localizedDescription)")
            return (nil, error.localizedDescription)
        }
        Self.diag("execute: process started pid=\(process.processIdentifier)")

        // Hard timeout: a hung agent (e.g. claude waiting for OAuth login)
        // must never wedge the serial queue forever. Per-adapter default
        // (codex 60s for slow provider turns; claude 20s; ...) so complex
        // tasks aren't killed mid-flight.
        let timeout: TimeInterval = Self.adapter(for: tool)?.timeout ?? 20
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        if process.isRunning {
            Self.diag("execute: TIMEOUT after \(Int(timeout))s, terminating")
            process.terminate()
            // SIGTERM may be ignored (GUI-launched CLIs often are); escalate
            // to SIGKILL after a short grace period, else waitUntilExit()
            // blocks forever.
            let killDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                Self.diag("execute: SIGTERM ignored, SIGKILL")
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return (nil, "timed out after \(Int(timeout))s")
        }
        Self.diag("execute: process exited status=\(process.terminationStatus)")

        // Process exited — collect output and finalize.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let adapter = Self.adapter(for: tool),
              let reply = adapter.extractReply(from: output), !reply.isEmpty else {
            let reason = String(output.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            Self.diag("execute: nonzero exit → fail (status=\(process.terminationStatus))")
            return (nil, reason.isEmpty ? "exit code \(process.terminationStatus)" : reason)
        }

        // Success: bind the codex session (printed on every exec) to THIS
        // conversation so later turns resume it. Only bind on success — a
        // failed exec must never claim a session id.
        if tool == "codex", let range = output.range(of: "session id: ") {
            let sid = String(output[range.upperBound...].prefix { !$0.isNewline })
            if !sid.isEmpty {
                Self.bindCodexSession(sid, to: conversation.id)
                Self.diag("execute: bound codex session \(sid) → conversation \(conversation.id)")
            }
        }

        var updated = conversation
        updated.status = .done
        updated.errorMessage = nil
        updated.messages.append(RemoteConversationMessage(role: "assistant", text: reply))
        updated.updatedAt = Date()
        Self.diag("execute: done, reply=\(reply.prefix(60))")
        return (updated, "")
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

    // MARK: - Readiness detail (settings panel)

    enum AgentReadiness: Equatable {
        case notApplicable      // demo adapter
        case notInstalled       // binary missing
        case needsLogin         // installed but not authenticated
        case proxyDown          // codex: auth ok but local proxy not listening
        case ready
    }

    /// Granular readiness for the settings panel, so it can distinguish
    /// "not installed" from "installed but not logged in" / "proxy down".
    static func agentReadiness(_ tool: String) -> AgentReadiness {
        guard let adapter = adapter(for: tool), !adapter.isDemo,
              let binary = adapter.binaryName else { return .notApplicable }
        guard agentBinaryPath(for: binary) != nil else { return .notInstalled }
        switch tool {
        case "codex":
            guard FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.codex/auth.json") else {
                return .needsLogin
            }
            return Self.codexProxyReachable() ? .ready : .proxyDown
        default:
            return Self.agentIsUsable(tool) ? .ready : .needsLogin
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
