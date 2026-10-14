import Foundation

// What the import tools (MCPImportTools.swift) answer, worked out from the same plan the import window shows: the
// sources found, each preview row with an id apply_import can name, the plan's id, and the checks on what an agent
// asks for. The app supplies what only it knows (the keys and settings in use now); nothing here reads another
// app's files except through the importers, and nothing writes. Every answer goes through `text(_:home:hiding:)`:
// MCPRedaction, the home folder as ~, other users' homes and the apps' settings folders hidden.

public enum MCPImport {
    /// Row ids: the shortcut set, a setting (`set:<UserDefaults key>`), one of the user's shortcuts
    /// (`key:<command id>`), the recent projects.
    public static let presetID = "preset"
    public static let recentsID = "recents"
    public static func settingID(_ key: String) -> String { "set:" + key }
    public static func shortcutID(_ command: String) -> String { "key:" + command }

    /// The most rows one list in an answer holds; the rest are counted.
    public static let listLimit = 100
    /// The most recent projects named in a preview.
    public static let recentsShown = 8
    /// The largest file preview_import reads (the importers' own limit).
    public static let maxFileBytes = 4 << 20

    static let previewNote = "Nothing changes here: apply_import opens Next Term's import window with these rows, and only the user's Apply changes anything."

    // MARK: sources

    /// Each app's id: its name in lower case, words joined by dashes ("cursor", "phpstorm-2026.1"), unique in the list.
    public static func ids(of apps: [DetectedApp]) -> [String] {
        var used = Set<String>()
        return apps.map { app in
            let base = slug(app.name)
            var id = base
            var number = 2
            while used.contains(id) {
                id = base + "-" + String(number)
                number += 1
            }
            used.insert(id)
            return id
        }
    }

    static func slug(_ name: String) -> String {
        var slug = ""
        var gap = false
        for character in name.lowercased() {
            guard character.isLetter || character.isNumber || character == "." else {
                gap = true
                continue
            }
            if gap, !slug.isEmpty { slug.append("-") }
            gap = false
            slug.append(character)
        }
        return slug.isEmpty ? "app" : slug
    }

    /// The app a call names, by its id or its name (any case), with its id.
    public static func source(_ raw: String, in apps: [DetectedApp]) -> (id: String, app: DetectedApp)? {
        let ids = ids(of: apps)
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let index = ids.firstIndex(of: text.lowercased()) { return (ids[index], apps[index]) }
        guard let index = apps.firstIndex(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) else { return nil }
        return (ids[index], apps[index])
    }

    /// The last import's id for agents: its snapshot's id, or its date for a snapshot saved before ids.
    public static func undoID(_ snapshot: ImportSnapshot) -> String {
        if let id = snapshot.id { return "imp-" + id.lowercased() }
        return "imp-" + String(Int(snapshot.date.timeIntervalSince1970))
    }

    /// "2026-10-09", in this Mac's time zone.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The last import as list_import_sources and the answers name it.
    public static func lastImport(_ snapshot: ImportSnapshot?) -> Any {
        guard let snapshot else { return NSNull() }
        let info: [String: Any] = ["undo_id": undoID(snapshot), "source": snapshot.source, "summary": snapshot.summary,
                                   "date": day(snapshot.date)]
        return info
    }

    /// One app as list_import_sources gives it: what detection found (DetectedApp), no setting's value. Its settings folder
    /// is never named.
    static func describe(_ app: DetectedApp, id: String) -> [String: Any] {
        var info: [String: Any] = ["id": id, "name": app.name, "family": app.kind.family.rawValue]
        info["app_installed"] = !app.appRemoved
        info["last_used"] = app.lastUsed.map(day) ?? NSNull()
        info["shortcut_set"] = app.preset.name
        info["can_bring"] = app.kind.canBring.map(\.rawValue)
        info["not_used_lately"] = app.notUsedLately
        if let version = app.version { info["version"] = version }
        return info
    }

