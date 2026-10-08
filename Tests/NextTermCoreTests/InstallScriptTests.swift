import Foundation
import Testing
@testable import NextTermCore

/// The install script run for real on made-up apps signed ad hoc in a temporary folder, with `open`
/// stubbed and the real `codesign`.
@Suite struct InstallScriptTests {
    /// A made-up install: an old app in place, a new one staged, a private sessions folder and an `open`
    /// that only records what it was asked to open.
    struct Layout {
        let root: String
        /// What each app must meet, read once both are signed: each one's own hashes, as for an app
        /// signed ad hoc.
        var requirement = ""
        var oldRequirement = ""
        var applications: String { root + "/Applications" }
        var app: String { applications + "/Next Term.app" }
        var staging: String { root + "/staging" }
        var newApp: String { staging + "/Next Term.app" }
        /// Where the backup used to go: in the staging folder, which agents can write.
        var stagingBackup: String { staging + "/Next Term (previous).app" }
        var sessions: String { root + "/sessions" }
        var openStub: String { root + "/bin/open" }
        var openLog: String { root + "/opened" }
        var resultFile: String { sessions + "/" + InstallResult.fileName }

        /// Whether the app at `path` is the made-up `version` ("old" or "new").
        func holds(_ version: String, at path: String) -> Bool {
            let text: String? = try? String(contentsOfFile: path + "/Contents/Resources/version", encoding: .utf8)
            return text == version
        }

        /// Whether `path` is a real folder, not a link.
        func isFolder(_ path: String) -> Bool {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return attributes?[.type] as? FileAttributeType == .typeDirectory
        }

        /// The private folders the script made beside the app for its backup.
        func backupFolders() -> [String] {
            let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []
            return names.filter { $0.hasPrefix(".Next Term (previous).") }.map { applications + "/" + $0 }
        }

