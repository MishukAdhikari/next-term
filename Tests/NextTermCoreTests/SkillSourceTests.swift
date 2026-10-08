import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillSourceTests {
    /// Public examples: Anthropic's and OpenAI's skill repositories.
    @Test func whatPeoplePaste() {
        #expect(SkillSource.parse("anthropics/skills") == SkillSource(owner: "anthropics", repo: "skills"))
        #expect(SkillSource.parse("openai/skills/skills/.curated/gh-fix-ci") == SkillSource(owner: "openai", repo: "skills", path: "skills/.curated/gh-fix-ci"))
        #expect(SkillSource.parse("https://github.com/anthropics/skills") == SkillSource(owner: "anthropics", repo: "skills"))
        #expect(SkillSource.parse("https://github.com/anthropics/skills/tree/main/skills/skill-creator")
                == SkillSource(owner: "anthropics", repo: "skills", ref: "main", path: "skills/skill-creator"))
        #expect(SkillSource.parse("github.com/anthropics/skills/blob/main/skills/mcp-builder/SKILL.md")
                == SkillSource(owner: "anthropics", repo: "skills", ref: "main", path: "skills/mcp-builder"))
        #expect(SkillSource.parse("https://github.com/openai/skills.git")?.repo == "skills")
    }

    @Test func notGitHubOrUnsafe() {
        #expect(SkillSource.parse("https://gitlab.com/a/b") == nil)
        #expect(SkillSource.parse("just-one-word") == nil)
        #expect(SkillSource.parse("owner/repo/../../etc") == nil)
        #expect(SkillSource.parse("-owner/repo") == nil)
        #expect(SkillSource.parse("owner/re po") == nil)
    }
}

@Suite struct GitHashTests {
    /// Compares with git itself, on a folder with a file, an executable, a link and a subfolder.
    @Test func treeHashesMatchGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-githash-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let skill = root + "/skills/demo"
        try FileManager.default.createDirectory(atPath: skill + "/scripts", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: skill + "/empty", withIntermediateDirectories: true)
        try "---\nname: demo\n---\nBody\n".write(toFile: skill + "/SKILL.md", atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho hi\n".write(toFile: skill + "/scripts/run.sh", atomically: true, encoding: .utf8)
        chmod(skill + "/scripts/run.sh", 0o755)
        try "a".write(toFile: skill + "/a-b.txt", atomically: true, encoding: .utf8)
        try "b".write(toFile: skill + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: skill + "/link", withDestinationPath: "a.txt")
        func git(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root] + args
            process.environment = ["HOME": root, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q"])
        _ = try git(["add", "-A"])
        _ = try git(["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "-m", "x"])
        let expected = try git(["rev-parse", "HEAD:skills/demo"])
        #expect(!expected.isEmpty)
        #expect(GitHash.folder(skill) == expected)
        #expect(GitHash.blob(Data("b".utf8)) == (try git(["rev-parse", "HEAD:skills/demo/a.txt"])))
    }
}
