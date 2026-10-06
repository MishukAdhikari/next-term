import AppKit
import NextTermCore

// MARK: - header: branch and changes at a glance

/// The sidebar's title row. With git: "⎇ main  +41 −10  ↑2 ↓1"; otherwise "Project".
final class SidebarHeaderView: NSView {
    private let branchIcon = NSImageView()
    private let title = NSTextField(labelWithString: "Project")
    private let summary = NSTextField(labelWithString: "")
    /// ⋯: which side the sidebar is on, and hiding it.
    let moreButton = MoreButton(toolTip: "Project sidebar layout", menu: LayoutMenu.sidebar)
    /// Hides the sidebar (⌘B); the top bar then shows a button to bring it back.
    let hideButton = HoverButton()
    var inset: CGFloat = 70 { didSet { needsLayout = true } }
    var onRight = false {
        didSet {
            hideButton.image = NSImage(systemSymbolName: onRight ? "sidebar.right" : "sidebar.left", accessibilityDescription: "Hide Project Sidebar")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        branchIcon.contentTintColor = Theme.textDim
        branchIcon.isHidden = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        Typography.singleLine(title, truncation: .byTruncatingMiddle) // long branch names keep both ends
        summary.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        summary.alignment = .right
        Typography.singleLine(summary, truncation: .byTruncatingTail)
        hideButton.bezelStyle = .regularSquare
        hideButton.isBordered = false
        hideButton.contentTintColor = Theme.textDim
        hideButton.action = #selector(TerminalWindowController.toggleProjectSidebar(_:)) // up the responder chain
        hideButton.toolTip = "Hide the project sidebar (⌘B)"
        hideButton.setAccessibilityLabel("Hide Project Sidebar")
        onRight = false
        [branchIcon, title, summary, hideButton, moreButton].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Project")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Whether the counts are cut short (for the self-test).
    var summaryIsTruncated: Bool {
        layoutSubtreeIfNeeded()
        return summary.cell?.expansionFrame(withFrame: summary.bounds, in: summary) != .zero
    }

    // The whole header is a drag handle for the window, except its ⋯ button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if moreButton.frame.contains(local) { return moreButton }
        if hideButton.frame.contains(local) { return hideButton }
        return self
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    func show(_ snapshot: GitSnapshot?) {
        guard let snapshot else {
            branchIcon.isHidden = true
            title.stringValue = "Project"
            summary.attributedStringValue = NSAttributedString()
            toolTip = nil
            setAccessibilityLabel("Project")
            needsLayout = true
            return
        }
        branchIcon.isHidden = false
        title.stringValue = snapshot.branch ?? "Detached at \(snapshot.head ?? "?")"
        let totals = snapshot.totals
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        // One space between items, none after the last.
        func add(_ s: String, _ color: NSColor) {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font]))
        }
        if totals.added > 0 { add("+\(totals.added)", Theme.linesAdded) }
        if totals.removed > 0 { add("−\(totals.removed)", Theme.linesRemoved) }
        if snapshot.ahead > 0 { add("↑\(snapshot.ahead)", Theme.textDim) }
        if snapshot.behind > 0 { add("↓\(snapshot.behind)", Theme.textDim) }
        summary.attributedStringValue = Typography.truncating(text, .byTruncatingTail, alignment: .right)
        toolTip = Self.describe(snapshot)
        setAccessibilityLabel(Self.describe(snapshot))
        needsLayout = true
    }

    /// "Branch main, tracking origin/main: 2 ahead, 1 behind. 3 modified, 1 added, 2 untracked. +41 −10 lines."
    static func describe(_ s: GitSnapshot) -> String {
        var parts: [String] = []
        var branch = s.branch.map { "Branch \($0)" } ?? "Detached HEAD at \(s.head ?? "?")"
        if let upstream = s.upstream { branch += ", tracking \(upstream)" }
        var sync: [String] = []
        if s.ahead > 0 { sync.append("\(s.ahead) ahead") }
        if s.behind > 0 { sync.append("\(s.behind) behind") }
        parts.append(branch + (sync.isEmpty ? "" : ": " + sync.joined(separator: ", ")))
        let counts: [(GitChange, String)] = [(.modified, "modified"), (.added, "added"), (.renamed, "renamed"),
                                             (.deleted, "deleted"), (.untracked, "untracked"), (.conflicted, "conflicted")]
        let listed = counts.compactMap { change, word -> String? in
            let n = s.count(of: change)
            return n > 0 ? "\(n) \(word)" : nil
        }
        parts.append(listed.isEmpty ? "No changes" : listed.joined(separator: ", "))
        let t = s.totals
        if t.added + t.removed > 0 { parts.append("+\(t.added) −\(t.removed) lines") }
        return parts.joined(separator: ". ") + "."
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let titleHeight = title.intrinsicContentSize.height
        let titleY = (h - titleHeight) / 2
        // The counts sit on the branch name's baseline; centring a smaller box against a larger one
        // leaves them a little high.
        let summaryHeight = summary.intrinsicContentSize.height
        let summaryY = titleY + title.firstBaselineOffsetFromTop - summary.firstBaselineOffsetFromTop
        // The text cell needs about 4 pt of its own margin beyond the text, or it truncates.
        let summaryWidth = min(ceil(summary.intrinsicContentSize.width) + 6, bounds.width * 0.5)
        moreButton.frame = NSRect(x: bounds.width - 30, y: (h - 24) / 2, width: 26, height: 24)
        hideButton.frame = NSRect(x: bounds.width - 56, y: (h - 24) / 2, width: 26, height: 24)
        summary.frame = NSRect(x: bounds.width - summaryWidth - 60, y: summaryY, width: summaryWidth, height: summaryHeight)
        var x = inset + 4
        if !branchIcon.isHidden {
            branchIcon.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
            x += 18
        }
        title.frame = NSRect(x: x, y: titleY, width: max(0, summary.frame.minX - x - 6), height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - a row in the tree

/// "… 12,345 more items" under a folder that is too big to list in full.
final class HiddenEntries {
    let count: Int
    init(count: Int) { self.count = count }
}

final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let stats = NSTextField(labelWithString: "")
    private(set) weak var node: FileNode?
    private(set) var isRenaming = false
    /// While renaming, the field takes the row's free width (up to the counts), as in Finder.
    private lazy var renameWidth = name.trailingAnchor.constraint(equalTo: stats.leadingAnchor, constant: -6)

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12.5)
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stats.alignment = .right
        Typography.singleLine(stats, truncation: .byClipping)
        [icon, name, stats].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        imageView = icon
        textField = name
        // Constraints, not frames: the counts resize themselves whenever their text changes, and the
        // name gives way (truncating in the middle) rather than the counts.
        stats.setContentHuggingPriority(.required, for: .horizontal)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -6),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stats.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(node: FileNode, isRoot: Bool, expanded: Bool, change: GitChange?, lines: LineStats?) {
        self.node = node
        guard !isRenaming else { return }
        icon.image = FileIcons.image(for: node, expanded: expanded)
        icon.alphaValue = change == .ignored ? 0.55 : 1
        let color = change == nil && node.name.hasPrefix(".") ? Theme.textDim : Theme.color(for: change)
        if isRoot {
            let home = canonicalPath(NSHomeDirectory())
            let shown = node.path == home || node.path.hasPrefix(home + "/") ? "~" + node.path.dropFirst(home.count) : node.path
            let text = NSMutableAttributedString(string: node.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text,
            ])
            text.append(Typography.gap(7, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: shown, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim,
            ]))
            // The project name stays whole; its path gives way at the end.
            name.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        } else {
            name.attributedStringValue = NSAttributedString(string: node.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: color,
                .paragraphStyle: Typography.paragraph(.byTruncatingMiddle),
            ])
        }
        // "+12 −3", like a pull request: lines added and removed in this file or below this folder.
        let text = NSMutableAttributedString()
        if let lines, !isRoot {
            if lines.added > 0 { text.append(NSAttributedString(string: "+\(lines.added)", attributes: [.foregroundColor: Theme.linesAdded])) }
            if lines.removed > 0 {
                if text.length > 0 { text.append(NSAttributedString(string: " ")) }
                text.append(NSAttributedString(string: "−\(lines.removed)", attributes: [.foregroundColor: Theme.linesRemoved]))
            }
            if text.length == 0, node.isDirectory, lines.files > 0 {
                text.append(NSAttributedString(string: "\(lines.files) file\(lines.files == 1 ? "" : "s")", attributes: [.foregroundColor: Theme.textDim]))
            }
        }
        text.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: text.length))
        stats.attributedStringValue = Typography.truncating(text, .byClipping, alignment: .right)
        var tip = node.path
        if let change {
            let word = Self.word(for: change)
            tip += "\n" + word.prefix(1).uppercased() + word.dropFirst()
        }
        if let lines, lines.added + lines.removed > 0 {
            tip += "\n+\(lines.added) −\(lines.removed) lines" + (node.isDirectory ? " in \(lines.files) file\(lines.files == 1 ? "" : "s")" : "")
        }
        tipText = tip // shown by the sidebar, for visible rows only (see ProjectSidebarView.updateToolTips)
        setAccessibilityLabel([node.name, change.map(Self.word(for:)), stats.stringValue.isEmpty ? nil : stats.stringValue]
            .compactMap { $0 }.joined(separator: ", "))
    }

    func setIcon(_ image: NSImage) { icon.image = image }

    /// The row's tooltip: its path, git state and line counts.
    private(set) var tipText = ""

    /// What the counts column shows, for the self-test.
    var statsText: String { stats.stringValue }

    /// Lines the name needs at `width` (1 unless something makes it wrap), for the self-test.
    func nameLines(atWidth width: CGFloat) -> Int {
        guard let cell = name.cell, let font = name.font else { return 0 }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return Int((height / line).rounded())
    }

    func configureHidden(_ entries: HiddenEntries) {
        node = nil
        icon.image = nil
        stats.stringValue = ""
        let more = "\(entries.count.formatted()) more item\(entries.count == 1 ? "" : "s")"
        name.attributedStringValue = NSAttributedString(string: "… " + more, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: Theme.textDim,
            .paragraphStyle: Typography.paragraph(.byTruncatingTail),
        ])
        toolTip = "This folder is too large to list in full."
        // Cells are reused: replace the previous file's label, or VoiceOver reads it here.
        setAccessibilityLabel(more + " not shown")
    }

    static func word(for change: GitChange) -> String {
        switch change {
        case .modified: return "modified"
        case .added: return "added"
        case .renamed: return "renamed"
        case .deleted: return "has deleted files"
        case .untracked: return "untracked"
        case .conflicted: return "conflicted"
        case .ignored: return "ignored"
        }
    }

    // MARK: inline rename

    /// Makes the name editable and selects it without its extension, like Finder.
    func beginRename(delegate: NSTextFieldDelegate) {
        guard let node else { return }
        isRenaming = true
        name.isEditable = true
        name.isSelectable = true
        name.isBezeled = true
        name.lineBreakMode = .byClipping // edit the whole name, never a truncated one
        name.cell?.isScrollable = true   // the editor follows the caret past the edge
        renameWidth.isActive = true
        name.bezelStyle = .squareBezel
        name.drawsBackground = true
        name.backgroundColor = Theme.background
        name.textColor = Theme.text
        name.stringValue = node.name
        name.delegate = delegate
        window?.makeFirstResponder(name)
        let stem = node.isDirectory || node.name.hasPrefix(".") ? node.name : (node.name as NSString).deletingPathExtension
        name.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    func endRename() {
        isRenaming = false
        name.isEditable = false
        name.isSelectable = false
        name.isBezeled = false
        name.drawsBackground = false
        name.delegate = nil
        renameWidth.isActive = false
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
    }

    var renameText: String { name.stringValue }
}
