import Foundation

// apply_setup (claudedocs/research_first-run-setup_2026-11-02, R3): settings, the layout and an import asked for in one
// call and approved in one window on the Mac, instead of an ask for each. Here is what the call takes, the rows the window
// shows and what they count, and the snapshot Next Term › Undo Agent Setup puts back. The app supplies the values in use
// now and applies only what the user ticked. Secrets, agent control, other apps' files and shell profiles are never part
// of it: the settings are settings_set's allowlist, the layout is set_layout's, and an import changes only Next Term.

public enum AgentSetup {
    /// The arguments apply_setup takes; any other is refused.
    public static let arguments: Set<String> = ["settings", "layout", "import", "reason", "request_id"]
    /// What `import` takes: preview_import's source (or path and format), and apply_import's items and plan_id.
    public static let importArguments: Set<String> = ["source", "path", "format", "project", "plan_id", "items"]

    /// Row ids: a setting (`setting:<name>`), a layout field (`layout:<argument>`), the import.
    public static func settingID(_ name: String) -> String { "setting:" + name }
    public static func layoutID(_ field: String) -> String { "layout:" + field }
    public static let importID = "import"

    // MARK: arguments

    /// What apply_setup was asked for: each part checked as its own tool checks it.
    public struct Asked {
        public var settings: [(MCPSettings.Setting, MCPSettings.Value)] = []
        public var layout: MCPLayoutChange?
        /// The layout's project, for its per-window fields (sidebar, terminal_folded), as set_layout takes it.
        public var layoutArguments: [String: Any] = [:]
        /// The import, as apply_import takes it (items and plan_id included).
        public var importArguments: [String: Any]?
        public var importAsked: MCPImport.Asked?
        public var reason: String?
        public var requestID: String?

        public init() {}

        public var isEmpty: Bool { settings.isEmpty && layout == nil && importAsked == nil }
    }

    /// The call's arguments: at least one of settings, layout and import, each valid as settings_set, set_layout and
    /// apply_import take it, and nothing set twice. A font family is looked up in `fonts` and a folder checked with
    /// `folderExists`; tests pass their own.
    public static func parse(_ arguments: [String: Any], fonts: FontCatalog = .system,
                             folderExists: (String) -> Bool = MCPSettings.isFolder) -> Result<Asked, MCPToolError> {
        MCPFileTools.catching {
            let args = MCPArguments(arguments)
            var asked = Asked()
            asked.requestID = try args.string("request_id")?.trimmingCharacters(in: .whitespaces).lowercased()
            asked.reason = try args.string("reason")
            if asked.requestID?.isEmpty == false { return asked }
            if let unknown = arguments.keys.sorted().first(where: { !Self.arguments.contains($0) }) {
                throw MCPToolError("apply_setup takes settings, layout, import and reason, not “\(MCPFileTools.cut(unknown))”; nothing was asked.")
            }
            if let raw = given(arguments["settings"]) {
                guard let values = raw as? [String: Any] else {
                    throw MCPToolError("settings is an object of setting names and values, as settings_set takes them; nothing was asked.")
                }
                for name in values.keys.sorted() where MCPSettings.setting(name) == nil && MCPLayoutChange.arguments.contains(name) {
                    throw MCPToolError("“\(name)” goes in layout, as set_layout takes it; nothing was asked.")
                }
                switch MCPSettings.changes(values, fonts: fonts, folderExists: folderExists) {
                case .failure(let error): throw MCPToolError(error.text.replacingOccurrences(of: "nothing was changed", with: "nothing was asked"))
                case .success(let changes): asked.settings = changes
                }
            }
            if let raw = given(arguments["layout"]) {
                guard let fields = raw as? [String: Any] else {
                    throw MCPToolError("layout is an object of set_layout's fields, such as {\"terminal_position\": \"right\"}; nothing was asked.")
                }
                let known = Set(MCPLayoutChange.arguments + ["project"])
                if let unknown = fields.keys.sorted().first(where: { !known.contains($0) }) {
                    throw MCPToolError("layout takes \(MCPLayoutChange.arguments.joined(separator: ", ")) and project, not “\(MCPFileTools.cut(unknown))”; nothing was asked.")
                }
                switch MCPLayoutChange.parse(fields) {
                case .failure(let error): throw error
                case .success(let change): asked.layout = change
                }
                asked.layoutArguments = fields.filter { $0.key == "project" }
            }
            if let raw = given(arguments["import"]) {
                guard let fields = raw as? [String: Any] else {
                    throw MCPToolError("import is an object with source (from list_import_sources), and items and plan_id as apply_import takes them; nothing was asked.")
                }
                if let unknown = fields.keys.sorted().first(where: { !importArguments.contains($0) }) {
                    throw MCPToolError("import takes \(importArguments.sorted().joined(separator: ", ")), not “\(MCPFileTools.cut(unknown))”; nothing was asked.")
                }
                switch MCPImport.Asked.parse(fields) {
                case .failure(let error): throw error
                case .success(let value): asked.importAsked = value
                }
                asked.importArguments = fields
            }
            guard !asked.isEmpty else {
                throw MCPToolError("Give at least one of settings (as settings_set takes them), layout (as set_layout) and import (as apply_import).")
            }
            if let twice = asked.settings.first(where: { !Set(keys(ofLayout: asked.layout)).isDisjoint(with: keys(ofSetting: $0.0.name)) }) {
                throw MCPToolError("\(twice.0.name) is in both settings and layout; give it once. Nothing was asked.")
            }
            return asked
        }
    }

