import AppKit
import NextTermCore

/// Commit…: the message, and exactly what goes in. What is staged if anything is (the rest stays out),
/// else every change, with new files marked and files that look like secrets or are large called out
/// before they are added. ⌘↩ commits; Commit and Push pushes after; Let Agent Commit asks the agent;
/// Write with Agent fills the message from an agent CLI, for you to read and edit.
final class CommitSheet: NSObject, NSTextViewDelegate {
    typealias Done = (_ message: String, _ files: [String]?, _ amend: Bool, _ andPush: Bool) -> Void

    private static var shown: CommitSheet?
    private let window: NSWindow
    private let message: NSTextView
    private let hint = NSTextField(labelWithString: "")
    private let writeButton = NSButton(title: "Write with Agent", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let writer: CommitWriter?
    /// The agent writing the message now; Stop stops it.
    private var writing: CommitMessageRun?
    /// The agent that wrote the message in the field.
    private var writtenBy: String?
    /// Why the agent wrote nothing, until the message is edited.
    private var writeProblem: String?
    private let amend = NSButton(checkboxWithTitle: "Amend last commit", target: nil, action: nil)
    private var commitButton: NSButton!
    private var pushButton: NSButton!
    private let files: [String]?
    private let hasChanges: Bool
    private let done: Done
    private let onAgent: () -> Void
    private weak var parent: NSWindow?

    static func present(over controller: TerminalWindowController, branch: String?, staged: [String], changed: [String], untracked: Set<String>,
                        writer: CommitWriter?, onAgent: @escaping () -> Void, done: @escaping Done) {
        guard let parent = controller.window, shown == nil else { return }
        let sheet = CommitSheet(branch: branch, staged: staged, changed: changed, untracked: untracked, root: controller.sidebar.git.snapshot?.root,
                                writer: writer, onAgent: onAgent, done: done)
        shown = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in shown = nil }
        sheet.window.makeFirstResponder(sheet.message)
    }

