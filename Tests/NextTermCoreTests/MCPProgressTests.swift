import Foundation
import Testing
@testable import NextTermCore

/// Progress for a long tool call: only a call that carries a progress token gets it, with a rising step, and nothing
/// follows the call's answer.
@Suite struct MCPProgressTests {
    func call(meta: Any?) -> [String: Any] {
        var params: [String: Any] = ["name": "wait_for_tab", "arguments": ["tab_id": "t"]]
        if let meta { params["_meta"] = meta }
        return ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": params]
    }

    /// As a client's line arrives: JSONSerialization's numbers, booleans among them.
    func parsed(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func sentToken(_ number: String) throws -> [String: Any] {
        try parsed(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{"progressToken":"# + number + "}}}")
    }

    @Test func theTokenIsAStringOrAnInteger() throws {
        #expect(MCPProgress.token(in: call(meta: ["progressToken": "abc"])) == .text("abc"))
        #expect(MCPProgress.token(in: call(meta: ["progressToken": 3])) == .number(3))
        #expect(MCPProgress.token(in: try sentToken("42")) == .number(42))
        #expect(MCPProgress.token(in: try sentToken("-5")) == .number(-5))
        #expect(MCPProgress.token(in: try sentToken("9223372036854775807")) == .number(Int.max))
        #expect(MCPProgress.token(in: try sentToken("-9223372036854775808")) == .number(Int.min))
    }

    @Test func noTokenWithoutMetaOrWithAnotherKind() throws {
        #expect(MCPProgress.token(in: call(meta: nil)) == nil)
        #expect(MCPProgress.token(in: call(meta: ["other": 1])) == nil)
        #expect(MCPProgress.token(in: call(meta: "progressToken")) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": ["a": 1]])) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": 1.5])) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": true])) == nil)
        #expect(MCPProgress.token(in: try sentToken("true")) == nil)
        #expect(MCPProgress.token(in: try sentToken("3.0")) == nil)
        #expect(MCPProgress.token(in: ["jsonrpc": "2.0", "id": 1, "method": "tools/call"]) == nil)
    }

    /// A whole number past Int's range comes from JSONSerialization unsigned, or as a decimal: no token for it, so
    /// progress never names a token the client did not send (18446744073709551615 read as an Int is -1).
    @Test func noTokenForAWholeNumberPastIntsRange() throws {
        for number in ["18446744073709551615", "9223372036854775808", "100000000000000000000000"] {
            #expect(MCPProgress.token(in: try sentToken(number)) == nil, "\(number)")
        }
    }

    @Test func theNotificationsShape() throws {
        func line(_ message: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let text = try line(MCPProgress.notification(token: .text("abc"), step: 1))
        let expected = #"{"jsonrpc":"2.0","method":"notifications/progress","#
            + #""params":{"message":"waiting","progress":1,"progressToken":"abc"}}"#
        #expect(text == expected)
        let number = try line(MCPProgress.notification(token: .number(9), step: 4))
        #expect(number.contains(#""params":{"message":"waiting","progress":4,"progressToken":9}"#))
        #expect(MCPProgress.notification(token: .number(9), step: 4)["id"] == nil) // a notification: no id
        #expect(MCPProgress.interval == 20)
    }

    /// The self-test's interval (NEXTTERM_TEST_MCP_PROGRESS_SECONDS, read only in a DEBUG build): a finite number of
    /// seconds from 0.01 up; anything else keeps 20, so a typo never floods the client.
    @Test func theSelfTestsIntervalIsAFiniteNumberOfSeconds() {
        #expect(MCPProgress.interval(testSeconds: "1") == 1)
        #expect(MCPProgress.interval(testSeconds: "0.5") == 0.5)
        #expect(MCPProgress.interval(testSeconds: "0.01") == 0.01)
        let kept: [String?] = [nil, "", "0", "-1", "junk", "1s", "inf", "nan", "0.001"]
        for text in kept {
            #expect(MCPProgress.interval(testSeconds: text) == 20, "\(text ?? "nil")")
        }
    }
}

/// What a ticker sent, in order, from any thread.
final class SentLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[String: Any]] = []
    private let arrived = DispatchSemaphore(value: 0)

    func send(_ message: [String: Any]) {
        lock.lock()
        lines.append(message)
        lock.unlock()
        arrived.signal()
    }

    var all: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// Waits for one more line, up to `seconds`.
    func next(within seconds: Double) -> Bool { arrived.wait(timeout: .now() + seconds) == .success }

    /// The progress lines with this token, in order.
    func progress(_ token: AnyHashable) -> [[String: Any]] { all.filter { Self.token($0) == token } }

    static func step(_ message: [String: Any]) -> Int? { (message["params"] as? [String: Any])?["progress"] as? Int }

    static func token(_ message: [String: Any]) -> AnyHashable? {
        (message["params"] as? [String: Any])?["progressToken"] as? AnyHashable
    }

    /// Polls until `ready` holds, up to `seconds`.
    static func until(_ seconds: Double, _ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}