    /// An argument given, not null: a client that names every argument changes only the rest.
    static func given(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    // MARK: what each part sets

    /// The saved keys (as an import's snapshot names them) that a settings_set setting changes; none for the
    /// notification and agent choices, which no import sets.
    public static func keys(ofSetting name: String) -> [String] {
        switch name {
        case "font_size": return ["fontSize"]
        case "line_height": return ["editorLineHeight"]
        case "soft_wrap": return ["softWrap"]
        case "terminal_font_family": return ["terminalFontFamily"]
        case "terminal_font_size": return ["terminalFontSize"]
        case "terminal_colours": return ["terminalPalette"]
        case "terminal_cursor": return ["terminalCursorShape"]
        case "terminal_cursor_blink": return ["terminalCursorBlink"]
        case "terminal_scrollback": return ["terminalScrollback"]
        case "new_tab_folder": return ["terminalStartFolder"]
        case "terminal_position": return ["terminalPosition"]
        case "open_projects_in": return ["openProjectsIn"]
        case "at_launch": return [LaunchSettings.Key.opens]
        case "sidebar_single_click": return ["sidebarSingleClickOpens"]
        case "shortcut_set": return ["keymapPreset"]
        default: return []
        }
    }

    /// The saved keys a layout change sets in every window; the per-window fields set none an import does.
    public static func keys(ofLayout change: MCPLayoutChange?) -> [String] {
        guard let change else { return [] }
        var keys: [String] = []
        if change.terminalPosition != nil { keys.append("terminalPosition") }
        if change.sidebarSide != nil { keys.append("sidebarSide") }
        if change.terminalTabs != nil { keys.append(TerminalTabsSetting.key) }
        return keys
    }

    /// The first thing set both by settings or the layout and by an import row (`importKeys`: each saved key the
    /// ticked import rows set, with its row id), as a refusal; nil when nothing is set twice. Set twice, Undo could not
    /// put back what was there before.
    public static func overlap(settings: [String], layout: MCPLayoutChange?, importKeys: [String: String]) -> MCPToolError? {
        for name in settings {
            for key in keys(ofSetting: name) {
                if let row = importKeys[key] {
                    return MCPToolError("\(name) is in settings and in the import (\(row)); give it once. Nothing was asked.")
                }
            }
        }
        let fields = ["terminalPosition": "terminal_position", "sidebarSide": "sidebar_side", TerminalTabsSetting.key: "terminal_tabs"]
        for key in keys(ofLayout: layout) {
            if let row = importKeys[key] {
                return MCPToolError("\(fields[key] ?? key) is in layout and in the import (\(row)); give it once. Nothing was asked.")
            }
        }
        return nil
    }

    // MARK: rows

    /// One row of the window: a tickable change, what it counts toward Apply N Changes, and a line under it.
    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public var detail: String?
        /// How many changes it makes (an import's rows, one for anything else).
        public var count: Int = 1

        public init(id: String, title: String, detail: String? = nil, count: Int = 1) {
            self.id = id
            self.title = title
            self.detail = detail
            self.count = count
        }
    }

