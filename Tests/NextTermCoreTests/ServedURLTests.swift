import Foundation
import Testing
@testable import NextTermCore

@Suite struct ServedURLTests {
    @Test func devServersBanners() {
        #expect(ServedURL.find(in: "  ➜  Local:   http://localhost:5173/")?.absoluteString == "http://localhost:5173/")
        #expect(ServedURL.find(in: "- 🚀 API: http://127.0.0.1:2024")?.absoluteString == "http://127.0.0.1:2024")
        #expect(ServedURL.find(in: "INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)")?.absoluteString == "http://localhost:8000")
        #expect(ServedURL.find(in: "ready on http://[::1]:3000.")?.absoluteString == "http://[::1]:3000")
        #expect(ServedURL.find(in: "Studio UI: https://localhost:8443/studio/?baseUrl=x,")?.absoluteString == "https://localhost:8443/studio/?baseUrl=x")
    }

    @Test func onlyLoopbackAddressesWithAPort() {
        #expect(ServedURL.find(in: "Network: http://192.168.1.4:5173/") == nil)
        #expect(ServedURL.find(in: "see https://example.com:443/docs") == nil)
        #expect(ServedURL.find(in: "http://localhost/ without a port") == nil)
        #expect(ServedURL.find(in: "http://localhost:99999") == nil)
        #expect(ServedURL.find(in: "nothing here") == nil)
    }

    @Test func aLineWithoutAnAddressIsNotMatched() {
        #expect(ServedURL.find(in: "Compiling NextTermCore ServedURL.swift (localhost:5173 in a comment)") == nil)
        #expect(ServedURL.find(in: "") == nil)
        #expect(ServedURL.find(in: "localhost:3000") == nil)
        #expect(ServedURL.find(in: "http:/localhost:3000") == nil)
        // An address with "://" still goes to the pattern, wherever it is in the line.
        #expect(ServedURL.find(in: "x://y then http://localhost:3000")?.absoluteString == "http://localhost:3000")
    }

    /// The tab's poll looks at up to 400 new lines twice a second, under a build's or a test run's flood of output.
    /// It used to build and compile the pattern for every line: 76 ms a poll, half the main thread.
    @Test func fourHundredLinesWithoutAnAddressTakeUnderFiveMilliseconds() {
        let lines = (0..<400).map { "[\($0)/400] Compiling Sources/NextTerm/TerminalTab.swift -o .build/arm64/TerminalTab.o \($0 * 7)" }
        let mixed = lines.enumerated().map { $0.offset % 50 == 0 ? "see https://github.com/swiftlang/swift/issues/\($0.offset)" : $0.element }
        var best = Double.infinity
        for _ in 0..<5 { // the best of five: a loaded machine slows one run, not the code
            let start = DispatchTime.now().uptimeNanoseconds
            for line in mixed { _ = ServedURL.find(in: line) }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        #expect(best < 5, "\(best) ms for 400 lines")
    }

    @Test func theTitleSuffixIsThePort() {
        #expect(ServedURL.suffix(URL(string: "http://localhost:5173/")!) == " · :5173")
    }

    @Test func whatLeavesTheTabHasNoQuery() throws {
        let jupyter = try #require(ServedURL.find(in: "    http://localhost:8888/tree?token=abc123def#top"))
        #expect(jupyter.query == "token=abc123def") // the tab keeps it, for your own click
        #expect(ServedURL.shared(jupyter) == "http://localhost:8888/tree")
        #expect(ServedURL.shared(try #require(URL(string: "http://127.0.0.1:5173/"))) == "http://127.0.0.1:5173/")
    }
}
