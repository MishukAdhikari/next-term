import Foundation
import Testing
@testable import NextTermCore

/// Rows of buttons as OpenCode draws them (permission.tsx, 1.19): the row on its own background, each button one cell
/// of padding either side of its label on the button's background, one cell of the row's between buttons. The colours
/// are made up.
enum ButtonRows {
    static let warm = ScreenRow.trueColor(red: 250, green: 178, blue: 80)
    static let grey = ScreenRow.trueColor(red: 40, green: 40, blue: 40)
    static let row = ScreenRow.trueColor(red: 30, green: 30, blue: 30)

    /// `labels` after the box's border, the label at `selected` on `chosen`, the others on `other`, then the hints.
    static func buttons(_ labels: [String], selected: Int?, chosen: Int = warm, other: Int = grey, row: Int = row,
                        lead: String = "  ┃  ") -> ScreenRow {
        var built = ScreenRow()
        built.append(lead, background: ScreenRow.defaultColor)
        for (index, label) in labels.enumerated() {
            built.append(" " + label + " ", background: index == selected ? chosen : other)
            built.append(" ", background: row)
        }
        built.append("        ctrl+f fullscreen  ⇆ select  enter confirm", background: row)
        return built
    }

    static let permission = ["Allow once", "Allow always", "Reject"]
}

@Suite struct ScreenRowTests {
    @Test func coloursAreOpaqueNumbers() {
        #expect(ScreenRow.trueColor(red: 0x12, green: 0x34, blue: 0x56) == 0x123456)
        #expect(ScreenRow.paletteColor(0) == 0x1000000 && ScreenRow.paletteColor(255) == 0x10000FF)
        // The palette's codes never meet a true colour, nor the defaults.
        #expect(ScreenRow.paletteColor(16) != ScreenRow.trueColor(red: 0, green: 0, blue: 16))
        #expect(ScreenRow.defaultColor < 0 && ScreenRow.defaultForeground < 0 && ScreenRow.defaultColor != ScreenRow.defaultForeground)
    }

    @Test func appendingMergesRunsOfOneColour() {
        var row = ScreenRow()
        row.append("ab", background: 1)
        row.append("c", background: 1)
        row.append("de", background: 2)
        #expect(row.text == "abcde")
        let runs: [ScreenRow.BackgroundRun] = [ScreenRow.BackgroundRun(start: 0, count: 3, color: 1),
                                               ScreenRow.BackgroundRun(start: 3, count: 2, color: 2)]
        #expect(row.backgrounds == runs)
        #expect(row.background(at: 2) == 1 && row.background(at: 3) == 2)
        // Past the runs, the default background.
        #expect(row.background(at: 9) == ScreenRow.defaultColor)
        #expect(ScreenRow("plain").background(at: 0) == ScreenRow.defaultColor)
    }

    @Test func cellsGiveRunsOnlyWhenEachCellIsOneCharacter() {
        let row = ScreenRow(text: "ab c", cells: [5, 5, 6, 6])
        let runs: [ScreenRow.BackgroundRun] = [ScreenRow.BackgroundRun(start: 0, count: 2, color: 5),
                                               ScreenRow.BackgroundRun(start: 2, count: 2, color: 6)]
        #expect(row.backgrounds == runs)
        // A cell that joined the character before it: where each colour falls is unknown, so none is kept.
        let joined = ScreenRow(text: "e\u{301}x", cells: [5, 6, 5])
        #expect(joined.backgrounds.isEmpty && joined.text == "e\u{301}x")
    }

    @Test func theOneOnItsOwnBackgroundIsSelected() {
        let labels = ButtonRows.permission
        #expect(ButtonRows.buttons(labels, selected: 0).selected(among: labels) == 0)
        #expect(ButtonRows.buttons(labels, selected: 1).selected(among: labels) == 1)
        #expect(ButtonRows.buttons(labels, selected: 2).selected(among: labels) == 2)
        // The unselected buttons on the row's own background (a theme with no menu colour of its own).
        let flat = ButtonRows.buttons(labels, selected: 2, other: ButtonRows.row)
        #expect(flat.selected(among: labels) == 2)
        // A 256-colour theme, and the default background for the others.
        let palette = ButtonRows.buttons(labels, selected: 1, chosen: ScreenRow.paletteColor(214), other: ScreenRow.defaultColor)
        #expect(palette.selected(among: labels) == 1)
    }

    @Test func noSelectionWhenTheBackgroundsDoNotSayOne() {
        let labels = ButtonRows.permission
        // All three on one grey.
        #expect(ButtonRows.buttons(labels, selected: nil).selected(among: labels) == nil)
        // Three backgrounds: two differ from a third.
        var three = ScreenRow()
        three.append("   ", background: ButtonRows.row)
        three.append(" Allow once ", background: 1)
        three.append(" ", background: ButtonRows.row)
        three.append(" Allow always ", background: 2)
        three.append(" ", background: ButtonRows.row)
        three.append(" Reject ", background: 3)
        #expect(three.selected(among: labels) == nil)
        // A label not on the row, or out of order.
        #expect(ButtonRows.buttons(labels, selected: 0).selected(among: ["Allow once", "Deny"]) == nil)
        #expect(ButtonRows.buttons(labels, selected: 0).selected(among: ["Reject", "Allow once"]) == nil)
        // A label whose cells are not all on one background.
        var split = ScreenRow()
        split.append("   ", background: ButtonRows.row)
        split.append(" Allow", background: ButtonRows.warm)
        split.append(" once ", background: ButtonRows.grey)
        split.append(" ", background: ButtonRows.row)
        split.append(" Allow always ", background: ButtonRows.grey)
        split.append(" ", background: ButtonRows.row)
        split.append(" Reject ", background: ButtonRows.grey)
        #expect(split.selected(among: labels) == nil)
        // No colours at all (the text alone).
        #expect(ScreenRow(ButtonRows.buttons(labels, selected: 0).text).selected(among: labels) == nil)
    }

    @Test func twoButtonsAreToldByTheRowsOwnBackground() {
        let labels = ["Confirm", "Cancel"]
        // The unselected button on the row's background (OpenCode's default: its menu colour is the row's).
        #expect(ButtonRows.buttons(labels, selected: 0, other: ButtonRows.row).selected(among: labels) == 0)
        #expect(ButtonRows.buttons(labels, selected: 1, other: ButtonRows.row).selected(among: labels) == 1)
        // Both on backgrounds of their own: which one is selected is not shown.
        #expect(ButtonRows.buttons(labels, selected: 0).selected(among: labels) == nil)
        // Both on the row's.
        #expect(ButtonRows.buttons(labels, selected: nil, other: ButtonRows.row).selected(among: labels) == nil)
        // Side by side with no gap of the row's between them: nothing to tell them by.
        var tight = ScreenRow()
        tight.append(" Confirm ", background: ButtonRows.warm)
        tight.append(" Cancel ", background: ButtonRows.row)
        #expect(tight.selected(among: labels) == nil)
    }

    @Test func wideCharactersBeforeTheLabelsChangeNothing() {
        let labels = ButtonRows.permission
        // "△" and a CJK name earlier on the row: offsets are in the row's characters.
        let lead = "  ┃ △ 日本語のファイル  "
        #expect(ButtonRows.buttons(labels, selected: 2, lead: lead).selected(among: labels) == 2)
        #expect(ButtonRows.buttons(labels, selected: 0, lead: lead).selected(among: labels) == 0)
    }
}
