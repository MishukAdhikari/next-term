import AppKit
import NextTermCore

// The keys outside the menus (KeyBindings.partCommands): the sidebar's Rename, Move to Trash and Open, the Git
// lists' Open, a proposed edit's Accept and the branch popup's keys. Settings › Keyboard Shortcuts lists them with
// the part of the window they belong to, and changes them as it changes a menu command's; each part answers its
// own keys, only where it always did.
extension KeyboardShortcuts {
    /// The commands outside the menus, as Settings lists them: the part of the window in place of a menu path.
    static var partCommands: [Command] {
        KeyBindings.partCommands.map { Command(id: $0.id, title: $0.title, path: $0.part.name, defaultChord: $0.chord, item: nil) }
    }

    /// The command of `part` that `event` presses (with its key as set in Settings), if any.
    func partCommand(for event: NSEvent, in part: KeyBindings.Part) -> String? {
        guard event.type == .keyDown, let pressed = Self.chord(from: event) else { return nil }
        return KeyBindings.partCommands.first { $0.part == part && chord(for: $0.id) == pressed }?.id
    }

    /// "Fetch from all remotes (⌘R)": the words with the key a command outside the menus has now, or alone.
    func hint(_ words: String, command id: String) -> String {
        guard let chord = chord(for: id) else { return words }
        return "\(words) (\(chord.display))"
    }
}

/// A button's key equivalent on a command's key as set in Settings, and a tooltip that names it ("Accept (⌘↩): …"),
/// both following a change. Kept by the button's owner for as long as the button.
final class ButtonShortcut: NSObject {
    private weak var button: NSButton?
    private let id: String
    private let words: String
    private let rest: String

    /// The tooltip: `words`, the key in brackets, then `rest`.
    init(_ button: NSButton, _ id: String, tip words: String, _ rest: String = "") {
        self.button = button
        self.id = id
        self.words = words
        self.rest = rest
        super.init()
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: KeyboardShortcuts.changed, object: nil)
    }

    @objc private func update() {
        guard let button else { return }
        let chord = KeyboardShortcuts.shared.chord(for: id)
        // A button compares the character the key types: ⌫ is DEL there, where menus spell it BS.
        let key = chord?.key ?? ""
        button.keyEquivalent = key == "\u{8}" ? "\u{7F}" : key
        var mask: NSEvent.ModifierFlags = []
        if chord?.command == true { mask.insert(.command) }
        if chord?.shift == true { mask.insert(.shift) }
        if chord?.option == true { mask.insert(.option) }
        if chord?.control == true { mask.insert(.control) }
        button.keyEquivalentModifierMask = mask
        button.toolTip = KeyboardShortcuts.shared.hint(words, command: id) + rest
    }
}

/// A view's tooltip that names the key of a command outside the menus ("Fetch from all remotes (⌘R)"), and follows
/// it. Kept by the view's owner for as long as the view.
final class PartToolTip: NSObject {
    private weak var view: NSView?
    private let words: String
    private let id: String

    init(_ view: NSView, _ words: String, command id: String) {
        self.view = view
        self.words = words
        self.id = id
        super.init()
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: KeyboardShortcuts.changed, object: nil)
    }

    @objc private func update() {
        view?.toolTip = KeyboardShortcuts.shared.hint(words, command: id)
    }
}
