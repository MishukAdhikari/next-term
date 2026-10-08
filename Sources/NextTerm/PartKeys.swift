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
