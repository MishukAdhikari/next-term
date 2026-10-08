import Foundation

// The review's rows about what else a skill folder is and the MCP servers it brings, as the review sheet
// shows them, and the line beside Claude Code's popup. Text only: the facts come from SkillPackage,
// SkillServers and the install plan, all read offline. Text from the skill's files goes through
// SkillReview.oneLine, so hidden characters and line breaks are written out.

public enum SkillReviewText {
    /// What a plugin that starts something does once added, in the words of the review and the popup's line.
    static let startsBelow = "it starts the programs below every time Claude Code opens, without asking you."
    static let declaresNothing = "It declares nothing that starts by itself."

    // MARK: the Claude Code plugin

    /// The plugin block: what it is, whether it starts anything by itself and how it starts, the plugins of
    /// the user's it clashes with (the install plan's), the parts reached through links, then what it would
    /// start and what else it brings. `start`: from the user's key, else the manifest.
    public static func pluginBlock(_ plugin: SkillPackage.ClaudePlugin, start: SkillPackage.Start,
                                   clashes: [SkillInstall.Clash]) -> [String] {
        var lines = [lead(plugin, start: start)]
        for clash in clashes { lines.append((clash.warning ? "⚠︎ " : "• ") + clash.text) }
        if let links = linksLine(plugin.links) { lines.append(links) }
        let starts = startsItems(plugin)
        if !starts.isEmpty {
            lines.append("It would start:")
            lines += starts.map { "• " + $0 }
        }
        let brings = bringsItems(plugin)
        if !brings.isEmpty {
            lines.append("It also brings:")
            lines += brings.map { "• " + $0 }
        }
        return lines
    }

    /// "Also a Claude Code plugin, “x” (.claude-plugin/plugin.json). If you add it … It starts on."
    static func lead(_ plugin: SkillPackage.ClaudePlugin, start: SkillPackage.Start) -> String {
        var first = "Also a Claude Code plugin, \(quoted(plugin.name)) (\(SkillReview.oneLine(plugin.manifest, limit: 120)))"
        if let display = plugin.displayName, !display.isEmpty, display != plugin.name { first += ", shown as " + quoted(display) }
        var sentences = [first + "."]
        // A manifest that can't be read says nothing about its name: it counts as one that starts programs.
        let manifestUnread = plugin.unread.contains { $0.file == plugin.manifest }
        let loads = plugin.loadsAsPlugin || manifestUnread
        if !loads {
            // Hand check H2: Claude Code 2.1.280 loads only the plain skill then.
            var text = "Claude Code loads only its skill, not its plugin, because its plugin.json has no usable name (as of October 2026)."
            if plugin.startsPrograms { text += " A later version may start the programs below." }
            sentences.append(text)
        } else if plugin.startsPrograms {
            sentences.append("If you add it to Claude Code, " + startsBelow)
        } else {
            sentences.append(declaresNothing)
        }
        let key = quoted(SkillClaudeSettings.key(plugin.name))
        switch start {
        case .offByKey:
            sentences.append("Your Claude Code settings keep it off (\(key): false), so Claude Code loads nothing from it, not even its skill, "
                + "until you turn it on in /plugin.")
        case .offByManifest where loads && plugin.startsPrograms:
            sentences.append("It starts off only because its manifest says so. A later version can change that.")
        case .on where loads && plugin.startsPrograms:
            sentences.append("It starts on.")
        default:
            break
        }
        return sentences.joined(separator: " ")
    }

    /// "Links inside the folder: bin is a link to tools; …"
    static func linksLine(_ links: [SkillPackage.Link]) -> String? {
        guard !links.isEmpty else { return nil }
        var said = links.prefix(SkillPackage.cap).map { link in
            SkillReview.oneLine(link.path, limit: 120) + " is a link to " + SkillReview.oneLine(link.target, limit: 120)
        }
        if let more = SkillPackage.more(links.count - said.count) { said.append(more) }
        return "Links inside the folder: " + said.joined(separator: "; ") + "."
    }

