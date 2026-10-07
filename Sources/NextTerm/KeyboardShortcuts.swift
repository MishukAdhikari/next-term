import AppKit
import NextTermCore

/// Every menu command's shortcut can be changed (Settings, Keyboard Shortcuts). The menus as built are
/// the defaults; the user's changes are saved as overrides and laid over them.
final class KeyboardShortcuts {
    static let shared = KeyboardShortcuts()

    struct Command {
        let id: String
        let title: String
        /// "Edit › Find" — where it lives in the menu bar.
        let path: String
        let defaultChord: KeyChord?
        weak var item: NSMenuItem?
    }

    private(set) var commands: [Command] = []
    private static let defaultsKey = "keyBindings"

    var bindings: KeyBindings {
        get { KeyBindings.decode(UserDefaults.standard.data(forKey: Self.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.encoded(), forKey: Self.defaultsKey) }
    }

    /// Every command's shortcut before the user's own changes: the preset's, else the menu's.
    var defaults: [String: KeyChord?] {
        let preset = self.preset
        return Dictionary(commands.map { ($0.id, preset.chord(for: $0.id, default: $0.defaultChord)) }, uniquingKeysWith: { first, _ in first })
    }

    private static let presetKey = "keymapPreset"

    /// Shortcuts from VS Code or JetBrains (macOS), laid between the menus' defaults and the user's own
    /// changes, which a preset never touches.
    var preset: KeymapPreset {
        get { KeymapPreset(rawValue: UserDefaults.standard.string(forKey: Self.presetKey) ?? "") ?? .nextTerm }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.presetKey)
            apply()
        }
    }

    /// A command's shortcut before the user's own change.
    func baseChord(for id: String) -> KeyChord? {
        preset.chord(for: id, default: commands.first { $0.id == id }?.defaultChord ?? nil)
    }

    /// Keys hidden menu items answer to (⌘= for Bigger), with the command each belongs to: no other
    /// command can take them.
    private(set) var aliases: [KeyChord: String] = [:]

    /// ⌘P, Next Term's Go to File key, as a second key for it when a shortcut set moves Go to File
    /// (the JetBrains set puts it on ⇧⌘O). It gives way to any command that has ⌘P.
    static let goToFileAlias = NSUserInterfaceItemIdentifier("goToFileAlias")
    static let goToFileKey = KeyChord(key: "p", command: true)
    private weak var goToFileAliasItem: NSMenuItem?

    /// Records the menus' commands and their default shortcuts, then applies the user's.
    func capture(_ menu: NSMenu) {
        commands = []
        aliases = [:]
        walk(menu, path: [])
        apply()
    }

    private func walk(_ menu: NSMenu, path: [String]) {
        for item in menu.items {
            if let submenu = item.submenu {
                walk(submenu, path: path + [item.title])
                continue
            }
            if item.identifier == Self.goToFileAlias {
                goToFileAliasItem = item
                continue
            }
            if item.isHidden, item.allowsKeyEquivalentWhenHidden, let id = Self.id(of: item), let chord = Self.chord(of: item) {
                aliases[chord] = id
            }
            // Hidden aliases (⌘= for Bigger) follow their visible item; dynamic menus (Open Recent) have none.
            guard !item.isSeparatorItem, !item.isHidden, let id = Self.id(of: item),
                  !commands.contains(where: { $0.id == id }) else { continue }
            commands.append(Command(id: id, title: item.title, path: path.joined(separator: " › "),
                                    defaultChord: Self.chord(of: item), item: item))
        }
    }

    /// A stable name for a menu command: its action, plus what tells same-action items apart.
    static func id(of item: NSMenuItem) -> String? {
        guard let action = item.action else { return nil }
        var id = NSStringFromSelector(action)
        if let value = item.representedObject as? String {
            id += value
        } else if let value = item.representedObject as? Double {
            id += String(value) // Line Height › 1.35: one id per item, not one for all seven
        } else if item.tag != 0 {
            id += "#\(item.tag)"
        }
        return id
    }

    static func chord(of item: NSMenuItem) -> KeyChord? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        return KeyChord(key: item.keyEquivalent, command: mask.contains(.command), shift: mask.contains(.shift),
                        option: mask.contains(.option), control: mask.contains(.control))
    }

    static func set(_ chord: KeyChord?, on item: NSMenuItem) {
        guard let chord else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        var mask: NSEvent.ModifierFlags = []
        if chord.command { mask.insert(.command) }
        if chord.shift { mask.insert(.shift) }
        if chord.option { mask.insert(.option) }
        if chord.control { mask.insert(.control) }
        item.keyEquivalent = chord.key
        item.keyEquivalentModifierMask = mask
    }

    /// The shortcut a key press makes, with the key unshifted ("]" for ⇧⌘], "t" for ⇧⌘T).
    static func chord(from event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        if key == "\u{7F}" { key = "\u{8}" } // the Delete key, as menus spell it
        if key == "\u{3}" { key = "\r" }      // Enter on the keypad
        guard key.count == 1 else { return nil }
        return KeyChord(key: key.lowercased(), command: flags.contains(.command), shift: flags.contains(.shift),
                        option: flags.contains(.option), control: flags.contains(.control))
    }

    func chord(for id: String) -> KeyChord? {
        bindings.chord(for: id, default: baseChord(for: id))
    }

    func title(of id: String) -> String {
        commands.first { $0.id == id }?.title ?? id
    }

    /// Lays the preset and the user's shortcuts over the menus. A saved shortcut that could not be typed
    /// (no ⌘ or ⌃, or hand-edited preferences) is ignored rather than taking keys from typing.
    func apply() {
        let bindings = self.bindings
        let preset = self.preset
        var chords: [(NSMenuItem, KeyChord?)] = []
        for command in commands {
            guard let item = command.item else { continue }
            let base = preset.chord(for: command.id, default: command.defaultChord)
            var chord = bindings.chord(for: command.id, default: base)
            if let saved = chord, !saved.isUsable { chord = base }
            chords.append((item, chord))
        }
        // Every key comes off before any goes on: AppKit leaves a menu item without its key when another
        // item still holds it, so a key moving between commands (or from ⌘P's alias) would be lost.
        goToFileAliasItem.map { Self.set(nil, on: $0) }
        for (item, _) in chords { Self.set(nil, on: item) }
        for (item, chord) in chords { Self.set(chord, on: item) }
        // ⌘P stays Go to File while no command has it.
        if let alias = goToFileAliasItem, !chords.contains(where: { $0.1 == Self.goToFileKey }) {
            Self.set(Self.goToFileKey, on: alias)
        }
    }

    /// Whether ⌘P opens Go to File through the alias now (for the self-test and the import preview).
    var goToFileAliasActive: Bool { goToFileAliasItem.flatMap(Self.chord(of:)) == Self.goToFileKey }

    func set(_ chord: KeyChord?, for id: String) {
        var bindings = self.bindings
        bindings.set(chord, for: id, default: baseChord(for: id))
        self.bindings = bindings
        apply()
    }

    /// Every command's shortcut as it would be under `preset`, the user's own changes on top (a saved one
    /// that can't be typed counts as the preset's, as in `apply`).
    func chords(under preset: KeymapPreset) -> [String: KeyChord?] {
        let bindings = self.bindings
        var chords: [String: KeyChord?] = [:]
        for command in commands where chords[command.id] == nil {
            let base = preset.chord(for: command.id, default: command.defaultChord)
            var chord = bindings.chord(for: command.id, default: base)
            if let saved = chord, !saved.isUsable { chord = base }
            chords[command.id] = .some(chord)
        }
        return chords
    }

    /// An import's shortcuts, saved as the user's own changes on top of the preset. A key another command
    /// has moves, leaving that command without one (as when it is typed in Settings); a Control key without
    /// ⌘ is never taken.
    func setImported(_ shortcuts: [PlannedShortcut]) {
        var bindings = self.bindings
        let defaults = self.defaults
        for shortcut in shortcuts where shortcut.allowed && defaults[shortcut.command] != nil {
            if let chord = shortcut.chord {
                guard chord.isUsable, !ImportShortcuts.isShellKey(chord) else { continue }
                if let owner = bindings.owner(of: chord, defaults: defaults, except: shortcut.command) {
                    bindings.set(nil, for: owner, default: defaults[owner] ?? nil)
                }
            }
            bindings.set(shortcut.chord, for: shortcut.command, default: defaults[shortcut.command] ?? nil)
        }
        self.bindings = bindings
        apply()
    }

    func reset(_ id: String) {
        var bindings = self.bindings
        bindings.reset(id)
        self.bindings = bindings
        apply()
    }

    func resetAll() {
        bindings = KeyBindings()
        apply()
    }

    func isCustomised(_ id: String) -> Bool { bindings.overrides[id] != nil }
}

