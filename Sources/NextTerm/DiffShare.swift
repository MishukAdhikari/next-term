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
/// at its trailing end, just before the controls on the right, while it fits: it takes no room of its own, so
/// the toolbar's controls never move for it.
final class AskAgentRoom: NSView {
    let hint = AskAgentHint()
    /// The hint has something to say (lines selected, an agent running); it shows when it also fits.
    private(set) var wanted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        hint.isHidden = true
        addSubview(hint) // by its frame: nothing it says reaches the toolbar's layout
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the hint for `agent` (its name and its tab's title), with Send to Agent's key; hides it for nil.
    func show(agent: (name: String, tab: String)?, key: String?) {
        if let agent { hint.set(agent: agent.name, tab: agent.tab, key: key) }
        wanted = agent != nil
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    /// At the trailing end, centred in the bar's height; hidden unless wanted and there is room for it.
    private func place() {
        let size = hint.fittingSize
        let fits = bounds.width >= size.width + 8
        hint.isHidden = !(wanted && fits)
        hint.frame = NSRect(x: max(0, bounds.width - size.width), y: ((bounds.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
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
        let text = [key, words].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
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