    /// One item per kind of part that starts by itself (or may), each with its gloss and its files. Every
    /// reason `startsPrograms` can be true has an item, so "the programs below" always names something.
    static func startsItems(_ plugin: SkillPackage.ClaudePlugin) -> [String] {
        var items: [String] = []
        if plugin.serverCount > 0 {
            let head = plugin.serverCount == 1 ? "An MCP server, a program or web service that gives the agent tools"
                : "\(plugin.serverCount) MCP servers, programs or web services that give the agent tools"
            let servers = SkillServers.described(plugin.servers, count: plugin.serverCount)
            items.append(head + from(plugin.servers.map(\.file)) + ": " + servers)
        }
        let kinds: [SkillPackage.Part.Kind] = [.hook, .monitor, .lspServer, .settings]
        for kind in kinds {
            if let item = partsItem(plugin, kind: kind) { items.append(item) }
        }
        if plugin.programCount > 0 {
            let head = plugin.programCount == 1 ? "A program in bin/, which Claude Code's shell can run by name"
                : "\(plugin.programCount) programs in bin/, which Claude Code's shell can run by name"
            let names = plugin.programs.map { SkillReview.oneLine($0, limit: 60) }
            items.append(head + ": " + SkillPackage.list(names, hidden: plugin.programCount - names.count) + ".")
        }
        if !plugin.unknownKeys.isEmpty {
            let keys = plugin.unknownKeys.prefix(SkillPackage.cap).map { SkillReview.oneLine($0, limit: 60) }
            items.append("Keys in its plugin.json that Next Term does not check: " + SkillPackage.list(keys, hidden: plugin.unknownKeys.count - keys.count) + ".")
        }
        if !plugin.unread.isEmpty {
            let files = plugin.unread.prefix(SkillPackage.cap).map { unread in
                SkillReview.oneLine(unread.file, limit: 120) + " (" + SkillReview.oneLine(unread.reason, limit: 120) + ")"
            }
            let text = "Files Next Term could not read, which count as parts that may start programs: "
            items.append(text + SkillPackage.list(files, hidden: plugin.unread.count - files.count) + ".")
        }
        if !plugin.outside.isEmpty {
            let paths = plugin.outside.prefix(SkillPackage.cap).map { SkillReview.oneLine($0, limit: 120) }
            let text = "Paths outside the skill folder, which Claude Code would read from there and which are not reviewed here: "
            items.append(text + SkillPackage.list(paths, hidden: plugin.outside.count - paths.count) + ".")
        }
        return items
    }

    /// One kind of part: "2 hooks, commands that run on Claude Code events, from hooks/hooks.json: …".
    static func partsItem(_ plugin: SkillPackage.ClaudePlugin, kind: SkillPackage.Part.Kind) -> String? {
        let count = plugin.partCounts[kind] ?? 0
        guard count > 0 else { return nil }
        let shown = plugin.parts.filter { $0.kind == kind }
        let hidden = SkillPackage.more(count - shown.count)
        if kind == .settings {
            let said = shown.map { "it " + SkillReview.oneLine($0.detail, limit: 200) } + (hidden.map { [$0] } ?? [])
            return "Its settings.json, which can make a plugin agent the main agent or run a status line command: " + said.joined(separator: "; ") + "."
        }
        let said = shown.map(describe) + (hidden.map { [$0] } ?? [])
        return heading(kind, count: count) + from(shown.map(\.file)) + ": " + said.joined(separator: "; ") + "."
    }

    static func heading(_ kind: SkillPackage.Part.Kind, count: Int) -> String {
        let one = count == 1
        switch kind {
        case .hook: return one ? "A hook, a command that runs on Claude Code events" : "\(count) hooks, commands that run on Claude Code events"
        case .monitor:
            return one ? "A monitor, a program that keeps running in the background" : "\(count) monitors, programs that keep running in the background"
        case .lspServer:
            return one ? "An LSP server, a program that reads code as Claude Code edits it" : "\(count) LSP servers, programs that read code as Claude Code edits it"
        case .settings: return "Its settings.json"
        }
    }

