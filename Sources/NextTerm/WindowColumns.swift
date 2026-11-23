import AppKit
import NextTermCore

/// Every window's column, kept as one: the rows from the index of every window (AppDelegate.windowIndex), whether the
/// column shows, and what changed, told to each window directly as AppDelegate tells them a layout change. No window
/// watches anything for it.
///
/// It hears a window opening (AppDelegate.indexed, before the window shows), closing (windowClosed), a window's entry
/// changing (indexed, when the index says it changed), and a project colour or View › Agent Spinner changing. Most
/// entry changes are a title or when the window last had the keyboard, which no column shows: those end here.
final class WindowColumns: NSObject {
    /// Off while the self-test's other parts run: their geometry was written without the column (PC14).
    static var suppressed = false
    /// No offer to show or hide it (WindowColumnOffer) while the self-test runs, but in its own checks.
    static var offersSuppressed = false
    /// No offer while the launch reopens the last session's projects: only a window the user opens offers it.
    var holdsOffers = false
    /// One notice about the column a launch, at most.
    private var offeredThisLaunch = false
    /// The notice's number (GitToast.count) while it shows, so a change of the setting takes it away and nothing else.
    private var offerNotice: Int?

    private(set) var list = WindowColumnList()
    /// The repositories whose worktrees are folded into their row (WindowColumnRow.foldKey), in every window, kept across
    /// launches: a repository folded and closed is folded again when it opens.
    private(set) var folded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: WindowColumnSettings.foldedKey) ?? [])
    /// Whether every window shows the column now.
    private(set) var visible = false
    /// Windows a restore is building and about to open, one at a time (SessionRestoreBuild): counted, so each is laid out
    /// with the column from the start rather than narrowed a moment after.
    var expecting = 0

    #if DEBUG
    /// For the self-test's budget: the whole list made again, and one window's change passed on to every window.
    private(set) var rebuildCount = 0
    private(set) var passCount = 0
    func resetCounters() {
        rebuildCount = 0
        passCount = 0
    }
    #endif

    override init() {
        WindowColumnWidth.expanded = WindowColumnWidth.expandedWidth(CGFloat(UserDefaults.standard.double(forKey: WindowColumnSettings.widthKey)))
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(colorsChanged), name: ProjectColorStore.changed, object: nil)
        center.addObserver(self, selector: #selector(spinnerChanged), name: AgentSpinner.changed, object: nil)
    }

    /// After every window has taken its new colour: each hears the same notification, some after this.
    @objc private func colorsChanged() {
        DispatchQueue.main.async { [weak self] in self?.remade() }
    }

    /// Agent Spinner, Reduce Motion or Increase Contrast changed (AgentSpinner.changed): the rows, and the well's edge and
    /// the dim text when Increase Contrast is what changed.
    @objc private func spinnerChanged() {
        remade()
        let contrast: Bool = DisplayOptions.increasesContrast
        guard contrast != contrastDrawn else { return }
        contrastDrawn = contrast
        for controller in windows {
            controller.windowColumn.contrastChanged()
            controller.columnHost.list?.contrastChanged()
            controller.columnHost.hint?.contrastChanged() // beside the rail; one in the column or list is theirs
        }
    }

    private var contrastDrawn: Bool = DisplayOptions.increasesContrast

    private var app: AppDelegate { AppDelegate.shared }
    private var showsWorking: Bool { AgentSpinner.current != .off }

    /// The windows told: the open ones, not one closing.
    private var windows: [TerminalWindowController] { app.controllers.filter { !$0.hasClosed } }

    /// Each window's colour as its top row shows it: none while Show Project Colors is off.
    private func colors() -> [Int: ProjectColor] {
        guard ProjectColorStore.isShown else { return [:] }
        var colors: [Int: ProjectColor] = [:]
        for controller in windows { colors[controller.indexID] = controller.projectColor }
        return colors
    }

    private func color(of id: Int) -> ProjectColor? {
        guard ProjectColorStore.isShown else { return nil }
        return windows.first { $0.indexID == id }?.projectColor
    }

    /// The setting on (or `shown`) and two or more terminal windows open (or about to): every window shows the column.
    private func decideVisible(count: Int, expecting: Int? = nil, shown: Bool? = nil) -> Bool {
        WindowColumnSettings.visible(shown: (shown ?? app.showsWindowColumn) && !Self.suppressed, windows: count,
                                     expecting: expecting ?? self.expecting)
    }

    /// Whether every window would show the column with the setting `shown`: what folding it needs (set_layout).
    func wouldShow(ifShown shown: Bool) -> Bool { decideVisible(count: app.windowIndex.windows.count, shown: shown) }

    /// Whether a window being made shows the column from the start, before it is in the index: with the windows open and
    /// itself, or every window a restore is making, itself among them (a restore of one window shows none).
    func visibleForNewWindow() -> Bool {
        decideVisible(count: app.windowIndex.windows.count, expecting: max(1, expecting))
    }

    /// A window opened or closed, or a setting changed: the whole list made again and every window told.
    /// `previous`: the list as it was before, when the caller has already moved `list` on (windowChanged's structure
    /// change), so the hints' triggers compare against what the column showed.
    func rebuild(from previous: WindowColumnList? = nil) {
        #if DEBUG
        rebuildCount += 1
        #endif
        let entries: [WindowIndex.Window] = app.windowIndex.windows
        let old: WindowColumnList = previous ?? list
        let was: Bool = visible
        list = WindowColumnList.build(windows: entries, colors: colors(), showsWorking: showsWorking, folded: folded)
        visible = decideVisible(count: entries.count)
        tell(.structure)
        hintTriggers(from: old, wasVisible: was)
    }

    /// The column's hints' triggers (ColumnHints): it has just come (H3), a mark has appeared in a window (H2), or a
    /// repository's row has a worktree more under it (H8).
    /// Never while a restore builds its windows: the column coming back with them at launch, or after an update, is not
    /// the user reaching it, and the marks they bring back are not new.
    private func hintTriggers(from old: WindowColumnList, wasVisible: Bool) {
        guard visible, expecting == 0 else { return }
        let new: WindowColumnList = list
        MainActor.assumeIsolated {
            if !wasVisible { ColumnHints.shared.columnAppeared() }
            ColumnHints.shared.rowsChanged(from: old, to: new)
        }
    }

    /// The pinned column's inner edge dragged to `width` in the window `from`: that window follows the drag, and every
    /// other window once it ends (`ended`), when the width is kept. Nil puts back the default.
    func setWidth(_ width: CGFloat?, from: TerminalWindowController, ended: Bool) {
        WindowColumnWidth.expanded = WindowColumnWidth.expandedWidth(width ?? 0)
        from.placeWindowColumn()
        guard ended else { return }
        if width == nil {
            UserDefaults.standard.removeObject(forKey: WindowColumnSettings.widthKey)
        } else {
            UserDefaults.standard.set(Double(WindowColumnWidth.expanded), forKey: WindowColumnSettings.widthKey)
        }
        for controller in windows where controller !== from { controller.placeWindowColumn() }
    }

    /// A repository's fold arrow, in any window's column: its worktrees fold into its row, or come out again, everywhere.
    func toggleFold(_ key: String) {
        if folded.remove(key) == nil { folded.insert(key) }
        // Used, by the arrow, VoiceOver's action or the hint's button: the hint on it is done.
        MainActor.assumeIsolated { HintCenter.shared.retire(.foldWorktrees, reason: .actionPerformed) }
        UserDefaults.standard.set(folded.sorted(), forKey: WindowColumnSettings.foldedKey)
        rebuild()
    }

    /// Window `id`'s entry in the index changed: only its row is made again, and nothing goes on when the row is the same.
    /// A change only to rows' details (what is in front in windows of the same name) waits `detailHold` first, unless
    /// `holding` is false: a quick command coming and going in a window's title never flashes beside its name, and a
    /// title that keeps changing shows at most once a second.
    func windowChanged(_ id: Int, holding: Bool = true) {
        guard let entry = app.windowIndex.window(id) else { return rebuild() }
        let (next, change) = list.updating(entry, color: color(of: id), showsWorking: showsWorking)
        if holding, case .rows(let ids) = change, Self.onlyDetails(ids, from: list, to: next) {
            // The list keeps the entry it had, so a title back as it was by then changes nothing.
            guard held.insert(id).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.detailHold) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.held.remove(id) != nil else { return }
                    self.windowChanged(id, holding: false)
                }
            }
            return
        }
        let old: WindowColumnList = list
        list = next
        switch change {
        case .none:
            return
        case .structure:
            // A window more, or one regrouped: made again whole, its triggers against the list before the change (H8's
            // worktree joining its repository's row, H2's mark in a regrouped row).
            rebuild(from: old)
        case .rows:
            tell(change)
            hintTriggers(from: old, wasVisible: visible)
        }
    }

    /// How long a change to a row's detail alone waits before it is drawn.
    static var detailHold: TimeInterval = 1
    /// The windows whose details are waiting.
    private var held: Set<Int> = []

    /// Whether going from `old` to `new` changes rows `ids` in their details and nothing else they draw (their words may
    /// change too: those draw nothing).
    private static func onlyDetails(_ ids: [Int], from old: WindowColumnList, to new: WindowColumnList) -> Bool {
        var details = false
        for id in ids {
            guard let before = old.row(id), let after = new.row(id) else { return false }
            guard before.face != after.face else { continue }
            guard before.depth == after.depth, before.name == after.name, before.prefix == after.prefix, before.color == after.color,
                  before.urgent == after.urgent, before.marks == after.marks else { return false }
            details = true
        }
        return details
    }

    /// A colour or Agent Spinner changed: every row made again, and only the rows that differ drawn again.
    private func remade() {
        let entries: [WindowIndex.Window] = app.windowIndex.windows
        let next = WindowColumnList.build(windows: entries, colors: colors(), showsWorking: showsWorking, folded: folded)
        let change: WindowColumnList.Change = WindowColumnList.change(from: list, to: next)
        list = next
        guard change != .none else { return }
        tell(change)
    }

    /// Settings › General's checkbox, View › Hide Window Column, or the fold: every window at once.
    func settingsChanged() {
        let was: Bool = visible
        visible = decideVisible(count: app.windowIndex.windows.count)
        tell(.none)
        hintTriggers(from: list, wasVisible: was)
    }

    // MARK: the offer to show or hide it

    /// A window the user opened (AppDelegate.openWindow; not a restore, the launch's reopening or an agent's window):
    /// the notice about the column, if one is due, once the window is in front.
    func windowOpened() {
        guard !holdsOffers, expecting == 0, !Self.suppressed, !Self.offersSuppressed, !offeredThisLaunch else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.offerIfDue() } }
    }

    /// The notice, if one is due and nothing is in the way: Next Term in front, no notice up (an Undo stays), no
    /// decision waiting (an agent's approval or proposal), no sheet or modal window. Kept for the next window otherwise.
    @MainActor private func offerIfDue() {
        guard !offeredThisLaunch, NSApp.isActive, !GitToast.isShowing, UpdateHolds.shared.openDecisions.isEmpty,
              let window = CommandLineTool.freeProjectWindow(key: NSApp.keyWindow, modal: NSApp.modalWindow),
              let controller = window.windowController as? TerminalWindowController else { return }
        let defaults = UserDefaults.standard
        let windows: Int = app.windowIndex.windows.count
        guard let kind = WindowColumnOffer.offer(shown: app.showsWindowColumn, windows: windows,
                                                 record: WindowColumnOffer.Record(defaults), now: Date()) else { return }
        // A narrow window hiding the column has nothing to point at.
        if kind == .hide, controller.columnHost.shown.form == .hidden { return }
        offeredThisLaunch = true
        WindowColumnOffer.noteShown(kind, defaults)
        let key: String? = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display
        let (button, other) = WindowColumnOffer.buttons(kind)
        let before: Int = GitToast.count
        GitToast.show(WindowColumnOffer.text(kind, windows: windows, key: key), in: window, button: button, action: { [weak self] in
            self?.offerNotice = nil
            self?.app.showsWindowColumn = kind == .show
            if kind == .hide { WindowColumnOffer.finish(defaults) }
        }, other: other, otherAction: { [weak self] in
            self?.offerNotice = nil
            if kind == .show { WindowColumnOffer.finish(defaults) }
        })
        offerNotice = GitToast.count > before ? GitToast.count : nil
    }

    /// The setting changed some other way while the notice shows: the notice goes, and nothing else does.
    func dismissOffer() {
        guard let notice = offerNotice else { return }
        offerNotice = nil
        if GitToast.isShowing, GitToast.count == notice { GitToast.dismiss() }
    }

    #if DEBUG
    /// The self-test's own checks of the offer: each starts as a fresh launch would.
    func resetOffersForTest() {
        offeredThisLaunch = false
        offerNotice = nil
    }
    #endif

    private func tell(_ change: WindowColumnList.Change) {
        #if DEBUG
        if change != .structure { passCount += 1 }
        #endif
        let expanded: Bool = app.windowColumnExpanded
        for controller in windows {
            controller.applyWindowColumn(list: list, change: change, visible: visible, expanded: expanded)
        }
    }
}
