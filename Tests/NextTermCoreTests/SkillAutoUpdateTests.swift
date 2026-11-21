import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillAutoUpdateTests {
    /// A skill folder named demo, with these files beside its SKILL.md; `executable` marks paths as runnable.
    func review(_ files: [String: String], executable: Set<String> = []) throws -> SkillReview {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-auto-\(UUID().uuidString)/demo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: A demo skill.\n---\nUse it well.\n".write(toFile: root + "/SKILL.md", atomically: true, encoding: .utf8)
        for (path, content) in files {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
            if executable.contains(path) { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full) }
        }
        return SkillReview.review(folder: root, folderName: "demo")
    }

    @Test func textChangesInstallByThemselves() throws {
        let installed = try review(["reference.md": "Old notes."])
        let update = try review(["reference.md": "New notes.", "more.md": "Another page."])
        #expect(SkillAutoUpdate.hold(installed: installed, update: update, edited: false) == nil)
    }

    @Test func aScriptItAlreadyHadMayChange() throws {
        let installed = try review(["scripts/run.sh": "echo one\n"], executable: ["scripts/run.sh"])
        let update = try review(["scripts/run.sh": "echo two\n"], executable: ["scripts/run.sh"])
        #expect(SkillAutoUpdate.hold(installed: installed, update: update, edited: false) == nil)
    }

    @Test func somethingNewThatRunsWaitsForAReview() throws {
        let installed = try review(["reference.md": "Notes."])
        let update = try review(["reference.md": "Notes.", "scripts/setup.sh": "curl example.com\n"], executable: ["scripts/setup.sh"])
        let why = SkillAutoUpdate.hold(installed: installed, update: update, edited: false)
        #expect(why?.contains("scripts/setup.sh") == true, "\(why ?? "nil")")
    }

    @Test func localChangesAndUnreadCopiesWait() throws {
        let same = try review(["reference.md": "Notes."])
        #expect(SkillAutoUpdate.hold(installed: same, update: same, edited: true)?.contains("You changed it") == true)
        #expect(SkillAutoUpdate.hold(installed: nil, update: same, edited: false) != nil)
    }

    @Test func aRefusedUpdateWaits() throws {
        let installed = try review([:])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-auto-\(UUID().uuidString)/demo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // No SKILL.md: not a skill, refused.
        let refused = SkillReview.review(folder: root, folderName: "demo")
        #expect(refused.refused && SkillAutoUpdate.hold(installed: installed, update: refused, edited: false)?.hasPrefix("The update can") == true)
    }
}
