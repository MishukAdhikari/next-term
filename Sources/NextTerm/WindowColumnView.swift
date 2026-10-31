import AppKit
import NextTermCore

/// The window column: a strip at the window's outer edge listing every open Next Term window, folded to its rail (the
/// count, then a dot apiece in its project's colour, a mark only where a window needs you or failed) or unfolded to a row
/// apiece (its name, colour and marks, as ⌘O shows them), with "Hide window column ⌃⇧⌘S" at its foot. A click brings
/// that window forward; a double-click on its empty space pins it unfolded or folds it back, in every window. Unfolded, a
/// chevron at its top folds it. Under the traffic lights, a strip of title bar. The same view unfolded is the list that
/// slides out over the content while the pointer rests on the rail (WindowColumnHost).
///
/// It does only what a change asks (WindowColumnList.Change): a window opening or closing matches its buttons by id and
/// lays it out once; one window's marks reconfigure that window's button alone, which draws only when what it shows
/// changed. Idle, it lays out and draws nothing. Badges and rows are plain buttons with frames set by hand, placed as the
/// rail and the folded tab list place their marks (MarkColumn); windows that do not fit become a "+N" that opens ⌘O.
final class WindowColumnView: NSView, ProjectGlowing {
    /// An unfolded row's place; the rail's is WindowColumnRail.slot.
    static let slot: CGFloat = 28
    private static let margin: CGFloat = 4
    private static let header: CGFloat = TabBarView.height
    /// The rail's count, under the title bar's strip when that is there.
    private static let countRow: CGFloat = 22
    /// Unfolded, the foot's row: how to hide the column.
    static let footRow: CGFloat = 26

