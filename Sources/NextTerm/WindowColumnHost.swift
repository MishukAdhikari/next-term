import AppKit
import NextTermCore

/// A terminal window's content: the window column at its outer edge, on the project sidebar's side, and the window's split
/// view [sidebar | work area] in the rest, mirrored with the sidebar on the right ([work area | sidebar | column]). The
/// split view itself does not change: when the column comes, goes or changes width, the split view is resized, and its
/// holding priorities give the whole change to the work area, so the sidebar keeps its width and each terminal resizes
/// once. Both frames change in the same pass, with implicit animations off.
///
/// How the column shows in this window is decided here, on every layout (a window resize included), by its room
/// (WindowColumnWidth.shown): unfolded while the editor and terminal keep their minimum beside the sidebar, folded when
/// they would not, hidden when even folded they would not. The user's choice is kept meanwhile.
final class WindowColumnHost: NSView {
    let column = WindowColumnView()
    let content: NSView

    /// Every window shows the column (WindowColumns: two or more windows, and the setting on).
    var visible = false {
        didSet { if visible != oldValue { needsLayout = true } }
    }
    /// The user's choice: unfolded in every window.
    var expanded = false {
        didSet { if expanded != oldValue { needsLayout = true } }
    }
    /// At the window's right edge, as the sidebar is.
    var columnOnRight = false {
        didSet {
            guard columnOnRight != oldValue else { return }
            column.onRight = columnOnRight
            needsLayout = true
        }
    }
    /// The sidebar's width with its divider, or 0 while it is hidden: what the room is measured beside.
    var sidebarWidth: () -> CGFloat = { 0 }
    /// How the column shows changed (hidden, folded, unfolded, for want of room or not): the window's insets follow.
    var onShownChange: ((WindowColumnShown) -> Void)?
    /// How the column shows now.
    private(set) var shown: WindowColumnShown = .hidden

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        autoresizesSubviews = true
        content.autoresizingMask = []
        addSubview(content)
        column.isHidden = true
        addSubview(column)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Its own frames for both, never the autoresizing mask's: one change each, in one pass.
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    override func layout() {
        super.layout()
        place()
    }

    /// How the column shows at the window's width now.
    func decide() -> WindowColumnShown {
        guard visible else { return .hidden }
        return WindowColumnWidth.shown(contentWidth: bounds.width, sidebarWidth: sidebarWidth(), expanded: expanded)
    }

    /// The column and the split view where they go now. Nothing moves when nothing changed.
    func place() {
        let decided: WindowColumnShown = decide()
        let width: CGFloat = decided.width
        let height: CGFloat = bounds.height
        let columnFrame = NSRect(x: columnOnRight ? bounds.width - width : 0, y: 0, width: width, height: height)
        let contentFrame = NSRect(x: columnOnRight ? 0 : width, y: 0, width: max(0, bounds.width - width), height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if column.isHidden != (width == 0) { column.isHidden = width == 0 }
        if width > 0, column.frame != columnFrame { column.frame = columnFrame }
        if content.frame != contentFrame { content.frame = contentFrame }
        CATransaction.commit()
        guard decided != shown else { return }
        shown = decided
        onShownChange?(decided)
    }
}