    /// list_import_sources' answer, without the targets (the app adds those).
    public static func listing(_ apps: [DetectedApp], currentPreset: KeymapPreset, last: ImportSnapshot?) -> [String: Any] {
        let ids = ids(of: apps)
        var answer: [String: Any] = [:]
        answer["sources"] = apps.indices.map { describe(apps[$0], id: ids[$0]) }
        answer["current_shortcut_set"] = currentPreset.name
        answer["last_import"] = lastImport(last)
        answer["file_formats"] = FileFormat.allCases.map(\.rawValue)
        answer["note"] = "Use preview_import, not these apps' files: those sit next to tokens, licence keys and account data."
        return answer
    }

    // MARK: targets

    /// What each setting an import can set takes, for list_import_sources' targets.
    public static let settingTargets: [(key: String, takes: String)] = [
        ("fontSize", "8 to 32 points: the editor's, and the terminal's while it has no size of its own"),
        ("terminalFontSize", "8 to 32 points: the terminal's own"),
        ("editorLineHeight", "1.0 to 2.0 times the font's line height, in steps of 0.05"),
        ("softWrap", "on or off"),
        ("optionAsMeta", "on or off"),
        ("terminalPosition", "bottom, right, left or top"),
        ("sidebarSide", "left or right"),
        (TerminalTabsSetting.key, "a list of the terminal’s tabs down its left or right, with the project sidebar’s side and Show Folders"),
        ("editorFontFamily", "an installed monospaced font"),
        ("terminalFontFamily", "an installed monospaced font"),
        ("terminalPalette", "16 colours with the text, background, cursor and selection colours"),
        ("terminalScrollback", "\(ImportRows.formatted(Scrollback.range.lowerBound)) to \(ImportRows.formatted(Scrollback.range.upperBound)) lines"),
        ("terminalStartFolder", "the project's folder, the current tab's folder, the home folder or another folder"),
        ("terminalCursorShape", "block, bar or underline"),
        ("terminalCursorBlink", "on or off"),
        ("trimTrailingWhitespace", "on or off"),
        ("insertFinalNewline", "on or off"),
        ("hiddenFilePatterns", "file name patterns, added to the user's own"),
        ("sidebarSingleClickOpens", "on or off"),
        ("backgroundFetch", FetchFrequency.allCases.map(\.title).joined(separator: ", ")),
        ("diffLayout", "side by side or unified"),
        ("currentLineBlame", "on or off"),
        ("openProjectsIn", "ask, this window or a new window"),
        (LaunchSettings.Key.opens, "the Welcome window or the projects that were open"),
    ]

    /// The settings and commands an import can set: `commands` are the app's (id, title, key now).
    public static func targets(commands: [(id: String, title: String, key: KeyChord?)]) -> [String: Any] {
        let settings: [[String: Any]] = settingTargets.map { target in
            ["id": settingID(target.key), "title": ImportSnapshot.title(of: target.key), "takes": target.takes]
        }
        let keys: [[String: Any]] = commands.map { command in
            ["id": shortcutID(command.id), "title": command.title, "key": command.key?.display ?? NSNull()]
        }
        return ["settings": settings, "commands": keys]
    }

    // MARK: rows

    /// The ids of a plan's settings and shortcut rows, in its order (a second row on the same key gets `#2`).
    public static func rowIDs(_ plan: ImportPlan) -> (settings: [String], shortcuts: [String]) {
        (unique(plan.settings.map { settingID($0.setting.key) }), unique(plan.shortcuts.map { shortcutID($0.command) }))
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return ids.map { id in
            seen[id, default: 0] += 1
            let count = seen[id] ?? 1
            return count == 1 ? id : id + "#" + String(count)
        }
    }

    /// The rows the window ticks at first: the shortcut set when it differs, and each row the importer ticks.
    public static func defaultTicks(_ plan: ImportPlan, currentPreset: KeymapPreset, newRecents: [String]) -> Set<String> {
        let ids = rowIDs(plan)
        var ticks = Set<String>()
        if plan.preset != currentPreset { ticks.insert(presetID) }
        for (index, row) in plan.settings.enumerated() where row.ticked { ticks.insert(ids.settings[index]) }
        for (index, row) in plan.shortcuts.enumerated() where row.ticked && row.allowed { ticks.insert(ids.shortcuts[index]) }
        if !newRecents.isEmpty { ticks.insert(recentsID) }
        return ticks
    }

