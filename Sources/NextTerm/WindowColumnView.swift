import AppKit
import NextTermCore

/// The window column: a strip at the window's outer edge listing every open Next Term window, folded to a badge apiece
/// (its project's colour, two letters, a dot when an agent there waits) or unfolded to a row apiece (its name, colour and
/// marks, as ⌘O shows them). A click brings that window forward. On top, a chevron that folds or unfolds it in every
/// window, and the count of windows; under the traffic lights, a strip of title bar.
///
/// It does only what a change asks (WindowColumnList.Change): a window opening or closing matches its buttons by id and
/// lays it out once; one window's marks reconfigure that window's button alone, which draws only when what it shows
/// changed. Idle, it lays out and draws nothing. Badges and rows are plain buttons with frames set by hand, placed as the
/// rail and the folded tab list place their marks (MarkColumn); windows that do not fit become a "+N" that opens ⌘O.
final class WindowColumnView: NSView, ProjectGlowing {
    /// Its places, folded and unfolded: a badge in each, or a row.
    static let slot: CGFloat = 28
    private static let margin: CGFloat = 4
    private static let header: CGFloat = TabBarView.height

    /// At the window's right edge: the hairline goes on its left, the window's side, and the chevron points the other way.
    var onRight = false {
        didSet {
            guard onRight != oldValue else { return }
            updateChevron()
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Folded at the window's top-left outside full screen: a strip of title bar for the traffic lights over the chevron.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Unfolded, where the header's words start: after the traffic lights at the window's top-left.
    var headerLeading: CGFloat = 8 {
        didSet { if headerLeading != oldValue { needsDisplay = true } }
    }

    /// A badge or row was clicked: its window's id.
    var onSelect: ((Int) -> Void)?
    /// The chevron: fold or unfold the column in every window.
    var onToggle: (() -> Void)?
    /// The "+N" for the windows there is no room for: ⌘O, which lists every one.
    var onMore: (() -> Void)?
    /// A right-click on the top row: the window's Project Color menu.
    var onTopRowMenu: (() -> NSMenu?)?
    /// The top row's slice of the project colour, as the tab bars beside it have.
    private(set) lazy var projectGlow = ProjectGlow(self)

    private(set) var list = WindowColumnList()
    /// This column's own window: its badge is outlined, its row highlighted.
    private(set) var current = 0
    /// Unfolded as it shows: the user's choice, unless the window's room folded it.
    private(set) var expanded = false
    private(set) var buttons: [WindowColumnButton] = []
    private let chevron = HoverButton()
    private let moreButton = HoverButton()
    private var chevronTip: ShortcutToolTip?
    /// How many buttons fit, as last laid out.
    private var shownCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.isBordered = false
        chevron.bezelStyle = .regularSquare
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = Theme.textDim
        chevron.refusesFirstResponder = true
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        addSubview(chevron)
        moreButton.isBordered = false
        moreButton.bezelStyle = .regularSquare
        moreButton.refusesFirstResponder = true
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.isHidden = true
        addSubview(moreButton)
        updateChevron()
        // A group, not a button: VoiceOver goes into it, to each window's button.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.groupLabel(0))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Its frame is set by hand (WindowColumnHost): a new size lays it out again, as a window resize or a new form does.
    override func setFrameSize(_ newSize: NSSize) {
        let resized: Bool = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsLayout = true }
    }

    /// "Windows, 5 open".
    static func groupLabel(_ count: Int) -> String { "Windows, \(count) open" }

    // MARK: update

    /// The rows as the hub has them now, and what changed: only that is touched. `current`: this window's id.
    /// `expanded`: the form it shows in.
    func update(list newList: WindowColumnList, change: WindowColumnList.Change, current newCurrent: Int, expanded newExpanded: Bool) {
        let formChanged: Bool = newExpanded != expanded
        let currentChanged: Bool = newCurrent != current
        let countChanged: Bool = newList.count != list.count
        list = newList
        current = newCurrent
        expanded = newExpanded
        switch change {
        case .none:
            break
        case .rows(let ids):
            if !formChanged && !currentChanged {
                for id in ids {
                    guard let button = buttons.first(where: { $0.id == id }), let row = newList.row(id) else { continue }
                    button.configure(row, current: id == current, expanded: expanded)
                }
            }
        case .structure:
            match(newList.rows)
            needsLayout = true
        }
        if formChanged || currentChanged || change == .structure {
            for (button, row) in zip(buttons, newList.rows) { button.configure(row, current: row.id == current, expanded: expanded) }
        }
        if formChanged {
            updateChevron()
            needsLayout = true
            needsDisplay = true
        }
        if countChanged {
            needsDisplay = true // the header's count
            setAccessibilityLabel(Self.groupLabel(newList.count))
        }
        if change != .none || formChanged { updateMore() }
    }

    /// One button per row, kept for each window still there (with its hover), a new one for each new window, and the
    /// buttons of windows gone removed.
    private func match(_ rows: [WindowColumnRow]) {
        var kept: [Int: WindowColumnButton] = [:]
        for button in buttons { kept[button.id] = button }
        var matched: [WindowColumnButton] = []
        matched.reserveCapacity(rows.count)
        for row in rows {
            if let button = kept.removeValue(forKey: row.id) {
                matched.append(button)
                continue
            }
            let button = WindowColumnButton(id: row.id)
            button.target = self
            button.action = #selector(buttonClicked(_:))
            addSubview(button, positioned: .below, relativeTo: moreButton)
            matched.append(button)
        }
        for gone in kept.values { gone.removeFromSuperview() }
        buttons = matched
    }

    // MARK: layout

    /// Where the strip starts across: after the hairline, which is on the window's side.
    private var stripX: CGFloat { onRight ? WindowColumnWidth.hairline : 0 }
    private var stripWidth: CGFloat { max(0, bounds.width - WindowColumnWidth.hairline) }
    /// The header's top: under the title bar's strip folded at the top-left, else the column's top.
    private var headerTop: CGFloat { expanded ? 0 : topInset }

    override func layout() {
        super.layout()
        #if DEBUG
        layoutCount += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x: CGFloat = stripX, width: CGFloat = stripWidth
        let chevronFrame: NSRect
        if expanded {
            chevronFrame = NSRect(x: onRight ? x : x + width - Self.slot, y: 0, width: Self.slot, height: Self.header)
        } else {
            chevronFrame = NSRect(x: x, y: headerTop + 3, width: width, height: 20)
        }
        if chevron.frame != chevronFrame { chevron.frame = chevronFrame }
        let column = MarkColumn(count: buttons.count, height: bounds.height, top: headerTop + Self.header, slot: Self.slot, margin: Self.margin)
        shownCount = column.shownCount
        for (index, button) in buttons.enumerated() {
            let shows: Bool = index < column.shownCount
            if button.isHidden == shows { button.isHidden = !shows }
            guard shows else { continue }
            let place: CGRect = column.place(index)
            let frame = NSRect(x: x, y: place.minY, width: width, height: place.height)
            if button.frame != frame { button.frame = frame }
        }
        if let more = column.more {
            moreButton.isHidden = false
            let frame = NSRect(x: x, y: more.minY, width: expanded ? width : Self.slot, height: more.height)
            if moreButton.frame != frame { moreButton.frame = frame }
        } else {
            moreButton.isHidden = true
        }
        CATransaction.commit()
        updateMore()
    }

    /// The "+N": how many windows do not fit, in the colour of the most urgent mark among them; its tooltip names them.
    private func updateMore() {
        guard !moreButton.isHidden else { return }
        let hidden: [WindowColumnRow] = Array(list.rows.dropFirst(shownCount))
        guard !hidden.isEmpty else { return }
        let state: TabState = MarkColumn.moreState(hidden.map { $0.urgent ?? .idle })
        let color: NSColor = state == .idle || state == .working ? Theme.textDim : StatusGlyph.color(for: state)
        let title = NSAttributedString(string: "+\(hidden.count)", attributes: [
            .foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        ])
        if moreButton.attributedTitle != title { moreButton.attributedTitle = title }
        let tip = "\(hidden.count) more window\(hidden.count == 1 ? "" : "s"): " + hidden.map(\.label).joined(separator: "; ")
        if moreButton.toolTip != tip { moreButton.toolTip = tip } // re-setting a tooltip resets it
        moreButton.setAccessibilityLabel(tip)
    }

    /// Folded, the chevron points into the window, the way the column opens; unfolded, the way it folds.
    private func updateChevron() {
        let inward: Bool = !expanded
        let pointsRight: Bool = onRight ? !inward : inward
        let symbol: String = pointsRight ? "chevron.right" : "chevron.left"
        let words: String = expanded ? "Collapse Window Column" : "Expand Window Column"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: words)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.setAccessibilityLabel(words)
        let tip: String = expanded ? "Collapse the window column" : "Expand the window column"
        chevronTip = ShortcutToolTip(chevron, tip, #selector(AppDelegate.toggleWindowColumnExpanded(_:)))
        chevronPointsRight = pointsRight
    }

    /// For the self-test: which way the chevron points.
    private(set) var chevronPointsRight = true

    /// The hairline down its inner edge. Folded under the traffic lights, from the strip's bottom line down: the strip and
    /// the bar beside it read as one title bar, with no line between the lights.
    var hairlineRect: NSRect {
        let top: CGFloat = topInset > 0 ? Self.header - 1 : 0
        return NSRect(x: onRight ? 0 : bounds.width - WindowColumnWidth.hairline, y: top, width: WindowColumnWidth.hairline,
                      height: max(0, bounds.height - top))
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        drawCount += 1
        #endif
        Theme.bar.setFill()
        bounds.fill()
        projectGlow.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: Self.header - 1))
        // The tab bars' bottom line runs on across the top row, and the hairline down the window's side.
        Theme.border.setFill()
        NSRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
        hairlineRect.fill()
        let count = "\(list.count)"
        let digits: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textDim, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        ]
        if expanded {
            let words: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.textDim, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
            let title = NSAttributedString(string: "Windows", attributes: words)
            let number = NSAttributedString(string: count, attributes: digits)
            let leading: CGFloat = onRight ? stripX + Self.slot + 4 : headerLeading
            let titleSize: NSSize = title.size()
            title.draw(at: NSPoint(x: leading, y: ((Self.header - titleSize.height) / 2).rounded()))
            let numberSize: NSSize = number.size()
            number.draw(at: NSPoint(x: leading + titleSize.width + 6, y: ((Self.header - numberSize.height) / 2).rounded()))
        } else {
            let number = NSAttributedString(string: count, attributes: digits)
            let size: NSSize = number.size()
            number.draw(at: NSPoint(x: stripX + ((stripWidth - size.width) / 2).rounded(), y: headerTop + 22))
        }
    }

    // MARK: mouse

    /// The top row is title bar: it moves the window, as the tab bars beside it do.
    func isTitleBar(_ point: NSPoint) -> Bool { point.y < Self.header }

    override func mouseDown(with event: NSEvent) {
        if isTitleBar(convert(event.locationInWindow, from: nil)) { return TabBarView.titleBarMouseDown(event, in: window) }
    }

    /// The top row: the window's Project Color menu. Below it: Hide Window Column and Collapse (or Expand) Window Column.
    override func menu(for event: NSEvent) -> NSMenu? {
        if isTitleBar(convert(event.locationInWindow, from: nil)) { return onTopRowMenu?() }
        return Self.columnMenu()
    }

    /// The View menu's two items for the column, their titles set as the menu opens (AppDelegate.validateMenuItem).
    static func columnMenu() -> NSMenu {
        let menu = NSMenu()
        let hide = menu.addItem(withTitle: "Hide Window Column", action: #selector(AppDelegate.toggleWindowColumn(_:)), keyEquivalent: "")
        hide.target = AppDelegate.shared
        let fold = menu.addItem(withTitle: "Collapse Window Column", action: #selector(AppDelegate.toggleWindowColumnExpanded(_:)),
                                keyEquivalent: "")
        fold.target = AppDelegate.shared
        return menu
    }

    @objc private func chevronClicked() { onToggle?() }
    @objc private func moreClicked() { onMore?() }

    @objc private func buttonClicked(_ sender: WindowColumnButton) {
        // The window's own badge: it is in front already, and nothing more happens.
        guard sender.id != current else { return }
        onSelect?(sender.id)
    }

    // MARK: VoiceOver

    override func accessibilityChildren() -> [Any]? {
        var views: [NSView] = [chevron]
        views += buttons.filter { !$0.isHidden } as [NSView]
        if !moreButton.isHidden { views.append(moreButton) }
        // A button view is not what VoiceOver reads (its cell is): the unignored ones stand in for them.
        return NSAccessibility.unignoredChildren(from: views)
    }

    // MARK: the self-test

    var chevronButton: NSButton { chevron }
    var overflowButton: NSButton { moreButton }
    var shownButtons: [WindowColumnButton] { buttons.filter { !$0.isHidden } }
    func button(for id: Int) -> WindowColumnButton? { buttons.first { $0.id == id } }

    #if DEBUG
    private(set) var layoutCount = 0
    private(set) var drawCount = 0

    func resetCounters() {
        layoutCount = 0
        drawCount = 0
        buttons.forEach { $0.resetCounters() }
    }
    #endif
}

