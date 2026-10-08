import AppKit
import NextTermCore

/// Tab completion at the window, one per window: a real Tab in a tab whose shell can take it becomes the
/// private key (CompletionSession). Everything else goes on as it was: ⌘ chords, Shift-Tab, a Tab while a
/// program runs, on the alternate screen, with marked text, or with Tab completion off. Agents' keys over MCP
/// never pass the window, so they are never caught.
final class CompletionController {
    private weak var owner: TerminalWindowController?

    init(owner: TerminalWindowController) {
        self.owner = owner
    }

    /// A key down for a terminal, before it gets it (TerminalWindow.sendEvent). True: handled here.
    func handle(_ event: NSEvent, in view: NextTermView) -> Bool {
        guard CompletionPreferences.isOn, Self.isPlainTab(event),
              let tab = owner?.tabs.first(where: { $0.view === view }) else { return false }
        let session = tab.completion
        guard session.state.isArmed || session.state.holding else { return false }
        guard !view.hasMarkedText(), !view.getTerminal().isCurrentBufferAlternate else { return false }
        // Scrolled back: the line being completed is at the bottom.
        if view.canScroll, view.scrollPosition < 1 { view.scroll(toPosition: 1) }
        return session.realTab()
    }

    /// Tab with no ⌘, ⌥, ⌃ or ⇧.
    static func isPlainTab(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}
