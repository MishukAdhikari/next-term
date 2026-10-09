import Darwin
import Foundation

/// The calls the MCP socket is serving, so the quit can answer each one (KTD17's drain): a call waiting on its tool, a call
/// posted to the main thread that has not run yet, and a request still being read. Every answer is written by the call's
/// own serve thread, which alone closes its connection, so no descriptor is closed under another thread's read.
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

        /// The quit's answer, unless the tool answered first. A request still being read stops being read, so its serve
        /// thread writes the answer at once.
        fileprivate func drain(_ answer: (Request?, Bool) -> MCPServer.CallResult) {
            lock.lock()
            guard result == nil else { return lock.unlock() }
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
