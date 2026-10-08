import AppKit
import NextTermCore

// The place mark in the window: the hollow branch glyph after a tab's title (tab bar and pane headers), and
// the sidebar header's "this tab: fix/7027-sso" while the focused tab is marked. Where agents work comes
// from AgentPlaces. Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R7–R11, R17).

// MARK: - the mark in the window

extension TerminalWindowController {
    /// The tab bar's items with their place marks: a split tab shows its keyboard pane's, else another pane's.
    func placeMarked(_ items: [TabBarItem]) -> [TabBarItem] {
        zip(items, groups).map { item, group in
            var item = item
            let panes = [group.focused] + group.panes.filter { $0 !== group.focused }
            item.place = panes.lazy.compactMap { self.placeFacts(of: $0) }.first
            return item
        }
    }

    /// What `tab`'s mark says (the tooltip, and VoiceOver); nil without a mark.
    func placeFacts(of tab: TerminalTab) -> String? {
        AgentPlaces.shared.mark(for: tab, in: self).map { $0.facts(agent: AgentName.of(program: tab.status.program), when: { SessionStore.when($0) }) }
    }

    /// The sidebar header's "this tab: fix/7027-sso" while the focused tab is marked.
    func updateTabPlace() {
        let header = sidebar.header
        if header.onTabPlaceClick == nil { header.onTabPlaceClick = { [weak self] in self?.showPlaceChoices() } }
        guard let tab = activeTab, let mark = AgentPlaces.shared.mark(for: tab, in: self) else { return header.showTabPlace(nil) }
        let facts = mark.facts(agent: AgentName.of(program: tab.status.program), when: { SessionStore.when($0) })
        header.showTabPlace(TabPlace(label: mark.label, facts: facts, hasChoices: mark.switched != nil))
    }

    /// A click on the header's label: for a branch switched under the focused tab's chat, Keep Going, and Go to
    /// That Tab when another tab made the switch.
    func showPlaceChoices() {
        guard let tab = activeTab, let mark = AgentPlaces.shared.mark(for: tab, in: self), let switched = mark.switched else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addBlock("Keep Going on \(switched.to.name)") { AgentPlaces.shared.keepGoing(tab) }
        if let key = switched.by.tabKey, let app = AppDelegate.shared,
           let owner = app.controllers.first(where: { $0.tabs.contains { $0.id.uuidString == key } }),
           let other = owner.tabs.first(where: { $0.id.uuidString == key }) {
            menu.addBlock("Go to That Tab (“\(other.title)”)") {
                owner.show(other)
                owner.window?.makeKeyAndOrderFront(nil)
            }
        }
        sidebar.header.popUpTabPlaceMenu(menu)
    }
}

// MARK: - the glyph

/// The place mark: a branch with hollow nodes, in the dim text colour, after a tab's title. One sign for an
/// agent elsewhere and a branch switched under a chat; never red and never blinking, and its words are in
/// the tooltip and VoiceOver, so it never relies on colour.
enum PlaceGlyph {
    static func image(size: CGFloat = 11) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let k = size / 12
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
            let path = NSBezierPath()
            path.lineWidth = 1.2 * k
            path.lineCapStyle = .round
            for (x, y) in [(3.5, 2.5), (3.5, 9.5), (8.5, 9.5)] {
                path.appendOval(in: NSRect(x: (x - 1.7) * k, y: (y - 1.7) * k, width: 3.4 * k, height: 3.4 * k))
            }
            path.move(to: point(3.5, 4.2))
            path.line(to: point(3.5, 7.8))
            path.move(to: point(8.5, 7.8))
            path.curve(to: point(3.5, 4.6), controlPoint1: point(8.5, 5.8), controlPoint2: point(3.5, 6.6))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Branch mark"
        return image
    }
}

/// What the sidebar header says about the focused tab's place.
struct TabPlace: Equatable {
    /// "this tab: fix/7027-sso", "chat was on fix/7611-3ds".
    let label: String
    /// The whole story, for the tooltip and VoiceOver.
    let facts: String
    /// A click offers Keep Going (a branch switched under the chat).
    let hasChoices: Bool
}

/// The sidebar header's label after the branch: the glyph and "this tab: fix/7027-sso", cut in the middle,
/// down to the glyph alone when the header is narrow. The full text is in its tooltip.
final class TabPlaceView: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var place: TabPlace?
    var onClick: (() -> Void)?
    /// The glyph alone: no room for the words.
    var compact = false { didSet { if compact != oldValue { label.isHidden = compact; needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.image = PlaceGlyph.image(size: 13)
        glyph.contentTintColor = Theme.textDim
        glyph.imageScaling = .scaleNone
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = Theme.textDim
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        label.setAccessibilityElement(false)
        glyph.setAccessibilityElement(false)
        [glyph, label].forEach(addSubview)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ place: TabPlace) {
        guard place != self.place else { return }
        self.place = place
        label.stringValue = place.label
        toolTip = place.facts + (place.hasChoices ? "\nClick for Keep Going." : "")
        setAccessibilityRole(place.hasChoices ? .button : .staticText)
        setAccessibilityLabel(place.facts)
        needsLayout = true
    }

    /// The glyph, a gap and the words in full.
    var fullWidth: CGFloat { 14 + 3 + ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) + 1 }
    static let glyphWidth: CGFloat = 14
    /// The words as shown ("" with the glyph alone), for the self-test.
    var shownText: String { label.isHidden ? "" : label.stringValue }
    var isTruncated: Bool {
        layoutSubtreeIfNeeded()
        return !label.isHidden && label.cell?.expansionFrame(withFrame: label.bounds, in: label) != .zero
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        glyph.frame = NSRect(x: 0, y: (h - 14) / 2, width: 14, height: 14)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 17, y: (h - labelHeight) / 2, width: max(0, bounds.width - 17), height: labelHeight)
    }

    override func mouseDown(with event: NSEvent) {
        if place?.hasChoices == true, let onClick { return onClick() }
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if place?.hasChoices == true { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard place?.hasChoices == true, let onClick else { return false }
        onClick()
        return true
    }
}
