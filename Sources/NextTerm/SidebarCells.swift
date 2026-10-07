import AppKit
import NextTermCore

// MARK: - header: branch and changes at a glance

/// The sidebar's title row. With git: "⎇ main  +41 −10  [Pull 2]"; otherwise "Project".
final class SidebarHeaderView: NSView {
    private let branchIcon = NSImageView()
    private let title = NSTextField(labelWithString: "Project")
    /// The branch name is a button: it opens the branch popup (⌥⌘B).
    var onBranchClick: (() -> Void)?
    private let chevron = NSImageView()
    private var hoveringBranch = false { didSet { if hoveringBranch != oldValue { needsDisplay = true } } }
    private let summary = NSTextField(labelWithString: "")
    /// Commits to pull or push, as a button; a spinning sync arrow while a fetch, pull or push runs.
    let syncButton = SyncButton()
    /// The sync button was clicked: pull (true) or push (false).
    var onSync: ((_ pull: Bool) -> Void)?
    private var snapshot: GitSnapshot?
    private var activity: GitWriter.Activity?
    /// A background fetch runs in this work tree's repository.
    private var fetchingInBackground = false
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
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        chevron.contentTintColor = Theme.textDim
        chevron.isHidden = true
        syncButton.target = self
        syncButton.action = #selector(syncClicked)
        syncButton.isHidden = true
        [branchIcon, title, chevron, summary, syncButton, hideButton, moreButton].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Project")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Whether the branch name is cut short (for the self-test).
    var titleIsTruncated: Bool {
        layoutSubtreeIfNeeded()
        return title.cell?.expansionFrame(withFrame: title.bounds, in: title) != .zero
    }

    /// Whether the counts are cut short (for the self-test).
    var summaryIsTruncated: Bool {
        layoutSubtreeIfNeeded()
        return summary.cell?.expansionFrame(withFrame: summary.bounds, in: summary) != .zero
    }

    /// Whether the counts are shown at all (for the self-test).
    var summaryIsShown: Bool {
        layoutSubtreeIfNeeded()
        return !summary.isHidden
    }

