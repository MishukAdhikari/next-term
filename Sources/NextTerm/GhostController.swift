import AppKit
import NextTermCore

/// Suggestions while typing at the window, one per window: while a tab's suggestion shows, the keys that take it (→, End,
/// ⌃E, ⌃F: the whole command; ⌥→: its next word) and Esc, which hides it (GhostSession.press). Every other key, and these
/// while nothing shows, go on as they were; Tab completion's list has every key first, and Tab and Return are never looked
/// at here. Agents' keys over MCP never pass the window, so they never take a suggestion.
final class GhostController {
    private weak var owner: TerminalWindowController?

    init(owner: TerminalWindowController) {
        self.owner = owner
    }

    /// A key down for a terminal that Tab completion passed on (TerminalWindow.sendEvent). True: taken here.
    func handle(_ event: NSEvent, in view: NextTermView) -> Bool {
        guard event.type == .keyDown, let key = Self.key(event), let tab = tab(of: view), tab.ghost.isShowing else { return false }
        return tab.ghost.press(key)
    }

    /// Tab completion took a key in `view` (its list opens, or works): the suggestion there hides.
    func tabListTook(in view: NextTermView) {
        tab(of: view)?.ghost.hide()
    }

    /// Another pane, the editor or a field took the keyboard: a suggestion in any other terminal hides (it shows only while
    /// its terminal has the keyboard), and Forget This Suggestion goes off with it.
    func responderChanged(to responder: NSResponder?) {
        owner?.tabs.filter { $0.view !== responder }.forEach { $0.ghost.hide() }
    }

    private func tab(of view: NextTermView) -> TerminalTab? {
        owner?.tabs.first { $0.view === view }
    }

    /// The keys, matched as Tab completion matches its own: by key code (→ 124, End 119, Esc 53), and ⌃E and ⌃F by the
    /// letter, whatever the keyboard layout. fn-→ is End.
    static func key(_ event: NSEvent) -> GhostKeys.Key? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (124, []): return .right
        case (124, [.option]): return .optionRight
        case (119, []): return .end
        case (53, []): return .escape
        default:
            guard flags == [.control] else { return nil }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e": return .ctrlE
            case "f": return .ctrlF
            default: return nil
            }
        }
    }
}