    /// A setting's short name in a row, before its values.
    static let rowTitles: [String: String] = [
        "font_size": "Font size", "line_height": "Line height", "soft_wrap": "Soft wrap", "terminal_font_family": "Terminal font",
        "terminal_font_size": "Terminal font size", "terminal_colours": "Terminal colours", "terminal_cursor": "Terminal cursor",
        "terminal_cursor_blink": "Terminal cursor blinks", "terminal_scrollback": "Terminal scrollback",
        "new_tab_folder": "New tabs open in", "notify_decisions": "Notify when an agent needs a decision",
        "notify_agent_finished": "Notify when an agent finishes", "notify_program_alerts": "Notify on a program’s bell or notification",
        "notification_sound": "Sound with notifications", "notify_commands": "Notify when a command finishes",
        "notify_threshold_seconds": "Notify for finished work after", "agent_spinner": "Agent spinner",
        "agents_offer_tabs": "Agents offer tabs for parallel work", "agents_bring_tabs_forward": "When an agent opens a tab",
        "open_projects_in": "Open projects in", "at_launch": "At launch", "sidebar_single_click": "Single click opens in the sidebar",
        "shortcut_set": "Shortcut set", "terminal_position": "Terminal position",
    ]

    /// A setting's value in a row, in words: “on”, “14”, “the home folder”, “Next Term’s own”.
    public static func words(_ value: MCPSettings.Value, of name: String, home: String) -> String {
        switch (name, value) {
        case ("terminal_scrollback", .number(let lines)): return ImportRows.formatted(Int(lines)) + " lines"
        case ("notify_threshold_seconds", .number(let seconds)):
            return WorkThreshold(rawValue: Int(seconds))?.title ?? "\(Int(seconds)) seconds"
        case ("terminal_font_family", .choice(MCPSettings.defaultFont)): return "Next Term’s own"
        case ("terminal_font_size", .choice): return "the editor’s"
        case ("terminal_colours", .choice(let name)): return name == "imported" ? "imported" : "Next Term’s"
        case ("new_tab_folder", .choice(let folder)):
            switch folder {
            case "project": return "the project’s folder"
            case "current": return "the current tab’s folder"
            case "home": return "the home folder"
            default: return RecentProjects.abbreviate(folder, home: home)
            }
        case ("notify_commands", .choice("in_another_app")): return "while in another app"
        case ("open_projects_in", .choice(let name)): return ProjectOpening.Setting(mcpName: name)?.title.lowercased() ?? name
        case ("at_launch", .choice(let name)):
            guard let title = LaunchOpens(mcpName: name)?.title else { return name }
            return title.prefix(1).lowercased() + title.dropFirst()
        case ("agents_bring_tabs_forward", .choice(let name)):
            switch name {
            case "focus": return "its window comes forward and takes focus"
            case "show": return "its window comes forward"
            default: return "its window stays where it is"
            }
        case (_, .choice(let text)): return text.replacingOccurrences(of: "_", with: " ")
        default: return value.text
        }
    }

