import AppKit
import NextTermCore
import SwiftTerm

/// SwiftTerm's local-process view, with hooks for the activity the status machine needs.
final class NextTermView: LocalProcessTerminalView {
    static let scrollbackLines = 10_000

    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    var onBell: (() -> Void)?
    /// Only beep for the tab the user is looking at; background tabs show a dot instead.
    var beepAllowed = true
    /// False once the shell has ended: there is nothing left to send keystrokes to.
    var acceptsInput = true

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice) // parse first: OSC marks in this chunk update the status
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
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
        let kept = String(text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || !ShellQuote.isControl($0) })
        let lines = kept.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(txt: getTerminal().bracketedPasteMode ? "\u{1b}[200~" + lines + "\u{1b}[201~" : lines)
    }

    override func bell(source: Terminal) {
        onBell?()
        if beepAllowed { super.bell(source: source) }
    }

    // MARK: drop files (from Finder or the project tree) to type their paths, like Terminal.app

    override init(frame: CGRect) {
        super.init(frame: frame, font: nil, options: TerminalOptions(scrollback: Self.scrollbackLines))
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

    // MARK: links (⌘-click): web and mail links open; files open safely; other schemes are refused

    /// Folder that relative paths in the output are relative to.
    var linkBaseDirectory: (() -> String)?
    /// Opens a file in the editor, at a line and column when the link has them (`src/a.ts:42:7`).
    var openFile: ((URL, _ line: Int?, _ column: Int) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            switch scheme {
            case "http", "https", "mailto": NSWorkspace.shared.open(url)
            // ls/fd/rg hyperlinks name this Mac: file://my-mac.local/path
            case "file" where LocalHost.contains(url.host):
                if let openFile { openFile(url, nil, 1) } else { SafeOpen.open(url, from: window) }
            default: NSSound.beep() // custom app schemes can trigger actions in other apps
            }
            return
        }
        // A plain path such as "src/main.swift:12:4", relative to the tab's folder.
        var path = (link as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = linkBaseDirectory?() { path = (base as NSString).appendingPathComponent(path) }
        var line: Int?, column = 1
        if !FileManager.default.fileExists(atPath: path),
           let range = path.range(of: #":[0-9]+(:[0-9]+)?:?$"#, options: .regularExpression) {
            let numbers = path[range].split(separator: ":").compactMap { Int($0) }
            line = numbers.first
            column = numbers.count > 1 ? numbers[1] : 1
            path = String(path[..<range.lowerBound])
        }
        guard FileManager.default.fileExists(atPath: path) else { return NSSound.beep() }
        if let openFile { openFile(URL(fileURLWithPath: path), line, column) } else { SafeOpen.open(URL(fileURLWithPath: path), from: window) }
    }
}

protocol TerminalTabDelegate: AnyObject {
    func tabDidChange(_ tab: TerminalTab)
    func tabDidExit(_ tab: TerminalTab)
}

