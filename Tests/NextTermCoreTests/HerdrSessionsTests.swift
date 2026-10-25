import Foundation
import Testing
@testable import NextTermCore

/// herdr's sessions and the tab its focus is in, from hand-written stand-ins of herdr 0.9.1's answers (Fixtures/herdr).
@Suite struct HerdrSessionsTests {
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func herdrsSessionsReadTheDefaultFirst() throws {
        let sessions = try #require(HerdrSession.parse(try fixture("session-list-0.9.1.json")))
        #expect(sessions == [HerdrSession(name: "default", isDefault: true, running: true), HerdrSession(name: "review", running: true),
                             HerdrSession(name: "scratch")])
        #expect(HerdrSession.parse(try fixture("session-list-default-only.json")) == [HerdrSession(name: "default", isDefault: true, running: true)])
        // Under result, as herdr's other answers are; with fields Next Term does not know.
        let wrapped = #"{"id":"cli:session:list","result":{"sessions":[{"name":"ops","default":false,"running":true,"color":"red"}],"next":1}}"#
        #expect(HerdrSession.parse(wrapped) == [HerdrSession(name: "ops", running: true)])
    }

    @Test func anEmptyListIsAnAnswerAndAnythingElseIsNone() {
        #expect(HerdrSession.parse(#"{"sessions":[]}"#) == [])
        #expect(HerdrSession.parse("error: unrecognized subcommand 'session'") == nil)
        #expect(HerdrSession.parse(#"{"error":{"code":"server_not_running","message":"no server"}}"#) == nil)
        #expect(HerdrSession.parse(#"{"result":{"agents":[]}}"#) == nil)
        // A version manager's warning before it is read past.
        #expect(HerdrSession.parse("mise WARN outdated\n" + #"{"sessions":[{"name":"a","default":true,"running":false}]}"#)?.count == 1)
    }

    @Test func aNameNextTermWouldNotPassOnIsLeftOut() {
        let output = #"{"sessions":[{"name":"a b","running":true},{"name":"x;rm","running":true},{"name":"","running":true},{"running":true},{"name":"ok_1-2","running":"yes"}]}"#
        #expect(HerdrSession.parse(output) == [HerdrSession(name: "ok_1-2")])
        #expect(HerdrSession.isName("review") && HerdrSession.isName(String(repeating: "a", count: 64)))
        #expect(!HerdrSession.isName(String(repeating: "a", count: 65)) && !HerdrSession.isName("é") && !HerdrSession.isName(""))
    }

    @Test func theFocusedTabIsTheOneHerdrMarks() throws {
        #expect(HerdrTabs.focusedTab(try fixture("tab-list-0.9.1.json")) == "w2:t1")
        #expect(HerdrTabs.focusedTab(#"{"result":{"type":"tab_list","tabs":[{"tab_id":"w1:t1","focused":false}]}}"#) == nil)
        // A string is not focus.
        #expect(HerdrTabs.focusedTab(#"{"tabs":[{"tab_id":"w1:t1","focused":"true"},{"tab_id":"w1:t2","focused":true}]}"#) == "w1:t2")
        #expect(HerdrTabs.focusedTab("not json") == nil)
    }

    /// herdr 0.9.1's own `session list --json`, as a hand check read it: each session also names its folder and socket,
    /// which are left out, and a stopped default is listed first all the same. The paths here are made up.
    @Test func herdr091sSessionListWithItsFoldersReads() {
        let output = #"{"sessions":[{"default":true,"name":"default","running":false,"session_dir":"/tmp/made-up/herdr","#
            + #""socket_path":"/tmp/made-up/herdr/herdr.sock"},{"default":false,"name":"review","running":true,"#
            + #""session_dir":"/tmp/made-up/herdr/sessions/review","socket_path":"/tmp/made-up/herdr/sessions/review/herdr.sock"}]}"#
        #expect(HerdrSession.parse(output) == [HerdrSession(name: "default", isDefault: true),
                                               HerdrSession(name: "review", running: true)])
    }
}
