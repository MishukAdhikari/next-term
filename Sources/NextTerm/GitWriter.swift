import AppKit
import NextTermCore

/// Git commands that change things: switch, branch, fetch, merge, push, commit. One at a time per
/// repository (worktrees share their refs), never waiting on a prompt (whatever needs a password or a
/// passphrase fails at once and says so), and each one written to Git Commands as it would be typed.
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

    /// One queue per repository (its common git folder, canonical): your writes and background fetches
    /// take turns.
    private var queues: [String: DispatchQueue] = [:]

    /// A run that talks to a remote, shown as a spinning sync arrow in the sidebar header.
    enum Activity: String {
        case fetching = "Fetching", pulling = "Pulling", pushing = "Pushing"
    }
    /// Posted on the main thread when a fetch, pull or push starts or ends.
    static let activityChanged = Notification.Name("NextTermGitActivityChanged")
    /// The remote runs under way, by work-tree folder (canonical), oldest first. Main thread.
    private var activities: [String: [Activity]] = [:]
    /// Runs that talk to a remote, yours and background fetches, by repository (canonical). Main thread.
    private var remoteRuns: [String: Int] = [:]
    /// The background fetch under way in each repository (canonical). Main thread.
    private var backgroundRuns: [String: BackgroundRun] = [:]

    /// What the work tree at `directory` is doing with its remote now, if anything.
    func activity(in directory: String) -> Activity? { activities[canonicalPath(directory)]?.last }

    /// For the self-test: as if a fetch, pull or push had started (or, with nil, all had ended) there.
    func setActivity(_ activity: Activity?, in directory: String) {
        let key = canonicalPath(directory)
        activities[key] = activity.map { [$0] }
        NotificationCenter.default.post(name: Self.activityChanged, object: self)
    }

    /// Whether a fetch, pull or push runs in the repository (any of its worktrees) now, a background fetch
    /// included.
    func isTalkingToRemote(repository: String) -> Bool { remoteRuns[canonicalPath(repository)] != nil }

    /// Whether a background fetch runs now in the repository of the work tree at `directory`.
    func isFetchingInBackground(in directory: String) -> Bool { backgroundRuns[Self.repository(of: directory)] != nil }

    /// For the self-test: as if a background fetch had started (or ended) in the work tree's repository.
    func setFetchingInBackground(_ fetching: Bool, in directory: String) {
        backgroundRuns[Self.repository(of: directory)] = fetching ? BackgroundRun() : nil
        NotificationCenter.default.post(name: Self.activityChanged, object: self)
    }

    /// The repository a folder is in: the common git folder of its work tree, canonical (worktrees of one
    /// repository share it). Read from the files, no git run.
    static func repository(of directory: String) -> String {
        canonicalPath(GitRunner.commonGitDir(root: ProjectRoot.find(from: directory)) ?? directory)
    }

    private func writeQueue(for repository: String) -> DispatchQueue {
        let key = canonicalPath(repository)
        let queue = queues[key] ?? DispatchQueue(label: "nextterm.git-writes.\(key)")
        queues[key] = queue
        return queue
    }

    private func remoteRunChanged(_ repository: String, by delta: Int) {
        let key = canonicalPath(repository)
        let count = (remoteRuns[key] ?? 0) + delta
        remoteRuns[key] = count > 0 ? count : nil
    }

    /// Runs each step (the arguments after `git -C directory`) in order, stopping at the first that fails,
    /// and reports the last one run, on the main thread. `repository` (the common git dir) serializes.
    /// `activity` marks a run that talks to a remote, for as long as it runs. A background fetch in the
    /// repository makes way: it stops now, rather than keep this waiting behind a slow remote.
    func run(_ title: String, in directory: String, repository: String, steps: [[String]], activity: Activity? = nil,
             completion: @escaping (Result) -> Void) {
        guard let git = Self.git else { return completion(Result(status: 127, output: "Git is not installed.")) }
        backgroundRuns[canonicalPath(repository)]?.stop()
        let queue = writeQueue(for: repository)
        let key = canonicalPath(directory)
        if let activity {
            activities[key, default: []].append(activity)
            remoteRunChanged(repository, by: 1)
            NotificationCenter.default.post(name: Self.activityChanged, object: self)
        }
        let completion: (Result) -> Void = { [weak self] result in
            if let self, let activity, let index = self.activities[key]?.firstIndex(of: activity) {
                self.activities[key]?.remove(at: index)
                if self.activities[key]?.isEmpty == true { self.activities[key] = nil }
                self.remoteRunChanged(repository, by: -1)
                NotificationCenter.default.post(name: Self.activityChanged, object: self)
            }
            completion(result)
        }
        queue.async {
            var last = Result(status: 0, output: "")
            for args in steps {
                let started = Date()
                last = Self.execute(git, ["-C", directory] + args)
                let entry = GitCommandLog.Entry(title: title, command: Self.commandLine(args), directory: directory, start: started,
                                         duration: Date().timeIntervalSince(started), status: last.status, output: last.output)
                DispatchQueue.main.async { GitCommandLog.shared.add(entry) }
                if !last.ok { break }
            }
            DispatchQueue.main.async { completion(last) }
        }
    }

    /// A background fetch of each remote in `remotes`, one after another on the repository's queue (so
    /// never at the same time as a write of yours), each with its own result, on the main thread. Nothing
    /// can prompt, FETCH_HEAD stays as it is, and each stops after three minutes. A command of yours for
    /// the repository stops it (see `run`). In Git Commands only when "Show background fetches" is on.
    func fetchInBackground(in directory: String, repository: String, remotes: [String], completion: @escaping ([Result]) -> Void) {
        guard let git = Self.git else { return completion([Result(status: 127, output: "Git is not installed.")]) }
        let key = canonicalPath(repository)
        let run = BackgroundRun()
        backgroundRuns[key] = run
        remoteRunChanged(repository, by: 1)
        NotificationCenter.default.post(name: Self.activityChanged, object: self)
        writeQueue(for: repository).async {
            var results: [Result] = []
            for remote in remotes where !run.isStopped {
                let args = FetchSchedule.arguments(remote: remote)
                let started = Date()
                var result = Self.execute(git, ["-C", directory] + args, environment: Self.backgroundEnvironment, timeout: 180,
                                          started: run.started)
                run.ended()
                if run.isStopped { result = Result(status: result.status, output: result.output + "\nStopped, so a command of yours could run.") }
                results.append(result)
                let entry = GitCommandLog.Entry(title: "Background fetch", command: Self.commandLine(args), directory: directory, start: started,
                                                duration: Date().timeIntervalSince(started), status: result.status, output: result.output,
                                                background: true)
                DispatchQueue.main.async { GitCommandLog.shared.add(entry) }
            }
            DispatchQueue.main.async { [weak self] in
                if self?.backgroundRuns[key] === run { self?.backgroundRuns[key] = nil }
                self?.remoteRunChanged(repository, by: -1)
                NotificationCenter.default.post(name: Self.activityChanged, object: self)
                completion(results)
            }
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

    /// A background fetch's: as above, and the Git Credential Manager fails rather than open its window.
    static let backgroundEnvironment: [String: String] = {
        var env = environment
        env["GCM_INTERACTIVE"] = "never"
        return env
    }()

    /// One git run: output to a file (never a pipe a long-lived child could hold open), no stdin, and a
    /// stop after ten minutes (or `timeout`) with SIGTERM only: a git that is writing is never killed outright.
    /// `started` is handed the running git.
    private static func execute(_ git: String, _ arguments: [String], environment: [String: String] = environment,
                                timeout: TimeInterval = 600, started: ((Process) -> Void)? = nil) -> Result {
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
        started?(process)
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            exited.wait()
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard timedOut else { return Result(status: process.terminationStatus, output: text) }
        return Result(status: 124, output: text + "\nStopped after \(Int(timeout / 60)) minutes.")
    }
}

/// A background fetch under way. A command of yours for the same repository stops it rather than wait
/// behind it: SIGTERM, which git cleans up after (it removes its lock files), and the remotes still to go
/// are skipped. The next interval tries again.
private final class BackgroundRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// One of its gits started (on the repository's queue). One that starts after `stop` stops at once.
    func started(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if stopped { process.terminate() } else { self.process = process }
    }

    func ended() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    /// A command of yours was queued (main thread).
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        process?.terminate()
    }
}

