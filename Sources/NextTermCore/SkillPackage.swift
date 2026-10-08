import CoreFoundation
import CryptoKit
import Foundation

// What else a skill folder is: a plugin or extension that an agent loads as a package, and, for Claude
// Code, the parts it would start by itself. Read offline from the folder's own files, by opening their
// paths (so the volume's case rules apply, as they do for the agents), never by running an agent.
//
// Package manifests at a skill folder's root (as of October 2026):
// - .claude-plugin/plugin.json: Claude Code. A folder in ~/.claude/skills that holds it loads as the plugin
//   "<name>@skills-dir", with its MCP servers, hooks, monitors, LSP servers and bin/, in every session and
//   with no question per part. Claude Code adopts it only in a folder spelled exactly ".claude-plugin";
//   the files in it and beside it follow the volume's case rules (hand checks, Claude Code 2.1.280).
// - .codex-plugin/plugin.json (Codex), .cursor-plugin/plugin.json (Cursor), .plugin/plugin.json (Copilot
//   CLI and VS Code) and .github/plugin/plugin.json (Copilot CLI);
// - a root plugin.json whose $schema is Agent Plugins' (agent-plugins.org): VS Code, Cursor, Copilot,
//   Codex, Kiro and Qwen Code read it;
// - gemini-extension.json (Gemini CLI), qwen-extension.json (Qwen Code), POWER.md (Kiro), and extension.json
//   beside mcp/.mcp.json or guidelines/ (Junie, as JetBrains lays its extensions out).
// Only the root counts: Claude Code ignores a manifest in a subfolder, so those are listed as notes.

