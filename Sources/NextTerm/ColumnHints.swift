import AppKit
import NextTermCore

/// The window column's three hints (plan 033 R3), each on its pull trigger, put up through HintCenter's rules:
/// - H1, column side: the hover list has stayed open a second. At its foot, a button that moves the column to the other
///   edge, which is the move itself and retires the hint (AppDelegate.setWindowColumnSide, by any route).
/// - H2, next agent: a needs-you or failed mark has appeared for a window that isn't the one in front. At the front
///   window's column foot, Go to Next Agent Needing You's key, as the user has it; no key, no hint.
/// - H3, column basics: the column has just come (a second window opened), and the user has left the keys alone for 3 s.
///   Beside the rail's foot, how to see the windows and keep the column open.
/// - H8, fold worktrees: a repository's row with two or more worktree rows under it, unfolded. In the hover list once
///   it has stayed open a second (when H1 is done), or at the pinned column's foot when a worktree's row joins it. A
///   button that folds them, which is the fold itself and retires the hint (WindowColumns.toggleFold, by any route).
///   Never beside the rail: the fold lives in the unfolded rows.
/// - H5, switch back: the second switch to another window by a click on its row in one session. At the window come
///   forward's column foot, Open Project…'s key as the user has it, then ↩; no key, no hint. Going to an open
///   project's window from the Welcome list retires it (⌘O then ↩ among them), and so does open_project on one.
/// Each is put up on HintStage, which holds one hint up across the app and lets a trigger whose moment is not right
/// wait: H2 while the mark is there, H3 while the column shows. H1's moment is the list's: it is not kept. H2 and H3 go
/// after a few seconds (longer while the pointer is on them), H1 with its list, and any hint when its place goes.
@MainActor
final class ColumnHints {
    static let shared = ColumnHints()

    /// How long the hover list stays open before H1 may show. The self-test stands in for these.
    static var listDwell: TimeInterval = 1
    /// How long the keys must have been left alone before H3 shows.
    static var basicsIdle: TimeInterval = 3

    /// Switches by a click on another window's row since launch: H5 waits for the second.
    private var switches = 0

    private init() {}

    // MARK: triggers

    /// H1's trigger: `host`'s list has stayed open for listDwell. With H1 done, H8's, for a foldable row in it.
    func listStayedOpen(in host: WindowColumnHost) {
        guard !HintStage.suppressed, let controller = host.window?.windowController as? TerminalWindowController else { return }
        guard HintCenter.shared.record(.columnSide).retired == nil else {
            guard let line = foldLine(host.column.list), HintCenter.shared.eligible(.foldWorktrees, in: controller) else { return }
            HintStage.shared.put(line, in: host)
            return
        }
        guard HintCenter.shared.eligible(.columnSide, in: controller) else { return }
        let words = HintWords.columnSide(onRight: host.columnOnRight)
        let line = HintLine(.columnSide, words: words.lead + " " + words.words, help: words.help, action: { [weak host] in
            guard let host else { return }
            AppDelegate.shared.setWindowColumnSide(host.columnOnRight ? .left : .right)
        })
        line.button?.setAccessibilityLabel(words.words)
        HintStage.shared.put(line, in: host)
    }

    /// H3's trigger: the column has just come in every window.
    func columnAppeared() {
        wait(for: .columnBasics, window: nil)
    }

    /// H2's trigger: the column's rows went from `old` to `new`; a mark new in a window behind waits for its moment.
    func rowsChanged(from old: WindowColumnList, to new: WindowColumnList) {
        worktreesJoined(from: old, to: new)
        let rows: [WindowColumnRow] = new.newlyUrgent(since: old)
        guard !rows.isEmpty else { return }
        let front: Int? = HintStage.front()?.indexID
        guard let row = rows.first(where: { (row: WindowColumnRow) -> Bool in front.map { !WindowColumnView.shows($0, in: row) } ?? true })
        else { return }
        wait(for: .nextAgent, window: row.id)
    }

