import AppKit
import NextTermCore

// The keys outside the menus (KeyBindings.partCommands): the sidebar's right-click menu's commands, the Git lists'
// Open, a proposed edit's Accept and the branch popup's keys. Settings › Keyboard Shortcuts lists them with the part
// of the window they belong to, and changes them as it changes a menu command's; each part answers its own keys,
// only while it has the keyboard (Accept: while it shows).
extension KeyboardShortcuts {
    /// The commands outside the menus, as Settings lists them: the part of the window in place of a menu path.
    static var partCommands: [Command] {
        KeyBindings.partCommands.map { Command(id: $0.id, title: $0.title, path: $0.part.name, defaultChord: $0.chord, item: nil) }
    }

    /// "Copy Path (Project Sidebar)": a command's title, with its part for a key outside the menus, so it reads apart from
    /// File › Copy Path (Settings' clash alert, VoiceOver, the import's preview).
    func placedTitle(of id: String) -> String {
        guard let part = KeyBindings.partCommands.first(where: { $0.id == id })?.part else { return title(of: id) }
        return "\(title(of: id)) (\(part.name))"
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

    /// A right-click or ⋯ menu's item as the command it is in Settings (its identifier), with the key that command has
    /// now, shown as the menu bar shows one; none while it has none. Only shown: AppKit looks for keys in the menu bar
    /// alone, never in a view's menu, so the key still goes to the command's own handler (the sidebar's, or the menu
    /// bar's for a menu command), and only where that handler answers it. Menus built when they open show a change at once.
    /// A key without ⌘ or ⌃ (the sidebar's ↩ for Rename) is named in the item's tooltip instead, "Rename (↩)": on the
    /// item it could be the open menu's own key, and ↩ there chooses the highlighted item.
    static func show(_ command: String, on item: NSMenuItem) {
        item.identifier = NSUserInterfaceItemIdentifier(command)
        let chord = shared.chord(for: command)
        if let chord, !chord.isUsable {
            set(nil, on: item)
            item.toolTip = shared.hint(shared.title(of: command), command: command)
        } else {
            set(chord, on: item)
        }
    }
}

/// A view's tooltip that names the key of a command outside the menus ("Fetch from all remotes (⌘R)", "Accept (⌘↩):
/// Claude then writes the file"), and follows it. Kept by the view's owner for as long as the view. Only the
/// tooltip: the part answers the key itself (a button's own key equivalent would want "Y" for ⇧⌘Y).
final class PartToolTip: NSObject {
    private weak var view: NSView?
    private let words: String
    private let id: String
    private let rest: String

    /// The tooltip: `words`, the key in brackets, then `rest`.
    init(_ view: NSView, _ words: String, command id: String, then rest: String = "") {
        self.view = view
        self.words = words
        self.id = id
        self.rest = rest
        super.init()
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: KeyboardShortcuts.changed, object: nil)
    }

    @objc private func update() {
        view?.toolTip = KeyboardShortcuts.shared.hint(words, command: id) + rest
    }
}
