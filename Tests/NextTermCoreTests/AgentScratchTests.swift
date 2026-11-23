import Foundation
import Testing
@testable import NextTermCore

/// An agent's scratch window: a temporary folder an agent opened, kept out of the lists, closed once quiet.
@Suite struct AgentScratchTests {
    let temporary = "/private/var/folders/ab/cd/T/"

    @Test func temporaryFoldersAreSeenHoweverSpelled() {
        #expect(AgentScratch.isTemporary("/private/tmp/claude-501/proj/session/scratchpad", temporary: temporary))
        #expect(AgentScratch.isTemporary("/tmp/claude-501/scratchpad", temporary: temporary))
        #expect(AgentScratch.isTemporary("/tmp", temporary: temporary))
        #expect(AgentScratch.isTemporary("/var/folders/ab/cd/T/x", temporary: temporary))
        #expect(AgentScratch.isTemporary("/private/var/folders/zz/yy/T/x", temporary: temporary))
        #expect(AgentScratch.isTemporary(NSTemporaryDirectory() + "nt-x"))
    }

    @Test func otherFoldersAreNot() {
        #expect(!AgentScratch.isTemporary("/Users/me/Code/app", temporary: temporary))
        #expect(!AgentScratch.isTemporary("/tmpfiles/app", temporary: temporary))
        #expect(!AgentScratch.isTemporary("/private/tmpx", temporary: temporary))
        #expect(!AgentScratch.isTemporary("/", temporary: temporary))
    }

    @Test func onlyAnAgentsTemporaryFolderIsLeftOutOfTheLists() {
        #expect(!AgentScratch.isRemembered("/private/tmp/claude-501/scratchpad", byAgent: true, temporary: temporary))
        #expect(AgentScratch.isRemembered("/private/tmp/claude-501/scratchpad", byAgent: false, temporary: temporary))
        #expect(AgentScratch.isRemembered("/Users/me/Code/app", byAgent: true, temporary: temporary))
        #expect(AgentScratch.isRemembered("/Users/me/Code/app", byAgent: false, temporary: temporary))
    }

    func window(scratch: Bool = true, touched: Bool = false, unsaved: Bool = false,
                tabs: [AgentScratch.Tab] = [AgentScratch.Tab()]) -> AgentScratch.Window {
        AgentScratch.Window(scratch: scratch, touched: touched, unsaved: unsaved, tabs: tabs)
    }

    @Test func anUntouchedScratchWindowOfIdleShellsIsQuiet() {
        #expect(AgentScratch.isQuiet(window()))
        #expect(AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(state: .done), AgentScratch.Tab(state: .failed)])))
    }

    @Test func itIsNeverQuietWhileAnythingKeepsIt() {
        #expect(!AgentScratch.isQuiet(window(scratch: false)))
        #expect(!AgentScratch.isQuiet(window(touched: true)))
        #expect(!AgentScratch.isQuiet(window(unsaved: true)))
        #expect(!AgentScratch.isQuiet(window(tabs: [])))
        #expect(!AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(), AgentScratch.Tab(running: true)])))
        #expect(!AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(jobs: 1)])))
        #expect(!AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(state: .working)])))
        #expect(!AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(state: .attention)])))
        #expect(!AgentScratch.isQuiet(window(tabs: [AgentScratch.Tab(remote: true)])))
    }
}