public struct SkillPackage: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case claudePlugin, codexPlugin, cursorPlugin, copilotPlugin, agentPlugin, geminiExtension, qwenExtension, junieExtension, kiroPower

        /// What the review calls it, with its article: "a Claude Code plugin".
        public var title: String {
            switch self {
            case .claudePlugin: return "a Claude Code plugin"
            case .codexPlugin: return "a Codex plugin"
            case .cursorPlugin: return "a Cursor plugin"
            case .copilotPlugin: return "a Copilot plugin"
            case .agentPlugin: return "an Agent Plugins package"
            case .geminiExtension: return "a Gemini CLI extension"
            case .qwenExtension: return "a Qwen Code extension"
            case .junieExtension: return "a Junie extension"
            case .kiroPower: return "a Kiro power"
            }
        }
    }

    /// A package manifest at the folder's root.
    public struct Manifest: Equatable, Sendable {
        public let kind: Kind
        /// Its path in the folder, as spelled on disk.
        public let file: String
        /// Who loads it, for the review: "Copilot CLI and VS Code".
        public let agent: String
        /// Its `name`, as written.
        public let name: String?
        /// The MCP servers it declares. Empty for the Claude Code plugin, whose parts are in `claude`.
        public let servers: [Server]
        /// The files that hold hooks it declares.
        public let hooks: [String]
        /// Files it names that could not be read.
        public let unread: [Unread]
    }

    /// An MCP server a package declares.
    public struct Server: Equatable, Sendable {
        public enum Transport: Equatable, Sendable {
            case stdio, http, sse
            /// A packed server (.mcpb or .dxt) that Claude Code unpacks and runs.
            case bundle
            case other(String)
        }

        public let name: String
        public let transport: Transport
        public let command: String?
        public let args: [String]
        public let url: String?
        /// A bundle's path or web address, as written.
        public let bundle: String?
        /// A command Claude Code runs for the server's headers.
        public let headersHelper: String?
        /// The file that declares it.
        public let file: String
    }

    /// Something other than an MCP server that a Claude Code plugin starts or loads by itself.
    public struct Part: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case hook, monitor, lspServer, settings

            /// What it is, in a few words, for the review.
            public var gloss: String {
                switch self {
                case .hook: return "commands that run on Claude Code events"
                case .monitor: return "programs that keep running in the background"
                case .lspServer: return "language servers: programs that read code as Claude Code edits it"
                case .settings: return "a plugin settings.json, which can make a plugin agent the main agent or run a status line command"
                }
            }
        }

        public let kind: Kind
        /// The hook's event (and matcher), the monitor's or language's name, or the file.
        public let name: String
        /// The command it runs, or what it does.
        public let detail: String
        public let file: String
        /// `detail` is the command line it runs; otherwise it says what the part does ("sends a web request to …").
        public var runsCommand = true
    }

    /// What a plugin also brings that loads with it but starts nothing by itself.
    public struct Brought: Equatable, Sendable {
        public enum Kind: String, Sendable { case agent, command, outputStyle, skill }
        public let kind: Kind
        public let file: String
        /// For skills and commands: SKILL.md's "What it may do" checks on this file.
        public let capabilities: [String]
    }

    /// A part reached through a link inside the folder.
    public struct Link: Equatable, Sendable {
        public let path: String
        public let target: String
    }

    /// A file the review could not read: it counts as running.
    public struct Unread: Error, Equatable, Sendable {
        public let file: String
        public let reason: String
    }

    /// The Claude Code plugin the folder is, and what it would start or bring once added to Claude Code.
    public struct ClaudePlugin: Equatable, Sendable {
        /// `.claude-plugin/plugin.json`, as spelled on disk.
        public let manifest: String
        /// The plugin's name in Claude Code: the manifest's `name`, else the folder's (its key is
        /// "<name>@skills-dir").
        public let name: String
        /// The manifest's `name`, as written.
        public let declaredName: String?
        public let displayName: String?
        /// False only when the manifest says `"defaultEnabled": false`.
        public let defaultEnabled: Bool
        /// The first 20 servers, and how many there are.
        public let servers: [Server]
        public let serverCount: Int
        /// The first 20 parts, and how many of each kind there are.
        public let parts: [Part]
        public let partCounts: [Part.Kind: Int]
        /// The first 20 names in bin/, and how many there are.
        public let programs: [String]
        public let programCount: Int
        /// Names in bin/ that are also common commands (git, node, …).
        public let commonCommands: [String]
        /// Manifest keys Next Term does not check.
        public let unknownKeys: [String]
        /// The first 20 agents, commands, output styles and skills it brings, and how many there are.
        public let brings: [Brought]
        public let bringCount: Int
        public let links: [Link]
        /// Paths the manifest names that lead outside the folder, as written.
        public let outside: [String]
        public let unread: [Unread]
        /// Only allowlisted manifest keys, and none of the parts Claude Code reads (KTD13).
        public let runsNothing: Bool
        /// Servers, hooks, monitors, LSP servers, bin/ programs, a plugin settings.json or keys Next Term
        /// does not check, or something unread: parts that run by themselves, or may.
        public let startsPrograms: Bool
        /// A digest of what it declares that starts by itself (PackageReader.partsFingerprint); nil when
        /// something could not be read or leads outside the folder.
        public let partsFingerprint: String?

        public var partCount: Int { partCounts.values.reduce(0, +) }

        /// It declares the same parts as `other`, the installed copy, so an update keeps its link by default:
        /// the same manifest keys outside the allowlist, the same files of servers, hooks, monitors, LSP
        /// servers and plugin settings, byte for byte, and the same names in bin/. A copy that could not be
        /// read in full is never the same.
        public func sameParts(as other: ClaudePlugin?) -> Bool {
            guard let mine = partsFingerprint, let theirs = other?.partsFingerprint else { return false }
            return mine == theirs
        }

        /// The manifest has a name without spaces. Claude Code 2.1.280 loads the folder as a plugin only
        /// then, and otherwise only the plain skill (hand check H2). The default still goes by
        /// `runsNothing` and `startsPrograms`, which don't count on it: a later version may load more.
        public var loadsAsPlugin: Bool { declaredName.map(SkillPackage.isUsableName) ?? false }

        /// Its plugin.json could not be read: nothing is known about its name, so it counts as a plugin that
        /// loads and starts programs (KTD13), not as one without a usable name.
        public var manifestUnread: Bool { unread.contains { $0.file == manifest } }

        /// Claude Code loads it as a plugin, or may: its name is usable, or its manifest could not be read.
        public var mayLoadAsPlugin: Bool { loadsAsPlugin || manifestUnread }

        /// What it runs is only programs in bin/, which Claude Code puts on its shell's PATH and doesn't start
        /// (hand check H6).
        public var programsOnly: Bool {
            programCount > 0 && serverCount == 0 && partCounts.isEmpty && unknownKeys.isEmpty && unread.isEmpty && outside.isEmpty
        }

        /// Whether Claude Code starts it on, given `"<name>@skills-dir"` in `enabledPlugins` (nil: not
        /// there). The key wins; without it, the manifest's `defaultEnabled` decides.
        public func start(key value: Bool?) -> Start {
            if let value { return value ? .on : .offByKey }
            return defaultEnabled ? .on : .offByManifest
        }
    }

    /// How a Claude Code plugin starts once it is added.
    public enum Start: Equatable, Sendable {
        case on
        /// Off only because its manifest says `"defaultEnabled": false`: a later version can change that.
        case offByManifest
        /// Off because the user's Claude Code settings hold `"<name>@skills-dir": false`. Claude Code then
        /// loads nothing from the folder, not even its skill (hand check H4).
        case offByKey
    }

    /// Readable names for Codex's namespace and Claude Code's plugin, read without the rest.
    public struct Names: Equatable, Sendable {
        /// Codex lists the skill as `$<codex>:<skill>`.
        public var codex: String?
        /// The Claude Code plugin's usable `name`.
        public var claude: String?
        /// The folder holds `.claude-plugin/plugin.json`.
        public var isClaudePlugin = false
    }

    public let manifests: [Manifest]
    public let claude: ClaudePlugin?
    /// Package manifests in subfolders, which agents don't adopt.
    public let nested: [String]
    /// A Claude Code manifest in a folder spelled otherwise (`.Claude-Plugin`), which Claude Code ignores.
    public let misspelled: [String]
    /// What the review flags about the package.
    public let flags: [SkillReview.Flag]

    /// Codex's namespace: the first manifest with a name, in Codex's order.
    public var codexName: String? {
        let order: [Kind] = [.agentPlugin, .codexPlugin, .claudePlugin, .cursorPlugin]
        for kind in order {
            if let name = manifests.first(where: { $0.kind == kind })?.name, !name.isEmpty { return name }
        }
        return nil
    }

    /// Claude Code's plugin name, when the folder is one.
    public var claudeName: String? { claude?.name }

    /// Some part of it runs by itself in an agent that loads it as a package (or may: other agents are
    /// not checked).
    public var runsPartsByItself: Bool {
        if claude?.startsPrograms == true { return true }
        return manifests.contains { $0.kind != .claudePlugin && (!$0.servers.isEmpty || !$0.hooks.isEmpty) }
    }

    /// Reads a skill folder's package manifests and, for Claude Code, its parts. Nil: no manifest at all.
    /// `home` expands `~` in the manifest's paths; without it they count as outside.
    public static func read(folder: String, folderName: String, home: String? = nil) -> SkillPackage? {
        let reader = PackageReader(folder: folder, home: home)
        var manifests: [Manifest] = []
        var claude: ClaudePlugin?
        var flags: [SkillReview.Flag] = []
        if reader.hasClaudeManifest {
            let (plugin, pluginFlags) = reader.readClaude(folderName: folderName)
            claude = plugin
            flags += pluginFlags
            manifests.append(Manifest(kind: .claudePlugin, file: plugin.manifest, agent: "Claude Code", name: plugin.declaredName,
                                      servers: [], hooks: [], unread: []))
        }
        for (kind, file) in reader.otherManifests() {
            let manifest = reader.readOther(kind, relative: file)
            manifests.append(manifest)
            flags += otherFlags(manifest)
        }
        let nested = reader.nestedManifests()
        let misspelled = reader.misspelledManifests()
        if manifests.isEmpty && nested.isEmpty && misspelled.isEmpty { return nil }
        for path in nested { flags.append(SkillReview.Flag(level: .note, file: path, text: nestedText)) }
        for path in misspelled { flags.append(SkillReview.Flag(level: .note, file: path, text: misspelledText)) }
        return SkillPackage(manifests: manifests, claude: claude, nested: nested, misspelled: misspelled, flags: flags)
    }

    /// The names only (Codex's namespace and Claude Code's plugin), for the inventory: opens at most four
    /// small manifests, never the parts.
    public static func names(folder: String) -> Names {
        let reader = PackageReader(folder: folder, home: nil)
        var names = Names()
        names.isClaudePlugin = reader.hasClaudeManifest
        let claude = names.isClaudePlugin ? reader.declaredName(".claude-plugin/plugin.json") : nil
        names.claude = claude.flatMap { isUsableName($0) ? $0 : nil }
        let root = reader.smallObject("plugin.json")
        let agentPlugin = root.flatMap { isAgentPlugins($0) ? nonEmpty($0["name"]) : nil }
        names.codex = agentPlugin ?? reader.declaredName(".codex-plugin/plugin.json") ?? claude ?? reader.declaredName(".cursor-plugin/plugin.json")
        return names
    }

    // MARK: names

    /// A name as Claude Code compares plugin names: NFC, then lowercased.
    public static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A name folded so look-alikes meet: NFKC, lowercased, and without `-`, `_`, `.` and spaces.
    public static func lookalike(_ name: String) -> String {
        let folded = name.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars.filter { !"-_. ".unicodeScalars.contains($0) && !$0.properties.isWhitespace }.map(Character.init))
    }

    public static func isASCII(_ name: String) -> Bool { name.unicodeScalars.allSatisfy(\.isASCII) }

    /// A plugin name Claude Code accepts: not empty, no spaces (hand check H2).
    static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    /// Commands a bin/ program could stand in for where they are not installed: Claude Code adds bin/ to
    /// the end of its shell's PATH (hand check H6).
    public static let commonCommands: Set<String> = ["git", "node", "npm", "npx", "python", "python3", "pip", "sh", "bash", "zsh",
                                                     "curl", "ssh", "gh", "make", "swift", "open", "sudo", "claude", "codex"]

    /// What a list leaves out: "and 10 more"; nil when nothing is.
    public static func more(_ hidden: Int) -> String? { hidden > 0 ? "and \(hidden) more" : nil }

    /// "a", "a and b", "a, b and c".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The items shown, then what the list leaves out: "a, b, and 3 more"; "a and b" when nothing is.
    public static func list(_ shown: [String], hidden: Int) -> String {
        guard let more = more(hidden) else { return list(shown) }
        return (shown + [more]).joined(separator: ", ")
    }

    static let agentPluginsSchema = "https://agent-plugins.org/schemas/"
    /// How many servers, parts, bin/ names and brought files are kept.
    static let cap = 20

    static func isAgentPlugins(_ object: [String: Any]) -> Bool {
        (object["$schema"] as? String)?.hasPrefix(agentPluginsSchema) == true
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A JSON boolean, never a number that Foundation would also read as one.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    static let nestedText = "A plugin or extension manifest in a subfolder. Claude Code reads only the one at the skill's root, so it loads nothing from this one; other agents were not checked."
    static let misspelledText = "Claude Code loads a plugin only from a folder spelled .claude-plugin, so it does not load this one as a plugin (as of October 2026). Other agents were not checked."
}