/// One tab: a shell in a pty, its terminal view and its status.
final class TerminalTab: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    /// Shared secret with this tab's shell; see ShellIntegration.
    private let nonce = ShellIntegration.makeNonce()
    let view: NextTermView
    let shellPath: String
    var status = TabStatus()
    /// Set by the user (double-click a tab). Wins over everything else.
    var userTitle: String?
    /// Set by the running program via OSC 0/2. Cleared at each command boundary.
    private var programTitle: String?
    private(set) var directory: String
    private(set) var exited = false
    weak var delegate: TerminalTabDelegate?
    /// Fires when the shell process execs something else (`exec zsh`, `omz reload`).
    private var execWatcher: DispatchSourceProcess?
    private var shellName: String { (shellPath as NSString).lastPathComponent }

    init(directory: String?, fontSize: CGFloat) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.directory = Self.isDirectory(directory) ? directory! : home
        self.shellPath = Self.loginShell()
        self.view = NextTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()

        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        // Off by default: on most non-US layouts Option types # @ | [ ] { } ~ \. Toggle in the Shell menu.
        view.optionAsMetaKey = Preferences.optionAsMeta

        view.onOutput = { [weak self] in self?.status.output(at: Self.now) }
        view.onInput = { [weak self] in self?.status.input(at: Self.now) }
        view.onBell = { [weak self] in self?.attention() }
        view.linkBaseDirectory = { [weak self] in self?.liveDirectory ?? NSHomeDirectory() }

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
        guard !exited else { return }
        exited = true
        let pid = view.process.shellPid
        view.terminate()
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
        ProcessInspector.currentDirectory(of: view.process.shellPid) ?? directory
    }

    /// The folder relative paths mean right now: the integration reports it; otherwise ask the kernel.
    var liveDirectory: String { status.integrated ? directory : currentDirectory() }

    /// Twice a second. For shells without integration this is how the tab knows what runs and where it
    /// is; with integration it only looks behind commands that look plain, for agents run by functions.
    func pollForeground() {
        guard !exited else { return }
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
        let top = terminal.buffer.totalLinesTrimmed
        // The last line that exists, found by bisection (SwiftTerm keeps the line count internal).
        var low = top, high = top + 1_000_000
        guard terminal.getScrollInvariantLine(row: low) != nil else { return [] }
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
        let first = max(top, last - count + 1)
        return (first...last).compactMap { terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) }
    }

    /// For a running AI agent: read its screen (working, asking a question, or idle) so the tab's
    /// status follows the agent itself.
    func pollAgentScreen() {
        guard !exited, status.running, status.kind == .agent else { return }
        let before = (status.state, status.question)
        status.observe(agentScreen: AgentScreen.activity(screenLines: screenTail()), at: Self.now)
        if before.0 != status.state || before.1 != status.question { delegate?.tabDidChange(self) }
    }

    /// Why closing this tab would lose something, or nil. Running programs, and jobs left in the
    /// background or suspended with Ctrl-Z (a stopped vim with unsaved changes).
    var closeWarning: String? {
        guard !exited else { return nil }
        var items: [String] = []
        if status.running { items.append(status.program.isEmpty ? "a running process" : "“\(status.program)” (running)") }
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

    /// A folder or program name keeps both ends, like Finder; a title a program sets is prose and gives
    /// way at the end.
    var titleTruncation: NSLineBreakMode {
        if let userTitle, !userTitle.isEmpty { return .byTruncatingMiddle }
        if status.running, let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return .byTruncatingTail }
        return .byTruncatingMiddle
    }

    var title: String {
        if let userTitle, !userTitle.isEmpty { return userTitle }
        // While a program runs, its own title (Claude Code names the task) or its name.
        // At the prompt, the folder: shell themes set titles like "user@host: ~/dir" there, which say less.
        if status.running {
            if let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return String(programTitle.prefix(200)) }
            if !status.program.isEmpty { return status.program }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        let last = (directory as NSString).lastPathComponent
        return last.isEmpty ? directory : last
    }

    var stateDescription: String {
        switch status.state {
        case .idle: return status.running ? "Running \(status.program)" : "Idle"
        case .working: return "Working"
        case .done: return "Done"
        case .failed: return status.exitCode.map { "Failed (exit \($0))" } ?? "Failed"
        case .attention: return status.question.map { "Needs your decision: \($0)" } ?? "Needs attention"
        }
    }

    var tooltip: String {
        var lines = [title, stateDescription]
        if status.running && !status.command.isEmpty { lines.append(String(status.command.prefix(300))) }
        lines.append(directory)
        return lines.joined(separator: "\n")
    }

    // MARK: events

    private func handle(_ event: ShellIntegration.Event) {
        switch event {
        case .commandStarted(let line, let expanded):
            programTitle = nil
            status.commandStarted(line, expanded: expanded, at: Self.now)
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
        if let url = URL(string: directory), url.isFileURL {
            guard LocalHost.contains(url.host) else { return }
            self.directory = url.path
        } else if directory.hasPrefix("/") {
            self.directory = directory
        }
        delegate?.tabDidChange(self)
    }

    /// `waitStatus` is the raw status from waitpid, as SwiftTerm passes it on.
    func processTerminated(source: TerminalView, exitCode waitStatus: Int32?) {
        guard !exited else { return }
        exited = true
        execWatcher?.cancel()
        execWatcher = nil
        guard let waitStatus, waitStatus != 0 else {
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

    // MARK: environment

    /// When this tab was last brought to the front (to find the agent you used most recently).
    var lastSelected = Date.distantPast

    /// PATH as given to the shell (for the self-test).
    private(set) var environmentPath = ""

    private func environment(shellName: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NextTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        // `nxtrm` works in every tab from the first launch, with no install step.
        if let bin = CommandLineTool.script?.deletingLastPathComponent().path {
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !path.split(separator: ":").contains(Substring(bin)) { env["PATH"] = path + ":" + bin }
        }
        // Apps opened from Finder get no LANG; without it zsh and most CLIs mangle UTF-8.
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        // Never leak the launching terminal's identity into ours.
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "WINDOWID", "__CFBundleIdentifier"] {
            env.removeValue(forKey: key)
        }
        if shellName == "zsh", let zdotdir = AppSupport.zshIntegrationDirectory {
            env["NEXTTERM_USER_ZDOTDIR"] = env["ZDOTDIR"] ?? ""
            env["ZDOTDIR"] = zdotdir.path
            env[ShellIntegration.nonceVariable] = nonce // the shell removes it from its environment at once
        }
        environmentPath = env["PATH"] ?? ""
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