    /// A setting's row: “Font size 13 → 14”, “Soft wrap: on → off”, “Shortcuts: VS Code set”, “Terminal on the right”.
    public static func settingRow(_ setting: MCPSettings.Setting, now: MCPSettings.Value, new: MCPSettings.Value, home: String) -> Row {
        let id = settingID(setting.name)
        switch (setting.name, new) {
        case ("shortcut_set", .choice(let name)):
            let to = KeymapPreset(mcpName: name)?.name ?? name
            let from = now.text == name ? nil : (KeymapPreset(mcpName: now.text)?.name).map { "Replaces the \($0) set; your own shortcuts stay" }
            return Row(id: id, title: "Shortcuts: \(to) set", detail: from)
        case ("terminal_position", .choice(let side)):
            return Row(id: id, title: terminalPlace(side))
        default:
            let title = rowTitles[setting.name] ?? setting.title
            let from = words(now, of: setting.name, home: home), to = words(new, of: setting.name, home: home)
            if case .number = new, !["terminal_scrollback", "notify_threshold_seconds"].contains(setting.name) {
                return Row(id: id, title: "\(title) \(from) → \(to)")
            }
            return Row(id: id, title: "\(title): \(from) → \(to)")
        }
    }

    /// “Terminal on the right”, “Terminal at the bottom”.
    static func terminalPlace(_ side: String) -> String {
        side == "bottom" || side == "top" ? "Terminal at the \(side)" : "Terminal on the \(side)"
    }

    /// The layout's rows, in set_layout's order, for the fields that change something. `place`: the window the
    /// per-window fields go to (“the window of api”).
    public static func layoutRows(_ change: MCPLayoutChange, place: String) -> [Row] {
        var rows: [Row] = []
        if let side = change.terminalPosition { rows.append(Row(id: layoutID("terminal_position"), title: terminalPlace(side))) }
        if let side = change.sidebarSide { rows.append(Row(id: layoutID("sidebar_side"), title: "Project sidebar on the \(side)")) }
        if let tabs = change.terminalTabs {
            let title = tabs == TerminalTabsSetting.top.rawValue ? "Terminal tabs along the top" : "Terminal tabs in a list on the \(tabs)"
            rows.append(Row(id: layoutID("terminal_tabs"), title: title))
        }
        if let shown = change.windowColumnShown {
            rows.append(Row(id: layoutID("window_column"), title: shown ? "Window column shown" : "Window column hidden",
                            detail: "A badge for each open window at every window’s edge, while two or more are open"))
        }
        if let folded = change.windowColumnFolded {
            rows.append(Row(id: layoutID("window_column_folded"), title: folded ? "Window column folded" : "Window column unfolded"))
        }
        if let shown = change.sidebarShown {
            rows.append(Row(id: layoutID("sidebar"), title: "Project sidebar \(shown ? "shown" : "hidden") in \(place)"))
        }
        if let folded = change.terminalFolded {
            rows.append(Row(id: layoutID("terminal_folded"), title: "Terminal \(folded ? "folded" : "unfolded") in \(place)"))
        }
        return rows
    }

    /// The import's one row: “12 keys and 3 settings from Cursor; 3 have no equivalent”. `preset`: the shortcut set it
    /// switches to, when that is ticked; `changes`: what Apply counts for it (MCPImport.changes).
    public static func importRow(source: String, preset: KeymapPreset?, keys: Int, settings: Int, recents: Int,
                                 notBroughtOver: Int, changes: Int) -> Row {
        var parts: [String] = []
        if let preset { parts.append("the \(preset.name) shortcut set") }
        if keys > 0 { parts.append(keys == 1 ? "1 key" : "\(keys) keys") }
        if settings > 0 { parts.append(settings == 1 ? "1 setting" : "\(settings) settings") }
        if recents > 0 { parts.append(recents == 1 ? "1 recent project" : "\(recents) recent projects") }
        var title = (parts.isEmpty ? "Settings" : joined(parts)) + " from \(source)"
        if notBroughtOver > 0 { title += "; \(notBroughtOver) \(notBroughtOver == 1 ? "has" : "have") no equivalent" }
        title = title.prefix(1).uppercased() + title.dropFirst()
        return Row(id: importID, title: title, detail: "As Import Settings and Shortcuts… would bring them over", count: changes)
    }

