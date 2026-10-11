import Foundation
import Testing
@testable import NextTermCore

/// The kernel side of a tab's hangup: the process list it plans from.
struct ProcessSnapshotTests {
    @Test func listsThisProcessWithItsParentAndStart() throws {
        let all = try #require(ProcessSnapshot.take())
        let me = try #require(all.first { $0.pid == getpid() })
        #expect(me.parent == getppid())
        #expect(me.group == getpgrp())
        #expect(me.started > 0 && !me.name.isEmpty)
        #expect(ProcessSnapshot.record(of: getpid()) == me)
        #expect(all.count > 10)
    }

    /// nohup sets SIGHUP to ignored before it runs the program: the snapshot says so, and SIGTERM is never sent.
    @Test func seesThatAProcessIgnoresSIGHUP() throws {
        let nohup = Process()
        nohup.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        nohup.arguments = ["/bin/sleep", "30"]
        nohup.standardOutput = FileHandle.nullDevice
        nohup.standardError = FileHandle.nullDevice
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        plain.arguments = ["30"]
        try nohup.run()
        try plain.run()
        defer {
            nohup.terminate()
            plain.terminate()
        }
        var ignoring: ProcessRecord?
        for _ in 0..<40 { // until nohup has become sleep
            ignoring = ProcessSnapshot.record(of: nohup.processIdentifier)
            if ignoring?.name == "sleep" { break }
            usleep(25_000)
        }
        #expect(ignoring?.ignoresHangup == true)
        #expect(ProcessSnapshot.record(of: plain.processIdentifier)?.ignoresHangup == false)
        #expect(ProcessSnapshot.record(of: plain.processIdentifier)?.parent == getpid())
    }

    @Test func aProcessThatEndedHasNoRecord() throws {
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        #expect(ProcessSnapshot.record(of: done.processIdentifier) == nil)
    }
}
