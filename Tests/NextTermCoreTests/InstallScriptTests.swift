import Foundation
import Testing
@testable import NextTermCore

/// The install script run for real on made-up apps in a temporary folder, with `open` stubbed.
@Suite struct InstallScriptTests {
    /// A made-up install: an old app in place, a new one staged, a private sessions folder and an `open`
    /// that only records what it was asked to open.
    struct Layout {
        let root: String
        var app: String { root + "/Applications/Next Term.app" }
        var staging: String { root + "/staging" }
        var newApp: String { staging + "/Next Term.app" }
        var backup: String { staging + "/Next Term (previous).app" }
        var sessions: String { root + "/sessions" }
        var openStub: String { root + "/bin/open" }
        var openLog: String { root + "/opened" }
        var resultFile: String { sessions + "/" + InstallResult.fileName }

        /// Whether the app at `path` is the made-up `version` ("old" or "new").
        func holds(_ version: String, at path: String) -> Bool {
            let text: String? = try? String(contentsOfFile: path + "/Contents/version", encoding: .utf8)
            return text == version
        }

        /// Each call of the stubbed `open`, as its arguments.
        func opened() -> [[String]] {
            guard let data = FileManager.default.contents(atPath: openLog) else { return [] }
            let calls = String(decoding: data, as: UTF8.self).split(separator: "\u{1E}")
            return calls.map { call in call.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
        }

        func result() -> InstallResult? {
            FileManager.default.contents(atPath: resultFile).flatMap(InstallResult.parse)
        }

        func script(pid: Int32, relaunch: Bool, marker: UUID? = nil, folderKey: String? = nil) -> InstallScript {
            var script = InstallScript(pid: pid, app: app, newApp: newApp, backup: backup, staging: staging, relaunch: relaunch)
            script.sessions = sessions
            script.marker = marker
            script.folderKey = folderKey
            script.open = openStub
            return script
        }
    }

    func makeLayout(named name: String = "install") throws -> Layout {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID().uuidString)")
        let layout = Layout(root: base.appendingPathComponent(name).path)
        let files = FileManager.default
        try files.createDirectory(atPath: layout.app + "/Contents", withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.newApp + "/Contents", withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.root + "/bin", withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "old".write(toFile: layout.app + "/Contents/version", atomically: true, encoding: .utf8)
        try "new".write(toFile: layout.newApp + "/Contents/version", atomically: true, encoding: .utf8)
        // Each argument ends in a NUL and each call in a record separator, so any path survives the log.
        let stub = "#!/bin/sh\nprintf '%s\\0' \"$@\" >> \(ShellQuote.quote(layout.openLog))\nprintf '\\036' >> \(ShellQuote.quote(layout.openLog))\n"
        try stub.write(toFile: layout.openStub, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.openStub)
        return layout
    }

    func remove(_ layout: Layout) {
        tool("/bin/chmod", ["-R", "-N", layout.root])
        tool("/bin/chmod", ["-R", "u+rwx", layout.root])
        try? FileManager.default.removeItem(atPath: (layout.root as NSString).deletingLastPathComponent)
    }

    @discardableResult
    func tool(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs the script the way Updater does (`bash -c`), from inside the layout. False if it never finished.
    func run(_ script: InstallScript, in layout: Layout) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script.text]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: layout.root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard !process.isRunning else {
            process.terminate()
            return false
        }
        return true
    }