    /// At the window's right edge: the hairline goes on its left, the window's side, and the chevron points the other way.
    var onRight = false {
        didSet {
            guard onRight != oldValue else { return }
            updateChevron()
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Folded at the window's top-left outside full screen: a strip of title bar for the traffic lights over the count.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            updateTrackingAreas()
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
    /// The pointer came onto the column (true) or left it (false): the rail's hover list follows it.
    var onPointer: ((Bool) -> Void)?
    /// It took new rows, a new form or a new window of its own: the hover list shows them too.
    var onUpdated: (() -> Void)?
    /// The list that slides out over the content from the rail (WindowColumnHost): no chevron, since it neither folds nor
    /// pins by one; a double-click on it pins the column, and leaving it closes it.
    var hovers = false {
        didSet { if hovers != oldValue { needsLayout = true } }
    }
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
    /// Unfolded, at its foot: "Hide window column ⌃⇧⌘S", with the key as the user has it.
    private let footButton = HoverButton()
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
        footButton.isBordered = false
        footButton.bezelStyle = .regularSquare
        footButton.refusesFirstResponder = true
        footButton.alignment = .left
        footButton.target = AppDelegate.shared
        footButton.action = #selector(AppDelegate.toggleWindowColumn(_:))
        footButton.isHidden = true
        addSubview(footButton)
        // The foot's key as the user sets it, as the menus' and the tooltips' follow it.
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: KeyboardShortcuts.changed, object: nil)
        updateChevron()
        // A group, not a button: VoiceOver goes into it, to each window's button.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.groupLabel(0))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // Its frame is set by hand (WindowColumnHost): a new size lays it out again, as a window resize or a new form does
    // (setFrameSize, below with its tracking).

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
        onUpdated?()
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
    /// Folded, where the count goes: under the title bar's strip at the top-left, else in the top row with the tab bars.
    private var countRect: NSRect {
        topInset > 0 ? NSRect(x: stripX, y: topInset, width: stripWidth, height: Self.countRow)
            : NSRect(x: stripX, y: 0, width: stripWidth, height: Self.header)
    }
    /// Where the windows' places start: under the count folded, under the header unfolded.
    private var placesTop: CGFloat { expanded ? Self.header : countRect.maxY }

    override func layout() {
        super.layout()
        #if DEBUG
        layoutCount += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x: CGFloat = stripX, width: CGFloat = stripWidth
        // Folded to the rail, no chevron: resting the pointer on it, a double-click or ⌃⌘S unfolds it. Nor on the hovering
        // list, which neither folds nor pins by one.
        let showsChevron: Bool = expanded && !hovers
        if chevron.isHidden == showsChevron { chevron.isHidden = !showsChevron }
        let chevronFrame = NSRect(x: onRight ? x : x + width - Self.slot, y: 0, width: Self.slot, height: Self.header)
        if showsChevron, chevron.frame != chevronFrame { chevron.frame = chevronFrame }
        if footButton.isHidden == expanded { footButton.isHidden = !expanded }
        let foot: CGFloat = expanded ? Self.footRow : 0
        if expanded {
            let frame = NSRect(x: x, y: bounds.height - Self.footRow, width: width, height: Self.footRow)
            if footButton.frame != frame { footButton.frame = frame }
            updateFoot()
        }
        let slot: CGFloat = expanded ? Self.slot : WindowColumnRail.slot
        let column = MarkColumn(count: buttons.count, height: bounds.height - foot, top: placesTop, slot: slot, margin: Self.margin)
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
            let frame = NSRect(x: x, y: more.minY, width: width, height: more.height)
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
        let title = NSAttributedString(string: "+\(hidden.count)", attributes: [
            .foregroundColor: StatusGlyph.moreColor(for: state), .font: Theme.countFont,
        ])
        if moreButton.attributedTitle != title { moreButton.attributedTitle = title }
        let tip = "\(hidden.count) more window\(hidden.count == 1 ? "" : "s"): " + hidden.map(\.label).joined(separator: "; ")
        if moreButton.toolTip != tip { moreButton.toolTip = tip } // re-setting a tooltip resets it
        moreButton.setAccessibilityLabel(tip)
    }

    /// "Hide window column ⌃⇧⌘S", the key as the user has it now (without one, the words alone).
    private func updateFoot() {
        let key: String = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display ?? ""
        let words: String = "Hide window column" + (key.isEmpty ? "" : "  " + key)
        guard footButton.title != words else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 10
        paragraph.headIndent = 10
        footButton.attributedTitle = NSAttributedString(string: words, attributes: [
            .foregroundColor: Theme.textDim, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: paragraph,
        ])
        footButton.setAccessibilityLabel(key.isEmpty ? "Hide Window Column" : "Hide Window Column, \(key)")
    }

    /// Folded, the chevron points into the window, the way the column opens; unfolded, the way it folds.
    private func updateChevron() {
        let inward: Bool = !expanded
        let pointsRight: Bool = onRight ? !inward : inward
        let symbol: String = pointsRight ? "chevron.right" : "chevron.left"
        let words: String = expanded ? "Collapse Window Column" : "Expand Window Column"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: words)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
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
        if expanded {
            // As ⌘O heads its windows: small capitals set apart, and the count in figures that never shift.
            let title: NSAttributedString = WelcomeWindowController.headingText("Windows")
            let number = NSAttributedString(string: count, attributes: [
                .foregroundColor: Theme.textDim, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            ])
            let leading: CGFloat = onRight ? stripX + Self.slot + 4 : headerLeading
            let titleSize: NSSize = title.size()
            title.draw(at: NSPoint(x: leading, y: ((Self.header - titleSize.height) / 2).rounded()))
            let numberSize: NSSize = number.size()
            number.draw(at: NSPoint(x: leading + titleSize.width + 6, y: ((Self.header - numberSize.height) / 2).rounded()))
            // The foot's hairline, apart from the rows above it.
            Theme.border.setFill()
            NSRect(x: stripX, y: bounds.height - Self.footRow, width: stripWidth, height: 1).fill()
        } else {
            // The rail: the count in its own row, clear of the traffic lights, the dots below it.
            let number = NSAttributedString(string: count, attributes: [.foregroundColor: Theme.textDim, .font: Theme.countFont])
            let size: NSSize = number.size()
            let place: NSRect = countRect
            number.draw(at: NSPoint(x: place.minX + ((place.width - size.width) / 2).rounded(), y: place.minY + ((place.height - size.height) / 2).rounded()))
        }
    }

    // MARK: mouse

    /// The top row is title bar: it moves the window, as the tab bars beside it do.
    func isTitleBar(_ point: NSPoint) -> Bool { point.y < Self.header }

