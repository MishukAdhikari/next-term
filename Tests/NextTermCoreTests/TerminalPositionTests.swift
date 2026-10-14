import Foundation
import Testing
@testable import NextTermCore

@Suite struct TerminalPositionTests {
    @Test func aStoredPositionReadsBackAndAnythingElseIsTheBottom() {
        #expect(TerminalPosition(stored: "right") == .right)
        #expect(TerminalPosition(stored: "top") == .top)
        #expect(TerminalPosition(stored: nil) == .bottom)
        #expect(TerminalPosition(stored: "") == .bottom)
        #expect(TerminalPosition(stored: "Right") == .bottom)
        #expect(TerminalPosition(stored: "middle") == .bottom)
        // The menus' and Settings' order and words.
        #expect(TerminalPosition.allCases.map(\.title) == ["Bottom", "Right", "Left", "Top"])
    }

    @Test func eachPositionKnowsItsOrientationAndSide() {
        #expect(TerminalPosition.allCases.filter(\.sideBySide) == [.right, .left])
        #expect(TerminalPosition.allCases.filter(\.terminalFirst) == [.left, .top])
    }

    @Test func onlyANewPositionLaysTheWorkAreaOutAgain() {
        // The first layout of a window.
        #expect(TerminalPosition.bottom.relaysWork(from: nil))
        // Chosen again (a menu, an import or its undo), or the sidebar moved: a folded terminal stays folded.
        for position in TerminalPosition.allCases { #expect(!position.relaysWork(from: position)) }
        // Moved, even within one orientation (bottom to top swaps the panes).
        #expect(TerminalPosition.top.relaysWork(from: .bottom))
        #expect(TerminalPosition.left.relaysWork(from: .right))
        #expect(TerminalPosition.right.relaysWork(from: .bottom))
    }

    @Test func withNoFileOpenTheNoticeSaysWhereTheTerminalGoes() {
        #expect(TerminalPosition.right.noticeWithNoFileOpen == "The terminal moves to the right when a file is open")
        #expect(TerminalPosition.top.noticeWithNoFileOpen == "The terminal moves to the top when a file is open")
    }
}

@Suite struct EditorShareTests {
    @Test func eachOrientationKeepsItsOwnShare() {
        #expect(EditorShare.key(sideBySide: true) != EditorShare.key(sideBySide: false))
        #expect(!EditorShare.keys.dropFirst().contains(EditorShare.sharedKey))
        #expect(Set(EditorShare.keys).count == 3)
        // Its own share wins over the one kept for both before.
        #expect(EditorShare.share(own: 0.4, shared: 0.7) == 0.4)
    }

    @Test func aShareNotKeptYetFallsBackToTheOldOneThenTheStandard() {
        // Someone who dragged before shares were kept apart: both orientations start from it.
        #expect(EditorShare.share(own: nil, shared: 0.45) == 0.45)
        #expect(EditorShare.share(own: nil, shared: nil) == EditorShare.standard)
        #expect(EditorShare.standard == 0.62)
        // Out of range is none: a stored 0 (nothing saved, as UserDefaults reads it) or a pane taking it all.
        #expect(EditorShare.share(own: 0, shared: 0.5) == 0.5)
        #expect(EditorShare.share(own: 0.95, shared: nil) == EditorShare.standard)
        #expect(EditorShare.share(own: Double.nan, shared: Double.infinity) == EditorShare.standard)
        #expect(EditorShare.share(own: 0.15, shared: nil) == 0.15)
        #expect(EditorShare.share(own: 0.9, shared: nil) == 0.9)
    }

    @Test func aShareKeptIsBroughtIntoRange() {
        #expect(EditorShare.kept(0.05) == 0.15)
        #expect(EditorShare.kept(0.99) == 0.9)
        #expect(EditorShare.kept(0.5) == 0.5)
    }

    @Test func theEditorGetsItsShareOfTheWorkArea() {
        // 1001 points across with a 1-point divider: the editor has 62 % (rounded), the terminal the rest.
        let editor = EditorShare.editorLength(share: 0.62, of: 1001, thickness: 1, editorMinimum: 240, terminalMinimum: 240)
        #expect(editor == 621)
    }

    @Test func neitherPaneGoesUnderItsMinimum() {
        // A share of 0.9 kept in a tall window, applied in one 600 high: the terminal keeps its 98.
        let squeezedTerminal = EditorShare.editorLength(share: 0.9, of: 600, thickness: 1, editorMinimum: 98, terminalMinimum: 98)
        #expect(squeezedTerminal == 501)
        #expect(600 - 1 - squeezedTerminal == 98)
        // A share of 0.15 beside the editor in a work area 700 wide: the editor keeps its 240.
        let squeezedEditor = EditorShare.editorLength(share: 0.15, of: 700, thickness: 1, editorMinimum: 240, terminalMinimum: 240)
        #expect(squeezedEditor == 240)
        // Exactly at both minimums.
        #expect(EditorShare.editorLength(share: 0.9, of: 481, thickness: 1, editorMinimum: 240, terminalMinimum: 240) == 240)
    }

    @Test func withNoRoomForBothMinimumsTheShareStands() {
        // 400 across cannot hold two panes of 240: neither minimum can be had.
        #expect(EditorShare.editorLength(share: 0.5, of: 400, thickness: 1, editorMinimum: 240, terminalMinimum: 240) == 200)
    }
}
