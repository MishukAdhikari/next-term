import AppKit
import NextTermCore
import SwiftTerm

/// One tab's side of suggestions while typing: its line's state (GhostState), the overlay (GhostTextView), the record's
/// answers and their checks.
///
/// Each report of the line from the ghost hook goes to the state with the gates as they are now. A new line asks the record
/// (CommandHistoryStore, off the main thread), and the first candidate that passes the checks (GhostValidation, on another
/// queue, two at a time at most, given 150 ms) shows if the line is still the one asked for. The overlay is placed only once
/// the shell's redraw is on screen: on the output after the report, or on the next turn of the main queue, once the cells
/// left of the cursor end with the line; not within 50 ms, it hides. Output that moves the cursor after that hides it until
/// the next report, and so do a resize, a scroll back, marked text, a paste, a selection and the window going to the back.
final class GhostSession {
    /// How long a suggestion's checks may take; one later shows nothing.
    static let checkDeadline: TimeInterval = 0.15
    /// How long a placement waits for the shell's redraw to be on screen.
    static let redrawWait: TimeInterval = 0.05
    /// Checks of a tab's that may run at once.
    static let maxChecks = 2

    private(set) weak var tab: TerminalTab?
    private(set) var state = GhostState()
    /// The hook's last `ghost` mark: whether zsh-autosuggestions draws suggestions in this shell.
    private(set) var hook: GhostProtocol.Hook?
    /// Since when a suggestion waits to be placed (the shell's redraw), and where it went (the cursor's cell).
    private var placing: TimeInterval?
    private var placed: (x: Int, y: Int)?
    private var checks = 0
    /// The newest candidates waiting for a check, while two are out.
    private var waiting: (gen: Int, candidates: [CommandHistory.Entry], folder: String)?
    /// When the last report was read: the perf budget's start.
    private var arrival: TimeInterval = 0
    private var resignObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    /// For the self-test: asks of the record, and suggestions placed.
    private(set) var asks = 0
    private(set) var shows = 0

    init(tab: TerminalTab) {
        self.tab = tab
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private(set) lazy var overlay: GhostTextView = {
        let overlay = GhostTextView(frame: .zero)
        tab?.view.addSubview(overlay, positioned: .below, relativeTo: nil)
        return overlay
    }()

    /// The overlay shows a suggestion now.
    var isShowing: Bool { state.shown != nil && placing == nil && overlayMade && !overlay.isHidden }
    private var overlayMade = false

    // MARK: the shell's marks

    func handle(_ message: GhostProtocol.Message) {
        switch message {
        case .hook(let hook):
            self.hook = hook
        case .buffer(let report):
            arrival = TerminalTab.now
            follow(state.report(report, gates: gates()))
        case .fallback:
            break
        }
    }

    private func follow(_ step: GhostState.Step) {
        switch step {
        case .ask(let gen, let prefix):
            hideOverlay()
            ask(gen, prefix)
        case .trimmed:
            placeAfterRedraw()
        case .hidden:
            hideOverlay()
        case .none:
            break
        }
    }

    /// The record, for the newest commands starting with `prefix` from the tab's folder; then the checks.
    private func ask(_ gen: Int, _ prefix: String) {
        guard let tab else { return }
        asks += 1
        let folder = tab.directory
        CommandHistoryStore.shared.query(prefix: prefix, folder: folder) { [weak self] candidates in
            self?.answered(gen, candidates, folder: folder)
        }
    }

    private func answered(_ gen: Int, _ candidates: [CommandHistory.Entry], folder: String) {
        guard state.asked == gen else { return }
        guard !candidates.isEmpty else { return }
        check(gen, candidates, folder: folder)
    }

    /// The checks for generation `gen`'s candidates, on a queue of their own. With two of the tab's out already (a folder
    /// on a slow volume), the newest waits for one of them to finish, and replaces any older one waiting.
    private func check(_ gen: Int, _ candidates: [CommandHistory.Entry], folder: String) {
        guard checks < Self.maxChecks else {
            waiting = (gen, candidates, folder)
            return
        }
        checks += 1
        let started = TerminalTab.now
        let home = NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async {
            let chosen = GhostValidation.first(candidates, cwd: folder, home: home, probe: .disk)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checked(gen, chosen, late: TerminalTab.now - started > Self.checkDeadline)
            }
        }
    }