    override func mouseDown(with event: NSEvent) {
        if isTitleBar(convert(event.locationInWindow, from: nil)) { return TabBarView.titleBarMouseDown(event, in: window) }
        // Its empty space: a double-click pins the column unfolded, or folds it back, in every window.
        if event.clickCount == 2 { onToggle?() }
    }

    /// Below the title bar's strip while it is there: resting on the traffic lights, or dragging the window from there,
    /// opens nothing.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let place = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        addTrackingArea(NSTrackingArea(rect: place, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized: Bool = newSize != frame.size
        super.setFrameSize(newSize)
        if resized {
            needsLayout = true
            updateTrackingAreas() // its rect is not the visible rect's, so it follows the size itself
        }
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }

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
        // Their keys as the user has them, as the View menu shows them.
        KeyboardShortcuts.set(KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:"), on: hide)
        KeyboardShortcuts.set(KeyboardShortcuts.shared.chord(for: "toggleWindowColumnExpanded:"), on: fold)
        return menu
    }

    @objc private func chevronClicked() { onToggle?() }

    @objc private func shortcutsChanged() { if expanded { updateFoot() } }
    @objc private func moreClicked() { onMore?() }

    @objc private func buttonClicked(_ sender: WindowColumnButton) {
        // The window's own badge: it is in front already, and nothing more happens.
        guard sender.id != current else { return }
        onSelect?(sender.id)
    }

    // MARK: VoiceOver

    override func accessibilityChildren() -> [Any]? {
        var views: [NSView] = chevron.isHidden ? [] : [chevron]
        views += buttons.filter { !$0.isHidden } as [NSView]
        if !moreButton.isHidden { views.append(moreButton) }
        if !footButton.isHidden { views.append(footButton) }
        // A button view is not what VoiceOver reads (its cell is): the unignored ones stand in for them.
        return NSAccessibility.unignoredChildren(from: views)
    }

    // MARK: the self-test

    var chevronButton: NSButton { chevron }
    var overflowButton: NSButton { moreButton }
    var hideButton: NSButton { footButton }
    var countFrame: NSRect { countRect }
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

/// One window in the column: folded to the rail, a dot in its project's colour (its mark instead when an agent there
/// needs you or failed, in a darker well when it is this window, as the tab you are in sits darker than the others);
/// unfolded, its row (the badge, its name, and its marks with counts). It draws itself, and only when what its form shows
/// changed: a tooltip or a VoiceOver label is set without a draw. Quiet on purpose: only a decision or a failure in a
/// window should draw the eye.
final class WindowColumnButton: NSButton {
    let id: Int
    private(set) var row: WindowColumnRow?
    private(set) var isCurrent = false
    private(set) var expanded = false
    /// On the rail, the mark of a window that needs you or failed, in its dot's place.
    private let dot = StatusDotView()
    /// Unfolded, the marks with counts, as ⌘O's rows show them.
    private let marks = SwitcherMarksView()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    private static let badge: CGFloat = WindowColumnWidth.badge
    /// A nested worktree's row is this much further in.
    private static let indent: CGFloat = 14

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

    /// Where an unfolded row's badge is, further in for a nested worktree.
    private var badgeRect: NSRect {
        let y: CGFloat = ((bounds.height - Self.badge) / 2).rounded()
        let depth: CGFloat = CGFloat(row?.depth ?? 0)
        return NSRect(x: 5 + depth * Self.indent, y: y, width: Self.badge, height: Self.badge)
    }

