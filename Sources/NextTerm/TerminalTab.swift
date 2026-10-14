import AppKit
import NextTermCore
import SwiftTerm

/// SwiftTerm's local-process view, with hooks for the activity the status machine needs.
final class NextTermView: LocalProcessTerminalView {
    static let scrollbackLines = 10_000

    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    /// A key you pressed in the view (TerminalWindow.sendEvent) or a paste: you, not Next Term or an agent
    /// over MCP, which send text without either.
    var onKeyboard: (() -> Void)?
    var onBell: (() -> Void)?
    /// Only beep for the tab the user is looking at; background tabs show a dot instead.
    var beepAllowed = true
    /// False once the shell has ended: there is nothing left to send keystrokes to.
    var acceptsInput = true
    /// An agent opened this tab over MCP and the user hasn't chosen it yet: it takes no keyboard (TerminalWindow refuses
    /// it) until they click it, pick its tab, move to its pane, or paste or drop into it, so nothing meant for the tab
    /// they were typing in lands in an agent's prompt (AgentArrival). A hint at its top says so.
    var awaitsChoice = false {
        didSet { if awaitsChoice != oldValue { showChoiceHint() } }
    }
    /// What the hint says.
    var choiceHint = "An agent opened this tab. Click to type here." {
        didSet { hintView?.stringValue = choiceHint }
    }
    private var hintView: NSTextField?

    private func showChoiceHint() {
        hintView?.removeFromSuperview()
        hintView = nil
        guard awaitsChoice else { return }
        let hint = NSTextField(labelWithString: choiceHint)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        hint.textColor = .white
        hint.drawsBackground = true
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 5
        hint.layer?.masksToBounds = true
        hint.setAccessibilityLabel(choiceHint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
        hintView = hint
    }

    /// Takes keystrokes before the program would (a remote tab waiting to reconnect); true: handled.
    var interceptInput: ((ArraySlice<UInt8>) -> Bool)?
    /// Tab completion's ordered writer (CompletionSession): true, the write waits and goes out later.
    var completionGate: ((ArraySlice<UInt8>) -> Bool)?
    /// Each write `inputWrites` counts, as it comes, before that gate: a line it ends is one Next Term can no longer name
    /// for zsh's history (TerminalTab.history).
    var onWrite: ((ArraySlice<UInt8>) -> Void)?
    /// Writes into the shell other than the terminal's own answers: every key, paste and drop, and all text anything types
    /// into the tab (Insert Path, a suggested command, Send to Agent, MCP, the restore itself). A restored action types
    /// only onto a line nothing else wrote to (`RestoreLayout.LineWatch`), whether or not what wrote said it was the user.
    private(set) var inputWrites = 0
    /// The terminal is answering a program's question (where the cursor is, its colours, focus), which is not input.
    private var answering = false
    /// The shell has printed something.
    private var hasOutput = false
    /// What the shell printed, watched from its first byte while a restore may feed a note into the tab
    /// (`watchSequences`), the notes waiting for it to be between sequences, and whether the watch ends once they are fed.
    private var sequences: TerminalText.SequenceWatch?
    private var waitingNotes: [String] = []
    private var watchEnds = false

    /// A key Clear Buffer shares with a command for everywhere (⌘K, Commit… under the JetBrains set) is Clear
    /// Buffer's here, before the menus, while this terminal has the keyboard (KeyboardShortcuts.terminalKeys).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let item = KeyboardShortcuts.shared.terminalItem(for: event),
              let action = item.action else { return super.performKeyEquivalent(with: event) }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }

