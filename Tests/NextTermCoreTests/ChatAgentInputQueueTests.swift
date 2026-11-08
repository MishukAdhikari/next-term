import Foundation
import Testing
@testable import NextTermCore

/// A chat agent's input (plan 037): what a full pipe can't take waits, in order, and goes once the pipe has room; a pipe
/// that is gone drops it all, and nothing is ever written twice.
@Suite struct ChatAgentInputQueueTests {
    /// A pipe that takes at most `room` bytes a write, then says it is full after `writes` writes.
    private final class FakePipe {
        var received: [UInt8] = []
        var room: Int
        var fullAfter: Int?
        var error: Int32?
        private var writes = 0

        init(room: Int = .max, fullAfter: Int? = nil, error: Int32? = nil) {
            self.room = room
            self.fullAfter = fullAfter
            self.error = error
        }

        func write(_ raw: UnsafeRawBufferPointer) -> AgentInputQueue.Written {
            if let error { return AgentInputQueue.Written(count: -1, error: error) }
            if let fullAfter, writes >= fullAfter { return AgentInputQueue.Written(count: -1, error: EAGAIN) }
            writes += 1
            let count = min(room, raw.count)
            received.append(contentsOf: [UInt8](raw.prefix(count)))
            return AgentInputQueue.Written(count: count)
        }
    }

    @Test func everythingGoesWhenThePipeHasRoom() {
        var queue = AgentInputQueue()
        queue.append(Data("one\n".utf8))
        queue.append(Data("two\n".utf8))
        let pipe = FakePipe(room: 3)
        #expect(queue.drain(pipe.write) == .drained)
        #expect(String(decoding: pipe.received, as: UTF8.self) == "one\ntwo\n")
        #expect(queue.isEmpty)
    }

    @Test func aFullPipeKeepsTheRestInOrderUntilItHasRoom() {
        var queue = AgentInputQueue()
        queue.append(Data("abcdef".utf8))
        let pipe = FakePipe(room: 2, fullAfter: 1)
        #expect(queue.drain(pipe.write) == .wouldBlock)
        #expect(String(decoding: pipe.received, as: UTF8.self) == "ab")
        #expect(queue.count == 4)
        // A line sent meanwhile goes after what waits.
        queue.append(Data("gh".utf8))
        pipe.fullAfter = nil
        #expect(queue.drain(pipe.write) == .drained)
        #expect(String(decoding: pipe.received, as: UTF8.self) == "abcdefgh")
    }

    @Test func anInterruptedWriteIsTriedAgain() {
        var queue = AgentInputQueue()
        queue.append(Data("x".utf8))
        var interrupted = false
        let outcome = queue.drain { raw in
            if !interrupted {
                interrupted = true
                return AgentInputQueue.Written(count: -1, error: EINTR)
            }
            return AgentInputQueue.Written(count: raw.count)
        }
        #expect(outcome == .drained && queue.isEmpty)
    }

    @Test func aPipeThatIsGoneDropsEverything() {
        var queue = AgentInputQueue()
        queue.append(Data("lost".utf8))
        #expect(queue.drain(FakePipe(error: EPIPE).write) == .failed)
        #expect(queue.isEmpty)
        // A write that takes nothing drops it too, rather than spinning.
        queue.append(Data("lost".utf8))
        #expect(queue.drain { _ in AgentInputQueue.Written(count: 0) } == .failed)
        #expect(queue.isEmpty)
    }

    @Test func droppingClearsWhatWaits() {
        var queue = AgentInputQueue()
        queue.append(Data("waiting".utf8))
        queue.drop()
        #expect(queue.isEmpty)
        #expect(queue.drain { _ in AgentInputQueue.Written(count: -1, error: EPIPE) } == .drained)
    }
}
