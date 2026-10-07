import AppKit
import NextTermCore

/// Commit…: the message, and exactly what goes in. What is staged if anything is (the rest stays out),
/// else every change, with new files marked and files that look like secrets or are large called out
/// before they are added. ⌘↩ commits; Commit and Push pushes after; Let Agent Commit asks the agent.
final class CommitSheet: NSObject, NSTextViewDelegate {
    typealias Done = (_ message: String, _ files: [String]?, _ amend: Bool, _ andPush: Bool) -> Void

    private static var shown: CommitSheet?
    private let window: NSWindow
    private let message: NSTextView
    private let hint = NSTextField(labelWithString: "")
    private let amend = NSButton(checkboxWithTitle: "Amend last commit", target: nil, action: nil)
    private var commitButton: NSButton!
    private var pushButton: NSButton!
    private let files: [String]?
    private let hasChanges: Bool
    private let done: Done
    private let onAgent: () -> Void
    private weak var parent: NSWindow?

    static func present(over controller: TerminalWindowController, branch: String?, staged: [String], changed: [String], untracked: Set<String>,
                        onAgent: @escaping () -> Void, done: @escaping Done) {
        guard let parent = controller.window, shown == nil else { return }
        let sheet = CommitSheet(branch: branch, staged: staged, changed: changed, untracked: untracked, root: controller.sidebar.git.snapshot?.root,
                                onAgent: onAgent, done: done)
        shown = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in shown = nil }
        sheet.window.makeFirstResponder(sheet.message)
    }

    private init(branch: String?, staged: [String], changed: [String], untracked: Set<String>, root: String?, onAgent: @escaping () -> Void, done: @escaping Done) {
        files = staged.isEmpty ? changed : nil
        hasChanges = !staged.isEmpty || !changed.isEmpty
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

        let stack = NSStackView(views: [title, scroll, hint, fileList, amend, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
        updateState()
    }

    func textDidChange(_ notification: Notification) { updateState() }

    @objc private func updateState() {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if summary.count > 72 {
            hint.stringValue = "The first line is \(summary.count) characters; 72 or fewer reads best in logs."
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

    private func close() {
        parent?.endSheet(window)
        Self.shown = nil
    }

    /// For the self-test.
    static var current: CommitSheet? { shown }
    func type(_ text: String) { message.string = text; updateState() }
    func pressCommit() { if commitButton.isEnabled { commit() } }
    func setAmend(_ on: Bool) { amend.state = on ? .on : .off; updateState() }
    var fileListText: String { (window.contentView as? NSStackView)?.views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n") ?? "" }
}
