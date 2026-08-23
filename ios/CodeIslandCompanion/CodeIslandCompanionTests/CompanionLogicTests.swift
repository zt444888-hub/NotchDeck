import XCTest
@testable import CodeIslandCompanion

/// Unit tests for the companion app's pure logic layer — model (de)serialization
/// and display-text mapping. These run without a host UI and without network, so
/// they're fast, deterministic, and CI-friendly. They deliberately avoid asserting
/// `L10n`-localized strings (which depend on the test runner's locale).
final class CompanionLogicTests: XCTestCase {

    // MARK: - CompanionStatus

    func testStatusRawValueRoundTrip() {
        for status in [
            CompanionStatus.idle, .processing, .running,
            .waitingApproval, .waitingQuestion,
        ] {
            let data = Data("\"\(status.rawValue)\"".utf8)
            let decoded = try? JSONDecoder().decode(CompanionStatus.self, from: data)
            XCTAssertEqual(decoded, status, "round-trip failed for \(status.rawValue)")
        }
    }

    /// A newer Mac app may ship status values this build has never heard of.
    /// Tolerant decoding must fall back to .idle instead of throwing (#246).
    func testStatusUnknownStringFallsBackToIdle() {
        let data = Data(#""someFutureStatus""#.utf8)
        let decoded = try? JSONDecoder().decode(CompanionStatus.self, from: data)
        XCTAssertEqual(decoded, .idle)
    }

    /// Display priority matches the Mac notch: approval > question > running > processing > idle.
    func testStatusPriorityOrdering() {
        XCTAssertGreaterThan(CompanionStatus.waitingApproval.priority, CompanionStatus.waitingQuestion.priority)
        XCTAssertGreaterThan(CompanionStatus.waitingQuestion.priority, CompanionStatus.running.priority)
        XCTAssertGreaterThan(CompanionStatus.running.priority, CompanionStatus.processing.priority)
        XCTAssertGreaterThan(CompanionStatus.processing.priority, CompanionStatus.idle.priority)
    }

    // MARK: - CompanionMessageRole

    func testMessageRoleUnknownFallsBackToAssistant() {
        let data = Data(#""unknownRole""#.utf8)
        let decoded = try? JSONDecoder().decode(CompanionMessageRole.self, from: data)
        XCTAssertEqual(decoded, .assistant)
    }

    // MARK: - CompanionQuestionPayload (tolerant decode #246)

    func testQuestionPayloadRequiresOnlyQuestion() throws {
        let json = #"{"question":"Continue?"}"#
        let payload = try JSONDecoder().decode(CompanionQuestionPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.question, "Continue?")
        XCTAssertNil(payload.header)
        XCTAssertEqual(payload.options, [])
        XCTAssertEqual(payload.descriptions, [])
        XCTAssertEqual(payload.index, 0)
        XCTAssertEqual(payload.total, 1)
        XCTAssertFalse(payload.allowsMultipleSelection)
    }

    func testQuestionPayloadClampsBadIndexAndTotal() throws {
        let json = #"{"question":"Q","index":-5,"total":0}"#
        let payload = try JSONDecoder().decode(CompanionQuestionPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.index, 0)
        XCTAssertEqual(payload.total, 1)
    }

    // MARK: - CompanionStatePayload (tolerant decode #246)

    func testStatePayloadMalformedPendingActionDegradesToNil() throws {
        let json = """
        {
          "version": 1,
          "sequence": 7,
          "source": "claude",
          "status": "running",
          "messages": [],
          "pendingAction": "enterpriseApproval",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let payload = try JSONDecoder().decode(CompanionStatePayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.pendingAction, "unknown pending action must degrade to nil")
        XCTAssertEqual(payload.source, "claude")
        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.status, .running)
    }

    func testStatePayloadMissingUpdatedAtDefaultsToNow() throws {
        let json = """
        {
          "version": 1,
          "sequence": 1,
          "source": "codex",
          "status": "idle",
          "messages": []
        }
        """
        let payload = try JSONDecoder().decode(CompanionStatePayload.self, from: Data(json.utf8))
        XCTAssertNotNil(payload.updatedAt)
    }

    // MARK: - CompanionSessionPreview id

    func testSessionPreviewIdUsesSessionIdWhenPresent() {
        let session = CompanionSessionPreview(
            sessionId: "abc", source: "claude", status: .running,
            toolName: nil, workspaceName: nil, message: nil, updatedAt: Date()
        )
        XCTAssertEqual(session.id, "abc")
    }

    func testSessionPreviewIdFallsBackToSourceWorkspace() {
        let session = CompanionSessionPreview(
            sessionId: nil, source: "gemini", status: .idle,
            toolName: nil, workspaceName: "ws", message: nil, updatedAt: Date()
        )
        XCTAssertEqual(session.id, "gemini-ws")
    }

    // MARK: - CompanionCommandPayload defaults

    func testCommandPayloadDefaultsVersionOne() {
        let command = CompanionCommandPayload(type: .approveCurrentPermission)
        XCTAssertEqual(command.version, 1)
        XCTAssertNil(command.sessionId)
        XCTAssertNil(command.answer)
    }

    // MARK: - CompanionDisplayText (locale-independent surface only)

    func testDisplaySourceMapsKnownAgents() {
        XCTAssertEqual(CompanionDisplayText.source("claude"), "CLAUDE")
        XCTAssertEqual(CompanionDisplayText.source("ClaudeCode"), "CLAUDE")
        XCTAssertEqual(CompanionDisplayText.source("codex"), "CODEX")
        XCTAssertEqual(CompanionDisplayText.source("gemini"), "GEMINI")
        XCTAssertEqual(CompanionDisplayText.source("cursor"), "CURSOR")
        XCTAssertEqual(CompanionDisplayText.source("opencode"), "OPENCODE")
    }

    func testDisplaySourceNilAndEmptyFallBackToProductName() {
        XCTAssertEqual(CompanionDisplayText.source(nil), "NotchDeck Buddy")
        XCTAssertEqual(CompanionDisplayText.source(""), "NotchDeck Buddy")
        XCTAssertEqual(CompanionDisplayText.source("   "), "NotchDeck Buddy")
    }

    func testDisplaySourceUnknownUppercases() {
        XCTAssertEqual(CompanionDisplayText.source("myagent"), "MYAGENT")
    }

    func testDisplaySubtitleReturnsFallbackWhenEmpty() {
        XCTAssertEqual(
            CompanionDisplayText.subtitle(workspaceName: nil, toolName: nil, fallback: "Standby"),
            "Standby"
        )
    }

    func testMessageMarkdownUserStaysPlain() {
        let result = CompanionDisplayText.messageMarkdown("**hi**", isUser: true)
        XCTAssertEqual(String(result.characters), "**hi**")
    }

    func testMessageMarkdownAssistantRendersInlineBold() {
        let result = CompanionDisplayText.messageMarkdown("**hi**", isUser: false)
        XCTAssertEqual(String(result.characters), "hi")
    }
}