// MARK: - Settings window

/// Settings (⌘,): every command with its shortcut. Click a shortcut and press the new one; ⌫ removes it,
/// ⎋ cancels.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [KeyboardShortcuts.Command] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // The editor's settings, the terminal's, every shortcut, and imports.
        let tabs = NSTabView()
        let editorTab = NSTabViewItem(identifier: "editor")
        editorTab.label = "Editor"
        editorTab.view = EditorSettingsView()
        let terminalTab = NSTabViewItem(identifier: "terminal")
        terminalTab.label = "Terminal"
        terminalTab.view = TerminalSettingsView()
        let keysTab = NSTabViewItem(identifier: "keys")
        keysTab.label = "Keyboard Shortcuts"
        keysTab.view = NSView()
        let importTab = NSTabViewItem(identifier: "import")
        importTab.label = "Import"
        importTab.view = ImportSettingsView()
        tabs.addTabViewItem(editorTab)
        tabs.addTabViewItem(terminalTab)
        tabs.addTabViewItem(keysTab)
        tabs.addTabViewItem(importTab)
        // A preset switched (here or by an import) changes the shortcuts listed.
        NotificationCenter.default.addObserver(self, selector: #selector(presetChanged), name: ImportCoordinator.changed, object: nil)
        window.contentView = tabs
        shortcutsContent = keysTab.view
        build()
        reload()
        window.center()
    }

    private var shortcutsContent: NSView?

    @objc private func presetChanged() { reload() }

    func showTab(_ identifier: String) {
        (window?.contentView as? NSTabView)?.selectTabViewItem(withIdentifier: identifier)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = shortcutsContent else { return }
        search.placeholderString = "Search commands or shortcuts"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        for (id, title, width) in [("command", "Command", 330.0), ("shortcut", "Shortcut", 150.0), ("reset", "", 90.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "command" ? 200 : width
            column.resizingMask = id == "command" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAll))
        restore.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "Click a shortcut, then press the new keys. ⌫ removes it, ⎋ cancels.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        Typography.singleLine(hint, truncation: .byTruncatingTail)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [hint, NSView(), restore])
        bottom.orientation = .horizontal

        for view in [search, scroll, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shortcuts = KeyboardShortcuts.shared
        rows = shortcuts.commands.filter { command in
            guard !query.isEmpty else { return true }
            let shortcut = shortcuts.chord(for: command.id)?.display.lowercased() ?? ""
            return command.title.lowercased().contains(query) || command.path.lowercased().contains(query) || shortcut.contains(query)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let command = rows[row]
        switch column?.identifier.rawValue {
        case "command":
            let label = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: command.title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            if !command.path.isEmpty {
                text.append(NSAttributedString(string: "  " + command.path, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            label.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
            return label
        case "shortcut":
            let recorder = ShortcutRecorder(commandID: command.id)
            recorder.onChange = { [weak self] in self?.reload() }
            return recorder
        default:
            guard KeyboardShortcuts.shared.isCustomised(command.id) else { return NSView() }
            let button = NSButton(title: "Default", target: self, action: #selector(resetRow(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = .init(command.id)
            button.toolTip = "Back to " + (KeyboardShortcuts.shared.baseChord(for: command.id)?.display ?? "no shortcut")
            return button
        }
    }

    @objc private func resetRow(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        KeyboardShortcuts.shared.reset(id)
        reload()
    }

    @objc private func restoreAll() {
        KeyboardShortcuts.shared.resetAll()
        reload()
    }
}

/// A shortcut you click and then type.
final class ShortcutRecorder: NSButton {
    let commandID: String
    var onChange: (() -> Void)?
    private var monitor: Any?
    private var clickMonitor: Any?

    init(commandID: String) {
        self.commandID = commandID
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(startRecording)
        showCurrent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func showCurrent() {
        title = KeyboardShortcuts.shared.chord(for: commandID)?.display ?? "—"
        setAccessibilityLabel("Shortcut for \(KeyboardShortcuts.shared.title(of: commandID)): \(title)")
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil // the keys belong to the recorder, not to the menus
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.stopRecording()
            return event
        }
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { return stopRecording() } // ⎋
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // ⌫ or ⌦ alone: no shortcut
            commit(nil)
            return
        }
        guard let chord = KeyboardShortcuts.chord(from: event), chord.isUsable else {
            NSSound.beep() // needs ⌘ or ⌃ (or a function key), so typing is never swallowed
            return
        }
        commit(chord)
    }

    private func commit(_ chord: KeyChord?) {
        stopRecording()
        let shortcuts = KeyboardShortcuts.shared
        if let chord, let owner = shortcuts.bindings.owner(of: chord, defaults: shortcuts.defaults, except: commandID) {
            let alert = NSAlert()
            alert.messageText = "\(chord.display) is used by “\(shortcuts.title(of: owner))”."
            alert.informativeText = "Use it for “\(shortcuts.title(of: commandID))” instead? “\(shortcuts.title(of: owner))” is left without a shortcut."
            alert.addButton(withTitle: "Use It Here")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return showCurrent() }
            shortcuts.set(nil, for: owner)
        }
        shortcuts.set(chord, for: commandID)
        showCurrent()
        onChange?()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        clickMonitor = nil
        showCurrent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }
}

/// Settings › Editor: line height, soft wrap, hidden .env values and font size, the sidebar, agents and git,
/// applied as they change.
final class EditorSettingsView: NSView {
    private let lineHeight = NSSlider(value: 1.35, minValue: 1.0, maxValue: 2.0, target: nil, action: nil)
    private let lineHeightValue = NSTextField(labelWithString: "")
    private let wrap = NSButton(checkboxWithTitle: "Wrap long lines at the edge", target: nil, action: nil)
    private let envValues = NSButton(checkboxWithTitle: "Hide values in .env files", target: nil, action: nil)
    private let singleClick = NSButton(checkboxWithTitle: "Open files with a single click", target: nil, action: nil)
    private let dotIcons = NSButton(checkboxWithTitle: "Icons on configuration folders (.github, .claude, .idea…)", target: nil, action: nil)
    private let claude = NSButton(checkboxWithTitle: "Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code)", target: nil, action: nil)
    private let control = NSButton(checkboxWithTitle: "Let agents control Next Term (MCP: projects, tabs, prompts, the editor)", target: nil, action: nil)
    private let controlStatus = NSTextField(wrappingLabelWithString: "")
    private let fontSize = NSStepper()
    private let fontSizeValue = NSTextField(labelWithString: "")
    private let fontFamily = FontFamilyPopup()
    /// How often git fetches by itself, to keep the sidebar's "Pull 3" up to date.
    let backgroundFetch = NSPopUpButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fontFamily.onChange = { family in AppDelegate.shared.setEditorFontFamily(family) }
        for frequency in FetchFrequency.allCases {
            backgroundFetch.addItem(withTitle: frequency.title)
            backgroundFetch.lastItem?.representedObject = frequency.rawValue
        }
        backgroundFetch.target = self
        backgroundFetch.action = #selector(backgroundFetchChanged)
        backgroundFetch.toolTip = "Fetches the remotes your branches track, so the sidebar can say “Pull 3” by itself. It waits for the git commands Next Term runs for you, never asks for a password, and leaves FETCH_HEAD as it is."
        lineHeight.target = self
        lineHeight.action = #selector(lineHeightChanged)
        lineHeight.isContinuous = true
        lineHeight.numberOfTickMarks = 21 // steps of 0.05
        lineHeight.allowsTickMarkValuesOnly = true
        lineHeightValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wrap.target = self
        wrap.action = #selector(wrapChanged)
        envValues.target = self
        envValues.action = #selector(envValuesChanged)
        envValues.toolTip = "For screen sharing: values show as dots, and the file itself does not change. The line you click or type in shows its value."
        singleClick.target = self
        singleClick.action = #selector(singleClickChanged)
        singleClick.toolTip = "A click opens the file in a preview tab that the next click reuses. Edit the file or double-click its tab to keep it. Off: a double-click opens, as in Finder."
        dotIcons.target = self
        dotIcons.action = #selector(dotIconsChanged)
        claude.target = self
        claude.action = #selector(claudeChanged)
        control.target = self
        control.action = #selector(controlChanged)
        controlStatus.textColor = .secondaryLabelColor
        controlStatus.font = .systemFont(ofSize: 11)
        controlStatus.preferredMaxLayoutWidth = 400
        fontSize.minValue = Double(Theme.fontSizeRange.lowerBound)
        fontSize.maxValue = Double(Theme.fontSizeRange.upperBound)
        fontSize.increment = 1
        fontSize.target = self
        fontSize.action = #selector(fontSizeChanged)
        fontSizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 10
            return stack
        }
        let note = NSTextField(wrappingLabelWithString: "Line height is a multiple of the font’s own line height; 1.35 reads well for code. The font size is shared with the terminal (⌘+ and ⌘-); the terminal’s font is in the Terminal tab. Claude Code, Gemini CLI and Qwen Code started in a new tab connect to Next Term as their IDE: the open files and the selected lines go with each prompt (never from .env files). They connect by themselves (Next Term turns Gemini's and Qwen's IDE mode on); turn this off to stop sharing. ⌥⌘K adds an @-mention to Claude's prompt.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        lineHeight.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let stack = NSStackView(views: [
            row("Font:", [fontFamily]),
            row("Font size:", [fontSize, fontSizeValue]),
            row("Line height:", [lineHeight, lineHeightValue]),
            row("", [wrap]),
            row("", [envValues]),
            row("Sidebar:", [singleClick]),
            row("", [dotIcons]),
            row("Git:", [NSTextField(labelWithString: "Fetch in the background:"), backgroundFetch]),
            row("Agents:", [claude]),
            row("", [control]),
            row("", [controlStatus]),
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(registrationsChanged), name: MCPRegistration.changed, object: nil)
        // An import or its undo can change the font.
        NotificationCenter.default.addObserver(self, selector: #selector(registrationsChanged), name: ImportCoordinator.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func registrationsChanged() { refresh() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        guard let app = AppDelegate.shared else { return }
        lineHeight.doubleValue = Double(app.editorLineHeight)
        lineHeightValue.stringValue = String(format: "%.2f×", app.editorLineHeight)
        wrap.state = app.softWrap ? .on : .off
        envValues.state = app.hidesEnvValues ? .on : .off
        singleClick.state = app.sidebarSingleClickOpens ? .on : .off
        dotIcons.state = app.iconsOnDotFolders ? .on : .off
        claude.state = app.shareWithClaude ? .on : .off
        control.state = app.agentControl ? .on : .off
        controlStatus.stringValue = !app.agentControl ? "Off: no agent can reach Next Term, and it is removed from the agents it was added to."
            : CommandLineTool.script == nil ? "Only the installed app adds itself to your agents."
            : "Any agent can open projects and tabs, start agents, give them prompts and read their screens. " + MCPRegistration.summary
        fontSize.doubleValue = Double(app.fontSize)
        fontSizeValue.stringValue = "\(Int(app.fontSize)) pt"
        fontFamily.show(Preferences.editorFontFamily)
        backgroundFetch.selectItem(at: FetchFrequency.allCases.firstIndex(of: BackgroundFetcher.shared.frequency) ?? 0)
    }

    @objc private func backgroundFetchChanged() {
        guard let raw = backgroundFetch.selectedItem?.representedObject as? String, let frequency = FetchFrequency(rawValue: raw) else { return }
        BackgroundFetcher.shared.frequency = frequency
    }

    @objc private func lineHeightChanged() {
        AppDelegate.shared.editorLineHeight = CGFloat((lineHeight.doubleValue * 20).rounded() / 20)
        refresh()
    }

    @objc private func wrapChanged() {
        if (wrap.state == .on) != AppDelegate.shared.softWrap { AppDelegate.shared.toggleSoftWrap(nil) }
        refresh()
    }

    @objc private func envValuesChanged() {
        AppDelegate.shared.hidesEnvValues = envValues.state == .on
        refresh()
    }

    @objc private func claudeChanged() {
        AppDelegate.shared.shareWithClaude = claude.state == .on
        refresh()
    }

    @objc private func controlChanged() {
        AppDelegate.shared.agentControl = control.state == .on
        refresh()
    }

    @objc private func singleClickChanged() {
        AppDelegate.shared.sidebarSingleClickOpens = singleClick.state == .on
        refresh()
    }

    @objc private func dotIconsChanged() {
        AppDelegate.shared.iconsOnDotFolders = dotIcons.state == .on
        refresh()
    }

    @objc private func fontSizeChanged() {
        AppDelegate.shared.setFontSize(CGFloat(fontSize.doubleValue))
        refresh()
    }
}
