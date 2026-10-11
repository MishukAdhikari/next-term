import Foundation
import Testing
@testable import NextTermCore

/// The door's open calls: each call answered once, at once on a revoke or turn-off, with the deadline text at 100
/// seconds, its late result dropped while its rate-limit slot still comes back; the grant checked again just before
/// a call runs; the list-changed event on the next stream for a grant whose options changed; and the JSON-RPC
/// messages the door reads and sends, with the MCPControl binding's policy and name.
@Suite struct RemoteAccessCallsTests {
    typealias Calls = RemoteAccessCalls
    typealias OAuth = RemoteAccessOAuth

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = RemoteAccessCallsTests.start

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            time = time.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    /// What one call was answered with, in order.
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var endings: [Calls.Ending] = []

        func add(_ ending: Calls.Ending) {
            lock.lock()
            endings.append(ending)
            lock.unlock()
        }

        var all: [Calls.Ending] {
            lock.lock()
            defer { lock.unlock() }
            return endings
        }

        var texts: [String] { all.map(\.callResult.text) }
    }

    static func grant(_ id: String = "g1", options: RemoteAccessOptions = .readOnly) -> OAuth.Grant {
        OAuth.Grant(id: id, name: "Claude, phone", clientID: "c1", clientName: "Claude", redirectHost: "claude.ai",
                    options: options, host: "mcp.example.com", created: start, lastUsed: start)
    }

    func makeCalls(_ clock: Clock, deadline: TimeInterval = Calls.deadline) -> Calls {
        Calls(deadline: deadline, clock: { clock.now })
    }

    /// Opens a call and returns its id, with what it was answered with.
    func openCall(_ calls: Calls, grant: String = "g1", connection: UInt64 = 1,
                  streamed: Bool = false) -> (id: Calls.ID, answers: Answers, listChanged: Bool)? {
        let answers = Answers()
        let opened = calls.open(grant: grant, connection: connection, streamed: streamed) { answers.add($0) }
        guard case .call(let id, let listChanged) = opened else { return nil }
        return (id, answers, listChanged)
    }

    static let screen = MCPServer.CallResult(text: #"{"screen": "ok"}"#)

    // MARK: revoke

    /// AE5: a revoke during a 50-second wait answers the call at once with the revoke text, and closes its
    /// connection; the result that comes later is dropped, and its slot comes back with it.
    @Test func aRevokeDuringACallAnswersAtOnceAndDropsTheLateResult() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        let call = try #require(openCall(calls))
        #expect(calls.begin(call.id, grant: Self.grant()) == .run(Self.grant()))
        clock.advance(10)

        #expect(calls.revoke(grants: ["g1"]) == 1)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        let ending = try #require(call.answers.all.first)
        #expect(ending.closesConnection)
        #expect(ending.callResult.isError)
        #expect(ending.decision == .failed)
        // The tool still runs on the Mac: its slot is held until its result comes.
        #expect(calls.running == 1)
        #expect(calls.openCount == 0)

        clock.advance(40)
        #expect(!calls.finish(call.id, Self.screen))
        #expect(call.answers.all.count == 1)
        #expect(calls.running == 0)
        // A second result, or a revoke again, changes nothing.
        #expect(!calls.finish(call.id, Self.screen))
        #expect(calls.revoke(grants: ["g1"]) == 0)
        #expect(call.answers.all.count == 1)
    }

    /// A revoke answers only the grants it ends: a call of another grant runs on and gets its result.
    @Test func aRevokeLeavesOtherGrantsCallsAlone() throws {
        let calls = makeCalls(Clock())
        let mine = try #require(openCall(calls, grant: "g1"))
        let other = try #require(openCall(calls, grant: "g2", connection: 2))
        _ = calls.begin(mine.id, grant: Self.grant("g1"))
        _ = calls.begin(other.id, grant: Self.grant("g2"))
        #expect(calls.revoke(grants: ["g1"]) == 1)
        #expect(other.answers.all.isEmpty)
        #expect(calls.finish(other.id, Self.screen))
        #expect(other.answers.texts == [Self.screen.text])
        #expect(other.answers.all.first?.closesConnection == false)
        #expect(other.answers.all.first?.decision == .allowed)
    }

    /// A call revoked before the main thread ran it never runs: begin says it ended, and its slot is back at once,
    /// since no result will come.
    @Test func aCallRevokedBeforeItRanNeverRuns() throws {
        let calls = makeCalls(Clock())
        let call = try #require(openCall(calls))
        #expect(calls.revoke(grants: ["g1"]) == 1)
        #expect(calls.running == 0)
        #expect(calls.begin(call.id, grant: Self.grant()) == .ended)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
    }

    /// KTD15: the grant is read again from the authority just before a call runs. A call whose check runs after a
    /// revoke is refused with the revoke text and runs nothing; one whose check ran before it completes.
    @Test func aCallCheckedAfterARevokeIsRefusedAndOneCheckedBeforeCompletes() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        var authority = OAuth(host: "mcp.example.com", grants: [Self.grant()])

        // Its token was valid, and its check runs before the revoke: it runs and completes.
        let before = try #require(openCall(calls))
        #expect(calls.begin(before.id, grant: authority.grant("g1")) == .run(Self.grant()))
        #expect(calls.finish(before.id, Self.screen))
        #expect(before.answers.texts == [Self.screen.text])

        // Its token was valid when it came, then the grant was revoked (the authority's lock, then the registry)
        // before the main thread checked it.
        let after = try #require(openCall(calls))
        let revoked = authority.revoke(grant: "g1", now: clock.now)
        #expect(revoked)
        #expect(calls.revoke(grants: ["g1"]) == 1)
        #expect(calls.begin(after.id, grant: authority.grant("g1")) == .ended)
        #expect(after.answers.texts == [RemoteAccessText.turnedOff])

        // A call registered after the revoke: the registry has nothing to answer, so the check refuses it.
        let late = try #require(openCall(calls))
        #expect(calls.begin(late.id, grant: authority.grant("g1")) == .refused)
        #expect(late.answers.texts == [RemoteAccessText.turnedOff])
        #expect(late.answers.all.first?.closesConnection == true)
        #expect(calls.running == 0)
        #expect(calls.openCount == 0)
    }

    /// The grant the check reads must be the call's own: another grant's record never lets it run.
    @Test func aCheckWithAnotherGrantIsRefused() throws {
        let calls = makeCalls(Clock())
        let call = try #require(openCall(calls, grant: "g1"))
        #expect(calls.begin(call.id, grant: Self.grant("g2")) == .refused)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
    }

    /// The grant's options are read at the check: a call runs under the options the grant has then (R60).
    @Test func beginHandsBackTheGrantAsTheCheckReadIt() throws {
        let calls = makeCalls(Clock())
        let call = try #require(openCall(calls))
        let changed = Self.grant(options: .customStart)
        #expect(calls.begin(call.id, grant: changed) == .run(changed))
        // Running it twice is not possible: a second begin finds it running.
        #expect(calls.begin(call.id, grant: changed) == .ended)
    }

    // MARK: deadline

    /// R25: every call is answered within 100 seconds. The deadline answers it with its text; the tool still runs
    /// on the Mac, so its slot stays taken until the late result comes, which is dropped and gives the slot back.
    @Test func theDeadlineAnswersAt100SecondsAndTheLateResultReleasesItsSlot() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        var running: [(id: Calls.ID, answers: Answers)] = []
        for _ in 0..<3 {
            let call = try #require(openCall(calls))
            #expect(calls.begin(call.id, grant: Self.grant()) == .run(Self.grant()))
            running.append((call.id, call.answers))
        }
        // A fourth call from the grant waits for nothing: three at a time (R27).
        #expect(calls.open(grant: "g1", connection: 4, streamed: false) { _ in } == .tooMany)

        clock.advance(99.9)
        #expect(calls.expire() == 0)
        #expect(running.allSatisfy { $0.answers.all.isEmpty })

        clock.advance(0.1)
        #expect(calls.expire() == 3)
        for call in running {
            #expect(call.answers.texts == [RemoteAccessText.deadline])
            #expect(call.answers.all.first?.closesConnection == false)
            #expect(call.answers.all.first?.decision == .failed)
        }
        #expect(calls.openCount == 0)
        #expect(calls.running == 3)
        #expect(calls.open(grant: "g1", connection: 4, streamed: false) { _ in } == .tooMany)

        // The late result is dropped, and its slot comes back with it.
        clock.advance(20)
        #expect(!calls.finish(running[0].id, Self.screen))
        #expect(running[0].answers.all.count == 1)
        #expect(calls.running == 2)
        #expect(openCall(calls) != nil)
        #expect(calls.expire() == 0)
    }

    /// The door runs expire on a timer; one at the deadline of a call that never reached the main thread answers it
    /// and frees its slot at once, and the main thread then runs nothing.
    @Test func aCallThatNeverRanFreesItsSlotAtTheDeadline() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        let call = try #require(openCall(calls))
        clock.advance(Calls.deadline)
        #expect(calls.expire() == 1)
        #expect(call.answers.texts == [RemoteAccessText.deadline])
        #expect(calls.running == 0)
        #expect(calls.begin(call.id, grant: Self.grant()) == .ended)
    }

    /// A result that never comes cannot hold a grant's slots for good: five minutes after its answer, the slot of a
    /// call that ran out of time is given back.
    @Test func aResultThatNeverComesGivesItsSlotBackLater() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        let call = try #require(openCall(calls))
        _ = calls.begin(call.id, grant: Self.grant())
        clock.advance(Calls.deadline)
        #expect(calls.expire() == 1)
        clock.advance(Calls.abandon - 1)
        #expect(calls.expire() == 0)
        #expect(calls.running == 1)
        clock.advance(1)
        #expect(calls.expire() == 0)
        #expect(calls.running == 0)
        #expect(!calls.finish(call.id, Self.screen))
        #expect(call.answers.all.count == 1)
    }

    /// Slots held by results that never came come back when the grant's next call opens, without waiting for the
    /// door's next timer: a grant whose three calls all hung is not locked out once they are abandoned.
    @Test func abandonedSlotsComeBackWhenTheNextCallOpens() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        for _ in 0..<3 {
            let call = try #require(openCall(calls))
            _ = calls.begin(call.id, grant: Self.grant())
        }
        clock.advance(Calls.deadline)
        #expect(calls.expire() == 3)
        #expect(openCall(calls) == nil)
        clock.advance(Calls.abandon)
        let next = try #require(openCall(calls))
        #expect(calls.running == 1)
        #expect(calls.begin(next.id, grant: Self.grant()) == .run(Self.grant()))
    }

    /// The deadline is a value the door passes: a debug self-test shortens it, and the answer still comes once.
    @Test func aShorterDeadlineIsKept() throws {
        let clock = Clock()
        let calls = makeCalls(clock, deadline: 2)
        #expect(calls.deadline == 2)
        let call = try #require(openCall(calls))
        _ = calls.begin(call.id, grant: Self.grant())
        clock.advance(2)
        #expect(calls.expire() == 1)
        #expect(calls.revoke(grants: ["g1"]) == 0)
        #expect(calls.turnOff() == 0)
        #expect(call.answers.texts == [RemoteAccessText.deadline])
    }

    /// R25: the door gives each call its own deadline timer, on the monotonic clock. `expire(id)` answers that call
    /// with the deadline text at once, whatever the wall clock says, and leaves every other call alone.
    @Test func aCallsOwnDeadlineAnswersItWhateverTheWallClockSays() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        let call = try #require(openCall(calls))
        let other = try #require(openCall(calls, connection: 2))
        _ = calls.begin(call.id, grant: Self.grant())
        // The wall clock is set back an hour while the call runs.
        clock.advance(-3600)
        #expect(calls.expire() == 0)
        #expect(calls.expire(call.id))
        #expect(call.answers.texts == [RemoteAccessText.deadline])
        #expect(other.answers.all.isEmpty)
        // The tool still runs on the Mac: its slot comes back with its late result.
        #expect(calls.running == 2)
        #expect(!calls.expire(call.id))
        #expect(!calls.finish(call.id, Self.screen))
        #expect(calls.running == 1)
        #expect(call.answers.all.count == 1)
    }

    // MARK: turning off

    /// R37: turning off answers every open call with the revoke text and closes its connection; nothing opens
    /// after it, and a check after it refuses.
    @Test func turningOffAnswersEveryCallAndOpensNoMore() throws {
        let calls = makeCalls(Clock())
        let first = try #require(openCall(calls, grant: "g1"))
        let second = try #require(openCall(calls, grant: "g2", connection: 2))
        _ = calls.begin(first.id, grant: Self.grant("g1"))
        #expect(calls.turnOff() == 2)
        #expect(calls.isOff)
        #expect(first.answers.texts == [RemoteAccessText.turnedOff])
        #expect(second.answers.texts == [RemoteAccessText.turnedOff])
        #expect(first.answers.all.first?.closesConnection == true)
        #expect(calls.open(grant: "g1", connection: 3, streamed: true) { _ in } == .closed)
        #expect(calls.begin(second.id, grant: Self.grant("g2")) == .ended)
        #expect(!calls.finish(first.id, Self.screen))
        #expect(calls.running == 0)
    }

    /// The door shapes a result (masking a long screen takes time) before it hands it to `finish`, so the call is
    /// still open meanwhile: a turn-off that lands then answers it with the revoke text, and closes its connection,
    /// and the shaped result is dropped. The client never gets a stream head and then nothing.
    @Test func aResultBeingShapedIsStillAnOpenCall() throws {
        let calls = makeCalls(Clock())
        let call = try #require(openCall(calls, streamed: true))
        _ = calls.begin(call.id, grant: Self.grant())
        // The Mac answered, and the door is shaping the result.
        #expect(calls.openCount == 1)
        #expect(calls.turnOff() == 1)
        #expect(!calls.finish(call.id, Self.screen))
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(call.answers.all.first?.closesConnection == true)
        #expect(calls.running == 0)
    }

    // MARK: limits

    /// R27: 3 at a time per grant and 6 overall. A refused call takes no slot.
    @Test func theGeneralLimitsHoldAcrossGrants() throws {
        let calls = makeCalls(Clock())
        for grant in ["g1", "g2"] {
            for _ in 0..<3 { #expect(openCall(calls, grant: grant) != nil) }
        }
        #expect(calls.open(grant: "g3", connection: 9, streamed: false) { _ in } == .tooMany)
        #expect(calls.running == 6)
    }

    /// R27, R39: a call the door answers without running it takes no slot, but counts toward its grant's 120 calls
    /// a minute. So a leaked token that sends only refused calls is held to the same rate as one whose calls run:
    /// past it, each gets the too-many text and the door sums its audit line with the minute's others.
    @Test func aRefusedCallCountsTowardItsGrantsMinuteAndTakesNoSlot() throws {
        let clock = Clock()
        let calls = makeCalls(clock)
        let running = try #require(openCall(calls))
        for index in 0..<119 {
            #expect(calls.countRefused(grant: "g1") == .counted, "refusal \(index)")
        }
        #expect(calls.running == 1)
        #expect(calls.countRefused(grant: "g1") == .tooMany)
        #expect(calls.open(grant: "g1", connection: 2, streamed: false) { _ in } == .tooMany)
        // Another grant has its own minute; a minute later the first counts again.
        #expect(calls.countRefused(grant: "g2") == .counted)
        clock.advance(60)
        #expect(calls.countRefused(grant: "g1") == .counted)
        #expect(running.answers.all.isEmpty)
        _ = calls.turnOff()
        #expect(calls.countRefused(grant: "g1") == .closed)
    }

    /// R60, R53: the options changed between the door's check and the main thread. The main thread's refusal is
    /// the call's one answer, carried with it, so the audit line says what the client got: a tool now off gets its
    /// error result and names the option; an argument that no longer fits gets JSON-RPC error -32602 (AE13).
    @Test func aRefusalOnTheMainThreadIsTheCallsOneAnswer() throws {
        let calls = makeCalls(Clock())
        let call = try #require(openCall(calls))
        #expect(calls.begin(call.id, grant: Self.grant()) == .run(Self.grant()))
        let text = RemoteAccessText.cantUse("read_tab", needing: [.tabs])
        #expect(calls.finish(call.id, refused: .options(text, by: [.tabs])))
        #expect(calls.running == 0)
        let ending = try #require(call.answers.all.first)
        #expect(ending.decision == .refused)
        #expect(ending.reason == text)
        #expect(ending.refusedBy == [.tabs])
        #expect(!ending.closesConnection)
        #expect(ending.callResult.text == text)
        #expect(ending.callResult.isError)
        #expect(Calls.answer(id: 4, ending) == Calls.result(id: 4, ending.callResult))
        // Answered once: a second answer, or a revoke after it, changes nothing.
        #expect(!calls.finish(call.id, refused: .invalidParams("x")))
        #expect(calls.revoke(grants: ["g1"]) == 0)
        #expect(call.answers.all.count == 1)

        let params = try #require(openCall(calls))
        _ = calls.begin(params.id, grant: Self.grant())
        let invalid = RemoteAccessText.notAnArgument("force", of: "close_tab")
        #expect(calls.finish(params.id, refused: .invalidParams(invalid)))
        let refusal = try #require(params.answers.all.first)
        #expect(refusal.decision == .refused)
        #expect(refusal.reason == invalid)
        #expect(refusal.refusedBy.isEmpty)
        let parsed = try JSONSerialization.jsonObject(with: Calls.answer(id: 9, refusal))
        let message = try #require(parsed as? [String: Any])
        let error = try #require(message["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect(error["message"] as? String == invalid)
        #expect(message["id"] as? Int == 9)
        #expect(message["result"] == nil)
    }

    /// Every ending but invalid params sends the tool-result envelope; the audit line takes its decision and reason.
    @Test func eachEndingSendsItsAnswerAndItsAuditReason() {
        let refused = Calls.Ending.refused(.options("No", by: [.tabs]))
        for ending in [Calls.Ending.result(Self.screen), refused, .turnedOff, .deadline] {
            #expect(Calls.answer(id: 3, ending) == Calls.result(id: 3, ending.callResult))
        }
        #expect(Calls.Ending.result(Self.screen).decision == .allowed)
        #expect(Calls.Ending.result(Self.screen).reason == nil)
        #expect(Calls.Ending.turnedOff.reason == RemoteAccessText.turnedOff)
        #expect(Calls.Ending.deadline.reason == RemoteAccessText.deadline)
        #expect(Calls.Ending.deadline.decision == .failed)
        #expect(Calls.Ending.turnedOff.refusedBy.isEmpty)
        #expect(refused.callResult.text == "No")
        #expect(refused.callResult.isError)
    }

    // MARK: list changed

    /// R20: after an options change, the next streamed call for that grant carries one list-changed event before
    /// its result; the one after it carries none, and a call from another grant carries none. A call answered as
    /// JSON can't carry it, so the mark waits for a stream.
    @Test func aChangedListIsSentOnceOnTheGrantsNextStream() throws {
        let calls = makeCalls(Clock())
        calls.markListChanged("g1")
        #expect(openCall(calls, grant: "g2", streamed: true)?.listChanged == false)
        #expect(openCall(calls, grant: "g1", streamed: false)?.listChanged == false)
        let next = try #require(openCall(calls, grant: "g1", streamed: true))
        #expect(next.listChanged)
        _ = calls.turnOff()

        let again = makeCalls(Clock())
        again.markListChanged("g1")
        #expect(openCall(again, grant: "g1", streamed: true)?.listChanged == true)
        #expect(openCall(again, grant: "g1", streamed: true)?.listChanged == false)
    }

    /// The stream that carries it starts with the event, before any keep-alive or result, exactly once.
    @Test func theListChangedEventComesFirstOnTheStream() throws {
        let start = Calls.streamStart(listChanged: true)
        let head = RemoteAccessHTTP.streamHead()
        let event = RemoteAccessHTTP.event(Calls.listChangedNotification)
        #expect(start == head + event)
        let text = String(decoding: start + RemoteAccessHTTP.event(Calls.result(id: 7, Self.screen)), as: UTF8.self)
        let notification = try #require(text.range(of: "notifications/tools/list_changed"))
        let result = try #require(text.range(of: #""id":7"#))
        #expect(notification.upperBound < result.lowerBound)
        #expect(text.components(separatedBy: "notifications/tools/list_changed").count == 2)
        #expect(Calls.streamStart(listChanged: false) == head)
        let parsed = try JSONSerialization.jsonObject(with: Calls.listChangedNotification)
        let message = try #require(parsed as? [String: Any])
        #expect(message["jsonrpc"] as? String == "2.0")
        #expect(message["method"] as? String == "notifications/tools/list_changed")
        #expect(message["id"] == nil)
    }

    /// A tools/list gives the client the new list, so it clears the mark; so does the grant's end.
    @Test func aToolsListOrARevokeClearsTheMark() throws {
        let calls = makeCalls(Clock())
        calls.markListChanged("g1")
        calls.clearListChanged("g1")
        #expect(openCall(calls, grant: "g1", streamed: true)?.listChanged == false)
        calls.markListChanged("g1")
        _ = calls.revoke(grants: ["g1"])
        #expect(openCall(calls, grant: "g1", streamed: true)?.listChanged == false)
    }

    // MARK: messages

    func incoming(_ text: String, version: String? = nil) -> Calls.Incoming {
        Calls.read(Data(text.utf8), protocolVersion: version)
    }

    /// KTD10: a batch gives 400, a notification or a response 202, a version the server does not speak 400.
    @Test func theDoorReadsOneMessageAtATime() throws {
        #expect(incoming(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#).status == 400)
        #expect(incoming(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).status == 202)
        #expect(incoming(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#).status == 202)
        #expect(incoming(#"{"jsonrpc":"2.0","id":3,"result":{}}"#).status == 202)
        #expect(incoming("not json").status == 400)
        // An authenticated request the door can't read still gets an audit line, which says why.
        let reasons = [incoming("[]"), incoming("not json"), incoming("{}", version: "1999-01-01")].map(\.reason)
        #expect(reasons.allSatisfy { $0 != nil })
        #expect(Set(reasons).count == 3)
        #expect(incoming(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).reason == nil)
        #expect(incoming(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).reason == nil)
        #expect(incoming(#""text""#).status == 400)
        #expect(incoming("").status == 400)
        #expect(incoming(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, version: "1999-01-01").status == 400)
        for version in MCPServer.supportedVersions {
            #expect(incoming(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, version: version).status == nil)
        }
        guard case .request(let message) = incoming(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) else {
            Issue.record("tools/list is a request")
            return
        }
        #expect(message["method"] as? String == "tools/list")

        let call = incoming(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"read_tab","arguments":{"tab_id":"t1"}}}"#)
        guard case .call(let id, let name, let arguments) = call else {
            Issue.record("tools/call is a call")
            return
        }
        #expect(id as? String == "a")
        #expect(name == "read_tab")
        #expect(arguments["tab_id"] as? String == "t1")
        let bare = incoming(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":7}}"#)
        guard case .call(_, let none, let empty) = bare else {
            Issue.record("a call without a name is still a call")
            return
        }
        #expect(none == "")
        #expect(empty.isEmpty)
    }

    /// A tool call's answer is the envelope `nxtrm mcp` sends for the same result.
    @Test func aResultIsTheLocalEnvelope() throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                      "params": ["name": "read_tab", "arguments": [:] as [String: Any]]]
        for outcome in [Self.screen, MCPServer.CallResult(text: "No", isError: true)] {
            let local = MCPServer.respond(to: message, version: "1", tools: MCPServer.tools, instructions: "",
                                          listChanged: false) { _, _ in outcome }
            let remote = try JSONSerialization.jsonObject(with: Calls.result(id: 5, outcome)) as? NSDictionary
            #expect(remote == local.map { NSDictionary(dictionary: $0) })
        }
        let refusal = Calls.error(id: "x", code: -32602, message: "Invalid params")
        let error = try #require(try JSONSerialization.jsonObject(with: refusal) as? [String: Any])
        #expect(error["id"] as? String == "x")
        let body = try #require(error["error"] as? [String: Any])
        #expect(body["code"] as? Int == -32602)
        #expect(body["message"] as? String == "Invalid params")
        // Slashes stay as they are, as in nxtrm mcp's answers.
        let path = String(decoding: Calls.result(id: 1, MCPServer.CallResult(text: "/a/b")), as: UTF8.self)
        #expect(path.contains("/a/b"))
    }

    // MARK: the MCPControl binding

    /// R56, R59: the door passes askOnMac while "Ask on this Mac before changes" is on, and the grant's id as a
    /// pre-approval while it is off; the requester is the connection's name as the approval window shows it.
    @Test func thePolicyAndTheNameFollowTheGrant() {
        var asks = RemoteAccessOptions.customStart
        asks[.askOnMac] = true
        #expect(Calls.approval(for: Self.grant(options: asks)) == .askOnMac)
        #expect(Calls.approval(for: Self.grant("g7", options: .control)) == .preApprovedByGrant("g7"))
        #expect(Calls.requester(for: Self.grant()) == "the connection “Claude, phone”")
    }

    /// The audit line of a refused call names the options that left it off: the first of each half with none on.
    @Test func aRefusalNamesTheOptionsThatLeftItOff() {
        #expect(Calls.refusedBy("read_tab", options: .readOnly).isEmpty)
        var noTabs = RemoteAccessOptions.readOnly
        noTabs[.tabs] = false
        #expect(Calls.refusedBy("read_tab", options: noTabs) == [.tabs])
        #expect(Calls.refusedBy("list_hosts", options: .readOnly) == [.serversRead])
        #expect(Calls.refusedBy("made_up", options: .readOnly).isEmpty)
    }
}
