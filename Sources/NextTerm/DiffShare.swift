import AppKit
import NextTermCore

/// Lines selected in a diff (a diff tab, the Git Diff tab's file or All files page, a commit's diff, an
/// agent's proposal), as the agents in the window's tabs are told about them, the way they are told about
/// the editor's selection: Claude Code's and opencode's selection_changed, Gemini CLI's and Qwen Code's
/// open files, Copilot CLI's selection; and what Send to Agent types for them (DiffSelection in Core).
struct DiffShare {
    /// Posted by a diff (any view in it) when what is selected in it may have changed.
    static let changed = Notification.Name("NextTermDiffSelectionChanged")

    /// What the diff compares the lines with, for what Send to Agent says about them.
    enum Version: Equatable {
        /// The working tree against HEAD, the index or a commit: the new side is the file on disk.
        case workingTree
        case staged
        case commit(String)
        case branch(String)
        case proposal
    }

    /// The file in the working tree.
    let path: String
    let selection: DiffSelection
    /// The file tends to hold secrets (.env, keys), by its name, its link's or its old name: shared as no
    /// file, as the editor shares such a file.
    let holdsSecrets: Bool
    /// The lines are changes not committed yet (the working tree's or the index's).
    let isUncommitted: Bool
    let version: Version
    /// The code fence's language.
    let language: String

    /// Whether any of a diff's names for its file is one that holds secrets.
    static func holdsSecrets(_ paths: [String?]) -> Bool {
        paths.compactMap { $0 }.contains { IDELink.isSensitive($0) || IDELink.isSensitive(canonicalPath($0)) }
    }

    /// Claude Code's selection_changed: the lines in the file now, or a caret where they were with their text;
    /// a version no place in the file matches starts at its top, the caret that says no line.
    var claudeParams: [String: Any] {
        let start = selection.start ?? DiffPosition(line: 0, character: 0)
        let end = selection.end ?? start
        return ClaudeIDEServer.selectionParams(path: holdsSecrets ? nil : path, text: selection.text,
                                               start: (start.line, start.character), end: (end.line, end.character))
    }

    /// Gemini CLI's and Qwen Code's active file: its path, the caret where the lines are or were (1-based, none
    /// when no place is true) and their text. Nil for a file that holds secrets.
    var geminiFile: [String: Any]? {
        guard !holdsSecrets else { return nil }
        var file: [String: Any] = ["path": path, "timestamp": Int(Date().timeIntervalSince1970 * 1000), "isActive": true]
        if let start = selection.start { file["cursor"] = ["line": start.line + 1, "character": start.character + 1] }
        file["selectedText"] = String(selection.text.prefix(16_384))
        return file
    }

    /// Send to Agent: the file at the lines selected, as `@path#L2-3`, when they are its lines on disk; a staged,
    /// committed or branch version's lines go along as code, said to be that; the old side's text, which the
    /// file no longer has, goes as code with the file's path and no lines. Nil for an agent's proposal (that
    /// agent waits for your answer in its terminal) and for old text too long to paste.
    func contextItem() -> ContextItem? {
        guard version != .proposal else { return nil }
        var item = ContextItem(path: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let code = selection.linesText
        if selection.side == .old {
            guard !code.isEmpty, !AgentPrompt.isTooLargeToInline(code) else { return nil }
            item.code = code
            item.language = language
            item.note = oldNote(exists: exists)
            return item
        }
        item.lines = selection.lines
        switch version {
        case let .commit(sha): item.note = "as of commit \(sha.prefix(7))"
        case let .branch(name): item.note = "as on \(name)"
        case .staged: item.note = "as staged"
        case .workingTree, .proposal: item.note = exists ? nil : "deleted"
        }
        if !selection.isInFile, !AgentPrompt.isTooLargeToInline(code) {
            item.code = code
            item.language = language
        }
        return item
    }

    /// What the old side's lines are: removed (in a commit, on a branch), or the version before the change when
    /// unchanged lines are among them.
    private func oldNote(exists: Bool) -> String {
        let removed = selection.changedOnly
        switch version {
        case let .commit(sha): return removed ? "lines removed in commit \(sha.prefix(7))" : "before commit \(sha.prefix(7))"
        case let .branch(name): return removed ? "lines removed on \(name)" : "before \(name) changed it"
        case .workingTree, .staged, .proposal: return exists ? (removed ? "lines removed" : "before the change") : "deleted"
        }
    }
}

/// A diff whose selected lines can go to an agent: a diff tab (the Git Diff tab's file too) and the All files page.
protocol DiffSelectionHost: AnyObject {
    /// The selected lines, nil when none are.
    func diffShare() -> DiffShare?
    /// Lines are selected, in a diff of changes not committed yet (what the Ask hint is for).
    var hasUncommittedSelection: Bool { get }
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