// MARK: - Flags

extension SkillPackage {
    static func warning(_ file: String, _ text: String) -> SkillReview.Flag {
        SkillReview.Flag(level: .warning, file: file, text: text)
    }

    /// "“a”, “b” and 3 more", each name on one line.
    static func quotedNames(_ names: [String], limit: Int = 5) -> String {
        let shown = names.prefix(limit).map { "“" + SkillReview.oneLine($0, limit: 60) + "”" }
        return list(Array(shown), hidden: names.count - shown.count)
    }

    static func otherFlags(_ manifest: Manifest) -> [SkillReview.Flag] {
        var flags: [SkillReview.Flag] = []
        var declares: [String] = []
        if !manifest.servers.isEmpty {
            let lead = manifest.servers.count == 1 ? "the MCP server " : "MCP servers "
            declares.append(lead + quotedNames(manifest.servers.map(\.name)))
        }
        if !manifest.hooks.isEmpty { declares.append("hooks") }
        if !declares.isEmpty {
            // "MCP servers “a” and “b”, and hooks", but "the MCP server “a” and hooks".
            let joiner = manifest.servers.count > 1 ? ", and " : " and "
            let text = "Also \(manifest.kind.title), with \(declares.joined(separator: joiner)). " + uncheckedBy(manifest.agent, what: "them")
            flags.append(warning(manifest.file, text))
        }
        for unread in manifest.unread {
            flags.append(warning(unread.file, "Next Term could not read it (\(unread.reason)). " + uncheckedBy(manifest.agent, what: "it")))
        }
        for server in manifest.servers where !isASCII(server.name) { flags.append(nonASCIIServer(server)) }
        return flags
    }

    /// "Next Term didn't check what Gemini CLI does with them." (`agent` may name two: "Copilot CLI and VS Code".)
    public static func uncheckedBy(_ agent: String, what: String) -> String {
        let verb = agent.contains(" and ") ? "do" : "does"
        return "Next Term didn't check what \(agent) \(verb) with \(what)."
    }

    static func nonASCIIServer(_ server: Server) -> SkillReview.Flag {
        let name = SkillReview.oneLine(server.name, limit: 60)
        return warning(server.file, "The MCP server name “\(name)” has letters outside ASCII, which can look like another name.")
    }

    /// What a Claude Code plugin starts by itself, counted: "1 MCP server and 2 hooks".
    static func startsSummary(_ plugin: ClaudePlugin) -> String {
        var said: [String] = []
        if plugin.serverCount > 0 { said.append(counted(plugin.serverCount, "MCP server", "MCP servers")) }
        let kinds: [(Part.Kind, String, String)] = [(.hook, "hook", "hooks"), (.monitor, "monitor", "monitors"), (.lspServer, "LSP server", "LSP servers")]
        for (kind, singular, plural) in kinds {
            if let count = plugin.partCounts[kind] { said.append(counted(count, singular, plural)) }
        }
        if plugin.programCount > 0 { said.append(counted(plugin.programCount, "program in bin/", "programs in bin/")) }
        if plugin.partCounts[.settings] != nil { said.append("a plugin settings.json") }
        if !plugin.unknownKeys.isEmpty {
            let keys = plugin.unknownKeys.prefix(5).map { SkillReview.oneLine($0, limit: 40) }
            said.append("keys Next Term does not check (" + keys.joined(separator: ", ") + (plugin.unknownKeys.count > 5 ? ", …" : "") + ")")
        }
        if !plugin.unread.isEmpty { said.append("files Next Term could not read") }
        if !plugin.outside.isEmpty { said.append("files outside the skill folder") }
        return list(said)
    }

    /// What a plugin brings beside the skill: "2 commands and 1 agent".
    static func bringsSummary(_ brings: [Brought]) -> String {
        let kinds: [(Brought.Kind, String, String)] = [(.agent, "agent", "agents"), (.command, "command", "commands"),
                                                       (.outputStyle, "output style", "output styles"), (.skill, "skill", "skills")]
        var said: [String] = []
        for (kind, singular, plural) in kinds {
            let count = brings.filter { $0.kind == kind }.count
            if count > 0 { said.append(counted(count, singular, plural)) }
        }
        return list(said)
    }

    static func claudeFlags(_ plugin: ClaudePlugin, allServers: [Server], allBrings: [Brought], programsFolder: String) -> [SkillReview.Flag] {
        var flags: [SkillReview.Flag] = []
        let name = SkillReview.oneLine(plugin.name, limit: 60)
        if plugin.startsPrograms {
            let text = "Also a Claude Code plugin, “\(name)”. Added to Claude Code, it runs parts by itself, without the agent asking you first: "
                + startsSummary(plugin) + "."
            flags.append(warning(plugin.manifest, text))
        } else if !plugin.runsNothing {
            let brought = bringsSummary(allBrings)
            let text = brought.isEmpty ? "Also a Claude Code plugin, “\(name)”, with keys or folders beyond this skill."
                : "Also a Claude Code plugin, “\(name)”. Added to Claude Code, it also brings \(brought)."
            flags.append(warning(plugin.manifest, text))
        }
        // Hand check H2: without a usable name, Claude Code loads only the plain skill. Not said when the
        // manifest itself could not be read: then nothing is known about it.
        if !plugin.loadsAsPlugin, !plugin.unread.contains(where: { $0.file == plugin.manifest }) {
            var text = "Its plugin.json has no usable name, so Claude Code loads the folder as a plain skill, not as a plugin (as of October 2026)."
            if !plugin.runsNothing { text += " Its parts are listed anyway, in case a later version loads them." }
            flags.append(SkillReview.Flag(level: .note, file: plugin.manifest, text: text))
        }
        if !isASCII(plugin.name) {
            flags.append(warning(plugin.manifest, "Its Claude Code plugin name “\(name)” has letters outside ASCII, which can look like another name."))
        }
        for server in allServers where !isASCII(server.name) { flags.append(nonASCIIServer(server)) }
        if !plugin.outside.isEmpty {
            let paths = plugin.outside.prefix(5).map { SkillReview.oneLine($0, limit: 80) }.joined(separator: ", ")
            let text = "Parts of its plugin lead outside the skill folder (\(paths)). Claude Code would read them from there, and they are not reviewed here."
            flags.append(warning(plugin.manifest, text))
        }
        for unread in plugin.unread {
            flags.append(warning(unread.file, "Next Term could not read it (\(unread.reason)), so it counts as a Claude Code part that may start programs."))
        }
        for command in plugin.commonCommands {
            let text = "Named like the command “\(command)”. Claude Code adds bin/ to the end of its shell's PATH, so where \(command) is not installed, this runs in its place."
            flags.append(warning(programsFolder + "/" + command, text))
        }
        return flags
    }
}

