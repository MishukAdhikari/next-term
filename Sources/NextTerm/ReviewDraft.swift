import AppKit
import NextTermCore

/// A window's draft review (plan 039 U3): comments on lines of its diffs, kept until they go to the agent as one
/// prompt or are discarded. In memory only, gone when the window closes or Next Term quits.
@MainActor
final class ReviewDraft {
    /// Posted with the window as object when its draft's comments change.
    static let changed = Notification.Name("NextTermReviewDraftChanged")

    private static var drafts: [ObjectIdentifier: ReviewDraft] = [:]
    private weak var window: NSWindow?
    private(set) var comments: [ReviewComment] = []

    private init(window: NSWindow) { self.window = window }

    /// `window`'s draft, made the first time it is asked for and dropped when the window closes.
    static func of(_ window: NSWindow) -> ReviewDraft {
        let key = ObjectIdentifier(window)
        if let draft = drafts[key] { return draft }
        let draft = ReviewDraft(window: window)
        drafts[key] = draft
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { drafts[key] = nil }
        }
        return draft
    }

    /// The draft of a window that has one, without making one.
    static func existing(_ window: NSWindow?) -> ReviewDraft? { window.flatMap { drafts[ObjectIdentifier($0)] } }

    func add(_ comment: ReviewComment) {
        comments.append(comment)
        posted()
    }

    func update(_ id: UUID, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        if note.isEmpty { comments.remove(at: index) } else { comments[index].note = note }
        posted()
    }

    func remove(_ id: UUID) {
        comments.removeAll { $0.id == id }
        posted()
    }

    func clear() {
        comments = []
        posted()
    }

    /// Each comment looked for again in its file as it is on disk now (each file read once).
    func reanchor() {
        var files: [String: [String]?] = [:]
        let before = comments
        comments = comments.map { comment in
            if files[comment.path] == nil {
                files[comment.path] = .some((try? String(contentsOfFile: comment.path, encoding: .utf8)).map(ReviewComments.lines(of:)))
            }
            return ReviewComments.reanchor(comment, fileLines: files[comment.path] ?? nil)
        }
        if comments != before { posted() }
    }

    private func posted() { NotificationCenter.default.post(name: Self.changed, object: window) }
}

/// The review's controls in a diff's toolbar: Comment for the selected lines, and Review (N) with the comments,
/// Send to Agent and Discard.
@MainActor
enum ReviewUI {
    /// Comment on the lines `host` has selected: a note typed in a popover under `anchor`.
    static func addComment(from host: DiffSelectionHost, anchor: NSView) {
        guard let window = anchor.window, let share = host.diffShare() else { return NSSound.beep() }
        let selected = share.selection.lines
        let span = selected.count == 1 ? "line \(selected.lowerBound)" : "lines \(selected.lowerBound)–\(selected.upperBound)"
        let name = (share.path as NSString).lastPathComponent
        NoteEditor.show(title: "Comment on \(name), \(span)", note: "", button: "Add Comment", anchor: anchor) { note in
            var share = share
            share = DiffShare(path: canonicalPath(share.path), selection: share.selection, holdsSecrets: share.holdsSecrets,
                              isUncommitted: share.isUncommitted, version: share.version, language: share.language)
            guard let comment = ReviewComment(share: share, note: note) else { return }
            ReviewDraft.of(window).add(comment)
        }
    }

    /// The draft's comments in a popover under `anchor`, each with Edit and Delete, and Send to Agent and Discard.
    static func showReview(anchor: NSView) {
        guard let window = anchor.window, let draft = ReviewDraft.existing(window), !draft.comments.isEmpty else { return NSSound.beep() }
        draft.reanchor()
        ReviewList.show(draft: draft, anchor: anchor)
    }

    /// Types the draft into the window's agent as one prompt and presses Return; the draft is then empty.
    static func send(_ draft: ReviewDraft, from window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        guard let tab = controller.agentTab else {
            let alert = controller.noAgentAlert()
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        controller.show(tab)
        window?.makeFirstResponder(tab.view)
        send(draft, to: tab)
    }

    /// The prompt for `draft`, typed into `tab` as one bracketed paste, then Return. Nothing is typed into a
    /// program that doesn't take pastes: a line break would send each line.
    static func send(_ draft: ReviewDraft, to tab: TerminalTab) {
        draft.reanchor()
        guard !draft.comments.isEmpty, MCPControl.canType(tab), tab.view.getTerminal().bracketedPasteMode else { return NSSound.beep() }
        let text = ReviewComments.prompt(draft.comments, relativeTo: canonicalPath(tab.directory))
        tab.view.onKeyboard?()
        tab.view.typeText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak tab] in
            guard let tab, MCPControl.canType(tab) else { return }
            tab.view.typeText("\r")
        }
        draft.clear()
    }
}

/// A quiet text button for a diff's toolbar, as the Ask hint is: the diff keeps the keyboard.
final class ToolbarWordButton: NSButton {
    var onClick: (() -> Void)?

    init(_ words: String, help: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        target = self
        action = #selector(clicked)
        toolTip = help
        setAccessibilityHelp(help)
        set(words)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ words: String, color: NSColor = Theme.textDim) {
        guard words != title else { return }
        attributedTitle = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: color])
        setAccessibilityLabel(words)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func clicked() { onClick?() }
}

