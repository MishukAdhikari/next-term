import Foundation
import Testing
@testable import NextTermCore

/// OSC 7501 as revision 0.4 of the spec writes it: the query and its answer, reports and their limits, and the records.
@Suite struct ProgramStatusTests {
    func parse(_ text: String) -> ProgramStatus.Parsed? { ProgramStatus.parse(Array(text.utf8)) }
    func report(_ text: String) -> ProgramStatus.Report? {
        if case .report(let report) = parse(text) { return report }
        return nil
    }
    func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    @Test func theQueryIsAnsweredWithEveryStateAndKind() {
        #expect(parse("?") == .query)
        #expect(ProgramStatus.reply == "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\")
    }

    @Test func theSpecsExamplesRead() {
        #expect(report("state=working:app=brew:msg=SW5zdGFsbGluZyB1cGRhdGVz")
                == ProgramStatus.Report(state: .working, app: "brew", message: "Installing updates"))
        #expect(report("state=blocked:kind=auth:app=brew:msg=UGFzc3dvcmQgcmVxdWlyZWQgdG8gaW5zdGFsbCB1cGRhdGVz")
                == ProgramStatus.Report(state: .blocked, kind: .auth, app: "brew", message: "Password required to install updates"))
        #expect(report("state=done:app=brew:msg=VXBncmFkZWQgMTIgcGFja2FnZXM=")?.message == "Upgraded 12 packages")
    }

    @Test func aReportWithoutAStateItNamesIsDiscarded() {
        #expect(parse("app=claude") == nil)
        #expect(parse("state=sleeping") == nil)
        #expect(parse("") == nil)
        #expect(report("state=clear")?.state == .clear)
    }

    @Test func malformedPairsAreSkippedAndUnknownKeysIgnored() {
        // No =, an empty key, a key with capitals or past 16 bytes, a byte outside the value set: each pair alone goes.
        let read = report("nothing:=x:App=x:averyveryverylongkey=x:title=a b:state=idle:colour=blue:app=codex")
        #expect(read == ProgramStatus.Report(state: .idle, app: "codex"))
        // The last value of a repeated key wins.
        #expect(report("state=working:state=idle")?.state == .idle)
    }

    @Test func kindAndProgressGoOnlyWithTheirStates() {
        #expect(report("state=blocked:kind=question")?.kind == .question)
        #expect(report("state=blocked:kind=coffee")?.kind == nil)
        #expect(report("state=working:kind=permission")?.kind == nil)
        #expect(report("state=working:progress=40")?.progress == 40)
        #expect(report("state=blocked:progress=100")?.progress == 100)
        #expect(report("state=working:progress=101")?.progress == nil)
        #expect(report("state=idle:progress=40")?.progress == nil)
    }

    @Test func wordsAreBase64OfOneLineWithOrWithoutPadding() {
        #expect(report("state=done:msg=\(base64("ok").replacingOccurrences(of: "=", with: ""))")?.message == "ok")
        #expect(report("state=done:title=\(base64("Build \u{2014} tests"))")?.title == "Build \u{2014} tests")
        // Base64 that doesn't decode, or words with a control character (a newline, an escape, C1), discard the report;
        // a byte outside the value set only skips its pair.
        #expect(parse("state=done:msg=a") == nil)
        #expect(report("state=done:msg=@@@") == ProgramStatus.Report(state: .done))
        #expect(parse("state=done:msg=\(base64("two\nlines"))") == nil)
        #expect(parse("state=done:msg=\(base64("\u{1b}[31mred"))") == nil)
        #expect(parse("state=done:title=\(base64("a\u{85}b"))") == nil)
    }

    @Test func limitsDiscardTheWholeReport() {
        #expect(report("state=done:msg=\(base64(String(repeating: "a", count: 2048)))")?.message?.count == 2048)
        #expect(parse("state=done:msg=\(base64(String(repeating: "a", count: 2049)))") == nil)
        #expect(parse("state=done:title=\(base64(String(repeating: "a", count: 193)))") == nil)
        #expect(report("state=idle:id=\(Array(repeating: "s", count: 8).joined(separator: "/"))")?.id != nil)
        #expect(parse("state=idle:id=\(Array(repeating: "s", count: 9).joined(separator: "/"))") == nil)
        #expect(parse("state=idle:id=\(String(repeating: "s", count: 33))") == nil)
        #expect(parse("state=idle:id=a//b") == nil)
        #expect(ProgramStatus.parse(Array(repeating: UInt8(ascii: "a"), count: ProgramStatus.maxPayload + 1)) == nil)
        // An app outside its own bytes is as if absent.
        #expect(report("state=idle:app=a,b")?.app == nil)
    }

    @Test func recordsReplaceClearAndAddUp() {
        var records = ProgramStatus.Records()
        #expect(records.activity == nil)
        records.apply(ProgramStatus.Report(state: .working, message: "Thinking"))
        #expect(records.activity == .working)
        // A report replaces its record whole: the message is gone.
        records.apply(ProgramStatus.Report(state: .idle))
        #expect(records[nil] == ProgramStatus.Report(state: .idle) && records.activity == .stopped)
        // A record beneath the root working keeps the program working; blocked anywhere asks, the root's first.
        records.apply(ProgramStatus.Report(state: .working, id: "task/1"))
        #expect(records.activity == .working)
        records.apply(ProgramStatus.Report(state: .blocked, id: "task/2", kind: .permission, message: "Edit a.swift?"))
        #expect(records.activity == .asking(.permission, "Edit a.swift?"))
        records.apply(ProgramStatus.Report(state: .blocked, kind: .question))
        #expect(records.activity == .asking(.question, nil))
        // clear with an id removes it and what is beneath it; with none, everything.
        records.apply(ProgramStatus.Report(state: .clear, id: "task"))
        #expect(records["task/1"] == nil && records["task/2"] == nil && records[nil]?.state == .blocked)
        records.apply(ProgramStatus.Report(state: .clear))
        #expect(records.isEmpty && records.activity == nil)
    }

    @Test func theLeastRecentlyUpdatedRecordMakesRoom() {
        var records = ProgramStatus.Records()
        for index in 0..<ProgramStatus.Records.limit { records.apply(ProgramStatus.Report(state: .idle, id: "r\(index)")) }
        records.apply(ProgramStatus.Report(state: .working, id: "r0")) // updated, so r1 is now the oldest
        records.apply(ProgramStatus.Report(state: .idle, id: "new"))
        #expect(records["r0"]?.state == .working && records["r1"] == nil && records["new"] != nil)
    }

    @Test func aBlockedProgramWithoutWordsSaysWhatItWaitsFor() {
        #expect(ProgramStatus.words(for: .permission) == "Permission needed")
        #expect(ProgramStatus.words(for: .auth) == "Sign-in needed")
        #expect(ProgramStatus.words(for: nil) == "Waiting for you")
    }
}