    /// H5's trigger: a click on window `id`'s row in `from`'s column brings it forward; the second such switch waits for
    /// that window's moment.
    func columnSwitched(to id: Int, from: TerminalWindowController) {
        guard id != from.indexID else { return }
        switches += 1
        guard switches >= 2 else { return }
        let left: String? = from.project.map { URL(fileURLWithPath: $0).lastPathComponent }
        HintStage.shared.wait(for: .switchBack, holds: { AppDelegate.shared.windowColumns.visible }, show: { [weak self] controller in
            guard let self, controller.indexID == id, self.ready(.switchBack, window: nil, in: controller),
                  HintCenter.shared.eligible(.switchBack, in: controller) else { return false }
            let key: String? = KeyboardShortcuts.shared.chord(for: "openProjectPanel:")?.display
            guard let words = HintWords.switchBack(key: key) else { return false }
            return HintStage.shared.put(HintLine(.switchBack, words: words, help: HintWords.switchBackHelp(project: left)), in: controller.columnHost)
        })
    }

    /// H8's trigger in the pinned column: the rows went from `old` to `new`, and a repository's row has a worktree
    /// more under it.
    private func worktreesJoined(from old: WindowColumnList, to new: WindowColumnList) {
        guard AppDelegate.shared.windowColumnExpanded, new.newlyFoldable(since: old) != nil else { return }
        wait(for: .foldWorktrees, window: nil)
    }

    /// "Fold worktrees", for the first foldable row in `list`: a button that folds it, unless it was folded meanwhile.
    func foldLine(_ list: WindowColumnList) -> HintLine? {
        guard let row = list.foldable().first?.row, let key = row.foldKey else { return nil }
        let words = HintWords.foldWorktrees(repository: row.name)
        let line = HintLine(.foldWorktrees, words: words.words, help: words.help, action: {
            let columns: WindowColumns = AppDelegate.shared.windowColumns
            if !columns.folded.contains(key) { columns.toggleFold(key) }
        })
        line.mayGoBeside = false
        return line
    }

    /// H2 or H3 waits on the stage for its moment, `window` being H2's window with the mark.
    private func wait(for hint: Hint, window: Int?) {
        HintStage.shared.wait(for: hint, holds: { [weak self] in self?.holds(hint, window: window) ?? false }, show: { [weak self] controller in
            guard let self, self.ready(hint, window: window, in: controller), HintCenter.shared.eligible(hint, in: controller),
                  let line = self.line(for: hint) else { return false }
            return HintStage.shared.put(line, in: controller.columnHost)
        })
    }

    /// Whether `hint`'s trigger still holds: the column shown, H2's mark still there, and H8's column pinned with a
    /// foldable row.
    private func holds(_ hint: Hint, window: Int?) -> Bool {
        let columns: WindowColumns = AppDelegate.shared.windowColumns
        guard columns.visible else { return false }
        if hint == .foldWorktrees { return AppDelegate.shared.windowColumnExpanded && !columns.list.foldable().isEmpty }
        guard hint == .nextAgent else { return true }
        guard let window, let urgent = columns.list.row(showing: window)?.urgent else { return false }
        return urgent == .attention || urgent == .failed
    }

    /// Whether `controller` is the place for `hint` now: its column showing (H3: as the rail, which resting on opens),
    /// H2's mark in another window, and H3 after basicsIdle without a key.
    private func ready(_ hint: Hint, window: Int?, in controller: TerminalWindowController) -> Bool {
        let host: WindowColumnHost = controller.columnHost
        guard host.visible, host.shown.form != .hidden, !host.listShowing else { return false }
        switch hint {
        case .nextAgent:
            guard let window, let row = host.column.list.row(showing: window) else { return false }
            return !WindowColumnView.shows(controller.indexID, in: row)
        case .columnBasics:
            return host.shown.form == .folded && HintCenter.sinceKey() >= Self.basicsIdle
        case .foldWorktrees:
            return host.shown.form == .expanded
        case .switchBack:
            return true
        default:
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
        case .foldWorktrees:
            return foldLine(AppDelegate.shared.windowColumns.list)
        default:
            return nil
        }
    }
}