    /// A hook by its event, a monitor or language server by its name: "Stop runs `say done`".
    static func describe(_ part: SkillPackage.Part) -> String {
        let name = part.kind == .hook ? SkillReview.oneLine(part.name, limit: 80) : quoted(part.name)
        let detail = SkillReview.oneLine(part.detail, limit: 160)
        return part.runsCommand ? name + " runs `" + detail + "`" : name + " " + detail
    }

    /// The agents, commands, output styles and skills it brings, each skill and command with its "What it
    /// may do" checks.
    static func bringsItems(_ plugin: SkillPackage.ClaudePlugin) -> [String] {
        var items = plugin.brings.map { brought -> String in
            let said = SkillReview.oneLine(brought.file, limit: 120) + ", " + article(brought.kind)
            guard !brought.capabilities.isEmpty else { return said + "." }
            let checks = brought.capabilities.map { sentence(SkillReview.oneLine($0, limit: 300)) }
            return said + ": " + checks.joined(separator: " ")
        }
        if let more = SkillPackage.more(plugin.bringCount - plugin.brings.count) { items.append(more + ".") }
        return items
    }

    static func article(_ kind: SkillPackage.Brought.Kind) -> String {
        switch kind {
        case .agent: return "an agent"
        case .command: return "a command"
        case .outputStyle: return "an output style"
        case .skill: return "a skill"
        }
    }

    // MARK: other packages

    /// "Also a Gemini CLI extension (gemini-extension.json), with MCP servers “a” and “b”.", one line per
    /// manifest other than Claude Code's, then once: "Not checked for other agents."
    public static func otherPackages(_ package: SkillPackage) -> [String] {
        let others = package.manifests.filter { $0.kind != .claudePlugin }
        guard !others.isEmpty else { return [] }
        return others.map(otherLine) + ["Not checked for other agents."]
    }

    static func otherLine(_ manifest: SkillPackage.Manifest) -> String {
        var declares: [String] = []
        if !manifest.servers.isEmpty {
            let lead = manifest.servers.count == 1 ? "the MCP server " : "MCP servers "
            declares.append(lead + SkillPackage.quotedNames(manifest.servers.map(\.name)))
        }
        if !manifest.hooks.isEmpty { declares.append("hooks") }
        let said = "Also \(manifest.kind.title) (\(SkillReview.oneLine(manifest.file, limit: 120)))"
        guard !declares.isEmpty else { return said + "." }
        // "MCP servers “a” and “b”, and hooks", but "the MCP server “a” and hooks".
        let joiner = manifest.servers.count > 1 ? ", and " : " and "
        return said + ", with " + declares.joined(separator: joiner) + "."
    }

    // MARK: Needs MCP servers

    /// "Needs MCP servers:", one line per agent that would use the skill's servers (the tables Codex would
    /// add indented under its line), then what Next Term does with them. Empty when no agent would use one.
    public static func serverRows(_ servers: SkillServers, choice: SkillInstall.ClaudeLink, start: SkillPackage.Start,
                                  codex: SkillServers.CodexConfig, trigger: String) -> [String] {
        let lines = servers.lines(choice: choice, start: start, codex: codex, trigger: trigger)
        guard !lines.isEmpty else { return [] }
        var rows = ["Needs MCP servers:"]
        for line in lines {
            rows.append("• " + line.text)
            rows += line.preview.map { "    " + $0 }
        }
        rows.append(SkillServers.closing)
        return rows
    }

    // MARK: Claude Code's popup

    /// The popup's two items, leave out (or remove the link) then add, in the plural for several folders.
    public static func choiceItems(count: Int, removesLink: Bool) -> [String] {
        if count > 1 {
            return [removesLink ? "Remove them from Claude Code" : "Leave them out of Claude Code", "Add them to Claude Code as plugins"]
        }
        return [removesLink ? "Remove it from Claude Code" : "Leave it out of Claude Code", "Add it to Claude Code as a plugin"]
    }

