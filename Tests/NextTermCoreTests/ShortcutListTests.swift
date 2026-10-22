import Foundation
import Testing
@testable import NextTermCore

/// The shortcut picker's parsing of `shortcuts list --show-identifiers`, the run's arguments, and the lines a run
/// ends with. Every name and identifier here is made up.
@Suite struct ShortcutListTests {
    let inbox = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
    let plan = "11111111-2222-4333-8444-555555555555"

    @Test func parsesNameAndIdentifier() {
        let found = ShortcutList.parse("Add to Inbox (\(inbox))\n")
        #expect(found == [ShortcutList.Shortcut(id: inbox, name: "Add to Inbox")])
    }

    @Test func theLastParenthesisedIdentifierIsTheId() {
        let found = ShortcutList.parse("Plan (Q3) (\(plan))")
        #expect(found == [ShortcutList.Shortcut(id: plan, name: "Plan (Q3)")])
    }

    @Test func skipsLinesWithoutAnIdentifier() {
        let lower = inbox.lowercased()
        let short = String(inbox.dropLast())
        let output = [
            "No identifier here", "", "   ", "Lower (\(lower))", "Short (\(short))", "(\(inbox))",
            "Trailing (\(inbox)) more", "Kept (\(plan))",
        ].joined(separator: "\n")
        #expect(ShortcutList.parse(output) == [ShortcutList.Shortcut(id: plan, name: "Kept")])
    }

    @Test func readsCarriageReturnsAndSpacesAround() {
        let output = "  One (\(inbox))  \r\nTwo (\(plan))\r\n"
        let names = ShortcutList.parse(output).map(\.name)
        #expect(names == ["One", "Two"])
    }

    @Test func aNameWithControlCharactersIsSkipped() {
        let output = "Bad\u{7}Name (\(inbox))\nGood (\(plan))"
        #expect(ShortcutList.parse(output).map(\.id) == [plan])
    }

    @Test func listedFindsTheIdentifier() {
        let list = ShortcutList.parse("Add to Inbox (\(inbox))")
        #expect(ShortcutList.isListed(inbox, in: list))
        #expect(!ShortcutList.isListed(plan, in: list))
    }

    @Test func runArgumentsNameTheShortcutByIdAndReadStdin() {
        #expect(ShortcutList.listArguments == ["list", "--show-identifiers"])
        #expect(ShortcutList.runArguments(id: inbox) == ["run", inbox, "--input-path", "-"])
        // Never an option or a name: only an identifier reaches the command.
        #expect(ShortcutList.runArguments(id: "--help") == nil)
        #expect(ShortcutList.runArguments(id: "Add to Inbox") == nil)
        #expect(ShortcutList.runArguments(id: "") == nil)
    }

    @Test func linesForEachEnd() {
        #expect(ShortcutList.line(.finished(0), name: "Add to Inbox") == .sent("Sent to the shortcut “Add to Inbox”."))
        let failed = "The shortcut “Add to Inbox” didn’t finish. Nothing more was sent."
        #expect(ShortcutList.line(.finished(1), name: "Add to Inbox") == .failed(failed))
        #expect(ShortcutList.line(.timedOut, name: "Add to Inbox") == .failed(failed))
        #expect(ShortcutList.line(.couldntStart, name: "Add to Inbox") == .failed(failed))
        #expect(ShortcutList.line(.stopped, name: "Add to Inbox") == .stopped(ShortcutList.stoppedLine))
        #expect(ShortcutList.stoppedLine == "The shortcut was stopped. Nothing more was sent.")
        #expect(ShortcutList.goneLine == "The shortcut is gone. Choose another in Settings › Tasks.")
    }

    @Test func theTitleIsTheInputsFirstLine() {
        #expect(ShortcutList.title(ofInput: "Fix the login\n\nPlanned: 2026-10-19\n\nSteps") == "Fix the login")
        #expect(ShortcutList.title(ofInput: "Only a title") == "Only a title")
    }

    @Test func theLimitIsAMinute() {
        #expect(ShortcutList.limit == 60)
    }
}