    private func checked(_ gen: Int, _ chosen: CommandHistory.Entry?, late: Bool) {
        checks -= 1
        if let next = waiting {
            waiting = nil
            if state.asked == next.gen { check(next.gen, next.candidates, folder: next.folder) }
        }
        guard !late, let chosen, state.answer(gen: gen, command: chosen.line) else { return }
        placeAfterRedraw()
    }

    // MARK: placing it

    /// The overlay goes where the shell's redraw put the cursor, once it is on screen.
    private func placeAfterRedraw() {
        placing = TerminalTab.now
        DispatchQueue.main.async { [weak self] in self?.place(late: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redrawWait) { [weak self] in self?.place(late: true) }
    }

    /// Places the suggestion when the cells left of the cursor end with the line's last 16 characters; past the wait, it
    /// hides.
    private func place(late: Bool) {
        guard let started = placing else { return }
        guard let shown = state.shown, let buffer = state.report?.buffer, let tab, gates().open else {
            placing = nil
            state.hide()
            return hideOverlay()
        }
        guard let left = tab.lineLeftOfCursor(), left.hasSuffix(String(buffer.suffix(16))) else {
            if late || TerminalTab.now - started >= Self.redrawWait {
                placing = nil
                state.hide()
                hideOverlay()
            }
            return
        }
        placing = nil
        draw(shown, in: tab.view)
    }

    private func draw(_ shown: GhostSuggestion, in view: NextTermView) {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        let available = rightEdge(of: terminal, row: cursor.y, after: cursor.x) - cursor.x - 1
        guard let text = GhostClip.fit(shown.remainder, available: available) else {
            state.hide()
            return hideOverlay()
        }
        let cell = view.cellSize
        let origin = CGPoint(x: CGFloat(cursor.x) * cell.width, y: view.bounds.height - cell.height * CGFloat(cursor.y + 1))
        let workspace = NSWorkspace.shared
        overlayMade = true
        overlay.show(text, at: origin, cell: cell, font: view.font, colour: Self.colour(for: view),
                     underline: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        placed = (cursor.x, cursor.y)
        shows += 1
        watch(view.window)
        _ = Self.displayOptions
        overlay.ghostShown(arrival)
    }

    /// The first column right of the cursor with something drawn in it (a right prompt), or the row's end.
    private func rightEdge(of terminal: Terminal, row: Int, after column: Int) -> Int {
        guard let line = terminal.getLine(row: row) else { return terminal.cols }
        let end = min(terminal.cols, line.count)
        var x = column + 1
        while x < end {
            let character = line[x].getCharacter()
            if character != "\u{0}", character != " " { return x }
            x += 1
        }
        return terminal.cols
    }

    /// The suggestion's colour for the terminal's theme (GhostColour), made again only when the theme or Increase Contrast
    /// changed.
    private static var colourCache: (foreground: NSColor, background: NSColor, increase: Bool, colour: NSColor)?

    static func colour(for view: TerminalView) -> NSColor {
        let increase = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let foreground = view.nativeForegroundColor, background = view.nativeBackgroundColor
        if let cache = colourCache, cache.foreground === foreground, cache.background === background, cache.increase == increase {
            return cache.colour
        }
        let derived = GhostColour.derive(foreground: rgb(foreground), background: rgb(background), increaseContrast: increase)
        let colour = NSColor(hex: derived)
        colourCache = (foreground, background, increase, colour)
        return colour
    }

    static func rgb(_ colour: NSColor) -> UInt32 {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return 0x808080 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
    }

    /// Increase Contrast or Differentiate Without Colour turned on or off: a suggestion showing is drawn again at once, in its
    /// new colour and with or without its underline. Watched from the first suggestion drawn.
    private static let displayOptions: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            for controller in AppDelegate.shared?.controllers ?? [] {
                for tab in controller.tabs { tab.ghost.restyle() }
            }
        }

    /// The suggestion showing, drawn again where it is (the display options changed).
    private func restyle() {
        guard isShowing, let shown = state.shown, let view = tab?.view else { return }
        draw(shown, in: view)
    }

    /// The window going to the back hides the suggestion at once.
    private func watch(_ window: NSWindow?) {
        guard let window, window !== observedWindow else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        observedWindow = window
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in self?.hide() }
    }

    private func hideOverlay() {
        placed = nil
        if overlayMade { overlay.hide() }
    }

