import Foundation
import Testing
@testable import NextTermCore

/// Signatures read from made-up apps signed ad hoc, and the requirement an update must meet.
@Suite struct CodeSignatureTests {
    func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nt-sig-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func anAppSignedAdHocIsKnownByItsOwnHashesAndNoTeam() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let app = root + "/Made Up.app"
        try MadeUpApp.make(at: app, version: "1")
        #expect(MadeUpApp.sign(app))
        let signature = try #require(CodeSignature.of(URL(fileURLWithPath: app)))
        #expect(signature.team == nil)
        #expect(signature.requirement.hasPrefix("cdhash H\""))
        let printed: String? = MadeUpApp.designated(app)
        #expect(printed == signature.requirement)
    }

    @Test func anUnsignedAppHasNoSignature() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let app = root + "/Made Up.app"
        try MadeUpApp.make(at: app, version: "1")
        let unsigned: CodeSignature? = CodeSignature.of(URL(fileURLWithPath: app))
        let missing: CodeSignature? = CodeSignature.of(URL(fileURLWithPath: root + "/Missing.app"))
        #expect(unsigned == nil)
        #expect(missing == nil)
    }

    @Test func theRunningProcessHasASignatureToRead() throws {
        // On Apple silicon every program is signed, at least ad hoc.
        let signature = try #require(CodeSignature.running())
        #expect(!signature.requirement.isEmpty)
    }

    @Test func twoBuildsSignedAdHocHaveDifferentRequirements() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try MadeUpApp.make(at: root + "/A.app", version: "1")
        try MadeUpApp.make(at: root + "/B.app", version: "2")
        #expect(MadeUpApp.sign(root + "/A.app") && MadeUpApp.sign(root + "/B.app"))
        let first = CodeSignature.of(URL(fileURLWithPath: root + "/A.app"))?.requirement
        let second = CodeSignature.of(URL(fileURLWithPath: root + "/B.app"))?.requirement
        #expect(first != nil && second != nil && first != second)
    }

    @Test func aTeamSignedAppTakesOnlyAnUpdateFromItsOwnTeam() {
        let running = CodeSignature(requirement: #"identifier "com.example.app" and certificate leaf[subject.OU] = "ABCDE12345""#,
                                    team: "ABCDE12345")
        let staged = CodeSignature(requirement: #"identifier "com.example.app" and certificate leaf[subject.OU] = "ZZZZZ99999""#,
                                   team: "ZZZZZ99999")
        #expect(CodeSignature.updateRequirement(running: running, staged: staged) == running.requirement)
    }

    @Test func anAppSignedAdHocTakesOnlyTheExactBuildThatWasStaged() {
        let running = CodeSignature(requirement: #"cdhash H"0123456789abcdef0123456789abcdef01234567""#, team: nil)
        let staged = CodeSignature(requirement: #"cdhash H"89abcdef0123456789abcdef0123456789abcdef""#, team: nil)
        #expect(CodeSignature.updateRequirement(running: running, staged: staged) == staged.requirement)
    }
}

/// A made-up app bundle: a shell script for its program and its `version` in its resources, so a
/// test can tell two apps apart and change one after it is signed.
enum MadeUpApp {
    static let identifier = "com.example.made-up"

    static func make(at path: String, version: String) throws {
        let files = FileManager.default
        try files.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try files.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "MadeUp", "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        try "#!/bin/sh\nexit 0\n".write(toFile: path + "/Contents/MacOS/MadeUp", atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path + "/Contents/MacOS/MadeUp")
        try change(path, to: version)
    }

    /// Writes the app's version in place: after signing, that breaks its signature.
    static func change(_ path: String, to version: String) throws {
        try version.write(toFile: path + "/Contents/Resources/version", atomically: false, encoding: .utf8)
    }

    /// Signs the app ad hoc, replacing any signature it has.
    static func sign(_ path: String) -> Bool {
        run(["-s", "-", "-f", path]).status == 0
    }

    /// The designated requirement as `codesign -d -r-` prints it.
    static func designated(_ path: String) -> String? {
        let prefix = "# designated => "
        let lines = run(["-d", "-r-", path]).output.split(separator: "\n").map(String.init)
        return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
