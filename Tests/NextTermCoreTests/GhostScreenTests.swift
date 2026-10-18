import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostScreenTests {
    typealias Span = GhostScreen.Span

    @Test func theGhostFollowsTheWholeLine() {
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 10, columns: 80, rightCells: 0, ghostCells: 6) == [Span(row: 5, columns: 10..<16)])
        // Wrapping at the edge, as zsh draws it.
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 76, columns: 80, rightCells: 0, ghostCells: 6)
                == [Span(row: 5, columns: 76..<80), Span(row: 6, columns: 0..<2)])
        // zsh draws POSTDISPLAY after the whole buffer: past what is right of the cursor.
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 10, columns: 80, rightCells: 3, ghostCells: 6) == [Span(row: 5, columns: 13..<19)])
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 78, columns: 80, rightCells: 4, ghostCells: 2) == [Span(row: 6, columns: 2..<4)])
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 10, columns: 80, rightCells: 0, ghostCells: 0).isEmpty)
        #expect(GhostScreen.span(caretRow: 5, caretColumn: 10, columns: 0, rightCells: 0, ghostCells: 3).isEmpty)
    }

    @Test func cellsAreCountedAsTheTerminalShowsThem() {
        #expect(GhostScreen.cells("eckout main") == 11)
        // A wide character takes two cells, a combining mark none.
        #expect(GhostScreen.cells("日本") == 4)
        #expect(GhostScreen.cells("cafe\u{301}") == 4)
        #expect(GhostScreen.cells("é😀") == 3)
        // zsh shows a control character as ^X, a line break as a new row: not placed.
        #expect(GhostScreen.cells("a\tb") == nil)
        #expect(GhostScreen.cells("a\nb") == nil)
        #expect(GhostScreen.cells("") == 0)
    }

    @Test func theCellsMustShowTheGhost() {
        #expect(GhostScreen.matches(cells: "eckout main", postdisplay: "eckout main", width: 11))
        // Cut short where the screen ends: its start is enough.
        #expect(GhostScreen.matches(cells: "eckout", postdisplay: "eckout main", width: 6))
        // An async suggestion newer than the report: something else is drawn there.
        #expect(!GhostScreen.matches(cells: "erry-pick a", postdisplay: "eckout main", width: 11))
        #expect(!GhostScreen.matches(cells: "erry", postdisplay: "eckout main", width: 4))
        #expect(!GhostScreen.matches(cells: "", postdisplay: "eckout main", width: 0))
        // A wide character that would be cut at the edge is not drawn there.
        #expect(GhostScreen.matches(cells: "日本", postdisplay: "日本語", width: 5))
        #expect(GhostScreen.matches(cells: "日本語", postdisplay: "日本語", width: 6))
    }

    @Test func inputSaysWhatIsTyped() throws {
        let report = GhostProtocol.BufferReport(line: 2, gen: 9, cursor: 6, buffer: "git ch", postdisplay: "eckout main")
        let input = try #require(InputReport.make(from: report, suggestion: report.postdisplay, mask: { $0 }))
        #expect(input["line"] as? String == "git ch" && input["cursor"] as? Int == 6 && input["suggestion"] as? String == "eckout main")
        // No plugin ghost found on screen: no suggestion.
        let unseen = try #require(InputReport.make(from: report, suggestion: nil, mask: { $0 }))
        #expect(unseen["suggestion"] == nil && unseen["line"] as? String == "git ch")
        #expect(InputReport.make(from: report, suggestion: "", mask: { $0 })?["suggestion"] == nil)
        // A line the hook couldn't send (over its cap): no input at all.
        let long = GhostProtocol.BufferReport(line: 2, gen: 9, cursor: 3000, buffer: nil)
        #expect(InputReport.make(from: long, suggestion: nil, mask: { $0 }) == nil)
        // Both texts are masked as the rest of the reply.
        let secret = GhostProtocol.BufferReport(line: 2, gen: 9, cursor: 12, buffer: "echo s3cr3t", postdisplay: "-and-s3cr3t")
        let masked = try #require(InputReport.make(from: secret, suggestion: secret.postdisplay, mask: { $0.replacingOccurrences(of: "s3cr3t", with: "•••") }))
        #expect(masked["line"] as? String == "echo •••" && masked["suggestion"] as? String == "-and-•••")
    }

    @Test func aReportIsCurrentUntilTheNextWrite() {
        #expect(GhostScreen.isCurrent(reportWrites: 7, currentWrites: 7))
        #expect(!GhostScreen.isCurrent(reportWrites: 7, currentWrites: 8))
    }
}
