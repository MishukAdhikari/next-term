import AppKit
import NextTermCore

/// Git commands that change things: switch, branch, fetch, merge, push, commit. One at a time per
/// repository (worktrees share their refs), never waiting on a prompt (whatever needs a password or a
/// passphrase fails at once and says so), and each one written to the Git Log as it would be typed.
/// Reads stay with GitRunner. Design: claudedocs/research_next-term-git-branches (8.8–8.11).
final class GitWriter {
    static let shared = GitWriter()
    static let git = GitRunner.locateGit()

    struct Result {
        let status: Int32
        /// What the command printed, standard output and error together.
        let output: String
        var ok: Bool { status == 0 }
        var failure: GitFailure? { GitOutput.classify(output) }
    }

    private var queues: [String: DispatchQueue] = [:]

    /// Runs each step (the arguments after `git -C directory`) in order, stopping at the first that fails,
    /// and reports the last one run, on the main thread. `repository` (the common git dir) serializes.
    func run(_ title: String, in directory: String, repository: String, steps: [[String]], completion: @escaping (Result) -> Void) {
        guard let git = Self.git else { return completion(Result(status: 127, output: "Git is not installed.")) }
        let queue = queues[repository] ?? DispatchQueue(label: "nextterm.git-writes.\(repository)")
        queues[repository] = queue
        queue.async {
            var last = Result(status: 0, output: "")
            for args in steps {
                let started = Date()
                last = Self.execute(git, ["-C", directory] + args)
                let entry = GitLog.Entry(title: title, command: Self.commandLine(args), directory: directory, start: started,
                                         duration: Date().timeIntervalSince(started), status: last.status, output: last.output)
                DispatchQueue.main.async { GitLog.shared.add(entry) }
                if !last.ok { break }
            }
            DispatchQueue.main.async { completion(last) }
        }
    }

    /// As it would be typed: `git switch -c 'feat/new idea'`.
    static func commandLine(_ args: [String]) -> String {
        (["git"] + args).map(ShellQuote.quote).joined(separator: " ")
    }

    /// The environment of the user's login shell (so hooks find node, husky and git-lfs, and ssh finds the
    /// agent), with everything that could prompt turned into a quick failure.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env.removeValue(forKey: "GPG_TTY")
        env["PATH"] = LoginShell.path.joined(separator: ":")
        if let socket = LoginShell.sshAuthSock { env["SSH_AUTH_SOCK"] = socket }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["GIT_PAGER"] = "cat"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["LANGUAGE"] = "en"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }()

    /// One git run: output to a file (never a pipe a long-lived child could hold open), no stdin, and a
    /// stop after ten minutes with SIGTERM only: a git that is writing is never killed outright.
    private static func execute(_ git: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.environment = environment
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else { return Result(status: 1, output: "Could not start git.") }
        defer { try? FileManager.default.removeItem(at: url) }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            try? handle.close()
            return Result(status: 127, output: error.localizedDescription)
        }
        try? handle.close()
        var timedOut = false
        if exited.wait(timeout: .now() + 600) == .timedOut {
            timedOut = true
            process.terminate()
            exited.wait()
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Result(status: timedOut ? 124 : process.terminationStatus, output: timedOut ? text + "\nStopped after 10 minutes." : text)
    }
}

/// Every git command Next Term ran for you, newest last: the exact command line, when, how long, how it
/// ended, and what it printed. Kept in memory, the last 500.
final class GitLog {
    static let shared = GitLog()

    struct Entry {
        let title: String
        let command: String
        let directory: String
        let start: Date
        let duration: TimeInterval
        let status: Int32
        let output: String
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        onChange?()
    }

    var text: String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        return entries.map { e in
            var block = "\(time.string(from: e.start))  \(e.title)  ·  \(e.status == 0 ? "done" : "exit \(e.status)")  ·  "
                + String(format: "%.1f s", e.duration) + "\n$ cd " + ShellQuote.quote(e.directory) + "\n$ " + e.command
            let output = e.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { block += "\n" + output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n") }
            return block
        }.joined(separator: "\n\n")
    }
}

