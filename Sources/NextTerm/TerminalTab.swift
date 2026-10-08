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
    /// Takes keystrokes before the program would (a remote tab waiting to reconnect); true: handled.
    var interceptInput: ((ArraySlice<UInt8>) -> Bool)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice) // parse first: OSC marks in this chunk update the status
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let interceptInput, interceptInput(data) { return }
        guard acceptsInput else { return }
        onInput?()
        super.send(source: source, data: Self.withoutScreenChecksum(data))
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
        typeIn(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Types text at the prompt as a paste: with bracketed paste on (zsh's default), the line editor
    /// inserts it literally and never runs it, even if it contained a newline.
    func typeIn(_ text: String) {
        let clean = String(text.unicodeScalars.filter { !ShellQuote.isControl($0) })
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + clean + "\u{1b}[201~" : clean)
    }

    /// Types text as a paste that keeps its line breaks (a prompt for an agent): other control
    /// characters are dropped, so the text cannot end the paste early or press keys.
    func typeText(_ text: String) {
        let kept = String(text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || !ShellQuote.isControl($0) })
        let lines = kept.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + lines + "\u{1b}[201~" : lines)
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
        // SwiftTerm keeps its cell size to itself: the height from the rows, the width from the font, as it does.
        let cellHeight = getOptimalFrameSize().height / CGFloat(terminal.rows)
        let scale = window?.backingScaleFactor ?? 2
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellWidth = max(1, (advance * scale).rounded() / scale)
        let row = Int((frame.height - point.y) / cellHeight)
        let col = Int(point.x / cellWidth)
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
    let id = UUID()
    /// Set for a tab on a server.
    let remote: RemoteTab?
    /// The connection to the host dropped; the tab waits to reconnect.
    private(set) var disconnected = false
    /// The tab's script runs on the host: ssh got past its login (password, host key). Until then
    /// nothing may be typed into the tab but by the user, who sees what ssh asks.
    private(set) var remoteConnected = false
    /// The host reported this tab's shell at its prompt at least once: commands can be typed into it.
    private(set) var remoteReady = false
    /// tmux or herdr was missing on the host, so this tab is a plain shell that nothing keeps.
    private(set) var fellBack = false
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
    /// herdr's agents, last reported (a herdr tab).
    private(set) var herdrAgents: [HerdrAgent] = []
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
    private var shellName: String { (shellPath as NSString).lastPathComponent }

    init(directory: String?, fontSize: CGFloat, remote: RemoteTab? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.remote = remote
        self.directory = remote?.directory ?? (Self.isDirectory(directory) ? directory! : home)
        self.shellPath = remote == nil ? Self.loginShell() : RemoteConnection.sshPath
        self.view = NextTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()

        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        // Off by default: on most non-US layouts Option types # @ | [ ] { } ~ \. Toggle in the File menu.
        view.optionAsMetaKey = Preferences.optionAsMeta

        view.onOutput = { [weak self] in self?.status.output(at: Self.now) }
        view.onInput = { [weak self] in self?.status.input(at: Self.now) }
        view.onKeyboard = { [weak self] in if let self { MCPControl.typedByUser(self) } }
        view.onBell = { [weak self] in self?.attention() }
        view.linkBaseDirectory = { [weak self] in self?.liveDirectory ?? NSHomeDirectory() }
        view.opensFiles = remote == nil

        let terminal = view.getTerminal()
        terminal.registerOscHandler(code: ShellIntegration.oscCode) { [weak self] payload in
            guard let self, let event = ShellIntegration.parse(payload, nonce: self.nonce) else { return }
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
            loginPrompt = false
            connectionToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
            view.interceptInput = nil
            view.acceptsInput = true
            view.startProcess(executable: shellPath, args: RemoteConnection.tabArguments(remote, path: path, tabKey: remoteKey, token: connectionToken),
                              environment: RemoteConnection.environment(), execName: nil, currentDirectory: NSHomeDirectory())
            return
        }
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
            self.delegate?.tabDidChange(self)
        }
        watcher.resume()
        execWatcher = watcher
    }

    /// Ends the shell and everything it started.
    func terminate() {
        execWatcher?.cancel()
        execWatcher = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        MCPControl.forget(self)
        guard !exited else { return }
        exited = true
        RemoteConnection.doneConnecting(self)
        // A disconnected remote tab's ssh has exited and was reaped: its pid may be another process's now,
        // so neither SwiftTerm (SIGTERM) nor we (SIGHUP) signal it, as for a shell that already exited.
        let gone = disconnected || waitingForConnection
        let pid = gone ? 0 : view.process.shellPid
        if !gone { view.terminate() }
        // Interactive shells ignore SIGTERM; SIGHUP makes them exit and hang up their jobs.
        if pid > 0 {
            kill(pid, SIGHUP)
            Self.reap(pid)
        }
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
        view.typeText(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.exited else { return }
            self.view.send(txt: "\r")
        }
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
        let terminal = view.getTerminal()
        guard let last = lastTextRow() else { return [] }
        let first = max(terminal.buffer.totalLinesTrimmed, last - count + 1)
        return (first...last).compactMap { terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) }
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

    // MARK: serving

    /// The local address a running server printed (`npm run dev`, `langgraph dev`, `uvicorn`): shown as
    /// " · :5173" after the title, opened by File › Open Served URL, given to agents in list_tabs.
    private(set) var servedURL: URL?
    /// The first row of the running command's output; set when the shell integration reports the start.
    private var pendingServingStart: Int?
    private var servingStart: Int?
    private var servingScanned: Int?
    private var servingCommand = -1

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
        }
        guard servedURL == nil, let start = servingStart, let last = lastTextRow() else { return }
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
        status.observe(agentScreen: AgentScreen.activity(screenLines: screenTail()), at: Self.now)
        if before.0 != status.state || before.1 != status.question { delegate?.tabDidChange(self) }
    }

    /// Why closing this tab would lose something, or nil. Running programs, and jobs left in the
    /// background or suspended with Ctrl-Z (a stopped vim with unsaved changes).
    var closeWarning: String? {
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
            return items.isEmpty ? nil : items.joined(separator: ", ") + " on \(remote.host.name)"
        }
        var items: [String] = []
        if status.running { items.append(status.program.isEmpty ? "a running process" : "“\(runningName)” (running)") }
        if status.integrated {
            if status.jobs > 0 {
                // "vim notes.md (suspended)" -> “vim notes.md” (suspended): the state is not part of the command.
                items += status.jobSummary.split(separator: "\n").map { line -> String in
                    if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
                        return "“\(line[..<open.lowerBound])”" + line[open.lowerBound...]
                    }
                    return "“\(line)”"
                }
                if items.isEmpty { items.append("\(status.jobs) background job\(status.jobs == 1 ? "" : "s")") }
            }
        } else if !status.running {
            items += ProcessInspector.childProcessNames(of: view.process.shellPid).map { "“\($0)”" }
        }
        return items.isEmpty ? nil : items.joined(separator: ", ")
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
        if let servedURL { lines.append("Serving \(servedURL.absoluteString)") }
        if let remote { lines.append("Sessions kept: \(remote.keep.label)") }
        return lines.joined(separator: "\n")
    }

    // MARK: events

    private func handle(_ event: ShellIntegration.Event) {
        switch event {
        case .commandStarted(let line, let expanded):
            programTitle = nil
            // Its output starts below the line the command was typed on.
            pendingServingStart = (lastTextRow() ?? 0) + 1
            status.commandStarted(line, expanded: expanded, at: Self.now)
            // Gemini or Qwen starting (or installed since launch): their IDE switch on, for the next start too.
            if ["gemini", "gemini-cli", "qwen", "qwen-code"].contains(status.program) { AppDelegate.shared.enableAgentIDEModes() }
        case .commandFinished(let code):
            programTitle = nil
            status.commandFinished(exitCode: code, at: Self.now)
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
        // Programs redraw after a resize; that is not work.
        status.resized(at: Self.now)
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
        let refusal = provedLogin ? nil : Self.loginRefusal(screenTail(16))
        loginRefused = refusal != nil
        let stopped = !isKept && status.running ? status.program : nil
        disconnected = true
        remoteConnected = false
        remoteReady = false
        loginPrompt = false
        status.shellReplaced()
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
        if report.plain { fellBack = true }
        if report.folderMissing { remoteFolderMissing = true }
        // A herdr tab shows herdr: its state comes from herdr's agents (applyHerdr), not from what runs in front.
        if let foreground = report.foreground, remote.keep != .herdr || fellBack {
            if foreground.isShell { remoteReady = true }
            status.observe(foreground, at: Self.now)
        }
        status.jobsChanged(count: report.jobs, summary: report.jobSummary)
        if let folder = report.directory, folder.hasPrefix("/") { directory = folder }
        // A title the remote prompt set is stale once a program runs, and the other way round.
        if (status.running, status.command) != (before.0, before.1) { programTitle = nil }
        if (status.running, status.command, directory, remoteConnected, fellBack) != before { delegate?.tabDidChange(self) }
    }

    /// herdr's agents on the host: the tab shows the one that most needs you. Only once this tab's own
    /// connection is up (herdr's list says nothing about this tab's ssh).
    func applyHerdr(_ agents: [HerdrAgent]) {
        guard remote?.keep == .herdr, remoteConnected, !fellBack, !exited, !disconnected else { return }
        herdrAgents = agents
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
        GeminiIDEServer.shared.prepare(&env, workspace: canonicalPath(ProjectRoot.find(from: directory)))
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
            env["NEXTTERM_USER_ZDOTDIR"] = env["ZDOTDIR"] ?? ""
            env["ZDOTDIR"] = zdotdir.path
            env[ShellIntegration.nonceVariable] = nonce // the shell removes it from its environment at once
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
    /// Where the zsh integration lives; written at launch so it always matches this build.
    static let zshIntegrationDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return try? ShellIntegration.install(in: base.appendingPathComponent("Next Term", isDirectory: true))
    }()
}