    /// Every row id the plan offers, and the shortcut rows that can't be ticked, with why. The shortcut set and the
    /// recent projects can always be named: with nothing to change (the set in use, the projects listed already) they
    /// change nothing.
    public static func offered(_ plan: ImportPlan) -> (ids: Set<String>, refused: [String: String]) {
        let ids = rowIDs(plan)
        var offered = Set(ids.settings).union([presetID, recentsID])
        var refused: [String: String] = [:]
        for (index, row) in plan.shortcuts.enumerated() {
            offered.insert(ids.shortcuts[index])
            if !row.allowed { refused[ids.shortcuts[index]] = row.note ?? "no import takes this key" }
        }
        return (offered, refused)
    }

    /// The rows `items` names (nil: none named, so the preview's ticks), refused whole when one is unknown or can't
    /// be ticked.
    public static func items(_ raw: Any?, offered: Set<String>, refused: [String: String]) -> Result<Set<String>?, MCPToolError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else {
            return .failure(MCPToolError("items is a list of row ids from preview_import, such as [\"preset\", \"set:fontSize\"]."))
        }
        let names = list.compactMap { $0 as? String }
        guard !names.isEmpty else {
            return .failure(MCPToolError("items is empty; name the rows to tick, or leave items out for the preview's ticked rows."))
        }
        let unknown = names.filter { !offered.contains($0) }
        if !unknown.isEmpty {
            let valid = MCPProjects.listed(offered.sorted(), limit: 12)
            let rows = valid.isEmpty ? "none" : valid
            return .failure(MCPToolError("Not rows of this preview: \(MCPProjects.listed(unknown)). Its rows: \(rows). Nothing was asked."))
        }
        for name in names {
            if let why = refused[name] { return .failure(MCPToolError("\(name) can't be ticked: \(why). Nothing was asked.")) }
        }
        return .success(Set(names))
    }

    /// How many things ticking `ticks` would change, as the window's Apply button counts them, leaving out settings
    /// that already have the imported value.
    public static func changes(_ plan: ImportPlan, ticks: Set<String>, currentPreset: KeymapPreset, newRecents: [String],
                               isCurrent: (ImportedSetting) -> Bool) -> Int {
        let ids = rowIDs(plan)
        var count = 0
        if ticks.contains(presetID), plan.preset != currentPreset { count += plan.preset.overrides.count }
        for (index, row) in plan.settings.enumerated() where ticks.contains(ids.settings[index]) && !isCurrent(row.setting) {
            count += 1
        }
        for (index, row) in plan.shortcuts.enumerated() where ticks.contains(ids.shortcuts[index]) && row.allowed { count += 1 }
        if ticks.contains(recentsID), !newRecents.isEmpty { count += 1 }
        return count
    }

    /// What the user did to the rows the agent asked for: "set:softWrap unticked", "key:goToFile: ticked".
    public static func userChanged(asked: Set<String>, applied: Set<String>) -> [String] {
        applied.subtracting(asked).sorted().map { $0 + " ticked" } + asked.subtracting(applied).sorted().map { $0 + " unticked" }
    }

    /// The plan's id: a hash of every row as the importer read it, before it is settled against Next Term's
    /// shortcuts, so a change in the other app's files since the preview shows, while applying it (which changes
    /// only Next Term) keeps the id: asked again, it is up to date.
    public static func planID(_ plan: ImportPlan) -> String {
        var lines = ["preset " + plan.preset.rawValue]
        for row in plan.settings { lines.append("set \(row.setting.key) \(String(describing: row.setting)) \(row.ticked)") }
        for row in plan.shortcuts {
            lines.append("key \(row.command) \(row.chord?.display ?? "none") \(row.ticked) \(row.allowed)")
        }
        lines.append("recents " + plan.recentProjects.joined(separator: "|"))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "p-" + String(String(hash, radix: 16).suffix(12))
    }

    // MARK: preview

    /// What only the app knows, for a preview.
    public struct PreviewContext {
        public var currentPreset: KeymapPreset
        /// "Replace in Files   ⇧⌘R → ⇧⌘H" for each command the plan's shortcut set changes.
        public var presetLines: [String]
        /// Each command's key now, under the shortcut set the rows were settled for.
        public var keysNow: [String: KeyChord?]
        /// A setting row's title, as the window words it ("Editor font size 13 → 14 pt").
        public var title: (ImportedSetting) -> String
        /// Whether Next Term has this value already.
        public var isCurrent: (ImportedSetting) -> Bool
        /// Recent projects Next Term lists already.
        public var knownRecents: [String]
        public var home: String

        public init(currentPreset: KeymapPreset, presetLines: [String] = [], keysNow: [String: KeyChord?] = [:],
                    title: @escaping (ImportedSetting) -> String, isCurrent: @escaping (ImportedSetting) -> Bool = { _ in false },
                    knownRecents: [String] = [], home: String) {
            self.currentPreset = currentPreset
            self.presetLines = presetLines
            self.keysNow = keysNow
            self.title = title
            self.isCurrent = isCurrent
            self.knownRecents = knownRecents
            self.home = home
        }
    }

    /// The recent projects Next Term doesn't list yet.
    public static func newRecents(_ plan: ImportPlan, known: [String]) -> [String] {
        plan.recentProjects.filter { !known.contains($0) }
    }

    /// preview_import's answer for a plan settled under its own shortcut set: the window's rows with their ids.
    /// `planID`: the id of the plan as the importer made it (`planID(_:)`).
    public static func preview(source: String, plan: ImportPlan, planID: String, context: PreviewContext) -> [String: Any] {
        let recents = newRecents(plan, known: context.knownRecents)
        let ticks = defaultTicks(plan, currentPreset: context.currentPreset, newRecents: recents)
        let ids = rowIDs(plan)
        var answer: [String: Any] = ["source": source, "plan_id": planID]
        answer["shortcut_set"] = shortcutSet(plan, context: context)
        let shortcuts = plan.shortcuts.indices.map { shortcutRow(plan.shortcuts[$0], id: ids.shortcuts[$0], context: context) }
        answer["your_shortcuts"] = Array(shortcuts.prefix(listLimit))
        if shortcuts.count > listLimit { answer["your_shortcuts_more"] = shortcuts.count - listLimit }
        answer["settings"] = plan.settings.indices.map { settingRow(plan.settings[$0], id: ids.settings[$0], context: context) }
        if !recents.isEmpty {
            let shown = recents.prefix(recentsShown).map { RecentProjects.abbreviate($0, home: context.home) }
            answer["recent_projects"] = ["id": recentsID, "count": recents.count, "shown": Array(shown),
                                         "more": max(0, recents.count - recentsShown), "ticked": true] as [String: Any]
        }
        let skipped = plan.skipped.map(skippedRow)
        answer["not_brought_over"] = Array(skipped.prefix(listLimit))
        if skipped.count > listLimit { answer["not_brought_over_more"] = skipped.count - listLimit }
        let everything = Set(ids.settings + ids.shortcuts + [presetID, recentsID])
        let changing = changes(plan, ticks: ticks, currentPreset: context.currentPreset, newRecents: recents, isCurrent: context.isCurrent)
        answer["changes_if_applied"] = changing
        let any = changes(plan, ticks: everything, currentPreset: context.currentPreset, newRecents: recents, isCurrent: context.isCurrent)
        answer["up_to_date"] = any == 0
        answer["note"] = previewNote
        return answer
    }

    static func shortcutSet(_ plan: ImportPlan, context: PreviewContext) -> [String: Any] {
        guard plan.preset != context.currentPreset else { return ["to": plan.preset.name, "in_use": true] }
        return ["id": presetID, "to": plan.preset.name, "differs": plan.preset.overrides.count, "ticked": true,
                "lines": context.presetLines]
    }

    static func shortcutRow(_ row: PlannedShortcut, id: String, context: PreviewContext) -> [String: Any] {
        var info: [String: Any] = ["id": id, "title": row.title]
        info["now"] = (context.keysNow[row.command] ?? nil)?.display ?? "no key"
        info["new"] = row.chord?.display ?? "no key"
        info["ticked"] = row.ticked && row.allowed
        info["allowed"] = row.allowed
        info["from"] = shown(row.source)
        info["note"] = row.note.map(shown) ?? NSNull()
        return info
    }

    static func settingRow(_ row: PlannedSetting, id: String, context: PreviewContext) -> [String: Any] {
        var info: [String: Any] = ["id": id, "title": shown(context.title(row.setting))]
        info["from"] = shown(row.source)
        info["ticked"] = row.ticked
        info["note"] = row.note.map(shown) ?? NSNull()
        if context.isCurrent(row.setting) { info["already_set"] = true }
        // Colours by count, never their values.
        if case .terminalPalette(let palette) = row.setting { info["colours"] = colourCount(palette) }
        return info
    }

    static func colourCount(_ palette: TerminalPalette) -> Int {
        palette.ansi.compactMap { $0 }.count + [palette.foreground, palette.background, palette.cursor, palette.selection].compactMap { $0 }.count
    }

    /// A skipped item by name only, with its reason; a name that looks like a credential is never shown.
    static func skippedRow(_ item: SkippedItem) -> [String: Any] {
        ["item": SecretGuard.looksSecret(item.item) ? "(a name that looked like a credential)" : item.item, "reason": shown(item.reason)]
    }

    /// Text for an answer, unless it looks like a credential.
    static func shown(_ text: String) -> String { SecretGuard.looksSecret(text) ? "…" : text }

    // MARK: answers

    /// The answer as the agent gets it: JSON, with each settings folder in `hiding` named only as such, the home
    /// folder as ~, other users' homes as /Users/•••, and anything MCPRedaction finds masked.
    public static func text(_ value: Any, home: String, hiding: [String] = []) -> String {
        var text = MCPServer.json(value)
        for folder in hiding.sorted(by: { $0.count > $1.count }) where folder.count > 1 {
            text = text.replacingOccurrences(of: folder, with: "(its settings folder)")
        }
        text = paths(text, home: home)
        return MCPRedaction.redact(text).text
    }

    /// `home` as ~, and any other /Users/<name> as /Users/•••.
    static func paths(_ text: String, home: String) -> String {
        var text = text
        if home.count > 1 {
            let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?=/|"|\s|$)"#
            text = text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"/Users/[^/"\s]+"#, with: "/Users/•••", options: .regularExpression)
    }

    // MARK: arguments

    /// What preview_import and apply_import were asked: a source, or a file and its format.
    public struct Asked: Sendable {
        public var source: String?
        public var path: String?
        public var format: FileFormat?
        public var project: String?
        public var planID: String?
        public var reason: String?
        public var requestID: String?

        /// The arguments, each of its type; a source or a path with its format, not both.
        public static func parse(_ arguments: [String: Any]) -> Result<Asked, MCPToolError> {
            MCPFileTools.catching {
                let args = MCPArguments(arguments)
                var asked = Asked()
                asked.requestID = try args.string("request_id")?.trimmingCharacters(in: .whitespaces).lowercased()
                asked.reason = try args.string("reason")
                asked.planID = try args.string("plan_id")?.trimmingCharacters(in: .whitespaces)
                asked.project = try args.string("project")
                asked.source = try args.string("source")
                asked.path = try args.string("path")
                if let raw = try args.string("format") {
                    guard let format = FileFormat(rawValue: raw) else {
                        throw MCPToolError("format is one of \(FileFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    asked.format = format
                }
                if asked.requestID?.isEmpty == false { return asked }
                if asked.source != nil, asked.path != nil { throw MCPToolError("Give source or path, not both.") }
                if asked.path != nil, asked.format == nil {
                    throw MCPToolError("Give format with path: vscode-settings (a settings.json) or vscode-keybindings (a keybindings.json).")
                }
                if asked.source?.trimmingCharacters(in: .whitespaces).isEmpty != false, asked.path == nil {
                    throw MCPToolError("Give source: an id from list_import_sources (or path and format for a settings file in an open project).")
                }
                return asked
            }
        }
    }

    /// list_import_sources' include_targets.
    public static func includeTargets(_ arguments: [String: Any]) -> Result<Bool, MCPToolError> {
        MCPFileTools.catching { try MCPArguments(arguments).bool("include_targets", default: false) }
    }

    /// undo_import's undo_id (nil with a request_id), its reason and request_id.
    public static func undoAsked(_ arguments: [String: Any]) -> Result<(undoID: String?, reason: String?, requestID: String?), MCPToolError> {
        MCPFileTools.catching {
            let args = MCPArguments(arguments)
            let requestID = try args.string("request_id")?.trimmingCharacters(in: .whitespaces).lowercased()
            let undoID = try args.string("undo_id")?.trimmingCharacters(in: .whitespaces).lowercased()
            if requestID?.isEmpty != false, undoID?.isEmpty != false {
                throw MCPToolError("Give undo_id: the last import's, from list_import_sources.")
            }
            return (undoID, try args.string("reason"), requestID)
        }
    }

    /// A named file's text: at most 4 MB, text only. The size is checked before anything is read, as read_file
    /// does, and no more than the limit is ever read (the file may grow meanwhile).
    public static func read(_ file: ProjectFile) -> Result<String, MCPToolError> {
        let tooBig = MCPToolError("\(file.relative) is over 4 MB; settings files are smaller.")
        var info = stat()
        guard stat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(MCPToolError("Could not read \(file.relative)."))
        }
        guard info.st_size <= maxFileBytes else { return .failure(tooBig) }
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return .failure(MCPToolError("Could not read \(file.relative).")) }
        defer { try? handle.close() }
        guard let read = try? handle.read(upToCount: maxFileBytes + 1) else {
            return .failure(MCPToolError("Could not read \(file.relative)."))
        }
        guard read.count <= maxFileBytes else { return .failure(tooBig) }
        guard let decoded = TextFile.decode(read) else { return .failure(MCPToolError("\(file.relative) is not a text file.")) }
        return .success(decoded.text)
    }

    // MARK: a file an agent names

    /// The files preview_import reads by path, and what each is.
    public enum FileFormat: String, CaseIterable, Sendable {
        case vsCodeSettings = "vscode-settings"
        case vsCodeKeybindings = "vscode-keybindings"
    }

    /// Why rows from a file an agent names are left out (the agent may have written it).
    public static let notFromAFile = "not taken from a file an agent names"
    public static let projectSettingsNote = "a project's settings; in Next Term they apply to every window"

    /// A file's text as a plan. It never sets hidden files, where new tabs open or recent projects; a project's
    /// own `.vscode/settings.json` (`projectSettings`) starts with every row unticked. `preset`: the shortcut set in
    /// use, which a file never changes.
    public static func filePlan(text: String, format: FileFormat, name: String, preset: KeymapPreset, projectSettings: Bool,
                                usKeyboard: Bool, fonts: FontCatalog = .system, home: String) -> Result<ImportPlan, MCPToolError> {
        var plan = ImportPlan(preset: preset)
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        guard JSONC.plain(text)?.trimmingCharacters(in: blank).isEmpty != true else { return .success(plan) }
        switch format {
        case .vsCodeSettings:
            guard let file = ImportVSCode.SettingsFile(text) else {
                return .failure(MCPToolError("\(name) couldn't be read as a VS Code settings file (JSON with comments)."))
            }
            let result = ImportVSCode.settingsPlan(file, appName: name, usKeyboard: usKeyboard, fonts: fonts, home: home)
            for row in result.settings {
                switch row.setting {
                case .hiddenFiles, .terminalStartFolder:
                    plan.skipped.append(SkippedItem(row.source, notFromAFile))
                default:
                    let note = projectSettings ? ImportShortcuts.join(projectSettingsNote, row.note) : row.note
                    plan.settings.append(PlannedSetting(row.setting, source: row.source, ticked: row.ticked && !projectSettings, note: note))
                }
            }
            plan.skipped += result.skipped
        case .vsCodeKeybindings:
            guard let rules = ImportVSCode.rules(text) else {
                return .failure(MCPToolError("\(name) couldn't be read as a VS Code keybindings file (a JSON list with comments)."))
            }
            let keys = ImportVSCode.shortcuts(rules, usKeyboard: usKeyboard)
            plan.shortcuts = keys.shortcuts
            plan.skipped = keys.skipped
        }
        return .success(plan)
    }

    /// Whether a project file is that project's own VS Code settings.
    public static func isProjectSettings(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        return parts.count >= 2 && parts[parts.count - 2] == ".vscode" && parts[parts.count - 1] == "settings.json"
    }
}
