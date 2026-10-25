import AppKit
import NextTermCore

/// One row of the terminal's tab list: a tab, or one pane of a split tab under it. The top bar's tab turned on its
/// side: the same status mark, server mark, title, place mark, × and "⌘N", the same "touch only what changed" lines,
/// and frames set by hand. It draws nothing itself: its fills are layer colours, so a row that moves (a scroll, a
/// reorder) redraws nothing, and only its text draws again, when it changes or re-truncates.
@objc(NTTabListRow)
final class TabListRowView: NSView, NSTextFieldDelegate {
    weak var list: TabListView?

    /// The status mark's and the title's places, as on the top bar's tab.
    static let markX: CGFloat = 12
    static let titleX: CGFloat = 29
    /// A pane's row sits in under its tab's, as a project tree's row under its folder.
    static let paneIndent: CGFloat = 14
    /// The server mark's column before a title.
    private static let remoteX: CGFloat = 25
    /// With two lines: the title's baseline down from the row's top, and the second line's below the title's.
    private static let titleBaseline: CGFloat = 17
    private static let detailLeading: CGFloat = 15

    private static let font = NSFont.systemFont(ofSize: 12.5)
    /// The sidebar's size for a line under a name.
    private static let detailFont = NSFont.systemFont(ofSize: 11.5)
    /// "⌘N" in tabular figures: the keys sit in a column, and "⌘2" is a point narrower than "⌘3" otherwise.
    private static let hintFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// A hovered row: a step darker than the top bar's hover, so the dim second line on it still reads at 4.5:1
    /// (4.56:1 here, 4.28:1 on the bar's).
    static let hoverFill = NSColor(hex: 0x35373B)
    /// The row's own layers change at once, as its view's colours do: never a fade.
    private static let noAnimations: [String: CAAction] = [
        "backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
    ]

    /// A line's height and where its baseline sits under its top, measured once for each font.
    private static func metrics(_ font: NSFont) -> (height: CGFloat, baseline: CGFloat) {
        let probe = NSTextField(labelWithString: "Ag")
        probe.font = font
        probe.setFrameSize(probe.intrinsicContentSize) // its baseline is read within the frame it would have
        return (probe.frame.height, probe.firstBaselineOffsetFromTop)
    }
    private static let titleMetrics = metrics(font)
    private static let detailMetrics = metrics(detailFont)
    private static let hintHeight: CGFloat = metrics(hintFont).height

    private let dot = StatusDotView()
    /// A remote tab's server mark: before the title with one line, at the start of the second line with two.
    private let remoteMark = RemoteMarkView()
    private let label = TabListText(labelWithString: "")
    /// Show Folders: the tab's folder, or the question its agent is asking.
    private let detail = TabListText(labelWithString: "")
    /// The place mark, right after the title.
    private let placeMark = NSImageView()
    private let closeButton = NSButton()
    /// "⌘1": how to get to this tab from the keyboard, in the ×'s place on the rows that show none.
    private let hint = TabListText(labelWithString: "")
    private var renameField: NSTextField?
    /// The selected tab's 2-point accent edge, on the side away from the terminal.
    private let edge = CALayer()
    /// Collapsed: the selected tab's rounded place and an idle tab's dot, as on the terminal rail.
    private let slot = CALayer()
    private let idleDot = CALayer()

    private(set) var row: TabListRow?
    /// A tab row: its tab is the selected one. A pane row: its tab is.
    private var selected = false
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    var isDragging = false {
        didSet {
            alphaValue = isDragging ? TabListMotion.draggedAlpha : 1
            layer?.zPosition = isDragging ? TabListMotion.draggedZ : 0
        }
    }