// MARK: - Reading

/// Reads one folder's manifests and parts. Every file is opened by its path, read only up to the review's
/// 5 MB cap, checked by `SkillJSONText` (no comments, no key twice), then read with type-checked casts:
/// anything else is listed as unread, never a crash.
struct PackageReader {
    let folder: String
    let realFolder: String
    let home: String?
    /// The folder's own entries, as spelled on disk.
    let entries: [String]

    static let rootVariable = "${CLAUDE_PLUGIN_ROOT}"

    /// The manifest keys that run nothing (KTD13), `defaultEnabled` included: it can only turn the plugin off.
    static let allowlist: Set<String> = ["$schema", "name", "displayName", "description", "version", "author", "homepage",
                                         "repository", "license", "keywords", "skills", "defaultEnabled"]
    /// What Claude Code reads beside the manifest; any of them makes a plugin more than its skill.
    static let componentPaths = [".mcp.json", ".lsp.json", "settings.json", "hooks", "bin", "monitors", "commands", "output-styles", "skills"]
    /// Each kind's default server file, read when its manifest names none.
    static let defaultServers: [SkillPackage.Kind: String] = [.cursorPlugin: "mcp.json", .agentPlugin: "mcp.json",
                                                              .kiroPower: "mcp.json", .junieExtension: "mcp/.mcp.json"]

    init(folder: String, home: String?) {
        self.folder = folder
        self.home = home
        realFolder = SkillReview.realPath(folder)
        entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    var hasClaudeManifest: Bool { entries.contains(".claude-plugin") && exists(".claude-plugin/plugin.json") }

    // MARK: files

    func full(_ relative: String) -> String {
        relative.isEmpty ? folder : (folder as NSString).appendingPathComponent(relative)
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(full(relative), &info) == 0
    }

    func isFolder(_ relative: String) -> Bool {
        var info = stat()
        return stat(full(relative), &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Where the path really ends is inside the folder.
    func staysInside(_ relative: String) -> Bool {
        let real = SkillReview.realPath(full(relative))
        return real == realFolder || real.hasPrefix(realFolder + "/")
    }

    /// The path as spelled on disk: `.MCP.json` for `.mcp.json` on a volume that ignores case.
    func spelling(_ relative: String) -> String {
        var parent = folder
        var spelled: [String] = []
        for piece in relative.split(separator: "/").map(String.init) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            let found = names.first { $0 == piece } ?? names.first { $0.caseInsensitiveCompare(piece) == .orderedSame } ?? piece
            spelled.append(found)
            parent = (parent as NSString).appendingPathComponent(found)
        }
        return spelled.joined(separator: "/")
    }

    /// Each link along a path, with where it points.
    func links(_ relative: String) -> [SkillPackage.Link] {
        var result: [SkillPackage.Link] = []
        var prefix: [String] = []
        for piece in relative.split(separator: "/").map(String.init) {
            prefix.append(piece)
            let path = prefix.joined(separator: "/")
            var info = stat()
            guard lstat(full(path), &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { continue }
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full(path))) ?? ""
            result.append(SkillPackage.Link(path: spelling(path), target: target))
        }
        return result
    }

    enum JSONRead {
        case missing
        case value(Any, file: String)
        case unread(SkillPackage.Unread)
    }

    /// A file's bytes, up to the cap; the reason when they can't be had.
    func contents(_ relative: String) -> Result<Data, SkillPackage.Unread>? {
        let path = full(relative)
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let file = spelling(relative)
        guard stat(path, &info) == 0 else { return .failure(SkillPackage.Unread(file: file, reason: "it is a link to nothing")) }
        guard staysInside(relative) else { return .failure(SkillPackage.Unread(file: file, reason: "it leads outside the skill folder")) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(SkillPackage.Unread(file: file, reason: "it is not a file")) }
        guard Int(info.st_size) <= SkillReview.maxReadSize else { return .failure(SkillPackage.Unread(file: file, reason: "it is larger than 5 MB")) }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(SkillPackage.Unread(file: file, reason: "it could not be opened"))
        }
        return .success(data)
    }

    func json(_ relative: String) -> JSONRead {
        guard let contents = contents(relative) else { return .missing }
        let file = spelling(relative)
        let data: Data
        switch contents {
        case .failure(let unread): return .unread(unread)
        case .success(let bytes): data = bytes
        }
        switch SkillJSONText.parse(data) {
        case .failure(let problem):
            return .unread(SkillPackage.Unread(file: file, reason: problem.reason))
        case .success(let node):
            if let key = SkillJSONText.duplicateKey(in: node) {
                return .unread(SkillPackage.Unread(file: file, reason: "it has the key “\(SkillReview.oneLine(key, limit: 60))” twice"))
            }
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .unread(SkillPackage.Unread(file: file, reason: "it is not valid JSON"))
        }
        return .value(value, file: file)
    }

    /// A small JSON object's members, for names: nil when it is missing, large or not an object.
    func smallObject(_ relative: String) -> [String: Any]? {
        guard case .success(let data) = contents(relative) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func declaredName(_ relative: String) -> String? { SkillPackage.nonEmpty(smallObject(relative)?["name"]) }

    func text(_ relative: String) -> String? {
        guard case .success(let data) = contents(relative) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A path a manifest names, relative to the folder, as Claude Code reads it: `${CLAUDE_PLUGIN_ROOT}`
    /// is the folder and `~` the home folder. Nil: it leads outside, as written or on disk. Absolute
    /// paths and other variables count as outside.
    func inside(_ declared: String) -> String? {
        var rest = Substring(declared)
        var base = folder
        if rest.hasPrefix(Self.rootVariable) {
            rest = rest.dropFirst(Self.rootVariable.count)
            // `${CLAUDE_PLUGIN_ROOT}-x` is a sibling of the folder once expanded.
            guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        } else if rest == "~" || rest.hasPrefix("~/") {
            guard let home else { return nil }
            rest = rest.dropFirst()
            base = home
        } else if rest.isEmpty || rest.hasPrefix("/") {
            return nil
        }
        // Another variable (`${HOME}`, `$CLAUDE_PLUGIN_ROOT`) can't be worked out here.
        if rest.contains("$") { return nil }
        guard let parts = Self.components(base + "/" + rest), let root = Self.components(folder) else { return nil }
        guard parts.starts(with: root) else { return nil }
        let relative = parts.dropFirst(root.count).joined(separator: "/")
        if exists(relative), !staysInside(relative) { return nil }
        return relative
    }

    /// A path's components with `.` and `..` worked out as written; nil when `..` climbs above the root.
    static func components(_ path: String) -> [String]? {
        var parts: [String] = []
        for piece in path.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
                continue
            }
            parts.append(String(piece))
        }
        return parts
    }

