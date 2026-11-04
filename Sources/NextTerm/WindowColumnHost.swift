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
/// Folded to its rail, resting the pointer on it opens the list over the content (`list`, the column unfolded, made on the
/// first hover and kept): it lies over the rail on the same grid, its dots, count and well on the rail's own, and is
/// revealed from the rail's edge outward, so only the names seem to come out beside the dots. It takes no room, so nothing
/// beside it moves or resizes. Passing over the rail opens nothing (WindowColumnRail.openDelay), nor does a pointer at
/// rest on it as its window comes forward, until it moves, nor one still on it as the column folds, until it leaves. The
/// list goes once the pointer has been off the rail and the list for WindowColumnRail.closeDelay. It never takes the
/// keyboard.
final class WindowColumnHost: NSView {
    let column = WindowColumnView()
    let content: NSView
    /// Pinned, the handle over its inner edge: the resize cursor and the drag.
    let edge = WindowColumnEdge()
    /// What the system's tab bar and the title row above it take off the top while macOS shows a tab bar over this window
    /// (TitleBarCover): the column and the split view lay out below it, and the strip it covers is filled with the bar's
    /// colour; 0 without a tab bar.
    var topCover: CGFloat = 0 {
        didSet {
            guard topCover != oldValue else { return }
            hideList(animated: false) // laid out for the old top
            hintPlaceWent()
            coverStrip.isHidden = topCover == 0
            place(force: true)
        }
    }
    /// The strip under the system tab bar and its title row: the bar's colour, so the window's top reads as one band.
    private let coverStrip = NSView()

    /// Every window shows the column (WindowColumns: two or more windows, and the setting on).
    var visible = false
    /// The user's choice: unfolded in every window.
    var expanded = false
    /// At the window's right edge, as the sidebar is.
    var columnOnRight = false {
        didSet {
            guard columnOnRight != oldValue else { return }
            hideList(animated: false) // laid out for the other side
            hintPlaceWent()
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
    /// Reduce Motion as System Settings has it: the list appears and goes without its reveal. The self-test stands in.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Where the pointer is on the screen. The self-test stands in.
    static var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// The list that opens over the rail and the content, once made: the column unfolded, laid out once at its whole
    /// width, in `listClip`, which `listShade` (its background and shadow) reveals from the rail's width to the list's.
    private(set) var list: WindowColumnView?
    private(set) var listShade: NSView?
    private var listClip: NSView?
    var listShowing: Bool { listShade.map { !$0.isHidden } ?? false }
    private var onRail = false
    private var onList = false
    /// Counts the pointer's moves on and off: a delay whose count has moved on does nothing.
    private var hoverMoves = 0
    /// The pointer on the rail as its window came forward: no list opens until it moves from here.
    private(set) var heldAt: NSPoint?
    /// The pointer on the column as it folded: no list opens until it leaves the column once.
    private(set) var waitsForExit = false
    /// Where the pointer last came to rest on the rail: the list opens once it has stayed within restRadius of it.
    private var restPoint: NSPoint?
    /// When the list last went: coming back onto the rail within warmDelay opens it at once. Not after Escape, which
    /// sent it away on purpose.
    private var closedAt: CFTimeInterval?
    private var dismissedByKey = false
    /// The reveal under way: the shade's width going from `from` to `to` over `duration`, then `done`.
    private var reveal: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval, opening: Bool)?
    private var revealTimer: Timer?
    /// Counts the list's openings: a wait for it to have stayed open (H1's trigger) whose count has moved on does nothing.
    private var listOpenings = 0

    /// The hint ColumnHints put up in this window, and where: at the open list's foot (`inList`), at the pinned column's,
    /// or beside the rail's foot over the content's edge.
    private(set) var hint: HintLine?
    private(set) var hintInList = false
    /// How wide the chrome is that lies beside the column, where a hint may sit without covering text: the window's
    /// project sidebar when it is shown on the column's edge, else none.
    var roomBeside: () -> CGFloat = { 0 }

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        autoresizesSubviews = true
        content.autoresizingMask = []
        addSubview(content)
        column.isHidden = true
        addSubview(column)
        edge.isHidden = true
        edge.onDrag = { [weak self] (event: NSEvent) in self?.column.dragEdge(from: event) }
        addSubview(edge) // over the column's rows and the content beside it
        coverStrip.wantsLayer = true
        coverStrip.layer?.backgroundColor = Theme.bar.cgColor
        coverStrip.isHidden = true
        addSubview(coverStrip)
        column.onPointer = { [weak self] (inside: Bool) in self?.railPointer(inside) }
        column.onMoved = { [weak self] in self?.railMoved() }
        column.onUpdated = { [weak self] in self?.mirror() }
    }

