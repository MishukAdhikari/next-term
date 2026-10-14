import AppKit
import Carbon.HIToolbox
import NextTermCore

// "Coming from another app?": find the apps a switcher used, show exactly what would change, apply it
// only on Apply, and undo it in one click. Nothing changes for people who never import. The readers for
// each app live in NextTermCore (Import*.swift) and only read; this file is the app's side.

/// The apps on this Mac an import can read, and their plans.
enum ImportSources {
    /// Every app found, most recently used first, those not used lately (180 days) last. No setting is read yet
    /// beyond what DetectedApp names.
    static func detect() -> [DetectedApp] {
        var found = detectors.flatMap { $0() }
        for index in found.indices where DetectedApp.isNotUsedLately(found[index].lastUsed) { found[index].notUsedLately = true }
        return found.sorted { a, b in
            if a.notUsedLately != b.notUsedLately { return !a.notUsedLately }
            return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
        }
    }

    static func plan(for app: DetectedApp) -> ImportPlan {
        plan(for: app, usKeyboard: usesUSKeyboard)
    }

    /// The plan with the keyboard layout given (read on the main thread), so it can be made off it.
    static func plan(for app: DetectedApp, usKeyboard: Bool) -> ImportPlan {
        planner(app, usKeyboard) ?? ImportPlan(preset: app.preset)
    }

    static let noneFound = "No settings were found on this Mac from VS Code or an editor built on it (VS Code Insiders, VSCodium, "
        + "Cursor, Windsurf, Kiro, Trae and others), a JetBrains IDE, Zed, Sublime Text, iTerm2, Ghostty, cmux, kitty, Alacritty, "
        + "WezTerm, Kaku, Warp or a changed Terminal profile."

    /// Each family's reader (NextTermCore/Import*.swift). The self-test can swap these for its own.
    nonisolated(unsafe) static var detectors: [() -> [DetectedApp]] = [
        { ImportVSCode.detect() }, { ImportJetBrains.detect() }, { ImportZed.detect() }, { ImportITerm2.detect() },
        { ImportGhostty.detect() }, { ImportWarp.detect() }, { ImportTerminalApp.detect() }, { ImportKitty.detect() },
        { ImportAlacritty.detect() }, { ImportWezTerm.detect() }, { ImportCmux.detect() }, { ImportSublimeText.detect() },
    ]
    nonisolated(unsafe) static var planner: (DetectedApp, Bool) -> ImportPlan? = { app, usKeyboard in
        switch app.kind {
        case .vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop, .vsCodeFork:
            return ImportVSCode.plan(for: app, usKeyboard: usKeyboard)
        case .jetBrains: return ImportJetBrains.plan(for: app, usKeyboard: usKeyboard)
        case .zed: return ImportZed.plan(for: app, usKeyboard: usKeyboard)
        case .iTerm2: return ImportITerm2.plan(for: app, usKeyboard: usKeyboard)
        case .ghostty: return ImportGhostty.plan(for: app, usKeyboard: usKeyboard)
        case .warp: return ImportWarp.plan(for: app, usKeyboard: usKeyboard)
        case .terminalApp: return ImportTerminalApp.plan(for: app, usKeyboard: usKeyboard)
        case .kitty: return ImportKitty.plan(for: app, usKeyboard: usKeyboard)
        case .alacritty: return ImportAlacritty.plan(for: app, usKeyboard: usKeyboard)
        case .wezTerm, .kaku: return ImportWezTerm.plan(for: app, usKeyboard: usKeyboard)
        case .cmux: return ImportCmux.plan(for: app, usKeyboard: usKeyboard)
        case .sublimeText: return ImportSublimeText.plan(for: app, usKeyboard: usKeyboard)
        }
    }

    /// Option as Meta is offered ticked only on U.S.-style layouts: elsewhere Option types @ [ ] { }.
    static var usesUSKeyboard: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return true }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id == "com.apple.keylayout.US" || id == "com.apple.keylayout.ABC"
    }
}

/// What the user ticked in the preview.
struct ImportChoice {
    var usePreset: Bool
    var settings: [PlannedSetting]
    var shortcuts: [PlannedShortcut] = []
    var recentProjects: [String]
}