    // MARK: manifests

    /// The root manifests other than Claude Code's, with their paths, in a fixed order.
    func otherManifests() -> [(SkillPackage.Kind, String)] {
        var found: [(SkillPackage.Kind, String)] = []
        let simple: [(SkillPackage.Kind, String)] = [(.codexPlugin, ".codex-plugin/plugin.json"), (.cursorPlugin, ".cursor-plugin/plugin.json"),
                                                     (.copilotPlugin, ".plugin/plugin.json"), (.copilotPlugin, ".github/plugin/plugin.json")]
        for (kind, path) in simple where exists(path) { found.append((kind, path)) }
        if let root = smallObject("plugin.json"), SkillPackage.isAgentPlugins(root) { found.append((.agentPlugin, "plugin.json")) }
        if exists("gemini-extension.json") { found.append((.geminiExtension, "gemini-extension.json")) }
        if exists("qwen-extension.json") { found.append((.qwenExtension, "qwen-extension.json")) }
        if exists("extension.json"), exists("mcp/.mcp.json") || isFolder("guidelines") { found.append((.junieExtension, "extension.json")) }
        if exists("POWER.md") { found.append((.kiroPower, "POWER.md")) }
        return found
    }

    func readOther(_ kind: SkillPackage.Kind, relative: String) -> SkillPackage.Manifest {
        var found = Found()
        let file = spelling(relative)
        var name: String?
        var declaresServers = false
        if kind == .kiroPower {
            name = text(relative).flatMap(SkillFrontMatter.parse)?.name
        } else {
            switch json(relative) {
            case .missing: break
            case .unread(let unread): found.unread.append(unread)
            case .value(let value, _):
                guard let object = value as? [String: Any] else {
                    found.couldNotRead(file, "it is not a JSON object")
                    break
                }
                name = object["name"] as? String
                if let servers = object["mcpServers"] {
                    declaresServers = true
                    readServers(servers, file: file, into: &found)
                }
                if object["hooks"] != nil { found.hookFiles.append(file) }
            }
        }
        if !declaresServers, let defaultFile = Self.defaultServers[kind] { readServers(defaultFile, file: file, into: &found) }
        if exists("hooks/hooks.json") { found.hookFiles.append(spelling("hooks/hooks.json")) }
        for path in found.outside { found.couldNotRead(file, "it names a path outside the skill folder (\(SkillReview.oneLine(path, limit: 80)))") }
        let agent = kind == .copilotPlugin && relative.hasPrefix(".github") ? "Copilot CLI" : Self.agent(kind)
        return SkillPackage.Manifest(kind: kind, file: file, agent: agent, name: name, servers: found.servers, hooks: found.hookFiles,
                                     unread: found.uniqueUnread)
    }

    static func agent(_ kind: SkillPackage.Kind) -> String {
        switch kind {
        case .claudePlugin: return "Claude Code"
        case .codexPlugin: return "Codex"
        case .cursorPlugin: return "Cursor"
        case .copilotPlugin: return "Copilot CLI and VS Code"
        case .agentPlugin: return "Agent Plugins"
        case .geminiExtension: return "Gemini CLI"
        case .qwenExtension: return "Qwen Code"
        case .junieExtension: return "Junie"
        case .kiroPower: return "Kiro"
        }
    }

    /// Package manifests below the root, which no agent adopts (at most 20).
    func nestedManifests() -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        let suffixes = ["/.claude-plugin/plugin.json", "/.codex-plugin/plugin.json", "/.cursor-plugin/plugin.json", "/.plugin/plugin.json",
                        "/.github/plugin/plugin.json", "/gemini-extension.json", "/qwen-extension.json", "/power.md"]
        var found: [String] = []
        while let relative = walker.nextObject() as? String, found.count < SkillPackage.cap {
            let name = (relative as NSString).lastPathComponent
            if name == ".git" || name == "node_modules" {
                walker.skipDescendants()
                continue
            }
            let lower = relative.lowercased()
            if suffixes.contains(where: { lower.hasSuffix($0) }) { found.append(relative) }
        }
        return found.sorted()
    }

    /// `.Claude-Plugin/plugin.json` and the like: a folder Claude Code does not adopt.
    func misspelledManifests() -> [String] {
        var found: [String] = []
        for entry in entries where entry != ".claude-plugin" && entry.lowercased() == ".claude-plugin" {
            if exists(entry + "/plugin.json") { found.append(spelling(entry + "/plugin.json")) }
        }
        return found.sorted()
    }
}

extension PackageReader {
    /// What a reader has found so far.
    struct Found {
        var servers: [SkillPackage.Server] = []
        var parts: [SkillPackage.Part] = []
        var programs: [String] = []
        var brings: [(SkillPackage.Brought.Kind, String)] = []
        var unknownKeys: [String] = []
        var outside: [String] = []
        /// An outside path names servers, hooks, monitors or LSP servers.
        var outsideRuns = false
        var unread: [SkillPackage.Unread] = []
        var links: [SkillPackage.Link] = []
        var hookFiles: [String] = []
        /// Files already read, by what they were read for, so one named twice is listed once.
        var read: Set<String> = []

        mutating func couldNotRead(_ file: String, _ reason: String = "it has entries Next Term could not read") {
            unread.append(SkillPackage.Unread(file: file, reason: reason))
        }

        mutating func leadsOutside(_ path: String, runs: Bool) {
            if !outside.contains(path) { outside.append(path) }
            if runs { outsideRuns = true }
        }

        var uniqueUnread: [SkillPackage.Unread] {
            var seen = Set<String>()
            return unread.filter { seen.insert($0.file + "\u{0}" + $0.reason).inserted }
        }

        var uniqueLinks: [SkillPackage.Link] {
            var seen = Set<String>()
            return links.filter { seen.insert($0.path).inserted }
        }
    }
}

// MARK: - Servers, hooks, monitors, LSP servers

extension PackageReader {
    /// `mcpServers` as a path, an inline map, a `.mcpb` or `.dxt` path or address, or a list of these.
    func readServers(_ value: Any, file: String, into found: inout Found, depth: Int = 0) {
        if let path = value as? String {
            readServerPath(path, file: file, into: &found)
        } else if let map = value as? [String: Any] {
            readServerMap(map, file: file, into: &found)
        } else if let list = value as? [Any], depth == 0 {
            for item in list { readServers(item, file: file, into: &found, depth: 1) }
        } else {
            found.couldNotRead(file, "its mcpServers is not a path, a map or a list")
        }
    }