/// A note typed in a popover: Return saves, ⇧Return adds a line, Esc closes it unsaved.
@MainActor
enum NoteEditor {
    private static var open: NSPopover?

    static func show(title: String, note: String, button: String, anchor: NSView, save: @escaping (String) -> Void) {
        open?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NoteEditorController(title: title, note: note, button: button) { [weak popover] text in
            popover?.close()
            if let text { save(text) }
        }
        popover.contentViewController = controller
        open = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(controller.textView)
    }

    /// For the self-test: the open editor's note view, if one shows.
    static var shown: NoteEditorController? { open?.isShown == true ? open?.contentViewController as? NoteEditorController : nil }
}

final class NoteEditorController: NSViewController, NSTextViewDelegate {
    let textView = NSTextView()
    private let heading: String
    private let initial: String
    private let buttonTitle: String
    private let done: (String?) -> Void

    init(title: String, note: String, button: String, done: @escaping (String?) -> Void) {
        heading = title
        initial = note
        buttonTitle = button
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let label = NSTextField(labelWithString: heading)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        textView.string = initial
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        let save = NSButton(title: buttonTitle, target: self, action: #selector(saveNote))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelNote))
        cancel.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "⇧Return adds a line")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [hint, NSView(), cancel, save])
        let stack = NSStackView(views: [label, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 380),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(equalToConstant: 84),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = stack
    }

    var note: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                saveNote()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelNote()
            return true
        default:
            return false
        }
    }

    @objc func saveNote() { done(textView.string) }
    @objc private func cancelNote() { done(nil) }
}

/// Review (N)'s popover: the comments, each with its place (outdated ones in amber), its note, Edit and Delete;
/// Send to Agent and Discard at the bottom.
@MainActor
enum ReviewList {
    private static var open: NSPopover?

    static func show(draft: ReviewDraft, anchor: NSView) {
        open?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let window = anchor.window
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        for comment in draft.comments {
            let span = comment.lines.count == 1 ? "\(comment.lines.lowerBound)" : "\(comment.lines.lowerBound)–\(comment.lines.upperBound)"
            var place = "\((comment.path as NSString).lastPathComponent):\(span)"
            if !comment.inFile { place += " (removed lines)" }
            if comment.outdated { place += " · outdated" }
            let label = NSTextField(labelWithString: place)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = comment.outdated ? Theme.attention : .secondaryLabelColor
            label.toolTip = comment.outdated ? "These lines have changed since the comment; it goes to the agent marked outdated." : comment.path
            let note = NSTextField(wrappingLabelWithString: comment.note)
            note.font = .systemFont(ofSize: 12.5)
            note.preferredMaxLayoutWidth = 300
            let edit = ToolbarWordButton("Edit", help: "Change this comment")
            edit.onClick = { [weak anchor] in
                popover.close()
                guard let anchor else { return }
                NoteEditor.show(title: "Comment on \(place)", note: comment.note, button: "Save", anchor: anchor) { text in
                    draft.update(comment.id, note: text)
                }
            }
            let delete = ToolbarWordButton("Delete", help: "Remove this comment")
            delete.onClick = { [weak anchor] in
                draft.remove(comment.id)
                popover.close()
                if !draft.comments.isEmpty, let anchor, anchor.window != nil { show(draft: draft, anchor: anchor) }
            }
            let head = NSStackView(views: [label, NSView(), edit, delete])
            head.widthAnchor.constraint(equalToConstant: 340).isActive = true
            rows.addArrangedSubview(head)
            rows.addArrangedSubview(note)
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let flipped = FlippedView()
        flipped.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), rows.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            rows.topAnchor.constraint(equalTo: flipped.topAnchor), rows.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        rows.layoutSubtreeIfNeeded()
        let height = min(320, max(40, rows.fittingSize.height))

        let agent = (window?.windowController as? TerminalWindowController)?.agentTab.map { TerminalWindowController.agentName(of: $0) }
        let send = NSButton(title: agent.map { "Send to \($0)" } ?? "Send to Agent", target: nil, action: nil)
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.toolTip = "Types every comment into the agent’s prompt as one message and sends it; the review is then empty."
        let discard = NSButton(title: "Discard", target: nil, action: nil)
        discard.bezelStyle = .rounded
        let actions = ClosureTargets()
        actions.bind(send) {
            popover.close()
            ReviewUI.send(draft, from: window)
        }
        actions.bind(discard) {
            popover.close()
            draft.clear()
        }
        objc_setAssociatedObject(popover, &ClosureTargets.key, actions, .OBJC_ASSOCIATION_RETAIN)
        let count = draft.comments.count
        let title = NSTextField(labelWithString: count == 1 ? "1 review comment" : "\(count) review comments")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let buttons = NSStackView(views: [discard, NSView(), send])
        let stack = NSStackView(views: [title, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 356), scroll.heightAnchor.constraint(equalToConstant: height),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        open = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// For the self-test: whether the list shows.
    static var isShown: Bool { open?.isShown == true }
    static func close() { open?.close() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Buttons' actions as closures, kept alive with the popover that shows them.
private final class ClosureTargets: NSObject {
    nonisolated(unsafe) static var key = 0
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func bind(_ button: NSButton, _ action: @escaping () -> Void) {
        actions[ObjectIdentifier(button)] = action
        button.target = self
        button.action = #selector(run(_:))
    }

    @objc private func run(_ sender: NSButton) { actions[ObjectIdentifier(sender)]?() }
}