    // MARK: keys (GhostController)

    /// A key that takes the suggestion showing, or Esc: true, taken, so SwiftTerm never sees it. An accept goes to the
    /// hook as a frame (GhostState.accept) through the tab's ordered writer, with the bytes the key sends otherwise,
    /// which the hook gives back to zsh where the line or the key's binding changed. Esc hides the suggestion for the
    /// rest of the line, and goes on to zsh in vi insert mode.
    func press(_ key: GhostKeys.Key) -> Bool {
        guard isShowing, let view = tab?.view else { return false }
        if key == .escape {
            let goesOn = state.escapeGoesOn
            state.escape()
            hideOverlay()
            return !goesOn
        }
        let terminal = view.getTerminal()
        let bytes = GhostKeys.bytes(key, applicationCursor: terminal.applicationCursor, optionAsMeta: view.optionAsMetaKey)
        guard let frame = state.accept(key, bytes: bytes) else { return false }
        placing = nil
        hideOverlay()
        view.send(data: frame[...])
        return true
    }

    // MARK: what the tab says

    /// The facts the state needs besides the line: the cheap ones first, the shell's process group last.
    private func gates() -> GhostGates {
        guard let tab, GhostPreferences.isOn, !GhostPreferences.privateMode else { return GhostGates(on: false) }
        let view = tab.view
        let window = view.window
        var gates = GhostGates()
        gates.viewReady = (!view.canScroll || view.scrollPosition >= 1) && !view.hasMarkedText()
        gates.noTabList = !tab.completion.isListOpen && tab.completion.state.pendingID == nil
        gates.focused = window?.isKeyWindow == true && window?.firstResponder === view && !view.awaitsChoice
        gates.notDriven = !MCPControl.isDriven(tab)
        // Where zsh-autosuggestions draws its own (the hook says it is on), none of Next Term's; a plugin's ghost on the line
        // keeps them off too (GhostState).
        gates.noPlugin = hook?.enabled != true
        guard gates.open else { return gates }
        let terminal = view.getTerminal()
        gates.shellAlone = tab.remote == nil && !tab.status.running && !terminal.isCurrentBufferAlternate && tab.shellAlone
        return gates
    }

    /// Who shows suggestions in this tab, for its tooltip; nil where none can (a server, a shell without the hook).
    var label: String? {
        guard tab?.remote == nil, hook != nil else { return nil }
        guard GhostPreferences.isOn else { return "Suggestions: off" }
        if GhostPreferences.privateMode { return "Suggestions: off (Private Mode)" }
        return hook?.enabled == true ? "Suggestions: zsh-autosuggestions" : "Suggestions: Next Term’s"
    }

    // MARK: what happened in the tab

    /// Output reached the terminal: a placement waiting for the shell's redraw looks again; a suggestion placed hides when
    /// the cursor moved since.
    func output() {
        if placing != nil { return place(late: false) }
        guard let placed, let view = tab?.view else { return }
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        if cursor.x != placed.x || cursor.y != placed.y || terminal.isCurrentBufferAlternate { hide() }
    }

    /// A key of yours in the tab (or a paste, a drop): suggestions may show on this line.
    func userKey() {
        state.userKey()
    }

    /// Hidden until the next report: a resize, a font change, a scroll back, marked text, a paste, a selection, the window
    /// going to the back.
    func hide() {
        placing = nil
        state.hide()
        hideOverlay()
    }

    func viewChanged() { hide() }

    /// The view scrolled: hidden unless it is at the bottom.
    func scrolled() {
        guard let view = tab?.view, view.canScroll, view.scrollPosition < 1 else { return }
        hide()
    }

    /// A command started, or the line ended otherwise: nothing shows until the next line.
    func lineEnded() {
        placing = nil
        state.lineEnded()
        hideOverlay()
    }

    /// The shell was replaced (`exec zsh`): the new one says what it is.
    func shellReplaced() {
        placing = nil
        state = GhostState()
        hook = nil
        hideOverlay()
    }
}

extension GhostValidation.FileProbe {
    /// The disk, by `stat` and `access`: nothing is opened or run.
    static let disk = GhostValidation.FileProbe(
        exists: { path in
            var info = stat()
            return stat(path, &info) == 0
        },
        isFolder: { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        },
        isExecutable: { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        })
}
