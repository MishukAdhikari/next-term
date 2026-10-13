import NextTermCore
import SwiftTerm

/// What a tab's screen shows, as its agent's own shapes read it.
extension TerminalTab {
    /// The tab shows OpenCode: OpenCode runs in it, or the program in front titles itself as OpenCode does
    /// ("OpenCode", "OC | <session>"), as OpenCode over ssh or in Next Term's own tmux does. Only such a tab reads
    /// OpenCode's screen shapes (AgentScreen.Opencode); every other agent's tab never sees them.
    var isOpencodeScreen: Bool {
        if AgentKind(program: status.program) == .opencode { return true }
        guard let programTitle else { return false }
        return AgentScreen.isOpencode(title: programTitle)
    }

    /// The menu under the question the tab's agent asks, for answer_agent and the choices list_tabs gives. OpenCode marks
    /// its selected button only by its background, so an OpenCode tab's menu is read from its rows with their colours
    /// (`liveRows`); every other tab's from its text, as before.
    func agentMenu() -> AgentMenu? {
        guard isOpencodeScreen else { return AgentScreen.menu(screenLines: screenTail()) }
        return AgentScreen.menu(screenRows: liveRows(), opencode: true)
    }

    /// Why the question on screen has no menu to pick from, when the screen says (OpenCode's forms with several
    /// questions or answers, and its reject step); nil otherwise.
    func menuRefusal() -> String? {
        guard isOpencodeScreen else { return nil }
        return AgentScreen.menuRefusal(screenRows: liveRows(), opencode: true)
    }

    /// `liveTail`, with each cell's background: the screen's last `count` rows that are live (below a restore's
    /// divider), each the text `liveTail` reads, one character per cell. Read only when a menu is, never on the status
    /// poll.
    func liveRows(_ count: Int = AgentScreen.scannedLines) -> [ScreenRow] {
        let terminal = view.getTerminal()
        guard let last = lastTextRow() else { return [] }
        let first = max(terminal.buffer.totalLinesTrimmed, last - count + 1)
        let rows: [ScreenRow] = (first...last).map { (row: Int) -> ScreenRow in
            Self.screenRow(terminal.getScrollInvariantLine(row: row))
        }
        guard let divider = restoreDivider else { return rows }
        let texts: [String] = rows.map { (row: ScreenRow) -> String in row.text }
        let live = ScrollbackText.below(divider: divider.text, row: divider.row, in: texts, first: first)
        return Array(rows.suffix(live.count))
    }

    /// A line's text, as `translateToString(trimRight: true)` gives it, and the background of each of its cells.
    static func screenRow(_ line: BufferLine?) -> ScreenRow {
        guard let line else { return ScreenRow("") }
        let text = line.translateToString(trimRight: true)
        let cells = min(line.count, line.getTrimmedLength())
        let colors: [Int] = (0..<max(0, cells)).map { (column: Int) -> Int in background(line[column].attribute) }
        return ScreenRow(text: text, cells: colors)
    }

    /// The background a cell shows, as an opaque number (ScreenRow): its foreground when the cell is reversed.
    static func background(_ attribute: Attribute) -> Int {
        let reversed = attribute.style.contains(.inverse)
        switch reversed ? attribute.fg : attribute.bg {
        case .trueColor(let red, let green, let blue):
            return ScreenRow.trueColor(red: Int(red), green: Int(green), blue: Int(blue))
        case .ansi256(let code):
            return ScreenRow.paletteColor(Int(code))
        case .defaultColor, .defaultInvertedColor:
            return reversed ? ScreenRow.defaultForeground : ScreenRow.defaultColor
        }
    }
}