    var density: TabListDensity = .oneLine { didSet { if density != oldValue { needsLayout = true } } }
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            needsLayout = true
            refresh()
        }
    }
    /// Some row of this kind shows its server mark before its title: every title of the kind then starts after
    /// that column, so the titles line up.
    var remoteColumn = false { didSet { if remoteColumn != oldValue { needsLayout = true } } }
    /// The widest "⌘N" in the list: every row leaves it the room, so the digits' own widths never decide alone
    /// which rows show their key, and all of them show it or none does.
    var listHintWidth: CGFloat = 0 { didSet { if listHintWidth != oldValue { needsLayout = true } } }
    var side: TabListSide = .left { didSet { if side != oldValue { needsLayout = true } } }
    /// This row's "⌘N", measured as it changes.
    private(set) var hintWidth: CGFloat = 0
    /// The title keeps room to be read beside "⌘N", as the last layout found.
    private var hintFits = false
    /// What the list's one tooltip area shows for this row (a row's own tooltip would stay live while it is
    /// scrolled out of sight).
    private(set) var toolTipText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for sublayer in [slot, idleDot, edge] {
            sublayer.actions = Self.noAnimations
            sublayer.isHidden = true
            layer?.addSublayer(sublayer)
        }
        // Under the mark, which is a view's layer.
        slot.zPosition = -1
        idleDot.zPosition = -1
        slot.cornerRadius = 4
        idleDot.cornerRadius = 2.5
        idleDot.backgroundColor = Theme.textDim.withAlphaComponent(0.7).cgColor
        edge.backgroundColor = Theme.accent.cgColor

        label.font = Self.font
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        addSubview(label)
        detail.font = Self.detailFont
        detail.textColor = Theme.textDim
        Typography.singleLine(detail, truncation: .byTruncatingHead)
        detail.isHidden = true
        addSubview(detail)
        addSubview(dot)
        remoteMark.isHidden = true
        addSubview(remoteMark)
        placeMark.image = PlaceGlyph.image()
        placeMark.contentTintColor = Theme.textDim
        placeMark.isHidden = true
        addSubview(placeMark)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.refusesFirstResponder = true // the list never takes the keyboard from the terminal
        closeButton.isHidden = true
        addSubview(closeButton)
        KeyHint.style(hint) // said in the row's own help, as the buttons' keys are in theirs
        hint.font = Self.hintFont
        hint.isHidden = true
        addSubview(hint)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        // View › Agent Spinner changed: a working tab with the ring off shows the idle dot while collapsed.
        NotificationCenter.default.addObserver(self, selector: #selector(spinnerChanged), name: AgentSpinner.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var isPane: Bool { row?.isPane ?? false }

    @objc private func spinnerChanged() { refresh() }

    // Called several times a second: touch only what changed (re-setting a label's text or colour redraws it).
    func configure(row newRow: TabListRow, selected isSelected: Bool) {
        guard newRow != row || isSelected != selected else { return }
        let old = row
        if newRow.kind != old?.kind {
            setAccessibilityRole(newRow.isPane ? .button : .radioButton) // a pane is no tab of its own
            needsLayout = true
        }
        if newRow.title != old?.title || newRow.shorterTitles != old?.shorterTitles {
            label.stringValue = newRow.title
            if !newRow.shorterTitles.isEmpty { needsLayout = true } // layout may shorten it
        }
        let truncation: NSLineBreakMode = newRow.truncatesTail ? .byTruncatingTail : .byTruncatingMiddle
        if label.lineBreakMode != truncation { label.lineBreakMode = truncation }
        if newRow.detail != old?.detail {
            detail.stringValue = newRow.detail ?? ""
            if (newRow.detail == nil) != (old?.detail == nil) { needsLayout = true }
        }
        // A folder keeps its end, which says the most; a question keeps its start.
        let detailTruncation: NSLineBreakMode = newRow.detailIsQuestion ? .byTruncatingTail : .byTruncatingHead
        if detail.lineBreakMode != detailTruncation { detail.lineBreakMode = detailTruncation }
        toolTipText = Self.tipText(for: newRow)
        if hint.stringValue != newRow.shortcut ?? "" {
            hint.stringValue = newRow.shortcut ?? ""
            hintWidth = hint.stringValue.isEmpty ? 0 : ceil(hint.intrinsicContentSize.width)
            needsLayout = true
        }
        setAccessibilityHelp(newRow.shortcut.map { "\($0) switches to this tab" })
        dot.state = newRow.state
        if (newRow.remote == nil) != (old?.remote == nil) { needsLayout = true } // the title moves over, or back
        remoteMark.link = newRow.remote?.link
        // The title makes room for the place mark, or takes it back; the mark follows the title's end.
        let placeMoved: Bool = (newRow.place == nil) != (old?.place == nil) || (newRow.place != nil && newRow.title != old?.title)
        if placeMoved { needsLayout = true }
        row = newRow
        selected = isSelected
        setAccessibilityLabel(newRow.accessibilityLabel)
        if !newRow.isPane { setAccessibilityValue(isSelected) }
        refresh()
    }

    /// The top bar's tooltip for the tab, its place and its key under it; a pane's own.
    private static func tipText(for row: TabListRow) -> String {
        guard !row.isPane else { return row.tooltip }
        let place: String = row.place.map { "\n" + $0 } ?? ""
        let key: String = row.shortcut.map { "\n\($0) switches to this tab" } ?? ""
        return row.tooltip + place + key
    }

    /// For the self-test: what the row shows.
    var shownTitle: String { label.stringValue }
    var shownShortcut: String? { hint.isHidden ? nil : hint.stringValue }
    var shownDetail: String? { detail.isHidden ? nil : detail.stringValue }
    var showsClose: Bool { !closeButton.isHidden }
    var showsPlaceMark: Bool { !placeMark.isHidden }
    var shownRemoteLink: RemoteLink? { remoteMark.isHidden ? nil : remoteMark.link }

    /// Whether `point`, in the row's coordinates, is on the × it shows.
    func closeContains(_ point: NSPoint) -> Bool { !closeButton.isHidden && closeButton.frame.contains(point) }

    private func refresh() {
        let pane = isPane
        layer?.backgroundColor = rowFill.cgColor
        edge.isHidden = collapsed || pane || !selected
        slot.isHidden = !collapsed || !(selected || hovering)
        if collapsed { slot.backgroundColor = Self.slotFill(selected: selected, hovering: hovering).cgColor }
        // An idle tab has no mark (nor a working one with Agent Spinner off); collapsed it still needs something to
        // see and click, as on the rail.
        idleDot.isHidden = !collapsed || StatusDotView.shows(row?.state ?? .idle)
        // Every tab's title in full colour: in a list the fill tells the selection. A pane's dim, but for the one
        // with the keyboard in the selected tab.
        let textColor: NSColor = !pane || (row?.focused == true && selected) ? Theme.text : Theme.textDim
        if label.textColor != textColor { label.textColor = textColor }
        remoteMark.tint = textColor
        updateCloseAndHint()
    }

    /// The selected tab's row takes the terminal's colour, a hovered row the hover fill; collapsed, the slot's
    /// layer shows them instead.
    private var rowFill: NSColor {
        if collapsed { return .clear }
        if selected && !isPane { return Theme.background }
        return hovering ? Self.hoverFill : .clear
    }

    /// The selected tab's place in the collapsed column, lighter under the pointer, as the rail's.
    private static func slotFill(selected: Bool, hovering: Bool) -> NSColor {
        let lift = NSColor.white.withAlphaComponent(0.08)
        guard selected else { return hovering ? lift : .clear }
        guard hovering else { return Theme.background }
        return Theme.background.blended(withFraction: 0.08, of: .white) ?? Theme.background
    }

    /// The × and "⌘N" share one place at the row's end: the × on the selected or hovered row, the key on the
    /// others. So the title is as wide in every state, and never re-truncates as the pointer passes.
    private func updateCloseAndHint() {
        let tabRow = !isPane && !collapsed && !isEditing
        let closeShown = tabRow && (selected || hovering)
        if closeButton.isHidden == closeShown { closeButton.isHidden = !closeShown }
        let hintShown = tabRow && !closeShown && hintFits
        if hint.isHidden == hintShown { hint.isHidden = !hintShown }
    }

    override func layout() {
        super.layout()
        #if DEBUG
        layoutCount += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if collapsed { layoutSlot() } else { layoutLine() }
        CATransaction.commit()
        updateCloseAndHint()
    }

    /// Collapsed: the mark alone, in the middle of a 24-point slot.
    private func layoutSlot() {
        let markX: CGFloat = ((bounds.width - 10) / 2).rounded()
        let markY: CGFloat = ((bounds.height - 10) / 2).rounded()
        dot.frame = NSRect(x: markX, y: markY, width: 10, height: 10)
        slot.frame = bounds.insetBy(dx: 3, dy: 2)
        idleDot.frame = CGRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)
        let words: [NSView] = [label, detail, remoteMark, placeMark]
        for view in words { view.isHidden = true }
        hintFits = false
    }

    private func layoutLine() {
        guard let row else { return }
        let w = bounds.width
        let h = bounds.height
        let pane = row.isPane
        let indent: CGFloat = pane ? Self.paneIndent : 0
        // A herdr agent's row has its second line too (its question, or where it works); a pane's has none.
        let twoLines = density == .twoLines && (!pane || row.isAgent)
        // One line sits in the middle of the row, as on the bar; with two the title's baseline is 17 down. The
        // marks, the × and the key sit on the title's line, not the row's middle.
        let titleHeight: CGFloat = Self.titleMetrics.height
        let titleY: CGFloat = twoLines ? Self.titleBaseline - Self.titleMetrics.baseline : (h - titleHeight) / 2
        let lineMid: CGFloat = titleY + titleHeight / 2
        dot.frame = NSRect(x: Self.markX + indent, y: lineMid - 5, width: 10, height: 10)

        // A remote row with one line: the status mark keeps its column (the same place on every row), and the
        // server mark goes before the title, like an icon of the title. Its server sits on the title's line.
        let remote = row.remote != nil
        let columnX: CGFloat = Self.remoteX + indent
        let afterColumn: CGFloat = columnX + RemoteMarkView.size.width + 3
        let markBeforeTitle = remote && !twoLines
        let labelX: CGFloat = markBeforeTitle || (remoteColumn && !twoLines) ? afterColumn : Self.titleX + indent

        // "⌘N" ends 14 points from the edge, in the ×'s place, as long as the title keeps 40 points to be read
        // (the bar's rule without its ×). Every tab row leaves the widest key's room, so they all decide alike.
        let closeX: CGFloat = w - 24
        let hintEnd: CGFloat = w - 14
        let keyRoom: CGFloat = max(hintWidth, listHintWidth)
        let keysShow: Bool = !pane && listHintWidth > 0 && hintEnd - listHintWidth - 6 - labelX >= 40
        hintFits = keysShow && hintWidth > 0
        let titleEnd: CGFloat
        if pane {
            titleEnd = hintEnd // no × and no key on a pane's row
        } else if keysShow {
            titleEnd = min(closeX, hintEnd - keyRoom) - 6
        } else {
            titleEnd = w - 28
        }
        let placeRoom: CGFloat = row.place == nil ? 0 : 15
        let titleWidth: CGFloat = max(0, titleEnd - labelX - placeRoom)
        let words = fittedTitle(within: titleWidth)
        if let words, label.stringValue != words { label.stringValue = words }
        label.frame = NSRect(x: labelX, y: titleY, width: titleWidth, height: titleHeight)
        label.isHidden = isEditing
        closeButton.frame = NSRect(x: closeX, y: lineMid - 9, width: 18, height: 18)
        let hintHeight: CGFloat = Self.hintHeight
        hint.frame = NSRect(x: hintEnd - hintWidth, y: lineMid - hintHeight / 2, width: hintWidth, height: hintHeight)

        // The place mark right after the title's last letter.
        placeMark.isHidden = row.place == nil
        let text: CGFloat = (label.stringValue as NSString).size(withAttributes: [.font: Self.font]).width + 4
        placeMark.frame = NSRect(x: labelX + min(titleWidth, ceil(text)) + 1, y: lineMid - 5.5, width: 11, height: 11)

        remoteMark.isHidden = !remote
        let markSize: NSSize = RemoteMarkView.size
        if twoLines {
            // The second line, under the title: a remote tab's server mark first, then its host and folder.
            let detailHeight: CGFloat = Self.detailMetrics.height
            let detailY: CGFloat = Self.titleBaseline + Self.detailLeading - Self.detailMetrics.baseline
            let detailX: CGFloat = (remote ? Self.titleX + markSize.width + 3 : Self.titleX) + indent
            detail.frame = NSRect(x: detailX, y: detailY, width: max(0, hintEnd - detailX), height: detailHeight)
            let markY: CGFloat = detailY + detailHeight / 2 - 8
            remoteMark.frame = NSRect(x: Self.titleX + indent, y: markY, width: markSize.width, height: markSize.height)
        } else {
            remoteMark.frame = NSRect(x: columnX, y: lineMid - 8, width: markSize.width, height: markSize.height)
        }
        detail.isHidden = !twoLines || row.detail == nil
        // Over the title and the ×'s place.
        let fieldX: CGFloat = labelX - 3
        renameField?.frame = NSRect(x: fieldX, y: lineMid - 11, width: max(40, w - 6 - fieldX), height: 22)
        edge.frame = side.selectionEdge(rowWidth: w, rowHeight: h)
    }

    /// A remote tab too narrow for "web-1: app (connecting)" says less rather than "web-1: a…g)": first "web-1: "
    /// goes, then the note, leaving "app", as on the bar.
    private func fittedTitle(within width: CGFloat) -> String? {
        guard let row else { return nil }
        if fits(row.title, within: width) { return row.title }
        return row.shorterTitles.first { fits($0, within: width) } ?? row.shorterTitles.last ?? row.title
    }

    private func fits(_ title: String, within width: CGFloat) -> Bool {
        (title as NSString).size(withAttributes: [.font: Self.font]).width + 4 <= width
    }

    // MARK: mouse

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

    override func mouseDown(with event: NSEvent) {
        list?.rowMouseDown(self, event: event)
    }

    // Middle-click closes, like a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { list?.rowMiddleClicked(self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { list?.rowMenu(self) }

    /// VoiceOver's "show menu": the right-click menu, under the row.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = list?.rowMenu(self) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: bounds.height), in: self)
        return true
    }

    @objc private func closeClicked() {
        list?.rowClose(self)
    }

    override func accessibilityPerformPress() -> Bool {
        list?.rowPressed(self) ?? false
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard row?.isFolded == true else { return false }
        list?.rowFolds(self, open: true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard row?.isFolded == true else { return false }
        list?.rowFolds(self, open: false)
        return true
    }

    // MARK: rename

    var isEditing: Bool { renameField != nil }

    func beginRename() {
        guard renameField == nil, let row, !row.isPane else { return }
        let field = NSTextField(string: row.editableTitle ?? row.title)
        field.font = Self.font
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.placeholderString = "Tab name"
        field.usesSingleLineMode = true // a pasted line break becomes a space
        renameField = field
        label.isHidden = true
        updateCloseAndHint() // the × and the key make way for the field
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private var renameCancelled = false

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(nil) // ends editing -> controlTextDidEndEditing
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField else { return }
        renameField = nil
        let text = field.stringValue.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        label.isHidden = false
        updateCloseAndHint()
        if renameCancelled {
            renameCancelled = false
        } else {
            // An empty name goes back to the automatic title.
            list?.rowRenamed(self, to: text.isEmpty ? nil : text)
        }
        list?.rowEndedEditing(self)
    }

    // MARK: counting, for the self-test's budget

    #if DEBUG
    /// How often the row laid out, and how often its text drew (the row itself draws nothing).
    private(set) var layoutCount = 0
    var drawCount: Int { label.draws + detail.draws + hint.draws }

    func resetCounters() {
        layoutCount = 0
        label.draws = 0
        detail.draws = 0
        hint.draws = 0
    }
    #endif
}

/// A row's text. A debug build counts its draws, for the self-test's smoothness budget. Its Objective-C name stays
/// put, so the perf budget's shim finds it in a release build: the text is all a row draws.
@objc(NTTabListText)
final class TabListText: NSTextField {
    #if DEBUG
    var draws = 0

    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        super.draw(dirtyRect)
    }
    #endif
}
