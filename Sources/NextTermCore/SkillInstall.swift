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
    /// A Claude Code link that already points at the shared copy: kept as it is, unless the folder is a
    /// Claude Code plugin left out of Claude Code (then it goes).
    public let keptLink: SkillCopy?
    /// Other links to the shared copy (`npx skills` makes them in ~/.commandcode/skills): kept too.
    public let keptOtherLinks: [SkillCopy]
    /// Places Next Term never touches that also hold this name, and what that means for the agents: the
    /// clashes' texts included.
    public let untouched: [String]
    /// Claude Code plugins whose name the folder's plugin shares, or looks like.
    public let clashes: [SkillInstall.Clash]
    /// Agents that will load the skill once installed.
    public let agents: [SkillAgent]
    public let steps: [SkillStep]

    /// Claude Code will read the skill through a link in ~/.claude/skills: one the install makes, or one it
    /// keeps.
    public var linksClaude: Bool {
        if steps.contains(where: { if case .link = $0 { return true }; return false }) { return true }
        guard let keptLink else { return false }
        return !steps.contains(.trash(keptLink.path))
    }
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

        /// The choice for several plugin folders at once: leave them out if any one's default does.
        public static func safest(_ choices: [ClaudeLink]) -> ClaudeLink {
            choices.contains(.skip) ? .skip : .link
        }
    }

    /// Another Claude Code plugin the folder's plugin would meet, named the way Claude Code compares names
    /// (NFC, then lowercased), or looking like it (KTD6). Read from the home folder, never written.
    public struct Clash: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Synced from claude.ai: the folder, once added, replaces it in Claude Code sessions.
            case synced
            /// Installed from a marketplace for the user (or the organization): Claude Code keeps that one,
            /// even turned off, and doesn't load the folder as a plugin (hand check H7).
            case installed
            /// Installed for a project only: Claude Code keeps it in that project, and loads the folder as
            /// a plugin everywhere else (H7).
            case installedForProject
            /// Another folder Claude Code reads, or another skill ticked in the same review, with the same
            /// plugin name: Claude Code loads only one, and one key turns off both.
            case skillsDir
            /// A name or display name that looks like one of the user's plugins.
            case lookalike
        }

        public let kind: Kind
        /// The other plugin's name, as written.
        public let name: String
        public let text: String

        /// Said as a warning: the folder would take the place of the user's plugin, or pass for it.
        public var warning: Bool { kind == .synced || kind == .lookalike }
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

    /// The plan for putting the reviewed folder `staged` in place as `name`. `claude`: Claude Code's link.
    /// `package`: the staged folder's (from its review); a Claude Code plugin left out loses a kept link.
    /// `facts`: Claude Code's plugins, for the clash notes. `ticked`: the other skills installed with it,
    /// by name, with their Claude Code plugin names. `sameSource`: the lock file (or Next Term's record)
    /// says the shared copy came from the source being installed. `projects`: project folders open in Next
    /// Term, whose skills are never touched but are named. No step writes anything but the skill folders;
    /// the app adds the lock file's and Next Term's own record.
    public static func plan(name: String, staged: String, staging: String, inventory: SkillInventory, claude: ClaudeLink,
                            package: SkillPackage?, facts: SkillClaudeSettings.Snapshot = .init(), ticked: [String: String] = [:],
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
        if let claudeRoot, claude == .link, keptLink == nil, !copies.contains(where: { $0.root.kind == .claude }) {
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
        // A plugin folder left out of Claude Code: its link goes too, or Claude Code would go on loading
        // the new copy as a plugin. A plain skill keeps it, as an unticked box always has.
        let dropsLink = claude == .skip && package?.claude != nil
        if dropsLink, let keptLink { steps.append(.trash(keptLink.path)) }
        steps.append(.move(from: staging, to: shared))
        var agents = sharedRoot.readers
        if let claudeRoot {
            let wantsLink = claude == .link || (keptLink != nil && !dropsLink)
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
        var clashes: [Clash] = []
        if let plugin = package?.claude {
            clashes = Self.clashes(plugin: plugin, skill: name, facts: facts, inventory: inventory, ticked: ticked)
            untouched += clashes.map(\.text)
        }
        return SkillInstallPlan(name: name, existing: existing, replaced: replaced, keptLink: keptLink, keptOtherLinks: keptOther,
                                untouched: untouched, clashes: clashes, agents: SkillAgent.allCases.filter(agents.contains), steps: steps)
    }

    /// What the review offers first for Claude Code's link (the High-Level Technical Design's table; the
    /// first row that holds wins):
    /// 1. the user turned the plugin off in /plugin ("<name>@skills-dir": false): link it, since Claude Code
    ///    loads nothing from it until it is turned on there, and nothing is written;
    /// 2. an update whose link is kept and whose declared parts are the installed copy's: keep the link;
    /// 3. its name, or a look-alike, clashes with another plugin: leave it out;
    /// 4. it runs nothing (KTD13): link it;
    /// 5. anything else, unread files included: leave it out.
    /// A folder that is not a Claude Code plugin is linked, as the checkbox always was. `installed`: the
    /// installed copy's package, for an update; `keptLink`: a link to the shared copy is there now.
    public static func defaultClaudeLink(package: SkillPackage?, installed: SkillPackage?, keptLink: Bool,
                                         facts: SkillClaudeSettings.Snapshot, clashes: [Clash]) -> ClaudeLink {
        guard let plugin = package?.claude else { return .link }
        if facts.value(for: plugin.name) == false { return .link }
        if keptLink, plugin.sameParts(as: installed?.claude) { return .link }
        if !clashes.isEmpty { return .skip }
        return plugin.runsNothing ? .link : .skip
    }

    /// The same, from a plan worked out with any choice (its kept link and clashes don't depend on it).
    public static func defaultClaudeLink(_ plan: SkillInstallPlan, package: SkillPackage?, installed: SkillPackage?,
                                         facts: SkillClaudeSettings.Snapshot) -> ClaudeLink {
        defaultClaudeLink(package: package, installed: installed, keptLink: plan.keptLink != nil, facts: facts, clashes: plan.clashes)
    }

    // MARK: Settings › Skills' Link and Unify

    /// A skill folder that is also a Claude Code plugin, as Settings › Skills' Link and Unify ask about
    /// Claude Code's link to it (R10): the plugin, how it would start, the plugins its name meets, and the
    /// review's default. Read from the disk; nothing is written for it but the link itself.
    public struct PluginLink: Equatable, Sendable {
        public let skill: String
        public let plugin: SkillPackage.ClaudePlugin
        public let start: SkillPackage.Start
        public let clashes: [Clash]
        /// What the review would offer first (defaultClaudeLink).
        public let preset: ClaudeLink

        /// Link asks first: the plugin runs something (or may: anything unread counts), or its name meets
        /// another plugin. One that runs nothing and meets none is linked as before, with no question.
        public var asks: Bool { !plugin.runsNothing || !clashes.isEmpty }
    }

    /// Some copies' packages, by real path, and Claude Code's plugins for their keys: what Link and Unify read
    /// off the main thread before they ask. Read only.
    public struct PluginFacts: Equatable, Sendable {
        public var packages: [String: SkillPackage] = [:]
        public var facts = SkillClaudeSettings.Snapshot()

        public init() {}
    }

    /// Reads each copy's folder once (by its real path, under its entry's name, as Claude Code keys a manifest
    /// without a usable name), and the keys of the plugins found. Copies that are no package are left out.
    public static func pluginFacts(_ copies: [SkillCopy], home: String) -> PluginFacts {
        var read = PluginFacts()
        var keys: [String] = []
        var seen = Set<String>()
        for copy in copies where !copy.broken && seen.insert(copy.realPath).inserted {
            guard let package = SkillPackage.read(folder: copy.realPath, folderName: copy.name, home: home) else { continue }
            read.packages[copy.realPath] = package
            if let plugin = package.claude { keys.append(SkillClaudeSettings.key(plugin.name)) }
        }
        read.facts = SkillClaudeSettings.snapshot(home: home, keys: keys)
        return read
    }

    /// Claude Code's link to `skill` from `copy`, when that copy is also a Claude Code plugin (nil otherwise).
    /// `loaded`: the package of the copy Claude Code loads now (Unify). When it is the same plugin, by its
    /// key, with the same parts, the default keeps Claude Code loading it, as an update keeps its link.
    public static func pluginLink(skill: String, copy: SkillCopy, read: PluginFacts, inventory: SkillInventory,
                                  loaded: SkillPackage? = nil) -> PluginLink? {
        guard let package = read.packages[copy.realPath], let plugin = package.claude else { return nil }
        let clashes = Self.clashes(plugin: plugin, skill: skill, facts: read.facts, inventory: inventory)
        let same = loaded?.claude?.name == plugin.name
        let preset = defaultClaudeLink(package: package, installed: same ? loaded : nil, keptLink: same, facts: read.facts, clashes: clashes)
        let start = plugin.start(key: read.facts.value(for: plugin.name))
        return PluginLink(skill: skill, plugin: plugin, start: start, clashes: clashes, preset: preset)
    }

    /// What Settings › Skills' Link would link for `skill`: its shared copy, read now. Nil for a plain folder,
    /// or none. Read again in the change's own turn, so a folder that changed since the question links nothing.
    public static func pluginLink(skill: String, inventory: SkillInventory) -> PluginLink? {
        let row = inventory.rows.first { $0.name == skill }
        guard let shared = row?.copies.first(where: { $0.root.kind == .shared && !$0.broken }) else { return nil }
        let read = pluginFacts([shared], home: inventory.home)
        return pluginLink(skill: skill, copy: shared, read: read, inventory: inventory)
    }

    // MARK: clashes

    /// The plugins `plugin` would meet in Claude Code: synced from claude.ai, installed from a marketplace,
    /// other folders Claude Code reads in the skills folders, and the other ticked skills (`ticked`, by
    /// skill name). The skill's own entry (`skill`) does not count. Each other plugin gives one clash at most.
    public static func clashes(plugin: SkillPackage.ClaudePlugin, skill: String, facts: SkillClaudeSettings.Snapshot,
                               inventory: SkillInventory, ticked: [String: String] = [:]) -> [Clash] {
        let name = SkillPackage.normalized(plugin.name)
        let mine = SkillReview.oneLine(plugin.name, limit: 60)
        let key = "“" + SkillClaudeSettings.key(mine) + "”"
        var clashes: [Clash] = []
        var looks: [Clash] = []
        let own = lookalikes(plugin.name, plugin.displayName)
        for synced in facts.synced {
            let theirs = quoted(synced.name)
            if SkillPackage.normalized(synced.name) == name {
                let text = "You have a plugin named \(theirs) from claude.ai. Added, this folder replaces it in Claude Code sessions, and Claude Code reports yours as not loaded."
                clashes.append(Clash(kind: .synced, name: synced.name, text: text))
            } else if !own.isDisjoint(with: lookalikes(synced.name, synced.displayName)) {
                looks.append(Clash(kind: .lookalike, name: synced.name, text: "Its plugin name looks like your plugin \(theirs) from claude.ai."))
            }
        }
        for installed in facts.installed {
            let theirs = quoted(installed.name)
            let market = quoted(installed.marketplace)
            if SkillPackage.normalized(installed.name) == name {
                clashes.append(installedClash(installed, theirs: theirs, market: market))
            } else if !own.isDisjoint(with: lookalikes(installed.name, nil)) {
                looks.append(Clash(kind: .lookalike, name: installed.name, text: "Its plugin name looks like your plugin \(theirs) from \(market)."))
            }
        }
        for row in inventory.rows where row.name != skill {
            // The copy Claude Code loads for that name: its link or own copy in ~/.claude/skills.
            guard let copy = row.rawLoad(for: .claudeCode).used, let other = copy.claudePluginName,
                  SkillPackage.normalized(other) == name else { continue }
            let place = copy.root.title + "/" + SkillReview.oneLine(copy.name, limit: 60)
            let text = "\(place) is also a Claude Code plugin named \(quoted(other)). Claude Code loads only one of them, and \(key): false turns off both."
            clashes.append(Clash(kind: .skillsDir, name: other, text: text))
        }
        for (other, otherPlugin) in ticked.sorted(by: { $0.key < $1.key }) where other != skill && SkillPackage.normalized(otherPlugin) == name {
            let text = "“\(SkillReview.oneLine(other, limit: 60))”, also ticked here, is also a Claude Code plugin named \(quoted(otherPlugin)). "
                + "Claude Code loads only one of them, and \(key): false turns off both."
            clashes.append(Clash(kind: .skillsDir, name: otherPlugin, text: text))
        }
        return clashes + looks
    }

    static func installedClash(_ installed: SkillClaudeSettings.Installed, theirs: String, market: String) -> Clash {
        if installed.everywhere {
            let text = "You have a plugin named \(theirs) installed from \(market). Claude Code keeps that one, even turned off, and won't load this folder as a plugin."
            return Clash(kind: .installed, name: installed.name, text: text)
        }
        let text = "You have a plugin named \(theirs) from \(market), installed for a project. In that project Claude Code keeps it; elsewhere it loads this folder as a plugin."
        return Clash(kind: .installedForProject, name: installed.name, text: text)
    }

    /// A name and a display name folded so look-alikes meet (empty folds left out).
    static func lookalikes(_ name: String, _ displayName: String?) -> Set<String> {
        Set([name, displayName].compactMap { $0.map(SkillPackage.lookalike) }.filter { !$0.isEmpty })
    }

    static func quoted(_ name: String) -> String { "“" + SkillReview.oneLine(name, limit: 60) + "”" }

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

    /// What a skill brought that outlives it, in a running session or in another app's settings: hooks,
    /// what its Claude Code plugin started, Amp's and Codex's MCP servers, Claude Code's key for its plugin,
    /// and pre-approved tools. Removal lists them, so the developer can check those places too; it removes
    /// and edits none of them (KTD12). `folder`: the installed copy, read for its plugin and servers (nil:
    /// none). `home`: for Claude Code's skills folder, settings and installed plugins in ~/.claude, and for
    /// ~/.codex/config.toml, all read only.
    public static func leftovers(frontMatter: SkillFrontMatter?, folder: String?, home: String) -> [String] {
        let read = folder.map { installed(folder: $0, home: home) }
        var items: [String] = []
        if frontMatter?.keys.contains("hooks") == true {
            items.append("Hooks it added stay active in Claude Code sessions that are open now, until they restart.")
        }
        if let read { items += claudeLeftovers(read, home: home) }
        if let servers = read?.servers, servers.hasAmp {
            items.append("Amp sessions open now keep its MCP servers until they restart.")
        } else if frontMatter?.keys.contains("mcpServers") == true {
            items.append("It asked for MCP servers: check your agents' MCP settings.")
        }
        if let servers = read?.servers { items += codexLeftovers(servers, config: SkillServers.codexConfig(home: home)) }
        if let tools = frontMatter?.allowedTools, !tools.isEmpty { items.append("It pre-approved these tools while it ran: \(tools).") }
        return items
    }

    /// An installed copy as removal reads it: its package, its servers, and whether Claude Code reads it (a
    /// link in ~/.claude/skills to it, or that folder linked to the shared one).
    struct InstalledCopy {
        let package: SkillPackage?
        let servers: SkillServers
        let claudeReads: Bool
    }

    static func installed(folder: String, home: String) -> InstalledCopy {
        let name = (folder as NSString).lastPathComponent
        let real = SkillChanges.realPath(folder)
        let skillFile = ["SKILL.md", "skill.md"].first { FileManager.default.fileExists(atPath: (real as NSString).appendingPathComponent($0)) }
        let text = skillFile.flatMap { SkillClaudeSettings.read((real as NSString).appendingPathComponent($0)) }.map { String(decoding: $0, as: UTF8.self) }
        let package = SkillPackage.read(folder: real, folderName: name, home: home)
        let servers = SkillServers.read(folder: real, skillText: text ?? "", skillFile: skillFile ?? "SKILL.md", package: package)
        let entry = ((home as NSString).appendingPathComponent(".claude/skills") as NSString).appendingPathComponent(name)
        let claudeReads = SkillChanges.exists(entry) && SkillChanges.realPath(entry) == real
        return InstalledCopy(package: package, servers: servers, claudeReads: claudeReads)
    }

    /// The Claude Code plugin's leftovers: what it started, while Claude Code loaded it as a plugin that
    /// was on, and the key the user set to keep it off, which stays.
    static func claudeLeftovers(_ installed: InstalledCopy, home: String) -> [String] {
        guard let plugin = installed.package?.claude else { return [] }
        let key = SkillClaudeSettings.key(plugin.name)
        let facts = SkillClaudeSettings.snapshot(home: home, keys: [key])
        let value = facts.values[key]
        // A plugin of the same name installed for the user wins, even turned off: Claude Code never loaded
        // this folder as a plugin (hand check H7).
        let name = SkillPackage.normalized(plugin.name)
        let shadowed = facts.installed.contains { $0.everywhere && SkillPackage.normalized($0.name) == name }
        var items: [String] = []
        if installed.claudeReads, plugin.loadsAsPlugin, plugin.startsPrograms, !shadowed, plugin.start(key: value) == .on {
            items.append(partsLeftover(plugin))
        }
        if value == false {
            let quoted = "“" + SkillReview.oneLine(key, limit: 80) + "”"
            items.append("~/.claude/settings.json keeps \(quoted): false. It stays, and keeps any later folder with that plugin name turned off in Claude Code.")
        }
        return items
    }

    /// "Its Claude Code plugin's MCP servers and hooks stop with it. …", naming the kinds it has.
    static func partsLeftover(_ plugin: SkillPackage.ClaudePlugin) -> String {
        var kinds: [String] = []
        if plugin.serverCount > 0 { kinds.append("MCP servers") }
        if (plugin.partCounts[.hook] ?? 0) > 0 { kinds.append("hooks") }
        if (plugin.partCounts[.monitor] ?? 0) > 0 { kinds.append("monitors") }
        if (plugin.partCounts[.lspServer] ?? 0) > 0 { kinds.append("language servers") }
        guard !kinds.isEmpty else {
            return "Its Claude Code plugin goes with it. Claude Code sessions open now keep what it started until they restart."
        }
        return "Its Claude Code plugin's \(SkillPackage.list(kinds)) stop with it. Claude Code sessions open now keep them until they restart."
    }

    /// The servers in ~/.codex/config.toml that match the skill's agents/openai.yaml by address, as Codex
    /// matches them (KTD7): Codex may have added them for this skill, or the user for other things, so they
    /// are named and left. A config or a dependency file Next Term could not read in full says so.
    static func codexLeftovers(_ servers: SkillServers, config: SkillServers.CodexConfig) -> [String] {
        var items: [String] = []
        let dependencies = servers.codex
        if !dependencies.isEmpty, !config.complete {
            var names: [String] = dependencies.prefix(SkillPackage.cap).map { quoted($0.name) }
            if let more = SkillPackage.more(dependencies.count - SkillPackage.cap) { names.append(more) }
            let text = "Codex may have added MCP servers for this skill (\(SkillPackage.list(names))). Next Term could not read all of "
                + "~/.codex/config.toml: check it there."
            items.append(text)
        } else if !dependencies.isEmpty {
            var matched: [SkillServers.CodexConfig.Table] = []
            for dependency in dependencies {
                for table in config.tables where SkillServers.matches(dependency, table) && !matched.contains(where: { $0.name == table.name }) {
                    matched.append(table)
                }
            }
            if let line = codexMatchedLine(matched) { items.append(line) }
        }
        if let file = servers.codexFile, servers.unread.contains(where: { $0.file == file }) {
            let text = "Next Term could not read every MCP entry in its \(file), so Codex may have added servers for it that aren't named here: "
                + "check ~/.codex/config.toml."
            items.append(text)
        }
        return items
    }

    /// One line for the matching tables, named as the config names them, with their address.
    static func codexMatchedLine(_ tables: [SkillServers.CodexConfig.Table]) -> String? {
        guard !tables.isEmpty else { return nil }
        var named: [String] = tables.prefix(SkillPackage.cap).map { table in
            let address: String
            if let url = SkillServers.trimmed(table.url) {
                address = SkillReview.oneLine(url)
            } else {
                address = "the program `" + SkillReview.oneLine(SkillServers.trimmed(table.command) ?? "", limit: 120) + "`"
            }
            return quoted(table.name) + " (" + address + ")"
        }
        if let more = SkillPackage.more(tables.count - SkillPackage.cap) { named.append(more) }
        let one = tables.count == 1
        let servers = one ? "the MCP server" : "the MCP servers"
        let stays = one ? "It stays there, because you may use it for other things. Remove it there if you don't."
            : "They stay there, because you may use them for other things. Remove them there if you don't."
        return "Codex may have added \(servers) \(SkillPackage.list(named)) for this skill, in ~/.codex/config.toml. " + stays
    }
}

extension SkillUnify {
    /// What Unify asks about Claude Code's link when the copy it keeps, `winner`, is also a Claude Code plugin
    /// and Claude Code had the skill in a folder of its own (otherwise Unify makes no link, and nil). `read`:
    /// the row's copies (SkillInstall.pluginFacts). The default keeps Claude Code loading the plugin when the
    /// copy it loads now is that plugin with the same parts; otherwise it is the review's.
    public static func pluginLink(_ row: SkillRow, winner: SkillCopy, in inventory: SkillInventory,
                                  read: SkillInstall.PluginFacts) -> SkillInstall.PluginLink? {
        guard inventory.root(.claude) != nil, row.copies.contains(where: { $0.root.kind == .claude }) else { return nil }
        let load = row.load(for: .claudeCode)
        let loaded = load.switchedOff ? nil : load.used.flatMap { read.packages[$0.realPath] }
        return SkillInstall.pluginLink(skill: row.name, copy: winner, read: read, inventory: inventory, loaded: loaded)
    }
}