    /// The pid of a process that has ended: the script does not wait.
    func endedProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// The pid of a sleep that ends after `seconds`. sh leaves it in the background and exits, so launchd
    /// adopts it and reaps it when it ends.
    func runningProcess(seconds: Double) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sleep \(seconds) </dev/null >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try #require(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func aSuccessfulSwapWritesInstalledAndWithRelaunchOffOpensNothing() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        let marker = UUID()
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: marker), in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(!FileManager.default.fileExists(atPath: layout.backup))
        #expect(!FileManager.default.fileExists(atPath: layout.staging))
        #expect(layout.result() == InstallResult(outcome: .installed, marker: marker))
        #expect(layout.opened().isEmpty)
    }

    @Test func aSuccessfulSwapWithRelaunchOnOpensTheNewAppInPlace() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: UUID()), in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(layout.result()?.outcome == .installed)
        let expected: [[String]] = [[layout.app]]
        #expect(layout.opened() == expected)
    }

    @Test func theScriptWaitsForTheAppToQuitFirst() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        let pid = try runningProcess(seconds: 0.8)
        let started = Date()
        #expect(try run(layout.script(pid: pid, relaunch: false), in: layout))
        #expect(Date().timeIntervalSince(started) > 0.4)
        #expect(layout.holds("new", at: layout.app))
    }

    @Test func anAppThatCannotBeMovedAsideWritesFailedKeptOldAndStaysInPlace() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // A folder the app cannot be taken out of.
        let applications = (layout.app as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications)
        let marker = UUID()
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: marker), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("new", at: layout.newApp))
        #expect(layout.result() == InstallResult(outcome: .failedKeptOld, marker: marker))
        let expected: [[String]] = [[layout.app]]
        #expect(layout.opened() == expected)
    }

    @Test func aNewAppThatCannotBeMovedInPutsTheOldOneBack() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try FileManager.default.removeItem(atPath: layout.newApp)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(!FileManager.default.fileExists(atPath: layout.backup))
        #expect(layout.result()?.outcome == .failedKeptOld)
        #expect(layout.opened().isEmpty)
    }

    @Test func whenTheOldAppCannotBePutBackItsBackupOpensWithTheOriginalFolderKey() throws {
        for relaunch in [true, false] {
            let layout = try makeLayout()
            defer { remove(layout) }
            // Things can go into the staging folder but nothing can leave it: the old app goes in as the
            // backup, and then neither the new app nor the backup can come out.
            #expect(tool("/bin/chmod", ["+a", "everyone deny delete_child", layout.staging]) == 0)
            let marker = UUID()
            let script = layout.script(pid: try endedProcess(), relaunch: relaunch, marker: marker, folderKey: "0a1b2c3d4e5f")
            #expect(try run(script, in: layout))
            #expect(!FileManager.default.fileExists(atPath: layout.app))
            #expect(layout.holds("old", at: layout.backup))
            #expect(layout.result() == InstallResult(outcome: .failedRestoredBackup, marker: marker))
            let expected: [[String]] = [[layout.backup, "--args", InstallScript.folderKeyArgument, "0a1b2c3d4e5f"]]
            #expect(layout.opened() == expected)
        }
    }

    @Test func aBackupOpenedWithoutAFolderKeyGetsNoArguments() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        #expect(tool("/bin/chmod", ["+a", "everyone deny delete_child", layout.staging]) == 0)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true), in: layout))
        let expected: [[String]] = [[layout.backup]]
        #expect(layout.opened() == expected)
    }

    @Test func everyPathIsQuotedEvenWithSpacesQuotesAndShellSyntax() throws {
        let name = "it's \"odd\" $(touch pwned) `touch pwned2`; touch pwned3 \\ $HOME *\nline"
        let layout = try makeLayout(named: name)
        defer { remove(layout) }
        let key = "k'ey $(touch pwned4)"
        let script = layout.script(pid: try endedProcess(), relaunch: true, marker: UUID(), folderKey: key)
        #expect(!script.text.contains(name))
        #expect(try run(script, in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(layout.result()?.outcome == .installed)
        let expected: [[String]] = [[layout.app]]
        #expect(layout.opened() == expected)
        let base = (layout.root as NSString).deletingLastPathComponent
        let made: [String] = try FileManager.default.contentsOfDirectory(atPath: base)
        let only: [String] = [name]
        #expect(made == only)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root).filter { $0.hasPrefix("pwned") }.isEmpty)
    }

    @Test func theBackupOpenQuotesAnOddFolderKeyAndPath() throws {
        let layout = try makeLayout(named: "it's a folder")
        defer { remove(layout) }
        #expect(tool("/bin/chmod", ["+a", "everyone deny delete_child", layout.staging]) == 0)
        let key = "k'ey $(touch pwned) x"
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, folderKey: key), in: layout))
        let expected: [[String]] = [[layout.backup, "--args", InstallScript.folderKeyArgument, key]]
        #expect(layout.opened() == expected)
        #expect(!FileManager.default.fileExists(atPath: layout.root + "/pwned"))
    }

    @Test func theResultFileIsPrivateAndReplacedThroughARename() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // A link planted where the result goes is replaced, never written through.
        let elsewhere = layout.root + "/elsewhere"
        try "untouched".write(toFile: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: layout.resultFile, withDestinationPath: elsewhere)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(try String(contentsOfFile: elsewhere, encoding: .utf8) == "untouched")
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.resultFile)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.sessions) == [InstallResult.fileName])
        #expect(layout.result()?.outcome == .installed)
    }

    @Test func theResultGoesIntoTheSessionsFolderOnly() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // No sessions folder: it is not made, and nothing is written anywhere else.
        try FileManager.default.removeItem(atPath: layout.sessions)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(!FileManager.default.fileExists(atPath: layout.sessions))
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root).sorted() == ["Applications", "bin"])
    }

    @Test func withoutASessionsFolderTheScriptWritesNoResult() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        var script = layout.script(pid: try endedProcess(), relaunch: true, marker: UUID())
        script.sessions = nil
        #expect(!script.text.contains(InstallResult.fileName))
        #expect(try run(script, in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.sessions).isEmpty)
        let expected: [[String]] = [[layout.app]]
        #expect(layout.opened() == expected)
    }

    @Test func aResultWithoutAMarkerStillSaysWhatHappened() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try FileManager.default.removeItem(atPath: layout.newApp)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false), in: layout))
        #expect(layout.result() == InstallResult(outcome: .failedKeptOld, marker: nil))
    }

    @Test func resultsRoundTripAndAnythingElseIsRefused() throws {
        let marker = try #require(UUID(uuidString: "6F0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D"))
        let json = #"{"marker":"6F0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D","outcome":"failed-restored-backup"}"#
        #expect(InstallResult.parse(Data(json.utf8)) == InstallResult(outcome: .failedRestoredBackup, marker: marker))
        #expect(InstallResult.parse(Data(#"{"outcome":"installed"}"#.utf8)) == InstallResult(outcome: .installed, marker: nil))
        #expect(InstallResult.parse(Data(#"{"outcome":"maybe"}"#.utf8)) == nil)
        #expect(InstallResult.parse(Data(#"{"outcome":"installed","marker":"not-a-uuid"}"#.utf8)) == nil)
        #expect(InstallResult.parse(Data("not json".utf8)) == nil)
        let padded = #"{"outcome":"installed","pad":""# + String(repeating: " ", count: InstallResult.maxSize) + #""}"#
        #expect(InstallResult.parse(Data(padded.utf8)) == nil)
    }

    @Test func todaysStepsAreKeptInOrder() throws {
        let script = InstallScript(pid: 4242, app: "/Applications/Next Term.app", newApp: "/s/Next Term.app",
                                   backup: "/s/Next Term (previous).app", staging: "/s", relaunch: true).text
        let lines: [String] = script.split(separator: "\n").map { line in line.trimmingCharacters(in: .whitespaces) }
        let wait = "while /bin/kill -0 4242 2>/dev/null; do /bin/sleep 0.2; done"
        #expect(lines.first == wait)
        let order = ["if /bin/mv '/Applications/Next Term.app' '/s/Next Term (previous).app'; then",
                     "if /bin/mv '/s/Next Term.app' '/Applications/Next Term.app'; then",
                     "/bin/rm -rf '/s/Next Term (previous).app' /s",
                     "elif /bin/mv '/s/Next Term (previous).app' '/Applications/Next Term.app'; then"]
        let indexes = order.map { line in lines.firstIndex(of: line) }
        #expect(indexes.allSatisfy { $0 != nil })
        #expect(indexes.compactMap { $0 } == indexes.compactMap { $0 }.sorted())
        let reopen = "/usr/bin/open '/Applications/Next Term.app'"
        #expect(lines.last == reopen)
        let quiet = InstallScript(pid: 4242, app: "/Applications/Next Term.app", newApp: "/s/Next Term.app",
                                  backup: "/s/Next Term (previous).app", staging: "/s", relaunch: false).text
        #expect(!quiet.contains("/usr/bin/open '/Applications/Next Term.app'"))
        #expect(quiet.contains("/usr/bin/open '/s/Next Term (previous).app'"))
    }
}
