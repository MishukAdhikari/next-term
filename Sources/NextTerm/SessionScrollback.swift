import Foundation
import NextTermCore
import SwiftTerm

/// Scrollback on the update and quit paths (R4, KTD9). At an update quit, or a quit under "Resume where I left off", each
/// tab's scrollback is read from its terminal (`capture`), with the id its pane's record will name it by, and made into
/// masked text (`ScrollbackText`), which `ScrollbackText.save` writes to a private file in the sessions folder named for
/// the quit and that id. At the next launch only the restore of that quit reads the files, and only those named for it;
/// each is removed as it is read, and every other one unread (`ScrollbackText.take`). Any other launch that holds the
/// folder removes them all unread (`ScrollbackText.removeAll`). A restored tab shows its text above a dim divider before
/// its shell starts (`TerminalTab.restoredScrollback`).
enum SessionScrollback {
    /// The most rows read from a terminal: a pane keeps `ScrollbackText.Limits.standard` lines at most, and a terminal can
    /// keep 100,000.
    static let rowsRead = 20_000
    /// How many echoes of commands that held a secret a tab keeps, the latest.
    static let droppedKept = 256
    /// The most lines of a command's echo read: its line, and one for each continuation row it was typed over.
    static let echoLines = 32

    /// What a tab's terminal held, read on the main thread. `text` makes it the saved text, on any thread.
    struct Capture: Sendable {
        /// The id the pane's record names its file by, chosen here: the state file that names it is written before the
        /// file (KTD18).
        let id = UUID()
        let rows: [ScrollbackText.Row]
        /// The scroll-invariant row of the first; nil for the normal buffer read as text behind the alternate screen.
        let firstRow: Int?
        let dropped: [ScrollbackText.Echo]
        let extent: ScrollbackText.Extent

        func text(limits: ScrollbackText.Limits = .standard) -> String {
            ScrollbackText.saved(rows, firstRow: firstRow, dropped: dropped, extent: extent, limits: limits)
        }
    }

    /// What `tab` holds now. With the normal buffer in front, its rows with their wrap flags, read as `clickedLine` reads
    /// them. With the alternate screen in front (an agent's or an editor's), the normal buffer behind it, which only reads
    /// as text, without wrap flags, each row noted as filling the width or not. An agent's pane keeps only what came before
    /// its command, and nothing when that is not known (a shell without the integration, a tab on a server).
    static func capture(_ tab: TerminalTab) -> Capture {
        let terminal = tab.view.getTerminal()
        let agent = tab.status.running && tab.status.kind == .agent
        let extent: ScrollbackText.Extent = agent ? .before(tab.runningEcho) : .all
        if terminal.isCurrentBufferAlternate {
            let rows = ScrollbackText.rows(bufferData: terminal.getBufferAsData(kind: .normal), columns: terminal.cols)
            return Capture(rows: Array(rows.suffix(rowsRead)), firstRow: nil, dropped: tab.droppedEchoes, extent: extent)
        }
        guard let last = tab.lastTextRow() else {
            return Capture(rows: [], firstRow: 0, dropped: [], extent: extent)
        }
        let first = max(terminal.buffer.totalLinesTrimmed, last - rowsRead + 1)
        var rows: [ScrollbackText.Row] = []
        rows.reserveCapacity(last - first + 1)
        var line = terminal.getScrollInvariantLine(row: first)
        for row in first...last {
            guard let current = line else { break }
            line = terminal.getScrollInvariantLine(row: row + 1)
            rows.append(ScrollbackText.Row(text(of: current, wrapsOn: line?.isWrapped == true), wrapped: current.isWrapped))
        }
        return Capture(rows: rows, firstRow: first, dropped: tab.droppedEchoes, extent: extent)
    }

    /// Where the command `typed` showed as it starts: the last lines with text, its line and one for each continuation
    /// row it was typed over, read as `capture` reads them. Nil on the alternate screen, or with no text on the screen.
    static func echo(in tab: TerminalTab, typed: String) -> ScrollbackText.Echo? {
        let terminal = tab.view.getTerminal()
        guard !terminal.isCurrentBufferAlternate, let last = tab.lastTextRow() else { return nil }
        let top = terminal.buffer.totalLinesTrimmed
        let count = min(echoLines, typed.components(separatedBy: "\n").count)
        var shown: [String] = []
        var end = last
        while shown.count < count, end >= top {
            var start = end
            while start > top, terminal.getScrollInvariantLine(row: start)?.isWrapped == true { start -= 1 }
            var text = ""
            for row in start...end {
                guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
                text += Self.text(of: line, wrapsOn: terminal.getScrollInvariantLine(row: row + 1)?.isWrapped == true)
            }
            shown.insert(text, at: 0)
            end = start - 1
        }
        return shown.isEmpty ? nil : ScrollbackText.Echo(row: end + 1, shown: shown)
    }

    /// A row's text: the second cell of a wide character skipped, and the cells after its last character kept only when
    /// the line wraps on from it, as the wrapped line holds them.
    private static func text(of line: BufferLine, wrapsOn: Bool) -> String {
        line.translateToString(trimRight: !wrapsOn, skipNullCellsFollowingWide: true)
    }
}
