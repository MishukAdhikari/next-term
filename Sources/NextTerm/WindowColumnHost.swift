import AppKit
import NextTermCore

/// A terminal window's content: the window column at its outer edge, on the project sidebar's side, and the window's split
/// view [sidebar | work area] in the rest, mirrored with the sidebar on the right ([work area | sidebar | column]). The
/// split view itself does not change. A split view shares any change of its width out among its panes, as a window's
/// resize does, so when the column comes, goes or changes width the window puts the sidebar back at the width it had
/// (`aroundColumnChange`), at once and before anything is laid out: the work area takes the whole change and each
/// terminal resizes once. The column and the split view move in the same pass, with implicit animations off.
///
/// How the column shows in this window is decided here, on every resize of the window and when what it is measured by
/// changes (WindowColumnWidth.shown): unfolded while the editor and terminal keep their minimum beside the sidebar as it
/// is, folded when they would not but do beside a minimal sidebar, hidden when even folded they would not. The user's
/// choice is kept meanwhile. A resize of the window is shared out first, as the split view shares any; only then does the
/// column change width, so the window puts the sidebar back where the resize alone left it.
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
            place(force: true)
        }
    }
    /// The room the sidebar takes in the measure, with its divider, 0 while it is hidden: as it is, which the unfolded
    /// column is measured beside, and a minimal sidebar's, which the folded one is, as a narrowing window narrows the
    /// sidebar toward it.
    var sidebarRoom: () -> (shown: CGFloat, minimal: CGFloat) = { (0, 0) }
    /// Wraps a change of the column's width (not the window's): the window notes the sidebar's width, the frames change,
    /// and it puts the sidebar back.
    var aroundColumnChange: ((_ apply: () -> Void) -> Void)?
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
    override func resizeSubviews(withOldSize oldSize: NSSize) { place(force: true) }

    override func layout() {
        super.layout()
        place()
    }

    /// How the column shows at the window's width now.
    func decide() -> WindowColumnShown {
        guard visible else { return .hidden }
        let sidebar = sidebarRoom()
        return WindowColumnWidth.shown(contentWidth: bounds.width, sidebarWidth: sidebar.shown, minimalSidebar: sidebar.minimal,
                                       expanded: expanded)
    }

    /// The column and the split view where they go now; nothing moves when nothing changed. `force`: the window's size or
    /// the column's side changed, so the frames are set even with the same form.
    func place(force: Bool = false) {
        // The window's own change first, beside the column as it is: the split view shares it out, as it does any resize.
        let (_, resized) = frames(for: shown.width)
        if content.frame != resized { setContentFrame(resized) }
        let decided: WindowColumnShown = decide()
        let width: CGFloat = decided.width
        let (columnFrame, contentFrame) = frames(for: width)
        let placed: Bool = content.frame == contentFrame && (columnFrame.map { !column.isHidden && column.frame == $0 } ?? column.isHidden)
        guard force || decided != shown || !placed else { return }
        let apply = { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if column.isHidden != (width == 0) { column.isHidden = width == 0 }
            if let columnFrame, column.frame != columnFrame { column.frame = columnFrame }
            if content.frame != contentFrame { content.frame = contentFrame }
            CATransaction.commit()
        }
        let columnResized: Bool = width != shown.width
        if columnResized, let around = aroundColumnChange { around(apply) } else { apply() }
        guard decided != shown else { return }
        shown = decided
        onShownChange?(decided)
    }

    private func setContentFrame(_ frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = frame
        CATransaction.commit()
    }

    /// The column's frame (none while it is hidden) and the split view's, for a column `width` across.
    private func frames(for width: CGFloat) -> (NSRect?, NSRect) {
        let height: CGFloat = bounds.height
        let columnFrame = NSRect(x: columnOnRight ? bounds.width - width : 0, y: 0, width: width, height: height)
        let contentFrame = NSRect(x: columnOnRight ? 0 : width, y: 0, width: max(0, bounds.width - width), height: height)
        return (width > 0 ? columnFrame : nil, contentFrame)
    }
}
