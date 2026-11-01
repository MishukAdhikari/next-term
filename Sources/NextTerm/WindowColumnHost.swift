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
///
/// Folded to its rail, resting the pointer on it slides the list out over the content (`list`, the column unfolded,
/// made on the first hover and kept): it takes no room, so nothing beside it moves or resizes. Passing over the rail opens
/// nothing (WindowColumnRail.openDelay), and the list goes once the pointer has been off the rail and the list for
/// WindowColumnRail.closeDelay. It never takes the keyboard.
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
    /// Where the hovering list's header words start, past the traffic lights when it sits under them.
    var listLeading: () -> CGFloat = { 8 }
    /// Reduce Motion as System Settings has it: the list appears and goes without sliding. The self-test stands in.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The list that slides out over the content from the rail, once made.
    private(set) var list: WindowColumnView?
    var listShowing: Bool { list.map { !$0.isHidden } ?? false }
    private var onRail = false
    private var onList = false
    /// Counts the pointer's moves on and off: a delay whose count has moved on does nothing.
    private var hoverMoves = 0

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        autoresizesSubviews = true
        content.autoresizingMask = []
        addSubview(content)
        column.isHidden = true
        addSubview(column)
        column.onPointer = { [weak self] (inside: Bool) in self?.railPointer(inside) }
        column.onUpdated = { [weak self] in self?.mirror() }
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
        if decided.form != .folded {
            hideList(animated: false) // pinned open, or hidden: no list over the content
        } else if listShowing, let list {
            list.frame = listFrame()
        }
        guard decided != shown else { return }
        shown = decided
        onShownChange?(decided)
    }

    // MARK: the list on hover

    private func railPointer(_ inside: Bool) {
        onRail = inside
        hoverMoves += 1
        guard shown.form == .folded, !column.isHidden else { return }
        if inside {
            guard !listShowing else { return }
            after(WindowColumnRail.openDelay) { [weak self] in
                // Not while a button is down: a drag or a click passing over the rail is not a rest on it.
                guard let self, self.onRail, NSEvent.pressedMouseButtons == 0 else { return }
                self.showList()
            }
        } else {
            closeSoon()
        }
    }

    private func listPointer(_ inside: Bool) {
        onList = inside
        hoverMoves += 1
        if !inside { closeSoon() }
    }

    /// A window chosen on the rail: no list opens after the click, and an open one goes, as a click in the list does.
    func chose() {
        hoverMoves += 1 // a pending open finds the count moved on, and does nothing
        hideList(animated: false)
    }

    /// The list goes once the pointer has stayed off the rail and the list for closeDelay.
    private func closeSoon() {
        guard listShowing else { return }
        after(WindowColumnRail.closeDelay) { [weak self] in
            guard let self, !self.onRail, !self.onList else { return }
            self.hideList(animated: true)
        }
    }

    /// `body` after `delay`, unless the pointer moved on or off the rail or the list meanwhile.
    private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        let move: Int = hoverMoves
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoverMoves == move else { return }
                body()
            }
        }
    }

    /// The list beside the rail, over the content: as tall as the window, the unfolded column's width.
    private func listFrame() -> NSRect {
        let width: CGFloat = WindowColumnRail.listWidth + WindowColumnWidth.hairline
        let x: CGFloat = columnOnRight ? column.frame.minX - width : column.frame.maxX
        return NSRect(x: x, y: 0, width: width, height: bounds.height)
    }

    private func makeList() -> WindowColumnView {
        let made = WindowColumnView()
        made.hovers = true
        made.isHidden = true
        made.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 10
            return shadow
        }()
        made.onSelect = { [weak self] (id: Int) in
            self?.hideList(animated: false)
            self?.column.onSelect?(id)
        }
        made.onToggle = { [weak self] in self?.column.onToggle?() } // a double-click pins it
        made.onMore = { [weak self] in self?.column.onMore?() }
        made.onTopRowMenu = { [weak self] in self?.column.onTopRowMenu?() }
        made.onPointer = { [weak self] (inside: Bool) in self?.listPointer(inside) }
        addSubview(made) // over the split view and the rail
        list = made
        return made
    }

    /// The rows as the rail has them, unfolded, while the list shows.
    private func mirror() {
        guard listShowing, let list else { return }
        list.update(list: column.list, change: .structure, current: column.current, expanded: true)
    }

    /// Slides the list out from the rail; at once with Reduce Motion.
    func showList() {
        guard visible, shown.form == .folded, !column.isHidden else { return }
        let panel: WindowColumnView = list ?? makeList()
        panel.onRight = columnOnRight
        panel.headerLeading = listLeading()
        panel.isHidden = false
        panel.update(list: column.list, change: .structure, current: column.current, expanded: true)
        let final: NSRect = listFrame()
        watchEscape()
        guard !Self.reducesMotion() else {
            panel.alphaValue = 1
            panel.frame = final
            return
        }
        panel.frame = final.offsetBy(dx: columnOnRight ? 16 : -16, dy: 0)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().frame = final
            panel.animator().alphaValue = 1
        }
    }

    /// The list back into the rail; at once with Reduce Motion, or when the column pins open or hides.
    func hideList(animated: Bool) {
        unwatchEscape()
        guard let list, !list.isHidden else {
            onList = false
            return
        }
        guard animated, !Self.reducesMotion() else {
            onList = false
            list.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ (context: NSAnimationContext) in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            list.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak list] in
            MainActor.assumeIsolated {
                guard let self, let list, list.alphaValue == 0 else { return }
                if self.onRail || self.onList {
                    // The pointer came back while it faded: it stays.
                    list.animator().alphaValue = 1
                    self.watchEscape()
                } else {
                    list.isHidden = true
                }
            }
        })
    }

    /// While the list shows, Escape in its window closes it, and still goes where it was going (the terminal, the
    /// editor): the list never takes a key.
    private var escapeMonitor: Any?

    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
            MainActor.assumeIsolated {
                if let self, event.keyCode == 53, event.window === self.window,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.hoverMoves += 1
                    self.onRail = false
                    self.onList = false // gone by the key, not by the pointer: it doesn't come back as it fades
                    self.hideList(animated: true)
                }
            }
            return event
        }
    }

    private func unwatchEscape() {
        guard let monitor = escapeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeMonitor = nil
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
