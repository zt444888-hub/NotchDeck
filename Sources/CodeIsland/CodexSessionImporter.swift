import Foundation
import CloudKit
import CodeIslandCore

/// Scans the Mac's LOCAL codex sessions (~/.codex/sessions/**/rollout-*.jsonl)
/// and mirrors them into CloudKit as RemoteConversation records, so the
/// iPhone companion sees the Mac's existing codex tasks and can drive them
/// (send a message → Mac resumes that codex session via `exec --session`).
enum CodexSessionImporter {

    static let validSessionsKey = "RemoteConv.validCodexSessions"
    static let deletedSessionsKey = "RemoteConv.deletedImportedSessions"

    private static let maxSessions = 50
    private static let maxMessagesPerSession = 20
    private static let titleLength = 40

    // MARK: - Public

    /// True when this session id maps to a real, importable codex session.
    static func isCodexSessionId(_ sessionId: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: validSessionsKey)?
            .contains(sessionId) ?? false
    }

    /// Record that the user deleted this imported codex task on the phone.
    /// Without this, the next syncImportedSessions() would resurrect it
    /// (the local rollout file still exists), making the delete feel broken.
    static func markDeleted(_ sessionId: String) {
        var deleted = Set(UserDefaults.standard.stringArray(forKey: deletedSessionsKey) ?? [])
        deleted.insert(sessionId)
        UserDefaults.standard.set(Array(deleted), forKey: deletedSessionsKey)
    }

    /// Scan local codex sessions and upsert their RemoteConversation records
    /// into the private database. Idempotent (same recordName → update).
    /// Sessions the user deleted from the phone are skipped (blacklist).
    static func syncImportedSessions(db: CKDatabase) async {
        let sessions = scanSessions()
        guard !sessions.isEmpty else { return }
        let deleted = Set(UserDefaults.standard.stringArray(forKey: deletedSessionsKey) ?? [])
        var valid = Set(UserDefaults.standard.stringArray(forKey: validSessionsKey) ?? [])
        for session in sessions where !deleted.contains(session.sessionId) {
            valid.insert(session.sessionId)
            let record = makeRecord(from: session)
            do {
                try await db.modifyRecords(saving: [record],
                                           deleting: [],
                                           savePolicy: .changedKeys)
            } catch {
                // Record never created before → plain insert.
                _ = try? await db.save(record)
            }
        }
        UserDefaults.standard.set(Array(valid), forKey: validSessionsKey)
    }

    // MARK: - Scanning

    private struct CodexSession {
        let sessionId: String
        let title: String
        let messages: [RemoteConversationMessage]
        let updatedAt: Date
    }

    private static func scanSessions() -> [CodexSession] {
        let root = NSHomeDirectory() + "/.codex/sessions"
        guard FileManager.default.fileExists(atPath: root),
              let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }

        var files: [(Date, String)] = []
        for case let path as String in enumerator where path.hasSuffix(".jsonl") {
            let full = root + "/" + path
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            files.append((mtime, full))
        }
        files.sort { $0.0 > $1.0 }
        return files.prefix(maxSessions).compactMap { parseSession(file: $0.1) }
    }

    /// Parse one rollout-*.jsonl into a conversation (session_meta +
    /// user inputs + agent messages).
    private static func parseSession(file path: String) -> CodexSession? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        var sessionId: String?
        var userTexts: [String] = []
        var agentTexts: [String] = []
        var lastTimestamp = Date.distantPast
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        handle.seekToEndOfFile()
        let size = handle.offsetInFile
        handle.seek(toFileOffset: 0)
        // jsonl files are small (tens of KB); read whole file for simplicity.
        guard size < 5_000_000 else { return nil } // safety cap
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if type == "session_meta", let payload = obj["payload"] as? [String: Any] {
                sessionId = payload["session_id"] as? String
                if let ts = payload["timestamp"] as? String, let date = iso.date(from: ts) {
                    lastTimestamp = date
                }
            } else if type == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["role"] as? String == "user",
                      let content = payload["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "input_text" {
                    if let text = block["text"] as? String,
                       let cleaned = cleanUserText(text), !cleaned.isEmpty {
                        userTexts.append(cleaned)
                    }
                }
            } else if type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "agent_message",
                      let message = payload["message"] as? String {
                agentTexts.append(message)
            }
        }

        guard let sessionId, !sessionId.isEmpty else { return nil }

        // Interleave user/agent chronologically (jsonl is already ordered).
        var messages: [RemoteConversationMessage] = []
        var uIdx = 0, aIdx = 0
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if type == "response_item",
               let payload = obj["payload"] as? [String: Any],
               payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "input_text" {
                    if let t = block["text"] as? String, let cleaned = cleanUserText(t), uIdx < userTexts.count {
                        messages.append(RemoteConversationMessage(role: "user", text: userTexts[uIdx]))
                        uIdx += 1
                    }
                }
            } else if type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "agent_message" {
                messages.append(RemoteConversationMessage(role: "assistant", text: agentTexts[aIdx]))
                aIdx += 1
            }
            if messages.count >= maxMessagesPerSession * 2 { break }
        }
        // Keep the TAIL (most recent context) for driving the session.
        if messages.count > maxMessagesPerSession {
            messages = Array(messages.suffix(maxMessagesPerSession))
        }

        let title = String((userTexts.first ?? "Codex task").prefix(titleLength))
        return CodexSession(sessionId: sessionId, title: title, messages: messages, updatedAt: lastTimestamp)
    }

    /// Strip system-injected wrappers (<environment_context>, <permissions
    /// instructions>, etc.) from user input lines.
    private static func cleanUserText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<environment_context>") || trimmed.hasPrefix("<permissions") {
            return nil
        }
        return trimmed
    }

    // MARK: - Record mapping

    private static func makeRecord(from session: CodexSession) -> CKRecord {
        let record = CKRecord(recordType: RemoteConversation.recordType,
                              recordID: CKRecord.ID(recordName: session.sessionId,
                                                    zoneID: RemoteConversationService.recordZoneID))
        record["sessionId"] = session.sessionId as CKRecordValue
        record["tool"] = "codex" as CKRecordValue
        record["title"] = session.title as CKRecordValue
        record["messages"] = (try? JSONEncoder().encode(session.messages)) as CKRecordValue?
        record["status"] = RemoteConversationStatus.done.rawValue as CKRecordValue
        record["updatedAt"] = session.updatedAt as CKRecordValue
        return record
    }
}
