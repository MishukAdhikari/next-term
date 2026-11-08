import Foundation

/// The bytes waiting to go to a chat agent's input (plan 037), in the order they were sent. The app's end of the pipe
/// doesn't block, so a write the pipe can't take now leaves the rest here until the pipe has room again, and the main
/// thread never waits on an agent that isn't reading. The writing itself is given as a closure, so the queue is tested
/// without a pipe.
public struct AgentInputQueue: Sendable {
    /// What a `drain` ended with.
    public enum Outcome: Equatable, Sendable {
        /// Everything was written.
        case drained
        /// The pipe is full: the rest waits for it to have room.
        case wouldBlock
        /// The pipe is gone (the agent quit): everything waiting was dropped.
        case failed
    }

    /// One write's result, as `write(2)` gives it: the bytes written, or -1 with the error.
    public struct Written: Equatable, Sendable {
        public var count: Int
        public var error: Int32

        public init(count: Int, error: Int32 = 0) {
            self.count = count
            self.error = error
        }
    }

    private var pending: [UInt8] = []

    public init() {}

    /// Nothing waits.
    public var isEmpty: Bool { pending.isEmpty }

    /// The bytes still waiting.
    public var count: Int { pending.count }

    /// Queues `data` after everything sent before it.
    public mutating func append(_ data: Data) {
        pending.append(contentsOf: [UInt8](data))
    }

    /// Drops everything waiting: the input closed.
    public mutating func drop() {
        pending.removeAll()
    }

    /// Writes as much as the pipe takes now, through `write`, which is handed the waiting bytes from the first.
    /// An interrupted write is tried again; a full pipe (EAGAIN) leaves the rest waiting; any other error, or a write
    /// that takes nothing, drops it all (the agent can't read any more).
    public mutating func drain(_ write: (UnsafeRawBufferPointer) -> Written) -> Outcome {
        while !pending.isEmpty {
            let result = pending.withUnsafeBytes { write($0) }
            if result.count > 0 {
                pending.removeFirst(min(result.count, pending.count))
                continue
            }
            if result.count < 0, result.error == EINTR { continue }
            if result.count < 0, result.error == EAGAIN { return .wouldBlock }
            pending.removeAll()
            return .failed
        }
        return .drained
    }
}
