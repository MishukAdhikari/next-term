import AppKit
import NextTermCore

/// The terminal folded away beside the editor: a slim bar at the window's edge with the arrow that brings
/// it back, and under it each tab's status mark, so an agent finishing or asking is still seen. A click
/// on a mark opens that tab; anywhere else on the rail, the terminal at its size.
final class TerminalRail: NSView {
    static let width: CGFloat = 24
    private static let slotHeight: CGFloat = 24

    /// One terminal tab, as its mark on the rail.
    struct Mark: Equatable {
        /// The tab (its pane group), so a change is told from a tab moving or closing.
        var id: ObjectIdentifier
        var state: TabState
        /// Its title and state: "claude" over "Done", or a split tab's panes line by line.
        var toolTip: String
        /// "claude, Done".
        var label: String
        var selected: Bool
    }

    var onExpand: (() -> Void)?
    /// A mark was clicked: the index of its tab.
    var onSelect: ((Int) -> Void)?

    /// The arrow points into the window: left with the rail at the window's right edge.
    var pointsLeft = true { didSet { needsDisplay = true } }
    /// Room left at the top for the traffic lights, when the rail is at the window's top-left corner.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// The most urgent first, as the tab bar's » button has it.
    private static let urgency: [TabState] = [.attention, .failed, .done, .working]

