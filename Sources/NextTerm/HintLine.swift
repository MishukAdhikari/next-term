import AppKit
import NextTermCore

/// One hint as a line of chrome (plan 033 R2): its words, small and in the secondary colour, or for a hint that does
/// something a real borderless button with those words, and a small × that closes it for good, there while the pointer
/// is on the line. In the window column (its open list, or the pinned column) it sits on the column's grid, its words at
/// the names' x; beside the rail it lies over the content's edge on a plate of the column's own colour, so it reads as
/// part of the column; in a tab bar's free room it has no plate, the bar being chrome already. It never takes the keyboard and posts no announcement: VoiceOver finds it where it is, its words
/// as static text and as help. It comes in over 150 ms, at once with Reduce Motion; with Increase Contrast its words are
/// in the label colour.
final class HintLine: NSView {
    let hint: Hint
    /// What it says, as shown.
    let words: String
    /// A hint that does something: its button. Else nil, and `label` says the words.
    private(set) var button: NSButton?
    private(set) var label: NSTextField?
    let closeButton = HoverButton()
    /// Its × was clicked.
    var onClose: (() -> Void)?
    /// Where a line sits, which decides its plate and where its words start.
    enum Place {
        /// On the window column's grid (its list's foot, or the pinned column's): the words at the names' x.
        case grid
        /// Beside the rail, over the content's edge, on a plate of the column's colour.
        case beside
        /// In a tab bar's free room: no plate, the words at the inset.
        case bar
    }

    var place: Place = .grid {
        didSet { if place != oldValue { restyle() } }
    }
    var beside: Bool { place == .beside }
    /// It may go beside the rail when the pinned column's foot is too narrow: not a hint whose feature lives in the
    /// unfolded rows (H8).
    var mayGoBeside = true
    /// In a column at the window's right edge: the grid's names start from its inner edge.
    var onRight = false {
        didSet { if onRight != oldValue { needsLayout = true } }
    }
    /// The pointer is on it: the × shows, and a button's words brighten.
    private(set) var hovering = false {
        didSet { if hovering != oldValue { restyle() } }
    }

    static let font = NSFont.systemFont(ofSize: 11)
    /// A row of the column's grid would be 32: the line is quieter, and the rows give up less room for it.
    static let height: CGFloat = 24
    private static let closeSize: CGFloat = 16
    /// Beside the rail and in a bar: the words' inset from the line's edges.
    private static let inset: CGFloat = 10

    /// The words' colour: the secondary one, the label colour with Increase Contrast, and a button's under the pointer.
    private var wordsColor: NSColor {
        if DisplayOptions.increasesContrast || (button != nil && hovering) { return Theme.text }
        return Theme.textDim
    }

    /// A passive hint: `words`, read as they are, and `help` as its tooltip and VoiceOver help when it has more to say.
    convenience init(_ hint: Hint, words: String, help: String? = nil) {
        self.init(hint, words: words, help: help, action: nil)
    }