/// One window in the column: folded, its badge (its colour, two letters, the dot of its most urgent mark, a ring when it
/// is this window); unfolded, its row (the badge, its name, and its marks with counts). It draws itself, and only when
/// what its form shows changed: a tooltip or a VoiceOver label is set without a draw.
final class WindowColumnButton: NSButton {
    let id: Int
    private(set) var row: WindowColumnRow?
    private(set) var isCurrent = false
    private(set) var expanded = false
    /// The badge's dot, at its top-right corner.
    private let dot = StatusDotView()
    /// Unfolded, the marks with counts, as ⌘O's rows show them.
    private let marks = SwitcherMarksView()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    private static let badge: CGFloat = WindowColumnWidth.badge
    /// A nested worktree's row is this much further in.
    private static let indent: CGFloat = 14
    private static let dotSize: CGFloat = 8

    init(id: Int) {
        self.id = id
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        wantsLayer = true
        dot.pulsesForAttention = false // a mark that stays still: the tab itself pulses
        dot.isHidden = true
        dot.setAccessibilityElement(false)
        addSubview(dot)
        marks.isHidden = true
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The badge's place: in the middle of the folded slot, and where it is in an unfolded row, further in for a nested
    /// worktree.
    private var badgeRect: NSRect {
        let y: CGFloat = ((bounds.height - Self.badge) / 2).rounded()
        guard expanded else { return NSRect(x: ((bounds.width - Self.badge) / 2).rounded(), y: y, width: Self.badge, height: Self.badge) }
        let depth: CGFloat = CGFloat(row?.depth ?? 0)
        return NSRect(x: 3 + depth * Self.indent, y: y, width: Self.badge, height: Self.badge)
    }

    /// `row` as it is now: drawn again only if what this form shows of it changed.
    func configure(_ newRow: WindowColumnRow, current: Bool, expanded newExpanded: Bool) {
        #if DEBUG
        configureCount += 1
        #endif
        let old: WindowColumnRow? = row
        let redraw: Bool = old.map { Self.drawsDifferently($0, newRow, expanded: newExpanded) } ?? true
            || current != isCurrent || newExpanded != expanded
        row = newRow
        isCurrent = current
        expanded = newExpanded
        if redraw {
            dot.state = newRow.urgent ?? .idle
            place()
            needsDisplay = true
        }
        if expanded {
            marks.show(newRow.marks, color: Theme.textDim)
            placeMarks()
        } else if !marks.isHidden {
            marks.isHidden = true
        }
        if old?.words != newRow.words || old == nil {
            if toolTip != newRow.toolTip { toolTip = newRow.toolTip } // re-setting a tooltip resets it
            setAccessibilityLabel(newRow.label)
        }
        if isAccessibilitySelected() != current { setAccessibilitySelected(current) }
    }

    /// What each form draws of its row: folded, the badge (letters, colour, dot); unfolded, the badge and the name, at its
    /// depth, up to the marks. The marks are a view of their own, but the room the name has ends where they start, so a
    /// change of them draws the row again.
    private static func drawsDifferently(_ old: WindowColumnRow, _ new: WindowColumnRow, expanded: Bool) -> Bool {
        if old.letters != new.letters || old.color != new.color { return true }
        if expanded { return old.name != new.name || old.depth != new.depth || old.marks != new.marks }
        return old.urgent != new.urgent
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
        placeMarks()
    }

    /// The dot at the badge's top-right corner, folded only: unfolded, the marks say it with counts.
    private func place() {
        let shows: Bool = !expanded && row?.urgent != nil
        if dot.isHidden == shows { dot.isHidden = !shows }
        guard shows else { return }
        let badge: NSRect = badgeRect
        let frame = NSRect(x: badge.maxX - Self.dotSize + 2, y: badge.minY - 2, width: Self.dotSize, height: Self.dotSize)
        if dot.frame != frame { dot.frame = frame }
    }

    /// Unfolded, the marks at the row's end, before its edge.
    private func placeMarks() {
        guard expanded else { return }
        let shows: Bool = !(row?.marks.isEmpty ?? true)
        if marks.isHidden == shows { marks.isHidden = !shows }
        guard shows else { return }
        let size: NSSize = marks.fittingSize
        let frame = NSRect(x: bounds.width - 8 - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        if marks.frame != frame { marks.frame = frame }
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        drawCount += 1
        #endif
        guard let row else { return }
        if expanded {
            let place = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5)
            if isCurrent {
                Theme.background.setFill()
                place.fill()
            }
            if hovering || isHighlighted {
                NSColor.white.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
                place.fill()
            }
        }
        let badge: NSRect = badgeRect
        let tile = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
        let fill: NSColor = NSColor(hex: row.color?.badge ?? ProjectColor.neutralBadge)
        fill.setFill()
        tile.fill()
        if !expanded && (hovering || isHighlighted) {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.1).setFill()
            tile.fill()
        }
        if !expanded && isCurrent {
            Theme.text.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(roundedRect: badge.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let letters = NSAttributedString(string: row.letters, attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        ])
        let size: NSSize = letters.size()
        letters.draw(at: NSPoint(x: badge.minX + ((badge.width - size.width) / 2).rounded(), y: badge.minY + ((badge.height - size.height) / 2).rounded()))
        if !expanded, row.urgent != nil {
            // The dot sits in a cut of the bar's colour, so it reads against any badge.
            Theme.bar.setFill()
            let frame: NSRect = dot.frame.insetBy(dx: -1.5, dy: -1.5)
            NSBezierPath(ovalIn: frame).fill()
        }
        guard expanded else { return }
        // Cut in the middle: a window with no project is named by its folder's path, whose end is the folder.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let name = NSAttributedString(string: row.name, attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph,
        ])
        let start: CGFloat = badge.maxX + 7
        let end: CGFloat = marks.isHidden ? bounds.width - 8 : marks.frame.minX - 6
        let height: CGFloat = ceil(name.size().height)
        name.draw(with: NSRect(x: start, y: ((bounds.height - height) / 2).rounded(), width: max(0, end - start), height: height),
                  options: [.usesLineFragmentOrigin])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    /// Clicks anywhere on the badge or row are the button's, the dot and the marks included.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    // VoiceOver reads the button itself: its window's title and marks, selected for this window.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityChildren() -> [Any]? { nil }
    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    #if DEBUG
    private(set) var drawCount = 0
    private(set) var configureCount = 0

    func resetCounters() {
        drawCount = 0
        configureCount = 0
    }
    #endif
}
