import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Windsurf (Codeium) Cascade hooks support.
/// Docs: https://docs.windsurf.com/windsurf/cascade/hooks
/// - User-level config: ~/.codeium/windsurf/hooks.json
/// - Events are snake_case (pre_run_command, post_write_code, ...)
/// - stdin carries agent_action_name / trajectory_id (bridged in the bridge binary)
/// - Pre-hooks can block via exit code 2 — the bridge must exit 0 (it does)
final class WindsurfSupportTests: XCTestCase {

    func testWindsurfEventNamesNormalizeToPascalCase() {
        XCTAssertEqual(EventNormalizer.normalize("pre_user_prompt"), "UserPromptSubmit")
        XCTAssertEqual(EventNormalizer.normalize("pre_run_command"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("post_run_command"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("pre_read_code"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("post_read_code"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("pre_write_code"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("post_write_code"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("pre_mcp_tool_use"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("post_mcp_tool_use"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("post_cascade_response"), "AfterAgentResponse")
    }

    func testWindsurfIsRegisteredAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("windsurf"), "windsurf")
    }

    func testBuiltInWindsurfCLIConfigIsRegistered() throws {
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "windsurf" })
        XCTAssertEqual(cli.configPath, ".codeium/windsurf/hooks.json")
        XCTAssertEqual(cli.format.storageValue, HookFormat.windsurf.storageValue)
        XCTAssertTrue(cli.events.contains { $0.0 == "pre_user_prompt" })
        XCTAssertTrue(cli.events.contains { $0.0 == "post_cascade_response" })
        XCTAssertFalse(cli.events.contains { $0.0 == "SessionStart" })  // Windsurf has no SessionStart event
    }

    func testWindsurfExternalHooksWriteFlatCommandWithShowOutputFalse() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("hooks.json").path
        let cli = CLIConfig(
            name: "Windsurf",
            source: "windsurf",
            configPath: configPath,
            configKey: "hooks",
            format: .windsurf,
            events: [("pre_run_command", 5, false), ("post_write_code", 5, false)]
        )

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))

        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])

        let preRun = try XCTUnwrap(hooks["pre_run_command"] as? [[String: Any]])
        let preEntry = try XCTUnwrap(preRun.first)
        let preCmd = try XCTUnwrap(preEntry["command"] as? String)
        XCTAssertTrue(preCmd.contains("notchdeck-bridge --source windsurf"))
        XCTAssertTrue(preCmd.contains("--event pre_run_command"))
        XCTAssertEqual(preEntry["show_output"] as? Bool, false)

        let postWrite = try XCTUnwrap(hooks["post_write_code"] as? [[String: Any]])
        let postEntry = try XCTUnwrap(postWrite.first)
        let postCmd = try XCTUnwrap(postEntry["command"] as? String)
        XCTAssertTrue(postCmd.contains("--event post_write_code"))
    }

    func testWindsurfUninstallRemovesOnlyOurEntries() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("hooks.json").path
        // Pre-seed with a user hook under the same event, then install ours, then uninstall.
        let seed: [String: Any] = [
            "hooks": [
                "pre_run_command": [
                    ["command": "echo user-hook", "show_output": true]
                ]
            ]
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted])
        try seedData.write(to: URL(fileURLWithPath: configPath))

        let cli = CLIConfig(
            name: "Windsurf",
            source: "windsurf",
            configPath: configPath,
            configKey: "hooks",
            format: .windsurf,
            events: [("pre_run_command", 5, false)]
        )
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))

        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)

        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["pre_run_command"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)  // user hook preserved
        let cmd = try XCTUnwrap(entries.first?["command"] as? String)
        XCTAssertEqual(cmd, "echo user-hook")
    }
}
