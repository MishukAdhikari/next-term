import AppKit
import NextTermCore

/// A badge that opens a page in the browser: "Neon", "Herd", ":5173". Drawn as the rows' other badges are (BadgeView),
/// but a button, so a click on it opens its page and leaves the row's selection alone, as the ⋯ button does. The pointer
/// is a hand over it, and VoiceOver reads it as a link in its tooltip's words. With no page it is a label, and a click
/// on it is a click on the row. Its tooltip comes from the outline's one tooltip owner (`tip`), never `toolTip`: a view's
/// own stays live for a row scrolled out of sight.
final class LinkBadge: NSButton {
    private(set) var word = ""
    private(set) var link: ServiceLink?
    private let wordFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    init() {
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        title = ""
        // The rows keep the keyboard, so ⌘↓ and the arrows still answer after a click on a badge (with Keyboard
        // navigation on, a click would focus it). The menu's Open Service Page is the keyboard's way to the page.
        refusesFirstResponder = true
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ badge: ServiceBadge) {
        word = badge.word
        link = badge.link
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The page it opens, as the pointer shows it: "Open Neon Console: project cold-grass-40154007". Nil for a label.
    var tip: String? { link?.tooltip }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard !word.isEmpty else { return .zero }
        let size = (word as NSString).size(withAttributes: [.font: wordFont])
        return NSSize(width: ceil(size.width) + 10, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !word.isEmpty else { return }
        // Pressed, it darkens, as a link does while the click is down.
        let pressed = isHighlighted && link != nil
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        Theme.textDim.withAlphaComponent(pressed ? 0.8 : 0.45).setStroke()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        path.stroke()
        let color = pressed ? Theme.text : Theme.textDim
        let size = (word as NSString).size(withAttributes: [.font: wordFont])
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (word as NSString).draw(at: origin, withAttributes: [.font: wordFont, .foregroundColor: color])
    }

    /// A label takes no click: the row under it does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        link == nil ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        if link != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // Its stack lays it out by hand: the hand cursor moves with it.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    @objc private func clicked() {
        guard let link, !Self.isRepeatClick(NSApp.currentEvent) else { return }
        ServiceLinks.open(link.url, from: window)
    }

    /// The second click of a double-click, from the rows' habit of double-clicking: the page opens once. Only a mouse
    /// event has a click count; VoiceOver's press has none.
    private static func isRepeatClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseUp || event.type == .leftMouseDown else { return false }
        return event.clickCount > 1
    }

    override func isAccessibilityElement() -> Bool { !word.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { link == nil ? .staticText : .link }
    override func accessibilityLabel() -> String? { link?.tooltip ?? word }
}

/// A row's badges side by side, 4 pt apart, its trailing edge where the row puts it: a database row's providers
/// ("Neon", "Vercel"), each its own link, or a service's one. Its `text` is their words as one string.
final class LinkBadgeStack: NSView {
    static let gap: CGFloat = 4
    private(set) var badges: [LinkBadge] = []
    private var shown: [ServiceBadge] = []

    /// "Neon · Vercel": what the badges read, side by side.
    var text: String { ServiceBadge.text(shown) }

    func show(_ items: [ServiceBadge]) {
        isHidden = items.isEmpty
        guard items != shown else { return }
        shown = items
        while badges.count < items.count {
            let badge = LinkBadge()
            addSubview(badge)
            badges.append(badge)
        }
        while badges.count > items.count { badges.removeLast().removeFromSuperview() }
        for (badge, item) in zip(badges, items) { badge.show(item) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        guard !badges.isEmpty else { return .zero }
        let widths = badges.map { (badge: LinkBadge) -> CGFloat in badge.intrinsicContentSize.width }
        let gaps = Self.gap * CGFloat(badges.count - 1)
        return NSSize(width: widths.reduce(0, +) + gaps, height: 15)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for badge in badges {
            let width = badge.intrinsicContentSize.width
            badge.frame = NSRect(x: x, y: ((bounds.height - 15) / 2).rounded(), width: width, height: 15)
            x += width + Self.gap
        }
    }

    /// The tooltip of the badge under `point` (in this view's coordinates), when it opens a page.
    func tip(at point: NSPoint) -> String? {
        guard !isHidden else { return nil }
        return badges.first { (badge: LinkBadge) -> Bool in badge.link != nil && badge.frame.contains(point) }?.tip
    }
}
