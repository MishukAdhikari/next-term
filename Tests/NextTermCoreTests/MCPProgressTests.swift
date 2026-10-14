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

    @Test func theTokenIsAStringOrAnInteger() throws {
        #expect(MCPProgress.token(in: call(meta: ["progressToken": "abc"])) == .text("abc"))
        #expect(MCPProgress.token(in: call(meta: ["progressToken": 3])) == .number(3))
        let sent = try parsed(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{"progressToken":42}}}"#)
        #expect(MCPProgress.token(in: sent) == .number(42))
    }

    @Test func noTokenWithoutMetaOrWithAnotherKind() throws {
        #expect(MCPProgress.token(in: call(meta: nil)) == nil)
        #expect(MCPProgress.token(in: call(meta: ["other": 1])) == nil)
        #expect(MCPProgress.token(in: call(meta: "progressToken")) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": ["a": 1]])) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": 1.5])) == nil)
        #expect(MCPProgress.token(in: call(meta: ["progressToken": true])) == nil)
        let boolean = try parsed(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{"progressToken":true}}}"#)
        #expect(MCPProgress.token(in: boolean) == nil)
        #expect(MCPProgress.token(in: ["jsonrpc": "2.0", "id": 1, "method": "tools/call"]) == nil)
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

    static func step(_ message: [String: Any]) -> Int? { (message["params"] as? [String: Any])?["progress"] as? Int }
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
}