    // The whole header is a drag handle for the window, except its ⋯ button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if moreButton.frame.contains(local) { return moreButton }
        if hideButton.frame.contains(local) { return hideButton }
        if !syncButton.isHidden, syncButton.frame.contains(local) { return syncButton }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        if let onBranchClick, branchArea.contains(convert(event.locationInWindow, from: nil)) { return onBranchClick() }
        window?.performDrag(with: event)
    }

    /// The branch's icon, name and chevron, with a little room around them.
    var branchArea: NSRect {
        guard !branchIcon.isHidden, onBranchClick != nil else { return .zero }
        return branchIcon.frame.union(title.frame).union(chevron.frame).insetBy(dx: -5, dy: -4)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !branchArea.isEmpty { addCursorRect(branchArea, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hoveringBranch = branchArea.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoveringBranch = false }

    func show(_ snapshot: GitSnapshot?) {
        self.snapshot = snapshot
        updateSyncButton()
        guard let snapshot else {
            branchIcon.isHidden = true
            chevron.isHidden = true
            title.stringValue = "Project"
            summary.attributedStringValue = NSAttributedString()
            toolTip = nil
            setAccessibilityLabel("Project")
            needsLayout = true
            return
        }
        branchIcon.isHidden = false
        chevron.isHidden = onBranchClick == nil
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
        summary.attributedStringValue = Typography.truncating(text, .byTruncatingTail, alignment: .right)
        toolTip = Self.describe(snapshot)
        setAccessibilityLabel(Self.describe(snapshot))
        needsLayout = true
    }

    /// A fetch, pull or push started or ended in this work tree, or a background fetch in its repository.
    func show(activity: GitWriter.Activity?, fetchingInBackground: Bool = false) {
        guard activity != self.activity || fetchingInBackground != self.fetchingInBackground else { return }
        self.activity = activity
        self.fetchingInBackground = fetchingInBackground
        updateSyncButton()
    }

    /// When the counts are from: the last fetch that worked in any work tree of the repository (its
    /// FETCH_HEAD), or Next Term's own last fetch (a background fetch leaves FETCH_HEAD alone), whichever
    /// is newer.
    private var lastFetch: Date? {
        let own = snapshot.flatMap { BackgroundFetcher.shared.lastFetch(at: $0.root) }
        return [snapshot?.lastFetch, own].compactMap { $0 }.max()
    }

    @objc private func syncClicked() {
        guard let snapshot, activity == nil else { return }
        onSync?(snapshot.behind > 0 || snapshot.ahead == 0)
    }

    /// "Pull 152" when the upstream has commits this branch doesn't, "Push 3" the other way, both counts
    /// when both; the commit glyph says they are commits. While git talks to the remote, a spinning sync
    /// arrow, and "Fetching…" if there is no count to show. A background fetch only spins a button that is
    /// there already: it never makes one appear every ten minutes.
    private func updateSyncButton() {
        let behind = snapshot?.behind ?? 0, ahead = snapshot?.ahead ?? 0
        let branch = snapshot?.branch ?? "this branch"
        let upstream = snapshot?.upstream ?? "the upstream"
        let full: String, compact: String, help: String, spoken: String
        if behind > 0, ahead > 0 {
            full = "↓\(behind) ↑\(ahead)"
            compact = full
            help = "\(branch) and \(upstream) have both changed: \(Self.commits(ahead)) here, \(Self.commits(behind)) there. Click to update; it asks whether to rebase or merge."
            spoken = "Update: \(Self.commits(behind)) to pull, \(Self.commits(ahead)) to push"
        } else if behind > 0 {
            full = "Pull \(behind)"
            compact = "↓\(behind)"
            help = "\(upstream) has \(Self.commits(behind)) that \(branch) doesn’t. Click to pull them."
            spoken = "Pull \(Self.commits(behind)) from \(upstream)"
        } else if ahead > 0 {
            full = "Push \(ahead)"
            compact = "↑\(ahead)"
            help = "\(branch) has \(Self.commits(ahead)) not on \(upstream) yet. Click to push them."
            spoken = "Push \(Self.commits(ahead)) to \(upstream)"
        } else {
            full = ""; compact = ""; help = ""; spoken = ""
        }
        var tip = help
        if let fetched = lastFetch, behind + ahead > 0 {
            tip += " Last fetched \(Self.relative.localizedString(for: fetched, relativeTo: Date()))."
        }
        if let activity {
            let doing = activity.rawValue + "…"
            syncButton.configure(full: full.isEmpty ? doing : full, compact: compact.isEmpty ? doing : compact,
                                 busy: true, toolTip: doing, accessibilityLabel: doing)
        } else if fetchingInBackground && !full.isEmpty {
            syncButton.configure(full: full, compact: compact, busy: true, toolTip: tip + " Fetching now…", accessibilityLabel: spoken)
        } else {
            syncButton.configure(full: full, compact: compact, busy: false, toolTip: tip, accessibilityLabel: spoken)
        }
        syncButton.isHidden = snapshot == nil || (activity == nil && full.isEmpty)
        needsLayout = true
    }

    private static func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n.formatted()) commits" }
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// What the sync button says (for the self-test): "" when it is hidden.
    var syncText: String { syncButton.isHidden ? "" : syncButton.shownTitle }

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
        moreButton.frame = NSRect(x: bounds.width - 30, y: (h - 24) / 2, width: 26, height: 24)
        hideButton.frame = NSRect(x: bounds.width - 56, y: (h - 24) / 2, width: 26, height: 24)
        // When room is short, the branch name keeps its own first, then the line counts give way (they are
        // in the tooltip, and on the tree's rows), and only then does the sync button lose its word ("↓152").
        let nameStart = inset + 4 + (branchIcon.isHidden ? 0 : 18)
        let chevronWidth: CGFloat = chevron.isHidden ? 0 : 12
        // The cell's own size, not the text's: it needs a few points of margin, or even "dev" truncates to "…".
        let nameNeeded = ceil(title.cell?.cellSize.width ?? title.intrinsicContentSize.width + 4) + 1
        let nameKept = nameStart + min(nameNeeded, 64) + chevronWidth + 6
        // The text cell needs about 4 pt of its own margin beyond the text, or it truncates.
        let summaryText = summary.attributedStringValue.length > 0 ? ceil(summary.intrinsicContentSize.width) + 6 : 0
        var right = bounds.width - 60
        if !syncButton.isHidden {
            let spare = right - nameStart - nameNeeded - chevronWidth - 6 - 4
            syncButton.compact = syncButton.width(compact: false) > spare
            let width = syncButton.width(compact: syncButton.compact)
            syncButton.frame = NSRect(x: right - width, y: (h - SyncButton.height) / 2, width: width, height: SyncButton.height)
            right = syncButton.frame.minX - 4
        }
        var summaryWidth = min(summaryText, max(0, right - nameKept))
        if summaryWidth < 28 { summaryWidth = 0 } // an ellipsis alone says nothing
        if !syncButton.isHidden && syncButton.isShortened { summaryWidth = 0 } // the counts went before the word did
        summary.isHidden = summaryWidth == 0
        summary.frame = NSRect(x: right - summaryWidth, y: summaryY, width: summaryWidth, height: summaryHeight)
        var x = inset + 4
        if !branchIcon.isHidden {
            branchIcon.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
            x += 18
        }
        // The name as wide as it is (the chevron right after it), up to the counts or the button.
        let room = max(0, (summary.isHidden ? right : summary.frame.minX) - x - 6 - chevronWidth)
        title.frame = NSRect(x: x, y: titleY, width: min(room, nameNeeded), height: titleHeight)
        chevron.frame = NSRect(x: title.frame.maxX + 2, y: (h - 10) / 2, width: 10, height: 10)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if hoveringBranch {
            Theme.tabHover.setFill()
            NSBezierPath(roundedRect: branchArea, xRadius: 5, yRadius: 5).fill()
        }
    }
}