    /// “a, b and c”.
    static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }

    /// What the ticked rows change, as Apply counts it.
    public static func count(_ rows: [Row], ticked: Set<String>) -> Int {
        rows.filter { ticked.contains($0.id) }.reduce(0) { $0 + $1.count }
    }

    /// The primary's title: “Apply 1 Change”, “Apply 9 Changes”; “Apply” with nothing ticked, when it is disabled.
    public static func applyTitle(_ count: Int) -> String {
        count == 0 ? "Apply" : "Apply \(count) Change\(count == 1 ? "" : "s")"
    }

    /// The fields of `change` whose row is ticked; the others left as they are.
    public static func only(_ change: MCPLayoutChange, ticked: Set<String>) -> MCPLayoutChange {
        func keep(_ field: String) -> Bool { ticked.contains(layoutID(field)) }
        return MCPLayoutChange(terminalPosition: keep("terminal_position") ? change.terminalPosition : nil,
                               sidebarSide: keep("sidebar_side") ? change.sidebarSide : nil,
                               terminalTabs: keep("terminal_tabs") ? change.terminalTabs : nil,
                               sidebarShown: keep("sidebar") ? change.sidebarShown : nil,
                               terminalFolded: keep("terminal_folded") ? change.terminalFolded : nil,
                               windowColumnShown: keep("window_column") ? change.windowColumnShown : nil,
                               windowColumnFolded: keep("window_column_folded") ? change.windowColumnFolded : nil)
    }

    /// Each field `change` sets, with its value as a snapshot keeps it: “right”, “shown”, “true”.
    public static func layoutValues(_ change: MCPLayoutChange) -> [(field: String, value: String)] {
        var values: [(String, String)] = []
        if let side = change.terminalPosition { values.append(("terminal_position", side)) }
        if let side = change.sidebarSide { values.append(("sidebar_side", side)) }
        if let tabs = change.terminalTabs { values.append(("terminal_tabs", tabs)) }
        if let shown = change.windowColumnShown { values.append(("window_column", shown ? "shown" : "hidden")) }
        if let folded = change.windowColumnFolded { values.append(("window_column_folded", String(folded))) }
        if let shown = change.sidebarShown { values.append(("sidebar", shown ? "shown" : "hidden")) }
        if let folded = change.terminalFolded { values.append(("terminal_folded", String(folded))) }
        return values
    }

    /// A change from snapshot values (`layoutValues`' form); a field it doesn't know is left out.
    public static func layoutChange(_ values: [(field: String, value: String)]) -> MCPLayoutChange {
        var change = MCPLayoutChange()
        for (field, value) in values {
            switch field {
            case "terminal_position": change.terminalPosition = value
            case "sidebar_side": change.sidebarSide = value
            case "terminal_tabs": change.terminalTabs = value
            case "window_column": change.windowColumnShown = value == "shown"
            case "window_column_folded": change.windowColumnFolded = value == "true"
            case "sidebar": change.sidebarShown = value == "shown"
            case "terminal_folded": change.terminalFolded = value == "true"
            default: continue
            }
        }
        return change
    }

    /// The layout fields that go to one window rather than every window.
    public static let perWindowFields: Set<String> = ["sidebar", "terminal_folded"]
}

/// What one apply_setup changed, each value as it was before and just after, so Next Term › Undo Agent Setup puts back
/// exactly those values (the import through Undo Import, while it is still the last one). Kept as JSON in the app's
/// `agentSetupSnapshot` key, so the menu item stays across relaunches; only the last setup is kept.
public struct AgentSetupSnapshot: Codable, Equatable, Sendable {
    public struct Setting: Codable, Equatable, Sendable {
        public let name: String
        public let before: MCPSettings.Value
        public let after: MCPSettings.Value

        public init(name: String, before: MCPSettings.Value, after: MCPSettings.Value) {
            self.name = name
            self.before = before
            self.after = after
        }
    }

    public struct Layout: Codable, Equatable, Sendable {
        /// set_layout's argument.
        public let field: String
        public let before: String
        public let after: String
        /// For a per-window field, the window's project (nil: a window with none).
        public let project: String?

        public init(field: String, before: String, after: String, project: String? = nil) {
            self.field = field
            self.before = before
            self.after = after
            self.project = project
        }
    }

