import Foundation
import Network
import os.log
import CodeIslandCore

/// MCP (Model Context Protocol) server — lets any MCP-capable tool
/// (TRAE Work, Cursor, Windsurf, Claude Desktop, OpenHands, ...) report agent
/// activity to the notch panel without a native hook mechanism.
///
/// Transport: MCP Streamable HTTP over localhost (JSON-RPC 2.0).
///   POST http://127.0.0.1:8765/mcp
///
/// Tools:
///   - notchdeck_report: report a lifecycle event (SessionStart / UserPromptSubmit /
///     PreToolUse / PostToolUse / Stop / Notification / SessionEnd)
///   - notchdeck_status: health check + version
///
/// Events are funneled into the exact same pipeline as socket events
/// (recordHookEvent + handleEvent), so the panel, permissions and diagnostics
/// all work identically. See docs/MCP-SERVER.md for the full design.
@MainActor
final class MCPServer {
    nonisolated private static let log = Logger(subsystem: "com.notchdeck.mac", category: "MCPServer")

    private weak var appState: AppState?
    private var listener: NWListener?
    private let port: UInt16
    private let workQueue = DispatchQueue(label: "com.notchdeck.mcp-work")

    nonisolated static let defaultPort: UInt16 = 8765

    /// Supported report event names (internal PascalCase namespace).
    private static let supportedEvents: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Stop", "Notification",
    ]

    // MARK: - Live state (read by settings page)

    @MainActor var eventCount: Int = 0

    // MARK: - Event deduplication

    /// When the same tool is configured with both native hooks and MCP, both
    /// paths report the same event. The hook event arrives first (sub-100ms),
    /// so we hold recent events here and drop MCP duplicates within the window.
    private struct DedupKey: Hashable {
        let source: String
        let sessionId: String
        let eventName: String
    }
    nonisolated(unsafe) private var dedupCache: [DedupKey: Date] = [:]
    nonisolated(unsafe) private var lastDedupPrune = Date.distantPast
    private static let dedupWindowSeconds: TimeInterval = 5.0
    private static let dedupPruneInterval: TimeInterval = 30.0

    init(appState: AppState, port: UInt16 = MCPServer.defaultPort) {
        self.appState = appState
        self.port = port
    }

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true // survive app restarts
        params.requiredInterfaceType = .loopback // 127.0.0.1 only — privacy
        let port = self.port
        let listener: NWListener
        do {
            guard let portNumber = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: params, on: portNumber)
        } catch {
            Self.log.error("MCPServer failed to listen on \(port): \(error.localizedDescription)")
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.log.info("MCP listening on 127.0.0.1:\(port)")
            case .failed(let err):
                Self.log.error("MCP listener failed: \(err.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: workQueue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dedupCache.removeAll()
        eventCount = 0
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: workQueue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var data = buffer
            if let content { data.append(content) }

            // We have the whole body once we've seen the header terminator and
            // buffered Content-Length worth of payload.
            if let expected = Self.httpBodyLength(data) {
                let headerLen = data.range(of: Data("\r\n\r\n".utf8))!.upperBound
                if data.count - headerLen >= expected {
                    self.processHTTPRequest(data, conn: conn)
                    return
                }
            } else if let error, error != .posix(.ECONNRESET) {
                // Connection died before a complete request — drop it.
                conn.cancel()
                return
            }

            if isComplete {
                // No Content-Length (unusual for MCP) — process what we have.
                self.processHTTPRequest(data, conn: conn)
            } else {
                self.receiveRequest(conn, buffer: data)
            }
        }
    }

    /// Parse Content-Length from an HTTP request head. Returns nil if the head
    /// is incomplete or the header is absent.
    private static func httpBodyLength(_ data: Data) -> Int? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) ?? ""
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length", let len = Int(parts[1]) {
                return len
            }
        }
        return nil
    }

    // MARK: - HTTP + JSON-RPC dispatch

    private func processHTTPRequest(_ data: Data, conn: NWConnection) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            sendHTTPResponse(conn, status: 400, body: Data(#"{"error":"bad_request"}"#.utf8))
            return
        }
        let body = data[headerEnd.upperBound...]
        let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        // Accept POST /mcp (any trailing path tolerated for flexibility).
        let isPost = head.hasPrefix("POST")
        guard isPost else {
            sendHTTPResponse(conn, status: 405, body: Data(#"{"error":"method_not_allowed"}"#.utf8))
            return
        }

        Task { @MainActor in
            let responseBody = self.handleJSONRPC(Data(body))
            self.sendHTTPResponse(conn, status: 200, body: responseBody)
        }
    }

    private func sendHTTPResponse(_ conn: NWConnection, status: Int, body: Data) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let head = "HTTP/1.1 \(status) \(statusText)\r\n" +
                   "Content-Type: application/json\r\n" +
                   "Access-Control-Allow-Origin: *\r\n" +
                   "Access-Control-Allow-Headers: Content-Type\r\n" +
                   "Content-Length: \(body.count)\r\n" +
                   "Connection: close\r\n\r\n"
        let response = Data(head.utf8) + body
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - JSON-RPC methods

    private func handleJSONRPC(_ body: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String,
              let id = json["id"] else {
            return Self.jsonRPCResponse(id: NSNull(), error: "invalid_request")
        }

        switch method {
        case "initialize":
            // Echo the client's requested protocol version when the handshake
            // carries one. Strict clients (TRAE Work, recent SDKs) disconnect if
            // the server unilaterally downgrades the version; our tool surface is
            // identical across 2024-11-05 / 2025-03-26 / 2025-06-18, so agreeing
            // to whatever the client speaks is always safe.
            let params = json["params"] as? [String: Any]
            let clientVersion = params?["protocolVersion"] as? String
            return Self.jsonRPCResponse(id: id, result: [
                "protocolVersion": clientVersion ?? "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "notchdeck", "version": Self.bundleVersion],
            ])
        case "notifications/initialized", "ping":
            // No response for notifications; ping gets an empty ack per JSON-RPC.
            if method == "ping" {
                return Self.jsonRPCResponse(id: id, result: [:])
            }
            return Data()
        case "tools/list":
            return Self.jsonRPCResponse(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            return handleToolsCall(id: id, params: json["params"] as? [String: Any] ?? [:])
        default:
            return Self.jsonRPCResponse(id: id, error: "method_not_found")
        }
    }

    private func handleToolsCall(id: Any, params: [String: Any]) -> Data {
        guard let name = params["name"] as? String else {
            return Self.jsonRPCResponse(id: id, error: "invalid_params")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "notchdeck_status":
            let text = "NotchDeck MCP server \(Self.bundleVersion) — listening on 127.0.0.1:\(port)"
            return Self.jsonRPCResponse(id: id, result: Self.toolResult(text: text))
        case "notchdeck_report":
            return handleReport(id: id, arguments: arguments)
        default:
            return Self.jsonRPCResponse(id: id, error: "tool_not_found")
        }
    }

    private func handleReport(id: Any, arguments: [String: Any]) -> Data {
        guard let event = arguments["event"] as? String,
              Self.supportedEvents.contains(event),
              let sessionId = arguments["session_id"] as? String, !sessionId.isEmpty else {
            return Self.jsonRPCResponse(id: id, error: "invalid_params",
                                        detail: "event (one of \(Self.supportedEvents.sorted().joined(separator: ","))) and non-empty session_id are required")
        }

        let source = (arguments["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "mcp"
        let cwd = arguments["cwd"] as? String
        let toolName = arguments["tool_name"] as? String
        let toolInput = arguments["tool_input"] as? [String: Any]
        let detail = arguments["detail"] as? String

        // Dedup: when the same AI tool sends events via both hooks and MCP,
        // the hook arrives first (sub-100ms). Drop the MCP duplicate for the
        // same (source, session_id, event_name) within the 5-second window.
        let dedupKey = DedupKey(source: source, sessionId: sessionId, eventName: event)
        pruneDedupCache()
        if let last = dedupCache[dedupKey], Date().timeIntervalSince(last) < Self.dedupWindowSeconds {
            Self.log.info("MCP dedup skip: \(event) session=\(sessionId) source=\(source)")
            return Self.jsonRPCResponse(id: id, result: Self.toolResult(text: "ok (deduped)"))
        }
        dedupCache[dedupKey] = Date()

        var raw: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionId,
            "_source": source,
            "_via_plugin": true,
        ]
        if let cwd, !cwd.isEmpty { raw["cwd"] = cwd }
        if let toolName, !toolName.isEmpty { raw["tool_name"] = toolName }
        if let toolInput { raw["tool_input"] = toolInput }
        if let detail, !detail.isEmpty { raw["prompt"] = detail }

        guard let eventData = try? JSONSerialization.data(withJSONObject: raw),
              let hookEvent = HookEvent(from: eventData) else {
            return Self.jsonRPCResponse(id: id, error: "internal_error")
        }

        appState?.recordHookEvent(
            source: source,
            sessionId: sessionId,
            eventName: event,
            toolName: toolName,
            viaPlugin: true,
            payloadKeys: raw.keys.filter { !$0.hasPrefix("_") }.sorted(),
            promptPreview: detail
        )
        appState?.handleEvent(hookEvent)

        eventCount += 1
        Self.log.info("MCP report: \(event) session=\(sessionId) source=\(source)")
        return Self.jsonRPCResponse(id: id, result: Self.toolResult(text: "ok"))
    }

    // MARK: - Dedup helpers

    private func pruneDedupCache() {
        let now = Date()
        guard now.timeIntervalSince(lastDedupPrune) >= Self.dedupPruneInterval else { return }
        lastDedupPrune = now
        dedupCache = dedupCache.filter { now.timeIntervalSince($0.value) < Self.dedupWindowSeconds }
    }

    // MARK: - JSON-RPC helpers

    private static var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "notchdeck_report",
                "description": "Report an AI agent lifecycle event to the NotchDeck dynamic-island panel. Call it at session start, before/after each tool use, and when the agent finishes a turn.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "event": [
                            "type": "string",
                            "enum": Array(supportedEvents).sorted(),
                            "description": "Lifecycle event name",
                        ],
                        "session_id": ["type": "string", "description": "Stable id for the current agent session/conversation"],
                        "source": ["type": "string", "description": "Tool name used for the panel badge (default: mcp)"],
                        "cwd": ["type": "string", "description": "Working directory of the session"],
                        "tool_name": ["type": "string", "description": "Tool being invoked (PreToolUse/PostToolUse)"],
                        "tool_input": ["type": "object", "description": "Tool arguments (PreToolUse/PostToolUse)"],
                        "detail": ["type": "string", "description": "Free-form detail (prompt text, command, summary)"],
                    ],
                    "required": ["event", "session_id"],
                ],
            ],
            [
                "name": "notchdeck_status",
                "description": "Health check — returns the NotchDeck version. Use once to confirm the server is reachable.",
                "inputSchema": ["type": "object", "properties": [:], "required": []],
            ],
        ]
    }

    private static func toolResult(text: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ]
    }

    private static func jsonRPCResponse(id: Any, result: [String: Any]? = nil, error: String? = nil, detail: String? = nil) -> Data {
        var json: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result {
            json["result"] = result
        } else if let error {
            var err: [String: Any] = ["code": -32601, "message": error]
            if let detail { err["data"] = detail }
            json["error"] = err
        }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"serialize_failed"}}"#.utf8)
        return data
    }

    private static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }
}
