import AppKit
import CoreText
import NextTermCore

/// The suggestion while typing, drawn over the terminal (a subview of NextTermView, at the bottom of its subviews, under
/// SwiftTerm's caret) at the terminal's cells, in its font, from the cursor's cell: never text in the grid, so nothing
/// that reads the terminal (copy, Find, MCP, the scrollback saved at quit, VoiceOver) ever finds it. A click goes through
/// it to the terminal. Its ObjC name is stable for the perf budget's shim, which stamps `ghostShown(_:)` and its drawing.
@objc(NTGhostText)
final class GhostTextView: NSView {
    private(set) var text = ""
    /// The cells each character takes.
    private var widths: [Int] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var colour = NSColor.gray
    private var underline = false
    private var cell = CGSize(width: 8, height: 16)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Shows `text`, fitted already (GhostClip), with its first cell at `origin` (the cursor's, in the terminal's
    /// coordinates): `cell` is the terminal's cell, and the baseline is SwiftTerm's, its font's descent and leading above the
    /// cell's bottom.
    func show(_ text: String, at origin: CGPoint, cell: CGSize, font: NSFont, colour: NSColor, underline: Bool) {
        let widths = text.map(GhostClip.cells)
        let frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(widths.reduce(0, +)) * cell.width, height: cell.height)
        let same = text == self.text && frame == self.frame && font == self.font && colour == self.colour && underline == self.underline
        self.text = text
        self.widths = widths
        self.cell = cell
        self.font = font
        self.colour = colour
        self.underline = underline
        if self.frame != frame { self.frame = frame }
        isHidden = false
        if !same { needsDisplay = true }
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        text = ""
    }

    /// Called once a suggestion is placed, with the uptime the shell's report it answers was read at: the perf budget's
    /// stamp (its shim swizzles it). Nothing is counted here.
    @objc dynamic func ghostShown(_ arrival: Double) {}

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let baseline = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        context.saveGState()
        context.textMatrix = .identity
        var column = 0
        for (character, width) in zip(text, widths) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))
            context.textPosition = CGPoint(x: CGFloat(column) * cell.width, y: baseline)
            CTLineDraw(line, context)
            column += width
        }
        if underline {
            // Differentiate Without Colour: a dotted line under it says it isn't typed.
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1, 2])
            let y = max(0.5, baseline - 1.5)
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(column) * cell.width, y: y))
            context.strokePath()
        }
        context.restoreGState()
    }
}