@Suite struct MCPProgressTickerTests {
    @Test func aTickSendsTheNextStepUntilStopped() {
        let sent = SentLines()
        let ticker = MCPProgress.Ticker(token: .text("t"), interval: 60, send: sent.send)
        ticker.start()
        #expect(sent.all.isEmpty) // the first progress comes after one interval, not at once
        ticker.tick()
        ticker.tick()
        #expect(sent.all.compactMap(SentLines.step) == [1, 2])
        #expect(sent.all.allSatisfy { $0["method"] as? String == "notifications/progress" })
        ticker.stop()
        ticker.tick()
        ticker.start()
        #expect(sent.all.count == 2) // stopped for good: neither a tick nor a new start sends again
    }

    @Test func theTimerTicksUntilStoppedAndNeverAfter() {
        let sent = SentLines()
        let ticker = MCPProgress.Ticker(token: .number(5), interval: 0.05, send: sent.send)
        ticker.start()
        #expect(sent.next(within: 5) && sent.next(within: 5))
        ticker.stop()
        let count = sent.all.count
        Thread.sleep(forTimeInterval: 0.3) // six intervals
        #expect(sent.all.count == count)
        let steps = sent.all.compactMap(SentLines.step)
        #expect(steps == (0..<count).map { $0 + 1 })
    }

    @Test func stoppingBeforeStartingSendsNothing() {
        let sent = SentLines()
        let ticker = MCPProgress.Ticker(token: .text("t"), interval: 0.05, send: sent.send)
        ticker.stop()
        ticker.start()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(sent.all.isEmpty)
    }

    /// A tick writing its line when stop() comes (a slow client's pipe): stop() returns once that line is whole, and
    /// no other follows.
    @Test func stopWaitsForATickMidWrite() {
        let started = SentLines()
        let written = SentLines()
        let ticker = MCPProgress.Ticker(token: .text("t"), interval: 0.02) { message in
            started.send(message)
            Thread.sleep(forTimeInterval: 0.2)
            written.send(message)
        }
        ticker.start()
        #expect(started.next(within: 5)) // a tick is writing
        ticker.stop()
        let whole = written.all.count
        #expect(whole >= 1 && whole == started.all.count, "\(started.all.count) started, \(whole) written")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(started.all.count == whole && written.all.count == whole)
    }

    /// A ticker dropped without stop() sends nothing more: its timer goes with it.
    @Test func aDroppedTickerSendsNothingMore() {
        let sent = SentLines()
        var ticker: MCPProgress.Ticker? = MCPProgress.Ticker(token: .text("t"), interval: 0.05, send: sent.send)
        ticker?.start()
        ticker = nil
        Thread.sleep(forTimeInterval: 0.03) // a tick that had begun ends
        let count = sent.all.count
        Thread.sleep(forTimeInterval: 0.3)
        #expect(sent.all.count == count)
    }
}