    private(set) var marks: [Mark] = []
    private var markViews: [RailMarkButton] = []
    /// "+3": the tabs there is no room for. A click opens the terminal.
    private let moreButton = HoverButton()
    private let glow = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { needsDisplay = true } }
    /// A press that began on the rail itself (not on the title bar strip): letting go inside opens the terminal.
    private var tracking = false

    /// Reduce Motion as System Settings has it; the self-test stands in for the setting.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Tabs that became done, failed or needs-you while the rail showed (for the self-test).
    private(set) var changesNoticed = 0
    /// "Expand the terminal (⌘J)", with the key Settings gives it.
    private var expandTip: ShortcutToolTip?
    /// "⌘J" just under the arrow, as a tab shows "⌘1", while every mark keeps its place below it.
    private lazy var expandHint = KeyHint(#selector(TerminalWindowController.toggleTerminalCollapsed(_:)), for: nil)
    /// The hint's height while it shows: the marks start that much lower.
    private var hintRow: CGFloat = 0
    /// The arrow's key as it shows now, nil once it gave way (for the self-test).
    var shownKey: String? {
        layoutSubtreeIfNeeded()
        return expandHint.shownKey
    }
    /// The states each tab pulsed for since the rail showed: an agent that goes done, working, done again
    /// (pauses in its output) pulses once, not every few seconds.
    private var pulsedFor: [ObjectIdentifier: Set<TabState>] = [:]
    var isPulsing: Bool { glow.animation(forKey: "pulse") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.opacity = 0
        layer?.addSublayer(glow)
        moreButton.isBordered = false
        moreButton.bezelStyle = .regularSquare
        moreButton.target = self
        moreButton.action = #selector(expandClicked)
        moreButton.isHidden = true
        addSubview(moreButton)
        addSubview(expandHint)
        expandTip = ShortcutToolTip(self, "Expand the terminal", #selector(TerminalWindowController.toggleTerminalCollapsed(_:)))
        // A group, not a button: VoiceOver does not go into a button, and the tabs' buttons are in here.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal, folded")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Called several times a second: only a change touches the views. A tab that turns done, failed or
    /// needs-you while the rail shows makes it pulse a few times, once for each state; then it stays still
    /// with the mark.
    func update(marks newMarks: [Mark]) {
        guard newMarks != marks else { return }
        let before = Dictionary(marks.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let urgent: [TabState] = [.done, .failed, .attention]
        let news = newMarks.filter {
            urgent.contains($0.state) && $0.state != (before[$0.id] ?? .idle) && pulsedFor[$0.id]?.contains($0.state) != true
        }
        if newMarks.count != markViews.count {
            let ids = Set(newMarks.map(\.id))
            pulsedFor = pulsedFor.filter { ids.contains($0.key) } // a closed tab's id may come back for a new one
            markViews.forEach { $0.removeFromSuperview() }
            markViews = newMarks.indices.map { _ in
                let view = RailMarkButton()
                view.target = self
                view.action = #selector(markClicked(_:))
                addSubview(view)
                return view
            }
            needsLayout = true
        }
        for (view, mark) in zip(markViews, newMarks) { view.configure(mark) }
        marks = newMarks
        updateMoreButton()
        if !isHidden, let state = Self.urgency.first(where: news.map(\.state).contains) {
            for mark in news { pulsedFor[mark.id, default: []].insert(mark.state) }
            changesNoticed += 1
            pulse(StatusGlyph.color(for: state))
        }
    }

    private func pulse(_ color: NSColor) {
        guard !Self.reducesMotion() else { return } // the mark just appears
        glow.backgroundColor = color.withAlphaComponent(0.3).cgColor
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.4
        animation.autoreverses = true
        animation.repeatCount = 3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(animation, forKey: "pulse")
    }

    /// The terminal opened: the next fold pulses afresh.
    func stopPulse() {
        glow.removeAnimation(forKey: "pulse")
        pulsedFor = [:]
    }

    // MARK: layout

    /// Where the marks start: under the arrow, which sits in the tab bars' strip along the top, and its key.
    private var marksTop: CGFloat { topInset + TabBarView.height + 4 + hintRow }

    /// The key shows under the arrow only if it fits across the rail and every mark shown without it still is.
    private func placeExpandHint() {
        let height = ceil(expandHint.intrinsicContentSize.height)
        hintRow = 0
        let without = shownCount
        hintRow = height
        let fits = !expandHint.key.isEmpty && expandHint.keyWidth <= bounds.width - 2 && shownCount == without
        hintRow = fits ? height : 0
        expandHint.isHidden = !fits
        let width = expandHint.keyWidth
        expandHint.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: topInset + TabBarView.height + 2, width: width, height: height)
    }

    /// How many marks fit; when some do not, the last place is the "+3".
    private var shownCount: Int {
        let room = Int(max(0, bounds.height - marksTop - 4) / Self.slotHeight)
        return markViews.count <= room ? markViews.count : max(0, room - 1)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
        placeExpandHint()
        let shown = shownCount
        for (i, view) in markViews.enumerated() {
            view.isHidden = i >= shown
            view.frame = NSRect(x: 0, y: marksTop + CGFloat(i) * Self.slotHeight, width: bounds.width, height: Self.slotHeight)
        }
        moreButton.frame = NSRect(x: 0, y: marksTop + CGFloat(shown) * Self.slotHeight, width: bounds.width, height: Self.slotHeight)
        updateMoreButton()
    }

    /// The hidden tabs' count, in the colour of the most urgent of them.
    private func updateMoreButton() {
        let hidden = Array(marks.dropFirst(shownCount))
        moreButton.isHidden = hidden.isEmpty
        guard !hidden.isEmpty else { return }
        let state = Self.urgency.first(where: hidden.map(\.state).contains) ?? .idle
        let color = state == .idle || state == .working ? Theme.textDim : StatusGlyph.color(for: state)
        moreButton.attributedTitle = NSAttributedString(string: "+\(hidden.count)", attributes: [
            .foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        ])
        let tip = "\(hidden.count) more tab\(hidden.count == 1 ? "" : "s"): " + hidden.map(\.label).joined(separator: "; ")
        if moreButton.toolTip != tip { moreButton.toolTip = tip }
        moreButton.setAccessibilityLabel(tip)
    }

    override func draw(_ dirtyRect: NSRect) {
        (pressed ? Theme.background : hovering ? Theme.tabHover : Theme.bar).setFill()
        bounds.fill()
        // The tab bars' bottom line runs on across the rail.
        Theme.border.setFill()
        NSRect(x: 0, y: TabBarView.height - 1, width: bounds.width, height: 1).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [hovering ? Theme.text : Theme.textDim]))
        guard let chevron = NSImage(systemSymbolName: pointsLeft ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = chevron.size
        let origin = NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: (topInset + (TabBarView.height - size.height) / 2).rounded())
        chevron.draw(in: NSRect(origin: origin, size: size))
    }

    // MARK: mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { hovering = false }
    private func hover(_ event: NSEvent) { hovering = !isTitleBar(convert(event.locationInWindow, from: nil)) }
    // Gone with the pointer on it (a click opened the terminal): next time it starts plain.
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        pressed = false
        tracking = false
    }

    /// Under the traffic lights the strip above the arrow is title bar: it moves the window, as the tab bars do.
    func isTitleBar(_ point: NSPoint) -> Bool { point.y < topInset }

    // Like a button: it opens on letting go inside, so a press can still be dragged away.
    override func mouseDown(with event: NSEvent) {
        if isTitleBar(convert(event.locationInWindow, from: nil)) { return TabBarView.titleBarMouseDown(event, in: window) }
        tracking = true
        pressed = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        tracking = false
        pressed = false
        if inside { onExpand?() }
    }

    // MARK: VoiceOver

    /// The arrow at the top as VoiceOver finds it: the Expand terminal button, then each tab's.
    private lazy var expandElement = RailExpandElement(rail: self)
    /// The arrow's place along the top, under the traffic lights' strip when there is one.
    fileprivate var arrowRect: NSRect { NSRect(x: 0, y: topInset, width: bounds.width, height: TabBarView.height) }

    override func accessibilityChildren() -> [Any]? {
        var buttons: [NSView] = markViews.filter { !$0.isHidden }
        if !moreButton.isHidden { buttons.append(moreButton) }
        // A button view is not what VoiceOver reads (its cell is): the unignored ones stand in for them.
        return [expandElement] + NSAccessibility.unignoredChildren(from: buttons)
    }

    @objc fileprivate func expandClicked() { onExpand?() }

    @objc private func markClicked(_ sender: NSButton) {
        guard let index = markViews.firstIndex(where: { $0 === sender }) else { return }
        onSelect?(index)
    }

    /// For the self-test: a click on the mark of tab `index`.
    func clickMark(_ index: Int) { markViews[safe: index]?.performClick(nil) }
    /// The marks' buttons as VoiceOver finds them.
    var markButtons: [NSButton] { markViews }
    /// For the self-test: the "+3" in the last place.
    var overflowButton: NSButton { moreButton }
}