    func readServerPath(_ path: String, file: String, into found: inout Found) {
        let address = Self.isWebAddress(path)
        if Self.isBundle(path, address: address) {
            found.servers.append(Self.bundleServer(path, address: address, file: file))
            guard !address else { return }
            if let relative = inside(path) { found.links += links(relative) } else { found.leadsOutside(path, runs: true) }
            return
        }
        guard !address else {
            found.couldNotRead(file, "it names MCP servers at a web address (\(SkillReview.oneLine(path, limit: 80)))")
            return
        }
        guard let relative = inside(path) else { return found.leadsOutside(path, runs: true) }
        found.links += links(relative)
        guard found.read.insert("servers:" + spelling(relative)).inserted else { return }
        switch json(relative) {
        case .missing: break
        case .unread(let unread): found.unread.append(unread)
        case .value(let content, let spelled):
            guard let object = content as? [String: Any] else { return found.couldNotRead(spelled, "it is not a JSON object") }
            if let inner = object["mcpServers"] {
                guard let map = inner as? [String: Any] else { return found.couldNotRead(spelled) }
                readServerMap(map, file: spelled, into: &found)
            } else {
                readServerMap(object, file: spelled, into: &found)
            }
        }
    }

    func readServerMap(_ map: [String: Any], file: String, into found: inout Found) {
        for name in map.keys.sorted() {
            guard let config = map[name] as? [String: Any] else {
                found.couldNotRead(file)
                continue
            }
            found.servers.append(Self.server(name, config, file: file))
        }
    }

