import Foundation

/// Progress for a long tool call (`notifications/progress`), so a client that resets its timeout on progress keeps
/// waiting: OpenCode, and others on the MCP SDK, give up on a call after 60 seconds otherwise. Only a call that asks for
/// it, with `params._meta.progressToken`, gets any; a client that sends no token sees nothing new. A call's progress
/// stops before its answer is sent, when the client cancels the call, and when the client closes its side.
public enum MCPProgress {
    /// Under the SDK's 60-second call timeout, and under the 30 seconds some clients wait to connect or list.
    public static let interval: TimeInterval = 20
    public static let message = "waiting"

    /// The self-test's interval (NEXTTERM_TEST_MCP_PROGRESS_SECONDS, which the bridge reads only in a DEBUG build): a
    /// finite number of seconds from 0.01 up. Anything else keeps `interval`, so a typo never floods the client.
    public static func interval(testSeconds text: String?) -> TimeInterval {
        guard let seconds = text.flatMap(TimeInterval.init), seconds.isFinite, seconds >= 0.01 else { return interval }
        return seconds
    }

    /// A progress token as the client gave it, sent back as it came. A request id has the same two kinds, so a
    /// cancel names its call by one.
    public enum Token: Equatable, Sendable {
        case text(String)
        case number(Int)

        /// A string, or a whole number that is not a boolean and fits an Int; nil for anything else. A number past
        /// Int's range (JSONSerialization's unsigned or decimal) is nil too, since as an Int it would name another.
        init?(json value: Any) {
            if let text = value as? String {
                self = .text(text)
                return
            }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number), let whole = Int(exactly: number) else { return nil }
            self = .number(whole)
        }

        var json: Any {
            switch self {
            case .text(let text): return text
            case .number(let number): return number
            }
        }
    }

    /// The call's progress token: a string or an integer in `params._meta.progressToken`; nil for anything else.
    public static func token(in message: [String: Any]) -> Token? {
        let params = message["params"] as? [String: Any]
        guard let value = (params?["_meta"] as? [String: Any])?["progressToken"] else { return nil }
        return Token(json: value)
    }

    /// One progress notification: `step` rises with each, as MCP asks; no total, since a wait's length is unknown.
    public static func notification(token: Token, step: Int) -> [String: Any] {
        let params: [String: Any] = ["progressToken": token.json, "progress": step, "message": message]
        return ["jsonrpc": "2.0", "method": "notifications/progress", "params": params]
    }
}

extension MCPProgress {
    /// One bridge's calls in flight that send progress. A call's ticker is kept by its request id from the moment its
    /// line is read, so a `notifications/cancelled` read next finds it; it stops before the call's answer is sent, at
    /// the call's cancel, or when the client closes its side, whichever comes first.
    public final class Tickers: @unchecked Sendable {
        public let interval: TimeInterval
        private let send: ([String: Any]) -> Void
        private let lock = NSLock()
        private var running: [(id: Token?, ticker: Ticker)] = []
        private var closed = false

        public init(every interval: TimeInterval, send: @escaping ([String: Any]) -> Void) {
            self.interval = interval
            self.send = send
        }

        /// Runs one `tools/call` on a background queue in `group` and sends its answer. A call that carries a progress
        /// token gets progress every `interval` while `respond` runs; the ticker stops before the answer is sent, an
        /// error's included, so nothing follows it.
        public func answer(_ message: [String: Any], in group: DispatchGroup,
                           respond: @escaping () -> [String: Any]?) {
            let ticker = begin(message) // now, on the reading thread
            DispatchQueue.global().async(group: group) {
                let response = respond()
                if let ticker { self.end(ticker) }
                if let response { self.send(response) }
            }
        }

        /// `notifications/cancelled`: the call it names (`params.requestId`) sends no more progress. Its answer still
        /// comes, as it did before progress. Any other message changes nothing.
        public func cancel(_ message: [String: Any]) {
            guard message["method"] as? String == "notifications/cancelled",
                  let requestID = (message["params"] as? [String: Any])?["requestId"],
                  let id = Token(json: requestID) else { return }
            lock.lock()
            let named = running.filter { $0.id == id }.map { $0.ticker }
            lock.unlock()
            named.forEach { $0.stop() }
        }

        /// The client closed its side (stdin's end): no call sends progress any more, one that starts later included.
        /// The answers in flight still come.
        public func stopAll() {
            lock.lock()
            closed = true
            let all = running.map { $0.ticker }
            lock.unlock()
            all.forEach { $0.stop() }
        }

        private func begin(_ message: [String: Any]) -> Ticker? {
            guard let token = MCPProgress.token(in: message) else { return nil }
            let id = message["id"].flatMap { Token(json: $0) }
            let ticker = Ticker(token: token, interval: interval, send: send)
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return nil }
            running.append((id: id, ticker: ticker))
            ticker.start()
            return ticker
        }

        private func end(_ ticker: Ticker) {
            ticker.stop()
            lock.lock()
            running.removeAll { $0.ticker === ticker }
            lock.unlock()
        }
    }
}

extension MCPProgress {
    /// Sends one call's progress every `interval`, from `start()` until `stop()`. A tick sends under the ticker's lock
    /// and only while not stopped, and `stop()` takes that lock: once `stop()` returns, a tick in flight has written its
    /// whole line and no other comes, so the answer written after it is the call's last line. Locks are taken in one
    /// order, Tickers' then a ticker's then the output's, and a tick never takes Tickers'.
    final class Ticker: @unchecked Sendable {
        let token: Token
        let interval: TimeInterval
        private let send: ([String: Any]) -> Void
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var step = 0
        private var stopped = false

        init(token: Token, interval: TimeInterval, send: @escaping ([String: Any]) -> Void) {
            self.token = token
            self.interval = interval
            self.send = send
        }

        /// A ticker let go without `stop()` takes its timer with it.
        deinit { timer?.cancel() }

        /// The first progress comes one interval after this. Once only, and never after `stop()`.
        func start() {
            lock.lock()
            defer { lock.unlock() }
            guard timer == nil, !stopped else { return }
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }

        /// One progress notification, with the next step; none once stopped.
        func tick() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            step += 1
            send(MCPProgress.notification(token: token, step: step))
        }

        /// Stops for good: nothing is sent after this returns.
        func stop() {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }
}
