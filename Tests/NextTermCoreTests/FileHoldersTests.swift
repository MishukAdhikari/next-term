import Foundation
import Testing
@testable import NextTermCore

@Suite struct FileHoldersTests {
    @Test func findsAnotherProcessHoldingTheFile() throws {
        let store = AgentStore()
        #expect(!FileHolders.processes(holding: store.path).contains("sleep"))
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["30"]
        let handle = try #require(FileHandle(forReadingAtPath: store.path))
        sleep.standardInput = handle
        try sleep.run()
        defer { sleep.terminate(); sleep.waitUntilExit() }
        try handle.close() // only the child holds it now
        let holders = FileHolders.processes(holding: store.path)
        #expect(holders.contains("sleep"), "\(holders)")
        let me = ProcessInfo.processInfo.processName
        #expect(!holders.contains(me) || me == "sleep")
        #expect(FileHolders.processes(holding: store.folder + "/nothing.db").isEmpty)
    }
}
