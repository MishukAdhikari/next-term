import AppKit
import NextTermCore

/// The window column's three hints (plan 033 R3), each on its pull trigger, put up through HintCenter's rules:
/// - H1, column side: the hover list has stayed open a second. At its foot, a button that moves the column to the other
///   edge, which is the move itself and retires the hint (AppDelegate.setWindowColumnSide, by any route).
/// - H2, next agent: a needs-you or failed mark has appeared for a window that isn't the one in front. At the front
///   window's column foot, Go to Next Agent Needing You's key, as the user has it; no key, no hint.
/// - H3, column basics: the column has just come (a second window opened), and the user has left the keys alone for 3 s.
///   Beside the rail's foot, how to see the windows and keep the column open.
/// A trigger whose moment is not right (the user typing, an agent working, a window under a minute old, another hint
/// up) waits while it still holds: H2 while the mark is there, H3 while the column shows, ten minutes at most, looked at
/// once a second. H1's moment is the list's: it is not kept. One hint is up across the app at a time; H2 and H3 go after
/// a few seconds (longer while the pointer is on them), H1 with its list, and any hint when its place goes.
@MainActor
final class ColumnHints {
    static let shared = ColumnHints()
    /// None while the self-test's other parts run, whose column geometry and notices were written without them.
    static var suppressed = false

    /// How long the hover list stays open before H1 may show. The self-test stands in for these.
    static var listDwell: TimeInterval = 1
    /// How long the keys must have been left alone before H3 shows.
    static var basicsIdle: TimeInterval = 3
    /// How long H2 and H3 stay up.
    static var stays: TimeInterval = 8
    /// How long a trigger waits for its moment, and how often it looks.
    static var waitsAtMost: TimeInterval = 10 * 60
    static var looksEvery: TimeInterval = 1
    /// The window the user works in: Next Term's key window while it is in front. The self-test stands in.
    static var front: () -> TerminalWindowController? = {
        NSApp.isActive ? NSApp.keyWindow?.windowController as? TerminalWindowController : nil
    }

    /// The hint up now, and the window it is in.
    private(set) var shown: (hint: Hint, line: HintLine, host: WindowColumnHost)?
    /// Triggers waiting for their moment: since when, on the uptime clock, and for H2 the window with the mark.
    private(set) var waiting: [Hint: (since: TimeInterval, window: Int?)] = [:]
    private var looking: Timer?
    /// Counts the hints put up: a wait to take one down whose count has moved on does nothing.
    private var showings = 0

