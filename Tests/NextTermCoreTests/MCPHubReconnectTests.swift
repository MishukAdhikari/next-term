import Foundation
import Testing
@testable import NextTermCore

/// Trying again, on its own, to reach an MCP server Next Term couldn't reach.
@Suite struct MCPHubReconnectTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func theWaitsGrowThenStayAtTenMinutes() {
        #expect(MCPHubReconnect.wait(after: 0) == 15)
        #expect(MCPHubReconnect.wait(after: 1) == 30)
        #expect(MCPHubReconnect.wait(after: 5) == 600)
        #expect(MCPHubReconnect.wait(after: 40) == 600)
    }

    @Test func anEntryIsDueAfterItsWait() {
        var entry = MCPHubReconnect.Entry(lastTry: start)
        #expect(MCPHubReconnect.due(["a": entry], at: start.addingTimeInterval(14)).isEmpty)
        #expect(MCPHubReconnect.due(["a": entry], at: start.addingTimeInterval(15)) == ["a"])
        entry.tried(at: start.addingTimeInterval(15))
        #expect(entry.due == start.addingTimeInterval(45))
    }

    @Test func aWakeOrTheNetworkComingBackMakesItDueAtOnce() {
        var entry = MCPHubReconnect.Entry(tries: 4, lastTry: start)
        let woke = start.addingTimeInterval(20)
        entry.startOver(at: woke)
        #expect(entry.tries == 0 && entry.due <= woke)
        #expect(MCPHubReconnect.due(["a": entry], at: woke) == ["a"])
    }

    @Test func theNextTimerIsTheSoonestDue() {
        let entries = ["a": MCPHubReconnect.Entry(tries: 2, lastTry: start), "b": MCPHubReconnect.Entry(tries: 0, lastTry: start)]
        #expect(MCPHubReconnect.next(entries) == start.addingTimeInterval(15))
        #expect(MCPHubReconnect.next([:]) == nil)
    }
}
