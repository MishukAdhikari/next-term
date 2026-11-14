import AppKit
import NextTermCore

/// Lines selected in a diff (a diff tab, the Git Diff tab's file or All files page, a commit's diff, an
/// agent's proposal), as the agents in the window's tabs are told about them, the way they are told about
/// the editor's selection, and what Send to Agent types for them: what DiffShare in Core decides, in each
/// agent's protocol.
extension DiffShare {
    /// Posted by a diff (any view in it) when what is selected in it may have changed.
    static let changed = Notification.Name("NextTermDiffSelectionChanged")

    /// Claude Code's selection_changed: the lines in the file now, or a caret where they were with their text;
    /// a version no place in the file matches starts at its top, the caret that says no line. A file that
    /// holds secrets is no file.
    var claudeParams: [String: Any] {
        guard let linked else { return ClaudeIDEServer.selectionParams(path: nil, text: "", start: (0, 0), end: (0, 0)) }
        let start = linked.start ?? DiffPosition(line: 0, character: 0)
        let end = linked.end ?? start
        return ClaudeIDEServer.selectionParams(path: linked.path, text: linked.text, start: (start.line, start.character),
                                               end: (end.line, end.character))
    }

    /// Gemini CLI's and Qwen Code's active file: its path, the caret where the lines are or were (1-based, none
    /// when no place is true) and their text. Nil for a file that holds secrets.
    var geminiFile: [String: Any]? {
        guard let linked else { return nil }
        var file: [String: Any] = ["path": linked.path, "timestamp": Int(Date().timeIntervalSince1970 * 1000), "isActive": true]
        if let start = linked.start { file["cursor"] = ["line": start.line + 1, "character": start.character + 1] }
        file["selectedText"] = String(linked.text.prefix(16_384))
        return file
    }

    /// Send to Agent, for the file as it is on disk now.
    func contextItem() -> ContextItem? { contextItem(exists: FileManager.default.fileExists(atPath: path)) }
}

/// A diff whose selected lines can go to an agent: a diff tab (the Git Diff tab's file too) and the All files page.
protocol DiffSelectionHost: AnyObject {
    /// The selected lines, nil when none are.
    func diffShare() -> DiffShare?
    /// The Ask hint is for what is selected: lines of changes not committed yet, in a file that may be shared
    /// (DiffShare.offersAsk).
    var offersAsk: Bool { get }
    /// The toolbar's free space, with the Ask hint in it.
    var askRoom: AskAgentRoom { get }
}

extension DiffSelectionHost where Self: NSView {
    /// Tells the window (and its agents) that the selection may have changed.
    func selectionMayHaveChanged() {
        NotificationCenter.default.post(name: DiffShare.changed, object: self)
    }
}

/// A diff toolbar's free space, between its controls on the left and those on the right. The Ask hint shows
/// at its trailing end, just before the controls on the right, while it fits, with Comment before it while lines
/// of uncommitted changes are selected; Review (N) shows at its leading end while the window's draft review has
/// comments. They take no room of their own, so the toolbar's controls never move for them.
final class AskAgentRoom: NSView {
    let hint = AskAgentHint()
    let comment = ToolbarWordButton("Comment", help: "Adds a review comment on the selected lines. Review sends every comment to the agent at once.")
    let review = ToolbarWordButton("Review", help: "The review comments in this window: edit them, send them to the agent as one message, or discard them.")
    /// The hint has something to say (lines selected, an agent running); it shows when it also fits.
    private(set) var wanted = false
    /// Lines that can be commented on are selected.
    private(set) var commentWanted = false
    private weak var host: DiffSelectionHost?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [hint, comment, review] as [NSView] {
            view.isHidden = true
            addSubview(view) // by its frame: nothing it says reaches the toolbar's layout
        }
        comment.onClick = { [weak self] in
            guard let self, let host = self.host else { return }
            ReviewUI.addComment(from: host, anchor: self.comment)
        }
        review.onClick = { [weak self] in
            guard let self else { return }
            ReviewUI.showReview(anchor: self.review)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(draftChanged(_:)), name: ReviewDraft.changed, object: nil)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the hint for `agent` (its name and its tab's title), with Send to Agent's key; hides it for nil.
    func show(agent: (name: String, tab: String)?, key: String?) {
        if let agent { hint.set(agent: agent.name, tab: agent.tab, key: key) }
        wanted = agent != nil
        place()
    }

    /// Comment for what `host` selects: offered for the lines Ask is offered for, an agent running or not.
    func offerComment(for host: DiffSelectionHost) {
        self.host = host
        commentWanted = host.offersAsk
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place()
    }

    @objc private func draftChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    /// The hint at the trailing end, Comment before it, Review at the leading end, each centred in the bar's
    /// height; hidden unless wanted and there is room for it, the hint first, then Comment, then Review.
    private func place() {
        func centred(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        var trailing = bounds.width
        let size = hint.fittingSize
        hint.isHidden = !(wanted && bounds.width >= size.width + 8)
        hint.frame = centred(size, x: max(0, trailing - size.width))
        if !hint.isHidden { trailing -= size.width + 10 }

        let count = ReviewDraft.existing(window)?.comments.count ?? 0
        review.set(count > 0 ? "Review (\(count))" : "Review", color: Theme.accent)
        let reviewSize = review.fittingSize
        let reviewRoom = count > 0 ? reviewSize.width + 10 : 0

        let commentSize = comment.fittingSize
        comment.isHidden = !(commentWanted && trailing - reviewRoom >= commentSize.width + 8)
        comment.frame = centred(commentSize, x: max(0, trailing - commentSize.width))
        if !comment.isHidden { trailing -= commentSize.width + 10 }

        review.isHidden = !(count > 0 && trailing >= reviewSize.width + 8)
        review.frame = centred(reviewSize, x: 4)
    }

    /// For the self-test: what the hint says while it shows, nil while hidden.
    var shownTitle: String? { hint.isHidden ? nil : hint.title }
}

/// "⌥⌘K Ask Claude Code": a quiet button in a diff's toolbar while lines of uncommitted changes are selected
/// and an agent runs in a tab of the window. A click does Send to Agent: the lines go into the agent's prompt,
/// never sent. The key is Send to Agent's, as Settings has it (none: no key text).
final class AskAgentHint: NSButton {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        refusesFirstResponder = true // the diff keeps the keyboard, and with it the side whose lines go
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(agent: String, tab: String, key: String?) {
        let words = "Ask \(agent)"
        let text = HintWords.ask(agent: agent, key: key) // the editor's hint says the same (H4)
        let tip = "Types the selected lines into \(agent)’s prompt in tab “\(tab)”. Nothing is sent until you press Return there."
        guard text != title || tip != toolTip else { return }
        attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim])
        toolTip = tip
        setAccessibilityLabel(words)
        setAccessibilityHelp(tip)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func clicked() { onClick?() }
}