/// Every git command Next Term ran for you, newest last: the exact command line, when, how long, how it
/// ended, and what it printed. Kept in memory, the last 500.
final class GitCommandLog {
    static let shared = GitCommandLog()

    struct Entry {
        let title: String
        let command: String
        let directory: String
        let start: Date
        let duration: TimeInterval
        let status: Int32
        let output: String
        /// A background fetch: listed only when "Show background fetches" is on.
        var background = false
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    /// Background fetches are listed too (Git Commands' "Show background fetches").
    var showBackground: Bool {
        get { UserDefaults.standard.bool(forKey: "gitCommandsShowBackground") }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitCommandsShowBackground")
            onChange?()
        }
    }

    func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        // Background fetches keep to the last 100, so they never push your own commands out.
        let background = entries.indices.filter { entries[$0].background }
        if background.count > 100 { entries.remove(at: background[0]) }
        if !entry.background || showBackground { onChange?() }
    }

    /// The entries listed now.
    var shown: [Entry] { showBackground ? entries : entries.filter { !$0.background } }

    var text: String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        return shown.map { e in
            var block = "\(time.string(from: e.start))  \(e.title)  ·  \(e.status == 0 ? "done" : "exit \(e.status)")  ·  "
                + String(format: "%.1f s", e.duration) + "\n$ cd " + ShellQuote.quote(e.directory) + "\n$ " + e.command
            let output = e.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { block += "\n" + output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n") }
            return block
        }.joined(separator: "\n\n")
    }
}

/// The Git Commands window (Git › Git Commands, or Show Git Commands from an error).
final class GitCommandsWindowController: NSWindowController {
    static let shared = GitCommandsWindowController()
    private let textView: NSTextView
    /// Lists the fetches Next Term makes by itself too.
    let showBackground = NSButton(checkboxWithTitle: "Show background fetches", target: nil, action: nil)

    private init() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Git Commands"
        window.isReleasedWhenClosed = false
        let content = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        showBackground.translatesAutoresizingMaskIntoConstraints = false
        showBackground.controlSize = .small
        showBackground.font = .systemFont(ofSize: 11)
        content.addSubview(scroll)
        content.addSubview(showBackground)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            showBackground.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 7),
            showBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            showBackground.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.contentView = content
        super.init(window: window)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        showBackground.target = self
        showBackground.action = #selector(showBackgroundChanged)
        showBackground.toolTip = "The fetches Next Term makes by itself, to keep “Pull” up to date (Settings › Editor › Git)."
        GitCommandLog.shared.onChange = { [weak self] in self?.reload() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func showBackgroundChanged() { GitCommandLog.shared.showBackground = showBackground.state == .on }

    func reload() {
        showBackground.state = GitCommandLog.shared.showBackground ? .on : .off
        let text = GitCommandLog.shared.text
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
