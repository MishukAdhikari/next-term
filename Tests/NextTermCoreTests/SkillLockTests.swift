import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillLockTests {
    let existing = """
        {
          "version": 3,
          "skills": {
            "tidy-prose": {
              "source": "example-org/tidy-prose", "sourceType": "github", "sourceUrl": "https://github.com/example-org/tidy-prose.git",
              "skillPath": "SKILL.md", "skillFolderHash": "0123456789abcdef0123456789abcdef01234567", "pluginName": "tidy-prose",
              "installedAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"
            }
          },
          "dismissed": { "someNotice": true },
          "lastSelectedAgents": ["example-agent"]
        }
        """

    @Test func addingAnEntryKeepsEverythingElse() throws {
        let entry = SkillLock.Entry(source: "example-org/skills", sourceUrl: "https://github.com/example-org/skills.git",
                                    skillPath: "skills/fill-forms/SKILL.md", skillFolderHash: "abc123",
                                    installedAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let text = try SkillLock.updated(existing, name: "fill-forms", entry: entry).get()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let skills = try #require(object["skills"] as? [String: Any])
        #expect(Set(skills.keys) == ["tidy-prose", "fill-forms"])
        #expect((skills["tidy-prose"] as? [String: Any])?["pluginName"] as? String == "tidy-prose")
        #expect((object["dismissed"] as? [String: Any])?["someNotice"] as? Bool == true)
        #expect(object["lastSelectedAgents"] as? [String] == ["example-agent"])
        let fillForms = try #require(skills["fill-forms"] as? [String: Any])
        #expect(fillForms["sourceType"] as? String == "github" && fillForms["skillFolderHash"] as? String == "abc123")
        #expect((fillForms["installedAt"] as? String)?.hasSuffix("Z") == true)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString).json").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let read = try SkillLock.entries(at: path).get()
        #expect(read["fill-forms"]?.skillPath == "skills/fill-forms/SKILL.md" && read["tidy-prose"]?.source == "example-org/tidy-prose")
    }

    @Test func removingAndStartingFresh() throws {
        let removed = try SkillLock.updated(existing, name: "tidy-prose", entry: nil).get()
        #expect(!removed.contains("\"tidy-prose\" :"))
        #expect(removed.contains("someNotice"))
        let fresh = try SkillLock.updated(nil, name: "x", entry: SkillLock.Entry(source: "a/b", sourceUrl: "u", skillPath: "SKILL.md", skillFolderHash: "h", installedAt: Date(), updatedAt: Date())).get()
        #expect(fresh.contains("\"version\" : 3"))
    }

    @Test func aNewerFormatIsLeftAlone() {
        #expect(SkillLock.updated(#"{"version": 4, "skills": {}}"#, name: "x", entry: nil) == .failure(.newerVersion(4)))
        #expect(SkillLock.updated("not json", name: "x", entry: nil) == .failure(.unreadable))
    }

    @Test func theLockFollowsXDGStateHome() {
        #expect(SkillLock.path(home: "/Users/me", environment: [:]) == "/Users/me/.agents/.skill-lock.json")
        #expect(SkillLock.path(home: "/Users/me", environment: ["XDG_STATE_HOME": "/s"]) == "/s/skills/.skill-lock.json")
    }
}
