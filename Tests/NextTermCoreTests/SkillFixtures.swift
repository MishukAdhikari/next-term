import Foundation
@testable import NextTermCore

/// A skill folder built on disk for the package and review tests, in its own temporary folder and named
/// like the skill. One builder call per package shape, link, case spelling and warning.
struct SkillFixture {
    let root: String
    var name: String { (root as NSString).lastPathComponent }

    init(_ name: String = "demo", skill: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-fixture-\(UUID().uuidString)/\(name)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try write("SKILL.md", skill ?? "---\nname: \(name)\ndescription: The \(name) skill.\n---\nUse it well.\n")
    }

    func at(_ path: String) -> String { (root as NSString).appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ text: String, executable: Bool = false) throws -> SkillFixture {
        try data(path, Data(text.utf8), executable: executable)
    }

    @discardableResult
    func data(_ path: String, _ data: Data, executable: Bool = false) throws -> SkillFixture {
        let full = at(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
        if executable { chmod(full, 0o755) }
        return self
    }

    @discardableResult
    func folder(_ path: String) throws -> SkillFixture {
        try FileManager.default.createDirectory(atPath: at(path), withIntermediateDirectories: true)
        return self
    }

    /// A link at `path` (inside the skill) to `target`, written as given.
    @discardableResult
    func link(_ path: String, to target: String) throws -> SkillFixture {
        let full = at(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: target)
        return self
    }

    /// `.claude-plugin/plugin.json` named `plugin`, with `extra` JSON members after the name.
    @discardableResult
    func claudeManifest(_ plugin: String = "demo", _ extra: String = "") throws -> SkillFixture {
        try write(".claude-plugin/plugin.json", "{\"name\": \"\(plugin)\"" + (extra.isEmpty ? "" : ", " + extra) + "}")
    }

    var package: SkillPackage? { SkillPackage.read(folder: root, folderName: name) }

    func package(home: String) -> SkillPackage? { SkillPackage.read(folder: root, folderName: name, home: home) }

    var review: SkillReview { SkillReview.review(folder: root, folderName: name) }

    /// The temporary folder that holds the skill folder (stands in for a home folder or a sibling).
    var parent: String { (root as NSString).deletingLastPathComponent }

    // MARK: shapes

    /// One package shape: its files, and the manifest it gives (nil: not a package).
    struct Shape: CustomStringConvertible {
        let description: String
        let files: [String: String]
        let kind: SkillPackage.Kind?
        let agent: String?
    }

    static let shapes: [Shape] = [
        Shape(description: "Claude Code plugin", files: [".claude-plugin/plugin.json": #"{"name": "demo"}"#], kind: .claudePlugin, agent: "Claude Code"),
        Shape(description: "Codex plugin", files: [".codex-plugin/plugin.json": #"{"name": "demo"}"#], kind: .codexPlugin, agent: "Codex"),
        Shape(description: "Cursor plugin", files: [".cursor-plugin/plugin.json": #"{"name": "demo"}"#], kind: .cursorPlugin, agent: "Cursor"),
        Shape(description: "Copilot plugin", files: [".plugin/plugin.json": #"{"name": "demo"}"#], kind: .copilotPlugin, agent: "Copilot CLI and VS Code"),
        Shape(description: "Copilot CLI plugin", files: [".github/plugin/plugin.json": #"{"name": "demo"}"#], kind: .copilotPlugin, agent: "Copilot CLI"),
        Shape(description: "Agent Plugins package",
              files: ["plugin.json": #"{"$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "name": "demo"}"#],
              kind: .agentPlugin, agent: "Agent Plugins"),
        Shape(description: "plugin.json with another schema", files: ["plugin.json": #"{"$schema": "https://example.com/plugin.json", "name": "demo"}"#],
              kind: nil, agent: nil),
        Shape(description: "Gemini CLI extension", files: ["gemini-extension.json": #"{"name": "demo", "version": "1.0.0"}"#],
              kind: .geminiExtension, agent: "Gemini CLI"),
        Shape(description: "Qwen Code extension", files: ["qwen-extension.json": #"{"name": "demo", "version": "1.0.0"}"#],
              kind: .qwenExtension, agent: "Qwen Code"),
        Shape(description: "Junie extension", files: ["extension.json": #"{"name": "demo"}"#, "mcp/.mcp.json": #"{"mcpServers": {}}"#],
              kind: .junieExtension, agent: "Junie"),
        Shape(description: "Junie extension with guidelines", files: ["extension.json": #"{"name": "demo"}"#, "guidelines/style.md": "Be brief."],
              kind: .junieExtension, agent: "Junie"),
        Shape(description: "bare extension.json", files: ["extension.json": #"{"name": "demo"}"#], kind: nil, agent: nil),
        Shape(description: "Kiro power", files: ["POWER.md": "---\nname: demo\ndescription: A power.\n---\nUse it.\n"], kind: .kiroPower, agent: "Kiro"),
        Shape(description: "plain skill", files: ["reference.md": "More."], kind: nil, agent: nil),
    ]

    static func shape(_ shape: Shape) throws -> SkillFixture {
        let fixture = try SkillFixture()
        for (path, text) in shape.files { try fixture.write(path, text) }
        return fixture
    }

    /// Whether the temporary folder's volume ignores case, as a Mac's usually does.
    static let caseInsensitive: Bool = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-case-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a", contents: Data())
        return FileManager.default.fileExists(atPath: folder + "/A")
    }()
}