    /// What Install does about one plugin folder, for the line beside the popup: "writing-helper: linked. It
    /// starts the programs below …". `keptLink`: a link to the shared copy is there now. `clashes`: the
    /// install plan's.
    public static func choiceLine(skill: String, plugin: SkillPackage.ClaudePlugin, choice: SkillInstall.ClaudeLink,
                                  start: SkillPackage.Start, keptLink: Bool, clashes: [SkillInstall.Clash]) -> String {
        let name = SkillReview.oneLine(skill, limit: 60)
        guard choice == .link else {
            let left = keptLink ? "its link is removed, so Claude Code doesn't load it" : "not linked"
            return "\(name): \(left). npx skills update may link it again."
        }
        let linked = name + (keptLink ? ": stays linked" : ": linked")
        if start == .offByKey {
            let key = quoted(SkillClaudeSettings.key(plugin.name))
            return "\(linked). Your Claude Code settings keep it off (\(key): false) until you turn it on in /plugin."
        }
        let manifestUnread = plugin.unread.contains { $0.file == plugin.manifest }
        if !plugin.loadsAsPlugin, !manifestUnread {
            return "\(linked) as a plain skill. Claude Code doesn't load its plugin, because its plugin.json has no usable name (as of October 2026)."
        }
        // Hand check H7: an installed plugin of the same name wins, even turned off.
        if let installed = clashes.first(where: { $0.kind == .installed }) {
            return "\(linked) as a plain skill. Claude Code keeps your installed plugin \(quoted(installed.name)) and doesn't load this one as a plugin."
        }
        guard plugin.startsPrograms else { return "\(linked). " + declaresNothing }
        if start == .offByManifest { return "\(linked). Its manifest starts it off; once it is on, " + startsBelow }
        return "\(linked). It starts the programs below every time Claude Code opens, without asking you."
    }

    // MARK: Settings › Skills

    /// A question Settings › Skills asks before it acts: its title, its text, and the button that goes ahead.
    public struct Question: Equatable, Sendable {
        public let title: String
        public let text: String
        public let button: String
    }

    /// Link's last line, unless the user's key already keeps the plugin off.
    public static let linkClosing = "Next Term changes none of Claude Code's settings: to keep an added plugin off, turn it off in Claude Code's /plugin."

    /// What Link asks before it links a plugin folder for Claude Code (R10): the lead line, the plugins its
    /// name meets, then what it would start. "Add with Its Programs" when it starts something (or may),
    /// "Add as Plugin" when only a clash asks.
    public static func linkQuestion(_ link: SkillInstall.PluginLink) -> Question {
        var lines = [lead(link.plugin, start: link.start)]
        for clash in link.clashes { lines.append((clash.warning ? "⚠︎ " : "• ") + clash.text) }
        let starts = startsItems(link.plugin)
        if !starts.isEmpty {
            lines.append("It would start:")
            lines += starts.map { "• " + $0 }
        }
        if link.start != .offByKey { lines.append(linkClosing) }
        let title = "Add " + quoted(link.skill) + " to Claude Code?"
        let button = link.plugin.startsPrograms ? "Add with Its Programs" : "Add as Plugin"
        return Question(title: title, text: lines.joined(separator: "\n"), button: button)
    }

    /// Unify's step when the copy it keeps is a Claude Code plugin left out of Claude Code.
    public static let unifyLeftOut = "Claude Code loses this skill: the copy kept is also a Claude Code plugin, left out of Claude Code"

    // MARK: words

    /// " from a and b", or nothing for no file.
    static func from(_ files: [String]) -> String {
        var unique: [String] = []
        for file in files where !unique.contains(file) { unique.append(file) }
        guard !unique.isEmpty else { return "" }
        return ", from " + SkillPackage.list(unique.map { SkillReview.oneLine($0, limit: 120) })
    }

    static func quoted(_ text: String) -> String { "“" + SkillReview.oneLine(text, limit: 60) + "”" }

    /// The text with a full stop, unless it ends with one.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }
}