    /// A hint with `action`: a real button saying `words`, its tooltip and VoiceOver help `help`.
    init(_ hint: Hint, words: String, help: String?, action: (() -> Void)?) {
        self.hint = hint
        self.words = words
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        if action != nil {
            let made = NSButton(title: words, target: self, action: #selector(pressed))
            made.isBordered = false
            made.bezelStyle = .regularSquare
            made.alignment = .left
            made.refusesFirstResponder = true
            made.toolTip = help
            made.setAccessibilityHelp(help)
            (made.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            addSubview(made)
            button = made
        } else {
            let made = NSTextField(labelWithString: words)
            made.font = Self.font
            made.lineBreakMode = .byTruncatingTail
            made.refusesFirstResponder = true
            made.setAccessibilityRole(.staticText)
            made.setAccessibilityHelp(help ?? words)
            made.toolTip = help
            addSubview(made)
            label = made
        }
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: HintWords.close)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.refusesFirstResponder = true
        closeButton.toolTip = HintWords.close
        closeButton.setAccessibilityLabel(HintWords.close)
        closeButton.target = self
        closeButton.action = #selector(closed)
        // There for VoiceOver and a click at all times, seen only while the pointer is on the line.
        closeButton.alphaValue = 0
        addSubview(closeButton)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private let action: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// The words' width as drawn: their cell's, with its padding (a label's intrinsic width can be short of it), so whole
    /// words are never cut.
    var wordsWidth: CGFloat {
        ceil(((button ?? label) as NSControl?)?.cell?.cellSize.width ?? 0)
    }

    /// Whether its words show whole in the room layout gave them (the self-test's check).
    var wordsWhole: Bool { ((button ?? label)?.frame.width ?? 0) >= wordsWidth }

    /// Beside the rail or in a bar: as wide as its words, its × and their insets.
    var ownWidth: CGFloat { Self.inset + wordsWidth + 4 + Self.closeSize + 6 }

    /// Whether its words fit whole on one line of the column's grid in a strip `width` across.
    func fits(width: CGFloat) -> Bool {
        let start: CGFloat = WindowColumnGrid.nameX(width: width, onRight: onRight, depth: 0)
        let end: CGFloat = WindowColumnGrid.trailingEnd(width: width, onRight: onRight)
        return start + wordsWidth + 4 + Self.closeSize <= end
    }

    override func layout() {
        super.layout()
        let start: CGFloat, end: CGFloat
        if place != .grid {
            start = Self.inset
            end = bounds.width - 6
        } else {
            start = WindowColumnGrid.nameX(width: bounds.width, onRight: onRight, depth: 0)
            end = WindowColumnGrid.trailingEnd(width: bounds.width, onRight: onRight)
        }
        let close = NSRect(x: end - Self.closeSize, y: ((bounds.height - Self.closeSize) / 2).rounded(), width: Self.closeSize, height: Self.closeSize)
        if closeButton.frame != close { closeButton.frame = close }
        let text: NSView? = button ?? label
        let height: CGFloat = ceil(Self.font.ascender - Self.font.descender) + 2
        let frame = NSRect(x: start, y: ((bounds.height - height) / 2).rounded(), width: max(0, close.minX - 4 - start), height: height)
        if let text, text.frame != frame { text.frame = frame }
    }

    /// Its words', its ×'s and its plate's look, for where it is and the pointer.
    private func restyle() {
        let color: NSColor = wordsColor
        if let button {
            button.attributedTitle = NSAttributedString(string: words, attributes: [
                .font: Self.font, .foregroundColor: color, .paragraphStyle: Typography.paragraph(.byTruncatingTail),
            ])
        }
        label?.textColor = color
        closeButton.contentTintColor = color
        closeButton.alphaValue = hovering ? 1 : 0
        layer?.backgroundColor = beside ? Theme.bar.cgColor : nil
        layer?.cornerRadius = beside ? 6 : 0
        layer?.borderWidth = beside ? 1 : 0
        layer?.borderColor = (DisplayOptions.increasesContrast ? Theme.textDim : Theme.border).cgColor
        needsLayout = true
    }

    /// Increase Contrast changed.
    func contrastChanged() { restyle() }

    /// It comes in: over 150 ms, or at once with Reduce Motion.
    func appear() {
        guard !WindowColumnHost.reducesMotion() else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// The pointer came onto it: a tab bar, whose title-bar band may send no exit, watches it from then on.
    var onPointerCame: (() -> Void)?

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onPointerCame?()
    }

    /// Where the pointer is, as a tab bar watching it sees it.
    func pointer(on: Bool) { hovering = on }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    #if DEBUG
    /// The pointer on it, for the self-test, whose own pointer never moves.
    func setHoveringForTest(_ on: Bool) { hovering = on }
    #endif

    @objc private func pressed() { action?() }
    @objc private func closed() { onClose?() }

    // A container: VoiceOver reads its words (or its button) and its ×, never the line itself.
    override func isAccessibilityElement() -> Bool { false }
}
