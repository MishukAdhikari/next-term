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

    var defaults: [String: KeyChord?] {
        Dictionary(commands.map { ($0.id, $0.defaultChord) }, uniquingKeysWith: { first, _ in first })
    }

    /// Records the menus' commands and their default shortcuts, then applies the user's.
    func capture(_ menu: NSMenu) {
        commands = []
        walk(menu, path: [])
        apply()
    }

    private func walk(_ menu: NSMenu, path: [String]) {
        for item in menu.items {
            if let submenu = item.submenu {
                walk(submenu, path: path + [item.title])
                continue
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
        if let value = item.representedObject as? String { id += value } else if item.tag != 0 { id += "#\(item.tag)" }
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
        bindings.chord(for: id, default: commands.first { $0.id == id }?.defaultChord ?? nil)
    }

    func title(of id: String) -> String {
        commands.first { $0.id == id }?.title ?? id
    }

    /// Lays the user's shortcuts over the menus.
    func apply() {
        let bindings = self.bindings
        for command in commands {
            guard let item = command.item else { continue }
            Self.set(bindings.chord(for: command.id, default: command.defaultChord), on: item)
        }
    }

    func set(_ chord: KeyChord?, for id: String) {
        var bindings = self.bindings
        bindings.set(chord, for: id, default: commands.first { $0.id == id }?.defaultChord ?? nil)
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
        // Two tabs: the editor's settings, and every shortcut.
        let tabs = NSTabView()
        let editorTab = NSTabViewItem(identifier: "editor")
        editorTab.label = "Editor"
        editorTab.view = EditorSettingsView()
        let keysTab = NSTabViewItem(identifier: "keys")
        keysTab.label = "Keyboard Shortcuts"
        keysTab.view = NSView()
        tabs.addTabViewItem(editorTab)
        tabs.addTabViewItem(keysTab)
        window.contentView = tabs
        shortcutsContent = keysTab.view
        build()
        reload()
        window.center()
    }

    private var shortcutsContent: NSView?

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
            button.toolTip = "Back to " + (command.defaultChord?.display ?? "no shortcut")
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

/// Settings › Editor: line height, soft wrap and font size, applied as they change.
final class EditorSettingsView: NSView {
    private let lineHeight = NSSlider(value: 1.35, minValue: 1.0, maxValue: 2.0, target: nil, action: nil)
    private let lineHeightValue = NSTextField(labelWithString: "")
    private let wrap = NSButton(checkboxWithTitle: "Wrap long lines at the edge", target: nil, action: nil)
    private let dotIcons = NSButton(checkboxWithTitle: "Icons on configuration folders (.github, .claude, .idea…)", target: nil, action: nil)
    private let claude = NSButton(checkboxWithTitle: "Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code)", target: nil, action: nil)
    private let fontSize = NSStepper()
    private let fontSizeValue = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        lineHeight.target = self
        lineHeight.action = #selector(lineHeightChanged)
        lineHeight.isContinuous = true
        lineHeight.numberOfTickMarks = 21 // steps of 0.05
        lineHeight.allowsTickMarkValuesOnly = true
        lineHeightValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wrap.target = self
        wrap.action = #selector(wrapChanged)
        dotIcons.target = self
        dotIcons.action = #selector(dotIconsChanged)
        claude.target = self
        claude.action = #selector(claudeChanged)
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
        let note = NSTextField(wrappingLabelWithString: "Line height is a multiple of the font’s own line height; 1.35 reads well for code. The font size is shared with the terminal (⌘+ and ⌘-). Claude Code, Gemini CLI and Qwen Code started in a new tab connect to Next Term as their IDE: the open files and the selected lines go with each prompt (never from .env files). They connect by themselves (Next Term turns Gemini's and Qwen's IDE mode on); turn this off to stop sharing. ⌥⌘K adds an @-mention to Claude's prompt.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        lineHeight.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let stack = NSStackView(views: [
            row("Line height:", [lineHeight, lineHeightValue]),
            row("Font size:", [fontSize, fontSizeValue]),
            row("", [wrap]),
            row("Sidebar:", [dotIcons]),
            row("Agents:", [claude]),
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        guard let app = AppDelegate.shared else { return }
        lineHeight.doubleValue = Double(app.editorLineHeight)
        lineHeightValue.stringValue = String(format: "%.2f×", app.editorLineHeight)
        wrap.state = app.softWrap ? .on : .off
        dotIcons.state = app.iconsOnDotFolders ? .on : .off
        claude.state = app.shareWithClaude ? .on : .off
        fontSize.doubleValue = Double(app.fontSize)
        fontSizeValue.stringValue = "\(Int(app.fontSize)) pt"
    }

    @objc private func lineHeightChanged() {
        AppDelegate.shared.editorLineHeight = CGFloat((lineHeight.doubleValue * 20).rounded() / 20)
        refresh()
    }

    @objc private func wrapChanged() {
        if (wrap.state == .on) != AppDelegate.shared.softWrap { AppDelegate.shared.toggleSoftWrap(nil) }
        refresh()
    }

    @objc private func claudeChanged() {
        AppDelegate.shared.shareWithClaude = claude.state == .on
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
