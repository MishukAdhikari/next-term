import Foundation
import Testing
@testable import NextTermCore

/// Settings › Tasks' Handoff folder row: a folder picked in the open panel becomes a setting relative to the project,
/// or nothing when it is not a plain folder inside it, and saving it changes only this project's entry.
@Suite struct HandoffFolderSettingTests {
    func project() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-handoff-pick-\(UUID().uuidString)"
        for folder in ["/project/notes/handoffs", "/elsewhere"] {
            try FileManager.default.createDirectory(atPath: dir + folder, withIntermediateDirectories: true)
        }
        return dir
    }

    @Test func aFolderPickedInsideTheProjectIsStoredRelative() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        #expect(TaskSettings.handoffSetting(picked: project + "/notes/handoffs", in: project) == "notes/handoffs")
        #expect(TaskSettings.handoffSetting(picked: project + "/notes/handoffs/", in: project) == "notes/handoffs")
        // Not there yet: the agent makes it.
        #expect(TaskSettings.handoffSetting(picked: project + "/notes/new", in: project) == "notes/new")
    }

    @Test func aFolderPickedOutsideOrThroughALinkIsRefused() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        try FileManager.default.createSymbolicLink(atPath: project + "/out", withDestinationPath: dir + "/elsewhere")
        try FileManager.default.createSymbolicLink(atPath: project + "/inside", withDestinationPath: project + "/notes")
        let refused = [dir + "/elsewhere", NSHomeDirectory(), project, project + "/out", project + "/out/handoffs",
                       project + "/inside", project + "/inside/handoffs", project + "/../elsewhere",
                       project + "/notes/../../elsewhere", project + "/.git/handoffs", "notes", "/"]
        for picked in refused {
            #expect(TaskSettings.handoffSetting(picked: picked, in: project) == nil, "\(picked)")
        }
    }

    @Test func aProjectReachedThroughALinkStillTakesItsOwnFolders() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir + "/alias", withDestinationPath: dir + "/project")
        // The window names the project by the link; the panel gives the real path.
        let viaLink = TaskSettings.handoffSetting(picked: dir + "/project/notes/handoffs", in: dir + "/alias")
        #expect(viaLink == "notes/handoffs")
    }

    @Test func savingTheFolderChangesOnlyThisProjectsEntry() throws {
        let saved = #"{"/other":{"handoffFolder":"x"},"/p":{"destination":{"kind":"things"},"future":1}}"#
        let json: String = try #require(TaskSettings.json(saved: saved, handoffFolder: "notes/handoffs", for: "/p"))
        let read = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        #expect(read["/p"]?["handoffFolder"] as? String == "notes/handoffs")
        #expect(read["/p"]?["future"] as? Int == 1 && read["/p"]?["destination"] != nil)
        #expect(read["/other"]?["handoffFolder"] as? String == "x")
        // Use Default clears it; an entry left empty goes.
        let cleared: String = try #require(TaskSettings.json(saved: json, handoffFolder: nil, for: "/p"))
        #expect(!cleared.contains("notes/handoffs") && cleared.contains("things"))
        let gone: String = try #require(TaskSettings.json(saved: #"{"/p":{"handoffFolder":"a"}}"#, handoffFolder: nil,
                                                          for: "/p"))
        #expect(gone == "{}")
        // Saved choices that can't be read are never written over.
        #expect(TaskSettings.json(saved: "not json", handoffFolder: "a", for: "/p") == nil)
        #expect(TaskSettings.json(saved: nil, handoffFolder: "a", for: "/p") == #"{"/p":{"handoffFolder":"a"}}"#)
    }

    @Test func everyWorktreeOfTheProjectReadsTheSameValue() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        let json: String = try #require(TaskSettings.json(saved: nil, handoffFolder: "notes/handoffs",
                                                          for: TaskSettings.projectKey(project)))
        let suite = "nt-handoff-pick-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(json, forKey: TaskSettings.Key.projects)
        #expect(TaskSettings(defaults: defaults).handoffFolder(for: project) == "notes/handoffs")
    }
}
