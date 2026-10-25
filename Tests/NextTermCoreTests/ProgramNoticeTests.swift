import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

@Suite struct ProgramNoticeTests {
    /// A made-up stored value, as AgentQuestionMaskTests has: no pattern catches it.
    static let stored = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"

    /// A mask made from the stored value's marks, as the app makes it. Never `SecretMask.current`: tests run in parallel.
    static func storedMask() -> SecretMask {
        let key = SymmetricKey(size: .bits256)
        return SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: stored), key: key))
    }

    /// Whether `text` shows any 5 characters in a row of the stored value.
    static func showsPart(_ text: String) -> Bool {
        let characters = Array(stored)
        return (0...(characters.count - 5)).contains { text.contains(String(characters[$0..<$0 + 5])) }
    }

    private func parse(_ code: Int, _ payload: String, mask: SecretMask = .empty) -> ProgramNotice? {
        ProgramNotice.parse(code: code, payload: Array(payload.utf8), mask: mask)
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

    @Test func aStoredKeyAcrossTheCutShowsNone() throws {
        // The key at 181..<209, across the cut at 200: masked first, so none of it shows. Cut first, its start showed.
        let filler = String(repeating: "x", count: 180)
        let mask = Self.storedMask()
        let body = try #require(parse(777, "notify;Tests;\(filler) \(Self.stored) and more", mask: mask)?.body)
        #expect(body == filler + " ••• and more" && !Self.showsPart(body))
        let title = try #require(parse(777, "notify;\(filler) \(Self.stored);Session error", mask: mask)?.title)
        #expect(title == filler + " •••" && !Self.showsPart(title))
        let nine = try #require(parse(9, "\(filler) \(Self.stored)", mask: mask)?.body)
        #expect(nine == filler + " •••")
        let unmasked = try #require(parse(9, "\(filler) \(Self.stored)")?.body)
        #expect(Self.showsPart(mask.mask(unmasked))) // masked after the cut, the key's start shows
    }

    @Test func aKeyJoinedByControlCharactersIsMaskedToo() {
        // Control characters go before the mask looks, so a key they split is whole again, and masked.
        let split = String(Self.stored.prefix(10)) + "\u{1b}" + String(Self.stored.dropFirst(10))
        let body = parse(777, "notify;Tests;key \(split) leaked", mask: Self.storedMask())?.body
        #expect(body == "key ••• leaked")
    }

    @Test func conEmusNumberedCommandsAreNotNotices() {
        // ConEmu's OSC 9;<n>: a folder (9;9, oh-my-posh's osc99), a tab title (9;3), a prompt's start (9;12), progress (9;4).
        for payload in ["9;\"/tmp/x\"", "3;Build", "12", "1;500", "4;1;50", "2;\"Hello\""] {
            #expect(!isNotification(9, payload) && parse(9, payload) == nil, "\(payload)")
        }
        // Words that start with a number are a notification's.
        #expect(parse(9, "3 tests failed")?.body == "3 tests failed")
        #expect(parse(9, "10:30 stand-up")?.body == "10:30 stand-up")
        #expect(parse(777, "notify;9;Session done")?.body == "Session done")
    }

    @Test func bidiControlsAndLineSeparatorsGo() {
        // Reordered text could show other words than the program sent; a line separator could start a line of its own.
        #expect(parse(777, "notify;Tests;Session \u{202E}rorre\u{202C} done")?.body == "Session rorre done")
        #expect(parse(777, "notify;Tests;\u{2066}isolated\u{2069} \u{2067}rtl\u{2069} \u{2068}first\u{2069}")?.body == "isolated rtl first")
        #expect(parse(777, "notify;Tests;marks\u{200E}\u{200F}\u{061C} \u{202A}\u{202B}\u{202D}gone")?.body == "marks gone")
        #expect(parse(777, "notify;Tests;two\u{2028}lines\u{2029}and more")?.body == "two lines and more")
        // Joiners in an emoji stay.
        #expect(parse(9, "Deployed 👩\u{200D}💻")?.body == "Deployed 👩\u{200D}💻")
    }

    @Test func aPayloadTooLongForANoticeSaysNothing() {
        // Still a call for attention, with no words: a notification is never that long, and the text is never read whole.
        let long = "notify;Tests;" + String(repeating: "x", count: ProgramNotice.maxPayload)
        #expect(isNotification(777, long) && parse(777, long) == nil)
        #expect(parse(9, String(repeating: "y", count: ProgramNotice.maxPayload + 1)) == nil)
        let fits = "notify;Tests;" + String(repeating: "x", count: ProgramNotice.maxPayload - "notify;Tests;".count)
        #expect(parse(777, fits)?.body.count == ProgramNotice.maxLength)
    }
}