    private init(branch: String?, staged: [String], changed: [String], untracked: Set<String>, root: String?, writer: CommitWriter?,
                 onAgent: @escaping () -> Void, done: @escaping Done) {
        files = staged.isEmpty ? changed : nil
        hasChanges = !staged.isEmpty || !changed.isEmpty
        self.writer = writer
        self.done = done
        self.onAgent = onAgent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        message = scroll.documentView as! NSTextView
        super.init()

        let title = NSTextField(labelWithString: branch.map { "Commit to “\($0)”" } ?? "Commit (detached HEAD)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        Typography.singleLine(title, truncation: .byTruncatingMiddle)

        message.font = .systemFont(ofSize: 13)
        message.isRichText = false
        message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.textContainerInset = NSSize(width: 6, height: 6)
        message.delegate = self
        message.setAccessibilityLabel("Commit message")
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        Typography.singleLine(hint, truncation: .byTruncatingTail)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Write with Agent, beside the hint under the message: only when an agent CLI is installed.
        writeButton.target = self
        writeButton.action = #selector(writeWithAgent)
        writeButton.controlSize = .small
        writeButton.font = .systemFont(ofSize: 11)
        writeButton.isHidden = writer == nil
        if let writer {
            writeButton.toolTip = "Asks \(writer.agent.name) to write the message from the changes below, for you to read and edit. "
                + "Nothing is committed, and the changes go to \(writer.agent.name) and nowhere else."
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let hintSpacer = NSView()
        hintSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let hintRow = NSStackView(views: [hint, hintSpacer, spinner, writeButton])
        hintRow.spacing = 6

        // What goes in.
        let shownFiles = staged.isEmpty ? changed : staged
        let heading = staged.isEmpty
            ? "All \(changed.count) change\(changed.count == 1 ? "" : "s") will be committed:"
            : "\(staged.count) staged file\(staged.count == 1 ? "" : "s") will be committed" + (changed.count > staged.count ? "; the other changes stay out:" : ":")
        let list = NSMutableAttributedString(string: heading + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        var warnings: [String] = []
        for path in shownFiles.prefix(14) {
            let new = untracked.contains(path)
            list.append(NSAttributedString(string: "  " + path + (new ? "  (new)" : "") + "\n",
                                           attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if shownFiles.count > 14 {
            list.append(NSAttributedString(string: "  …and \(shownFiles.count - 14) more\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for path in shownFiles {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(".env") || [".pem", ".p12", ".key", ".pfx"].contains(where: name.hasSuffix) || name.hasPrefix("id_") {
                warnings.append("\(path) looks like it may hold secrets.")
            } else if let root, let size = (try? FileManager.default.attributesOfItem(atPath: (root as NSString).appendingPathComponent(path)))?[.size] as? Int,
                      size > 5_000_000 {
                warnings.append("\(path) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).")
            }
        }
        if !warnings.isEmpty {
            list.append(NSAttributedString(string: "\n" + warnings.prefix(4).map { "⚠︎ " + $0 }.joined(separator: "\n"),
                                           attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange]))
        }
        if shownFiles.isEmpty {
            list.setAttributedString(NSAttributedString(string: "Nothing to commit.", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let fileList = NSTextField(labelWithAttributedString: list)
        fileList.maximumNumberOfLines = 22
        fileList.lineBreakMode = .byTruncatingMiddle

        amend.target = self
        amend.action = #selector(updateState)
        amend.toolTip = "Replace the last commit with this one. Empty message: keep its message."

        let agent = NSButton(title: "Let Agent Commit", target: self, action: #selector(letAgent))
        agent.toolTip = "Asks the agent in this project to commit the changes with a clear message (it doesn’t push)."
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        pushButton = NSButton(title: "Commit and Push", target: self, action: #selector(commitAndPush))
        commitButton = NSButton(title: "Commit", target: self, action: #selector(commit))
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.toolTip = "⌘↩"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [agent, spacer, cancel, pushButton, commitButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, scroll, hintRow, fileList, amend, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for view in [scroll, hintRow, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
        updateState()
    }

    func textDidChange(_ notification: Notification) {
        writeProblem = nil
        updateState()
    }

    @objc private func updateState() {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        hint.textColor = writeProblem == nil ? .secondaryLabelColor : Theme.failed
        writeButton.isEnabled = hasChanges || writing != nil
        if writing != nil, let writer {
            hint.stringValue = "\(writer.agent.name) is writing the message…"
        } else if let writeProblem {
            hint.stringValue = writeProblem
        } else if summary.count > 72 {
            hint.stringValue = "The first line is \(summary.count) characters; 72 or fewer reads best in logs."
        } else if let writtenBy, !text.isEmpty {
            hint.stringValue = "Written by \(writtenBy): read it, edit it, then commit."
        } else if text.isEmpty {
            hint.stringValue = amend.state == .on ? "Empty: the last commit keeps its message." : "A short summary line, then a blank line and the details."
        } else {
            hint.stringValue = ""
        }
        let amending = amend.state == .on
        commitButton.isEnabled = (!text.isEmpty || amending) && (hasChanges || amending)
        pushButton.isEnabled = commitButton.isEnabled
    }

    private func finish(push: Bool) {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let amending = amend.state == .on
        close()
        done(text, files, amending, push)
    }

    @objc private func commit() { finish(push: false) }
    @objc private func commitAndPush() { finish(push: true) }
    @objc private func cancel() { close() }
    @objc private func letAgent() {
        close()
        onAgent()
    }

    /// Asks the agent for a message (or, while it writes, stops it).
    @objc private func writeWithAgent() {
        if let writing { return writing.stop() }
        guard let writer, hasChanges else { return }
        writeProblem = nil
        writeButton.title = "Stop"
        spinner.startAnimation(nil)
        writing = writer.start { [weak self] outcome in self?.written(outcome) }
        updateState()
    }

    private func written(_ outcome: CommitMessageRun.Outcome) {
        writing = nil
        spinner.stopAnimation(nil)
        writeButton.title = "Write with Agent"
        let name = writer?.agent.name ?? "The agent"
        switch outcome {
        case let .message(text):
            writtenBy = name
            // One edit, so ⌘Z brings back what was there.
            let all = NSRange(location: 0, length: (message.string as NSString).length)
            if message.shouldChangeText(in: all, replacementString: text) {
                message.replaceCharacters(in: all, with: text)
                message.didChangeText()
            }
            window.makeFirstResponder(message)
        case let .failed(why):
            writeProblem = "\(name) didn’t write one: \(why)"
        case .timedOut:
            writeProblem = "\(name) didn’t answer within a minute."
        case .stopped:
            break
        }
        updateState()
    }

    private func close() {
        writing?.stop()
        parent?.endSheet(window)
        Self.shown = nil
    }

    /// For the self-test.
    static var current: CommitSheet? { shown }
    func type(_ text: String) { message.string = text; updateState() }
    func pressCommit() { if commitButton.isEnabled { commit() } }
    func setAmend(_ on: Bool) { amend.state = on ? .on : .off; updateState() }
    var fileListText: String { (window.contentView as? NSStackView)?.views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n") ?? "" }
    var messageText: String { message.string }
    var hintText: String { hint.stringValue }
    var canWriteWithAgent: Bool { !writeButton.isHidden && writeButton.isEnabled }
    var isWriting: Bool { writing != nil }
    func pressWriteWithAgent() { writeWithAgent() }
}

/// Write with Agent: the agent that writes the message, and what it is given to read.
struct CommitWriter {
    let agent: CommitMessageAgent
    /// The agent's program.
    let path: String
    let root: String
    /// Nothing staged: every change goes in, and these new files with it. Nil: what is staged.
    let newFiles: [String]?

    /// Reads what will be committed and asks the agent, off the main thread; `done` on the main thread.
    func start(_ done: @escaping (CommitMessageRun.Outcome) -> Void) -> CommitMessageRun {
        let run = CommitMessageRun()
        let agent = agent, path = path, root = root, newFiles = newFiles
        DispatchQueue.global(qos: .userInitiated).async {
            guard let git = GitWriter.git else { return DispatchQueue.main.async { done(.failed("git is not installed.")) } }
            let prompt = CommitMessageAgent.prompt(recentSubjects: CommitMessageAgent.recentSubjects(at: root, git: git))
            let changes = CommitMessageAgent.changes(at: root, git: git, staged: newFiles == nil, newFiles: newFiles ?? [])
            let outcome = run.run(agent, path: path, prompt: prompt, changes: changes, environment: Self.environment)
            DispatchQueue.main.async { done(outcome) }
        }
        return run
    }

    /// The login shell's PATH, where agents are installed, without what another program's session or git
    /// left behind.
    static var environment: [String: String] {
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        env["PATH"] = LoginShell.path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        return env
    }
}
