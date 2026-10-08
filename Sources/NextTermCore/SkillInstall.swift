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
    /// Other links to the shared copy (`npx skills` makes them in ~/.commandcode/skills): kept too.
    public let keptOtherLinks: [SkillCopy]
    /// Places Next Term never touches that also hold this name, and what that means for the agents.
    public let untouched: [String]
    /// Agents that will load the skill once installed.
    public let agents: [SkillAgent]
    public let steps: [SkillStep]
}

public enum SkillInstall {
    /// What an install does about Claude Code's link to one skill. A folder that is also a Claude Code
    /// plugin loads through that link as the plugin "<name>@skills-dir", whose servers and hooks start by
    /// themselves, so the review asks: leave it out of Claude Code, or add it as a plugin. There is no
    /// "add it turned off": with the plugin's key false, Claude Code loads nothing from the folder, not
    /// even its skill (hand check H4), and Next Term changes no agent's settings for a skill.
    public enum ClaudeLink: Equatable, Sendable {
        /// No link: an existing link is removed for a plugin folder, and kept for a plain skill.
        case skip
        /// A link in ~/.claude/skills.
        case link
    }

    /// Claude Code's own slash commands: a skill with one of these names would hide the command.
    public static let claudeCommands: Set<String> = [
        "add-dir", "agents", "bashes", "bug", "clear", "compact", "config", "context", "cost", "doctor", "exit",
        "export", "feedback", "help", "hooks", "ide", "init", "install-github-app", "login", "logout", "mcp",
        "memory", "model", "output-style", "permissions", "plugin", "pr-comments", "privacy-settings",
        "release-notes", "reload-skills", "resume", "review", "rewind", "security-review", "skills", "status",
        "statusline", "terminal-setup", "todos", "upgrade", "usage", "vim",
    ]

    /// `.` and `..` worked out from the text alone. (NSString's standardizingPath follows links for `..`,
    /// which would turn a link to the shared entry into a link to wherever that entry points.)
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Where a symlink points, as an absolute path, without following any further links. Relative
    /// targets count from the folder the link really sits in.
    static func linkDestination(_ path: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        if destination.hasPrefix("/") { return lexical(destination) }
        let folder = SkillChanges.realPath((path as NSString).deletingLastPathComponent)
        return lexical((folder as NSString).appendingPathComponent(destination))
    }

    /// Whether an agent folder's entry is a link to the shared folder's entry for that name.
    static func linksToShared(_ copy: SkillCopy, sharedRoot: SkillRoot) -> Bool {
        guard copy.isLink, let destination = linkDestination(copy.path) else { return false }
        let candidates = [sharedRoot.path, sharedRoot.realPath, SkillChanges.realPath(sharedRoot.path)]
        return candidates.contains { lexical(($0 as NSString).appendingPathComponent(copy.name)) == destination }
    }

    /// The plan for putting the reviewed folder `staged` in place as `name`. `sameSource`: the lock file
    /// (or Next Term's record) says the shared copy came from the source being installed. `projects`:
    /// project folders open in Next Term, whose skills are never touched but are named.
    public static func plan(name: String, staged: String, staging: String, inventory: SkillInventory, linkForClaude: Bool,
                            sameSource: Bool, projects: [String] = []) -> SkillInstallPlan {
        let home = inventory.home
        let sharedRoot = inventory.root(.shared) ?? SkillRoot(kind: .shared, path: (home as NSString).appendingPathComponent(".agents/skills"))
        let shared = (sharedRoot.path as NSString).appendingPathComponent(name)
        let claudeRoot = inventory.root(.claude)
        let row = inventory.rows.first { $0.name == name }
        let copies = row?.copies ?? []

        let keptLink = copies.first { $0.root.kind == .claude && linksToShared($0, sharedRoot: sharedRoot) }
        let keptOther = copies.filter { $0.root.kind != .claude && $0.root.kind != .shared && linksToShared($0, sharedRoot: sharedRoot) }
        var replaced = copies.filter { $0 != keptLink && !keptOther.contains($0) }
        let sharedCopy = copies.first { $0.root.kind == .shared }
        // Something the inventory leaves out (a stray file) at the place the skill goes is in the way too.
        var stray: [String] = []
        if sharedCopy == nil, SkillChanges.exists(shared) { stray.append(shared) }
        if let claudeRoot, linkForClaude, keptLink == nil, !copies.contains(where: { $0.root.kind == .claude }) {
            let at = (claudeRoot.path as NSString).appendingPathComponent(name)
            if SkillChanges.exists(at) { stray.append(at) }
        }
        var existing = SkillInstallPlan.Existing.none
        if !replaced.isEmpty || !stray.isEmpty {
            let onlyShared = replaced.allSatisfy { $0.root.kind == .shared } && stray.isEmpty
            existing = sameSource && sharedCopy != nil && onlyShared ? .update : .conflict
        }
        replaced = replaced.sorted { $0.root.kind.order < $1.root.kind.order }

        // Copied to `staging` (a folder of Next Term's own) first: the slow step runs while the old copy
        // is still in place, so a quit or crash part-way leaves the skill as it was, and the new copy
        // only takes its place once complete.
        var steps: [SkillStep] = [.copy(from: staged, to: staging)]
        steps += replaced.map { SkillStep.trash($0.path) } + stray.map { SkillStep.trash($0) }
        steps.append(.move(from: staging, to: shared))
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
        if !stray.isEmpty { untouched.append("Something else is at \(stray.map(SkillStep.short).joined(separator: " and ")): it goes to the Trash.") }
        return SkillInstallPlan(name: name, existing: existing, replaced: replaced, keptLink: keptLink, keptOtherLinks: keptOther,
                                untouched: untouched, agents: SkillAgent.allCases.filter(agents.contains), steps: steps)
    }

    /// Several skills' steps as one change: every new copy is made before any old one goes, so a crash
    /// part-way through leaves each skill as it was; then each skill's other steps, in order.
    public static func combined(_ parts: [[SkillStep]]) -> [SkillStep] {
        let copies = parts.flatMap { $0.filter(\.isCopy) }
        let rest = parts.flatMap { $0.filter { !$0.isCopy } }
        return copies + rest
    }

    /// Removing a skill's shared copy and every agent folder's link to it (Claude Code's, and the ones
    /// `npx skills` makes in ~/.commandcode/skills), so no link is left pointing at nothing. Copies of
    /// that name made by hand in an agent's own folder are not part of it and stay.
    public static func removal(name: String, inventory: SkillInventory) -> [SkillStep] {
        guard let sharedRoot = inventory.root(.shared), let row = inventory.rows.first(where: { $0.name == name }) else { return [] }
        var steps: [SkillStep] = []
        for copy in row.copies where copy.root.kind != .shared && linksToShared(copy, sharedRoot: sharedRoot) {
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
