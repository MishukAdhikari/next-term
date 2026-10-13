import Darwin
import Foundation

/// The calls the MCP socket is serving, so the quit can answer each one (KTD17's drain): a call waiting on its tool, a call
/// posted to the main thread that has not run yet, and a request still being read. Every answer is written by the call's
/// own serve thread, which alone closes its connection, so no descriptor is closed under another thread's read. A call
/// that answers itself (`nxtrm secret run`'s request, SecretSocket) is left be.
public final class MCPCalls: @unchecked Sendable {
    /// What a call asked, once its request was read.
    public struct Request {
        public let tool: String
        public let arguments: [String: Any]

        public init(tool: String, arguments: [String: Any]) {
            self.tool = tool
            self.arguments = arguments
        }
    }

    /// One connection, from accept to close.
    public final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private let fd: Int32
        private var request: Request?
        private var started = false
        private var closed = false
        private var answersItself = false
        private var result: MCPServer.CallResult?
        /// Signalled once the call has its answer: the tool's, or the drain's.
        public let answered = DispatchSemaphore(value: 0)

        fileprivate init(fd: Int32) { self.fd = fd }

        /// The answer, once there is one.
        public var answer: MCPServer.CallResult? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        /// The request was read. False when the quit answered the call meanwhile.
        public func asked(_ request: Request) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.request = request
            return result == nil
        }

        /// The tool is about to run, on the main thread. False when the quit answered the call first: then it never runs.
        public func starts() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return false }
            started = true
            return true
        }

        /// The tool's answer. One that comes after the quit's is dropped.
        public func finish(_ answer: MCPServer.CallResult) {
            lock.lock()
            let first = result == nil
            if first { result = answer }
            lock.unlock()
            if first { answered.signal() }
        }

        /// It answers itself from here. False when the quit answered it first.
        fileprivate func takesOwnAnswer() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return false }
            answersItself = true
            return true
        }

        /// The quit's answer, unless the tool answered first or the call answers itself. A request still being read stops
        /// being read, so its serve thread writes the answer at once.
        fileprivate func drain(_ answer: (Request?, Bool) -> MCPServer.CallResult) {
            lock.lock()
            guard result == nil, !answersItself else { return lock.unlock() }
            result = answer(request, started)
            if request == nil && !closed { shutdown(fd, SHUT_RD) }
            lock.unlock()
            answered.signal()
        }

        /// Closes the connection, once.
        fileprivate func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    private let lock = NSLock()
    private var calls: [ObjectIdentifier: Call] = [:]
    /// Set by the drain: a call that begins after it is answered with this at once.
    private var quitAnswer: ((Request?, Bool) -> MCPServer.CallResult)?
    private let open = DispatchGroup()

    public init() {}

    /// A connection was accepted.
    public func begin(_ fd: Int32) -> Call {
        let call = Call(fd: fd)
        lock.lock()
        calls[ObjectIdentifier(call)] = call
        let answer = quitAnswer
        open.enter()
        lock.unlock()
        if let answer { call.drain(answer) }
        return call
    }

    /// The call's request is `nxtrm secret run`'s, which answers itself on its connection (SecretSocket). From here the
    /// drain neither answers it nor stops its reading, which the wrapper's wait would take for the wrapper leaving, and
    /// doesn't wait for it: its answer comes from the main thread, which the quit holds. Its connection still closes as
    /// it ends. False when the quit answered the call first: then nothing more is written to it.
    public func answersItself(_ call: Call) -> Bool {
        guard call.takesOwnAnswer() else { return false }
        lock.lock()
        let known = calls.removeValue(forKey: ObjectIdentifier(call)) != nil
        lock.unlock()
        if known { open.leave() }
        return true
    }

    /// What the serve thread does with a call once its line is read.
    public enum Route {
        /// It answers itself on its connection (`answersItself`).
        case answerItself
        /// Nothing is written to it: the quit answered a call that answers itself first, or cut the reading of a line
        /// whose peer is a wrapper, which is no MCP caller.
        case nothing
        /// The quit's answer.
        case drained(MCPServer.CallResult)
        /// Asked, run and answered as ever.
        case serve
    }

    /// The route for `call`, whose line read as `request` (nil when none did: the drain cut its reading, or it was not a
    /// whole request). `selfAnswering`: the request is `nxtrm secret run`'s, which answers itself (SecretSocket), unless the
    /// quit answered the call first. A call the quit answered gets that answer, except a wrapper whose line the drain cut;
    /// `isWrapper` looks at the peer's process, only then.
    public func route(_ call: Call, read request: Request?, selfAnswering: Bool, isWrapper: () -> Bool) -> Route {
        if request != nil, selfAnswering { return answersItself(call) ? .answerItself : .nothing }
        guard let drained = call.answer else { return .serve }
        return request == nil && isWrapper() ? .nothing : .drained(drained)
    }

    /// The call's answer is written: its connection closes.
    public func end(_ call: Call) {
        call.close()
        lock.lock()
        let known = calls.removeValue(forKey: ObjectIdentifier(call)) != nil
        lock.unlock()
        if known { open.leave() }
    }

    /// Answers every call not answered yet with `answer` (its request, nil when not read yet, and whether its tool had
    /// started), and every call that begins meanwhile, accepted just before the socket stopped listening; then waits up
    /// to `wait` for their serve threads to write those answers and close. A server started again later serves as before.
    public func drain(wait: TimeInterval, answer: @escaping (Request?, Bool) -> MCPServer.CallResult) {
        lock.lock()
        quitAnswer = answer
        let serving = Array(calls.values)
        lock.unlock()
        for call in serving { call.drain(answer) }
        _ = open.wait(timeout: .now() + wait)
        lock.lock()
        quitAnswer = nil
        lock.unlock()
    }
}