    public let id: String
    public let date: Date
    /// Who asked, as the approval window named it (“the agent in the tab “codex” in api”).
    public let agent: String
    public let settings: [Setting]
    public let layout: [Layout]
    /// The import's undo_id (MCPImport.undoID), and the app it came from.
    public let importUndoID: String?
    public let importSource: String?
    /// The rows applied, as the window showed them.
    public let lines: [String]

    public init(id: String = UUID().uuidString, date: Date = Date(), agent: String, settings: [Setting], layout: [Layout],
                importUndoID: String?, importSource: String?, lines: [String]) {
        self.id = id
        self.date = date
        self.agent = agent
        self.settings = settings
        self.layout = layout
        self.importUndoID = importUndoID
        self.importSource = importSource
        self.lines = lines
    }

    /// The snapshot of an apply, or nil when it changed nothing: settings and layout fields whose value before and after
    /// are the same are left out.
    public static func applied(agent: String, settings: [Setting], layout: [Layout], importUndoID: String?, importSource: String?,
                               lines: [String], date: Date = Date()) -> AgentSetupSnapshot? {
        let settings = settings.filter { $0.before != $0.after }
        let layout = layout.filter { $0.before != $0.after }
        guard !settings.isEmpty || !layout.isEmpty || importUndoID != nil else { return nil }
        return AgentSetupSnapshot(date: date, agent: agent, settings: settings, layout: layout, importUndoID: importUndoID,
                                  importSource: importSource, lines: lines)
    }

    /// The settings and layout fields that hold something else now than just after the setup (`settings` and `layout`:
    /// their values today, by name and field), changed by hand since: Undo puts them back too.
    public func changedSince(settings current: [String: MCPSettings.Value], layout now: [String: String]) -> [String] {
        var names: [String] = []
        for setting in settings {
            guard let value = current[setting.name], !Self.same(value, setting.after) else { continue }
            names.append(setting.name)
        }
        for entry in layout {
            guard let value = now[entry.field], value != entry.after else { continue }
            names.append(entry.field)
        }
        return names
    }

    /// Two values of a setting mean the same: numbers within a thousandth, as settings_set compares them.
    public static func same(_ one: MCPSettings.Value, _ other: MCPSettings.Value) -> Bool {
        if case .number(let x) = one, case .number(let y) = other { return abs(x - y) < 0.001 }
        return one == other
    }

    /// The layout as it was before, for the fields to put back: those of every window, or those of one project's window.
    public func layoutBefore(perWindow: Bool, project: String? = nil) -> MCPLayoutChange {
        let entries = layout.filter { AgentSetup.perWindowFields.contains($0.field) == perWindow && (!perWindow || $0.project == project) }
        return AgentSetup.layoutChange(entries.map { ($0.field, $0.before) })
    }

    /// The projects whose windows had a per-window field changed.
    public var perWindowProjects: [String?] {
        var projects: [String?] = []
        for entry in layout where AgentSetup.perWindowFields.contains(entry.field) && !projects.contains(entry.project) {
            projects.append(entry.project)
        }
        return projects
    }

    /// How a setting or layout field is named in the undo alert (“Font size”, “Terminal position”).
    public static func title(of name: String) -> String {
        switch name {
        case "sidebar_side": return "Project sidebar side"
        case "terminal_tabs": return "Terminal tabs"
        case "window_column": return "Window column"
        case "window_column_folded": return "Window column folded"
        case "sidebar": return "Project sidebar"
        case "terminal_folded": return "Terminal folded"
        default: return AgentSetup.rowTitles[name] ?? name
        }
    }

    /// What the Undo Agent Setup alert says: what goes back, what was changed by hand since (`changedSince`: names from
    /// `changedSince(settings:layout:)`), and whether the import goes back too (`importIsLast`: it is still the import
    /// Undo Import would undo).
    public func undoMessage(changedSince: [String], importIsLast: Bool) -> String {
        var text = logLine() + ".\n\nThe settings and layout it changed go back to what they were before."
        if !changedSince.isEmpty {
            let names = changedSince.map(Self.title(of:))
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            text += " You changed \(names.count == 1 ? "this" : "these") since, and Undo puts \(names.count == 1 ? "it" : "them") back too: \(list)."
        }
        if let source = importSource, importUndoID != nil {
            text += importIsLast
                ? " The import from \(source) is undone too, as Undo Import does."
                : " The import from \(source) stays: a later import, or its own Undo, came after it."
        }
        return text
    }

