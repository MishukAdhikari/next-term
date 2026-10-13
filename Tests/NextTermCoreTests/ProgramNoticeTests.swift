import Foundation
import Testing
@testable import NextTermCore

@Suite struct ProgramNoticeTests {
    private func parse(_ code: Int, _ payload: String) -> ProgramNotice? {
        ProgramNotice.parse(code: code, payload: Array(payload.utf8))
    }

    private func isNotification(_ code: Int, _ payload: String) -> Bool {
        ProgramNotice.isNotification(code: code, payload: Array(payload.utf8))
    }

    @Test func titledAsOpencodeWritesIt() {
        // OpenTUI with a title: ESC ] 777 ; notify ; <title> ; <message> ESC \ (the title is the session's).
        #expect(parse(777, "notify;Fix the login test;Session error") == ProgramNotice(title: "Fix the login test", body: "Session error"))
    }

    @Test func untitledPutsTheMessageInTheTitlesPlace() {
        // OpenTUI with no title: ESC ] 777 ; notify ; <message> ; ESC \, so the message is the body.
        #expect(parse(777, "notify;Session error;") == ProgramNotice(title: nil, body: "Session error"))
        #expect(parse(777, "notify;Session done") == ProgramNotice(title: nil, body: "Session done"))
        #expect(parse(777, "notify;;Session error") == ProgramNotice(title: nil, body: "Session error"))
    }

    @Test func theFirstSemicolonEndsTheTitle() {
        // Another program's body may hold semicolons of its own.
        #expect(parse(777, "notify;Build;step 1; step 2;") == ProgramNotice(title: "Build", body: "step 1; step 2;"))
    }

    @Test func controlCharactersGo() {
        #expect(parse(777, "notify;Tests;Session\u{1b}[31m error\u{7}")?.body == "Session[31m error")
        #expect(parse(777, "notify;Tests;two\nlines\tand a tab")?.body == "two lines and a tab")
        #expect(parse(777, "notify;Ti\u{9b}tle;Done")?.title == "Title")
    }

    @Test func eachPartIsCutAt200Characters() {
        let long = String(repeating: "é", count: 500)
        let notice = parse(777, "notify;\(long);\(long)")
        #expect(notice?.title?.count == 200 && notice?.body.count == 200)
        #expect(parse(9, long)?.body.count == 200)
    }

    @Test func nothingToSayIsNoNotice() {
        // The tab still asks for attention (isNotification), with no words of its own.
        #expect(parse(777, "notify;;") == nil && isNotification(777, "notify;;"))
        #expect(parse(777, "notify; \u{1b} ;  ") == nil)
        #expect(parse(777, "notify;") == nil && isNotification(777, "notify;"))
        #expect(parse(9, "") == nil && isNotification(9, ""))
    }

    @Test func osc9IsTheBodyWhole() {
        // OpenTUI's OSC 9 is "<title>: <message>": shown as it is.
        #expect(parse(9, "Fix the login test: Session error") == ProgramNotice(title: nil, body: "Fix the login test: Session error"))
    }

    @Test func progressAndOtherPayloadsAreNotNotices() {
        #expect(!isNotification(9, "4;1;50") && parse(9, "4;1;50") == nil)
        #expect(!isNotification(777, "preexec;ls") && parse(777, "preexec;ls") == nil)
        #expect(!isNotification(52, "c;aGk=") && parse(52, "c;aGk=") == nil)
    }

    @Test func invalidUTF8IsReplacedNotRefused() {
        let payload: [UInt8] = Array("notify;Tests;bad ".utf8) + [0xFF, 0xFE] + Array(" bytes".utf8)
        #expect(ProgramNotice.parse(code: 777, payload: payload)?.body == "bad \u{FFFD}\u{FFFD} bytes")
    }

    @Test func aRepeatOfNextTermsOwnNoticeIsDropped() {
        #expect(ProgramNotice.isRepeat(lastOwnNoticeAt: 100, now: 109))
        #expect(!ProgramNotice.isRepeat(lastOwnNoticeAt: 100, now: 111))
        #expect(!ProgramNotice.isRepeat(lastOwnNoticeAt: nil, now: 5))
        #expect(!ProgramNotice.isRepeat(lastOwnNoticeAt: 100, now: 99))
    }

    @Test func tabsAskOpenTUIProgramsForOSC777() {
        var fresh: [String: String] = ["PATH": "/usr/bin"]
        ProgramNotice.prepare(&fresh)
        #expect(fresh == ["PATH": "/usr/bin", "OPENTUI_NOTIFICATION_PROTOCOL": "osc777"])
        // A value the user set on purpose stays.
        var own = ["OPENTUI_NOTIFICATION_PROTOCOL": "osc9"]
        ProgramNotice.prepare(&own)
        #expect(own["OPENTUI_NOTIFICATION_PROTOCOL"] == "osc9")
    }
}
