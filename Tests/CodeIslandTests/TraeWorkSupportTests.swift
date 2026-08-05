import XCTest
import CodeIslandCore
@testable import CodeIsland

/// TRAE Work zero-config integration: auto-inject MCP server entry into
/// TRAE's User/mcp.json + drop AGENTS.md/CLAUDE.md rules into the latest
/// workspace, and clean up cleanly on uninstall.
final class TraeWorkSupportTests: XCTestCase {

    private func makeTempTRAE() throws -> (userDir: String, workspaceDir: String, skillDir: String, root: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("trae-test-\(UUID().uuidString)")
        let userDir = root.appendingPathComponent("User").path
        let ws = root.appendingPathComponent("Workspaces/ws1").path
        let skillDir = root.appendingPathComponent(".trae-cn/skills/notchdeck-report").path
        try fm.createDirectory(atPath: userDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try "{}".write(toFile: ws + "/workspace.json", atomically: true, encoding: .utf8)
        return (userDir, ws, skillDir, root)
    }

    private func setOverrides(_ temp: (userDir: String, workspaceDir: String, skillDir: String, root: URL)) {
        ConfigInstaller.traeUserRootsOverride = [temp.userDir]
        ConfigInstaller.traeWorkSkillDirOverride = temp.skillDir
    }

    func testTraeWorkConfigRegisteredInBuiltInCLIs() {
        guard let cli = ConfigInstaller.allCLIs.first(where: { $0.source == "trae-work" }) else {
            return XCTFail("trae-work not in allCLIs")
        }
        XCTAssertEqual(cli.name, "TRAE Work")
        XCTAssertEqual(cli.format, .traeWork)
        XCTAssertTrue(cli.events.isEmpty)
    }

    func testTraeWorkIsRegisteredAsSupportedSource() {
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("trae-work"))
    }

    func testInstallWritesMcpJsonAndRules() throws {
        let fm = FileManager.default
        let temp = try makeTempTRAE()
        setOverrides(temp)
        defer { try? fm.removeItem(at: temp.root) }

        XCTAssertTrue(ConfigInstaller.installTraeWorkConfig(fm: fm))

        // mcp.json carries our entry.
        let mcpPath = temp.userDir + "/mcp.json"
        XCTAssertTrue(fm.fileExists(atPath: mcpPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: mcpPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["notchdeck"] as? [String: Any])
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:8765/mcp")

        // Rules dropped into the latest workspace (AGENTS.md + CLAUDE.md).
        let agents = try String(contentsOfFile: temp.workspaceDir + "/AGENTS.md", encoding: .utf8)
        XCTAssertTrue(agents.contains("notchdeck_report"))
        XCTAssertTrue(agents.contains("source=trae-work"))
        XCTAssertTrue(agents.contains("notchdeck-managed"))
        let claude = try String(contentsOfFile: temp.workspaceDir + "/CLAUDE.md", encoding: .utf8)
        XCTAssertTrue(claude.contains("notchdeck_report"))

        // Agent skill — the injection point that actually works for the
        // AI-office client.
        let skill = try String(contentsOfFile: temp.skillDir + "/SKILL.md", encoding: .utf8)
        XCTAssertTrue(skill.contains("notchdeck_report"))
        XCTAssertTrue(skill.contains("source=trae-work"))
        XCTAssertTrue(skill.contains("USE THIS SKILL IN EVERY CONVERSATION"))

        XCTAssertTrue(ConfigInstaller.isTraeWorkInstalled(fm: fm))
    }

    func testInstallMergesExistingMcpServers() throws {
        let fm = FileManager.default
        let temp = try makeTempTRAE()
        setOverrides(temp)
        defer { try? fm.removeItem(at: temp.root) }

        // Pre-existing user MCP server must survive.
        let existing = """
        {"mcpServers":{"github":{"url":"https://mcp.example.com/github"}}}
        """
        try existing.write(toFile: temp.userDir + "/mcp.json", atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.installTraeWorkConfig(fm: fm))

        let data = try Data(contentsOf: URL(fileURLWithPath: temp.userDir + "/mcp.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["notchdeck"], "notchdeck entry missing")
        XCTAssertNotNil(servers["github"], "user server was clobbered")
        let entry = try XCTUnwrap(servers["notchdeck"] as? [String: Any])
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:8765/mcp")
    }

    func testUninstallRemovesOnlyOurEntryAndRules() throws {
        let fm = FileManager.default
        let temp = try makeTempTRAE()
        setOverrides(temp)
        defer { try? fm.removeItem(at: temp.root) }

        // Pre-existing user server + a user rule file with unrelated content.
        let existing = """
        {"mcpServers":{"github":{"url":"https://mcp.example.com/github"}}}
        """
        try existing.write(toFile: temp.userDir + "/mcp.json", atomically: true, encoding: .utf8)
        let userRules = "# My rules\nBe nice.\n"
        try userRules.write(toFile: temp.workspaceDir + "/AGENTS.md", atomically: true, encoding: .utf8)
        // Simulate a pre-existing user skill with the same name.
        try "# user skill\n".write(toFile: temp.skillDir + "/SKILL.md", atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.installTraeWorkConfig(fm: fm))
        XCTAssertTrue(ConfigInstaller.isTraeWorkInstalled(fm: fm))

        ConfigInstaller.uninstallTraeWorkConfig(fm: fm)

        // notchdeck entry gone; github preserved.
        XCTAssertFalse(ConfigInstaller.isTraeWorkInstalled(fm: fm))
        let data = try Data(contentsOf: URL(fileURLWithPath: temp.userDir + "/mcp.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["notchdeck"])
        XCTAssertNotNil(servers["github"])

        // Our rule block stripped; user content preserved.
        let agents = try String(contentsOfFile: temp.workspaceDir + "/AGENTS.md", encoding: .utf8)
        XCTAssertFalse(agents.contains("notchdeck-managed"))
        XCTAssertTrue(agents.contains("# My rules"))
        XCTAssertTrue(agents.contains("Be nice."))

        // Our skill removed.
        XCTAssertFalse(fm.fileExists(atPath: temp.skillDir + "/SKILL.md"))
    }

    func testInstallWithoutTRAEReturnsFalse() {
        let fm = FileManager.default
        ConfigInstaller.traeUserRootsOverride = ["/nonexistent/trae/user"]
        ConfigInstaller.traeWorkSkillDirOverride = "/nonexistent/skills/notchdeck-report"
        XCTAssertFalse(ConfigInstaller.installTraeWorkConfig(fm: fm))
        XCTAssertNil(ConfigInstaller.traeWorkMcpPath())
        XCTAssertFalse(ConfigInstaller.isTraeWorkInstalled(fm: fm))
    }
}