/// The header's "Pull 152": a capsule with git's commit glyph (a dot on a line) and the count. While a
/// fetch, pull or push runs, the glyph turns into a sync arrow that spins (still, with Reduce Motion).
final class SyncButton: NSButton {
    static let height: CGFloat = 20
    private var full = "", short = ""
    private(set) var busy = false
    /// The arrow and count only, when the sidebar is narrow.
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var angle: CGFloat = 0
    private var spinner: Timer?
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(full: String, compact: String, busy: Bool, toolTip: String, accessibilityLabel: String) {
        self.full = full
        short = compact
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityLabel)
        if busy != self.busy {
            self.busy = busy
            angle = 0
            updateSpinner()
        }
        needsDisplay = true
    }

    var shownTitle: String { compact ? short : full }
    /// It shows "↓152" for "Pull 152": its word is gone.
    var isShortened: Bool { compact && short != full }

    private func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                                                      .foregroundColor: Theme.accent])
    }

    func width(compact: Bool) -> CGFloat { (8 + 12 + 5 + label(compact ? short : full).size().width + 9).rounded(.up) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinner()
    }

    private func updateSpinner() {
        spinner?.invalidate()
        spinner = nil
        guard busy, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.angle -= .pi / 15 // a turn a second
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        spinner = timer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { if !busy { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: 0, y: ((bounds.height - Self.height) / 2).rounded(), width: bounds.width, height: Self.height)
        let strength: CGFloat = isHighlighted ? 0.32 : (hovering && !busy ? 0.24 : 0.14)
        Theme.accent.withAlphaComponent(strength).setFill()
        NSBezierPath(roundedRect: pill, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        let icon = NSRect(x: 8, y: pill.midY - 6, width: 12, height: 12)
        if busy { drawSync(in: icon) } else { drawCommit(in: icon) }
        let text = label(shownTitle)
        let size = text.size()
        text.draw(at: NSPoint(x: icon.maxX + 5, y: pill.midY - size.height / 2))
    }

    /// git's commit glyph: a ring on a line.
    private func drawCommit(in rect: NSRect) {
        let radius: CGFloat = 3.2
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.midX - radius, y: rect.midY))
        path.move(to: NSPoint(x: rect.midX + radius, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.appendOval(in: NSRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        Theme.accent.setStroke()
        path.stroke()
    }

    private func drawSync(in rect: NSRect) {
        guard let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Theme.accent]))) else { return }
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: rect.midX, yBy: rect.midY)
        turn.rotate(byRadians: isFlipped ? -angle : angle)
        turn.concat()
        let size = image.size
        image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - remote tab: whose files these are