    /// Its window coming forward holds the list back while the pointer rests on the rail, as a window brought forward from
    /// another's list lands with the pointer where that list was.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(cameForward), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// Its window came forward: once the window server has it in front (a turn later; it is not yet as the key change is
    /// told), a pointer resting on the rail holds the list back. An open already on its way waits for that too, as it
    /// asks again when it is due.
    @objc func cameForward() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.holdIfResting() }
        }
    }

    func holdIfResting() {
        heldAt = pointerOnColumn() ? Self.pointerLocation() : nil
    }

    /// Its window is closing: no open on its way, and the list, its reveal and its Escape monitor gone.
    func windowClosing() {
        hoverMoves += 1
        onRail = false
        hideList(animated: false)
        hintPlaceWent()
    }

    /// Pinned with a width to drag, the handle straddles the column's inner edge below the title bar's strip; else it is
    /// hidden. The host is not flipped: the strip is at the top.
    private func placeEdge(form: WindowColumnShown.Form) {
        let shows: Bool = form == .expanded && !column.isHidden && column.onResize != nil
        if edge.isHidden == shows { edge.isHidden = !shows }
        guard shows else { return }
        let half: CGFloat = 4
        let x: CGFloat = columnOnRight ? column.frame.minX - half : column.frame.maxX - half
        let frame = NSRect(x: x, y: 0, width: 2 * half, height: max(0, bounds.height - topCover - WindowColumnGrid.titleStrip))
        guard edge.frame != frame else { return }
        edge.frame = frame
        window?.invalidateCursorRects(for: edge)
    }

    /// Whether the pointer is on the column, as it is now, in this window and not one over it.
    private func pointerOnColumn() -> Bool {
        guard !column.isHidden, let point = pointerHere() else { return false }
        return column.frame.contains(point)
    }

    /// Whether the pointer is on the open list below its title bar's strip: a list that opens under the pointer hears no
    /// entry, as its tracking starts with the pointer inside, so its place is measured.
    private func pointerOnList() -> Bool {
        guard let shade = listShade, !shade.isHidden, let point = pointerHere() else { return false }
        var place: NSRect = shade.frame
        place.size.height -= column.topInset // the host is not flipped: the strip is at the frame's top
        return place.contains(point)
    }

    #if DEBUG
    /// For the self-test: whether the real pointer rests where the column and its list are, which its real entries and
    /// exits then race the checks' own.
    var realPointerOnColumnArea: Bool {
        guard let window else { return false }
        let real: NSPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let area = NSRect(x: columnOnRight ? column.frame.maxX - WindowColumnRail.listWidth - 1 : column.frame.minX, y: 0,
                          width: WindowColumnRail.listWidth + 1, height: bounds.height)
        return area.contains(real) && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    /// For the self-test: where the hover stands.
    var hoverForTest: String {
        "rail \(onRail), list \(onList), closing \(closing), showing \(listShowing), held \(heldAt != nil), "
            + (realPointerOnColumnArea ? "the real pointer on the column's area" : "the real pointer elsewhere")
    }
    #endif

    /// Whether the pointer is on the rail's foot, the hide key.
    private func pointerOnFoot() -> Bool {
        guard let point = pointerHere(), !column.hideButton.isHidden else { return false }
        return column.convert(column.hideButton.frame, to: self).contains(point)
    }

    /// The pointer in the host's coordinates while this window is the one under it; nil otherwise.
    private func pointerHere() -> NSPoint? {
        guard let window else { return nil }
        let screen: NSPoint = Self.pointerLocation()
        guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
        return convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Its own frames for both, never the autoresizing mask's: one change each, in one pass.
    override func resizeSubviews(withOldSize oldSize: NSSize) { place(force: true) }

    override func layout() {
        super.layout()
        place()
    }

    /// The widest the unfolded column can be here and stay unfolded: the window less the sidebar as it is and the work
    /// area's minimum, less its hairline.
    func unfoldedRoom() -> CGFloat {
        bounds.width - max(0, sidebarRoom().shown) - WindowColumnWidth.workMinimum - WindowColumnWidth.hairline
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
        let strip = NSRect(x: 0, y: max(0, bounds.height - topCover), width: bounds.width, height: min(topCover, bounds.height))
        if coverStrip.frame != strip { coverStrip.frame = strip }
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
        if width == 0, onRail {
            // Hidden under the pointer, which then sends no exit: the pointer is off it, and the dots rest.
            onRail = false
            hoverMoves += 1
            updateAwake()
        }
        placeEdge(form: decided.form)
        placeHintBeside()
        if decided.form != .folded {
            hideList(animated: false) // pinned open, or hidden: no list over the content
        } else if listShowing {
            setShade(width: reveal == nil ? listFrame().width : shadeWidth)
        }
        guard decided != shown else { return }
        // Hidden, folded or pinned: the hint's place is gone, and a hint the new form wants comes on its trigger.
        if decided.form != shown.form { hintPlaceWent() }
        // Shown folded with the pointer elsewhere: its dots settle a few seconds on.
        if decided.form == .folded, shown.form != .folded { updateAwake() }
        // Folded under the pointer: the list it would open is the column just folded. It waits for the pointer to leave.
        if shown.form == .expanded && decided.form == .folded { waitsForExit = pointerOnColumn() }
        shown = decided
        onShownChange?(decided)
    }

    // MARK: a hint

    /// Puts `line` up: at the open list's foot (`inList`); else at the pinned column's foot when its words fit there, or
    /// beside the column's foot, over the content's edge, when they don't or the column is the rail. False when there
    /// is no such place now (the column hidden, or no list open), and nothing is put up.
    func showHint(_ line: HintLine, inList: Bool) -> Bool {
        guard hint == nil, visible, !column.isHidden, shown.form != .hidden else { return false }
        if inList {
            guard listShowing, !closing, let list else { return false }
            list.hint = line
        } else {
            guard !listShowing else { return false }
            line.onRight = columnOnRight
            if shown.form == .expanded, line.fits(width: column.frame.width - WindowColumnWidth.hairline) {
                column.hint = line
            } else {
                // Beside the column only over chrome (the project sidebar on that edge), never the editor's or terminal's text.
                guard line.besideWidth + 8 <= roomBeside() else { return false }
                line.beside = true
                addSubview(line) // over the split view, as the list is
            }
        }
        hint = line
        hintInList = inList
        placeHintBeside()
        line.appear()
        return true
    }

    /// Takes the hint down, wherever it is (ColumnHints, which counts its showing).
    func removeHint() {
        guard let line = hint else { return }
        hint = nil
        hintInList = false
        if list?.hint === line { list?.hint = nil }
        if column.hint === line { column.hint = nil }
        line.removeFromSuperview()
    }

    /// Beside the column, its plate at the foot's middle, from the column's inner edge into the content: never wider than
    /// the content leaves room for.
    private func placeHintBeside() {
        guard let line = hint, line.beside, !column.isHidden else { return }
        let width: CGFloat = min(line.besideWidth, max(0, content.frame.width - 16))
        let x: CGFloat = columnOnRight ? column.frame.minX - width : column.frame.maxX
        let frame = NSRect(x: x, y: ((WindowColumnGrid.foot - HintLine.height) / 2).rounded(), width: width, height: HintLine.height)
        if line.frame != frame { line.frame = frame }
    }

    /// Where the hint was is gone (the list closed, the column folded, pinned, hidden or moved, the window closing): it
    /// goes, and its showing counts as long as it was up.
    private func hintPlaceWent() {
        guard hint != nil else { return }
        ColumnHints.shared.placeWent(in: self)
    }

    // MARK: the list on hover

    private func railPointer(_ inside: Bool) {
        onRail = inside
        hoverMoves += 1
        if !inside {
            heldAt = nil
            waitsForExit = false
        } else if let held = heldAt, Self.pointerLocation() != held {
            heldAt = nil // it came onto the rail from elsewhere: a move, not a rest
        }
        updateAwake()
        guard shown.form == .folded, !column.isHidden else { return }
        if inside {
            // Back while it closes: it opens again from where it is; not while Escape holds it shut.
            if closing { return heldAt == nil ? showList() : () }
            guard !listShowing else { return }
            // Back on the rail just after the list went: it opens at once, as a slip off the edge costs no wait.
            if let closedAt, CACurrentMediaTime() - closedAt < WindowColumnRail.warmDelay, heldAt == nil, !waitsForExit, !pointerOnFoot() {
                return showList()
            }
            restPoint = Self.pointerLocation()
            openSoon()
        } else {
            closeSoon()
        }
    }

    /// The pointer moved on the rail: a list held back for a pointer at rest opens once it rests again, and a pointer that
    /// moves on past restRadius starts its rest over, so moving along the rail opens nothing.
    private func railMoved() {
        let now: NSPoint = Self.pointerLocation()
        if let held = heldAt {
            guard now != held else { return }
            heldAt = nil
        }
        guard onRail, !listShowing, !waitsForExit else { return }
        if let rest = restPoint, hypot(now.x - rest.x, now.y - rest.y) <= WindowColumnRail.restRadius { return }
        restPoint = now
        hoverMoves += 1
        openSoon()
    }

    /// The dots wake to their colours while the pointer is on the rail or the list is open.
    private func updateAwake() {
        let awake: Bool = onRail || listShowing
        if column.awake != awake { column.awake = awake }
        if awake {
            settleMoves += 1 // a settle on its way finds the count moved on
            if column.settled { column.settled = false }
        } else {
            settleSoon()
        }
    }

    /// Counts the wakes: a settle whose count has moved on does nothing.
    private var settleMoves = 0

    /// A few seconds after the rail is left alone, its dots settle to a trace.
    private func settleSoon() {
        guard !column.settled else { return }
        settleMoves += 1
        let move: Int = settleMoves
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowColumnRail.settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settleMoves == move, !self.column.awake else { return }
                self.column.settled = true
            }
        }
    }

    /// The list after the pointer has rested on the rail for openDelay: not while it was held back, nor while a button
    /// is down (a drag or a click passing over the rail is not a rest on it).
    private func openSoon() {
        guard heldAt == nil, !waitsForExit else { return }
        after(WindowColumnRail.openDelay) { [weak self] in
            guard let self, self.onRail, self.heldAt == nil, !self.waitsForExit, NSEvent.pressedMouseButtons == 0 else { return }
            // Resting on the hide key at the rail's foot is for clicking it: no list over it.
            guard !self.pointerOnFoot() else { return }
            self.showList()
        }
    }

    private func listPointer(_ inside: Bool) {
        onList = inside
        hoverMoves += 1
        // The pointer back on it while it closes opens it again, unless Escape closed it: a list closing under a resting
        // pointer hears an entry as its tracking is set up again, which is no move toward it.
        if inside, closing, heldAt == nil { return showList() }
        if !inside { closeSoon() }
    }

    /// A window chosen on the rail: no list opens after the click, and an open one goes, as a click in the list does.
    func chose() {
        hoverMoves += 1 // a pending open finds the count moved on, and does nothing
        hideList(animated: false)
        closedAt = nil // a window was chosen: no quick reopen in the one just left
    }

    /// The list goes once the pointer has stayed off the rail and the list for closeDelay. One the pointer is on, though it
    /// heard no entry, stays, and goes when the pointer leaves it.
    private func closeSoon() {
        guard listShowing, !closing else { return }
        after(WindowColumnRail.closeDelay) { [weak self] in
            guard let self, !self.onRail, !self.onList else { return }
            if self.pointerOnList() {
                self.onList = true
                return
            }
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

    /// The list over the rail and the content: as tall as the window, the unfolded column's width, from the column's
    /// outer edge, so its dots lie on the rail's.
    private func listFrame() -> NSRect {
        let width: CGFloat = WindowColumnRail.listWidth + WindowColumnWidth.hairline
        let x: CGFloat = columnOnRight ? column.frame.maxX - width : column.frame.minX
        return NSRect(x: x, y: 0, width: width, height: max(0, bounds.height - topCover))
    }

    private func makeList() -> WindowColumnView {
        let made = WindowColumnView()
        made.hovers = true
        made.onSelect = { [weak self] (id: Int) in
            self?.hideList(animated: false)
            self?.column.onSelect?(id)
        }
        made.onToggle = { [weak self] in self?.column.onToggle?() } // a double-click pins it
        made.onMore = { [weak self] in self?.column.onMore?() }
        made.onTopRowMenu = { [weak self] in self?.column.onTopRowMenu?() }
        made.onPointer = { [weak self] (inside: Bool) in self?.listPointer(inside) }
        made.onFold = { [weak self] (key: String) in self?.column.onFold?(key) }
        // Its background and shadow, round the clip that reveals the list: a clip's mask would cut the shadow off.
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = Theme.bar.cgColor
        shade.layer?.shadowColor = NSColor.black.cgColor
        shade.layer?.shadowRadius = 5
        shade.layer?.shadowOffset = .zero
        shade.layer?.shadowOpacity = 0
        shade.isHidden = true
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(made)
        shade.addSubview(clip)
        addSubview(shade) // over the split view and the rail
        list = made
        listShade = shade
        listClip = clip
        return made
    }

    /// The rows as the rail has them, unfolded, while the list shows, and the window's glow along its top.
    private func mirror() {
        guard listShowing, let list else { return }
        list.update(list: column.list, change: .structure, current: column.current, expanded: true)
        list.setMerged(column.merged)
        list.projectGlow.peak = column.projectGlow.peak
        list.projectGlow.dimmed = column.projectGlow.dimmed
    }

    /// The list out from the rail; at once with Reduce Motion. Called while it closes, it opens again from where it is.
    func showList() {
        guard visible, shown.form == .folded, !column.isHidden else { return }
        let panel: WindowColumnView = list ?? makeList()
        panel.onRight = columnOnRight
        panel.topInset = column.topInset
        panel.projectGlow.peak = column.projectGlow.peak
        panel.projectGlow.dimmed = column.projectGlow.dimmed
        let opening: Bool = !listShowing
        listShade?.isHidden = false
        column.covered = true
        updateAwake()
        if opening { onList = pointerOnList() }
        // Opened on hover: resting on the column to see the windows is known. A hint beside the rail would be under the
        // list: it goes. Open a second, the list may say it can move to the other edge (H1).
        if opening {
            HintCenter.shared.retire(.columnBasics, reason: .actionPerformed)
            if hint != nil, !hintInList { hintPlaceWent() }
            listOpenings += 1
            let opened: Int = listOpenings
            DispatchQueue.main.asyncAfter(deadline: .now() + ColumnHints.listDwell) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.listOpenings == opened, self.listShowing, !self.closing else { return }
                    ColumnHints.shared.listStayedOpen(in: self)
                }
            }
        }
        if opening {
            panel.update(list: column.list, change: .structure, current: column.current, expanded: true)
            panel.frame = NSRect(origin: .zero, size: listFrame().size)
            panel.layoutSubtreeIfNeeded() // laid out once, at its whole width: the reveal only moves the clip
        }
        watchEscape()
        let full: CGFloat = listFrame().width
        guard !Self.reducesMotion() else {
            stopReveal()
            setShade(width: full)
            return
        }
        animateShade(from: opening ? column.frame.width : shadeWidth, to: full, duration: WindowColumnRail.openDuration, opening: true)
    }

    /// The list back into the rail; at once with Reduce Motion, or when the column pins open or hides.
    func hideList(animated: Bool) {
        unwatchEscape()
        guard listShowing else {
            onList = false
            return
        }
        guard animated, !Self.reducesMotion() else {
            closed()
            return
        }
        animateShade(from: shadeWidth, to: column.frame.width, duration: WindowColumnRail.closeDuration, opening: false)
    }

    /// The list gone: hidden, and the rail heard by VoiceOver again.
    private func closed() {
        stopReveal()
        onList = false
        if hintInList { hintPlaceWent() }
        listShade?.isHidden = true
        column.covered = false
        closedAt = dismissedByKey ? nil : CACurrentMediaTime()
        dismissedByKey = false
        updateAwake()
    }

    /// Closing, not yet gone.
    private var closing: Bool { reveal.map { !$0.opening } ?? false }

    /// The shade's width as it shows now.
    private var shadeWidth: CGFloat { listShade?.frame.width ?? 0 }

    /// The shade `width` across from the column's outer edge, the clip filling it, and the list in it at its whole width,
    /// held at that edge; its shadow as strong as it is open.
    private func setShade(width: CGFloat) {
        guard let shade = listShade, let clip = listClip, let panel = list else { return }
        let full: NSRect = listFrame()
        let shown: CGFloat = min(max(0, width), full.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = NSRect(x: columnOnRight ? full.maxX - shown : full.minX, y: 0, width: shown, height: full.height)
        if shade.frame != frame { shade.frame = frame }
        let inside = NSRect(origin: .zero, size: frame.size)
        if clip.frame != inside { clip.frame = inside }
        let place = NSRect(x: columnOnRight ? shown - full.width : 0, y: 0, width: full.width, height: full.height)
        if panel.frame != place { panel.frame = place }
        let open: CGFloat = full.width > column.frame.width ? (shown - column.frame.width) / (full.width - column.frame.width) : 1
        shade.layer?.shadowOpacity = Float(0.35 * min(1, max(0, open)))
        shade.layer?.shadowPath = CGPath(rect: inside, transform: nil)
        CATransaction.commit()
    }

    /// The shade from `from` to `to` over `duration`: easing out as it opens, in as it closes; a closed one hides.
    private func animateShade(from: CGFloat, to: CGFloat, duration: CFTimeInterval, opening: Bool) {
        stopReveal()
        setShade(width: from)
        reveal = (from, to, CACurrentMediaTime(), duration, opening)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] (timer: Timer) in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() } // its window closed mid-reveal
                self.revealStep()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func revealStep() {
        guard let reveal else { return stopReveal() }
        let t: CGFloat = CGFloat(min(1, max(0, (CACurrentMediaTime() - reveal.start) / reveal.duration)))
        let eased: CGFloat = reveal.opening ? 1 - pow(1 - t, 3) : t * t
        setShade(width: reveal.from + (reveal.to - reveal.from) * eased)
        guard t >= 1 else { return }
        if reveal.opening { stopReveal() } else { closed() }
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        reveal = nil
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
                    self.dismissedByKey = true
                    // Held shut where the pointer is: nothing opens it again until the pointer moves.
                    self.heldAt = Self.pointerLocation()
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
        // Below the system tab bar while it shows (the host is not flipped: the room is left at the top).
        let height: CGFloat = max(0, bounds.height - topCover)
        let columnFrame = NSRect(x: columnOnRight ? bounds.width - width : 0, y: 0, width: width, height: height)
        let contentFrame = NSRect(x: columnOnRight ? 0 : width, y: 0, width: max(0, bounds.width - width), height: height)
        return (width > 0 ? columnFrame : nil, contentFrame)
    }
}
