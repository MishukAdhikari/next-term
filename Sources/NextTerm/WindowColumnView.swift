import AppKit
import NextTermCore

/// The window column: a strip at the window's outer edge listing every open Next Term window, folded to its rail (the
/// count, then a dot apiece in its project's colour, a mark only where a window needs you or failed) or unfolded to a row
/// apiece (the same dot, its name, and its marks as ⌘O shows them), with "Hide Column" and its key at its foot. A click
/// brings that window forward; a double-click on its empty space pins it unfolded or folds it back, in every window.
/// Pinned, a chevron in its count row folds it. Under the traffic lights, a strip of title bar. The same view unfolded is
/// the list that the rail opens over the content while the pointer rests on it (WindowColumnHost).
///
/// One grid in every form (WindowColumnGrid): the dot column at the window's outer edge, the count in it, a row of 24
/// points per window under it, a foot of 24 kept at the bottom. Unfolding only draws the names beside the dots: no dot,
/// count or well moves.
///
/// It does only what a change asks (WindowColumnList.Change): a window opening or closing matches its buttons by id and
/// lays it out once; one window's marks reconfigure that window's button alone, which draws only when what it shows
/// changed. Idle, it lays out and draws nothing. Rows are plain buttons with frames set by hand, placed as the folded tab
/// list places its marks (MarkColumn); windows that do not fit become a "+N" that opens ⌘O.
final class WindowColumnView: NSView, ProjectGlowing {
    /// At the window's right edge: the hairline goes on its left, the window's side, and the dots on its right.
    var onRight = false {
        didSet {
            guard onRight != oldValue else { return }
            updateChevron()
            for (button, row) in zip(buttons, list.rows) { button.configure(row, current: row.id == current, expanded: expanded, onRight: onRight) }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// At the window's top-left outside full screen: a strip of title bar for the traffic lights over the count, in every
    /// form, so nothing of the column is under them.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            updateTrackingAreas()
        }
    }

    /// A row was clicked: its window's id.
    var onSelect: ((Int) -> Void)?
    /// The chevron, or a double-click on its empty space: fold or unfold the column in every window.
    var onToggle: (() -> Void)?
    /// The "+N" for the windows there is no room for: ⌘O, which lists every one.
    var onMore: (() -> Void)?
    /// The pointer came onto the column (true) or left it (false): the rail's hover list follows it.
    var onPointer: ((Bool) -> Void)?
    /// The pointer moved on the column: a list held back for a pointer at rest may open now.
    var onMoved: (() -> Void)?
    /// It took new rows, a new form or a new window of its own: the hover list shows them too.
    var onUpdated: (() -> Void)?
    /// The list that the rail opens over the content (WindowColumnHost): no chevron, since it neither folds nor pins by
    /// one; a double-click on it pins the column, and leaving it closes it.
    var hovers = false {
        didSet { if hovers != oldValue { needsLayout = true } }
    }
    /// The list on hover covers the rail: VoiceOver hears each window once, in the list.
    var covered = false
    /// A right-click on the top row: the window's Project Color menu.
    var onTopRowMenu: (() -> NSMenu?)?
    /// The top row's slice of the project colour, as the tab bars beside it have.
    private(set) lazy var projectGlow = ProjectGlow(self)

