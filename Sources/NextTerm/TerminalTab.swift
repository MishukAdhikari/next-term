import AppKit
import NextTermCore
import SwiftTerm

/// SwiftTerm's local-process view, with hooks for the activity the status machine needs.
final class NextTermView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    var onBell: (() -> Void)?
    /// Only beep for the tab the user is looking at; background tabs show a dot instead.
    var beepAllowed = true

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice) // parse first: OSC marks in this chunk update the status
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
    }

    override func bell(source: Terminal) {
        onBell?()
        if beepAllowed { super.bell(source: source) }
    }

    // MARK: drop files (from Finder or the project tree) to type their paths, like Terminal.app

    override init(frame: CGRect) {
        super.init(frame: frame)
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

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            switch scheme {
            case "http", "https", "mailto": NSWorkspace.shared.open(url)
            case "file" where url.host == nil || url.host == "" || url.host == "localhost": SafeOpen.open(url, from: window)
            default: NSSound.beep() // custom app schemes can trigger actions in other apps
            }
            return
        }
        // A plain path such as "src/main.swift:12:4", relative to the tab's folder.
        var path = (link as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = linkBaseDirectory?() { path = (base as NSString).appendingPathComponent(path) }
        if !FileManager.default.fileExists(atPath: path),
           let range = path.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            path = String(path[..<range.lowerBound])
        }
        guard FileManager.default.fileExists(atPath: path) else { return NSSound.beep() }
        SafeOpen.open(URL(fileURLWithPath: path), from: window)
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

    init(directory: String?, fontSize: CGFloat) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.directory = Self.isDirectory(directory) ? directory! : home
        self.shellPath = Self.loginShell()
        self.view = NextTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()

        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        view.optionAsMetaKey = true

        view.onOutput = { [weak self] in self?.status.output(at: Self.now) }
        view.onInput = { [weak self] in self?.status.input(at: Self.now) }
        view.onBell = { [weak self] in self?.attention() }
        view.linkBaseDirectory = { [weak self] in self?.directory ?? NSHomeDirectory() }

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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
        let shellName = (shellPath as NSString).lastPathComponent
        view.startProcess(
            executable: shellPath,
            args: [],
            environment: environment(shellName: shellName),
            execName: "-" + shellName, // leading dash: a login shell, like Terminal.app
            currentDirectory: directory
        )
    }

    /// Ends the shell and everything it started.
    func terminate() {
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

    func pollForeground() {
        guard !status.integrated, !exited else { return }
        let name = ProcessInspector.foregroundProcessName(ptyFileDescriptor: view.process.childfd) ?? ""
        status.foregroundProcess(name, shell: shellPath, at: Self.now)
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
        case .attention: return "Needs attention"
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
        case .commandStarted(let line):
            programTitle = nil
            status.commandStarted(line, at: Self.now)
        case .commandFinished(let code):
            programTitle = nil
            status.commandFinished(exitCode: code, at: Self.now)
        case .directory(let dir):
            if !dir.isEmpty { directory = dir }
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
            guard Self.isLocalHost(url.host) else { return }
            self.directory = url.path
        } else if directory.hasPrefix("/") {
            self.directory = directory
        }
        delegate?.tabDidChange(self)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        delegate?.tabDidExit(self)
    }

    // MARK: environment

    private func environment(shellName: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NextTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty, host != "localhost" else { return true }
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, name.count)
        let local = String(cString: name).lowercased()
        let short = local.split(separator: ".").first.map(String.init) ?? local
        return host == local || host == short || host == short + ".local"
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

enum AppSupport {
    /// Where the zsh integration lives; written at launch so it always matches this build.
    static let zshIntegrationDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return try? ShellIntegration.install(in: base.appendingPathComponent("Next Term", isDirectory: true))
    }()
}