        /// The old app in its backup folder, when one is left.
        var backup: String? { backupFolders().first.map { $0 + "/Next Term.app" } }

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
            var script = InstallScript(pid: pid, app: app, newApp: newApp, staging: staging, requirement: requirement,
                                       oldRequirement: oldRequirement, relaunch: relaunch)
            script.sessions = sessions
            script.marker = marker
            script.folderKey = folderKey
            script.open = openStub
            return script
        }
    }

    func makeLayout(named name: String = "install") throws -> Layout {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID().uuidString)")
        var layout = Layout(root: base.appendingPathComponent(name).path)
        let files = FileManager.default
        try files.createDirectory(atPath: layout.applications, withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.staging, withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.root + "/bin", withIntermediateDirectories: true)
        try files.createDirectory(atPath: layout.sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try MadeUpApp.make(at: layout.app, version: "old")
        try MadeUpApp.make(at: layout.newApp, version: "new")
        try #require(MadeUpApp.sign(layout.app) && MadeUpApp.sign(layout.newApp))
        layout.requirement = try #require(CodeSignature.of(URL(fileURLWithPath: layout.newApp))).requirement
        layout.oldRequirement = try #require(CodeSignature.of(URL(fileURLWithPath: layout.app))).requirement
        // Each argument ends in a NUL and each call in a record separator, so any path survives the log.
        let stub = "#!/bin/sh\nprintf '%s\\0' \"$@\" >> \(ShellQuote.quote(layout.openLog))\nprintf '\\036' >> \(ShellQuote.quote(layout.openLog))\n"
        try stub.write(toFile: layout.openStub, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.openStub)
        return layout
    }

    func remove(_ layout: Layout) {
        tool("/usr/bin/chflags", ["-R", "nouchg", layout.root])
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

    /// Neither app can be put in place: the new one cannot leave the staging folder, and the backup
    /// folder the script makes beside the app inherits a rule that nothing leaves it either.
    func strand(_ layout: Layout) {
        #expect(tool("/bin/chmod", ["+a", "everyone deny delete_child", layout.staging]) == 0)
        #expect(tool("/bin/chmod", ["+a", "everyone deny delete_child,directory_inherit,only_inherit", layout.applications]) == 0)
    }

    /// What the stubbed `open` was asked to open, checked in one place: comparing nested arrays inside
    /// `#expect` is slow to type-check.
    func expectOpened(_ expected: [[String]], in layout: Layout, sourceLocation: SourceLocation = #_sourceLocation) {
        let calls: [[String]] = layout.opened()
        let same: Bool = calls == expected
        #expect(same, "opened \(calls)", sourceLocation: sourceLocation)
    }

    func expectOutcome(_ outcome: InstallResult.Outcome, in layout: Layout, sourceLocation: SourceLocation = #_sourceLocation) {
        let found: InstallResult.Outcome? = layout.result()?.outcome
        let expected: InstallResult.Outcome? = outcome
        #expect(found == expected, sourceLocation: sourceLocation)
    }

    func expectResult(_ expected: InstallResult, in layout: Layout, sourceLocation: SourceLocation = #_sourceLocation) {
        let found: InstallResult? = layout.result()
        let wanted: InstallResult? = expected
        #expect(found == wanted, sourceLocation: sourceLocation)
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

    // MARK: The swap

    @Test func aSuccessfulSwapWritesInstalledAndWithRelaunchOffOpensNothing() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        let marker = UUID()
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: marker), in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(layout.backupFolders().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.staging))
        expectResult(InstallResult(outcome: .installed, marker: marker), in: layout)
        #expect(layout.opened().isEmpty)
    }

    @Test func aSuccessfulSwapWithRelaunchOnOpensTheNewAppInPlace() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: UUID()), in: layout))
        #expect(layout.holds("new", at: layout.app))
        expectOutcome(.installed, in: layout)
        expectOpened([[layout.app]], in: layout)
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
        // A folder the app cannot be taken out of, and no backup folder can be made in.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: layout.applications)
        let marker = UUID()
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: marker), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("new", at: layout.newApp))
        expectResult(InstallResult(outcome: .failedKeptOld, marker: marker), in: layout)
        expectOpened([[layout.app]], in: layout)
    }

    @Test func aNewAppThatCannotBeMovedInPutsTheOldOneBack() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // An immutable folder cannot be renamed.
        #expect(tool("/usr/bin/chflags", ["uchg", layout.newApp]) == 0)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("new", at: layout.newApp))
        #expect(layout.backupFolders().isEmpty)
        expectOutcome(.failedKeptOld, in: layout)
        #expect(layout.opened().isEmpty)
    }

    // MARK: The signature check

    @Test func aStagedAppChangedAfterSigningWritesFailedKeptOldAndNothingIsSwapped() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try MadeUpApp.change(layout.newApp, to: "evil")
        let marker = UUID()
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: marker), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("evil", at: layout.newApp))
        #expect(layout.backupFolders().isEmpty)
        expectResult(InstallResult(outcome: .failedKeptOld, marker: marker), in: layout)
        expectOpened([[layout.app]], in: layout)
    }

    @Test func aStagedAppChangedAndSignedAgainIsRefused() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // An intact signature, the same bundle id, but not the build that was staged.
        try MadeUpApp.change(layout.newApp, to: "evil")
        #expect(MadeUpApp.sign(layout.newApp))
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("evil", at: layout.newApp))
        expectOutcome(.failedKeptOld, in: layout)
    }

    @Test func aStagedLinkToTheSignedAppIsRefused() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // Moved in, the link would leave the install path pointing into a folder agents can write.
        let elsewhere = layout.staging + "/Elsewhere.app"
        try FileManager.default.moveItem(atPath: layout.newApp, toPath: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: layout.newApp, withDestinationPath: elsewhere)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.isFolder(layout.app))
        #expect(layout.holds("old", at: layout.app))
        expectOutcome(.failedKeptOld, in: layout)
    }

    @Test func aStagedAppWithAFileLinkedFromElsewhereIsRefused() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // The signature is intact, but whoever holds the other name could change the installed app.
        let version = layout.newApp + "/Contents/Resources/version"
        try FileManager.default.linkItem(atPath: version, toPath: layout.staging + "/kept")
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("old", at: layout.app))
        expectOutcome(.failedKeptOld, in: layout)
    }

    @Test func anAppChangedBetweenTheCheckAndTheMoveIsTakenOutAndTheOldOnePutBack() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // codesign as it is, except that right after its first check passes the staged app changes.
        let wrapper = layout.root + "/bin/codesign"
        let mark = ShellQuote.quote(layout.root + "/checked")
        let version = ShellQuote.quote(layout.newApp + "/Contents/Resources/version")
        let text = "#!/bin/sh\n/usr/bin/codesign \"$@\" || exit $?\n[ -e \(mark) ] && exit 0\n: > \(mark)\nprintf evil > \(version)\n"
        try text.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        var script = layout.script(pid: try endedProcess(), relaunch: true, marker: UUID())
        script.codesign = wrapper
        #expect(try run(script, in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(!FileManager.default.fileExists(atPath: layout.newApp))
        #expect(layout.backupFolders().isEmpty)
        expectOutcome(.failedKeptOld, in: layout)
        expectOpened([[layout.app]], in: layout)
    }

    @Test func anOldAppThatFailsItsCheckIsNeverOpened() throws {
        // Refused update, relaunch on: the old app stays in place but is not opened.
        let kept = try makeLayout()
        defer { remove(kept) }
        try MadeUpApp.change(kept.newApp, to: "evil")
        try MadeUpApp.change(kept.app, to: "changed")
        #expect(try run(kept.script(pid: try endedProcess(), relaunch: true), in: kept))
        #expect(kept.holds("changed", at: kept.app))
        #expect(kept.opened().isEmpty)
        // Stranded in its backup with a folder key: not opened either.
        let stranded = try makeLayout()
        defer { remove(stranded) }
        strand(stranded)
        try MadeUpApp.change(stranded.app, to: "changed")
        #expect(try run(stranded.script(pid: try endedProcess(), relaunch: true, folderKey: "0a1b2c3d4e5f"), in: stranded))
        expectOutcome(.failedRestoredBackup, in: stranded)
        #expect(stranded.opened().isEmpty)
    }

    // MARK: The backup

    @Test func aFolderOrLinkPlantedWhereTheBackupUsedToGoIsNeverUsed() throws {
        for asLink in [false, true] {
            let layout = try makeLayout()
            defer { remove(layout) }
            let planted = layout.root + "/planted.app"
            try MadeUpApp.make(at: planted, version: "planted")
            if asLink {
                try FileManager.default.createSymbolicLink(atPath: layout.stagingBackup, withDestinationPath: planted)
            } else {
                try FileManager.default.moveItem(atPath: planted, toPath: layout.stagingBackup)
            }
            // The staged app cannot be moved in, so the old one has to be put back.
            #expect(tool("/usr/bin/chflags", ["uchg", layout.newApp]) == 0)
            #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: UUID()), in: layout))
            #expect(layout.isFolder(layout.app))
            #expect(layout.holds("old", at: layout.app))
            #expect(layout.holds("planted", at: layout.stagingBackup))
            expectOutcome(.failedKeptOld, in: layout)
            expectOpened([[layout.app]], in: layout)
        }
    }

    @Test func aPlantedBackupWithNoStagedAppLeavesTheOriginalInPlace() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try MadeUpApp.make(at: layout.stagingBackup, version: "planted")
        try FileManager.default.removeItem(atPath: layout.newApp)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true, marker: UUID()), in: layout))
        #expect(layout.holds("old", at: layout.app))
        #expect(layout.holds("planted", at: layout.stagingBackup))
        expectOutcome(.failedKeptOld, in: layout)
        expectOpened([[layout.app]], in: layout)
    }

    @Test func whenTheOldAppCannotBePutBackItsBackupOpensWithTheOriginalFolderKey() throws {
        // With relaunch off too ("When I Quit"): otherwise no app would be where the user looks.
        for relaunch in [true, false] {
            let layout = try makeLayout()
            defer { remove(layout) }
            strand(layout)
            let marker = UUID()
            let script = layout.script(pid: try endedProcess(), relaunch: relaunch, marker: marker, folderKey: "0a1b2c3d4e5f")
            #expect(try run(script, in: layout))
            #expect(!FileManager.default.fileExists(atPath: layout.app))
            let backup = try #require(layout.backup)
            #expect(layout.holds("old", at: backup))
            expectResult(InstallResult(outcome: .failedRestoredBackup, marker: marker), in: layout)
            expectOpened([[backup, "--args", InstallScript.folderKeyArgument, "0a1b2c3d4e5f"]], in: layout)
        }
    }

    @Test func withoutAFolderKeyAStrandedBackupIsNotOpened() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        strand(layout)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: true), in: layout))
        let backup = try #require(layout.backup)
        #expect(layout.holds("old", at: backup))
        expectOutcome(.failedRestoredBackup, in: layout)
        #expect(layout.opened().isEmpty)
    }

    // MARK: Quoting

    @Test func everyPathIsQuotedEvenWithSpacesQuotesAndShellSyntax() throws {
        let name = "it's \"odd\" $(touch pwned) `touch pwned2`; touch pwned3 \\ $HOME *\nline"
        let layout = try makeLayout(named: name)
        defer { remove(layout) }
        let key = "k'ey $(touch pwned4)"
        let script = layout.script(pid: try endedProcess(), relaunch: true, marker: UUID(), folderKey: key)
        #expect(!script.text.contains(name))
        #expect(try run(script, in: layout))
        #expect(layout.holds("new", at: layout.app))
        expectOutcome(.installed, in: layout)
        expectOpened([[layout.app]], in: layout)
        let base = (layout.root as NSString).deletingLastPathComponent
        let made: [String] = try FileManager.default.contentsOfDirectory(atPath: base)
        let only: [String] = [name]
        #expect(made == only)
        let pwned: [String] = try FileManager.default.contentsOfDirectory(atPath: layout.root).filter { $0.hasPrefix("pwned") }
        #expect(pwned.isEmpty)
    }

    @Test func theBackupOpenQuotesAnOddFolderKeyAndPath() throws {
        let layout = try makeLayout(named: "it's a folder")
        defer { remove(layout) }
        strand(layout)
        let key = "k'ey $(touch pwned) x"
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, folderKey: key), in: layout))
        let backup = try #require(layout.backup)
        expectOpened([[backup, "--args", InstallScript.folderKeyArgument, key]], in: layout)
        #expect(!FileManager.default.fileExists(atPath: layout.root + "/pwned"))
    }

    // MARK: The result

    @Test func theResultFileIsPrivateAndReplacedThroughARename() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        // A link planted where the result goes is replaced, never written through.
        let elsewhere = layout.root + "/elsewhere"
        try "untouched".write(toFile: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: layout.resultFile, withDestinationPath: elsewhere)
        let script = layout.script(pid: try endedProcess(), relaunch: false, marker: UUID())
        #expect(try run(script, in: layout))
        #expect(try String(contentsOfFile: elsewhere, encoding: .utf8) == "untouched")
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.resultFile)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        // mktemp makes the file 0600 whatever the umask, so only the script's text shows umask 077.
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(script.text.contains("(umask 077; t=$(/usr/bin/mktemp "))
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.sessions) == [InstallResult.fileName])
        expectOutcome(.installed, in: layout)
    }

    @Test func aLinkToAFolderWhereTheResultGoesIsReplacedNotFollowed() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        let outside = layout.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.resultFile, withDestinationPath: outside)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.resultFile)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        expectOutcome(.installed, in: layout)
    }

    @Test func aFolderWhereTheResultGoesGetsNothing() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try FileManager.default.createDirectory(atPath: layout.resultFile, withIntermediateDirectories: true)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false, marker: UUID()), in: layout))
        #expect(layout.holds("new", at: layout.app))
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.resultFile).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.sessions) == [InstallResult.fileName])
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
        expectOpened([[layout.app]], in: layout)
    }

    @Test func aResultWithoutAMarkerStillSaysWhatHappened() throws {
        let layout = try makeLayout()
        defer { remove(layout) }
        try FileManager.default.removeItem(atPath: layout.newApp)
        #expect(try run(layout.script(pid: try endedProcess(), relaunch: false), in: layout))
        expectResult(InstallResult(outcome: .failedKeptOld, marker: nil), in: layout)
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

    // MARK: The text

    @Test func theStepsRunInOrderAndTheCheckComesBeforeAnyMove() throws {
        func text(relaunch: Bool) -> String {
            InstallScript(pid: 4242, app: "/Applications/Next Term.app", newApp: "/s/Next Term.app", staging: "/s",
                          requirement: #"identifier "com.example.new""#, oldRequirement: #"identifier "com.example.old""#,
                          relaunch: relaunch).text
        }
        let lines: [String] = text(relaunch: true).split(separator: "\n").map { line in line.trimmingCharacters(in: .whitespaces) }
        let wait = "while /bin/kill -0 4242 2>/dev/null; do /bin/sleep 0.2; done"
        #expect(lines.first == wait)
        let new = lines.first { $0.hasPrefix("new_ok() {") } ?? ""
        let old = lines.first { $0.hasPrefix("old_ok() {") } ?? ""
        #expect(new.contains(#"/usr/bin/codesign --verify --deep --strict -R '=identifier "com.example.new"' "$1""#))
        #expect(old.contains(#"/usr/bin/codesign --verify --deep --strict -R '=identifier "com.example.old"' "$1""#))
        let aside = "elif ! { backup=$(/usr/bin/mktemp -d '/Applications/.Next Term (previous).XXXXXX' 2>/dev/null)"
            + " && /bin/mv '/Applications/Next Term.app' \"$backup\"/'Next Term.app'; }; then"
        let order = [new, old, "if ! new_ok '/s/Next Term.app'; then", aside,
                     "elif /bin/mv '/s/Next Term.app' '/Applications/Next Term.app' && new_ok '/Applications/Next Term.app'; then",
                     "/bin/rm -rf \"$backup\" /s",
                     "/usr/bin/open '/Applications/Next Term.app'"]
        let indexes: [Int?] = order.map { line in lines.firstIndex(of: line) }
        #expect(indexes.allSatisfy { $0 != nil })
        let found: [Int] = indexes.compactMap { $0 }
        #expect(found == found.sorted())
        let firstMove: Int = lines.firstIndex { $0.contains("/bin/mv") } ?? Int.min
        let firstCheck: Int = lines.firstIndex { $0.hasPrefix("if ! new_ok") } ?? Int.max
        #expect(firstCheck < firstMove)
        let quiet = text(relaunch: false)
        #expect(!quiet.contains("/usr/bin/open"))
    }
}