    /// Bytes of output parsed so far: what is new since a poll last looked (the served-URL scan).
    private(set) var outputBytes = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        hasOutput = true
        super.dataReceived(slice: slice) // parse first: OSC marks in this chunk update the status
        outputBytes &+= slice.count
        if sequences != nil { watched(slice) }
        onOutput?()
    }

    /// Starts watching what the shell prints, so a note can be fed between sequences (`feedBetweenSequences`). Only
    /// before the shell has printed anything: a watch started later could not tell where its output stands.
    func watchSequences() {
        guard !hasOutput, sequences == nil else { return }
        sequences = TerminalText.SequenceWatch()
        watchEnds = false
    }

    /// No more notes will be fed: the watch stops once those waiting are fed.
    func endSequenceWatch() {
        watchEnds = true
        if waitingNotes.isEmpty { sequences = nil }
    }

    /// Feeds `text`, ready to feed (no sequence of its own left open), once what the shell printed is between sequences
    /// (TerminalText.SequenceWatch): now, or after the first read that leaves it there. Text fed inside one would join
    /// it. Unwatched, now.
    func feedBetweenSequences(_ text: String) {
        guard let sequences, !sequences.isBetweenSequences else { return feed(text: text) }
        waitingNotes.append(text)
    }

    /// A read the terminal parsed, followed by the watch; the notes waiting are fed once it ends between sequences.
    private func watched(_ slice: ArraySlice<UInt8>) {
        sequences?.read(slice)
        guard sequences?.isBetweenSequences == true, !waitingNotes.isEmpty || watchEnds else { return }
        let notes = waitingNotes
        waitingNotes = []
        for note in notes { feed(text: note) }
        if watchEnds { sequences = nil }
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        answering = true
        defer { answering = false }
        // A right or middle release being reported: SwiftTerm 1.20 sends every SGR release as the left button's.
        super.send(source: source, data: releasing.map { MouseReport.sgrRelease(data, button: $0) } ?? data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let interceptInput, interceptInput(data) { return }
        guard acceptsInput else { return }
        if !answering {
            inputWrites += 1
            onWrite?(data)
        }
        if let completionGate, completionGate(data) { return }
        onInput?()
        super.send(source: source, data: Self.withoutScreenChecksum(data))
    }

    /// Tab completion's own keys, and the writes it held, past its gate.
    func sendPastGate(_ data: ArraySlice<UInt8>) {
        guard acceptsInput else { return }
        onInput?()
        super.send(source: self, data: Self.withoutScreenChecksum(data))
    }

    /// DECRQCRA asks the terminal for a checksum of a screen rectangle; for one cell, the checksum is the
    /// character itself, so anything that can print to the terminal (a remote host over ssh) could read
    /// the whole screen back cell by cell. SwiftTerm always answers, so answer "0000" for every request.
    static func withoutScreenChecksum(_ data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        // DCS Pid ! ~ xxxx ST, with DCS as ESC P (or 8-bit 0x90) and ST as ESC \ (or 0x9C).
        guard data.count >= 8, data.count <= 32,
              data.first == 0x90 || (data.first == 0x1B && data.dropFirst().first == UInt8(ascii: "P")),
              let text = String(bytes: data, encoding: .isoLatin1),
              let range = text.range(of: #"!~[0-9A-Fa-f]+"#, options: .regularExpression) else { return data }
        let neutral = text.replacingCharacters(in: range, with: "!~0000")
        return ArraySlice(neutral.data(using: .isoLatin1) ?? Data(data))
    }

    /// ⌘V. Pasted text loses every control character except tab and newline: an escape sequence on the
    /// clipboard (from OSC 52, a web page or a file name) could otherwise end bracketed paste early and
    /// run the rest as typed input.
    override func paste(_ sender: Any) {
        guard acceptsInput, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onKeyboard?()
        let kept = String(text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || !ShellQuote.isControl($0) })
        let lines = kept.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + lines + "\u{1b}[201~" : lines)
    }

    // MARK: drawing only what can be seen

    /// SwiftTerm marks what its output changed through setNeedsDisplay(_:) (its own override of it is `#if false`).
    /// While nobody can see the window (NSWindow.canBeSeen), or before the view is in one, the gate drops those marks
    /// and remembers them; the whole terminal is drawn once when it can be seen again. The output is still parsed
    /// meanwhile: only the drawing waits. Not `needsDisplay`, which SwiftTerm sets only on a resize, a selection or a
    /// font change: overriding it cost an idle window with 10 tabs 4 M instructions a second (30% more), and those
    /// rare marks would draw once while hidden at most.
    private var drawGate = DrawGate(visible: false)
    private var visibilityObservers: [NSObjectProtocol] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard mayDraw() else { return }
        super.setNeedsDisplay(invalidRect)
    }

    /// Asked at each mark, so a window seen again draws its next change even before its notification comes.
    private func mayDraw() -> Bool {
        drawIfSeenAgain()
        return drawGate.invalidate()
    }

    /// Draws all of the terminal if it can be seen again after changes it did not draw. On every visibility
    /// notification, and from the window's ticker in case one never comes (a self-test run's window ordered in).
    func drawIfSeenAgain() {
        let seen = window?.canBeSeen ?? false
        guard seen != drawGate.visible else { return }
        if drawGate.setVisible(seen) { needsDisplay = true }
    }

    /// Changes dropped while the terminal could not be seen, for the self-test.
    var undrawnChanges: Int { drawGate.dropped }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
        visibilityObservers = []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            visibilityObservers = NSWindow.visibilityNotifications.map { name, ofApp in
                NotificationCenter.default.addObserver(forName: name, object: ofApp ? NSApp : window, queue: .main) { [weak self] _ in
                    self?.drawIfSeenAgain()
                }
            }
        }
        drawIfSeenAgain()
    }

    deinit {
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func bell(source: Terminal) {
        onBell?()
        if beepAllowed { super.bell(source: source) }
    }

    /// A program putting the cursor back (DECSCUSR 0 or 1, which arrive as a blinking block) gets the one chosen
    /// in Settings › Terminal.
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let chosen = Preferences.terminalCursorStyle
        if newStyle == .blinkBlock && chosen != .blinkBlock { return source.setCursorStyle(chosen) }
        super.cursorStyleChanged(source: source, newStyle: newStyle)
    }

    // MARK: drop files (from Finder or the project tree) to type their paths, like Terminal.app

    override init(frame: CGRect) {
        super.init(frame: frame, font: nil, options: Self.startingOptions)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func droppedPaths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        guard !paths.isEmpty else { return false }
        onKeyboard?() // a drop is the user's input, as a key or a paste is
        typeIn(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Types text at the prompt as a paste: with bracketed paste on (zsh's default), the line editor
    /// inserts it literally and never runs it, even if it contained a newline. Returns the text as typed.
    @discardableResult
    func typeIn(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { !ShellQuote.isControl($0) })
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + clean + "\u{1b}[201~" : clean)
        return clean
    }

    /// Types text as a paste that keeps its line breaks (a prompt for an agent): other control
    /// characters are dropped, so the text cannot end the paste early or press keys. Returns the text as typed.
    @discardableResult
    func typeText(_ text: String) -> String {
        let kept = String(text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || !ShellQuote.isControl($0) })
        let lines = kept.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + lines + "\u{1b}[201~" : lines)
        return lines
    }

    // MARK: links (⌘-click): web and mail links open; files open safely; other schemes are refused

    /// Folder that relative paths in the output are relative to.
    var linkBaseDirectory: (() -> String)?
    /// False for a tab on a server: paths in its output name the server's files, not this Mac's.
    var opensFiles = true
    /// Opens a file in the editor, at a line and column when the link has them (`src/a.ts:42:7`).
    var openFile: ((URL, _ line: Int?, _ column: Int) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let target = target(of: link) else { return NSSound.beep() }
        open(target)
    }

    /// What a link in the output opens: a web or mail address, or a file on this Mac at a line.
    enum LinkTarget: Equatable {
        case web(URL)
        case file(URL, line: Int?, column: Int)
    }

    /// What ⌘-click (or the right-click menu) does with `link`; nil when it opens nothing: another scheme
    /// (custom app schemes can trigger actions in other apps), a path that is not there, or any path in a
    /// tab on a server.
    func target(of link: String) -> LinkTarget? {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            switch scheme {
            case "http", "https", "mailto": return .web(url)
            // ls/fd/rg hyperlinks name this Mac: file://my-mac.local/path
            case "file" where opensFiles && LocalHost.contains(url.host): return .file(url, line: nil, column: 1)
            default: return nil
            }
        }
        // A plain path, relative to the tab's folder: "src/main.swift:12:4", a Python traceback's
        // `File "…/graph.py", line 42`, pytest's "tests/x.py:42:", or a graph's "graph.py:graph".
        guard opensFiles else { return nil }
        let base = linkBaseDirectory?()
        guard let reference = FileReference.resolve(
            link: link, row: clickedLine(containing: link),
            absolute: { printed in
                let path = (printed as NSString).expandingTildeInPath
                guard !path.hasPrefix("/"), let base else { return path }
                return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
            },
            exists: { FileManager.default.fileExists(atPath: $0) })
        else { return nil }
        let url = URL(fileURLWithPath: reference.path)
        var line = reference.line
        if let symbol = reference.symbol {
            // Where the name is defined, read from a file of a sensible size; else the top.
            if let size = (try? FileManager.default.attributesOfItem(atPath: reference.path)[.size] as? Int) ?? nil, size < 5_000_000,
               let text = try? String(contentsOf: url, encoding: .utf8) {
                line = FileReference.definitionLine(of: symbol, in: text)
            }
        }
        return .file(url, line: line, column: reference.column ?? 1)
    }

    /// Opens a link's target: a web page in the browser, a file in the editor (or safely in its app).
    func open(_ target: LinkTarget) {
        switch target {
        case .web(let url):
            WebLinks.open(url, from: window)
        case let .file(url, line, column):
            if let openFile { openFile(url, line, column) } else { SafeOpen.open(url, from: window) }
        }
    }

    /// Where the mouse button went up last, in the view: which row a ⌘-click was on.
    var lastClickPoint: NSPoint?

    override func mouseUp(with event: NSEvent) {
        lastClickPoint = convert(event.locationInWindow, from: nil)
        super.mouseUp(with: event)
    }

    /// SwiftTerm 1.20 snaps its cell width to the pixel grid only when the font (or the line spacing) is set, at the
    /// scale of the window then, or of the main screen before there is one: on a screen of another scale it drew and
    /// hit-tested cells snapped for the old one, and a table's box lines drifted from its text a little more each column.
    /// Setting the font again snaps them for this screen. AppKit calls this also when the view first goes into a window
    /// of another scale (a tab's font is set before it has one); SelfTestCellSnap checks both.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let snapped = max(1, (advance * scale).rounded() / scale)
        // Only when it differs: setting the font clears the selection.
        if abs(snapped - cellSize.width) > 0.001 { font = font }
    }

    // MARK: right and middle buttons, for a program that reads the mouse (TerminalMouse.swift)

    /// False for a tab Next Term's own tmux keeps: its `mouse on` is there for the wheel, and tmux's menu (splits,
    /// kills) has no place in a tab, so a right-click there stays Next Term's menu.
    var passesOtherButtons: () -> Bool = { true }
    /// The buttons (xterm's numbers) whose press went to the program: only their drags and release follow it.
    var pressedForProgram: Set<Int> = []
    /// The button a release is being sent for: send(source: Terminal) puts it back into the SGR release.
    var releasing: Int?

    // super: Next Term's menu (through menu(for:)) for a right-click, nothing for a middle one.
    override func rightMouseDown(with event: NSEvent) {
        if !reportOther(event, .press) { super.rightMouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !reportOther(event, .drag) { super.rightMouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !reportOther(event, .release) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !reportOther(event, .press) { super.otherMouseDown(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !reportOther(event, .drag) { super.otherMouseDragged(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !reportOther(event, .release) { super.otherMouseUp(with: event) }
    }

    // MARK: right-click

    /// The window's right-click menu for this terminal, with the link or path under the pointer if there is
    /// one (SwiftTerm has no menu of its own).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller = window?.windowController as? TerminalWindowController,
              let tab = controller.tabs.first(where: { $0.view === self }) else { return super.menu(for: event) }
        var link: String?
        if event.type == .rightMouseDown || event.type == .leftMouseDown { // a right-click, or a Control-click
            let point = convert(event.locationInWindow, from: nil)
            lastClickPoint = point // the row a traceback's line number is read from
            link = self.link(at: point)
        }
        return controller.terminalMenu(for: tab, link: link)
    }

    /// The link or path at `point` (in the view), as ⌘-click finds it: an OSC 8 hyperlink, or a URL or
    /// path in the text.
    func link(at point: NSPoint) -> String? {
        let terminal = getTerminal()
        guard terminal.rows > 0, terminal.cols > 0 else { return nil }
        let cell = cellSize
        let row = Int((frame.height - point.y) / cell.height)
        let col = Int(point.x / cell.width)
        guard row >= 0, row < terminal.rows, col >= 0, col < terminal.cols else { return nil }
        return terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit)
    }

    /// The text of the line a link was clicked in, its wrapped rows joined: where a traceback says
    /// `line 42`. SwiftTerm gives only the link, so this finds the logical lines on screen that contain
    /// it and takes the one nearest the click (its row, estimated from the view's height).
    func clickedLine(containing link: String) -> String? {
        let terminal = getTerminal()
        let rows = terminal.rows
        guard rows > 0 else { return nil }
        let estimate = lastClickPoint.map { point -> Int in
            Int((frame.height - point.y) / (frame.height / CGFloat(rows)))
        }
        var best: (distance: Int, text: String)?
        var row = 0
        while row < rows {
            guard let first = terminal.getLine(row: row) else { row += 1; continue }
            var end = row
            var text = first.translateToString(trimRight: false)
            while let next = terminal.getLine(row: end + 1), next.isWrapped {
                text += next.translateToString(trimRight: false)
                end += 1
            }
            if text.contains(link) {
                let distance = estimate.map { $0 < row ? row - $0 : $0 > end ? $0 - end : 0 } ?? row
                if best == nil || distance < best!.distance { best = (distance, text) }
            }
            row = end + 1
        }
        return best.map { $0.text.trimmingCharacters(in: .whitespaces) }
    }
}

protocol TerminalTabDelegate: AnyObject {
    func tabDidChange(_ tab: TerminalTab)
    func tabDidExit(_ tab: TerminalTab)
}

/// One tab: a shell in a pty, its terminal view and its status. A remote tab runs ssh in the pty instead,
/// to a shell, a tmux session or herdr on a server (see RemoteConnection).
final class TerminalTab: NSObject, LocalProcessTerminalViewDelegate {
    /// What MCP clients know the tab by: a restored tab keeps the one it had (SessionRestore).
    let id: UUID
    /// Set for a tab on a server.
    let remote: RemoteTab?
    /// The tab whose agent started this one over MCP (new_tab): list_tabs says opened_by, the tooltip "Started by".
    var openedBy: UUID?
    /// The connection to the host dropped; the tab waits to reconnect.
    private(set) var disconnected = false
    /// The tab's script runs on the host: ssh got past its login (password, host key). Until then
    /// nothing may be typed into the tab but by the user, who sees what ssh asks.
    private(set) var remoteConnected = false
    /// The host reported this tab's shell at its prompt at least once: commands can be typed into it.
    private(set) var remoteReady = false
    /// tmux or herdr was missing on the host, so this tab is a plain shell that nothing keeps.
    private(set) var fellBack = false
    /// Why, when a copy was on the host but did not run ("herdr at … did not run (…)"); nil when none was found.
    private(set) var fellBackReason: String?
    /// The last status report said this tab's tmux pane is in one of tmux's modes (copy mode): keys go to tmux.
    private(set) var paneInMode = false
    /// The folder asked for was not on the host (the tab opened in the home folder).
    private(set) var remoteFolderMissing = false
    /// Something on the host keeps this tab's session when the connection drops.
    var isKept: Bool { (remote?.keep ?? .off) != .off && !fellBack }
    private var waitingForConnection = false
    /// New for each connection: the tab's script writes it on the host, and only a poll that reports it
    /// back proves that this tab's own login got through (not another tab's, nor an old connection's).
    private var connectionToken = ""
    /// This tab's ssh got through at least once since it opened.
    private(set) var everConnected = false
    /// The last connection ended at the login (a refused password or key, a host key that did not verify).
    private var loginRefused = false
    /// ssh is asking for something in this tab right now (a password, a passphrase, a host key).
    private(set) var loginPrompt = false
    /// Which of the host's master connections this tab uses (see RemoteConnection.tabsPerMaster).
    private(set) var controlSlot: Int?
    var controlPath: String? { remote.flatMap { remote in controlSlot.map { RemoteConnection.controlPath(remote.host, slot: $0) } } }
    /// Lost its connection when the master went too: reconnect as soon as a master is up again (once).
    private(set) var wakesWithMaster = false
    /// What herdr's lists said (a herdr tab): its agents, and a note when it doesn't answer.
    private(set) var herdrWatch = HerdrWatch()
    /// herdr's agents, last reported (a herdr tab); none while herdr doesn't answer.
    var herdrAgents: [HerdrAgent] { herdrWatch.agents ?? [] }
    private var connectedAt: TimeInterval = 0
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    /// This tab's name in the files Next Term keeps on the host.
    var remoteKey: String { RemoteShell.safeName(id.uuidString.lowercased()) }
    /// Shared secret with this tab's shell; see ShellIntegration.
    private let nonce = ShellIntegration.makeNonce()
    let view: NextTermView
    let shellPath: String
    var status = TabStatus()
    /// Set by the user (double-click a tab). Wins over everything else.
    var userTitle: String?
    /// Set by the running program via OSC 0/2. Cleared at each command boundary.
    private var programTitle: String?
    private(set) var directory: String {
        didSet { if !leftStartFolder, remote == nil, canonicalPath(directory) != canonicalPath(oldValue) { leftStartFolder = true } }
    }
    /// The shell has been in another folder than the one it started in. Without the zsh integration (bash,
    /// fish) a `cd` is not a command anyone sees, so this is what says the tab was used.
    private(set) var leftStartFolder = false
    private(set) var exited = false
    /// The shell ended by itself (`exit`, Ctrl-D), so the tab goes. A shell that failed or was killed has
    /// `exited` too, but its tab stays to show why.
    private(set) var endedByItself = false
    weak var delegate: TerminalTabDelegate?
    /// Fires when the shell process execs something else (`exec zsh`, `omz reload`).
    private var execWatcher: DispatchSourceProcess?
    /// Tab completion in this tab.
    private(set) lazy var completion = CompletionSession(tab: self)
    /// Whether this tab's zsh can take history's key now, so a line Next Term submits by itself stays out of its history
    /// (ShellHistory, submitOwnLine).
    private(set) var history = ShellHistory.Readiness()
    private var shellName: String { (shellPath as NSString).lastPathComponent }

    init(directory: String?, fontSize: CGFloat, remote: RemoteTab? = nil, id: UUID = UUID()) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.id = id
        self.remote = remote
        self.directory = remote?.directory ?? (Self.isDirectory(directory) ? directory! : home)
        self.shellPath = remote == nil ? Self.loginShell() : RemoteConnection.sshPath
        self.view = NextTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()

        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        // Off by default: on most non-US layouts Option types # @ | [ ] { } ~ \. Toggle in the File menu.
        view.optionAsMetaKey = Preferences.optionAsMeta

        view.onOutput = { [weak self] in
            self?.status.output(at: Self.now)
            self?.completion.output()
        }
        view.onInput = { [weak self] in self?.status.input(at: Self.now) }
        view.onKeyboard = { [weak self] in self?.userInput() }
        view.onBell = { [weak self] in self?.attention() }
        view.completionGate = { [weak self] data in self?.completion.gate(data) ?? false }
        view.onWrite = { [weak self] data in self?.history.input(data) }
        view.linkBaseDirectory = { [weak self] in self?.liveDirectory ?? NSHomeDirectory() }
        view.opensFiles = remote == nil
        // Next Term's own tmux turns the mouse on for the wheel: right and middle clicks there stay Next Term's.
        view.passesOtherButtons = { [weak self] in !(self?.remote?.keep == .tmux && self?.isKept == true) }

        let terminal = view.getTerminal()
        terminal.registerOscHandler(code: ShellIntegration.oscCode) { [weak self] payload in
            guard let self, let event = ShellIntegration.parse(payload, nonce: self.nonce) ?? self.serverCompletionMark(payload) else { return }
            self.handle(event)
        }
        // OSC 52 clipboard. Reading is refused: any program, or a remote host over ssh, could harvest the
        // clipboard silently. Writing (vim, tmux, agents copying text) is allowed from the tab you are
        // looking at, so a background tab cannot swap what you are about to paste.
        terminal.registerOscHandler(code: 52) { [weak self] payload in
            guard let self, let sep = payload.firstIndex(of: UInt8(ascii: ";")) else { return }
            let data = payload[payload.index(after: sep)...]
            guard !data.elementsEqual([UInt8(ascii: "?")]), self.status.visible, data.count <= 1_400_000,
                  let decoded = Data(base64Encoded: Data(data), options: .ignoreUnknownCharacters),
                  let text = String(data: decoded, encoding: .utf8) else { return }
            // No escape sequences onto the clipboard: copied text is for pasting, not for steering.
            let clean = String(text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || !ShellQuote.isControl($0) })
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clean, forType: .string)
        }
        // OSC 9 (iTerm2 / ConEmu) and OSC 777 (rxvt) desktop notifications mean "look at me".
        // OSC 9;4 is a progress report, not a notification.
        terminal.registerOscHandler(code: 9) { [weak self] payload in
            if payload.starts(with: Array("4;".utf8)) { return }
            self?.attention()
        }
        terminal.registerOscHandler(code: 777) { [weak self] payload in
            if payload.starts(with: Array("notify;".utf8)) { self?.attention() }
        }
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        showRestoredScrollback()
        started = true
        if let remote {
            if controlSlot == nil { controlSlot = RemoteConnection.slot(for: self, host: remote.host) }
            let path = RemoteConnection.controlPath(remote.host, slot: controlSlot ?? 0)
            // Another tab is logging in on this master: wait for its connection rather than ask twice.
            guard RemoteConnection.mayConnect(self, to: remote.host, path: path) else {
                disconnected = false
                wakesWithMaster = false
                if !waitingForConnection {
                    waitingForConnection = true
                    let other = RemoteConnection.loginTab(path: path).map { " (the tab “\($0.title)”)" } ?? ""
                    view.feed(text: "\u{1b}[2m[Waiting for another tab's login to \(remote.host.name)\(other)…]\u{1b}[0m\r\n")
                    delegate?.tabDidChange(self)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.exited, !self.view.process.running else { return }
                    self.start()
                }
                return
            }
            waitingForConnection = false
            connectedAt = Self.now
            disconnected = false
            remoteConnected = false
            remoteReady = false
            // The tab script tries tmux or herdr again: whether this connection fell back, or its pane is in copy mode,
            // is for its own reports to say (a .plain file comes back if the tool is still missing).
            fellBack = false
            fellBackReason = nil
            herdrWatch = HerdrWatch()
            paneInMode = false
            loginPrompt = false
            connectionToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
            view.interceptInput = nil
            view.acceptsInput = true
            DescriptorSweep.markCloseOnExec() // ssh inherits nothing of ours (see below)
            view.startProcess(executable: shellPath, args: RemoteConnection.tabArguments(remote, path: path, tabKey: remoteKey, token: connectionToken),
                              environment: RemoteConnection.environment(), execName: nil, currentDirectory: NSHomeDirectory())
            return
        }
        // SwiftTerm's forkpty and execve close nothing: without this the shell would hold every earlier tab's pty
        // master (and the MCP socket), and after a crash or Force Quit the kernel could hang none of those tabs up.
        DescriptorSweep.markCloseOnExec()
        view.startProcess(
            executable: shellPath,
            args: [],
            environment: environment(shellName: shellName),
            execName: "-" + shellName, // leading dash: a login shell, like Terminal.app
            currentDirectory: directory
        )
        // The kernel tells us when the shell process becomes something else. Text cannot: `omz reload`
        // and `alias reload='exec zsh'` hide the exec, and the new shell has no integration.
        let pid = view.process.shellPid
        guard pid > 0 else { return }
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exec, queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, !self.exited else { return }
            self.programTitle = nil
            self.status.shellReplaced()
            self.completion.shellReplaced()
            self.history.disarm()
            self.delegate?.tabDidChange(self)
        }
        watcher.resume()
        execWatcher = watcher
    }

    /// Ends the shell and what runs in front of it: the program and what it started outside its group or the
    /// terminal (an agent's dev server), as TabProcessTree decides from `snapshot` (taken here if nil). Those
    /// that outlive the hangup get SIGTERM after a second: here off the main thread, or, with `finishLater`
    /// false, by the caller, who gets them back (Quit waits once for all its tabs).
    @discardableResult
    func terminate(snapshot: [ProcessRecord]? = nil, finishLater: Bool = true) -> [ProcessRecord] {
        execWatcher?.cancel()
        execWatcher = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        MCPControl.forget(self)
        guard !exited else { return [] }
        // A disconnected remote tab's ssh has exited and was reaped: its pid may be another process's now,
        // so neither SwiftTerm (SIGTERM) nor we (SIGHUP) signal it, as for a shell that already exited.
        let gone = disconnected || waitingForConnection
        let pid = gone ? 0 : view.process.shellPid
        // Before any signal: closing the pty hangs the shell up, and then its terminal is gone.
        let plan = gone ? HangupPlan.none : hangupPlan(snapshot)
        exited = true
        RemoteConnection.doneConnecting(self)
        if !gone { view.terminate() }
        // Interactive shells ignore SIGTERM; SIGHUP makes them exit and hang up their jobs.
        if pid > 0 {
            kill(pid, SIGHUP)
            Self.reap(pid)
        }
        TabHangup.send(plan)
        guard finishLater else { return plan.stoppable }
        TabHangup.finishLater(plan.stoppable)
        return []
    }

    /// Closes these tabs (a window's, or every tab at Quit) from one snapshot of the processes, taken before any
    /// signal and only if a program runs in front of one of them. Returns what is left to wait for.
    static func terminate(_ tabs: [TerminalTab], finishLater: Bool) -> [ProcessRecord] {
        let snapshot = tabs.contains(where: \.hasProgramInFront) ? ProcessSnapshot.take() : nil
        return tabs.flatMap { $0.terminate(snapshot: snapshot, finishLater: finishLater) }
    }

    /// The pty's foreground process group (tcgetpgrp), 0 if unknown.
    private var foregroundGroup: pid_t {
        let fd = view.process.childfd
        guard fd >= 0 else { return 0 }
        return max(0, tcgetpgrp(fd))
    }

    /// A program, not the shell, is in front of this tab on this Mac.
    private var hasProgramInFront: Bool {
        guard remote == nil, !exited else { return false }
        let group = foregroundGroup
        return group > 0 && group != view.process.shellPid
    }

    /// What closing this tab hangs up besides the shell (none for a tab on a server, or at the prompt).
    func hangupPlan(_ snapshot: [ProcessRecord]? = nil) -> HangupPlan {
        guard hasProgramInFront, let snapshot = snapshot ?? ProcessSnapshot.take() else { return .none }
        let group = foregroundGroup
        // An interactive shell in front (`bash`, `nix develop`) is at its own prompt: its jobs are its business.
        let shells = snapshot.filter { record in
            guard record.group == group, ProcessInspector.shells.contains(record.name) else { return false }
            let arguments = ProcessInspector.commandLine(of: record.pid)?.arguments ?? []
            return TabProcessTree.isInteractiveShell(name: record.name, arguments: arguments)
        }
        return TabProcessTree.plan(snapshot: snapshot, shell: view.process.shellPid, foregroundGroup: group,
                                   remote: remote != nil, interactiveShells: Set(shells.map(\.pid)))
    }

    /// A process as the close alerts name it: from its command line ("next-server", "claude"), not the kernel's
    /// short name ("node").
    static func displayName(_ record: ProcessRecord) -> String {
        TabProcessTree.displayName(command: record.name, arguments: ProcessInspector.commandLine(of: record.pid)?.arguments ?? [])
    }

    /// SwiftTerm stops watching the shell once we terminate it, so collect its exit status here;
    /// otherwise every closed tab leaves a zombie until the app quits.
    private static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 { // up to 2 s to hang up its jobs and exit
                if waitpid(pid, &status, WNOHANG) != 0 { return } // reaped, or not ours any more
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Live working directory of the shell, for opening a new tab in the same place.
    func currentDirectory() -> String {
        if remote != nil { return directory } // a folder on the host, as the host reports it
        return ProcessInspector.currentDirectory(of: view.process.shellPid) ?? directory
    }

    /// The folder relative paths mean right now: the integration reports it; otherwise ask the kernel.
    var liveDirectory: String { status.integrated || remote != nil ? directory : currentDirectory() }

    /// Types a command at the prompt and runs it, once the shell is at its first prompt (its integration
    /// reports in) or after 3 seconds.
    func runWhenReady(_ command: String, waited: TimeInterval = 0) {
        guard !exited else { return }
        if !status.integrated && waited < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.runWhenReady(command, waited: waited + 0.1) }
            return
        }
        let typed = view.typeText(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.exited else { return }
            self.submitOwnLine(typed)
        }
    }

    /// Return for a line Next Term or an agent typed into this tab by itself (`typed`, as typeText or typeIn returned
    /// it), never for the user's: every such Return comes here (MCP's send_to_tab, new_tab and press_keys, runWhenReady,
    /// a restore's resume). Where the tab's zsh can take history's key now, the key names the line first, in the same
    /// write, so zsh keeps the line out of its history, ↑ and autosuggestions (ShellHistory). Anywhere else (bash, fish,
    /// a server, a program in front, a zsh without the hook) a plain Return, as before; and zsh keeps out only that line
    /// to the byte, so one the user typed on too goes in as theirs.
    func submitOwnLine(_ typed: String) {
        let bytes = ShellHistory.submit(typed: typed, armed: history.armed)
        view.send(data: bytes[...])
    }

    /// Twice a second. For shells without integration this is how the tab knows what runs and where it
    /// is; with integration it only looks behind commands that look plain, for agents run by functions.
    func pollForeground() {
        guard !exited else { return }
        guard remote == nil else { return watchLogin() } // a remote tab's foreground comes from its host (applyRemote)
        if status.integrated && !(status.running && status.kind == .command) { return }
        let before = (status.running, status.command)
        let foreground = ProcessInspector.foreground(ptyFileDescriptor: view.process.childfd,
                                                     shellPid: view.process.shellPid, shellName: shellName)
        status.observe(foreground, at: Self.now)
        var changed = (status.running, status.command) != before
        if !status.integrated {
            // A prompt title ("user@host: ~/dir") is stale once a command runs, and vice versa.
            if changed { programTitle = nil }
            // Follow `cd` without integration: the shell's own working directory, read at the prompt.
            if foreground?.isShell == true, let dir = ProcessInspector.currentDirectory(of: view.process.shellPid), dir != directory {
                directory = dir
                changed = true
            }
        }
        if changed { delegate?.tabDidChange(self) }
    }

    /// The live end of the terminal, whatever the user has scrolled back to: the last `count` lines of
    /// the active buffer that end at the last line with text. Agents draw inline where the cursor is,
    /// so after a screen clear their UI sits at the top with blank rows below it.
    func screenTail(_ count: Int = AgentScreen.scannedLines) -> [String] {
        tailRows(count).rows
    }

    /// `screenTail`, with stored keys masked over whole lines (`SecretMask.mask(window:rows:text:)`): the rows above the
    /// window are masked with it, wrapped by the terminal or not (agent UIs wrap with a newline or cursor moves), so the
    /// tail of a key whose start is above the window never shows.
    func screenTail(_ count: Int, masked mask: SecretMask) -> [String] {
        let terminal = view.getTerminal()
        guard let last = lastTextRow() else { return [] }
        let top = terminal.buffer.totalLinesTrimmed
        let first = max(top, last - count + 1)
        return mask.mask(window: first...last, rows: top...last) { row in
            terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true) ?? ""
        }
    }

    /// `screenTail`, with the scroll-invariant row of its first line.
    private func tailRows(_ count: Int) -> (first: Int, rows: [String]) {
        let terminal = view.getTerminal()
        guard let last = lastTextRow() else { return (0, []) }
        let first = max(terminal.buffer.totalLinesTrimmed, last - count + 1)
        return (first, (first...last).map { terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) ?? "" })
    }

    /// The last line with text, in scroll-invariant rows (as getScrollInvariantLine counts them).
    func lastTextRow() -> Int? {
        let terminal = view.getTerminal()
        let top = terminal.buffer.totalLinesTrimmed
        // The last line that exists, found by bisection (SwiftTerm keeps the line count internal).
        var low = top, high = top + 1_000_000
        guard terminal.getScrollInvariantLine(row: low) != nil else { return nil }
        while low < high {
            let mid = (low + high + 1) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid - 1 }
        }
        // Skip blank rows at the bottom (at most one screen of them).
        var last = low
        while last > top, low - last < terminal.rows,
              terminal.getScrollInvariantLine(row: last)?.translateToString(trimRight: true).isEmpty ?? true {
            last -= 1
        }
        return last
    }

    // MARK: scrollback on the update and quit paths (SessionScrollback)

    /// Where each command whose line held a secret showed (`ScrollbackText.holdsSecret`), the latest: the scrollback a
    /// quit saves has those lines blanked.
    private(set) var droppedEchoes: [ScrollbackText.Echo] = []
    /// Where the running command showed: an agent's pane saves only what came before it.
    private(set) var runningEcho: ScrollbackText.Echo?
    /// The scrollback saved at the quit restored, read back at the launch after, and the quit it was saved at. The first
    /// `start()` shows it once, before the shell starts, above a dim divider; set once the tab has started, it is never
    /// shown.
    var restoredScrollback: (text: String, savedAt: ScrollbackText.SavedAt)?
    /// The divider under it, once shown, with its last row and the width it was shown at: what is read as live (agent
    /// questions, ssh refusing a login) is read only below it (`liveTail`).
    private(set) var restoreDivider: (text: String, row: Int?, columns: Int)?
    /// `start()` has run: anything fed now would land among what the shell printed.
    private var started = false
    /// The record this tab was restored from, at launch. While its action waits, every save writes it as it was
    /// (SessionCapture), so a restore that stops part-way loses nothing (KTD3).
    var restoredRecord: SessionSnapshot.Pane?
    /// The restore's note for this tab (RestoreNote), shown once, under the restored scrollback, before the shell starts.
    var restoreNote: String?
    /// The user put something in this tab (`userInput`): an action the restore has not applied yet is theirs to drop (KTD6).
    private(set) var touchedByUser = false
    /// The integration's command marks, a command starting or ending, each as it is read and before the status takes it:
    /// the screen then holds what came before the mark and nothing after it. The restore's start watch reads them
    /// (StartWatcher, KTD6). Nothing may be fed into the terminal from here, as its parser is still reading.
    var onCommandMark: ((ShellIntegration.Event) -> Void)?

    /// The user put something in this tab: a key, a paste or a drop (`NextTermView.onKeyboard`), or text Next Term types
    /// at their word, such as Insert Path or a suggested command. A restored action not applied yet is dropped, and one
    /// typed that waits for its Return does not run; an agent over MCP no longer drives the tab.
    func userInput() {
        touchedByUser = true
        view.awaitsChoice = false // a paste or a drop into it is the user's choice
        MCPControl.typedByUser(self)
    }

    /// Nothing has happened in this tab that a caller could lose by reusing it (`nxtrm`, ⌥⌘O, MCP `new_tab`): nothing ran
    /// in it, and it holds nothing restored, such as a put-back line (KTD10).
    var isUntouched: Bool { restoredRecord == nil && status.command.isEmpty && !status.running }

    /// The restore brought this tab back, and the user has not put anything in it since: its put-back line, note and
    /// scrollback may be unseen, so Open Project does not replace it (TerminalWindowController.holdsRestore).
    var holdsRestore: Bool { restoredRecord != nil && !touchedByUser }

    /// Notes where the command now starting showed, as the integration reports it.
    private func noteEcho(_ typed: String, expanded: String?) {
        runningEcho = SessionScrollback.echo(in: self, typed: typed)
        guard let echo = runningEcho, ScrollbackText.holdsSecret(typed: typed, expanded: expanded) else { return }
        droppedEchoes.append(echo)
        if droppedEchoes.count > SessionScrollback.droppedKept {
            droppedEchoes.removeFirst(droppedEchoes.count - SessionScrollback.droppedKept)
        }
    }

    /// Feeds the restored scrollback and its divider, once, before the shell has printed anything: nothing it prints can
    /// be inside them, and they are sanitized again, as their file was read as untrusted. Notes the divider's last row.
    /// The restore's note follows, below the divider, just before the prompt.
    func showRestoredScrollback() {
        let restored = restoredScrollback
        let note = restoreNote
        restoredScrollback = nil
        restoreNote = nil
        guard !started else { return }
        if let restored {
            view.feed(text: ScrollbackText.preface(restored.text, savedAt: restored.savedAt))
            restoreDivider = (restored.savedAt.divider, lastTextRow(), view.getTerminal().cols)
        }
        if let note { view.feed(text: RestoreLayout.noteLine(note)) }
    }

    /// The screen's last `count` lines that are live: below a restore's divider, so a question or a refusal replayed above
    /// it is not read as one now. The divider is known by its row until the width changes (`sizeChanged`), which wraps
    /// the rows above it again; then by its text.
    func liveTail(_ count: Int = AgentScreen.scannedLines) -> [String] {
        let tail = tailRows(count)
        guard let divider = restoreDivider else { return tail.rows }
        return ScrollbackText.below(divider: divider.text, row: divider.row, in: tail.rows, first: tail.first)
    }

    // MARK: a branch another worktree holds

    /// The row a git command's output starts on, while one runs in this (local) tab: if it fails because another
    /// worktree has the branch, the window offers to free it (TerminalWindowController.noticeHeldBranch). Only the
    /// command's own output is read, once, when it ends; nothing is typed in the shell.
    private var gitOutputStart: Int?

    private func gitCommandEnded(_ code: Int32) {
        guard let start = gitOutputStart else { return }
        gitOutputStart = nil
        guard code != 0, remote == nil, let last = lastTextRow(), last >= start else { return }
        let terminal = view.getTerminal()
        // A line the terminal wrapped is one line again: git's message names a long path.
        var lines: [String] = []
        for row in max(start, last - 60)...last {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
            if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text } else { lines.append(text) }
        }
        guard let held = GitOutput.heldBranch(lines.joined(separator: "\n")) else { return }
        AppDelegate.shared.controllers.first { $0.tabs.contains { $0 === self } }?.noticeHeldBranch(held.branch, at: held.path, from: directory)
    }

    // MARK: serving

    /// The local address a running server printed (`npm run dev`, `langgraph dev`, `uvicorn`): shown as
    /// " · :5173" after the title, opened by File › Open Served URL, given to agents in list_tabs.
    private(set) var servedURL: URL?
    /// The first row of the running command's output; set when the shell integration reports the start.
    private var pendingServingStart: Int?
    private var servingStart: Int?
    private var servingScanned: Int?
    private var servingCommand = -1
    /// The tab's output count (NextTermView.outputBytes) at the last scan: no new output, nothing new to scan.
    private var servingOutput = -1

    /// Twice a second: look at what the running command printed since it started for a loopback URL.
    /// Not for agents, editors or ssh (an address there is the agent's business, or the other host's).
    func pollServing() {
        guard remote == nil, !exited, status.running, status.kind == .command else {
            servingCommand = -1
            if servedURL != nil {
                servedURL = nil
                delegate?.tabDidChange(self)
            }
            return
        }
        if status.commandsStarted != servingCommand {
            servingCommand = status.commandsStarted
            servedURL = nil
            servingScanned = nil
            // Without the integration the start is seen late: look back a little (the command line
            // itself is skipped below).
            servingStart = pendingServingStart ?? max(0, (lastTextRow() ?? 0) - 50)
            pendingServingStart = nil
            servingOutput = -1
        }
        // A tab with nothing new printed since the last look has nothing new to scan (the last line, which may
        // have been mid-write then, is as it was).
        guard servedURL == nil, view.outputBytes != servingOutput else { return }
        servingOutput = view.outputBytes
        guard let start = servingStart, let last = lastTextRow() else { return }
        let first = max(start, (servingScanned ?? start - 1) + 1, last - 400)
        guard first <= last else { return }
        let terminal = view.getTerminal()
        let command = status.command.trimmingCharacters(in: .whitespaces)
        for row in first...last {
            guard let text = terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true), !text.isEmpty else { continue }
            if command.count >= 6 && text.contains(command) { continue } // a URL typed in the command line is not served
            if let url = ServedURL.find(in: text) {
                servedURL = url
                delegate?.tabDidChange(self)
                return
            }
        }
        servingScanned = last - 1 // the last line may still be being written
    }

    /// For a running AI agent: read its screen (working, asking a question, or idle) so the tab's
    /// status follows the agent itself.
    func pollAgentScreen() {
        guard !exited, status.running, status.kind == .agent, remote?.keep != .herdr || fellBack else { return } // herdr reports its own
        let before = (status.state, status.question)
        status.observe(agentScreen: agentActivity(liveTail()), at: Self.now)
        if before.0 != status.state || before.1 != status.question { delegate?.tabDidChange(self) }
    }

    /// The last screen read and what it says, with the masks it was read with: an agent that drew nothing new since
    /// (most of them, most of the time) is not parsed again 4 times a second. AgentScreen.activity is a function of the
    /// lines and the masks alone, and TabStatus takes the same activity again as it did.
    private var lastAgentRead: (lines: [String], mask: ObjectIdentifier, activity: AgentActivity)?

    private func agentActivity(_ lines: [String]) -> AgentActivity {
        let mask = ObjectIdentifier(SecretMask.current)
        if let last = lastAgentRead, last.mask == mask, last.lines == lines { return last.activity }
        let activity = AgentScreen.activity(screenLines: lines)
        lastAgentRead = (lines, mask, activity)
        return activity
    }

    /// What the program in front started outside the terminal that its hangup stops, as the close alerts name it
    /// ("“next-server” (started by “claude”)"), or nil: the update sheet's word for it. `snapshot`: one for every tab.
    func startedStops(_ snapshot: [ProcessRecord]?) -> String? {
        guard remote == nil, !exited, status.running else { return nil }
        let stops = TabProcessTree.startedNote(hangupPlan(snapshot).named(Self.displayName)).stops
        return stops.isEmpty ? nil : stops.joined(separator: ", ")
    }

    /// What closing this tab would stop, and what it would leave running, or nil: nothing to say. The program in
    /// front and what it started outside the terminal (an agent's dev server), from the same TabProcessTree plan
    /// the hangup follows; jobs left in the background or suspended with Ctrl-Z (a stopped vim with unsaved changes).
    var closeNote: CloseNote? {
        guard !exited else { return nil }
        if let remote {
            // tmux and herdr keep the session on the host: closing the tab only detaches (keptNote says so).
            guard !disconnected, remoteConnected, !isKept else { return nil }
            var items: [String] = []
            if status.running { items.append("“\(status.program.isEmpty ? "a running process" : status.program)”") }
            items += status.jobSummary.split(separator: "\n").map { line -> String in
                if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) { return "“\(line[..<open.lowerBound])”" + line[open.lowerBound...] }
                return "“\(line)”"
            }
            return items.isEmpty ? nil : CloseNote(stops: [items.joined(separator: ", ") + " on \(remote.host.name)"])
        }
        var note = CloseNote()
        if status.running {
            let program = status.program.isEmpty ? nil : "“\(runningName)”"
            note = TabProcessTree.closeNote(hangupPlan().named(Self.displayName), running: true, program: program)
        }
        if status.integrated {
            if status.jobs > 0 {
                // "vim notes.md (suspended)" -> “vim notes.md” (suspended): the state is not part of the command.
                let jobs = status.jobSummary.split(separator: "\n").map { line -> String in
                    if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
                        return "“\(line[..<open.lowerBound])”" + line[open.lowerBound...]
                    }
                    return "“\(line)”"
                }
                note.stops += jobs
                if note.isEmpty { note.stops.append("\(status.jobs) background job\(status.jobs == 1 ? "" : "s")") }
            }
        } else if !status.running {
            note.stops += ProcessInspector.childProcessNames(of: view.process.shellPid).map { "“\($0)”" }
        }
        return note.isEmpty ? nil : note
    }

    /// What closing this tab stops, as a phrase ("“claude” (running), “next-server” (started by “claude”)"), or
    /// nil if it stops nothing.
    var closeWarning: String? {
        guard let stops = closeNote?.stops, !stops.isEmpty else { return nil }
        return stops.joined(separator: ", ")
    }

    /// What runs in front, as the close alerts name it: the program with its arguments as they were typed ("npm run
    /// dev", as a suspended job is named), shortened; its name alone when nothing was typed (one the polling found).
    private var runningName: String {
        let typed = status.integrated ? CommandClassifier.programLine(status.command) : ""
        return typed.isEmpty ? status.program : Typography.shortened(typed, to: 60)
    }

    /// What closing a kept tmux tab leaves running on its host, said in the close alert (nil: nothing).
    var keptNote: String? {
        guard let remote, isKept, remote.keep == .tmux, remoteConnected, !disconnected, status.running else { return nil }
        let program = status.program.isEmpty ? "What runs in it" : "“\(status.program)”"
        return "\(program) keeps running on \(remote.host.name), in tmux session \(remote.session). Reopen it from File › New Remote Tab… (Sessions on this host)."
    }

    /// Where a remote tab's connection stands (nil: a tab on this Mac).
    var remoteLink: RemoteLink? {
        guard remote != nil else { return nil }
        return RemoteLink(exited: exited, disconnected: disconnected, waiting: waitingForConnection, loginPrompt: loginPrompt,
                          connected: remoteConnected)
    }

    /// The server mark its tab shows (nil: a tab on this Mac).
    var remoteMark: RemoteMark? {
        guard let remote, let remoteLink else { return nil }
        return RemoteMark(host: remote.host.name, destination: remote.host.destination, link: remoteLink)
    }

    /// Where a remote tab's connection stands, when it is not simply up: for the title and list_tabs.
    var connectionNote: String? { remoteLink?.titleNote }

    /// A folder or program name keeps both ends, like Finder; a title a program sets is prose and gives
    /// way at the end.
    var titleTruncation: NSLineBreakMode {
        if let userTitle, !userTitle.isEmpty { return .byTruncatingMiddle }
        if status.running, let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return .byTruncatingTail }
        return .byTruncatingMiddle
    }

    /// The tab's name, and " · :5173" while it serves (state, so also after a name the user gave it).
    var title: String {
        baseTitle + servedSuffix
    }

    /// Shorter forms of the title, for a tab too narrow for "web-1: app (connecting)": without the host
    /// ("app (connecting)": the server mark says it is on one), then without the note ("app": the mark's
    /// dot says it). Only a remote tab named after its folder has them.
    var shorterTitles: [String] {
        guard let remoteName else { return [] }
        let folder = remoteName.folder
        let shorter = remoteName.note.map { [folder + " (\($0))", folder] } ?? [folder]
        return shorter.map { $0 + servedSuffix }
    }

    /// What the rename field starts with: the name alone. Not a remote tab's connection note, which would
    /// stay in the name ("(connecting)" long after it connected), nor the served port, which the title adds
    /// to any name.
    var editableTitle: String {
        guard let remoteName else { return baseTitle }
        return remoteName.host + ": " + remoteName.folder
    }

    private var servedSuffix: String { servedURL.map(ServedURL.suffix) ?? "" }

    private var baseTitle: String {
        if let userTitle, !userTitle.isEmpty { return userTitle }
        // While a program runs, its own title (Claude Code names the task) or its name.
        // At the prompt, the folder: shell themes set titles like "user@host: ~/dir" there, which say less.
        if let programName { return programName }
        if let remoteName {
            let name = remoteName.host + ": " + remoteName.folder
            return remoteName.note.map { name + " (\($0))" } ?? name
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        let last = (directory as NSString).lastPathComponent
        return last.isEmpty ? directory : last
    }

    private var programName: String? {
        guard status.running else { return nil }
        if let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return String(programTitle.prefix(200)) }
        return status.program.isEmpty ? nil : status.program
    }

    /// A remote tab at its prompt is named after its host and folder, with the connection's note: "web-1",
    /// "app", "connecting". nil while a name of its own shows (the user's, a program's).
    private var remoteName: (host: String, folder: String, note: String?)? {
        guard let remote, userTitle?.isEmpty != false, programName == nil else { return nil }
        let last = (directory as NSString).lastPathComponent
        return (remote.host.name, directory == "~" || last.isEmpty ? directory : last, connectionNote)
    }

    var stateDescription: String {
        if disconnected { return "Disconnected" }
        if loginPrompt { return "Waiting for you to log in (ssh is asking in this tab)" }
        if remote != nil && !exited && !remoteConnected { return "Connecting" }
        switch status.state {
        case .idle: return status.running ? "Running \(status.program)" : "Idle"
        case .working: return "Working"
        case .done: return "Done"
        case .failed: return status.exitCode.map { "Failed (exit \($0))" } ?? "Failed"
        case .attention: return status.question.map { "Needs your decision: \($0)" } ?? "Needs attention"
        }
    }

    /// The state in words, unless it is only the connection's ("Connecting", "Disconnected"): a remote tab's
    /// mark says that, and the tooltip and VoiceOver say it once, in its words.
    var ownStateDescription: String? {
        guard let remoteLink, remoteLink != .connected, remoteLink != .ended else { return stateDescription }
        return nil
    }

    /// This pane in a split tab's tooltip and VoiceOver label: "zsh: Idle", or for a pane on a server whose
    /// connection is not up, its connection once: "web-1: app (connecting)" (the note says it), "claude:
    /// disconnected".
    var paneSummary: String {
        if let ownStateDescription { return "\(title): \(ownStateDescription)" }
        if remoteName?.note != nil { return title }
        return remoteLink.map { "\(title): \($0.phrase)" } ?? title
    }

    /// A remote tab says where it runs right under its name.
    var tooltip: String {
        var lines = [title]
        if let remoteMark { lines.append(remoteMark.summary) }
        if let ownStateDescription { lines.append(ownStateDescription) }
        if status.running && !status.command.isEmpty { lines.append(String(status.command.prefix(300))) }
        lines.append(remote == nil ? directory : "Folder on the host: \(directory)")
        if let servedURL { lines.append("Serving \(ServedURL.shared(servedURL))") } // its token, if any, stays out of sight
        if let openedBy, let opener = AppDelegate.shared?.controllers.flatMap(\.tabs).first(where: { $0.id == openedBy }) {
            lines.append("Started by “\(opener.title)”")
        }
        if let remote {
            lines.append(remote.keep.keptLine(fellBack: fellBack))
            if fellBack, let fellBackReason { lines.append(fellBackReason) }
            if let note = herdrWatch.note { lines.append(note) }
        }
        lines.append(completion.engineLabel)
        return lines.joined(separator: "\n")
    }

    // MARK: events

    private func handle(_ event: ShellIntegration.Event) {
        switch event {
        case .completion(let message):
            return completion.handle(message)
        case .history(let version):
            return history.marked(version: version)
        case .commandStarted(let line, let expanded):
            onCommandMark?(event)
            completion.disarm()
            history.disarm()
            programTitle = nil
            // Its output starts below the line the command was typed on.
            pendingServingStart = (lastTextRow() ?? 0) + 1
            gitOutputStart = remote == nil && GitOutput.isGitCommand(expanded ?? line) ? pendingServingStart : nil
            noteEcho(line, expanded: expanded)
            status.commandStarted(line, expanded: expanded, at: Self.now)
            // Gemini or Qwen starting (or installed since launch): their IDE switch on, for the next start too.
            if ["gemini", "gemini-cli", "qwen", "qwen-code"].contains(status.program) { AppDelegate.shared.enableAgentIDEModes() }
        case .commandFinished(let code):
            onCommandMark?(event)
            programTitle = nil
            runningEcho = nil
            status.commandFinished(exitCode: code, at: Self.now)
            gitCommandEnded(code)
        case .directory(let dir):
            if !dir.isEmpty { directory = dir }
        case .jobs(let count, let summary):
            status.jobsChanged(count: count, summary: summary)
        }
        delegate?.tabDidChange(self)
    }

    private func attention() {
        status.bell()
        delegate?.tabDidChange(self)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Rows wrapped again: the restore divider's row no longer says where it is.
        if let divider = restoreDivider, newCols != divider.columns { restoreDivider?.row = nil }
        // Programs redraw after a resize; that is not work.
        status.resized(at: Self.now)
        completion.viewChanged()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        programTitle = title
        delegate?.tabDidChange(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 from the user's own shell config: a file:// URL or a bare path. A remote shell
        // (over ssh) reports its own host's paths: those are not folders on this Mac.
        guard let directory, !directory.isEmpty else { return }
        if remote != nil {
            // A remote tab's folder is on its host: take the path whatever host the URL names.
            if let url = URL(string: directory), url.isFileURL, !url.path.isEmpty { self.directory = url.path }
            else if directory.hasPrefix("/") { self.directory = directory }
            delegate?.tabDidChange(self)
            return
        }
        if let url = URL(string: directory), url.isFileURL {
            guard LocalHost.contains(url.host) else { return }
            self.directory = url.path
        } else if directory.hasPrefix("/") {
            self.directory = directory
        }
        delegate?.tabDidChange(self)
    }

    /// `reported` is the raw status from waitpid, as SwiftTerm passes it on: a 0 it may have read before
    /// the process could be reaped is read again.
    func processTerminated(source: TerminalView, exitCode reported: Int32?) {
        guard !exited else { return }
        let waitStatus = ExitStatus.confirmed(reported, pid: view.process.shellPid)
        if let remote {
            RemoteConnection.doneConnecting(self)
            let raw = waitStatus ?? 0
            if raw & 0x7F == 0, (raw >> 8) & 0xFF == 255 {
                // 255: ssh's own failure, or the remote shell's own `exit 255`. After a dropped connection
                // the master is gone too; looked at a moment later, once it had time to go (and ssh's
                // last words have reached the screen).
                loginPrompt = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.exited, !self.view.process.running else { return }
                    if self.remoteConnected, let path = self.controlPath, RemoteConnection.masterAlive(path: path) {
                        self.shellEnded(waitStatus)
                    } else {
                        self.connectionLost(remote)
                    }
                }
                return
            }
        }
        shellEnded(waitStatus)
    }

    private func shellEnded(_ waitStatus: Int32?) {
        exited = true
        execWatcher?.cancel()
        execWatcher = nil
        guard let waitStatus, waitStatus != 0 else {
            endedByItself = true
            delegate?.tabDidExit(self) // `exit`, Ctrl-D: the tab goes away, like any terminal
            return
        }
        // Anything else stays on screen, so the reason is not lost (a failing `exec tmux` in .zshrc
        // would otherwise close the only window at launch).
        let signal = waitStatus & 0x7F
        let code = (waitStatus >> 8) & 0xFF
        let reason = signal == 0 ? "exited with code \(code)" : "was ended by signal \(signal)"
        view.acceptsInput = false
        status.shellExited(code: signal == 0 ? code : 128 + signal)
        view.feed(text: "\r\n\u{1b}[2m[The shell \(reason). ⌘W closes this tab.]\u{1b}[0m\r\n")
        delegate?.tabDidChange(self)
    }

    // MARK: remote

    /// Whether ssh's last words say the login itself was refused: retrying by itself would only ask again
    /// (or count against the host's ban list). nil: the network, most likely. Rows are joined without
    /// spaces, so a phrase that wrapped at the edge of the tab is still found.
    static func loginRefusal(_ lines: [String]) -> String? {
        let text = lines.joined().replacingOccurrences(of: " ", with: "")
        func has(_ phrase: String) -> Bool { text.contains(phrase.replacingOccurrences(of: " ", with: "")) }
        if has("REMOTE HOST IDENTIFICATION HAS CHANGED") || has("Host key verification failed") {
            return "The host key could not be verified."
        }
        if has("Permission denied") || has("Too many authentication failures") || has("No more authentication methods")
            || has("Authentication failed") {
            return "ssh could not log in. If your key is in an agent your shell sets up, Next Term uses the SSH_AUTH_SOCK your login shell exports; otherwise set IdentityAgent in ~/.ssh/config."
        }
        return nil
    }

    /// A kept tab that dropped for a network reason comes back by itself: up to 30 attempts in a row
    /// that never get through once it had connected (about half an hour), 5 when it never did (the host
    /// may be booting, or the Wi-Fi not up yet). Then Return.
    var mayReconnectByItself: Bool { isKept && !loginRefused && reconnectAttempts < (everConnected ? 30 : 5) }

    /// The connection dropped or could not be made. The tab stays, says why, and Return reconnects.
    private func connectionLost(_ remote: RemoteTab) {
        // Only an attempt that never proved its own login can have been refused at the login: once the
        // tab's script ran, "Permission denied" on its screen is some program's (a git push), not ssh's.
        let provedLogin = remoteConnected
        if provedLogin { reconnectAttempts = 0 }
        // Read below a restore's divider: a "Permission denied" replayed above it is from before.
        let refusal = provedLogin ? nil : Self.loginRefusal(liveTail(16))
        loginRefused = refusal != nil
        let stopped = !isKept && status.running ? status.program : nil
        disconnected = true
        remoteConnected = false
        remoteReady = false
        loginPrompt = false
        status.shellReplaced()
        completion.connectionLost()
        // What ran in a plain remote shell ended with the connection: mark it, as a failure would be.
        if stopped != nil { status.shellExited(code: 255) }
        // tmux or an agent left the terminal in their modes (alternate screen, mouse, keyboard protocol,
        // focus reports, application cursor keys): back to plain. Leaving the alternate screen also
        // restores a saved cursor, so only when it is on (the note would land higher up otherwise).
        if view.getTerminal().isCurrentBufferAlternate { view.feed(text: "\u{1b}[?1049l") }
        view.feed(text: "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[?2004l\u{1b}[?1l\u{1b}>\u{1b}[=0;1u\u{1b}[?25h\u{1b}[0m")
        let name = remote.host.name
        let note: String
        if let refusal {
            note = "\(refusal) Return tries again; ⌘W closes this tab."
        } else if mayReconnectByItself {
            let delay = [2, 5, 10, 20, 30, 60][min(reconnectAttempts, 5)]
            reconnectAttempts += 1
            // The master went with it: wake as soon as one is up again (another tab, the network back).
            wakesWithMaster = !(controlPath.map(RemoteConnection.masterAlive(path:)) ?? false)
            note = everConnected
                ? "Connection to \(name) lost. Reconnecting in \(delay) s (Return: now). The session keeps running on the host; ⌘W closes this tab."
                : "Could not connect to \(name). Trying again in \(delay) s (Return: now); ⌘W closes this tab."
            let work = DispatchWorkItem { [weak self] in self?.reconnect() }
            reconnectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        } else if isKept {
            note = "Could not connect to \(name). Return tries again; ⌘W closes this tab."
        } else {
            let what = stopped.map { "“\($0)” stopped with it" } ?? "what ran in this shell has stopped"
            note = "Connection to \(name) lost: \(what). Return opens a new shell there; ⌘W closes this tab."
        }
        view.feed(text: "\r\n\u{1b}[2m[\(note)]\u{1b}[0m\r\n")
        view.acceptsInput = false
        // Only the user's own Return reconnects: MCP never types into a disconnected tab (see MCPControl).
        view.interceptInput = { [weak self] data in
            if data.contains(13) { self?.reconnect() }
            return true
        }
        delegate?.tabDidChange(self)
    }

    /// Connects again: to the same tmux session or herdr (they kept running), or a new shell.
    func reconnect() {
        guard remote != nil, disconnected, !exited else { return }
        wakesWithMaster = false
        reconnectWork?.cancel()
        reconnectWork = nil
        view.feed(text: "\r\n")
        start()
        delegate?.tabDidChange(self)
    }

    /// While this tab logs in: is ssh asking the user something here (a password, a passphrase, a host
    /// key)? Then the tab says so, and is marked for attention when it is not the one in front.
    private func watchLogin() {
        let asking: Bool
        // ssh asks on the normal screen, on the last line, in a few known shapes; a remote program's own
        // text (a file named password.ts, a MOTD about passwords) is not a question from ssh.
        if remote != nil, !remoteConnected, !disconnected, !waitingForConnection, view.process.running,
           !view.getTerminal().isCurrentBufferAlternate {
            let line = (screenTail(1).last ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            asking = line.hasSuffix("password:") || line.hasSuffix("passphrase:") || line.hasPrefix("enter passphrase for")
                || line.contains("(yes/no") || line.hasSuffix("verification code:") || line.hasSuffix("one-time password:")
                || (line.hasPrefix("enter pin for") && line.hasSuffix(":")) || line.hasSuffix("otp:")
        } else {
            asking = false
        }
        guard asking != loginPrompt else { return }
        loginPrompt = asking
        if asking { status.needsAttention() }
        delegate?.tabDidChange(self)
    }

    /// What the host says about this tab: only once it proves this connection's login got through
    /// (its token), and then what runs in front of its shell, where it is, and its jobs.
    func applyRemote(_ report: RemoteTabReport) {
        guard let remote, !exited, !disconnected else { return }
        let before = (status.running, status.command, directory, remoteConnected, fellBack)
        if let token = report.token, !connectionToken.isEmpty, token == connectionToken {
            remoteConnected = true
            everConnected = true
            loginPrompt = false
            reconnectAttempts = 0
        }
        guard remoteConnected else { return } // files on the host from another connection prove nothing
        if report.plain {
            fellBack = true
            fellBackReason = report.plainReason
        }
        if report.folderMissing { remoteFolderMissing = true }
        paneInMode = report.inMode
        // A herdr tab shows herdr: its state comes from herdr's agents (applyHerdr), not from what runs in front.
        if let foreground = report.foreground, remote.keep != .herdr || fellBack {
            if foreground.isShell { remoteReady = true }
            status.observe(foreground, at: Self.now)
        }
        status.jobsChanged(count: report.jobs, summary: report.jobSummary)
        if let folder = report.directory, folder.hasPrefix("/") { directory = folder }
        completion.remoteReport(folder: report.directory != nil)
        // A title the remote prompt set is stale once a program runs, and the other way round.
        if (status.running, status.command) != (before.0, before.1) { programTitle = nil }
        if (status.running, status.command, directory, remoteConnected, fellBack) != before { delegate?.tabDidChange(self) }
    }

    /// What the host's status checks say about this tab's prompt, for what Next Term types in by itself (Suggest a
    /// Command, Tab completion from the screen); nil for a tab on this Mac.
    var serverPrompt: ServerPrompt? {
        guard let remote else { return nil }
        let alternate = view.getTerminal().isCurrentBufferAlternate
        return ServerPrompt(keep: remote.keep, fellBack: fellBack, connected: remoteConnected && !disconnected && !exited,
                            shellReported: remoteReady, running: status.running, inMode: paneInMode, alternateScreen: alternate,
                            reportsSinceReturn: completion.reportsSinceReturn)
    }

    /// What herdr said on the host: the tab shows the agent that most needs you, or says why herdr doesn't answer
    /// (HerdrWatch). Only once this tab's own connection is up (herdr's list says nothing about this tab's ssh). A tab
    /// that fell back only learns whether herdr is on the host now.
    func applyHerdr(_ report: HerdrReport) {
        guard remote?.keep == .herdr, remoteConnected, !exited, !disconnected else { return }
        let note = herdrWatch.note
        let listed = herdrWatch.observe(report, showsHerdr: !fellBack)
        if herdrWatch.note != note { delegate?.tabDidChange(self) }
        guard let agents = listed else { return }
        let before = (status.state, status.question)
        status.observeAgentHost("herdr", at: Self.now)
        status.observe(agentScreen: HerdrAgent.activity(agents), at: Self.now)
        if before != (status.state, status.question) { delegate?.tabDidChange(self) }
    }

    // MARK: environment

    /// When this tab was last brought to the front (to find the agent you used most recently).
    var lastSelected = Date.distantPast

    /// PATH as given to the shell (for the self-test).
    private(set) var environmentPath = ""
    /// The Claude Code link's port as given to the shell (for the self-test).
    private(set) var claudePort: String?

    private func environment(shellName: String) -> [String] {
        // A fresh terminal, not a child of whatever launched Next Term (see TerminalEnvironment).
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NextTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        // Claude Code connects to Next Term as its IDE (and never to another editor's leftover port).
        ClaudeIDEServer.shared.prepare(&env)
        // Its project, or its own folder where it has none (the home folder: ProjectRoot.project).
        GeminiIDEServer.shared.prepare(&env, workspace: canonicalPath(ProjectRoot.project(from: directory) ?? directory))
        // `nxtrm mcp`, started by an agent in this tab, reaches this copy of Next Term.
        if MCPControlServer.shared.isRunning { env[MCPServer.socketVariable] = MCPControlServer.shared.path }
        // `nxtrm` works in every tab from the first launch, with no install step.
        if let bin = CommandLineTool.script?.deletingLastPathComponent().path {
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !path.split(separator: ":").contains(Substring(bin)) { env["PATH"] = path + ":" + bin }
        }
        // Apps opened from Finder get no LANG; without it zsh and most CLIs mangle UTF-8.
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        if shellName == "zsh", let zdotdir = AppSupport.zshIntegrationDirectory {
            env["NEXTTERM_USER_ZDOTDIR"] = Self.userZDOTDIR(env)
            env["ZDOTDIR"] = zdotdir.path
            env[ShellIntegration.nonceVariable] = nonce // the shell removes it from its environment at once
            // Tab completion's hook loads; `q`: with zsh-autocomplete's list as you type off from the first prompt.
            if CompletionPreferences.isOn { env[ShellIntegration.completionVariable] = CompletionPreferences.quietsAutocomplete ? "q" : "1" }
        }
        environmentPath = env["PATH"] ?? ""
        claudePort = env["CLAUDE_CODE_SSE_PORT"]
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    private static func isDirectory(_ path: String?) -> Bool {
        guard let path else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Whether a URL host names this Mac (file:// URLs from ls, fd, rg and OSC 7 include it).
enum LocalHost {
    static func contains(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty, host != "localhost" else { return true }
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, name.count)
        let local = String(cString: name).lowercased()
        let short = local.split(separator: ".").first.map(String.init) ?? local
        return host == local || host == short || host == short + ".local"
    }
}

/// User preferences that are not per window.
enum Preferences {
    static var optionAsMeta: Bool {
        get { UserDefaults.standard.bool(forKey: "optionAsMeta") }
        set { UserDefaults.standard.set(newValue, forKey: "optionAsMeta") }
    }
}

enum AppSupport {
    /// Where the zsh integration lives; written at launch so it always matches this build. In Next Term's folder in
    /// Application Support, which is the relaunch harness's own for it (`SelfTest.supportFolder`).
    static let zshIntegrationDirectory: URL? = {
        guard let folder = SelfTest.supportFolder else { return nil }
        return try? ShellIntegration.install(in: folder)
    }()
}