/// Under the header while the active tab runs on a server: the tree stays on this Mac's files (a remote
/// tab's folder is on its host), so it says so, with the tab's server mark on the other side.
final class RemoteFilesNote: NSView {
    static let height: CGFloat = 28
    private let local = NSImageView()
    private let localText = NSTextField(labelWithString: "Files on this Mac")
    private let mark = RemoteMarkView()
    private let host = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        local.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        local.contentTintColor = Theme.textDim
        localText.font = .systemFont(ofSize: 11.5)
        localText.textColor = Theme.textDim
        Typography.singleLine(localText, truncation: .byTruncatingTail)
        host.font = .systemFont(ofSize: 11.5, weight: .medium)
        host.textColor = Theme.text
        host.alignment = .right
        Typography.singleLine(host, truncation: .byTruncatingMiddle) // host names keep both ends
        mark.tint = Theme.text
        [local, localText, mark, host].forEach(addSubview)
        // One line for VoiceOver, in its own words (show()), not its parts read again after it. A control's
        // cell is what VoiceOver reads, so the cell opts out: the view saying so leaves the cell listed.
        [local, localText, host].forEach { $0.cell?.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private(set) var shown: RemoteMark?

    func show(_ remote: RemoteMark) {
        guard remote != shown else { return }
        shown = remote
        host.stringValue = remote.host
        mark.link = remote.link
        let words = "The files below are on this Mac. The active tab runs on \(remote.place), \(remote.link.phrase)."
        toolTip = words
        setAccessibilityLabel(words)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height - 1
        let textHeight = localText.intrinsicContentSize.height
        let textY = (h - textHeight) / 2
        local.frame = NSRect(x: 12, y: (h - 16) / 2, width: 18, height: 16)
        // The host as wide as it is, up to half the row; "Files on this Mac" gives way first.
        let hostWidth = min(ceil(host.cell?.cellSize.width ?? 0) + 1, bounds.width * 0.5)
        host.frame = NSRect(x: bounds.width - 12 - hostWidth, y: textY, width: hostWidth, height: textHeight)
        mark.frame = NSRect(x: host.frame.minX - 4 - RemoteMarkView.size.width, y: (h - RemoteMarkView.size.height) / 2,
                            width: RemoteMarkView.size.width, height: RemoteMarkView.size.height)
        let room = max(0, mark.frame.minX - 8 - local.frame.maxX - 5)
        // A narrow sidebar keeps the words that matter, "This Mac", rather than "Files on th…".
        let full = "Files on this Mac"
        let fits = (full as NSString).size(withAttributes: [.font: localText.font as Any]).width + 4 <= room
        if localText.stringValue != (fits ? full : "This Mac") { localText.stringValue = fits ? full : "This Mac" }
        localText.frame = NSRect(x: local.frame.maxX + 5, y: textY, width: room, height: textHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.tabHover.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - a row in the tree

/// "… 12,345 more items" under a folder that is too big to list in full.
final class HiddenEntries {
    let count: Int
    init(count: Int) { self.count = count }
}

/// A file or folder git still has but the disk no longer does (deleted, not yet committed). Shown struck
/// through where it was, so a folder's −N always has a row that explains it.
final class DeletedEntry {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// From the work tree's root.
    let relative: String
    /// The nearest folder above it that is still on disk.
    weak var realFolder: FileNode?

    init(url: URL, relative: String, isDirectory: Bool, realFolder: FileNode?) {
        self.url = url
        self.relative = relative
        self.isDirectory = isDirectory
        self.realFolder = realFolder
        name = url.lastPathComponent
    }
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
        showStats(isRoot ? nil : lines, isDirectory: node.isDirectory)
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

    /// "+12 −3", like a pull request: lines added and removed in this file or below this folder.
    private func showStats(_ lines: LineStats?, isDirectory: Bool) {
        let text = NSMutableAttributedString()
        if let lines {
            if lines.added > 0 { text.append(NSAttributedString(string: "+\(lines.added)", attributes: [.foregroundColor: Theme.linesAdded])) }
            if lines.removed > 0 {
                if text.length > 0 { text.append(NSAttributedString(string: " ")) }
                text.append(NSAttributedString(string: "−\(lines.removed)", attributes: [.foregroundColor: Theme.linesRemoved]))
            }
            if text.length == 0, isDirectory, lines.files > 0 {
                text.append(NSAttributedString(string: "\(lines.files) file\(lines.files == 1 ? "" : "s")", attributes: [.foregroundColor: Theme.textDim]))
            }
        }
        text.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: text.length))
        stats.attributedStringValue = Typography.truncating(text, .byClipping, alignment: .right)
    }

    /// A deleted file or folder: its name struck through in red, its removed lines, a quiet icon.
    func configureDeleted(_ entry: DeletedEntry, expanded: Bool, lines: LineStats?) {
        node = nil
        guard !isRenaming else { return }
        icon.image = FileIcons.image(forDeleted: entry.name, parent: entry.url.deletingLastPathComponent().lastPathComponent,
                                     isDirectory: entry.isDirectory, expanded: expanded)
        icon.alphaValue = 0.45
        name.attributedStringValue = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.linesRemoved,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: Typography.paragraph(.byTruncatingMiddle),
        ])
        showStats(lines, isDirectory: entry.isDirectory)
        var tip = entry.url.path + "\nDeleted, not yet committed"
        if let lines, lines.removed > 0 {
            tip += "\n−\(lines.removed) lines" + (entry.isDirectory ? " in \(lines.files) file\(lines.files == 1 ? "" : "s")" : "")
        }
        if !entry.isDirectory { tip += "\nDouble-click to see what was removed." }
        tipText = tip
        setAccessibilityLabel([entry.name, "deleted", stats.stringValue.isEmpty ? nil : stats.stringValue].compactMap { $0 }.joined(separator: ", "))
    }

    /// Whether the row shows a deleted file, for the self-test.
    var isDeletedRow: Bool {
        let text = name.attributedStringValue
        return text.length > 0 && text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
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