/// One bridge's calls in flight (MCPProgress.Tickers): each call's progress carries its own token and steps and ends
/// before its answer; a cancelled call's ends at the cancel; and once the client closes its side, no call sends any.
@Suite struct MCPProgressTickersTests {
    func call(id: Any, token: Any?) -> [String: Any] {
        var params: [String: Any] = ["name": "wait_for_tab", "arguments": ["tab_id": "t"]]
        if let token { params["_meta"] = ["progressToken": token] }
        return ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params]
    }

    func answer(_ id: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": ["content": []]] }

    func cancelled(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func isAnswer(_ line: [String: Any], _ id: AnyHashable) -> Bool {
        line["method"] == nil && line["id"] as? AnyHashable == id
    }

    @Test func twoCallsInFlightEachGetTheirOwnProgressBeforeTheirAnswer() {
        let sent = SentLines()
        let progress = MCPProgress.Tickers(every: 0.03, send: sent.send)
        let calls = DispatchGroup()
        let pairs: [(id: AnyHashable, token: AnyHashable)] = [(1, "a"), ("two", 2)]
        for pair in pairs {
            progress.answer(call(id: pair.id.base, token: pair.token.base), in: calls) {
                _ = SentLines.until(5) { sent.progress(pair.token).count >= 2 }
                return answer(pair.id.base)
            }
        }
        #expect(calls.wait(timeout: .now() + 10) == .success)
        Thread.sleep(forTimeInterval: 0.2) // several intervals more: nothing may follow an answer
        let lines = sent.all
        for pair in pairs {
            let mine = sent.progress(pair.token)
            #expect(mine.count >= 2 && mine.compactMap(SentLines.step) == Array(1...max(1, mine.count)), "\(pair)")
            let answerAt = lines.firstIndex { isAnswer($0, pair.id) } ?? -1
            let lastProgress = lines.lastIndex { SentLines.token($0) == pair.token } ?? Int.max
            #expect(lastProgress < answerAt, "\(pair): \(lines)")
        }
    }

    /// notifications/cancelled ends the progress of the call it names, and only that call's; the answer still comes,
    /// as it did before progress. Another message, or a cancel for an id not in flight, changes nothing.
    @Test func aCancelledCallSendsNoMoreProgress() throws {
        let sent = SentLines()
        let progress = MCPProgress.Tickers(every: 0.03, send: sent.send)
        let calls = DispatchGroup()
        let release = DispatchSemaphore(value: 0)
        progress.answer(call(id: "c1", token: "a"), in: calls) { release.wait(); return answer("c1") }
        progress.answer(call(id: 2, token: "b"), in: calls) { release.wait(); return answer(2) }
        #expect(SentLines.until(5) { sent.progress("a").count >= 1 && sent.progress("b").count >= 1 })

        progress.cancel(try cancelled(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        progress.cancel(try cancelled(#"{"jsonrpc":"2.0","id":3,"method":"ping","params":{"requestId":"c1"}}"#))
        let aGoesOn = sent.progress("a").count
        #expect(SentLines.until(5) { sent.progress("a").count > aGoesOn })

        let reason = #""reason":"The user pressed Esc""#
        progress.cancel(try cancelled(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"c1",\#(reason)}}"#))
        let aAtCancel = sent.progress("a").count
        let bAtCancel = sent.progress("b").count
        Thread.sleep(forTimeInterval: 0.2)
        #expect(sent.progress("a").count == aAtCancel)
        #expect(sent.progress("b").count > bAtCancel) // the other call goes on

        progress.cancel(try cancelled(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#))
        let bAtItsCancel = sent.progress("b").count
        release.signal()
        release.signal()
        #expect(calls.wait(timeout: .now() + 10) == .success)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(sent.progress("b").count == bAtItsCancel)
        #expect(sent.all.contains { isAnswer($0, "c1") } && sent.all.contains { isAnswer($0, 2) })
    }

    /// The client closed its side (stdin's end): no call sends progress any more, nor does one that starts after;
    /// the answers in flight still come.
    @Test func closingEndsEveryCallsProgress() {
        let sent = SentLines()
        let progress = MCPProgress.Tickers(every: 0.03, send: sent.send)
        let calls = DispatchGroup()
        let release = DispatchSemaphore(value: 0)
        progress.answer(call(id: 1, token: "a"), in: calls) { release.wait(); return answer(1) }
        #expect(SentLines.until(5) { sent.progress("a").count >= 1 })
        progress.stopAll()
        let atClose = sent.all.count
        progress.answer(call(id: 2, token: "b"), in: calls) { release.wait(); return answer(2) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(sent.all.count == atClose)
        release.signal()
        release.signal()
        #expect(calls.wait(timeout: .now() + 10) == .success)
        let after = sent.all.dropFirst(atClose)
        #expect(after.count == 2 && after.allSatisfy { $0["method"] == nil }, "\(Array(after))")
    }

    /// A call that sent progress and then fails: its error is the last line, after the progress.
    @Test func progressThenAnErrorAnswer() {
        let sent = SentLines()
        let progress = MCPProgress.Tickers(every: 0.03, send: sent.send)
        let calls = DispatchGroup()
        progress.answer(call(id: 4, token: 4), in: calls) {
            _ = SentLines.until(5) { sent.progress(4).count >= 2 }
            return ["jsonrpc": "2.0", "id": 4, "error": ["code": -32603, "message": "Next Term is not running"]]
        }
        #expect(calls.wait(timeout: .now() + 10) == .success)
        Thread.sleep(forTimeInterval: 0.2)
        let lines = sent.all
        let progressFirst = lines.dropLast().allSatisfy { $0["method"] as? String == "notifications/progress" }
        #expect(lines.count >= 3 && progressFirst && lines.last?["error"] != nil, "\(lines)")
    }
}