/// The rail's arrow for VoiceOver: a button of its own beside the tabs' buttons, which a click anywhere on
/// the rail stands in for with the mouse.
private final class RailExpandElement: NSAccessibilityElement {
    private weak var rail: TerminalRail?

    init(rail: TerminalRail) {
        self.rail = rail
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Expand terminal" }
    override func accessibilityHelp() -> String? {
        KeyboardShortcuts.shared.hint("Brings the terminal back at its size", #selector(TerminalWindowController.toggleTerminalCollapsed(_:))) + "."
    }
    override func accessibilityParent() -> Any? { rail }
    override func accessibilityFrame() -> NSRect {
        guard let rail else { return .zero }
        return NSAccessibility.screenRect(fromView: rail, rect: rail.arrowRect)
    }
    override func accessibilityPerformPress() -> Bool {
        rail?.expandClicked()
        return rail != nil
    }
}

/// One tab on the rail: its status mark, the selected tab's on a darker place, as in the tab bar.
private final class RailMarkButton: NSButton {
    private let dot = StatusDotView()
    private var mark: TerminalRail.Mark?
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        dot.pulsesForAttention = false // the rail pulsed once; after that the mark stays still
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(_ newMark: TerminalRail.Mark) {
        guard newMark != mark else { return }
        dot.state = newMark.state
        if toolTip != newMark.toolTip { toolTip = newMark.toolTip } // re-setting a tooltip resets it
        setAccessibilityLabel(newMark.label)
        setAccessibilitySelected(newMark.selected)
        mark = newMark
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: ((bounds.width - 10) / 2).rounded(), y: ((bounds.height - 10) / 2).rounded(), width: 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let place = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4)
        if mark?.selected == true {
            Theme.background.setFill()
            place.fill()
        }
        if hovering || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            place.fill()
        }
        // An idle tab has no mark in the tab bar; here it still needs something to see and click.
        if mark?.state == .idle {
            Theme.textDim.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
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

    /// Clicks on the mark itself are the button's.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    // VoiceOver reads the button itself (not its cell, as for other buttons), the tab and its state: the mark
    // inside is drawn, not a picture to stop on.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityChildren() -> [Any]? { nil }
    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }
}