/// Applies an import (after a snapshot) and undoes the last one exactly.
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    /// UserDefaults keys the import changed, their values before and just after (NextTermCore/ImportUndo.swift).
    typealias Snapshot = ImportSnapshot

    private static let snapshotKey = "importSnapshot"
    static let changed = Notification.Name("NextTermImportChanged")

    var last: Snapshot? {
        get { UserDefaults.standard.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.snapshotKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// How many things an import would change, as an agent's preview counts them (MCPImport.changes): a ticked
    /// setting Next Term already has changes nothing, so it isn't counted.
    static func count(_ choice: ImportChoice, plan: ImportPlan) -> Int {
        let preset = choice.usePreset && plan.preset != KeyboardShortcuts.shared.preset ? plan.preset.overrides.count : 0
        return preset + changing(choice.settings).count + choice.shortcuts.count + (choice.recentProjects.isEmpty ? 0 : 1)
    }

    /// The ticked settings that would change something.
    static func changing(_ settings: [PlannedSetting]) -> [PlannedSetting] {
        settings.filter { !ImportCurrent.has($0.setting) }
    }

    /// Applies what was ticked and remembers it for Undo. An Apply that changes nothing (every value was
    /// already so) returns nil and keeps the Undo of the import before it.
    @discardableResult
    func apply(_ choice: ImportChoice, plan: ImportPlan, from source: String) -> Snapshot? {
        let defaults = UserDefaults.standard
        var keys: [String] = []
        if choice.usePreset { keys.append("keymapPreset") }
        keys += choice.settings.flatMap(\.setting.keys)
        if !choice.shortcuts.isEmpty { keys.append("keyBindings") }
        if !choice.recentProjects.isEmpty { keys.append("recentProjects") }
        var unique: [String] = []
        for key in keys where !unique.contains(key) { unique.append(key) }
        let before = Snapshot.values(of: unique, in: defaults)
        let settingsChanging = Self.changing(choice.settings).count
        let app = AppDelegate.shared!
        if choice.usePreset { KeyboardShortcuts.shared.preset = plan.preset }
        // The user's own shortcuts go on top of the preset, as their own changes.
        if !choice.shortcuts.isEmpty { KeyboardShortcuts.shared.setImported(choice.shortcuts) }
        for planned in choice.settings { app.applyImported(planned.setting) }
        let added = choice.recentProjects.isEmpty ? [] : app.importRecentProjects(choice.recentProjects)
        var parts: [String] = []
        if choice.usePreset { parts.append("\(plan.preset.name) shortcuts") }
        if !choice.shortcuts.isEmpty { parts.append("\(choice.shortcuts.count) of your shortcut\(choice.shortcuts.count == 1 ? "" : "s")") }
        if settingsChanging > 0 { parts.append("\(settingsChanging) setting\(settingsChanging == 1 ? "" : "s")") }
        if !added.isEmpty { parts.append("\(added.count) project\(added.count == 1 ? "" : "s")") }
        let after = Snapshot.values(of: unique, in: defaults)
        guard let snapshot = Snapshot.applied(keys: unique, before: before, after: after, source: source,
                                              summary: parts.joined(separator: ", ")) else { return nil }
        last = snapshot
        return snapshot
    }

    /// The settings the last import changed that hold something else now: changed by hand since, so Undo
    /// puts them back too. Named as Settings names them.
    func changedSinceImport() -> [String] {
        guard let snapshot = last else { return [] }
        let current = Snapshot.values(of: snapshot.touched, in: UserDefaults.standard)
        return Snapshot.titles(of: snapshot.changedSince(current))
    }

    /// What the Undo Import alert says, naming what was changed since the import.
    static func undoMessage(changedSince: [String]) -> String {
        let base = "The shortcuts, settings and recent projects it changed go back to what they were before."
        guard !changedSince.isEmpty else { return base }
        let list = ListFormatter.localizedString(byJoining: changedSince)
        return base + " You changed \(changedSince.count == 1 ? "this" : "these") since the import, and Undo puts "
            + "\(changedSince.count == 1 ? "it" : "them") back too: \(list)."
    }

    /// Puts every key the last import touched back as it was.
    func undo() {
        guard let snapshot = last else { return }
        let app = AppDelegate.shared!
        for key in snapshot.touched {
            let value = snapshot.before[key]
            switch key {
            case "keymapPreset":
                if case .string(let raw)? = value, let preset = KeymapPreset(rawValue: raw) { KeyboardShortcuts.shared.preset = preset }
                else { UserDefaults.standard.removeObject(forKey: key); KeyboardShortcuts.shared.apply() }
            case "keyBindings":
                // The user's shortcuts exactly as they were, including none at all.
                if case .data(let data)? = value { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
                KeyboardShortcuts.shared.apply()
            case "recentProjects":
                // Only the folders the import added go: projects opened since stay.
                app.setRecentProjects(snapshot.recentProjectsAfterUndo(current: UserDefaults.standard.stringArray(forKey: key) ?? []))
            default:
                app.restoreSetting(key, to: value)
            }
        }
        last = nil
    }
}

extension AppDelegate {
    /// Sets an imported value the way the menus and Settings do, so it applies at once.
    func applyImported(_ setting: ImportedSetting) {
        switch setting {
        case .fontSize(let size): setFontSize(CGFloat(size))
        case .terminalFontSize(let size): setTerminalFontSize(CGFloat(size))
        case .editorLineHeight(let factor): editorLineHeight = CGFloat(factor)
        case .softWrap(let on): if softWrap != on { toggleSoftWrap(nil) }
        case .optionAsMeta(let on): if Preferences.optionAsMeta != on { toggleOptionAsMeta(nil) }
        case .terminalPosition(let raw): if let position = TerminalPosition(rawValue: raw) { moveTerminal(to: position) }
        case .sidebarSide(let raw):
            if let side = SidebarSide(rawValue: raw), side != sidebarSide { toggleSidebarSide(nil) }
        case .editorFontFamily(let family): setEditorFontFamily(family)
        case .terminalFontFamily(let family): setTerminalFontFamily(family)
        case .terminalPalette(let palette): setTerminalPalette(palette)
        case .terminalScrollback(let lines): setTerminalScrollback(lines)
        case .terminalStartFolder(let stored): Preferences.terminalStartFolder = StartFolder(stored: stored)
        case .terminalCursorShape(let raw): if let shape = CursorShape(rawValue: raw) { setTerminalCursor(shape: shape) }
        case .terminalCursorBlink(let on): setTerminalCursor(blinks: on)
        case .trimTrailingWhitespace(let on): Preferences.trimTrailingWhitespace = on
        case .insertFinalNewline(let on): Preferences.insertFinalNewline = on
        case .hiddenFiles(let patterns):
            // Added to the patterns you have.
            let mine = Preferences.hiddenFilePatterns
            setHiddenFilePatterns(mine + patterns.filter { !mine.contains($0) })
        default: applyWindowSetting(setting)
        }
    }

    /// How files and projects open, what reopens at launch, diffs and git, as their menus and Settings set them.
    private func applyWindowSetting(_ setting: ImportedSetting) {
        switch setting {
        case .sidebarSingleClick(let on): sidebarSingleClickOpens = on
        case .backgroundFetch(let raw): if let frequency = FetchFrequency(rawValue: raw) { BackgroundFetcher.shared.frequency = frequency }
        case .diffLayout(let raw): if let layout = DiffLayout(rawValue: raw) { DiffLayout.current = layout }
        case .currentLineBlame(let on): setCurrentLineBlame(on)
        case .openProjectsIn(let raw): if let target = ProjectTarget(rawValue: raw) { projectTarget = target }
        case .launchOpens(let raw):
            if LaunchOpens(rawValue: raw) != nil { UserDefaults.standard.set(raw, forKey: LaunchSettings.Key.opens) }
        case .tabList(let list): applyTabList(list)
        default: break
        }
    }

    /// The tabs' side, the sidebar's and Show Folders set together, then each window laid out once: in full when the
    /// sidebar moves, else only where its tabs show. What is already so changes nothing.
    private func applyTabList(_ list: TabListImport) {
        guard let tabs = TerminalTabsSetting(rawValue: list.tabs) else { return }
        let side: SidebarSide? = list.sidebarSide.flatMap(SidebarSide.init(rawValue:))
        let movesTabs: Bool = tabs != terminalTabs
        let movesSidebar: Bool = side.map { $0 != sidebarSide } ?? false
        let foldersChange: Bool = list.showsFolders.map { $0 != tabListShowsFolders } ?? false
        if movesTabs { terminalTabs = tabs }
        if movesSidebar, let side { sidebarSide = side }
        if foldersChange, let folders = list.showsFolders { tabListShowsFolders = folders }
        for controller in controllers {
            if movesSidebar { controller.applyLayout() } else if movesTabs { controller.applyTerminalTabs() }
            if foldersChange { controller.refresh() }
        }
        if movesTabs { NotificationCenter.default.post(name: Self.terminalTabsChanged, object: nil) }
    }

    /// Undo: a setting back to its value before the import (nil: it had none, so the default returns).
    func restoreSetting(_ key: String, to value: ImportCoordinator.Snapshot.Value?) {
        switch (key, value) {
        case ("fontSize", .double(let size)?): setFontSize(CGFloat(size))
        case ("fontSize", nil): setFontSize(Theme.defaultFontSize)
        case ("terminalFontSize", .double(let size)?): setTerminalFontSize(CGFloat(size))
        case ("terminalFontSize", nil): setTerminalFontSize(nil)
        case ("editorLineHeight", .double(let factor)?): editorLineHeight = CGFloat(factor)
        case ("editorLineHeight", nil): editorLineHeight = 1.35
        case ("softWrap", .bool(let on)?): applyImported(.softWrap(on))
        case ("softWrap", nil): applyImported(.softWrap(true))
        case ("optionAsMeta", .bool(let on)?): applyImported(.optionAsMeta(on))
        case ("optionAsMeta", nil): applyImported(.optionAsMeta(false))
        case ("terminalPosition", .string(let raw)?): applyImported(.terminalPosition(raw))
        case ("terminalPosition", nil): applyImported(.terminalPosition(TerminalPosition.bottom.rawValue))
        case ("sidebarSide", .string(let raw)?): applyImported(.sidebarSide(raw))
        case ("sidebarSide", nil): applyImported(.sidebarSide(SidebarSide.left.rawValue))
        case ("editorFontFamily", .string(let family)?): setEditorFontFamily(family)
        case ("editorFontFamily", nil): setEditorFontFamily(nil)
        case ("terminalFontFamily", .string(let family)?): setTerminalFontFamily(family)
        case ("terminalFontFamily", nil): setTerminalFontFamily(nil)
        case ("terminalPalette", let value), ("customTerminalPalette", let value):
            // The saved bytes exactly as they were (none: Next Term's colours), then every terminal repainted.
            if case .data(let data)? = value { UserDefaults.standard.set(data, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            for controller in controllers { for tab in controller.tabs { Theme.applyColours(to: tab.view) } }
        default: restoreBehaviourSetting(key, to: value)
        }
    }

    /// Undo for the cursor, scrollback, start folder, clean-up on save and hidden files: the value before, or
    /// none, so the default returns.
    private func restoreBehaviourSetting(_ key: String, to value: ImportCoordinator.Snapshot.Value?) {
        let defaults = UserDefaults.standard
        switch (key, value) {
        case ("terminalScrollback", .double(let lines)?): setTerminalScrollback(Int(lines))
        case ("terminalScrollback", nil): setTerminalScrollback(nil)
        case ("terminalCursorShape", .string(let raw)?): setTerminalCursor(shape: CursorShape(rawValue: raw) ?? .block)
        case ("terminalCursorBlink", .bool(let on)?): setTerminalCursor(blinks: on)
        case ("terminalCursorShape", nil), ("terminalCursorBlink", nil):
            defaults.removeObject(forKey: key)
            setTerminalCursor()
        case ("hiddenFilePatterns", .strings(let patterns)?): setHiddenFilePatterns(patterns)
        case ("hiddenFilePatterns", nil): setHiddenFilePatterns([])
        case ("terminalStartFolder", .string(let stored)?): defaults.set(stored, forKey: key)
        case ("trimTrailingWhitespace", .bool(let on)?), ("insertFinalNewline", .bool(let on)?): defaults.set(on, forKey: key)
        case ("terminalStartFolder", nil), ("trimTrailingWhitespace", nil), ("insertFinalNewline", nil):
            defaults.removeObject(forKey: key)
        default: restoreWindowSetting(key, to: value)
        }
    }

    /// Undo for how files and projects open, what reopens at launch, diffs and git: the value before, or none,
    /// so the default returns.
    private func restoreWindowSetting(_ key: String, to value: ImportCoordinator.Snapshot.Value?) {
        let defaults = UserDefaults.standard
        switch (key, value) {
        case ("sidebarSingleClickOpens", .bool(let on)?): sidebarSingleClickOpens = on
        case ("currentLineBlame", .bool(let on)?): setCurrentLineBlame(on)
        case ("backgroundFetch", .string(let raw)?), ("diffLayout", .string(let raw)?), ("openProjectsIn", .string(let raw)?),
             (LaunchSettings.Key.opens, .string(let raw)?):
            applyWindowSetting(Self.windowSetting(key, raw))
        case ("sidebarSingleClickOpens", nil):
            sidebarSingleClickOpens = false
            defaults.removeObject(forKey: key)
        case ("currentLineBlame", nil):
            setCurrentLineBlame(false)
            defaults.removeObject(forKey: key)
        case ("backgroundFetch", nil):
            BackgroundFetcher.shared.frequency = .standard
            defaults.removeObject(forKey: key)
        case ("diffLayout", nil):
            DiffLayout.current = .sideBySide
            defaults.removeObject(forKey: key)
        case ("openProjectsIn", nil), (LaunchSettings.Key.opens, nil):
            defaults.removeObject(forKey: key)
        default: restoreTabListSetting(key, to: value)
        }
    }

    /// Undo for where the terminal's tabs show and Show Folders: the value before, or none, so the top and off return.
    private func restoreTabListSetting(_ key: String, to value: ImportCoordinator.Snapshot.Value?) {
        let defaults = UserDefaults.standard
        switch (key, value) {
        case (TerminalTabsSetting.key, .string(let raw)?): moveTerminalTabs(to: TerminalTabsSetting(stored: raw))
        case (TerminalTabsSetting.key, nil):
            moveTerminalTabs(to: .top)
            defaults.removeObject(forKey: key)
        case (TabListImport.showsFoldersKey, .bool(let on)?):
            tabListShowsFolders = on
            controllers.forEach { $0.refresh() }
        case (TabListImport.showsFoldersKey, nil):
            defaults.removeObject(forKey: key)
            controllers.forEach { $0.refresh() }
        default: break
        }
    }

    private static func windowSetting(_ key: String, _ raw: String) -> ImportedSetting {
        switch key {
        case "backgroundFetch": return .backgroundFetch(raw)
        case "diffLayout": return .diffLayout(raw)
        case "openProjectsIn": return .openProjectsIn(raw)
        default: return .launchOpens(raw)
        }
    }

    // MARK: menu

    @objc func showImport(_ sender: Any?) {
        ImportWindowController.shared.showChooser(firstRun: false, completion: nil)
    }
}

// MARK: - the window

/// "Coming from another app?" (the apps found, or keep Next Term's keys), then the preview for one app.
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImportWindowController()

    private var apps: [DetectedApp] = []
    private var completion: ((_ imported: ImportPlan?) -> Void)?
    /// The plan as the importer made it, and as shown (its shortcut rows settled against Next Term's).
    private var source: ImportPlan?
    private var plan: ImportPlan?
    private var app: DetectedApp?
    private var presetBox: NSButton?
    private var settingBoxes: [(NSButton, PlannedSetting)] = []
    private var shortcutBoxes: [(NSButton, PlannedShortcut)] = []
    /// With many shortcuts: the line beside the disclosure, and the list it opens.
    private var shortcutSummary: NSTextField?
    private var shortcutList: NSView?
    private var recentsBox: NSButton?
    private var applyButton: NSButton?
    private var radios: [NSButton] = []
    /// After one click: Undo Import on the window that says what came over.
    private var importedUndoButton: NSButton?

    /// An agent's request (apply_import): this window is its ask, with the agent's rows ticked and a banner naming it.
    struct AgentAsk {
        /// Who asks, as the approval windows name it ("the agent in the tab “claude” in api").
        let who: String
        /// The agent's reason, shown as its own words.
        let reason: String?
        /// The row ids it asked for (MCPImport's ids), ticked at first; the rest start unticked.
        let ticks: Set<String>
        /// Lines under its words: an earlier import's Undo that would go, a file's warning.
        let notes: [String]
        /// How the user answered, once.
        let answered: (AgentOutcome) -> Void
    }

    enum AgentOutcome {
        /// Applied with these rows ticked; `snapshot` nil when nothing changed, `replaced` the import whose Undo went.
        case applied(ticked: Set<String>, snapshot: ImportSnapshot?, replaced: ImportSnapshot?)
        case declined(stopAsking: Bool)
    }

    private(set) var agentAsk: AgentAsk?
    /// The user's own import window is open (not an agent's request).
    var isOpenForUser: Bool { window?.isVisible == true && agentAsk == nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Import Settings and Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `completion` runs once, when the window closes (with the plan applied, or nil).
    /// One list grouped by kind of app (editors, then terminals), each app with its version (or "app removed"), when
    /// it was last used and what it can bring; then keeping Next Term's shortcuts; then, folded, the apps not used
    /// lately.
    func showChooser(firstRun: Bool, completion: ((_ imported: ImportPlan?) -> Void)?) {
        // An agent's request is open here: it comes to the front instead, and stays as the user left it.
        if agentAsk != nil {
            window?.makeKeyAndOrderFront(nil)
            completion?(nil)
            return
        }
        self.completion = completion
        apps = ImportSources.detect()
        let title = Self.label(firstRun ? "Coming from another app?" : "Bring over your settings and shortcuts", size: 20, weight: .semibold)
        let intro = Self.wrapping("Next Term can use the shortcuts and settings you already have. Import brings an app’s over in one click; "
            + "Preview… shows every change first. Undo Import puts it all back.")
        var rows: [NSView] = [title, intro]
        radios = []
        let keep = NSButton(radioButtonWithTitle: "Keep Next Term’s shortcuts", target: self, action: #selector(radioChanged(_:)))
        keep.tag = -1
        keep.identifier = .init("spaced")
        radios.append(keep)
        var appRows: [[NSView]] = []
        for (index, found) in apps.enumerated() {
            let radio = NSButton(radioButtonWithTitle: found.name, target: self, action: #selector(radioChanged(_:)))
            radio.tag = index
            let detail = Self.detail(found)
            radio.setAccessibilityHelp(detail)
            radios.append(radio)
            appRows.append([Self.appLine(radio, importing: importButton(for: index, name: found.name)),
                            Self.wrapping(detail, secondary: true, size: 11, indent: true)])
        }
        // First run defaults to keeping everything; from the menu, to the app used last.
        let selected = firstRun || apps.isEmpty ? keep : radios[1]
        selected.state = .on
        if apps.isEmpty {
            rows.append(Self.wrapping(ImportSources.noneFound, secondary: true))
        }
        // Apps used lately, by kind; apps not used lately (180 days) come last, folded, after keeping Next Term's.
        for family in ImportFamily.allCases {
            let members = apps.indices.filter { !apps[$0].notUsedLately && apps[$0].kind.family == family }
            guard !members.isEmpty else { continue }
            rows.append(Self.heading(family.title))
            for index in members { rows += appRows[index] }
        }
        rows.append(keep)
        let stale = apps.indices.filter { apps[$0].notUsedLately }
        staleList = nil
        if !stale.isEmpty {
            let disclosure = NSButton(title: "", target: self, action: #selector(toggleStaleList(_:)))
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.pushOnPushOff)
            disclosure.setAccessibilityLabel("Show the apps not used lately")
            let header = NSStackView(views: [disclosure, Self.heading("Not used lately (\(stale.count))")])
            header.spacing = 4
            header.identifier = .init("heading")
            let list = NSStackView(views: stale.flatMap { appRows[$0] })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 8
            // Open when every app found is not used lately (the first run chooses Keep, and folded they would look
            // like nothing was found), or when one of them is chosen.
            let open = stale.count == apps.count || stale.contains { radios[$0 + 1] === selected }
            disclosure.state = open ? .on : .off
            list.isHidden = !open
            staleList = list
            rows += [header, list]
        }
        rows.append(Self.wrapping("Reads files on this Mac only. Never changes the other app. Nothing leaves your Mac.", secondary: true, size: 11))
        let preview = NSButton(title: "Preview…", target: self, action: #selector(previewChosen))
        preview.keyEquivalent = "\r"
        let close = NSButton(title: firstRun ? "Keep Next Term’s Shortcuts" : "Close", target: self, action: #selector(closeWithoutImport))
        close.keyEquivalent = "\u{1b}"
        preview.isEnabled = !apps.isEmpty
        previewButton = preview
        layout(rows, buttons: [close, preview], scrolls: apps.count > Self.appsShownWithoutScrolling)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePreviewButton()
    }

    /// More apps than this, and the chooser scrolls.
    static let appsShownWithoutScrolling = 7

    /// The folded list of apps not used lately.
    private var staleList: NSView?
    private var previewButton: NSButton?

    @objc private func toggleStaleList(_ sender: NSButton) {
        staleList?.isHidden = sender.state != .on
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// "1.105.1  ·  used 3 days ago  ·  brings shortcuts, settings, fonts and colours", or "app removed" for an app
    /// whose settings stayed behind.
    static func detail(_ app: DetectedApp) -> String {
        var parts: [String] = []
        if app.appRemoved {
            parts.append("app removed")
        } else if let version = app.version {
            parts.append(version)
        }
        if let used = used(app.lastUsed) { parts.append(used) }
        parts.append("brings " + ImportContent.list(app.kind.canBring))
        return parts.joined(separator: "  ·  ")
    }

    @objc private func radioChanged(_ sender: NSButton) {
        for radio in radios { radio.state = radio === sender ? .on : .off }
        updatePreviewButton()
    }

    private func updatePreviewButton() {
        let chosen = radios.first { $0.state == .on }?.tag ?? -1
        previewButton?.isEnabled = chosen >= 0
    }

    /// An app's Import, at the end of its row: one click brings over what its preview ticks at first.
    private func importButton(for index: Int, name: String) -> NSButton {
        let button = NSButton(title: "Import", target: self, action: #selector(importApp(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.setAccessibilityLabel("Import from \(name)")
        button.toolTip = "Brings over what Preview… ticks at first, in one click. Undo Import puts it all back."
        return button
    }

    /// The app's radio button, and its Import at the row's end.
    private static func appLine(_ radio: NSButton, importing button: NSButton) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [radio, spacer, button])
        line.orientation = .horizontal
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return line
    }

    @objc private func importApp(_ sender: NSButton) {
        guard apps.indices.contains(sender.tag) else { return }
        importRecommended(from: apps[sender.tag])
    }

    /// What the preview ticks at first, for `source` settled as the preview settles it: the rows MCPImport.defaultTicks
    /// names (the shortcut set when it differs from the one in use, each row the importer ticks, the recent projects not
    /// listed yet). An agent's preview starts from the same rows.
    static func recommended(_ source: ImportPlan) -> (plan: ImportPlan, choice: ImportChoice) {
        let current = KeyboardShortcuts.shared.preset
        let plan = settle(source, under: source.preset)
        let projects = plan.recentProjects.filter { !AppDelegate.shared.recentProjects.contains($0) }
        let ticks = MCPImport.defaultTicks(plan, currentPreset: current, newRecents: projects)
        let ids = MCPImport.rowIDs(plan)
        let settings = plan.settings.indices.filter { ticks.contains(ids.settings[$0]) }.map { plan.settings[$0] }
        let shortcuts = plan.shortcuts.indices.filter { ticks.contains(ids.shortcuts[$0]) && plan.shortcuts[$0].allowed }
            .map { plan.shortcuts[$0] }
        let choice = ImportChoice(usePreset: ticks.contains(MCPImport.presetID), settings: settings, shortcuts: shortcuts,
                                  recentProjects: ticks.contains(MCPImport.recentsID) ? projects : [])
        return (plan, choice)
    }

    /// One click (an app's Import, here or in Settings › Import): the recommended rows applied, then the window says what
    /// came over, with Undo Import. Not while an agent's request is open here: that comes to the front instead.
    func importRecommended(from found: DetectedApp) {
        guard agentAsk == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let source = ImportSources.plan(for: found)
        let (plan, choice) = Self.recommended(source)
        app = found
        self.source = source
        self.plan = plan
        // A layout the import moves is named, so it never changes unannounced.
        let moved: [String] = ImportCoordinator.changing(choice.settings).compactMap { (planned: PlannedSetting) -> String? in
            guard case .tabList(let list) = planned.setting else { return nil }
            return list.movedLine
        }
        let snapshot = ImportCoordinator.count(choice, plan: plan) > 0
            ? ImportCoordinator.shared.apply(choice, plan: plan, from: found.name) : nil
        showImported(from: found, snapshot: snapshot, skipped: plan.skipped.count, moved: moved)
    }

    /// After one click: what came over (or that nothing would change), and Undo Import; Done closes the window.
    private func showImported(from found: DetectedApp, snapshot: ImportSnapshot?, skipped: Int, moved: [String] = []) {
        var rows: [NSView] = []
        if let snapshot {
            rows.append(Self.label("Brought over from \(found.name)", size: 20, weight: .semibold))
            rows.append(Self.wrapping(snapshot.summary.prefix(1).uppercased() + snapshot.summary.dropFirst() + "."))
            for line in moved { rows.append(Self.wrapping(line)) }
            rows.append(Self.wrapping("Undo Import puts all of it back, here or in Settings › Import.", secondary: true, size: 12))
        } else {
            rows.append(Self.label("Nothing to bring over from \(found.name)", size: 20, weight: .semibold))
            rows.append(Self.wrapping("Next Term already has what \(found.name) would bring."))
        }
        if skipped > 0 {
            rows.append(Self.wrapping("\(skipped) thing\(skipped == 1 ? " wasn’t" : "s weren’t") brought over: Preview… in Settings › Import "
                                      + "lists each one and why.", secondary: true, size: 12))
        }
        let undo = NSButton(title: "Undo Import", target: self, action: #selector(undoImported))
        undo.isHidden = snapshot == nil
        let done = NSButton(title: "Done", target: self, action: #selector(doneImporting))
        done.keyEquivalent = "\r"
        importedUndoButton = undo
        layout(rows, buttons: [undo, done])
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func doneImporting() { finish(with: plan) }

    /// Undo straight after the import: nothing has changed since, so nothing needs naming first.
    @objc private func undoImported() {
        ImportCoordinator.shared.undo()
        finish(with: nil)
    }

    @objc private func previewChosen() {
        guard let chosen = radios.first(where: { $0.state == .on })?.tag, chosen >= 0, apps.indices.contains(chosen) else {
            return closeWithoutImport()
        }
        showPreview(for: apps[chosen])
    }

    /// The preview: every change with where it came from, each one a checkbox.
    func showPreview(for found: DetectedApp, plan given: ImportPlan? = nil) {
        if agentAsk != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        app = found
        source = given ?? ImportSources.plan(for: found)
        buildPreview(usePreset: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// An agent's request: the preview of `plan` with the rows it asked for ticked and the others unticked, under a
    /// banner naming the agent. Shown in front without taking the keyboard, and Return never applies it.
    func showAgentRequest(for found: DetectedApp, plan: ImportPlan, ask: AgentAsk) {
        agentAsk = ask
        completion = nil
        app = found
        source = plan
        buildPreview(usePreset: ask.ticks.contains(MCPImport.presetID))
        window?.center()
        window?.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Ends an agent's request as a decline (no answer in time): the window closes.
    func endAgentRequest() {
        guard agentAsk != nil else { return }
        closeWithoutImport()
    }

    /// The banner over an agent's request: who asks, in whose words, and what the user decides.
    private func agentBanner(_ ask: AgentAsk, from name: String) -> [NSView] {
        let who = ask.who.prefix(1).uppercased() + String(ask.who.dropFirst())
        var views = [Self.wrapping("\(who) asks to bring these over from \(name). Only the rows you tick change, and only when you click Apply.")]
        if let words = ask.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            let quote = Self.wrapping("The agent says: “\(String(words.prefix(500)))”", secondary: true, size: 12)
            quote.toolTip = "These are the agent's words, not Next Term's."
            views.append(quote)
        }
        for note in ask.notes { views.append(Self.wrapping(note, secondary: true, size: 12)) }
        return views
    }

    /// The user's own shortcuts are checked against Next Term's as they will be: under the plan's preset
    /// while it is ticked, else the one in use. Ticking or unticking it lays the preview out again.
    private func buildPreview(usePreset: Bool) {
        guard let found = app, let source else { return }
        let current = KeyboardShortcuts.shared.preset
        let under = usePreset ? source.preset : current
        let plan = Self.settle(source, under: under)
        self.plan = plan
        settingBoxes = []
        var rows: [NSView] = [Self.label("Bring over from \(found.name)", size: 20, weight: .semibold)]
        let ask = agentAsk
        if let ask { rows += agentBanner(ask, from: found.name) }
        let ids = MCPImport.rowIDs(plan)

        // Shortcuts.
        if plan.preset != .nextTerm || current != .nextTerm {
            rows.append(Self.heading("Shortcuts"))
            let box = NSButton(checkboxWithTitle: plan.preset == current ? "Already using \(plan.preset.name) shortcuts"
                               : "Use \(plan.preset.name) shortcuts (\(plan.preset.overrides.count) differ from Next Term’s)",
                               target: self, action: #selector(presetToggled))
            box.state = plan.preset != current && usePreset ? .on : .off
            box.identifier = .init(MCPImport.presetID)
            box.isEnabled = plan.preset != current
            presetBox = box
            rows.append(box)
            for line in Self.presetLines(plan.preset) { rows.append(Self.wrapping(line, secondary: true, size: 11, indent: true)) }
        } else {
            presetBox = nil
        }

        // The user's own shortcuts, each moved over as their own change. A long list starts folded.
        shortcutBoxes = []
        shortcutSummary = nil
        shortcutList = nil
        if !plan.shortcuts.isEmpty {
            rows.append(Self.heading("Your shortcuts (\(plan.shortcuts.count))"))
            let chords = KeyboardShortcuts.shared.chords(under: under)
            var list: [NSView] = []
            for (index, planned) in plan.shortcuts.enumerated() {
                let box = NSButton(checkboxWithTitle: Self.describe(planned, from: chords[planned.command] ?? nil),
                                   target: self, action: #selector(recount))
                let ticked = ask.map { $0.ticks.contains(ids.shortcuts[index]) && planned.allowed } ?? planned.ticked
                box.state = ticked ? .on : .off
                box.identifier = .init(ids.shortcuts[index])
                box.isEnabled = planned.allowed
                shortcutBoxes.append((box, planned))
                list.append(box)
                list.append(Self.wrapping(planned.source + (planned.note.map { " — " + $0 } ?? ""), secondary: true, size: 11, indent: true))
            }
            if plan.shortcuts.count > Self.shortcutsShownOpen {
                let disclosure = NSButton(title: "", target: self, action: #selector(toggleShortcutList(_:)))
                disclosure.bezelStyle = .disclosure
                disclosure.setButtonType(.pushOnPushOff)
                disclosure.state = .off
                disclosure.setAccessibilityLabel("Show your shortcuts")
                let summary = NSTextField(labelWithString: "")
                shortcutSummary = summary
                let header = NSStackView(views: [disclosure, summary])
                header.spacing = 4
                let folded = NSStackView(views: list)
                folded.orientation = .vertical
                folded.alignment = .leading
                folded.spacing = 8
                folded.isHidden = true
                shortcutList = folded
                rows += [header, folded]
            } else {
                rows += list
            }
        }

        // Settings.
        if !plan.settings.isEmpty {
            rows.append(Self.heading("Settings"))
            for (index, planned) in plan.settings.enumerated() {
                let box = NSButton(checkboxWithTitle: Self.describe(planned.setting), target: self, action: #selector(recount))
                let ticked = ask.map { $0.ticks.contains(ids.settings[index]) } ?? planned.ticked
                box.state = ticked ? .on : .off
                box.identifier = .init(ids.settings[index])
                settingBoxes.append((box, planned))
                rows.append(box)
                if case .terminalPalette(let palette) = planned.setting { rows.append(Self.swatches(palette)) }
                let detail = planned.source + (planned.note.map { " — " + $0 } ?? "")
                rows.append(Self.wrapping(detail, secondary: true, size: 11, indent: true))
            }
        }

        // Recent projects.
        let projects = plan.recentProjects.filter { !AppDelegate.shared.recentProjects.contains($0) }
        if !projects.isEmpty {
            rows.append(Self.heading("Recent projects"))
            let box = NSButton(checkboxWithTitle: "Add \(projects.count) recent project\(projects.count == 1 ? "" : "s") to Open Recent and the Welcome window",
                               target: self, action: #selector(recount))
            let recentsTicked = ask.map { $0.ticks.contains(MCPImport.recentsID) } ?? true
            box.state = recentsTicked ? .on : .off
            box.identifier = .init(MCPImport.recentsID)
            recentsBox = box
            rows.append(box)
            let names = projects.prefix(8).map { RecentProjects.abbreviate($0) }.joined(separator: "\n")
                + (projects.count > 8 ? "\nand \(projects.count - 8) more" : "")
            rows.append(Self.wrapping(names, secondary: true, size: 11, indent: true))
        } else {
            recentsBox = nil
        }

        // Not brought over.
        if !plan.skipped.isEmpty {
            rows.append(Self.heading("Not brought over (\(plan.skipped.count))"))
            let list = plan.skipped.prefix(12).map { "\($0.item): \($0.reason)" }.joined(separator: "\n")
                + (plan.skipped.count > 12 ? "\nand \(plan.skipped.count - 12) more" : "")
            rows.append(Self.wrapping(list, secondary: true, size: 11, indent: true))
            let copy = NSButton(title: "Copy List for Your Agent", target: self, action: #selector(copySkipped))
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            rows.append(copy)
        }
        if plan.settings.isEmpty && plan.shortcuts.isEmpty && projects.isEmpty && presetBox?.isEnabled != true {
            rows.append(Self.wrapping("Already up to date: nothing here differs from Next Term now.", secondary: true))
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWithoutImport))
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyChosen))
        applyButton = apply
        if ask != nil {
            // An agent asks at a moment of its own choosing: no key answers it, and only a click applies.
            apply.refusesFirstResponder = true
            let stop = NSButton(title: "Decline and Stop Asking", target: self, action: #selector(declineAndStop))
            layout(rows, buttons: [stop, cancel, apply], scrolls: true)
        } else {
            cancel.keyEquivalent = "\u{1b}"
            apply.keyEquivalent = "\r"
            layout(rows, buttons: [cancel, apply], scrolls: true)
        }
        recount()
    }

    /// More of the user's own shortcuts than this start folded under a disclosure.
    static let shortcutsShownOpen = 8

    /// The importer's shortcut rows settled against Next Term's shortcuts under `preset`, the user's own on top.
    static func settle(_ plan: ImportPlan, under preset: KeymapPreset) -> ImportPlan {
        let shortcuts = KeyboardShortcuts.shared
        let titles = Dictionary(shortcuts.commands.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return plan.settlingShortcuts(current: shortcuts.chords(under: preset), aliases: shortcuts.aliases, titles: titles)
    }

    /// The preset ticked or not changes which keys are free, so the shortcut rows are settled again; the
    /// settings and recent projects keep what the user ticked.
    @objc private func presetToggled() {
        let settings = settingBoxes.map { $0.0.state }
        let recents = recentsBox?.state
        let open = shortcutList?.isHidden == false
        buildPreview(usePreset: presetBox?.state == .on)
        for (box, state) in zip(settingBoxes.map(\.0), settings) { box.state = state }
        if let recents { recentsBox?.state = recents }
        if open {
            shortcutList?.isHidden = false
            (shortcutSummary?.superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first?.state = .on
        }
        recount()
    }

    @objc private func toggleShortcutList(_ sender: NSButton) {
        shortcutList?.isHidden = sender.state != .on
    }

    private var choice: ImportChoice {
        let projects = plan?.recentProjects.filter { !AppDelegate.shared.recentProjects.contains($0) } ?? []
        let usePreset = presetBox?.isEnabled == true && presetBox?.state == .on
        let settings: [PlannedSetting] = settingBoxes.filter { $0.0.state == .on }.map(\.1)
        let shortcuts: [PlannedShortcut] = shortcutBoxes.filter { $0.0.state == .on && $0.1.allowed }.map(\.1)
        let recents: [String] = recentsBox?.state == .on ? projects : []
        return ImportChoice(usePreset: usePreset, settings: settings, shortcuts: shortcuts, recentProjects: recents)
    }

    @objc private func recount() {
        guard let plan else { return }
        let choice = self.choice
        let count = ImportCoordinator.count(choice, plan: plan)
        applyButton?.title = count == 0 ? "Apply" : "Apply \(count) Change\(count == 1 ? "" : "s")"
        applyButton?.isEnabled = count > 0
        shortcutSummary?.stringValue = "\(choice.shortcuts.count) of \(plan.shortcuts.count) ticked"
    }

    @objc private func applyChosen() {
        guard let plan, let app else { return }
        let ticked = tickedIDs
        let replaced = ImportCoordinator.shared.last
        let snapshot = ImportCoordinator.shared.apply(choice, plan: plan, from: app.name)
        if let ask = agentAsk {
            agentAsk = nil
            ask.answered(.applied(ticked: ticked, snapshot: snapshot, replaced: snapshot == nil ? nil : replaced))
        }
        finish(with: plan)
    }

    /// The ids of the rows ticked now (MCPImport's), for an agent's answer.
    var tickedIDs: Set<String> {
        guard let plan else { return [] }
        let ids = MCPImport.rowIDs(plan)
        var ticked = Set<String>()
        if presetBox?.isEnabled == true, presetBox?.state == .on { ticked.insert(MCPImport.presetID) }
        for (index, entry) in settingBoxes.enumerated() where entry.0.state == .on { ticked.insert(ids.settings[index]) }
        for (index, entry) in shortcutBoxes.enumerated() where entry.0.state == .on && entry.1.allowed { ticked.insert(ids.shortcuts[index]) }
        if recentsBox?.state == .on { ticked.insert(MCPImport.recentsID) }
        return ticked
    }

    @objc private func declineAndStop() { declineAgent(stopAsking: true) }

    /// Answers an agent's request as declined, once.
    private func declineAgent(stopAsking: Bool) {
        if let ask = agentAsk {
            agentAsk = nil
            ask.answered(.declined(stopAsking: stopAsking))
        }
        finish(with: nil)
    }

    @objc private func copySkipped() {
        guard let plan else { return }
        let name = app?.name ?? "another app"
        var text = "Next Term imported settings from \(name). These were not brought over; help me with them if Next Term has a way. "
            + "Next Term's MCP tools list_import_sources, preview_import and apply_import show and ask for the same rows: use them rather than "
            + "reading \(name)'s own files, which sit next to tokens.\n"
        text += plan.skipped.map { "- \($0.item): \($0.reason)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWithoutImport() { declineAgent(stopAsking: false) }

    func windowWillClose(_ notification: Notification) {
        // Closing an agent's request is a decline.
        if let ask = agentAsk {
            agentAsk = nil
            ask.answered(.declined(stopAsking: false))
        }
        let done = completion
        completion = nil
        done?(nil)
    }

    private func finish(with plan: ImportPlan?) {
        let done = completion
        completion = nil
        window?.orderOut(nil)
        done?(plan)
    }

    /// For the self-test: tick state and apply.
    var applyTitle: String { applyButton?.title ?? "" }
    /// For the self-test: the app chosen in the chooser, and whether the apps not used lately are shown.
    var chosenTitle: String? { radios.first { $0.state == .on }?.title }
    var staleListIsOpen: Bool { staleList?.isHidden == false }
    func applyForTest() { applyChosen() }
    /// For the self-test: the Import buttons on the chooser's rows, and the one-click result's Undo Import.
    var importButtons: [NSButton] {
        func find(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { $0.action == #selector(importApp(_:)) ? [$0] : [] } ?? []) + view.subviews.flatMap(find)
        }
        return window?.contentView.map(find) ?? []
    }
    var undoImportedButton: NSButton? { importedUndoButton }
    /// For the self-test: a shortcut row's note and tick, and ticking it as a click does.
    func shortcutRow(for command: String) -> (note: String?, ticked: Bool)? {
        shortcutBoxes.first { $0.1.command == command }.map { ($0.1.note, $0.0.state == .on) }
    }
    func tickShortcutForTest(_ command: String) {
        shortcutBoxes.first { $0.1.command == command }?.0.state = .on
        recount()
    }

    // MARK: layout

    private func layout(_ rows: [NSView], buttons: [NSButton], scrolls: Bool = false) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (i, row) in rows.enumerated() where i > 0 && ["heading", "spaced"].contains(row.identifier?.rawValue) {
            stack.setCustomSpacing(16, after: rows[i - 1])
        }
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 16, right: 24)
        let buttonRow = NSStackView(views: [NSView()] + buttons)
        buttonRow.orientation = .horizontal
        buttonRow.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 18, right: 24)
        for button in buttons { button.bezelStyle = .rounded }
        let content = NSView()
        let body: NSView
        if scrolls {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let flipped = FlippedStack()
            flipped.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: flipped.topAnchor),
                stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            ])
            flipped.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = flipped
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            body = scroll
        } else {
            body = stack
        }
        for view in [body, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if !scrolls { stack.widthAnchor.constraint(equalToConstant: 560).isActive = true }
        window?.contentView = content
        if scrolls { window?.setContentSize(NSSize(width: 560, height: 560)) } else { fitHeight(content) }
    }

    /// The window as tall as what it shows, its top edge where it was: a short page (the chooser with one app, what one
    /// click brought over) after a long one keeps no empty space.
    private func fitHeight(_ content: NSView) {
        content.layoutSubtreeIfNeeded()
        guard let window else { return }
        let fitting = content.fittingSize
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: max(fitting.width, 560), height: fitting.height)))
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height), display: true)
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    /// A small section heading in capitals, letterspaced so the caps don't crowd.
    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.8,
        ])
        label.identifier = .init("heading")
        return label
    }

    /// Wrapping text; `indent` sets it under a checkbox's title, at a fixed width so it wraps rather than
    /// being cut off.
    private static func wrapping(_ text: String, secondary: Bool = false, size: CGFloat = 13, indent: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        if secondary { label.textColor = .secondaryLabelColor }
        label.preferredMaxLayoutWidth = indent ? 470 : 510
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: indent ? 22 : 0),
            label.widthAnchor.constraint(equalToConstant: indent ? 470 : 510),
            box.trailingAnchor.constraint(equalTo: label.trailingAnchor),
        ])
        return box
    }

    /// The colours as they would look, under the checkbox's title.
    private static func swatches(_ palette: TerminalPalette) -> NSView {
        let swatches = PaletteSwatches()
        swatches.colours = Theme.terminalColours(palette)
        swatches.identifier = .init("swatches")
        swatches.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(swatches)
        NSLayoutConstraint.activate([
            swatches.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            swatches.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            swatches.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 22),
            box.trailingAnchor.constraint(equalTo: swatches.trailingAnchor),
        ])
        return box
    }

    /// "used 3 days ago" (nil: no date).
    static func used(_ date: Date?) -> String? {
        guard let date else { return nil }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        switch days {
        case ..<1: return "used today"
        case 1: return "used yesterday"
        case 2..<14: return "used \(days) days ago"
        case 14..<60: return "used \(days / 7) weeks ago"
        case 60..<730: return "used \(days / 30) months ago"
        default: return "used \(days / 365) years ago"
        }
    }

    /// "Replace in Files  ⇧⌘R → ⇧⌘H" for each command the preset changes.
    static func presetLines(_ preset: KeymapPreset) -> [String] {
        let shortcuts = KeyboardShortcuts.shared
        var lines = preset.overrides.keys.sorted().map { id -> String in
            let from = shortcuts.commands.first { $0.id == id }?.defaultChord?.display ?? "no key"
            let to = preset.overrides[id]!?.display ?? "no key"
            // ⌘P keeps opening Go to File unless something else takes it (see KeyboardShortcuts.goToFileAlias).
            let alsoP = id == "goToFile:" && to != KeyboardShortcuts.goToFileKey.display ? " (⌘P still works)" : ""
            // A key outside the menus says where it is: "New Folder (Project Sidebar)".
            return "\(shortcuts.placedTitle(of: id))   \(from) → \(to)\(alsoP)"
        }
        if preset.clearsOnlyInTerminal { lines.append("⌘K clears only while a terminal has the keyboard") }
        lines.append("Your own shortcut changes stay as they are")
        return lines
    }

    /// "Go to File…   ⌘P → ⇧⌘O": the command, its key now (with the preset) and the one it would get.
    static func describe(_ shortcut: PlannedShortcut, from now: KeyChord?) -> String {
        "\(shortcut.title)   \(now?.display ?? "no key") → \(shortcut.chord?.display ?? "no key")"
    }

    static func describe(_ setting: ImportedSetting) -> String {
        let app = AppDelegate.shared!
        switch setting {
        case .fontSize(let size): return "Editor font size \(Int(app.fontSize)) → \(Int(size)) pt"
        case .terminalFontSize(let size): return "Terminal font size \(Int(app.terminalFontSize)) → \(Int(size)) pt"
        case .editorLineHeight(let factor): return String(format: "Line height %.2f× → %.2f×", app.editorLineHeight, factor)
        case .softWrap(let on): return on ? "Wrap long lines" : "Don’t wrap long lines"
        case .optionAsMeta(let on): return on ? "Use Option as Meta in the terminal" : "Option types special characters"
        case .terminalPosition(let raw): return "Terminal on the \(raw)"
        case .sidebarSide(let raw): return "Project sidebar on the \(raw)"
        case .editorFontFamily(let family):
            return "Editor font \(Preferences.editorFontFamily ?? Theme.defaultFontName) → \(family)"
        case .terminalFontFamily(let family):
            return "Terminal font \(Preferences.terminalFontFamily ?? Theme.defaultFontName) → \(family)"
        case .terminalPalette(let palette):
            return "Terminal colours \(Preferences.terminalPalette?.name ?? "Next Term default") → \(palette.name)"
        case .terminalScrollback(let lines):
            let now = TerminalBehaviourControls.formatted(Preferences.terminalScrollback)
            return "Terminal scrollback \(now) → \(TerminalBehaviourControls.formatted(lines)) lines"
        case .terminalStartFolder(let stored): return "New tabs open " + startFolderTitle(StartFolder(stored: stored))
        case .terminalCursorShape(let raw):
            let shape = CursorShape(rawValue: raw)?.title ?? raw
            return "Terminal cursor \(Preferences.terminalCursorShape.title.lowercased()) → \(shape.lowercased())"
        case .terminalCursorBlink(let on): return on ? "Terminal cursor blinks" : "Terminal cursor doesn’t blink"
        case .trimTrailingWhitespace(let on): return on ? "Trim trailing spaces on save" : "Don’t trim trailing spaces on save"
        case .insertFinalNewline(let on): return on ? "End files with a newline on save" : "Don’t add a final newline on save"
        case .hiddenFiles(let patterns): return "Hide in the project sidebar: " + FileHiding.text(of: patterns)
        default: return describeWindowSetting(setting)
        }
    }

    static func describeWindowSetting(_ setting: ImportedSetting) -> String {
        switch setting {
        case .sidebarSingleClick(let on):
            return on ? "Open files with a single click, in a preview tab" : "Open files with a double click"
        case .backgroundFetch(let raw):
            let frequency = FetchFrequency(rawValue: raw) ?? .standard
            return "Fetch in the background: " + lowerFirst(frequency.title)
        case .diffLayout(let raw): return raw == "unified" ? "Show diffs in one column (Unified Diffs)" : "Show diffs side by side"
        case .currentLineBlame(let on): return on ? "Show the current line’s last commit (Current Line Blame)" : "Don’t show the current line’s last commit"
        case .openProjectsIn(let raw):
            switch raw {
            case "newWindow": return "Open projects in a new window"
            case "thisWindow": return "Open projects in the window in use"
            default: return "Ask where to open projects"
            }
        case .launchOpens(let raw): return "At launch: " + lowerFirst((LaunchOpens(rawValue: raw) ?? .standard).title)
        case .tabList(let list): return list.title
        default: return ""
        }
    }

    /// "Every 5 minutes" → "every 5 minutes", leaving the rest ("the Welcome window") as it is.
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    static func startFolderTitle(_ folder: StartFolder) -> String {
        switch folder {
        case .project: return "in the project’s folder"
        case .current: return "in the current tab’s folder"
        case .home: return "in your home folder"
        case .folder(let path): return "in " + RecentProjects.abbreviate(path)
        }
    }
}

private final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings › Import

/// Settings › Import: the shortcuts preset, the apps found, and the last import with Undo.
final class ImportSettingsView: NSView {
    private let presetPopup = NSPopUpButton()
    private let lastLabel = NSTextField(wrappingLabelWithString: "")
    private let undoButton = NSButton(title: "Undo Import", target: nil, action: nil)
    private let appsStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for preset in KeymapPreset.allCases {
            presetPopup.addItem(withTitle: preset.name)
            presetPopup.lastItem?.representedObject = preset.rawValue
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        let presetRow = NSStackView(views: [NSTextField(labelWithString: "Shortcuts from:"), presetPopup])
        let presetNote = NSTextField(wrappingLabelWithString: "VS Code and JetBrains keys for the commands that differ; your own changes in Keyboard Shortcuts stay on top.")
        presetNote.font = .systemFont(ofSize: 11)
        presetNote.textColor = .secondaryLabelColor
        presetNote.preferredMaxLayoutWidth = 520
        let appsTitle = NSTextField(labelWithString: "Bring over settings, shortcuts and recent projects from:")
        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = 6
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded
        lastLabel.textColor = .secondaryLabelColor
        lastLabel.font = .systemFont(ofSize: 12)
        lastLabel.preferredMaxLayoutWidth = 420
        let lastRow = NSStackView(views: [lastLabel, undoButton])
        lastRow.alignment = .centerY
        let stack = NSStackView(views: [presetRow, presetNote, appsTitle, appsStack, lastRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(24, after: presetNote)
        stack.setCustomSpacing(24, after: appsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ImportCoordinator.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc private func refresh() {
        let preset = KeyboardShortcuts.shared.preset
        presetPopup.selectItem(at: KeymapPreset.allCases.firstIndex(of: preset) ?? 0)
        appsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let apps = ImportSources.detect()
        if apps.isEmpty {
            let none = NSTextField(wrappingLabelWithString: ImportSources.noneFound)
            none.preferredMaxLayoutWidth = 520
            none.textColor = .secondaryLabelColor
            appsStack.addArrangedSubview(none)
        }
        for (index, app) in apps.enumerated() {
            let button = NSButton(title: "Preview…", target: self, action: #selector(preview(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            var tags: [String] = []
            if app.appRemoved { tags.append("app removed") }
            if app.notUsedLately { tags.append("not used lately") }
            let name = NSTextField(labelWithString: ([app.name] + tags).joined(separator: "  ·  "))
            let importing = NSButton(title: "Import", target: self, action: #selector(importApp(_:)))
            importing.bezelStyle = .rounded
            importing.controlSize = .small
            importing.tag = index
            importing.setAccessibilityLabel("Import from \(app.name)")
            importing.toolTip = "Brings over what Preview… ticks at first, in one click. Undo Import puts it all back."
            let row = NSStackView(views: [name, button, importing])
            appsStack.addArrangedSubview(row)
        }
        if let last = ImportCoordinator.shared.last {
            let date = DateFormatter.localizedString(from: last.date, dateStyle: .medium, timeStyle: .none)
            lastLabel.stringValue = "Imported from \(last.source) on \(date): \(last.summary)."
            undoButton.isHidden = false
        } else {
            lastLabel.stringValue = "Nothing imported."
            undoButton.isHidden = true
        }
    }

    @objc private func presetChanged() {
        guard let raw = presetPopup.selectedItem?.representedObject as? String, let preset = KeymapPreset(rawValue: raw) else { return }
        KeyboardShortcuts.shared.preset = preset
        NotificationCenter.default.post(name: ImportCoordinator.changed, object: nil)
    }

    @objc private func preview(_ sender: NSButton) {
        let apps = ImportSources.detect()
        guard apps.indices.contains(sender.tag) else { return }
        ImportWindowController.shared.showPreview(for: apps[sender.tag])
    }

    /// One click, as on the import window's rows.
    @objc private func importApp(_ sender: NSButton) {
        let apps = ImportSources.detect()
        guard apps.indices.contains(sender.tag) else { return }
        ImportWindowController.shared.importRecommended(from: apps[sender.tag])
    }

    @objc private func undo() {
        let alert = NSAlert()
        alert.messageText = "Undo the import?"
        alert.informativeText = ImportCoordinator.undoMessage(changedSince: ImportCoordinator.shared.changedSinceImport())
        alert.addButton(withTitle: "Undo Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ImportCoordinator.shared.undo()
    }
}