    private(set) var list = WindowColumnList()
    /// This column's own window: its dot sits in a darker well, its row in a darker pill.
    private(set) var current = 0
    /// Unfolded as it shows: the user's choice, unless the window's room folded it.
    private(set) var expanded = false
    private(set) var buttons: [WindowColumnButton] = []
    private let chevron = HoverButton()
    private let moreButton = WindowColumnActionButton()
    /// Unfolded, at its foot: "Hide Column", with the key as the user has it.
    private let footButton = WindowColumnActionButton()
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
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.isHidden = true
        addSubview(moreButton)
        footButton.target = AppDelegate.shared
        footButton.action = #selector(AppDelegate.toggleWindowColumn(_:))
        footButton.isHidden = true
        footButton.words = "Hide Column"
        footButton.wordsFont = .systemFont(ofSize: 11)
        addSubview(footButton)
        // The keys at the foot and on "+N" as the user sets them, as the menus' and the tooltips' follow them.
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: KeyboardShortcuts.changed, object: nil)
        updateChevron()
        updateFoot()
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
                    button.configure(row, current: id == current, expanded: expanded, onRight: onRight)
                }
            }
        case .structure:
            match(newList.rows)
            needsLayout = true
        }
        if formChanged || currentChanged || change == .structure {
            for (button, row) in zip(buttons, newList.rows) { button.configure(row, current: row.id == current, expanded: expanded, onRight: onRight) }
        }
        if formChanged {
            updateChevron()
            needsLayout = true
            needsDisplay = true
        }
        if countChanged {
            needsDisplay = true // the count
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
    /// The count, in the dot column: under the title bar's strip at the top-left, else in the top row with the tab bars.
    private var countRect: NSRect {
        let x: CGFloat = stripX + WindowColumnGrid.dotColumnX(width: stripWidth, onRight: onRight)
        return NSRect(x: x, y: WindowColumnGrid.countTop(topInset: topInset), width: WindowColumnGrid.dotColumn,
                      height: WindowColumnGrid.countHeight(topInset: topInset))
    }

    override func layout() {
        super.layout()
        #if DEBUG
        layoutCount += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x: CGFloat = stripX, width: CGFloat = stripWidth
        let count: NSRect = countRect
        // Folded to the rail, no chevron: resting the pointer on it, a double-click or ⌃⌘S unfolds it. Nor on the hovering
        // list, which neither folds nor pins by one. Pinned, at the count row's trailing end.
        let showsChevron: Bool = expanded && !hovers
        if chevron.isHidden == showsChevron { chevron.isHidden = !showsChevron }
        let end: CGFloat = x + WindowColumnGrid.trailingEnd(width: width, onRight: onRight)
        let chevronFrame = NSRect(x: end - 14, y: count.minY, width: 20, height: count.height) // its glyph ends at `end`
        if showsChevron, chevron.frame != chevronFrame { chevron.frame = chevronFrame }
        if footButton.isHidden == expanded { footButton.isHidden = !expanded }
        let foot: CGFloat = WindowColumnGrid.foot
        if expanded {
            let frame = NSRect(x: x, y: bounds.height - foot, width: width, height: foot)
            if footButton.frame != frame { footButton.frame = frame }
        }
        let column = MarkColumn(count: buttons.count, height: bounds.height - foot, top: count.maxY, slot: WindowColumnGrid.row,
                                margin: WindowColumnGrid.margin)
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
        moreButton.place(expanded: expanded, onRight: onRight)
        footButton.place(expanded: expanded, onRight: onRight)
        CATransaction.commit()
        updateMore()
    }

    /// The "+N": how many windows do not fit, in the colour of the most urgent mark among them; unfolded, "All Windows…"
    /// beside it with ⌘O's key. Its tooltip names them.
    private func updateMore() {
        guard !moreButton.isHidden else { return }
        let hidden: [WindowColumnRow] = Array(list.rows.dropFirst(shownCount))
        guard !hidden.isEmpty else { return }
        let state: TabState = MarkColumn.moreState(hidden.map { $0.urgent ?? .idle })
        moreButton.lead = "+\(hidden.count)"
        moreButton.leadColor = StatusGlyph.moreColor(for: state)
        moreButton.words = "All Windows…"
        moreButton.key = KeyboardShortcuts.shared.chord(for: "openProjectPanel:")?.display ?? ""
        let tip = "\(hidden.count) more window\(hidden.count == 1 ? "" : "s"): " + hidden.map(\.label).joined(separator: "; ")
        if moreButton.toolTip != tip { moreButton.toolTip = tip } // re-setting a tooltip resets it
        moreButton.setAccessibilityLabel(tip)
    }

    /// "Hide Column" and the key as the user has it now (without one, the words alone).
    private func updateFoot() {
        let key: String = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display ?? ""
        footButton.key = key
        footButton.setAccessibilityLabel(key.isEmpty ? "Hide Window Column" : "Hide Window Column, \(key)")
    }

    /// Pinned, the chevron points the way the column folds: toward the window's edge.
    private func updateChevron() {
        let pointsRight: Bool = onRight
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

    /// The hairline down its inner edge. Under the traffic lights, from the strip's bottom line down: the strip and the
    /// bar beside it read as one title bar, with no line between the lights.
    var hairlineRect: NSRect {
        let top: CGFloat = topInset > 0 ? WindowColumnGrid.titleStrip - 1 : 0
        return NSRect(x: onRight ? 0 : bounds.width - WindowColumnWidth.hairline, y: top, width: WindowColumnWidth.hairline,
                      height: max(0, bounds.height - top))
    }

    /// Text that is not a window's name (the count, the heading, a detail, the foot): dim, and plainer with Increase
    /// Contrast.
    static var secondary: NSColor { DisplayOptions.increasesContrast ? SwitcherRowStyle.selectedSecondary : Theme.textDim }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        drawCount += 1
        #endif
        Theme.bar.setFill()
        bounds.fill()
        let strip: CGFloat = WindowColumnGrid.titleStrip
        projectGlow.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: strip - 1))
        // The tab bars' bottom line runs on across the top row, and the hairline down the window's side: the list's
        // plainer with Increase Contrast, where it lies over the content.
        Theme.border.setFill()
        NSRect(x: 0, y: strip - 1, width: bounds.width, height: 1).fill()
        if hovers && DisplayOptions.increasesContrast { Theme.textDim.setFill() }
        hairlineRect.fill()
        // The count in the dot column, as the rail draws it, in figures that never shift.
        let place: NSRect = countRect
        let number = NSAttributedString(string: "\(list.count)", attributes: [.foregroundColor: Self.secondary, .font: Theme.countFont])
        let size: NSSize = number.size()
        let numberAt = NSPoint(x: place.minX + ((place.width - size.width) / 2).rounded(), y: place.minY + ((place.height - size.height) / 2).rounded())
        number.draw(at: numberAt)
        guard expanded else { return }
        // Unfolded, what they are beside it, at the names' x and on its baseline: a figure in one column, a word in the
        // other, as ⌘O heads its rows.
        let heading: NSAttributedString = Self.headingText()
        let baseline: CGFloat = numberAt.y + Theme.countFont.ascender
        let headingFont: NSFont = heading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 11)
        let x: CGFloat = stripX + WindowColumnGrid.nameX(width: stripWidth, onRight: onRight, depth: 0)
        heading.draw(at: NSPoint(x: x, y: WindowColumnButton.snap(baseline - headingFont.ascender, in: self)))
    }

    /// "WINDOWS", as ⌘O heads its windows: small capitals set apart.
    static func headingText() -> NSAttributedString {
        let set = NSMutableAttributedString(attributedString: WelcomeWindowController.headingText("Windows"))
        set.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: 0, length: set.length))
        return set
    }

    /// Increase Contrast changed: the dim text, the hairline, the wells' edges.
    func contrastChanged() {
        needsDisplay = true
        buttons.forEach { $0.contrastChanged() }
        moreButton.contrastChanged()
        footButton.contrastChanged()
    }

    // MARK: mouse

    /// The top row is title bar: it moves the window, as the tab bars beside it do.
    func isTitleBar(_ point: NSPoint) -> Bool { point.y < WindowColumnGrid.titleStrip }

    override func mouseDown(with event: NSEvent) {
        if isTitleBar(convert(event.locationInWindow, from: nil)) { return TabBarView.titleBarMouseDown(event, in: window) }
        // Its empty space: a double-click pins the column unfolded, or folds it back, in every window.
        if event.clickCount == 2 { onToggle?() }
    }

    /// Below the title bar's strip while it is there: resting on the traffic lights, or dragging the window from there,
    /// opens nothing. Its moves say when a pointer held still has moved.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let place = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        addTrackingArea(NSTrackingArea(rect: place, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
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
    override func mouseMoved(with event: NSEvent) { onMoved?() }

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

    @objc private func shortcutsChanged() {
        updateFoot()
        updateMore()
    }

    @objc private func moreClicked() { onMore?() }

    @objc private func buttonClicked(_ sender: WindowColumnButton) {
        // The window's own row: it is in front already, and nothing more happens.
        guard sender.id != current else { return }
        onSelect?(sender.id)
    }

    // MARK: VoiceOver

    override func accessibilityChildren() -> [Any]? {
        // Under the list on hover, which reads the same windows: nothing here, so none is heard twice.
        if covered { return [] }
        var views: [NSView] = chevron.isHidden ? [] : [chevron]
        views += buttons.filter { !$0.isHidden } as [NSView]
        if !moreButton.isHidden { views.append(moreButton) }
        if !footButton.isHidden { views.append(footButton) }
        // A button view is not what VoiceOver reads (its cell is): the unignored ones stand in for them.
        return NSAccessibility.unignoredChildren(from: views)
    }

    // MARK: the self-test

    var chevronButton: NSButton { chevron }
    var overflowButton: WindowColumnActionButton { moreButton }
    var hideButton: WindowColumnActionButton { footButton }
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