    /// The change log line, for the menu item and the undo alert: “The agent in the tab “codex” in api changed font size
    /// 13 → 14 and 2 more, 2 Nov at 14:02”.
    public func logLine(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        let who = agent.prefix(1).uppercased() + agent.dropFirst()
        let first = lines.first.map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "settings"
        let more = lines.count > 1 ? " and \(lines.count - 1) more" : ""
        return "\(who) changed \(first)\(more), \(formatter.string(from: date))"
    }
}

// MARK: - the tool

extension MCPServer {
    /// apply_setup: its own list, as the import tools and add_task have, so the remote door's list of write tools stays as
    /// it is; local only. Used once in a while, so tool search finds it rather than keeping it loaded.
    public static let setupTools: [Tool] = [
        Tool(name: "apply_setup", title: "Ask to apply a setup plan",
             description: "Asks the user to apply a whole setup plan in one window on the Mac, instead of an ask for each part: settings (names and values as settings_set takes them), layout (set_layout's fields, with project for the per-window ones) and import (a source from list_import_sources, or path and format, with items and plan_id from preview_import, as apply_import takes them). Give one or more. The window names you and shows your reason, with a tickable row per change (\"Font size 13 → 14\", \"Terminal on the right\", \"Shortcuts: VS Code set\", and one row for the import) and Apply N Changes; the user may untick rows, and only the ticked ones change. Nothing may be set twice: a setting in settings and in layout, or in the import's ticked rows too, is refused. Answers within about 50 seconds: applied (the rows applied and skipped, the values now, the import's undo_id, and how to undo it), declined, stopped, busy, up_to_date (nothing would change; no window opens), changed_since_preview, or pending with a request_id: call again with only request_id to keep waiting. The window closes as a cancel after 10 minutes. Next Term › Undo Agent Setup… puts back all it changed, across relaunches; undo_import the import alone. Agent control, keys, other apps' files and shell profiles are never part of it. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {"settings": {"type": "object", "description": "Setting names and their new values, as settings_get lists them and settings_set takes them.", "minProperties": 1}, "layout": {"type": "object", "description": "set_layout's fields.", "properties": {"terminal_position": {"type": "string", "enum": ["bottom", "right", "left", "top"]}, "sidebar_side": {"type": "string", "enum": ["left", "right"]}, "terminal_tabs": {"type": "string", "enum": ["top", "left", "right"]}, "window_column": {"type": "string", "enum": ["shown", "hidden"]}, "window_column_folded": {"type": "boolean"}, "sidebar": {"type": "string", "enum": ["shown", "hidden"]}, "terminal_folded": {"type": "boolean"}, "project": {"type": "string", "description": "For sidebar and terminal_folded: an open project's folder or name. Default: your window's project, or the front one."}}, "additionalProperties": false}, "import": {"type": "object", "description": "An import, as apply_import takes it.", "properties": {"source": {"type": "string", "description": "A source's id (or name) from list_import_sources."}, "path": {"type": "string", "description": "Instead of source: a settings file in an open project, as preview_import reads it."}, "format": {"type": "string", "enum": ["vscode-settings", "vscode-keybindings"]}, "project": {"type": "string", "description": "With a relative path: an open project's folder or name."}, "items": {"type": "array", "items": {"type": "string"}, "maxItems": 300, "description": "Row ids from preview_import to tick. Default: the rows the preview ticks."}, "plan_id": {"type": "string", "description": "preview_import's plan_id: refused if the plan changed since."}}, "additionalProperties": false}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words in the window."}, "request_id": {"type": "string", "description": "A pending request's id, to keep waiting for the user's answer."}}, "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60, alwaysLoad: false),
    ]

    public static func isSetupTool(_ name: String) -> Bool { setupTools.contains { $0.name == name } }
}