    /// On the rail, the dot in the middle of the window's place.
    private var railDotRect: NSRect {
        let size: CGFloat = WindowColumnRail.dot
        return NSRect(x: ((bounds.width - size) / 2).rounded(), y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    /// The well behind this window: on the rail, round its dot; unfolded, the row.
    private var plateRect: NSRect { expanded ? bounds.insetBy(dx: 3, dy: 1) : railDotRect.insetBy(dx: -5, dy: -5) }

    /// What the rail marks: only a decision or a failure. Done and working stay a plain dot there; the list says them.
    private var railMark: TabState? {
        guard let urgent = row?.urgent, urgent == .attention || urgent == .failed else { return nil }
        return urgent
    }

    /// `row` as it is now: drawn again only if what this form shows of it changed.
    func configure(_ newRow: WindowColumnRow, current: Bool, expanded newExpanded: Bool) {
        #if DEBUG
        configureCount += 1
        #endif
        let old: WindowColumnRow? = row
        let formChanged: Bool = newExpanded != expanded
        let redraw: Bool = old.map { Self.drawsDifferently($0, newRow, expanded: newExpanded) } ?? true
            || current != isCurrent || formChanged
        row = newRow
        isCurrent = current
        expanded = newExpanded
        if redraw {
            dot.state = railMark ?? .idle
            place()
            needsDisplay = true
        }
        if expanded {
            marks.show(newRow.marks, color: Theme.textDim)
            placeMarks()
        } else if !marks.isHidden {
            marks.isHidden = true
        }
        if old?.words != newRow.words || old == nil || formChanged {
            // On the rail the list that opens on hover names the windows: no tooltip there to pop up over it.
            let tip: String? = expanded ? newRow.toolTip : nil
            if toolTip != tip { toolTip = tip } // re-setting a tooltip resets it
            setAccessibilityLabel(newRow.label)
        }
        if isAccessibilitySelected() != current { setAccessibilitySelected(current) }
    }

    /// What each form draws of its row: on the rail, the dot (colour, or the mark of a decision or a failure); unfolded, the
    /// badge and the name, at its depth, up to the marks. The marks are a view of their own, but the room the name has ends
    /// where they start, so a change of them draws the row again.
    private static func drawsDifferently(_ old: WindowColumnRow, _ new: WindowColumnRow, expanded: Bool) -> Bool {
        if old.letters != new.letters || old.color != new.color { return true }
        if expanded { return old.name != new.name || old.depth != new.depth || old.marks != new.marks }
        return old.color != new.color || old.urgent != new.urgent
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
        placeMarks()
    }

    /// On the rail, the mark of a decision or a failure in the dot's place: unfolded, the marks say it with counts.
    private func place() {
        let shows: Bool = !expanded && railMark != nil
        if dot.isHidden == shows { dot.isHidden = !shows }
        guard shows else { return }
        let frame: NSRect = railDotRect
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
        let plate: NSRect = plateRect
        let place = NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7)
        if isCurrent {
            // This window: a darker well, as the tab you are in. Increase Contrast edges it.
            Theme.background.setFill()
            place.fill()
            if DisplayOptions.increasesContrast {
                Theme.textDim.setStroke()
                let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
                edge.lineWidth = 1
                edge.stroke()
            }
        }
        if hovering || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            place.fill()
        }
        let fill: NSColor = NSColor(hex: row.color?.badge ?? ProjectColor.neutralBadge)
        guard expanded else {
            // The rail: the window's dot in its project's own colour (the Welcome rows' dot, readable on the bar where the
            // badge's darker tone is not), grey without one; its mark in its place when it needs you or failed.
            if railMark == nil {
                (row.color?.swatchColor ?? Theme.textDim).setFill()
                NSBezierPath(ovalIn: railDotRect).fill()
            }
            return
        }
        let badge: NSRect = badgeRect
        let tile = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
        fill.setFill()
        tile.fill()
        let letters: NSAttributedString = Self.lettersText(row.letters)
        let size: NSSize = letters.size()
        letters.draw(at: NSPoint(x: badge.minX + ((badge.width - size.width) / 2).rounded(), y: badge.minY + ((badge.height - size.height) / 2).rounded()))
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

    /// A badge's two letters: medium, lighter than bold as light text on dark reads heavier; two capitals or figures
    /// ("XC", "73") set a little apart, as short capitals read best, mixed case ("Ag") as the font sets it.
    static func lettersText(_ letters: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        return Typography.capitals(letters, font: font, color: Theme.text, tracking: WindowColumnBadge.tracks(letters) ? 0.7 : 0)
    }

    /// Increase Contrast changed: the well's edge is drawn again (the dot follows by itself).
    func contrastChanged() { if isCurrent { needsDisplay = true } }

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

    /// For the self-test: where the badge, the well and the dot are.
    var badgeForTest: NSRect { badgeRect }
    var railDotForTest: NSRect { railDotRect }
    var plateForTest: NSRect { plateRect }
    var dotFrameForTest: NSRect? { dot.isHidden ? nil : dot.frame }
    #endif
}
