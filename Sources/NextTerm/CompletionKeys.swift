import AppKit
import NextTermCore

/// Tab completion at the window, one per window: a real Tab in a tab whose shell can take it becomes the
/// private key (CompletionSession), and while a list is open, the keys that work it. Everything else goes on
/// as it was: ⌘ chords, Shift-Tab, a Tab while a program runs, on the alternate screen, with marked text, or
/// with Tab completion off. Agents' keys over MCP never pass the window, so they are never caught.
final class CompletionController {
    private weak var owner: TerminalWindowController?
    private(set) lazy var popup: CompletionPopup = {
        let popup = CompletionPopup()
        popup.onPick = { [weak self] row in self?.shown?.accept(row) }
        return popup
    }()
    /// The session whose list the popup shows.
    private weak var shown: CompletionSession?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(owner: TerminalWindowController) {
        self.owner = owner
        let center = NotificationCenter.default
        // The window going to the back, resizing or going full screen, and another app taking over, close it.
        let closing: [(Notification.Name, Any?)] = [
            (NSWindow.didResignKeyNotification, owner.window), (NSWindow.didResizeNotification, owner.window),
            (NSWindow.willEnterFullScreenNotification, owner.window), (NSWindow.willExitFullScreenNotification, owner.window),
            (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in closing {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.closeShown() })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        removeMonitors()
    }

    /// A key down for a terminal, before it gets it (TerminalWindow.sendEvent). True: handled here.
    func handle(_ event: NSEvent, in view: NextTermView) -> Bool {
        guard event.type == .keyDown, let tab = owner?.tabs.first(where: { $0.view === view }) else { return false }
        let session = tab.completion
        if session.isListOpen { return listKey(event, session) }
        guard CompletionPreferences.isOn, Self.isPlainTab(event) else { return false }
        guard session.state.isArmed || session.state.holding else { return false }
        guard !view.hasMarkedText(), !view.getTerminal().isCurrentBufferAlternate else { return false }
        // Scrolled back: the line being completed is at the bottom.
        if view.canScroll, view.scrollPosition < 1 { view.scroll(toPosition: 1) }
        // Where a plugin owns Tab, the user's choice decides; the first time, they are asked.
        if !session.state.holding, let plugin = session.owner {
            switch CompletionPreferences.answer(for: plugin) {
            case .nextTerm: break
            case .plugin: return session.plainTab()
            case .ask:
                return ask(plugin, session, tab) || session.plainTab()
            }
        }
        watch(session)
        return session.realTab()
    }

    /// The question, over the window; the Tab that raised it waits for the answer. If the shell moved on
    /// meanwhile (an agent typed, a command started), that Tab goes nowhere. False: another sheet is up, so
    /// the Tab is the plugin's this time.
    private func ask(_ plugin: CompletionOwner.Plugin, _ session: CompletionSession, _ tab: TerminalTab) -> Bool {
        guard let window = owner?.window, window.attachedSheet == nil else { return false }
        let writes = session.writes
        let arm = session.state.arm
        CompletionPluginQuestion.ask(plugin, in: window) { [weak self] answer in
            switch answer {
            case .nextTerm: CompletionPreferences.choose(.nextTerm, for: plugin)
            case .plugin: CompletionPreferences.choose(.plugin, for: plugin)
            case .notNow: CompletionPreferences.dismissed(plugin)
            }
            CompletionSession.syncAll()
            let unchanged = session.state.isArmed && session.state.arm?.sameLine(as: arm) == true && session.writes == writes
            guard unchanged, tab.view.window === window, window.makeFirstResponder(tab.view) else { return }
            if answer == .nextTerm {
                self?.watch(session)
                if !session.realTab() { session.sendPlainTab() }
            } else {
                session.sendPlainTab()
            }
        }
        return true
    }

    /// Tab with no ⌘, ⌥, ⌃ or ⇧.
    static func isPlainTab(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// The keys while a list is open: ↑ ↓ (and ⇧Tab, ^P, ^N) choose, Tab and Return insert, Esc closes and is
    /// never sent; ^C, ^J and → close and go on to the shell; letters and Backspace go to the shell, which
    /// reports the word for the list to narrow.
    private func listKey(_ event: NSEvent, _ session: CompletionSession) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ^N, ^P, ^C and ^J by the letter, whatever the keyboard layout.
        let letter = flags == [.control] ? event.charactersIgnoringModifiers?.lowercased() : nil
        switch (event.keyCode, flags) {
        case (48, []), (36, []), (76, []): // Tab, Return, Enter
            // While Loading, or before the list shows, there is nothing to insert yet.
            if session.isShown, shown === session, session.list?.rows.isEmpty == false { session.accept(popup.selected) }
            return true
        case (125, []): // ↓
            popup.move(by: 1)
            return true
        case (126, []), (48, [.shift]): // ↑, ⇧Tab
            popup.move(by: -1)
            return true
        case (53, []): // Esc
            session.closeList()
            return true
        case (124, []): // →
            session.closeList()
            return false
        default:
            switch letter {
            case "n":
                popup.move(by: 1)
                return true
            case "p":
                popup.move(by: -1)
                return true
            case "c", "j":
                session.closeList()
                return false
            default:
                if flags.contains(.command) { session.closeList() }
                return false
            }
        }
    }

    // MARK: the popup

    private func watch(_ session: CompletionSession) {
        session.onChange = { [weak self] session in self?.refresh(session) }
    }

    /// Shows the session's list at its caret, or hides it. A list that can't be shown (the window isn't in
    /// front, its terminal doesn't have the keyboard) goes back to the shell.
    func refresh(_ session: CompletionSession) {
        guard session.isShown else {
            if shown === session || shown == nil { hide() }
            return
        }
        guard let tab = session.tab, let window = owner?.window, tab.view.window === window, window.isKeyWindow,
              window.firstResponder === tab.view else {
            hide()
            return session.cannotShow()
        }
        if let other = shown, other !== session { other.closeList() }
        let rows = session.list?.rows ?? []
        let loading = session.list == nil || (session.list?.isZsh == true && rows.isEmpty)
        if !loading, rows.isEmpty { return session.closeList() } // nothing matches what was typed
        // Said when it opens, and when the Loading row gives way to the list.
        let announce = !popup.isVisible || (popup.loading && !loading)
        popup.show(rows, loading: loading, footer: Self.footer(session.list), anchor: anchor(tab, word: session.list?.word ?? ""),
                   over: window)
        shown = session
        addMonitors()
        if announce { popup.announceOpen() }
    }

    /// "2,000 of 10,000. Type to narrow." when only the best are listed.
    static func footer(_ list: CompletionList?) -> String? {
        guard let list else { return nil }
        let count = list.rows.count
        if count < list.total { return "\(count.formatted()) of \(list.total.formatted()). Type to narrow." }
        if !list.exact { return "\(count.formatted()) shown. Type to narrow." }
        return nil
    }

    /// The screen rectangle of the word's first cell: the caret's, moved back by the word's width in cells.
    private func anchor(_ tab: TerminalTab, word: String) -> NSRect {
        let caret = tab.view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let cell = ("W" as NSString).size(withAttributes: [.font: tab.view.font]).width
        var cells = 0
        for scalar in word.unicodeScalars { cells += max(0, Int(wcwidth(wchar_t(bitPattern: scalar.value)))) }
        return NSRect(x: caret.minX - CGFloat(cells) * cell, y: caret.minY, width: cell, height: caret.height)
    }

    private func hide() {
        popup.hide()
        shown = nil
        removeMonitors()
    }

    /// Closes the list on show (Esc's way, nothing sent but the close).
    func closeShown() {
        guard let session = shown else { return }
        session.closeList()
        hide()
    }

    /// Another pane or tab took the keyboard.
    func responderChanged() {
        guard let session = shown, let window = owner?.window, window.firstResponder !== session.tab?.view else { return }
        closeShown()
    }

    /// While the list shows: a click outside it, a scroll, or a ⌘ chord (which the menus may take before the
    /// window sees it) closes it.
    private func addMonitors() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if let self, event.window !== self.popup.window { self.closeShown() }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let chord = event.modifierFlags.contains(.command) || (event.keyCode == 48 && event.modifierFlags.contains(.control))
            if chord { self?.closeShown() }
            return event
        }) { monitors.append(monitor) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