    static func server(_ name: String, _ config: [String: Any], file: String) -> SkillPackage.Server {
        let command = config["command"] as? String
        let url = (config["url"] as? String) ?? (config["httpUrl"] as? String) ?? (config["serverUrl"] as? String)
        let args = (config["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let type = (config["type"] as? String)?.lowercased()
        let transport: SkillPackage.Server.Transport
        switch type {
        case "stdio": transport = .stdio
        case "http", "streamable-http", "streamable_http", "streamablehttp": transport = .http
        case "sse": transport = .sse
        case nil: transport = command != nil || url == nil ? .stdio : .http
        case let other?: transport = .other(other)
        }
        return SkillPackage.Server(name: name, transport: transport, command: command, args: args, url: url, bundle: nil,
                                   headersHelper: config["headersHelper"] as? String, file: file)
    }

    static func isWebAddress(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    /// A `.mcpb` or `.dxt` file: for an address, its path before `?` or `#`.
    static func isBundle(_ path: String, address: Bool) -> Bool {
        var bare = Substring(path)
        if address, let end = bare.firstIndex(where: { $0 == "?" || $0 == "#" }) { bare = bare[..<end] }
        let lower = bare.lowercased()
        return lower.hasSuffix(".mcpb") || lower.hasSuffix(".dxt")
    }

    static func bundleServer(_ path: String, address: Bool, file: String) -> SkillPackage.Server {
        var bare = Substring(path)
        if address, let end = bare.firstIndex(where: { $0 == "?" || $0 == "#" }) { bare = bare[..<end] }
        let name = ((String(bare) as NSString).lastPathComponent as NSString).deletingPathExtension
        return SkillPackage.Server(name: name, transport: .bundle, command: nil, args: [], url: address ? path : nil, bundle: path,
                                   headersHelper: nil, file: file)
    }

    /// A manifest value that is a path to a JSON file, an inline value, or a list of these: `read` takes
    /// each inline or file value with the file it is in.
    func each(_ value: Any, file: String, what: String, into found: inout Found, depth: Int = 0,
              _ read: (Any, String, inout Found) -> Void) {
        if let path = value as? String {
            guard let relative = inside(path) else { return found.leadsOutside(path, runs: true) }
            found.links += links(relative)
            guard found.read.insert(what + ":" + spelling(relative)).inserted else { return }
            switch json(relative) {
            case .missing: break
            case .unread(let unread): found.unread.append(unread)
            case .value(let content, let spelled): read(content, spelled, &found)
            }
        } else if let list = value as? [Any], depth == 0 {
            for item in list { each(item, file: file, what: what, into: &found, depth: 1, read) }
        } else {
            read(value, file, &found)
        }
    }

    /// `{"hooks": {Event: [{matcher, hooks: [{type, command}]}]}}`, or the events map itself.
    func readHookEvents(_ value: Any, file: String, into found: inout Found) {
        guard let object = value as? [String: Any] else { return found.couldNotRead(file, "it is not a JSON object") }
        var events = object
        if let inner = object["hooks"] {
            guard let map = inner as? [String: Any] else { return found.couldNotRead(file) }
            events = map
        }
        for event in events.keys.sorted() {
            guard let groups = events[event] as? [Any] else {
                found.couldNotRead(file)
                continue
            }
            for group in groups { readHookGroup(group, event: event, file: file, into: &found) }
        }
    }

    func readHookGroup(_ group: Any, event: String, file: String, into found: inout Found) {
        guard let group = group as? [String: Any], let hooks = group["hooks"] as? [Any] else { return found.couldNotRead(file) }
        var name = event
        if let matcher = group["matcher"] as? String, !matcher.isEmpty { name += " (\(matcher))" }
        for hook in hooks {
            guard let hook = hook as? [String: Any] else {
                found.couldNotRead(file)
                continue
            }
            let type = hook["type"] as? String ?? "command"
            let command = type == "command" && hook["command"] is String
            found.parts.append(SkillPackage.Part(kind: .hook, name: name, detail: Self.hookDetail(hook), file: file, runsCommand: command))
        }
    }

    static func hookDetail(_ hook: [String: Any]) -> String {
        let type = (hook["type"] as? String) ?? "command"
        switch type {
        case "command": return (hook["command"] as? String) ?? "runs a command Next Term could not read"
        case "http": return "sends a web request to " + ((hook["url"] as? String) ?? "an address")
        case "mcp_tool": return "calls the MCP tool " + ((hook["server"] as? String) ?? "?") + " " + ((hook["tool"] as? String) ?? "?")
        case "prompt": return "asks a model"
        case "agent": return "runs an agent"
        default: return "runs a hook of the kind “\(type)”"
        }
    }

    /// Monitors as a list, a map of names, one monitor, or `{"monitors": …}`.
    func readMonitors(_ value: Any, file: String, into found: inout Found, depth: Int = 0) {
        guard depth < 3 else { return found.couldNotRead(file) }
        if let list = value as? [Any] {
            for item in list {
                guard let config = item as? [String: Any] else {
                    found.couldNotRead(file)
                    continue
                }
                found.parts.append(Self.commandPart(.monitor, config, key: nil, file: file))
            }
            return
        }
        guard let map = value as? [String: Any] else { return found.couldNotRead(file) }
        if map["command"] != nil { return found.parts.append(Self.commandPart(.monitor, map, key: nil, file: file)) }
        if let inner = map["monitors"] { return readMonitors(inner, file: file, into: &found, depth: depth + 1) }
        for key in map.keys.sorted() {
            guard let config = map[key] as? [String: Any] else {
                found.couldNotRead(file)
                continue
            }
            found.parts.append(Self.commandPart(.monitor, config, key: key, file: file))
        }
    }

    /// `{language: {command, args, …}}`, or `{"lspServers": …}`.
    func readLSP(_ value: Any, file: String, into found: inout Found) {
        guard var servers = value as? [String: Any] else { return found.couldNotRead(file, "it is not a JSON object") }
        if let inner = servers["lspServers"] {
            guard let map = inner as? [String: Any] else { return found.couldNotRead(file) }
            servers = map
        }
        for language in servers.keys.sorted() {
            guard let config = servers[language] as? [String: Any] else {
                found.couldNotRead(file)
                continue
            }
            found.parts.append(Self.commandPart(.lspServer, config, key: language, file: file))
        }
    }

    static func commandPart(_ kind: SkillPackage.Part.Kind, _ config: [String: Any], key: String?, file: String) -> SkillPackage.Part {
        let name = (config["name"] as? String) ?? key ?? kind.rawValue
        guard let command = config["command"] as? String else {
            return SkillPackage.Part(kind: kind, name: name, detail: "runs a command Next Term could not read", file: file, runsCommand: false)
        }
        let line = [command] + ((config["args"] as? [Any])?.compactMap { $0 as? String } ?? [])
        return SkillPackage.Part(kind: kind, name: name, detail: line.joined(separator: " "), file: file)
    }

    /// The plugin's own settings.json: what it sets that changes Claude Code's sessions.
    static func settingsDetail(_ object: [String: Any]) -> String {
        var said: [String] = []
        if let agent = object["agent"] as? String {
            said.append("makes its agent “\(agent)” the main agent")
        } else if object["agent"] != nil {
            said.append("sets the main agent")
        }
        if object["subagentStatusLine"] != nil || object["statusLine"] != nil { said.append("runs a status line command") }
        let others = object.keys.filter { !["agent", "subagentStatusLine", "statusLine"].contains($0) }.sorted()
        if !others.isEmpty { said.append("sets " + others.joined(separator: ", ")) }
        return said.isEmpty ? "sets nothing" : SkillPackage.list(said)
    }
}

// MARK: - The Claude Code plugin

extension PackageReader {
    func readClaude(folderName: String) -> (SkillPackage.ClaudePlugin, [SkillReview.Flag]) {
        var found = Found()
        let manifestPath = ".claude-plugin/plugin.json"
        let manifestFile = spelling(manifestPath)
        found.links += links(manifestPath)
        var manifest: [String: Any] = [:]
        switch json(manifestPath) {
        case .missing: found.couldNotRead(manifestFile, "it could not be opened")
        case .unread(let unread): found.unread.append(unread)
        case .value(let value, _):
            if let object = value as? [String: Any] { manifest = object } else { found.couldNotRead(manifestFile, "it is not a JSON object") }
        }
        readManifestKeys(manifest, file: manifestFile, into: &found)
        readDefaultParts(into: &found)
        return assemble(manifest, file: manifestFile, folderName: folderName, found: found)
    }

    func readManifestKeys(_ manifest: [String: Any], file: String, into found: inout Found) {
        for key in manifest.keys.sorted() {
            guard let value = manifest[key] else { continue }
            switch key {
            case "skills": readSkillPaths(value, file: file, into: &found)
            case _ where Self.allowlist.contains(key): continue
            case "mcpServers": readServers(value, file: file, into: &found)
            case "hooks": each(value, file: file, what: "hooks", into: &found) { readHookEvents($0, file: $1, into: &$2) }
            case "monitors": each(value, file: file, what: "monitors", into: &found) { readMonitors($0, file: $1, into: &$2) }
            case "lspServers": each(value, file: file, what: "lsp", into: &found) { readLSP($0, file: $1, into: &$2) }
            case "commands": readBroughtPaths(value, kind: .command, file: file, into: &found)
            case "agents": readBroughtPaths(value, kind: .agent, file: file, into: &found)
            case "outputStyles": readBroughtPaths(value, kind: .outputStyle, file: file, into: &found)
            case "experimental": readExperimental(value, file: file, into: &found)
            default: found.unknownKeys.append(key)
            }
        }
    }

    func readExperimental(_ value: Any, file: String, into found: inout Found) {
        guard let object = value as? [String: Any] else { return found.unknownKeys.append("experimental") }
        for key in object.keys.sorted() {
            guard key == "monitors", let monitors = object[key] else {
                found.unknownKeys.append("experimental." + key)
                continue
            }
            each(monitors, file: file, what: "monitors", into: &found) { readMonitors($0, file: $1, into: &$2) }
        }
    }

    /// What Claude Code reads beside the manifest by default.
    func readDefaultParts(into found: inout Found) {
        readServers(".mcp.json", file: ".mcp.json", into: &found)
        each("hooks/hooks.json", file: "hooks/hooks.json", what: "hooks", into: &found) { readHookEvents($0, file: $1, into: &$2) }
        each("monitors/monitors.json", file: "monitors/monitors.json", what: "monitors", into: &found) { readMonitors($0, file: $1, into: &$2) }
        each(".lsp.json", file: ".lsp.json", what: "lsp", into: &found) { readLSP($0, file: $1, into: &$2) }
        readSettings(into: &found)
        readPrograms(into: &found)
        let folders: [(SkillPackage.Brought.Kind, String)] = [(.command, "commands"), (.agent, "agents"), (.outputStyle, "output-styles")]
        for (kind, path) in folders where exists(path) { collectBrought(kind, relative: path, into: &found) }
        if exists("skills") { collectSkills(relative: "skills", into: &found) }
    }

    func readSettings(into found: inout Found) {
        guard exists("settings.json") else { return }
        found.links += links("settings.json")
        switch json("settings.json") {
        case .missing: break
        case .unread(let unread): found.unread.append(unread)
        case .value(let value, let file):
            guard let object = value as? [String: Any] else { return found.couldNotRead(file, "it is not a JSON object") }
            found.parts.append(SkillPackage.Part(kind: .settings, name: file, detail: Self.settingsDetail(object), file: file, runsCommand: false))
        }
    }

    /// The names in bin/, which Claude Code adds to its shell's PATH.
    func readPrograms(into found: inout Found) {
        guard exists("bin") else { return }
        found.links += links("bin")
        guard staysInside("bin") else { return found.leadsOutside("bin", runs: true) }
        guard isFolder("bin") else { return }
        let folder = spelling("bin")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: full("bin"))) ?? []
        for name in names.sorted() where name != ".DS_Store" && !isFolder("bin/" + name) {
            found.programs.append(name)
            var info = stat()
            if lstat(full("bin/" + name), &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full("bin/" + name))) ?? ""
                found.links.append(SkillPackage.Link(path: folder + "/" + name, target: target))
            }
        }
    }

    /// A path or a list of paths; nil for anything else.
    static func pathList(_ value: Any) -> [String]? {
        if let path = value as? String { return [path] }
        guard let list = value as? [Any] else { return nil }
        let paths = list.compactMap { $0 as? String }
        return paths.count == list.count ? paths : nil
    }

    /// `commands`, `agents` or `outputStyles` in the manifest: a path or a list of paths.
    func readBroughtPaths(_ value: Any, kind: SkillPackage.Brought.Kind, file: String, into found: inout Found) {
        guard let paths = Self.pathList(value) else { return found.couldNotRead(file, "a path list Next Term could not read") }
        for path in paths {
            guard let relative = inside(path) else {
                found.leadsOutside(path, runs: false)
                continue
            }
            collectBrought(kind, relative: relative, into: &found)
        }
    }

    /// `skills` in the manifest: folders that hold a skill, or hold skill folders. The root is the skill
    /// under review, not something it brings.
    func readSkillPaths(_ value: Any, file: String, into found: inout Found) {
        guard let paths = Self.pathList(value) else { return found.couldNotRead(file, "a path list Next Term could not read") }
        for path in paths {
            guard let relative = inside(path) else {
                found.leadsOutside(path, runs: false)
                continue
            }
            if !relative.isEmpty { collectSkills(relative: relative, into: &found) }
        }
    }

    /// A file, or every Markdown file in a folder and its subfolders. Agents only count as Markdown, so
    /// Codex's `agents/openai.yaml` is not one.
    func collectBrought(_ kind: SkillPackage.Brought.Kind, relative: String, into found: inout Found) {
        found.links += links(relative)
        guard staysInside(relative) else { return found.leadsOutside(relative, runs: false) }
        let base = spelling(relative)
        guard isFolder(relative) else {
            if exists(relative) { found.brings.append((kind, base)) }
            return
        }
        let walker = FileManager.default.enumerator(atPath: full(relative))
        while let sub = walker?.nextObject() as? String {
            guard (sub as NSString).pathExtension.lowercased() == "md", !isFolder(relative + "/" + sub) else { continue }
            found.brings.append((kind, base + "/" + sub))
        }
    }

    /// A folder holding SKILL.md, or folders that each hold one.
    func collectSkills(relative: String, into found: inout Found) {
        found.links += links(relative)
        guard staysInside(relative) else { return found.leadsOutside(relative, runs: false) }
        if exists(relative + "/SKILL.md") { return found.brings.append((.skill, spelling(relative + "/SKILL.md"))) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: full(relative))) ?? []
        for name in names.sorted() where exists(relative + "/" + name + "/SKILL.md") {
            found.brings.append((.skill, spelling(relative + "/" + name + "/SKILL.md")))
        }
    }

    /// "What it may do" for a brought skill or command; nothing for agents and output styles.
    func broughtCapabilities(_ kind: SkillPackage.Brought.Kind, file: String) -> [String] {
        guard kind == .skill || kind == .command, let text = text(file) else { return [] }
        return SkillReview.capabilities(front: SkillFrontMatter.parse(text), skillText: text, files: [])
    }

    func assemble(_ manifest: [String: Any], file: String, folderName: String, found: Found) -> (SkillPackage.ClaudePlugin, [SkillReview.Flag]) {
        let declared = manifest["name"] as? String
        let name = declared.flatMap { SkillPackage.isUsableName($0) ? $0 : nil } ?? folderName
        var seen = Set<String>()
        let brought = found.brings.filter { seen.insert($0.1).inserted }.sorted { $0.1 < $1.1 }
        let shownBrought = brought.prefix(SkillPackage.cap).map {
            SkillPackage.Brought(kind: $0.0, file: $0.1, capabilities: broughtCapabilities($0.0, file: $0.1))
        }
        let allBrought = brought.map { SkillPackage.Brought(kind: $0.0, file: $0.1, capabilities: []) }
        var counts: [SkillPackage.Part.Kind: Int] = [:]
        for part in found.parts { counts[part.kind, default: 0] += 1 }
        let unread = found.uniqueUnread
        let allowlisted = Set(manifest.keys).isSubset(of: Self.allowlist)
        let components = Self.componentPaths.contains { exists($0) } || brought.contains { $0.0 == .agent }
        let runsNothing = allowlisted && !components && found.outside.isEmpty && unread.isEmpty && found.unknownKeys.isEmpty
        let starts = !found.servers.isEmpty || !found.parts.isEmpty || !found.programs.isEmpty
        let startsPrograms = starts || !found.unknownKeys.isEmpty || !unread.isEmpty || found.outsideRuns
        let plugin = SkillPackage.ClaudePlugin(
            manifest: file, name: name, declaredName: declared, displayName: manifest["displayName"] as? String,
            defaultEnabled: SkillPackage.bool(manifest["defaultEnabled"]) != false,
            servers: Array(found.servers.prefix(SkillPackage.cap)), serverCount: found.servers.count,
            parts: Array(found.parts.prefix(SkillPackage.cap)), partCounts: counts,
            programs: Array(found.programs.prefix(SkillPackage.cap)), programCount: found.programs.count,
            commonCommands: found.programs.filter(SkillPackage.commonCommands.contains),
            unknownKeys: found.unknownKeys, brings: shownBrought, bringCount: brought.count, links: found.uniqueLinks,
            outside: found.outside, unread: unread, runsNothing: runsNothing, startsPrograms: startsPrograms,
            partsFingerprint: partsFingerprint(manifest, file: file, found: found))
        let flags = SkillPackage.claudeFlags(plugin, allServers: found.servers, allBrings: allBrought, programsFolder: spelling("bin"))
        return (plugin, flags)
    }

    /// What a plugin declares that starts by itself, as one digest: the manifest's keys outside the
    /// allowlist, the bytes of every file that declares a server, hook, monitor, LSP server or plugin
    /// settings, the bytes of each MCP bundle in the folder (the server itself), and each program in bin/,
    /// by name and bytes. Nil when something could not be read or leads outside: then no two copies count
    /// as the same. A file that declares none of these (a hooks.json with no hooks) does not count.
    func partsFingerprint(_ manifest: [String: Any], file: String, found: Found) -> String? {
        guard found.unread.isEmpty, found.outside.isEmpty else { return nil }
        let declared = manifest.filter { !Self.allowlist.contains($0.key) }
        guard let keys = try? JSONSerialization.data(withJSONObject: declared, options: [.sortedKeys]) else { return nil }
        var hasher = SHA256()
        hasher.update(data: keys)
        let declaring = Set(found.servers.map(\.file) + found.parts.map(\.file)).subtracting([file])
        for path in declaring.sorted() {
            guard case .success(let data)? = contents(path) else { return nil }
            hasher.update(data: Data("\u{0}file\u{0}\(path)\u{0}".utf8))
            hasher.update(data: Data(SHA256.hash(data: data)))
        }
        let bundles = found.servers.compactMap { $0.url == nil ? $0.bundle : nil }
        for path in Set(bundles).sorted() {
            guard let relative = inside(path), let digest = digest(relative) else { return nil }
            hasher.update(data: Data("\u{0}bundle\u{0}\(path)\u{0}\(digest)".utf8))
        }
        for name in found.programs {
            guard let digest = digest("bin/" + name) else { return nil }
            hasher.update(data: Data("\u{0}bin\u{0}\(name)\u{0}\(digest)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A file's bytes as a digest, read in pieces, so a large bundle or program counts too. Nil for
    /// anything but a file inside the folder (a link out, a folder, a pipe).
    func digest(_ relative: String) -> String? {
        let path = full(relative)
        var info = stat()
        guard staysInside(relative), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return SkillHash.fileDigest(path)
    }
}
