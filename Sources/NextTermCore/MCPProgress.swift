import Foundation

/// Progress for a long tool call (`notifications/progress`), so a client that resets its timeout on progress keeps
/// waiting: OpenCode, and others on the MCP SDK, give up on a call after 60 seconds otherwise. Only a call that asks for
/// it, with `params._meta.progressToken`, gets any; a client that sends no token sees nothing new. Progress for a call
/// stops before its answer is sent, so none ever follows the answer.
public enum MCPProgress {
    /// Under the SDK's 60-second call timeout, and under the 30 seconds some clients wait to connect or list.
    public static let interval: TimeInterval = 20
    public static let message = "waiting"

    /// A progress token as the client gave it, sent back as it came.
    public enum Token: Equatable, Sendable {
        case text(String)
        case number(Int)

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
        if let text = value as? String { return .text(text) }
        // A JSON true or 2.5 is an NSNumber too: only a whole number that is not a boolean is a token.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return .number(number.intValue)
    }

    /// One progress notification: `step` rises with each, as MCP asks; no total, since a wait's length is unknown.
    public static func notification(token: Token, step: Int) -> [String: Any] {
        let params: [String: Any] = ["progressToken": token.json, "progress": step, "message": message]
        return ["jsonrpc": "2.0", "method": "notifications/progress", "params": params]
    }

    /// Runs one `tools/call` and sends its answer. A call that carries a progress token gets progress every `interval`
    /// while `respond` runs; the ticker stops before the answer is sent, an error's included, so nothing follows it.
    public static func answer(_ message: [String: Any], every interval: TimeInterval,
                              send: @escaping ([String: Any]) -> Void, respond: () -> [String: Any]?) {
        let ticker = token(in: message).map { Ticker(token: $0, interval: interval, send: send) }
        ticker?.start()
        let response = respond()
        ticker?.stop()
        if let response { send(response) }
    }
}

extension MCPProgress {
    /// Sends one call's progress every `interval`, from `start()` until `stop()`. A tick sends under the ticker's lock
    /// and only while not stopped, and `stop()` takes that lock: once `stop()` returns, a tick in flight has written its
    /// whole line and no other comes, so the answer written after it is the call's last line.
    public final class Ticker: @unchecked Sendable {
        public let token: Token
        public let interval: TimeInterval
        private let send: ([String: Any]) -> Void
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var step = 0
        private var stopped = false

        public init(token: Token, interval: TimeInterval, send: @escaping ([String: Any]) -> Void) {
            self.token = token
            self.interval = interval
            self.send = send
        }

        /// The first progress comes one interval after this. Once only, and never after `stop()`.
        public func start() {
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
        public func stop() {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }
}
