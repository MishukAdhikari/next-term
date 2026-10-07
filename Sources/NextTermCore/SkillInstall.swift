import Foundation

/// What installing (or removing) a reviewed skill does on disk, worked out before anything is written,
/// so the review sheet can show it. A skill is installed once, in the shared folder, under its `name`;
/// Codex and Command Code read it there, Claude Code through a link when the developer wants one.
public struct SkillInstallPlan: Equatable, Sendable {
    public enum Existing: Equatable, Sendable {
        /// Nothing of that name in the personal folders: a plain install.
        case none
        /// The shared copy came from this same source: installing again is an update.
        case update
        /// Personal copies or links of that name from elsewhere: installing replaces them (they go to
        /// the Trash, links are removed, and Undo puts them back).
        case conflict
    }

    public let name: String
    public let existing: Existing
    /// The personal copies and links that go.
    public let replaced: [SkillCopy]
    /// A Claude Code link that already points at the shared copy: kept as it is.
    public let keptLink: SkillCopy?
    /// Places Next Term never touches that also hold this name, and what that means for the agents.
    public let untouched: [String]
    /// Agents that will load the skill once installed.
    public let agents: [SkillAgent]
    public let steps: [SkillStep]
}

public enum SkillInstall {
    /// Claude Code's own slash commands: a skill with one of these names would hide the command.
    public static let claudeCommands: Set<String> = [
        "add-dir", "agents", "bashes", "bug", "clear", "compact", "config", "context", "cost", "doctor", "exit",
        "export", "feedback", "help", "hooks", "ide", "init", "install-github-app", "login", "logout", "mcp",
        "memory", "model", "output-style", "permissions", "plugin", "pr-comments", "privacy-settings",
        "release-notes", "reload-skills", "resume", "review", "rewind", "security-review", "skills", "status",
        "statusline", "terminal-setup", "todos", "upgrade", "usage", "vim",
    ]

    /// Where a symlink points, as an absolute path, without following any further links.
    static func linkDestination(_ path: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        let absolute = destination.hasPrefix("/") ? destination : (folder as NSString).appendingPathComponent(destination)
        return (absolute as NSString).standardizingPath
    }

    /// Whether a Claude Code entry is a link to the shared folder's entry for that name.
    static func linksToShared(_ copy: SkillCopy, sharedRoot: SkillRoot) -> Bool {
        guard copy.isLink, let destination = linkDestination(copy.path) else { return false }
        return [sharedRoot.path, sharedRoot.realPath].contains { (($0 as NSString).appendingPathComponent(copy.name) as NSString).standardizingPath == destination }
    }

    /// The plan for putting the reviewed folder `staged` in place as `name`. `sameSource`: the lock file
    /// (or Next Term's record) says the shared copy came from the source being installed. `projects`:
    /// project folders open in Next Term, whose skills are never touched but are named.
    public static func plan(name: String, staged: String, inventory: SkillInventory, linkForClaude: Bool,
                            sameSource: Bool, projects: [String] = []) -> SkillInstallPlan {
        let home = inventory.home
        let sharedRoot = inventory.root(.shared) ?? SkillRoot(kind: .shared, path: (home as NSString).appendingPathComponent(".agents/skills"))
        let shared = (sharedRoot.path as NSString).appendingPathComponent(name)
        let claudeRoot = inventory.root(.claude)
        let row = inventory.rows.first { $0.name == name }
        let copies = row?.copies ?? []

        let keptLink = copies.first { $0.root.kind == .claude && linksToShared($0, sharedRoot: sharedRoot) }
        let replaced = copies.filter { $0 != keptLink }
        let sharedCopy = copies.first { $0.root.kind == .shared }
        var existing = SkillInstallPlan.Existing.none
        if !replaced.isEmpty {
            let onlyShared = replaced.allSatisfy { $0.root.kind == .shared }
            existing = sameSource && sharedCopy != nil && onlyShared ? .update : .conflict
        }

        var steps = replaced.map { SkillStep.trash($0.path) }
        steps.append(.copy(from: staged, to: shared))
        var agents = sharedRoot.readers
        if let claudeRoot {
            let wantsLink = linkForClaude || keptLink != nil
            if wantsLink {
                agents.append(.claudeCode)
                if keptLink == nil { steps.append(.link(at: (claudeRoot.path as NSString).appendingPathComponent(name), to: shared)) }
            }
        }

        var untouched: [String] = []
        let manager = FileManager.default
        let synced = (home as NSString).appendingPathComponent(".claude/skills/synced/" + name)
        if manager.fileExists(atPath: synced) {
            untouched.append("Your claude.ai skill “\(name)” (~/.claude/skills/synced) stays as it is; Claude Code may list both.")
        }
        let system = (home as NSString).appendingPathComponent(".codex/skills/.system/" + name)
        if manager.fileExists(atPath: system) {
            untouched.append("Codex has its own built-in “\(name)” (~/.codex/skills/.system); it stays, and Codex lists both.")
        }
        for project in projects {
            for folder in [".claude/skills", ".agents/skills", ".codex/skills", ".commandcode/skills"] {
                let path = ((project as NSString).appendingPathComponent(folder) as NSString).appendingPathComponent(name)
                guard manager.fileExists(atPath: path) else { continue }
                untouched.append("The project skill \(SkillStep.short(path)) stays. In that project Claude Code prefers your personal copy, Command Code the project's, and Codex lists both.")
            }
        }
        if claudeCommands.contains(name), agents.contains(.claudeCode) {
            untouched.append("Claude Code has its own /\(name) command: this skill would take its place.")
        }
        return SkillInstallPlan(name: name, existing: existing, replaced: replaced, keptLink: keptLink, untouched: untouched,
                                agents: SkillAgent.allCases.filter(agents.contains), steps: steps)
    }

    /// Removing an installed skill: its shared copy and the Claude Code link to it. Copies of that name
    /// elsewhere (made by hand, or in an agent's own folder) are not part of the install and stay.
    public static func removal(name: String, inventory: SkillInventory) -> [SkillStep] {
        guard let sharedRoot = inventory.root(.shared), let row = inventory.rows.first(where: { $0.name == name }) else { return [] }
        var steps: [SkillStep] = []
        for copy in row.copies where copy.root.kind == .claude && linksToShared(copy, sharedRoot: sharedRoot) {
            steps.append(.trash(copy.path))
        }
        if row.copies.contains(where: { $0.root.kind == .shared }) {
            steps.append(.trash((sharedRoot.path as NSString).appendingPathComponent(name)))
        }
        return steps
    }

    /// What a skill asked for that outlives it in a running session or in settings: hooks, MCP servers
    /// and pre-approved tools. Removal lists them, so the developer can check those places too.
    public static func leftovers(frontMatter: SkillFrontMatter?) -> [String] {
        guard let front = frontMatter else { return [] }
        var items: [String] = []
        if front.keys.contains("hooks") { items.append("Hooks it added stay active in Claude Code sessions that are open now, until they restart.") }
        if front.keys.contains("mcpServers") { items.append("It asked for MCP servers: check your agents' MCP settings.") }
        if let tools = front.allowedTools, !tools.isEmpty { items.append("It pre-approved these tools while it ran: \(tools).") }
        return items
    }
}