/// The Git Log window (⌥⌘L, or Show Git Log from an error).
final class GitLogWindowController: NSWindowController {
    static let shared = GitLogWindowController()
    private let textView: NSTextView

    private init() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Git Log"
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        super.init(window: window)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        GitLog.shared.onChange = { [weak self] in self?.reload() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        let text = GitLog.shared.text
        textView.string = text.isEmpty ? "Nothing yet: the git commands Next Term runs for you appear here, exactly as they would be typed." : text
        textView.scrollToEndOfDocument(nil)
    }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A short notice at the bottom of a window ("Switched to feat/login"), with one optional button
/// ("Undo"). It goes by itself; a notice with a button stays longer.
final class GitToast {
    private static var current: NSPanel?
    private static var action: (() -> Void)?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, in window: NSWindow?, button: String? = nil, isError: Bool = false, action: (() -> Void)? = nil) {
        guard let window else { return }
        dismiss()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = isError ? Theme.failed : Theme.text
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        var views: [NSView] = [label]
        if let button {
            let control = NSButton(title: button, target: GitToastTarget.shared, action: #selector(GitToastTarget.pressed))
            control.bezelStyle = .rounded
            control.controlSize = .small
            views.append(control)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        let size = stack.fittingSize
        let width = min(max(size.width, 160), window.frame.width - 60)
        let panel = NSPanel(contentRect: NSRect(x: window.frame.midX - width / 2, y: window.frame.minY + 24, width: width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.tabHover.cgColor
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background
        stack.frame = background.bounds
        stack.autoresizingMask = [.width, .height]
        background.addSubview(stack)
        panel.setAccessibilityLabel(text)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        current = panel
        self.action = action
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { dismiss() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (button == nil ? 4 : 30), execute: work)
    }

    static func dismiss() {
        hide?.cancel()
        if let current { current.parent?.removeChildWindow(current); current.orderOut(nil) }
        current = nil
        action = nil
    }

    fileprivate static func pressed() {
        let run = action
        dismiss()
        run?()
    }

    /// The current notice's text, for the self-test.
    static var text: String? { (current?.contentView?.subviews.first as? NSStackView)?.views.compactMap { ($0 as? NSTextField)?.stringValue }.first }
    static func pressButtonForTest() { pressed() }
}

private final class GitToastTarget: NSObject {
    static let shared = GitToastTarget()
    @objc func pressed() { GitToast.pressed() }
}

/// Small sheets the git operations share: a name to type (checked as it is typed), a yes/no.
enum GitPrompt {
    /// Asks for one line of text over `window`; `check` returns why it can't be used (shown, and OK is
    /// disabled) or nil.
    static func text(_ title: String, info: String, initial: String = "", placeholder: String = "", button: String,
                     over window: NSWindow?, check: @escaping (String) -> String?, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = Theme.failed
        problem.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [field, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        alert.accessoryView = stack
        let ok = alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let watcher = FieldWatcher { text in
            let why = text.isEmpty ? nil : check(text)
            problem.stringValue = why ?? ""
            ok.isEnabled = !text.isEmpty && why == nil
        }
        field.delegate = watcher
        watcher.changed(field.stringValue)
        alert.window.initialFirstResponder = field
        let finish = { (response: NSApplication.ModalResponse) in
            _ = watcher // kept alive while the sheet is up
            completion(response == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// A question with buttons; the completion gets the index of the one chosen.
    static func ask(_ title: String, info: String, buttons: [String], destructive: Int? = nil, style: NSAlert.Style = .informational,
                    over window: NSWindow?, completion: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = style
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            if index == destructive { button.hasDestructiveAction = true }
            if title == "Cancel" { button.keyEquivalent = "\u{1b}" }
        }
        let finish = { (response: NSApplication.ModalResponse) in completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

private final class FieldWatcher: NSObject, NSTextFieldDelegate {
    let changed: (String) -> Void
    init(_ changed: @escaping (String) -> Void) { self.changed = changed }
    func controlTextDidChange(_ note: Notification) { (note.object as? NSTextField).map { changed($0.stringValue) } }
}
