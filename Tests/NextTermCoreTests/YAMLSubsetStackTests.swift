import Foundation
import Testing
@testable import NextTermCore

/// The YAML reader on a thread with a small stack, as the app reads a chosen file off the main thread: anchors and tags
/// written again and again are read in a loop or stopped by the depth, never by the stack. Every file here is made up.
@Suite struct YAMLSubsetStackTests {
    typealias Y = YAMLSubset
    typealias Read = Result<[Y.Node], Y.Failure>

    static let count = 100_000

    /// What `documents` gives for `text`, read on a thread with a 512 KB stack.
    static func onSmallStack(_ text: String) async -> Read {
        await withCheckedContinuation { (continuation: CheckedContinuation<Read, Never>) in
            let thread = Thread {
                continuation.resume(returning: Y.documents(text))
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    @Test func anchorsAloneOnTheirLinesStopAtTheDepth() async throws {
        let text: String = "k: &a\n" + String(repeating: " &a\n", count: Self.count) + " x\n"
        guard case .failure(let failure) = await Self.onSmallStack(text) else { return #expect(Bool(false)) }
        #expect(failure.reason == .tooDeep)
        // One anchor alone on its line still names the node under it.
        let root = try #require(try Y.documents("k: &a\n  inner: v\n").get().first)
        #expect(root["k"]?["inner"]?.scalar?.text == "v")
    }

    @Test func anchorsOnOneLineAreReadPast() async throws {
        let run: String = String(repeating: "&a ", count: Self.count)
        let read: Read = await Self.onSmallStack("k: " + run + "x\n")
        let root = try #require(try read.get().first)
        #expect(root["k"]?.scalar?.text == "x")
    }

    @Test func anchorsAndTagsInAFlowAreReadInALoop() async throws {
        let anchors: Read = await Self.onSmallStack("k: [" + String(repeating: "&a ", count: Self.count) + "x]\n")
        let anchored = try #require(try anchors.get().first)
        #expect(anchored["k"]?.items?.first?.scalar?.text == "x")
        let tags: Read = await Self.onSmallStack("k: [" + String(repeating: "!a ", count: Self.count) + "x]\n")
        let tagged = try #require(try tags.get().first)
        #expect(tagged["k"]?.items == [.skipped(.tag, line: 1)])
        let mixed: Read = await Self.onSmallStack("k: {a: " + String(repeating: "&a !b ", count: Self.count) + "v}\n")
        let both = try #require(try mixed.get().first)
        #expect(both["k"]?["a"] == .skipped(.tag, line: 1))
    }
}
