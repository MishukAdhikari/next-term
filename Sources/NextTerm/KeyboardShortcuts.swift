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

    /// Records the menus' commands and their default shortcuts, then applies the user's. Called before the
    /// menu is the menu bar: macOS then keeps only one item per key, and ⌘D is on two (Split Right, Duplicate Line).
    func capture(_ menu: NSMenu) {
        commands = []
        aliases = [:]
        walk(menu, path: [])
        apply()
        guard trackingObservers.isEmpty else { return }
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            trackingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
                if open { self.menuBarOpened() } else { self.menuBarClosed() }
            })
        }
    }

    // MARK: the editor's own keys

    /// The editor's commands (Edit › Line) on their keys. Their menu items hold no key while the menus are
    /// closed: the editor answers these keys itself while it has the keyboard (CodeTextView.performKeyEquivalent),
    /// and everywhere else a key goes where it would without them: to the terminal command that shares it (⌘D,
    /// Split Right), or to the terminal or the sidebar (a disabled menu item would swallow it).
    private(set) var editorKeys: [KeyChord: NSMenuItem] = [:]
    /// The item of another command on the same key, which gives it up while the menus are open over the editor.
    private var sharedKeys: [KeyChord: NSMenuItem] = [:]
    private var trackingObservers: [NSObjectProtocol] = []
    /// Whether the editor's items show their keys now (the menu bar is open).
    private(set) var showsEditorKeys = false

    /// The editor command `event` presses, if any: by the key as typed unshifted, or as the ⌘ layer of a
    /// non-Latin layout gives it.
    func editorItem(for event: NSEvent) -> NSMenuItem? {
        guard !editorKeys.isEmpty, let chord = Self.chord(from: event) else { return nil }
        if let item = editorKeys[chord] { return item }
        guard let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1, typed != chord.key else { return nil }
        return editorKeys[KeyChord(key: typed, command: chord.command, shift: chord.shift, option: chord.option, control: chord.control)]
    }

    /// The menu bar opened: the editor's items show their keys, and with the editor's keyboard a shared key is
    /// shown on the editor's command only, since that is what it does there.
    func menuBarOpened(editorHasKeyboard: Bool? = nil) {
        let inEditor = editorHasKeyboard ?? (NSApp.keyWindow?.firstResponder is CodeTextView)
        for (chord, item) in editorKeys {
            if let other = sharedKeys[chord] {
                guard inEditor else { continue }
                Self.set(nil, on: other)
            }
            Self.set(chord, on: item)
        }
        showsEditorKeys = true
    }

    /// The menu bar closed: the editor's items give their keys back.
    func menuBarClosed() {
        guard showsEditorKeys else { return }
        showsEditorKeys = false
        for item in editorKeys.values { Self.set(nil, on: item) }
        for (chord, other) in sharedKeys { Self.set(chord, on: other) }
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

    /// Posted when the shortcuts change (Settings, a preset, an import), for tooltips that name a key.
    static let changed = Notification.Name("NextTermKeyboardShortcutsChanged")

    /// The key the menu command for `action` has now, if any.
    func key(for action: Selector) -> KeyChord? {
        let id = NSStringFromSelector(action)
        return commands.first(where: { $0.id == id })?.item.flatMap(Self.chord(of:))
    }

    /// "New tab (⌘T)": the words with the key the command has now, or the words alone without one.
    func hint(_ words: String, _ action: Selector) -> String {
        guard let chord = key(for: action) else { return words }
        return "\(words) (\(chord.display))"
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
        // The editor's commands keep theirs off the menus while they are closed (`editorKeys`).
        let editorIDs = KeyBindings.editorCommands
        showsEditorKeys = false
        editorKeys = [:]
        sharedKeys = [:]
        func isEditors(_ item: NSMenuItem) -> Bool { Self.id(of: item).map { editorIDs.contains($0) } ?? false }
        for (item, chord) in chords where isEditors(item) {
            if let chord { editorKeys[chord] = item }
        }
        for (item, chord) in chords where !isEditors(item) {
            Self.set(chord, on: item)
            if let chord, editorKeys[chord] != nil { sharedKeys[chord] = item }
        }
        // ⌘P stays Go to File while no command has it.
        if let alias = goToFileAliasItem, !chords.contains(where: { $0.1 == Self.goToFileKey }) {
            Self.set(Self.goToFileKey, on: alias)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
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
    /// has moves, leaving that command without one (as when it is typed in Settings), unless the two can share
    /// it (KeyBindings.canShareKey); a Control key without ⌘ is never taken.
    func setImported(_ shortcuts: [PlannedShortcut]) {
        var bindings = self.bindings
        let defaults = self.defaults
        for shortcut in shortcuts where shortcut.allowed && defaults[shortcut.command] != nil {
            if let chord = shortcut.chord {
                guard chord.isUsable, !ImportShortcuts.isShellKey(chord) else { continue }
                for owner in bindings.owners(of: chord, defaults: defaults, except: shortcut.command) {
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

    /// "⌘D is Duplicate Line while the editor has the keyboard, Split Right everywhere else", when the command's
    /// key is shared that way (Settings says so on both).
    func sharing(_ id: String) -> String? {
        guard let chord = chord(for: id), let other = bindings.sharer(of: chord, defaults: defaults, except: id) else { return nil }
        let editor = KeyBindings.editorCommands.contains(id) ? id : other
        let elsewhere = editor == id ? other : id
        return "\(chord.display) is \(title(of: editor)) while the editor has the keyboard, \(title(of: elsewhere)) everywhere else"
    }
}

/// A view's tooltip that names a menu command's key as it is now ("New tab (⌘T)"), and follows it when
/// the shortcut changes. Kept by the view's owner for as long as the view.
final class ShortcutToolTip: NSObject {
    private weak var view: NSView?
    private let words: String
    private let action: Selector

    init(_ view: NSView, _ words: String, _ action: Selector) {
        self.view = view
        self.words = words
        self.action = action
        super.init()
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: KeyboardShortcuts.changed, object: nil)
    }

    @objc private func update() {
        view?.toolTip = KeyboardShortcuts.shared.hint(words, action)
    }
}

/// A menu command's key just before the icon button that does the same ("⌘B" before the sidebar icon), as a
/// tab shows "⌘1" before its ×. It follows the key as Settings changes it and says nothing while the command
/// has none; its owner shows it only while there is room. One that gave way still shows while the pointer is
/// on its button, over what is beside the icon. VoiceOver hears the key once, as the button's help.
final class KeyHint: NSTextField {
    /// A tab's "⌘1", and these: small and dim, never cut short.
    static func style(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.textDim
        label.alignment = .right
        Typography.singleLine(label, truncation: .byClipping)
        // The tab's or the button's help says it. VoiceOver is given the field's cell, not the field.
        label.setAccessibilityElement(false)
        label.cell?.setAccessibilityElement(false)
    }

    /// From the key to the icon, as from a tab's "⌘1" to its ×.
    static let gap: CGFloat = 7
    /// Clear room before the key, a little more than `gap`, so it reads with its icon and not with what
    /// comes before it (the last tab, the Pull button).
    static let lead: CGFloat = 8

    private let command: Selector?
    private weak var button: NSButton?

    /// The key `command`'s menu command has, before `button` (none: its owner places it, and says when the
    /// pointer is on its icon).
    init(_ command: Selector, for button: NSButton?) {
        self.command = command
        self.button = button
        super.init(frame: .zero)
        configure()
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: KeyboardShortcuts.changed, object: nil)
    }

    /// A key of the view's own rather than a menu command's (the branch popup's ⌘R).
    init(key: String, for button: NSButton) {
        command = nil
        self.button = button
        super.init(frame: .zero)
        configure()
        stringValue = key
        button.setAccessibilityHelp(key)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        Self.style(self)
        isHidden = true
        // At once, as the pointer comes onto the button: no tooltip's wait.
        button?.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self, userInfo: nil))
    }

    /// "⌘B", shown or not; empty while the command has no key.
    var key: String { stringValue }
    /// The key as it shows now: nil while hidden (for the self-test).
    var shownKey: String? { isHidden ? nil : key }

    @objc private func update() {
        guard let command else { return }
        let key = KeyboardShortcuts.shared.key(for: command)?.display ?? ""
        guard key != stringValue else { return }
        stringValue = key
        button?.setAccessibilityHelp(key.isEmpty ? nil : key)
        superview?.needsLayout = true // its owner decides again whether there is room
        updateOverlay()
    }

    // MARK: while the pointer is on the button

    /// Its owner had no room for it, though it has a key and its button shows.
    private var gaveWay = false
    private var pointerOnIcon = false
    private var overlay: KeyHintOverlay?
    /// What is under the key where it shows over the row: the bar's colour (the rail's, while it is hovered).
    var backdrop = Theme.bar { didSet { overlay?.needsDisplay = true } }
    /// Where its overlay may start: the window's buttons sit before it (a tab bar's `leadingInset`). With no
    /// room before the icon there, the key shows just after it instead.
    var keepClear: CGFloat = 0
    /// Where its overlay may go, in its owner's coordinates: anywhere in it unless the owner says (the rail
    /// keeps the tab bars' line above the key clear).
    var overlayBounds: NSRect?

    /// The key shown over the row while the pointer is on the button, nil while it is not (for the self-test).
    var hoverKey: String? { overlay?.isHidden == false ? overlay?.label.stringValue : nil }
    /// Where it shows then, in its owner's coordinates (for the self-test).
    var hoverFrame: NSRect { overlay?.isHidden == false ? overlay?.frame ?? .zero : .zero }

    override func mouseEntered(with event: NSEvent) { pointer(onIcon: true) }
    override func mouseExited(with event: NSEvent) { pointer(onIcon: false) }

    /// The pointer came onto the button's icon or left it (the button's tracking area, or the rail's own).
    func pointer(onIcon: Bool) {
        guard onIcon != pointerOnIcon else { return }
        pointerOnIcon = onIcon
        updateOverlay()
    }

    // Gone with the pointer still on it (a click hid the sidebar): it must not come back by itself. Its
    // owner hiding it says nothing; an ancestor hiding it, or its overlay, does.
    override func viewDidHide() {
        super.viewDidHide()
        if !isHidden { pointer(onIcon: false) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointer(onIcon: false)
    }

    /// While it gave way and the pointer is on the button: the key at its own place before the icon, over
    /// whatever is there now, on `backdrop` with a little margin. It moves nothing and is gone when the
    /// pointer leaves.
    private func updateOverlay() {
        guard gaveWay, pointerOnIcon, !key.isEmpty, let superview else {
            overlay?.isHidden = true
            return
        }
        let overlay = self.overlay ?? KeyHintOverlay(hint: self)
        self.overlay = overlay
        var text = frame
        if let button, text.minX - KeyHintOverlay.padding < keepClear {
            text.origin.x = button.frame.midX + iconWidth / 2 + Self.gap
        }
        if superview.subviews.last !== overlay { superview.addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.show(key, at: text, within: overlayBounds ?? superview.bounds)
    }

    /// A label: a click goes to what is under it (the bar, which drags the window, or the button's margin).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var keyWidth: CGFloat { key.isEmpty ? 0 : ceil(intrinsicContentSize.width) }
    private var iconWidth: CGFloat { button?.image?.size.width ?? 0 }

    /// The room it takes before the frame of its button, `buttonWidth` wide, with its `lead` (it may use the
    /// button's own margin beside the icon); 0 with no key.
    func room(buttonWidth: CGFloat) -> CGFloat {
        key.isEmpty ? 0 : max(0, Self.lead + keyWidth + Self.gap - (buttonWidth - iconWidth) / 2)
    }

    /// Lays it out just before its button's icon, centred on it: shown while its owner has room for it
    /// (`shown`), otherwise kept there for the pointer.
    func place(shown: Bool) {
        guard let button, !button.isHidden else { return place(nil, shown: false) }
        let height = intrinsicContentSize.height
        place(NSRect(x: button.frame.midX - iconWidth / 2 - Self.gap - keyWidth, y: button.frame.midY - height / 2,
                     width: keyWidth, height: height), shown: shown)
    }

    /// Lays it out at `frame` (none: its button is hidden, and so is it). Shown while there is room for it
    /// there; without, it gave way, and shows there only while the pointer is on its icon.
    func place(_ frame: NSRect?, shown: Bool) {
        if let frame { self.frame = frame }
        isHidden = !shown || key.isEmpty || frame == nil
        gaveWay = !shown && !key.isEmpty && frame != nil
        if frame == nil { pointerOnIcon = false } // a hidden button gets no word that the pointer left
        updateOverlay()
    }

    /// The same place, for a button laid out by constraints.
    func constraintsBeforeIcon() -> [NSLayoutConstraint] {
        guard let button else { return [] }
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = key.isEmpty
        return [trailingAnchor.constraint(equalTo: button.centerXAnchor, constant: -iconWidth / 2 - Self.gap),
                centerYAnchor.constraint(equalTo: button.centerYAnchor)]
    }
}

/// A key that gave way, while the pointer is on its button: drawn over the row on its hint's backdrop, with
/// a little margin so it reads over the counts or a tab. A click goes through it to what is under it, and
/// VoiceOver hears nothing of it: the key is in the button's help.
final class KeyHintOverlay: NSView {
    static let padding: CGFloat = 4
    let label = NSTextField(labelWithString: "")
    private weak var hint: KeyHint?
    /// As its hint's owner, where it goes: the key sits in it as in the owner.
    private let ownerIsFlipped: Bool

    init(hint: KeyHint) {
        self.hint = hint
        ownerIsFlipped = hint.superview?.isFlipped ?? false
        super.init(frame: .zero)
        KeyHint.style(label)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { ownerIsFlipped }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidHide() {
        super.viewDidHide()
        if !isHidden { hint?.pointer(onIcon: false) } // its owner went with the pointer on the button
    }

    /// `key` with its text at `text`, in its owner's coordinates, its margin kept inside `area`.
    func show(_ key: String, at text: NSRect, within area: NSRect) {
        let box = text.insetBy(dx: -Self.padding, dy: -Self.padding).intersection(area)
        label.stringValue = key
        frame = box
        label.frame = text.offsetBy(dx: -box.minX, dy: -box.minY)
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (hint?.backdrop ?? Theme.bar).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
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
        // The editor's settings, the terminal's, notifications, every shortcut, and imports.
        let tabs = NSTabView()
        let editorTab = NSTabViewItem(identifier: "editor")
        editorTab.label = "Editor"
        editorTab.view = EditorSettingsView()
        let terminalTab = NSTabViewItem(identifier: "terminal")
        terminalTab.label = "Terminal"
        terminalTab.view = TerminalSettingsView()
        let notificationsTab = NSTabViewItem(identifier: "notifications")
        notificationsTab.label = "Notifications"
        notificationsTab.view = NotificationSettingsView()
        let keysTab = NSTabViewItem(identifier: "keys")
        keysTab.label = "Keyboard Shortcuts"
        keysTab.view = NSView()
        let importTab = NSTabViewItem(identifier: "import")
        importTab.label = "Import"
        importTab.view = ImportSettingsView()
        tabs.addTabViewItem(editorTab)
        tabs.addTabViewItem(terminalTab)
        tabs.addTabViewItem(notificationsTab)
        tabs.addTabViewItem(keysTab)
        tabs.addTabViewItem(importTab)
        let skillsTab = NSTabViewItem(identifier: "skills")
        skillsTab.label = "Skills"
        skillsTab.view = SkillsSettingsView()
        tabs.addTabViewItem(skillsTab)
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
        let shortcuts = KeyboardShortcuts.shared
        title = shortcuts.chord(for: commandID)?.display ?? "—"
        setAccessibilityLabel("Shortcut for \(shortcuts.title(of: commandID)): \(title)")
        toolTip = shortcuts.sharing(commandID)
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
        // A key the editor's command and a terminal command share is no clash (KeyBindings.canShareKey); a
        // command for both parts on ⌘D clashes with both.
        let owners = chord.map { shortcuts.bindings.owners(of: $0, defaults: shortcuts.defaults, except: commandID) } ?? []
        if let chord, !owners.isEmpty {
            let names = owners.map { "“\(shortcuts.title(of: $0))”" }.joined(separator: " and ")
            let alert = NSAlert()
            alert.messageText = "\(chord.display) is used by \(names)."
            alert.informativeText = "Use it for “\(shortcuts.title(of: commandID))” instead? \(names) \(owners.count == 1 ? "is" : "are") left without a shortcut."
            alert.addButton(withTitle: "Use It Here")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return showCurrent() }
            for owner in owners { shortcuts.set(nil, for: owner) }
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
    private let claude = NSButton(checkboxWithTitle: "Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code, opencode)", target: nil, action: nil)
    private let copilot = NSButton(checkboxWithTitle: "GitHub Copilot CLI in a tab sees the editor", target: nil, action: nil)
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
        copilot.target = self
        copilot.action = #selector(copilotChanged)
        copilot.toolTip = "Copilot CLI connects when it starts in a tab’s folder or an open project. Its proposed edits open as diffs to accept or reject."
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
        let note = NSTextField(wrappingLabelWithString: "Line height is a multiple of the font’s own line height; 1.35 reads well for code. The font size is shared with the terminal (⌘+ and ⌘-); the terminal’s font is in the Terminal tab. Claude Code, Gemini CLI, Qwen Code, opencode and Copilot CLI started in a new tab connect to Next Term as their IDE: the selected lines go with each prompt (and for Gemini and Qwen, the open files), never from .env files. They connect by themselves (Next Term turns Gemini's and Qwen's IDE mode on); turn these off to stop sharing. ⌥⌘K adds an @-mention to the prompt of Claude, opencode and Copilot.")
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
            row("", [copilot]),
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
        copilot.state = app.shareWithCopilot ? .on : .off
        control.state = app.agentControl ? .on : .off
        let status = !app.agentControl ? "Off: no agent can reach Next Term, and it is removed from the agents it was added to."
            : CommandLineTool.script == nil ? "Only the installed app adds itself to your agents."
            : "Any agent can open projects and tabs, start agents, give them prompts and read their screens. " + MCPRegistration.summary
        controlStatus.stringValue = status + MCPRegistration.claudeAppNote(on: app.agentControl)
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

    @objc private func copilotChanged() {
        AppDelegate.shared.shareWithCopilot = copilot.state == .on
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