/// One window in the column, on the grid every form shares (WindowColumnGrid): its dot in the dot column in its
/// project's colour (its mark instead when an agent there needs you or failed), in a darker well when it is this window,
/// as the tab you are in sits darker than the others. Unfolded, its name beside the dot, at its depth; a dimmer detail
/// after it while another row shows the same name; its marks with counts at the row's end; and this window's well is a
/// pill along the row. It draws itself, and only when what its form shows changed: a tooltip or a VoiceOver label is set
/// without a draw. Quiet on purpose: only a decision or a failure in a window should draw the eye.
final class WindowColumnButton: NSButton {
    let id: Int
    private(set) var row: WindowColumnRow?
    private(set) var isCurrent = false
    private(set) var expanded = false
    private(set) var onRight = false
    /// The mark of a window that needs you or failed, in its dot's place.
    private let dot = StatusDotView()
    /// Unfolded, the marks with counts, as ⌘O's rows show them.
    private let marks = SwitcherMarksView()
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            if expanded { marks.show(row?.marks ?? [], color: marksColor) }
        }
    }

    /// The name's face: the tab bar's, the tab list's and the project tree's size, so a window reads as a tab does.
    static let nameFont = NSFont.systemFont(ofSize: 12.5)
    /// A detail after it: the sidebar's smaller size, in the dim colour.
    static let detailFont = NSFont.systemFont(ofSize: 12)
    /// Between a name and its detail, and between its end and the marks.
    private static let gap: CGFloat = 6
    /// The least room a detail is shown in: less, and it gives way whole.
    private static let detailMinimum: CGFloat = 24

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

    /// The dot, in the middle of the dot column.
    private var dotRect: NSRect { WindowColumnGrid.dotRect(width: bounds.width, height: bounds.height, onRight: onRight) }

    /// The plate behind this window and under the pointer: on the rail, the well round its dot; unfolded, the pill.
    private var plateRect: NSRect {
        WindowColumnGrid.plateRect(width: bounds.width, height: bounds.height, rail: !expanded, onRight: onRight)
    }

    /// What the dot's place marks: only a decision or a failure. Done and working stay a plain dot there; the list's marks
    /// say them.
    private var railMark: TabState? {
        guard let urgent = row?.urgent, urgent == .attention || urgent == .failed else { return nil }
        return urgent
    }

    /// A hovered or pressed row lights its dim text a step, as a selected ⌘O row does; this window's own row stays.
    private var lit: Bool { expanded && !isCurrent && (hovering || isHighlighted) }
    private var secondaryColor: NSColor { lit ? SwitcherRowStyle.selectedSecondary : WindowColumnView.secondary }
    private var marksColor: NSColor { secondaryColor }

    /// `row` as it is now: drawn again only if what this form shows of it changed.
    func configure(_ newRow: WindowColumnRow, current: Bool, expanded newExpanded: Bool, onRight newOnRight: Bool) {
        #if DEBUG
        configureCount += 1
        #endif
        let old: WindowColumnRow? = row
        let formChanged: Bool = newExpanded != expanded || newOnRight != onRight
        let redraw: Bool = old.map { Self.drawsDifferently($0, newRow, expanded: newExpanded) } ?? true
            || current != isCurrent || formChanged
        row = newRow
        let currentChanged: Bool = current != isCurrent
        isCurrent = current
        expanded = newExpanded
        onRight = newOnRight
        if redraw {
            dot.state = railMark ?? .idle
            place()
            needsDisplay = true
        }
        if expanded {
            marks.show(newRow.marks, color: marksColor)
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
        if currentChanged || old == nil {
            setAccessibilityHelp(current ? "This window" : "Brings this window to the front")
        }
        if isAccessibilitySelected() != current { setAccessibilitySelected(current) }
    }

    /// What each form draws of its row: on the rail, the dot (colour, or the mark of a decision or a failure); unfolded,
    /// the dot and the name, its prefix and detail, at its depth, up to the marks. The marks are a view of their own, but
    /// the room the name has ends where they start, so a change of them draws the row again.
    private static func drawsDifferently(_ old: WindowColumnRow, _ new: WindowColumnRow, expanded: Bool) -> Bool {
        if old.color != new.color || old.urgent != new.urgent { return true }
        guard expanded else { return false }
        return old.name != new.name || old.prefix != new.prefix || old.detail != new.detail || old.depth != new.depth
            || old.marks != new.marks
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
        placeMarks()
    }

    /// The mark of a decision or a failure in the dot's place, in either form: the list over the rail shows what the rail
    /// does, and its marks say it again with counts.
    private func place() {
        let shows: Bool = railMark != nil
        if dot.isHidden == shows { dot.isHidden = !shows }
        guard shows else { return }
        let frame: NSRect = dotRect
        if dot.frame != frame { dot.frame = frame }
    }

    /// Unfolded, the marks at the trailing column's end, centred on the dot's line.
    private func placeMarks() {
        guard expanded else { return }
        let shows: Bool = !(row?.marks.isEmpty ?? true)
        if marks.isHidden == shows { marks.isHidden = !shows }
        guard shows else { return }
        let size: NSSize = marks.fittingSize
        let end: CGFloat = WindowColumnGrid.trailingEnd(width: bounds.width, onRight: onRight)
        let frame = NSRect(x: end - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        if marks.frame != frame { marks.frame = frame }
    }

    /// `y` on the screen's pixel grid, so text sits sharp.
    static func snap(_ y: CGFloat, in view: NSView) -> CGFloat {
        let scale: CGFloat = view.window?.backingScaleFactor ?? 2
        return (y * scale).rounded() / scale
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        drawCount += 1
        #endif
        guard let row else { return }
        let plate: NSRect = plateRect
        let radius: CGFloat = WindowColumnGrid.plateRadius
        let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
        if isCurrent {
            // This window: a darker well, as the tab you are in. Increase Contrast edges it. No hover over it: a click on
            // it does nothing.
            Theme.background.setFill()
            shape.fill()
            if DisplayOptions.increasesContrast {
                Theme.textDim.setStroke()
                let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                edge.lineWidth = 1
                edge.stroke()
            }
        } else if hovering || isHighlighted {
            if expanded {
                // A row: the tab list's hover, and a step lighter pressed.
                (isHighlighted ? Theme.tabHover : TabListRowView.hoverFill).setFill()
            } else {
                NSColor.white.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            }
            shape.fill()
        }
        // The window's dot in its project's own colour (the Welcome rows' dot), grey without one; its mark in its place
        // when it needs you or failed.
        if railMark == nil {
            (row.color?.swatchColor ?? Theme.textDim).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
        guard expanded else { return }
        drawWords(row)
    }

    /// The name, with a worktree's repository before it, and a detail after it while there is room, on one baseline:
    /// the name's cap height centred on the dot. The name keeps its room first; the detail gives way, cut at its end,
    /// and goes whole under `detailMinimum`.
    private func drawWords(_ row: WindowColumnRow) {
        let start: CGFloat = WindowColumnGrid.nameX(width: bounds.width, onRight: onRight, depth: row.depth)
        let end: CGFloat = marks.isHidden ? WindowColumnGrid.trailingEnd(width: bounds.width, onRight: onRight) : marks.frame.minX - Self.gap
        guard end > start else { return }
        let dim: NSColor = secondaryColor
        let name = NSMutableAttributedString()
        if let prefix = row.prefix {
            name.append(NSAttributedString(string: prefix + WorktreeWindow.separator, attributes: [.font: Self.nameFont, .foregroundColor: dim]))
        }
        name.append(NSAttributedString(string: row.name, attributes: [.font: Self.nameFont, .foregroundColor: Theme.text]))
        let baseline: CGFloat = Self.snap(bounds.height / 2 + Self.nameFont.capHeight / 2, in: self)
        let room: CGFloat = end - start
        let nameWidth: CGFloat = ceil(name.size().width)
        // Cut in the middle: a name's end tells it apart as much as its start does.
        let shown: NSAttributedString = Typography.truncating(name, .byTruncatingMiddle)
        let nameHeight: CGFloat = ceil(Self.nameFont.ascender - Self.nameFont.descender)
        shown.draw(with: NSRect(x: start, y: baseline - Self.nameFont.ascender, width: min(room, nameWidth), height: nameHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard let detail = row.detail, nameWidth < room else { return }
        let left: CGFloat = room - nameWidth - Self.gap
        guard left >= Self.detailMinimum else { return }
        let words = NSAttributedString(string: detail, attributes: [
            .font: Self.detailFont, .foregroundColor: dim, .paragraphStyle: Typography.paragraph(.byTruncatingTail),
        ])
        let detailHeight: CGFloat = ceil(Self.detailFont.ascender - Self.detailFont.descender)
        words.draw(with: NSRect(x: start + nameWidth + Self.gap, y: baseline - Self.detailFont.ascender, width: left, height: detailHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Increase Contrast changed: the well's edge, and unfolded the dim text, are drawn again (the dot follows by itself).
    func contrastChanged() {
        guard isCurrent || expanded else { return }
        needsDisplay = true
        if expanded { marks.show(row?.marks ?? [], color: marksColor) }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
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

    /// Clicks anywhere on the row are the button's, the dot and the marks included.
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

    /// For the self-test: where the dot, the plate, the mark and the marks are.
    var dotForTest: NSRect { dotRect }
    var plateForTest: NSRect { plateRect }
    var dotFrameForTest: NSRect? { dot.isHidden ? nil : dot.frame }
    var marksFrameForTest: NSRect? { marks.isHidden ? nil : marks.frame }
    var marksForTest: SwitcherMarksView { marks }
    var hoveringForTest: Bool {
        get { hovering }
        set { hovering = newValue }
    }
    #endif
}

/// A row of the column that is not a window: "+N" for the windows with no room (unfolded, "All Windows…" and ⌘O's key
/// beside it) and the foot's "Hide Column" with its key. On the same grid as the windows' rows: the lead in the dot
/// column, the words at the names' x, the key at the trailing column's end, a row's pill under the pointer. One button,
/// the whole row, so it is easy to hit.
final class WindowColumnActionButton: NSButton {
    /// In the dot column: "+3".
    var lead: String? {
        didSet { if lead != oldValue { needsDisplay = true } }
    }
    var leadColor: NSColor = Theme.textDim {
        didSet { if leadColor != oldValue { needsDisplay = true } }
    }
    /// Unfolded, at the names' x.
    var words: String = "" {
        didSet { if words != oldValue { needsDisplay = true } }
    }
    var wordsFont: NSFont = WindowColumnButton.nameFont {
        didSet { if wordsFont != oldValue { needsDisplay = true } }
    }
    /// Unfolded, at the trailing end: the key, as KeyHint shows one; nothing without one.
    var key: String = "" {
        didSet { if key != oldValue { needsDisplay = true } }
    }
    private(set) var expanded = false
    private(set) var onRight = false
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func place(expanded newExpanded: Bool, onRight newOnRight: Bool) {
        guard newExpanded != expanded || newOnRight != onRight else { return }
        expanded = newExpanded
        onRight = newOnRight
        needsDisplay = true
    }

    /// What it says, for the self-test: "+3", "All Windows…  ⌘O", "Hide Column  ⌃⇧⌘S".
    var shownWords: String {
        let parts: [String] = [lead ?? "", expanded ? words : "", expanded ? key : ""].filter { !$0.isEmpty }
        return parts.joined(separator: "  ")
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            let plate: NSRect = WindowColumnGrid.plateRect(width: bounds.width, height: bounds.height, rail: !expanded, onRight: onRight)
            let radius: CGFloat = WindowColumnGrid.plateRadius
            if expanded {
                (isHighlighted ? Theme.tabHover : TabListRowView.hoverFill).setFill()
            } else {
                NSColor.white.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            }
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
        }
        let lit: Bool = expanded && (hovering || isHighlighted)
        let dim: NSColor = lit ? SwitcherRowStyle.selectedSecondary : WindowColumnView.secondary
        let middle: CGFloat = bounds.height / 2
        if let lead {
            let text = NSAttributedString(string: lead, attributes: [.foregroundColor: leadColor, .font: Theme.countFont])
            let size: NSSize = text.size()
            let column: CGFloat = WindowColumnGrid.dotColumnX(width: bounds.width, onRight: onRight)
            text.draw(at: NSPoint(x: column + ((WindowColumnGrid.dotColumn - size.width) / 2).rounded(), y: (middle - size.height / 2).rounded()))
        }
        guard expanded else { return }
        let baseline: CGFloat = WindowColumnButton.snap(middle + wordsFont.capHeight / 2, in: self)
        let start: CGFloat = WindowColumnGrid.nameX(width: bounds.width, onRight: onRight, depth: 0)
        let end: CGFloat = WindowColumnGrid.trailingEnd(width: bounds.width, onRight: onRight)
        let keyFont = NSFont.systemFont(ofSize: 11)
        var keyStart: CGFloat = end
        if !key.isEmpty {
            let hint = NSAttributedString(string: key, attributes: [.font: keyFont, .foregroundColor: dim])
            let width: CGFloat = ceil(hint.size().width)
            keyStart = end - width
            hint.draw(at: NSPoint(x: keyStart, y: baseline - keyFont.ascender))
        }
        let room: CGFloat = keyStart - KeyHint.lead - start
        guard !words.isEmpty, room > 0 else { return }
        let text = NSAttributedString(string: words, attributes: [
            .font: wordsFont, .foregroundColor: dim, .paragraphStyle: Typography.paragraph(.byTruncatingTail),
        ])
        let height: CGFloat = ceil(wordsFont.ascender - wordsFont.descender)
        text.draw(with: NSRect(x: start, y: baseline - wordsFont.ascender, width: room, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Increase Contrast changed: unfolded, its dim text is drawn again.
    func contrastChanged() { if expanded { needsDisplay = true } }

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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }
}