    private init() {
        NotificationCenter.default.addObserver(forName: HintCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.centerChanged() }
        }
    }

    // MARK: triggers

    /// H1's trigger: `host`'s list has stayed open for listDwell.
    func listStayedOpen(in host: WindowColumnHost) {
        guard !Self.suppressed, let controller = host.window?.windowController as? TerminalWindowController,
              HintCenter.shared.eligible(.columnSide, in: controller) else { return }
        let words = HintWords.columnSide(onRight: host.columnOnRight)
        let line = HintLine(.columnSide, words: words.lead + " " + words.words, help: words.help, action: { [weak host] in
            guard let host else { return }
            AppDelegate.shared.setWindowColumnSide(host.columnOnRight ? .left : .right)
        })
        line.button?.setAccessibilityLabel(words.words)
        put(line, in: host, inList: true)
    }

    /// H3's trigger: the column has just come in every window.
    func columnAppeared() {
        wait(for: .columnBasics, window: nil)
    }

    /// H2's trigger: the column's rows went from `old` to `new`; a mark new in a window behind waits for its moment.
    func rowsChanged(from old: WindowColumnList, to new: WindowColumnList) {
        let rows: [WindowColumnRow] = new.newlyUrgent(since: old)
        guard !rows.isEmpty else { return }
        let front: Int? = Self.front()?.indexID
        guard let row = rows.first(where: { (row: WindowColumnRow) -> Bool in front.map { !WindowColumnView.shows($0, in: row) } ?? true })
        else { return }
        wait(for: .nextAgent, window: row.id)
    }

    private func wait(for hint: Hint, window: Int?) {
        guard !Self.suppressed, HintCenter.shared.tipsOn, HintCenter.shared.record(hint).retired == nil else { return }
        waiting[hint] = (ProcessInfo.processInfo.systemUptime, window)
        look()
        guard looking == nil, !waiting.isEmpty else { return }
        let timer = Timer(timeInterval: Self.looksEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        RunLoop.main.add(timer, forMode: .common)
        looking = timer
    }

    /// Each waiting trigger: dropped once it no longer holds or has waited too long, put up once its moment is right.
    func look() {
        let now: TimeInterval = ProcessInfo.processInfo.systemUptime
        for (hint, trigger) in waiting {
            if now - trigger.since > Self.waitsAtMost || !holds(hint, window: trigger.window) { waiting[hint] = nil }
        }
        if shown == nil, let controller = Self.front() {
            for hint in [Hint.nextAgent, .columnBasics] where waiting[hint] != nil {
                guard ready(hint, in: controller), HintCenter.shared.eligible(hint, in: controller),
                      let line = line(for: hint), put(line, in: controller.columnHost, inList: false) else { continue }
                waiting[hint] = nil
                break
            }
        }
        if waiting.isEmpty {
            looking?.invalidate()
            looking = nil
        }
    }

    /// Whether `hint`'s trigger still holds: not retired, tips on, and H2's mark still there, H3's column still shown.
    private func holds(_ hint: Hint, window: Int?) -> Bool {
        guard HintCenter.shared.tipsOn, HintCenter.shared.record(hint).retired == nil else { return false }
        let columns: WindowColumns = AppDelegate.shared.windowColumns
        guard columns.visible else { return false }
        guard hint == .nextAgent else { return true }
        guard let window, let urgent = columns.list.row(showing: window)?.urgent else { return false }
        return urgent == .attention || urgent == .failed
    }

    /// Whether `controller` is the place for `hint` now: its column showing (H3: as the rail, which resting on opens),
    /// H2's mark in another window, and H3 after basicsIdle without a key.
    private func ready(_ hint: Hint, in controller: TerminalWindowController) -> Bool {
        let host: WindowColumnHost = controller.columnHost
        guard host.visible, host.shown.form != .hidden, !host.listShowing else { return false }
        switch hint {
        case .nextAgent:
            guard let window = waiting[hint]?.window, let row = host.column.list.row(showing: window) else { return false }
            return !WindowColumnView.shows(controller.indexID, in: row)
        case .columnBasics:
            return host.shown.form == .folded && HintCenter.sinceKey() >= Self.basicsIdle
        case .columnSide:
            return false
        }
    }

    /// H2's or H3's line; H2's only with a key for Go to Next Agent Needing You.
    private func line(for hint: Hint) -> HintLine? {
        switch hint {
        case .nextAgent:
            let key: String? = KeyboardShortcuts.shared.chord(for: "goToNextAgentNeedingYou:")?.display
            return HintWords.nextAgent(key: key).map { HintLine(.nextAgent, words: $0) }
        case .columnBasics:
            return HintLine(.columnBasics, words: HintWords.columnBasics)
        case .columnSide:
            return nil
        }
    }

    // MARK: up and down

    /// `line` up in `host`, counted from now, its × retiring it; H2 and H3 go after `stays`.
    @discardableResult
    private func put(_ line: HintLine, in host: WindowColumnHost, inList: Bool) -> Bool {
        guard shown == nil, host.showHint(line, inList: inList) else { return false }
        let hint: Hint = line.hint
        line.onClose = { [weak self] in
            HintCenter.shared.retire(hint, reason: .closed)
            self?.hide()
        }
        HintCenter.shared.noteShown(hint)
        shown = (hint, line, host)
        showings += 1
        if !inList { takeDownLater(showings) }
        return true
    }

    /// After `stays`, the hint put up as `showing` goes, unless the pointer is on it: then once it has left.
    private func takeDownLater(_ showing: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stays) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showings == showing, let shown = self.shown else { return }
                if shown.line.hovering { return self.takeDownLater(showing) }
                self.hide()
            }
        }
    }

    /// The hint up goes, its showing counted as long as it was up.
    func hide() {
        guard let up = shown else { return }
        shown = nil
        up.host.removeHint()
        HintCenter.shared.noteHidden(up.hint)
    }

    /// `host`'s hint lost its place: it goes.
    func placeWent(in host: WindowColumnHost) {
        guard let up = shown, up.host === host else { return host.removeHint() }
        hide()
    }

    /// HintCenter no longer has the hint up (it retired by use or ×, tips went off, or were reset): its line goes,
    /// and nothing more is counted. A hint at its last showing stays until it goes as it would.
    private func centerChanged() {
        guard let up = shown, HintCenter.shared.visible?.hint != up.hint else { return }
        shown = nil
        up.host.removeHint()
    }

    #if DEBUG
    /// For the self-test: nothing up or waiting, as at launch.
    func resetForTest() {
        hide()
        waiting = [:]
        looking?.invalidate()
        looking = nil
    }
    #endif
}
