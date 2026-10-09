import AppKit
import NextTermCore
import Shiki

/// A file's changes side by side: the old version on the left, the new on the right, rows aligned,
/// removed lines tinted red, added green, the changed words within a line stronger, both sides
/// syntax-coloured and scrolling together. Hunk by hunk you can stage, unstage or revert, each checked
/// against what the diff was made from, so a change an agent made meanwhile is never overwritten.
final class DiffPane: NSView, DiffSelectionHost {
    let root: String
    /// Relative to `root`.
    let path: String
    var base: GitRunner.DiffBase { didSet { if oldValue != base { baseControl.selectedSegment = Self.bases.firstIndex(of: base) ?? 0; reload() } } }
    var onTitleChange: (() -> Void)?

    static let bases: [GitRunner.DiffBase] = [.head, .unstaged, .staged]

    private let header = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let baseControl = NSSegmentedControl(labels: ["All Changes", "Unstaged", "Staged"], trackingMode: .selectOne, target: nil, action: nil)
    private let counts = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let position = NSTextField(labelWithString: "")
    private let stage = NSButton(title: "Stage Hunk", target: nil, action: nil)
    private let unstage = NSButton(title: "Unstage Hunk", target: nil, action: nil)
    private let revert = NSButton(title: "Revert Hunk", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let accept = NSButton(title: "Accept", target: nil, action: nil)
    private let reject = NSButton(title: "Reject", target: nil, action: nil)
    /// Accept's tooltip, naming its key: ⌘↩, or what Settings › Keyboard Shortcuts gives it (`performKeyEquivalent`).
    private var acceptKey: PartToolTip?
    /// The header's free space, where "⌥⌘K Ask Claude Code" shows while lines are selected.
    let askRoom = AskAgentRoom()
    /// The side whose selection counts while neither has the keyboard: the one selected last.
    private var lastSelectedSide: DiffSide = .new

    /// An agent's proposed edit (Claude Code's openDiff): your file against its version, to accept or
    /// reject. Next Term never writes the file; the agent does, once you accept.
    struct Proposal {
        let original: String
        let proposed: String
        let author: String
        /// The agent's name for this diff (Claude's tab_name), to close it later.
        let tag: String
        let client: ObjectIdentifier?
    }
    private(set) var proposal: Proposal?

    /// A file as one commit changed it (from the Git Log), against the commit's first parent. Read-only.
    struct CommitChange {
        let sha: String
        let parent: String?
        /// Where a renamed file came from.
        let oldPath: String?
    }
    private(set) var commit: CommitChange?

    /// A file as a branch changed it since it parted from what is checked out (Compare with Current):
    /// their merge base on the left, the branch on the right. Read-only.
    struct BranchChange {
        /// "refs/heads/feat/x".
        let branch: String
        /// Where a renamed file came from.
        let oldPath: String?
        /// The merge base the comparison read, so the diff starts where its list of files does.
        let base: String
    }
    private(set) var branchChange: BranchChange?
    /// Show Diff with Working Tree (base `.ref`): where the branch has a file that was renamed on disk.
    private(set) var renamedFrom: String?
    /// What base `.ref` is called in the title, when not the ref's own name (the Git Diff tab compares with
    /// where the branch parted from its base, a commit, and names the base).
    private(set) var refLabel: String?
    /// The branch the file on disk is compared with (base `.ref`).
    var workingTreeBranch: String? {
        if case let .ref(name) = base { return name }
        return nil
    }
    /// What that branch is called here: "feat/x", or the label it was given.
    private var refName: String? { workingTreeBranch.map { refLabel ?? BranchCompare.displayName($0) } }
    /// Called once with the decision (true: accepted, with the proposed text).
    var onDecision: ((Bool, String) -> Void)?
    private var decided = false
    private let left = DiffColumn(side: .left)
    private let right = DiffColumn(side: .right)
    private let columns = NSStackView()

    private(set) var file: FileDiff?
    private var rows: [SideBySideRow] = []
    /// The Unified view and the Side by Side | Unified switch (UnifiedDiffView.swift).
    let unified = UnifiedDiffPart()
    /// Next or previous change past the last or the first: true when someone took it (the Git Diff tab
    /// moves to the next or previous file); otherwise the stepper goes round this file.
    var onStepPastEnd: ((_ forward: Bool) -> Bool)?
    /// The change to go to once the diff is read (-1: the last), for a file stepped into from the one after.
    var pendingHunk: Int?
    /// Row index of each hunk's header, in order.
    private var hunkRows: [Int] = []
    private(set) var currentHunk = 0
    private var generation = 0
    private var stamps: (file: FileStamp?, index: FileStamp?) = (nil, nil)
    private var syncing = false
    /// Scrolling done by the stepper, which must not re-pick the hunk from the scroll position.
    private var steering = false
    private static let git = GitRunner.locateGit()

    var absolutePath: String { (root as NSString).appendingPathComponent(path) }
    var title: String {
        if let proposal { return (path as NSString).lastPathComponent + " ✻ " + proposal.author }
        if let commit { return (path as NSString).lastPathComponent + " @ " + commit.sha.prefix(7) }
        if let branchChange { return (path as NSString).lastPathComponent + " @ " + BranchCompare.displayName(branchChange.branch) }
        if let branch = refName { return (path as NSString).lastPathComponent + " ↔ " + branch }
        return (path as NSString).lastPathComponent + " ↔ " + ["HEAD", "Index", "HEAD"][Self.bases.firstIndex(of: base) ?? 0]
    }
    var tooltip: String {
        if let proposal { return "\(proposal.author) proposes changes to \(absolutePath)" }
        if let commit {
            let from = commit.oldPath.map { ", renamed from \($0)" } ?? ""
            return "\(path) in commit \(commit.sha.prefix(7))\(from), against " + (commit.parent.map { "its parent \($0.prefix(7))" } ?? "nothing (the first commit)")
        }
        if let branchChange {
            let from = branchChange.oldPath.map { ", renamed from \($0)" } ?? ""
            return "\(path) as \(BranchCompare.displayName(branchChange.branch)) changed it\(from), since \(branchChange.base.prefix(7)), the commit it shares with HEAD"
        }
        if let branch = refName {
            let from = renamedFrom.map { " (\($0) there)" } ?? ""
            if let point = partingPoint { return "\(path): \(renamedFrom ?? "the file") \(point) on the left, the file on disk on the right" }
            return "\(path): \(branch)’s version\(from) on the left, the file on disk on the right"
        }
        return "Changes in \(path) — " + ["working tree against HEAD", "working tree against the index (unstaged)", "index against HEAD (staged)"][Self.bases.firstIndex(of: base) ?? 0]
    }
    var focusView: NSView { unified.isOn ? unified.column.textView : right.textView }
    /// For the self-test: lines shown as changed, removed or added.
    var changedLineCount: Int { rows.filter { $0.kind == .changed || $0.kind == .added || $0.kind == .removed }.count }

    /// For the self-test: the hunks shown and the text of each side.
    var hunkCount: Int { hunkRows.count }
    var sideTexts: (String, String) { (left.textView.string, right.textView.string) }
    /// For the self-test: what is said instead of the two sides ("" while they show).
    var messageText: String { message.isHidden ? "" : message.stringValue }

    func matches(root: String, path: String) -> Bool {
        proposal == nil && commit == nil && branchChange == nil && workingTreeBranch == nil && self.root == root && self.path == path
    }
    func matches(root: String, path: String, commit sha: String) -> Bool { commit?.sha == sha && self.root == root && self.path == path }
    func matches(root: String, path: String, branch: String) -> Bool { branchChange?.branch == branch && self.root == root && self.path == path }
    func matches(root: String, path: String, workingTreeAgainst branch: String) -> Bool {
        workingTreeBranch == branch && self.root == root && self.path == path
    }

    /// An agent's proposal for `absolutePath`.
    init(proposalFor absolutePath: String, proposal: Proposal) {
        root = (absolutePath as NSString).deletingLastPathComponent
        path = (absolutePath as NSString).lastPathComponent
        base = .head
        self.proposal = proposal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    /// Accept or reject (once). Closing the tab rejects.
    func decide(_ accepted: Bool) {
        guard let proposal, !decided else { return }
        decided = true
        onDecision?(accepted, proposal.proposed)
    }

    var isDecided: Bool { decided }

    @objc private func acceptClicked() { decide(true); closeSelf() }
    @objc private func rejectClicked() { decide(false); closeSelf() }

    /// Accept's key (⌘↩, or what Settings gives it), wherever the keyboard is in the window while the proposal shows:
    /// read as the other parts read theirs, so a key with ⇧ works too. A pane in a tab behind is hidden, and never asked.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard proposal != nil, !decided, accept.isEnabled,
              KeyboardShortcuts.shared.partCommand(for: event, in: .diff) == "diff.accept" else { return super.performKeyEquivalent(with: event) }
        accept.performClick(nil)
        return true
    }

    /// For the self-test: Accept's tooltip.
    var acceptToolTip: String? { accept.toolTip }

    private func closeSelf() {
        var view: NSView? = superview
        while let current = view, !(current is EditorArea) { view = current.superview }
        (view as? EditorArea)?.close(self)
    }

    /// `path` as commit `change.sha` changed it.
    init(root: String, path: String, commit change: CommitChange) {
        self.root = root
        self.path = path
        base = .head
        commit = change
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    /// `path` as `change.branch` changed it since it parted from HEAD.
    init(root: String, path: String, branchChange change: BranchChange) {
        self.root = root
        self.path = path
        base = .head
        branchChange = change
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    /// `path` on disk against its version on `branch`, which had it at `renamedFrom` when it was renamed since.
    /// `label`: what to call `branch` (a commit) in the title.
    convenience init(root: String, path: String, workingTreeAgainst branch: String, renamedFrom: String?, label: String? = nil) {
        self.init(root: root, path: path, base: .ref(branch), renamedFrom: renamedFrom, label: label)
    }

    init(root: String, path: String, base: GitRunner.DiffBase, renamedFrom: String? = nil, label: String? = nil) {
        self.root = root
        self.path = path
        self.base = base
        self.renamedFrom = renamedFrom
        refLabel = label
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let folder = (path as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(string: (path as NSString).lastPathComponent,
                                             attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        if !folder.isEmpty {
            text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: folder, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        }
        pathLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        Typography.singleLine(pathLabel, truncation: .byTruncatingMiddle)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        baseControl.selectedSegment = Self.bases.firstIndex(of: base) ?? 0
        baseControl.controlSize = .small
        baseControl.target = self
        baseControl.action = #selector(baseChanged)
        counts.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        for (button, symbol, tip, action) in [(previous, "chevron.up", "Previous change", #selector(previousHunk)),
                                              (next, "chevron.down", "Next change", #selector(nextHunk))] {
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.contentTintColor = Theme.textDim
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = Theme.textDim
        for (button, action, tip) in [(stage, #selector(stageHunk), "Stage this change (git add, for these lines only)"),
                                      (unstage, #selector(unstageHunk), "Unstage this change"),
                                      (revert, #selector(revertHunk), "Undo this change in the file")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        if let proposal {
            let who = NSMutableAttributedString(string: "\(proposal.author) proposes changes to ", attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textDim,
            ])
            who.append(NSAttributedString(string: (path as NSString).lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text,
            ]))
            pathLabel.attributedStringValue = Typography.truncating(who, .byTruncatingMiddle)
            pathLabel.toolTip = (root as NSString).appendingPathComponent(path)
            for (button, action) in [(accept, #selector(acceptClicked)), (reject, #selector(rejectClicked))] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11.5, weight: button === accept ? .semibold : .regular)
                button.target = self
                button.action = action
            }
            acceptKey = PartToolTip(accept, "Accept", command: "diff.accept", then: ": \(proposal.author) then writes the file")
            accept.bezelColor = .controlAccentColor // the default button's colour, which ⌘↩ as its own key equivalent gave it
            reject.toolTip = "Reject: the file stays as it is"
            header.setViews([pathLabel, counts, askRoom, previous, position, next, reject, accept], in: .leading)
        } else if let commit {
            text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: "@ " + commit.sha.prefix(7), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Theme.textDim,
            ]))
            pathLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
            pathLabel.toolTip = tooltip
            header.setViews([pathLabel, counts, askRoom, previous, position, next], in: .leading)
        } else if let branch = branchChange.map({ BranchCompare.displayName($0.branch) }) ?? refName {
            // Which branch, after the name: "@ feat/x" for its change, "↔ feat/x" for the disk against it.
            text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: (branchChange != nil ? "@ " : "↔ ") + branch, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.textDim,
            ]))
            pathLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
            pathLabel.toolTip = tooltip
            header.setViews([pathLabel, counts, askRoom, previous, position, next], in: .leading)
        } else {
            header.setViews([pathLabel, baseControl, counts, askRoom, previous, position, next, stage, unstage, revert], in: .leading)
        }
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true

        columns.setViews([left, right], in: .leading)
        columns.distribution = .fillEqually
        columns.spacing = 1
        columns.wantsLayer = true
        columns.layer?.backgroundColor = WorkSplitView.line.cgColor // the line between the sides

        for view in [header, columns, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            askRoom.heightAnchor.constraint(equalTo: header.heightAnchor),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: columns.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
        unified.install(in: self, header: header, before: previous)
        askRoom.hint.onClick = { [weak self] in
            guard let self else { return }
            (self.window?.windowController as? TerminalWindowController)?.askAgent(from: self)
        }
        // What is selected goes to the agents, as the editor's selection does.
        for view in [left.textView, right.textView] {
            NotificationCenter.default.addObserver(self, selector: #selector(sideSelectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: view)
        }
        // The sides scroll together, both ways.
        for (column, other) in [(left, right), (right, left)] {
            column.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: column.contentView, queue: .main) { [weak self] _ in
                guard let self, !self.syncing else { return }
                self.syncing = true
                other.contentView.scroll(to: column.contentView.bounds.origin)
                other.reflectScrolledClipView(other.contentView)
                self.syncing = false
                if !self.steering { self.updateCurrentHunk() }
            }
        }
    }

    // MARK: loading

    /// Diffs again, keeping the scroll position.
    func reload() {
        generation += 1
        let token = generation
        let root = self.root, path = self.path, base = self.base
        let absolute = absolutePath
        if let proposal {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Compared with line endings set aside, so a CRLF file does not show every line as changed.
                func lf(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }
                let diff = Self.git.flatMap { GitRunner.diff(old: lf(proposal.original), new: lf(proposal.proposed), git: $0) }
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.show(diff, message: diff == nil ? "The proposed change could not be compared." : nil, token: token)
                }
            }
            return
        }
        if let commit {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let diff = Self.git.flatMap { CommitLog.diff(of: path, oldPath: commit.oldPath, commit: commit.sha, parent: commit.parent, in: root, git: $0) }
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.show(diff, message: diff == nil ? "This change could not be read from git." : nil, token: token)
                }
            }
            return
        }
        if let change = branchChange {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let diff = Self.git.flatMap { BranchCompare.diff(of: path, oldPath: change.oldPath, branch: change.branch, base: change.base, in: root, git: $0) }
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.show(diff, message: diff == nil ? "This change could not be read from git." : nil, token: token)
                }
            }
            return
        }
        if let branch = workingTreeBranch {
            // Tracked or not doesn't matter here: the list came from the branch's files and the disk's.
            let renamedFrom = self.renamedFrom
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let git = Self.git else { return DispatchQueue.main.async { self?.show(nil, message: "Git is not installed.", token: token) } }
                // Nil only when git fails: the branch was deleted, or pruned by a fetch, since the tab opened.
                let diff = GitRunner.diff(of: path, in: root, git: git, base: base, oldPath: renamedFrom)
                let stamps = (FileStamp(path: absolute), FileStamp(path: (root as NSString).appendingPathComponent(".git/index")))
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.stamps = stamps
                    let gone = self.partingPoint.map { "Git could not read the file \($0)." }
                        ?? "Git could not read \(BranchCompare.displayName(branch)): it may have been deleted."
                    self.show(diff, message: diff == nil ? gone : nil, token: token)
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let git = Self.git else { return DispatchQueue.main.async { self?.show(nil, message: "Git is not installed.", token: token) } }
            let tracked = GitRunner.isTracked(path, in: root, git: git)
            let diff = GitRunner.diff(of: path, in: root, git: git, base: tracked ? base : .head, untracked: !tracked && base != .staged)
            let stamps = (FileStamp(path: absolute), FileStamp(path: (root as NSString).appendingPathComponent(".git/index")))
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.stamps = stamps
                self.show(diff, message: nil, token: token)
            }
        }
    }

    /// Opened again from a comparison read since (the branch moved): its change as that list has it now,
    /// from its merge base and the file's old name there, read again.
    func reopen(_ change: BranchChange) {
        guard branchChange != nil else { return }
        branchChange = change
        pathLabel.toolTip = tooltip
        reload()
    }

    /// Opened again from a list read since (base `.ref`): read again, with where the branch has the file
    /// as that list says.
    func reopen(renamedFrom: String?) {
        guard workingTreeBranch != nil else { return }
        self.renamedFrom = renamedFrom
        pathLabel.toolTip = tooltip
        reload()
    }

    /// The file or the index changed (an agent, a commit, a stage): diff again.
    func refreshIfChanged() {
        guard proposal == nil, commit == nil, branchChange == nil else { return } // a commit never changes
        let now = (FileStamp(path: absolutePath), FileStamp(path: (root as NSString).appendingPathComponent(".git/index")))
        if now.0 != stamps.file || now.1 != stamps.index { reload() }
    }

    private func show(_ diff: FileDiff?, message text: String?, token: Int) {
        file = diff
        let empty = diff == nil || diff?.hunks.isEmpty == true
        if let text {
            message.stringValue = text
        } else if diff?.isBinary == true {
            message.stringValue = "This is a binary file: its contents cannot be compared line by line."
        } else if empty, proposal != nil {
            message.stringValue = "The proposed version is the same as the file."
        } else if empty, commit != nil, let diff, diff.newPath != nil, diff.oldPath == nil {
            message.stringValue = "This commit added the file, empty."
        } else if empty, commit != nil, let diff, diff.oldPath != nil, diff.newPath == nil {
            message.stringValue = "This commit deleted the file, which was empty."
        } else if empty, commit != nil {
            message.stringValue = "This commit changed the file’s name or mode, not its lines."
        } else if empty, let branch = (branchChange?.branch).map(BranchCompare.displayName) {
            message.stringValue = Self.emptyBranchChange(diff, on: branch)
        } else if empty, let branch = refName {
            // Renamed since: the same as the file under its name there.
            let there = renamedFrom.map { "\($0) on" } ?? "on"
            message.stringValue = partingPoint.map { "The file on disk is as \(renamedFrom ?? "it") was \($0)." }
                ?? "The file on disk is the same as \(there) \(branch)."
        } else if empty {
            message.stringValue = ["No changes against the last commit.", "No unstaged changes.", "No staged changes."][Self.bases.firstIndex(of: base) ?? 0]
        }
        let showRows = !(empty || diff?.isBinary == true || text != nil)
        message.isHidden = showRows
        columns.isHidden = !showRows || unified.isOn
        unified.column.isHidden = !showRows || !unified.isOn
        rows = showRows ? SideBySide.rows(for: diff!) : []
        hunkRows = rows.indices.filter { rows[$0].kind == .hunkHeader }
        if unified.isOn {
            unified.update(self)
        } else {
            let origin = right.contentView.bounds.origin
            let language = EditorLanguage.id(forFileName: (path as NSString).lastPathComponent)
            left.show(rows, language: language)
            right.show(rows, language: language)
            right.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, right.textView.frame.height - right.contentView.bounds.height))))
            right.reflectScrolledClipView(right.contentView)
        }
        currentHunk = min(currentHunk, max(0, hunkRows.count - 1))
        steering = true
        defer { steering = false }
        let added = diff?.hunks.reduce(0) { $0 + $1.added } ?? 0, removed = diff?.hunks.reduce(0) { $0 + $1.removed } ?? 0
        let numbers = NSMutableAttributedString()
        if added > 0 { numbers.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: Theme.linesAdded])) }
        if removed > 0 {
            if numbers.length > 0 { numbers.append(NSAttributedString(string: " ")) }
            numbers.append(NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: Theme.linesRemoved]))
        }
        counts.attributedStringValue = numbers
        updateButtons()
        if !unified.isOn { updateCurrentHunk() }
        if let wanted = pendingHunk, !hunkRows.isEmpty {
            pendingHunk = nil
            go(toHunk: wanted < 0 ? hunkRows.count - 1 : wanted)
        }
        onTitleChange?()
        selectionMayHaveChanged() // the lines under the selection may be others now
    }

    func applyFont() {
        if unified.isOn { return unified.render(self) }
        left.show(rows, language: EditorLanguage.id(forFileName: (path as NSString).lastPathComponent))
        right.show(rows, language: EditorLanguage.id(forFileName: (path as NSString).lastPathComponent))
    }

    /// Side by Side or Unified was chosen (here, in another diff, or in the View menu): this diff shows
    /// that way, at the change it was on.
    func applyLayout() {
        unified.control.selectedSegment = unified.isOn ? 1 : 0
        let showRows = message.isHidden
        columns.isHidden = !showRows || unified.isOn
        unified.column.isHidden = !showRows || !unified.isOn
        if unified.isOn { unified.update(self) } else { applyFont() }
        if hunkRows.indices.contains(currentHunk) { go(toHunk: currentHunk) }
        selectionMayHaveChanged() // the other view's selection is the one that counts now
    }

    // MARK: the selection, for agents

    /// What Send to Agent gives the agent: the selected lines (DiffShare.contextItem), or the whole file with
    /// nothing selected. Nil for an agent's proposal: that agent is waiting for your answer in its terminal.
    func contextItem() -> ContextItem? {
        guard proposal == nil else { return nil }
        if let share = diffShare() { return share.contextItem() }
        var item = ContextItem(path: absolutePath)
        if let commit {
            item.note = "as of commit \(commit.sha.prefix(7))"
        } else if !FileManager.default.fileExists(atPath: absolutePath) {
            item.note = "deleted"
        }
        return item
    }

    /// The lines selected, as the agents are told about them: in Unified, its column's; side by side, the
    /// side with the keyboard's, else the side selected last (each side keeps its selection drawn).
    func diffShare() -> DiffShare? {
        guard message.isHidden, let file else { return nil }
        let rows = unified.isOn ? unified.column.selectedDiffRows() : (selectedSide == .old ? left : right).selectedDiffRows()
        guard let selection = DiffSelections.make(rows, in: unified.isOn ? unified.shownFile ?? file : file, today: today) else { return nil }
        let version: DiffShare.Version
        if proposal != nil {
            version = .proposal
        } else if let commit {
            version = .commit(commit.sha)
        } else if let branchChange {
            version = .branch(BranchCompare.displayName(branchChange.branch))
        } else {
            version = base == .staged ? .staged : .workingTree
        }
        return DiffShare(path: absolutePath, selection: selection,
                         holdsSecrets: DiffShare.holdsSecrets([absolutePath, renamedFrom, commit?.oldPath, branchChange?.oldPath]),
                         isUncommitted: isUncommitted, version: version,
                         language: EditorLanguage.id(forFileName: (path as NSString).lastPathComponent) ?? "text")
    }

    /// Changes not committed yet: the working tree's or the index's, against HEAD or each other (a file's diff
    /// tab, Git Diff's Uncommitted); not a commit's, a branch's, an agent's proposal, or All changes since a base.
    var isUncommitted: Bool { proposal == nil && commit == nil && branchChange == nil && workingTreeBranch == nil }

    var hasUncommittedSelection: Bool {
        guard isUncommitted, message.isHidden else { return false }
        return unified.isOn ? unified.column.hasSelectedLines : (selectedSide == .old ? left : right).hasSelectedLines
    }

    /// Which version is the file as it is now: the new side for the working tree's changes, your file for an
    /// agent's proposal, neither for a commit's, a branch's or the index's version, or a file that is gone.
    private var today: DiffToday {
        let exists = FileManager.default.fileExists(atPath: absolutePath)
        if proposal != nil { return exists ? .old : .neither }
        if commit != nil || branchChange != nil || base == .staged { return .neither }
        return exists ? .new : .neither
    }

    /// The side with the keyboard, else the one selected last.
    private var selectedSide: DiffSide {
        if let responder = window?.firstResponder {
            if responder === left.textView { return .old }
            if responder === right.textView { return .new }
        }
        return lastSelectedSide
    }

    @objc private func sideSelectionChanged(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        if view.selectedRange().length > 0 { lastSelectedSide = view === left.textView ? .old : .new }
        selectionMayHaveChanged()
    }

    /// For the self-test: the old side, to select removed lines in.
    var oldSideView: NSTextView { left.textView }
    /// For the self-test: where the toolbar's controls are (the Ask hint never moves them).
    var toolbarFrames: [NSRect] { header.arrangedSubviews.filter { $0 !== askRoom && !$0.isHidden }.map(\.frame) }

    // MARK: hunks

    /// Why a branch's change to a file has no lines to show.
    private static func emptyBranchChange(_ diff: FileDiff?, on branch: String) -> String {
        guard let diff, diff.oldPath != nil || diff.newPath != nil else { return "\(branch) no longer changes this file." }
        if diff.oldPath == nil { return "\(branch) added the file, empty." }
        if diff.newPath == nil { return "\(branch) deleted the file, which was empty." }
        return "\(branch) changed the file’s name or mode, not its lines."
    }

    private func updateButtons() {
        let has = !hunkRows.isEmpty
        if proposal != nil || commit != nil || branchChange != nil || workingTreeBranch != nil {
            for button in [previous, next] { button.isEnabled = has }
            position.stringValue = has ? "\(currentHunk + 1) of \(hunkRows.count)" : ""
            return
        }
        stage.isHidden = base != .unstaged
        unstage.isHidden = base != .staged
        revert.isHidden = base == .staged
        for button in [stage, unstage, revert, previous, next] { button.isEnabled = has }
        position.stringValue = has ? "\(currentHunk + 1) of \(hunkRows.count)" : ""
    }

    /// When you scroll, the hunk at the top of the view becomes the one the buttons act on (unless the
    /// whole diff fits: then only the stepper or a click picks it).
    private func updateCurrentHunk() {
        guard !hunkRows.isEmpty else { return }
        if right.textView.frame.height > right.contentView.bounds.height + 1 {
            let top = right.contentView.bounds.minY + right.rowHeight * 2
            let row = Int(max(0, top - right.textView.textContainerInset.height) / right.rowHeight)
            currentHunk = (hunkRows.lastIndex { $0 <= row }) ?? 0
        }
        showCurrentHunk()
    }

    private func showCurrentHunk() {
        guard hunkRows.indices.contains(currentHunk) else { return }
        position.stringValue = "\(currentHunk + 1) of \(hunkRows.count)"
        left.currentHunkRow = hunkRows[currentHunk]
        right.currentHunkRow = hunkRows[currentHunk]
        unified.column.currentHunk = currentHunk
    }

    /// The Unified view picked a change: a click in it, the selection, the scroll position.
    func pick(hunk: Int) {
        guard hunkRows.indices.contains(hunk) else { return }
        currentHunk = hunk
        showCurrentHunk()
    }

    /// What the hunk buttons offer here: nothing for an agent's proposal or a read-only diff.
    var hunkActions: [HunkOps.Action] {
        if proposal != nil || commit != nil || branchChange != nil || workingTreeBranch != nil { return [] }
        switch base {
        case .unstaged: return [.stage, .revert]
        case .staged: return [.unstage]
        default: return [.revert]
        }
    }

    /// A click in a row picks its hunk.
    func select(row: Int) {
        guard let hunk = rows[safe: row]?.hunkIndex, hunkRows.indices.contains(hunk) else { return }
        currentHunk = hunk
        showCurrentHunk()
    }

    @objc private func previousHunk() {
        if currentHunk <= 0, onStepPastEnd?(false) == true { return }
        go(toHunk: currentHunk - 1)
    }

    @objc private func nextHunk() {
        if currentHunk >= hunkRows.count - 1, onStepPastEnd?(true) == true { return }
        go(toHunk: currentHunk + 1)
    }

    func go(toHunk index: Int) {
        guard !hunkRows.isEmpty else { return }
        let target = (index + hunkRows.count) % hunkRows.count
        if unified.isOn {
            unified.go(toHunk: target)
            currentHunk = target
            return showCurrentHunk()
        }
        let y = right.textView.textContainerInset.height + CGFloat(hunkRows[target]) * right.rowHeight - right.rowHeight
        steering = true
        right.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, right.textView.frame.height - right.contentView.bounds.height))))
        right.reflectScrolledClipView(right.contentView)
        steering = false
        currentHunk = target
        showCurrentHunk()
    }

    @objc private func baseChanged() {
        base = Self.bases[max(0, baseControl.selectedSegment)]
        onTitleChange?()
    }

    @objc private func stageHunk() { perform(.stage) }
    @objc private func unstageHunk() { perform(.unstage) }

    @objc private func revertHunk() { confirmRevert(hunk: currentHunk, of: file) }

    /// Asks, then reverts change `index` of `shown`: the diff it was chosen in, whatever is read meanwhile.
    func confirmRevert(hunk index: Int, of shown: FileDiff?) {
        guard let window else { return }
        // Unsaved edits to this file in the editor would be overwritten by the reload: ask to save first.
        if let open = (window.windowController as? TerminalWindowController)?.editorArea.documents.first(where: { $0.path == canonicalPath(absolutePath) }),
           open.isDirty {
            let alert = NSAlert()
            alert.messageText = "“\((path as NSString).lastPathComponent)” has unsaved changes in the editor"
            alert.informativeText = "Save or close it before reverting a change in it."
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert this change in “\((path as NSString).lastPathComponent)”?"
        alert.informativeText = "The lines go back to how they were. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.perform(.revert, hunk: index, of: shown) }
        }
    }

    /// Runs a hunk operation on the current change, the one "2 of 3" names.
    func perform(_ action: HunkOps.Action) { perform(action, hunk: currentHunk, of: file) }

    /// Runs a hunk operation on change `index` of `shown`, the diff it was chosen in (HunkOps first checks
    /// the file and the index are still what that diff was made from); tells the user if the file changed
    /// meanwhile or git is busy.
    func perform(_ action: HunkOps.Action, hunk index: Int, of shown: FileDiff?) {
        guard let file = shown, let git = Self.git, file.hunks.indices.contains(index) else { return NSSound.beep() }
        let hunk = file.hunks[index]
        let before = action == .revert ? try? Data(contentsOf: URL(fileURLWithPath: absolutePath)) : nil
        let outcome = HunkOps.perform(action, hunk: hunk, in: file, root: root, git: git)
        switch outcome {
        case .done:
            if action == .revert, let before { registerUndo(restoring: before) }
        case .changedSinceDiff:
            tell("The file changed since this diff was made", "Nothing was changed. The diff is up to date again: check it and try once more.")
        case .gitBusy:
            tell("Git is busy", "Another git command (perhaps an agent committing) holds the index. Try again in a moment.")
        case .failed:
            tell("That change could not be applied", "Git refused it. The diff is refreshed.")
        }
        reload()
    }

    /// ⌘Z after a revert puts the file back, if nothing changed it since.
    private func registerUndo(restoring data: Data) {
        let url = URL(fileURLWithPath: absolutePath)
        let after = try? Data(contentsOf: url)
        window?.undoManager?.registerUndo(withTarget: self) { pane in
            guard (try? Data(contentsOf: url)) == after else { return pane.tell("The file changed since", "The revert was not undone, so nothing is lost.") }
            try? TextFile.write(data, to: url)
            pane.reload()
        }
        window?.undoManager?.setActionName("Revert Change")
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// One side of the diff: a read-only text view with fixed-height rows, tinted per row, with line numbers.
final class DiffColumn: NSScrollView {
    enum Side { case left, right }
    let side: Side
    let textView: DiffTextView
    private let spacing = LineSpacing()
    var rowHeight: CGFloat { spacing.lineHeight }
    var currentHunkRow: Int? { didSet { if currentHunkRow != oldValue { textView.needsDisplay = true } } }

    init(side: Side) {
        self.side = side
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        textView = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        super.init(frame: .zero)
        layout.delegate = spacing
        textView.column = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.usesFindBar = true
        textView.setAccessibilityLabel(side == .left ? "Before" : "After")
        documentView = textView
        hasVerticalScroller = side == .right
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = Theme.background
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        let ruler = DiffRuler(column: self)
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private(set) var rows: [SideBySideRow] = []
    /// Where each row's text starts (UTF-16).
    private(set) var starts: [Int] = []

    /// What the selection covers, row by row (a header or filler row has no line).
    func selectedDiffRows() -> [DiffSelectedRow] {
        let spans = DiffSelections.spans(of: textView.selectedRange(), starts: starts, length: textView.textStorage?.length ?? 0)
        return spans.compactMap { span in
            guard rows.indices.contains(span.row) else { return nil }
            let row = rows[span.row]
            let line = row.kind == .hunkHeader ? nil : (side == .left ? row.left : row.right)
            return DiffSelectedRow(line: line, side: side == .left ? .old : .new, from: span.from, to: span.to)
        }
    }

    /// The selection holds a line, not only a header or a filler: asked often, so it stops at the first.
    var hasSelectedLines: Bool {
        guard let touched = DiffSelections.rows(of: textView.selectedRange(), starts: starts) else { return false }
        return touched.contains { rows.indices.contains($0) && rows[$0].kind != .hunkHeader && (side == .left ? rows[$0].left : rows[$0].right) != nil }
    }

    /// Line number shown on each row (nil: a filler or a hunk header).
    func number(at row: Int) -> Int? {
        guard rows.indices.contains(row) else { return nil }
        return side == .left ? rows[row].left?.oldNumber : rows[row].right?.newNumber
    }

    /// Text shown on each row (nil: a filler or a hunk header).
    func text(at row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        return side == .left ? rows[row].left?.text : rows[row].right?.text
    }

    func show(_ rows: [SideBySideRow], language: String?) {
        self.rows = rows
        let font = EditorDocument.font
        spacing.font = font
        spacing.factor = AppDelegate.shared?.editorLineHeight ?? 1.35
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = spacing.lineHeight
        style.maximumLineHeight = spacing.lineHeight
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.terminalForeground, .paragraphStyle: style]
        let text = NSMutableAttributedString()
        var lineStarts: [Int] = []
        for row in rows {
            lineStarts.append(text.length)
            let line: String
            if row.kind == .hunkHeader {
                line = ""
            } else {
                line = (side == .left ? row.left?.text : row.right?.text) ?? ""
            }
            text.append(NSAttributedString(string: line.replacingOccurrences(of: "\r", with: "") + "\n", attributes: base))
        }
        // Syntax colours, carrying the grammar's state down each side.
        if let engine = SyntaxEngine.shared, var grammar = engine.language(language) {
            if grammar == "php" { grammar = engine.language("blade") ?? grammar }
            var state: ShikiGrammarState?
            for (i, row) in rows.enumerated() where row.kind != .hunkHeader {
                guard let line = side == .left ? row.left?.text : row.right?.text, line.count < 2000 else { continue }
                guard let result = engine.tokenize(line: line, language: grammar, after: state) else { continue }
                state = result.state
                for token in result.tokens {
                    guard let color = engine.color(token.color) else { continue }
                    let range = NSRange(location: lineStarts[i] + token.offset, length: (token.content as NSString).length)
                    if NSMaxRange(range) <= text.length { text.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
        }
        // The words that changed within a changed line.
        let wordTint = (side == .left ? Theme.linesRemoved : Theme.linesAdded).withAlphaComponent(0.32)
        for (i, row) in rows.enumerated() where row.kind == .changed {
            for range in side == .left ? row.leftChanges : row.rightChanges {
                let shifted = NSRange(location: lineStarts[i] + range.location, length: range.length)
                if NSMaxRange(shifted) <= text.length { text.addAttribute(.backgroundColor, value: wordTint, range: shifted) }
            }
        }
        starts = lineStarts
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        let height = textView.textContainerInset.height * 2 + CGFloat(rows.count) * spacing.lineHeight
        textView.setFrameSize(NSSize(width: max(textView.frame.width, contentSize.width), height: max(height, contentSize.height)))
        (verticalRulerView as? DiffRuler)?.updateThickness()
        verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
    }
}

/// Paints each row's tint under the text: removed red, added green, a quiet hatch where the other side
/// has the line, a band for each hunk's start.
final class DiffTextView: NSTextView {
    weak var column: DiffColumn?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let column, column.rowHeight > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - textContainerInset.height) / column.rowHeight)
        var view: NSView? = superview
        while let current = view, !(current is DiffPane) { view = current.superview }
        (view as? DiffPane)?.select(row: row)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let column else { return }
        let height = column.rowHeight
        let top = textContainerInset.height
        let first = max(0, Int((rect.minY - top) / height))
        let last = min(column.rows.count - 1, Int((rect.maxY - top) / height) + 1)
        guard first <= last else { return }
        for index in first...last {
            let row = column.rows[index]
            let band = NSRect(x: 0, y: top + CGFloat(index) * height, width: bounds.width, height: height)
            let mine = column.side == .left ? row.left : row.right
            switch row.kind {
            case .hunkHeader:
                (index == column.currentHunkRow ? NSColor(hex: 0x2E3440) : NSColor(hex: 0x26282E)).setFill()
                band.fill()
                if let hunk = row.hunkIndex {
                    let label = "⋯  change \(hunk + 1)" as NSString
                    label.draw(at: NSPoint(x: 8, y: band.minY + (height - 14) / 2), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.textDim,
                    ])
                }
            case .removed, .added, .changed:
                if mine == nil {
                    NSColor(hex: 0x232428).setFill() // the line exists only on the other side
                    band.fill()
                } else {
                    (column.side == .left ? Theme.linesRemoved : Theme.linesAdded).withAlphaComponent(0.12).setFill()
                    band.fill()
                }
            case .unchanged:
                break
            }
        }
    }
}

/// Line numbers for one side of a diff (blank on filler and header rows).
final class DiffRuler: NSRulerView {
    private weak var column: DiffColumn?

    init(column: DiffColumn) {
        self.column = column
        super.init(scrollView: column, orientation: .verticalRuler)
        clientView = column.textView
        clipsToBounds = true
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func updateThickness() {
        let largest = column?.rows.compactMap { column?.side == .left ? $0.left?.oldNumber : $0.right?.newNumber }.max() ?? 0
        let digits = max(3, String(largest).count)
        ruleThickness = CGFloat(digits) * 8 + 18
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let column, let text = clientView as? NSTextView else { return }
        let height = column.rowHeight
        let offset = convert(NSPoint.zero, from: text).y
        let visible = column.contentView.bounds
        let top = text.textContainerInset.height
        let first = max(0, Int((visible.minY - top) / height))
        let last = min(column.rows.count - 1, Int((visible.maxY - top) / height) + 1)
        guard first <= last else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (EditorDocument.font.pointSize) - 1.5), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: 0x5A5F69)]
        for index in first...last {
            guard let number = column.number(at: index) else { continue }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = top + CGFloat(index) * height + offset + (height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
    }
}
