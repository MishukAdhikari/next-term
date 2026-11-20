import NextTermCore
import SwiftTerm

extension BufferLine {
    /// The row's text as the screen shows it (ScreenText): an empty cell (character 0, one cleared or erased, or skipped
    /// by a cursor move) as a space, and a wide character's second cell left out. Every place Next Term reads a screen as
    /// text reads it this way: read_tab, the agent's status and its questions, the output it scans.
    func screenText(trimRight: Bool = true, startCol: Int = 0, endCol: Int = -1) -> String {
        translateToString(trimRight: trimRight, startCol: startCol, endCol: endCol, skipNullCellsFollowingWide: true) { cell in
            ScreenText.character(cell.getCharacter())
        }
    }

    /// Whether column `column` is the second cell of a wide character, which `screenText` leaves out.
    func isWideHalf(_ column: Int) -> Bool {
        column > 0 && column < count && self[column].getCharacter() == "\u{0}" && self[column - 1].width == 2
    }
}
