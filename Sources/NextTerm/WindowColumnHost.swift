import AppKit
import NextTermCore

/// A terminal window's content: the window column at its outer edge, on the project sidebar's side, and the window's split
/// view [sidebar | work area] in the rest, mirrored with the sidebar on the right ([work area | sidebar | column]). The
/// split view itself does not change: it is pinned to the column's edge by constraints, as it was to the window's while it
/// was the content view, so when the column comes, goes or changes width its holding priorities give the whole change to
/// the work area. The sidebar keeps its width and each terminal resizes once, the column and the split view moving in the
/// same layout pass. (Framed by hand, a split view shares a change out among its panes, the sidebar too.)
///
/// How the column shows in this window is decided here, as the window's width changes and when what it is measured by
/// does (WindowColumnWidth.shown): unfolded while the editor and terminal keep their minimum beside the sidebar, folded
/// when they would not, hidden when even folded they would not. The user's choice is kept meanwhile.
final class WindowColumnHost: NSView {
    let column = WindowColumnView()
    let content: NSView

    /// Every window shows the column (WindowColumns: two or more windows, and the setting on).
    var visible = false
    /// The user's choice: unfolded in every window.
    var expanded = false
    /// At the window's right edge, as the sidebar is.
    var columnOnRight = false {
        didSet {
            guard columnOnRight != oldValue else { return }
            column.onRight = columnOnRight
            place()
        }
    }
    /// The sidebar's width with its divider, or 0 while it is hidden: what the room is measured beside.
    var sidebarWidth: () -> CGFloat = { 0 }
    /// How the column shows changed (hidden, folded, unfolded, for want of room or not): the window's insets follow.
    var onShownChange: ((WindowColumnShown) -> Void)?
    /// How the column shows now.
    private(set) var shown: WindowColumnShown = .hidden

    private var columnWidth: NSLayoutConstraint!
    private var columnAtLeft: NSLayoutConstraint!
    private var columnAtRight: NSLayoutConstraint!
    /// The split view's edges: in from the window's by the column's width on its side.
    private var contentLeading: NSLayoutConstraint!
    private var contentTrailing: NSLayoutConstraint!

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        columnWidth = column.widthAnchor.constraint(equalToConstant: 0)
        columnAtLeft = column.leadingAnchor.constraint(equalTo: leadingAnchor)
        columnAtRight = column.trailingAnchor.constraint(equalTo: trailingAnchor)
        contentLeading = content.leadingAnchor.constraint(equalTo: leadingAnchor)
        contentTrailing = content.trailingAnchor.constraint(equalTo: trailingAnchor)
        addSubview(content)
        column.isHidden = true
        addSubview(column)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentLeading, contentTrailing,
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            columnWidth, columnAtLeft,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window's width changed: the room is decided again before the layout pass places anything.
    override func setFrameSize(_ newSize: NSSize) {
        let resized: Bool = newSize.width != frame.width
        super.setFrameSize(newSize)
        if resized { place() }
    }

    /// How the column shows at the window's width now.
    func decide() -> WindowColumnShown {
        guard visible else { return .hidden }
        return WindowColumnWidth.shown(contentWidth: bounds.width, sidebarWidth: sidebarWidth(), expanded: expanded)
    }

    /// The column's width and side, and the split view's edges, as decided now; the next layout pass moves them together.
    /// Nothing changes when nothing would.
    func place() {
        let decided: WindowColumnShown = decide()
        let width: CGFloat = decided.width
        set(columnWidth, width)
        set(contentLeading, columnOnRight ? 0 : width)
        set(contentTrailing, columnOnRight ? -width : 0)
        if columnAtLeft.isActive == columnOnRight {
            // One off before the other on: both at once cannot be met.
            if columnOnRight {
                columnAtLeft.isActive = false
                columnAtRight.isActive = true
            } else {
                columnAtRight.isActive = false
                columnAtLeft.isActive = true
            }
        }
        if column.isHidden != (width == 0) { column.isHidden = width == 0 }
        guard decided != shown else { return }
        shown = decided
        onShownChange?(decided)
    }

    private func set(_ constraint: NSLayoutConstraint, _ constant: CGFloat) {
        if constraint.constant != constant { constraint.constant = constant }
    }
}
