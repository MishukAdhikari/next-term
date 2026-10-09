import Foundation
import Testing
@testable import NextTermCore

/// Claude Code's plugin facts, read from a home folder built in the test: never written.
@Suite struct SkillClaudeSettingsTests {
    let home: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-claude-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.claude/plugins", withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let full = (home as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func snapshot(_ keys: [String] = []) -> SkillClaudeSettings.Snapshot {
        SkillClaudeSettings.snapshot(home: home, keys: keys)
    }

    @Test func theKeyIsThePluginNameAndTheSentinel() {
        #expect(SkillClaudeSettings.key("writing-helper") == "writing-helper@skills-dir")
    }

    @Test func enabledPluginsGivesTheValuesAskedFor() throws {
        let settings = #"{"model": "x", "enabledPlugins": {"writing-helper@skills-dir": false, "other@skills-dir": true, "#
            + #""odd@skills-dir": "no", "docs@market": true}}"#
        try write(".claude/settings.json", settings)
        let facts = snapshot(["writing-helper@skills-dir", "other@skills-dir", "odd@skills-dir", "absent@skills-dir"])
        #expect(facts.values == ["writing-helper@skills-dir": false, "other@skills-dir": true])
        #expect(facts.value(for: "writing-helper") == false && facts.value(for: "absent") == nil)
        // Keys are compared exactly, as Claude Code compares them (hand check H2).
        #expect(snapshot(["Writing-helper@skills-dir"]).values.isEmpty)
    }

    /// Claude Code reads its settings with JSON.parse: the last of two equal keys wins, and a comment
    /// makes the file unreadable to it, so no value is taken from it.
    @Test func theLastOfTwoEqualKeysWinsAndACommentGivesNoValues() throws {
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false, "a@skills-dir": true}}"#)
        #expect(snapshot(["a@skills-dir"]).values == ["a@skills-dir": true])
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false}, "enabledPlugins": {"b@skills-dir": false}}"#)
        #expect(snapshot(["a@skills-dir", "b@skills-dir"]).values == ["b@skills-dir": false])
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false, "a@skills-dir": "on"}}"#)
        #expect(snapshot(["a@skills-dir"]).values.isEmpty)
        try write(".claude/settings.json", "{\n  // off for now\n  \"enabledPlugins\": {\"a@skills-dir\": false}\n}\n")
        #expect(snapshot(["a@skills-dir"]).values.isEmpty)
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false,}}"#)
        #expect(snapshot(["a@skills-dir"]).values.isEmpty)
    }

    @Test func installedPluginsGiveNameMarketplaceScopesAndOnOrOff() throws {
        try write(".claude/plugins/installed_plugins.json", """
            {"version": 2, "plugins": {
              "writing-helper@some-market": [{"scope": "user", "installPath": "/x", "version": "1.0.0"}],
              "docs@team.market": [{"scope": "project", "projectPath": "/p", "installPath": "/y"},
                                   {"scope": "local", "projectPath": "/q", "installPath": "/z"}],
              "policy@org": [{"scope": "managed", "installPath": "/m"}],
              "a@b@c": [{"scope": "user", "installPath": "/n"}]
            }}
            """)
        try write(".claude/settings.json", #"{"enabledPlugins": {"writing-helper@some-market": false, "docs@team.market": true}}"#)
        let installed = snapshot().installed
        #expect(installed.map(\.name) == ["a@b", "docs", "policy", "writing-helper"])
        let writing = try #require(installed.first { $0.name == "writing-helper" })
        #expect(writing.marketplace == "some-market" && writing.scopes == ["user"] && writing.enabled == false && writing.everywhere)
        let docs = try #require(installed.first { $0.name == "docs" })
        #expect(docs.marketplace == "team.market" && docs.scopes == ["project", "local"] && docs.enabled == true && !docs.everywhere)
        #expect(installed.first { $0.name == "policy" }?.everywhere == true)
        #expect(installed.first { $0.name == "a@b" }?.marketplace == "c")
    }

    /// Version 1 kept one install per plugin, with no scope: it was installed for the user.
    @Test func versionOneInstallsAreTheUsers() throws {
        try write(".claude/plugins/installed_plugins.json", #"{"version": 1, "plugins": {"old@legacy": {"version": "1", "installPath": "/w"}}}"#)
        #expect(snapshot().installed == [.init(name: "old", marketplace: "legacy", scopes: ["user"], enabled: nil)])
    }

    @Test func syncedPluginsAreReadFromEachBucketSkippingDotFolders() throws {
        try write(".claude/plugins/synced/org-1/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper", "displayName": "Writing Helper"}"#)
        try write(".claude/plugins/synced/user/notes/.claude-plugin/plugin.json", #"{"description": "No name: the folder's."}"#)
        try write(".claude/plugins/synced/.cache/hidden/.claude-plugin/plugin.json", #"{"name": "hidden"}"#)
        try write(".claude/plugins/synced/user/.partial/.claude-plugin/plugin.json", #"{"name": "partial"}"#)
        try write(".claude/plugins/synced/user/broken/.claude-plugin/plugin.json", "{")
        try write(".claude/plugins/synced/user/empty/README.md", "No manifest.")
        let synced = snapshot().synced
        #expect(synced == [.init(name: "notes", displayName: nil), .init(name: "writing-helper", displayName: "Writing Helper")])
    }

    /// Missing, broken or oddly shaped files give nothing from them, and never a failure.
    @Test func missingOrBrokenFilesGiveNothing() throws {
        #expect(snapshot(["a@skills-dir"]) == .init())
        try write(".claude/settings.json", #"{"enabledPlugins": [false]}"#)
        try write(".claude/plugins/installed_plugins.json", "not JSON")
        try write(".claude/plugins/synced", "A file, not a folder.")
        #expect(snapshot(["a@skills-dir"]) == .init())
        try write(".claude/plugins/installed_plugins.json", #"{"version": 2, "plugins": {"a@m": 7, "b@m": [{"scope": 3}], "c@m": []}}"#)
        #expect(snapshot().installed.isEmpty)
        try write(".claude/plugins/installed_plugins.json", #"{"version": 2, "plugins": ["a@m"]}"#)
        #expect(snapshot().installed.isEmpty)
    }

    /// A settings file larger than the review's 5 MB cap is not read.
    @Test func aHugeSettingsFileIsNotRead() throws {
        let padding = String(repeating: " ", count: SkillReview.maxReadSize)
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false}}"# + padding)
        #expect(snapshot(["a@skills-dir"]).values.isEmpty)
    }

    /// Reading never writes: the files keep their bytes and dates.
    @Test func readingWritesNothing() throws {
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@skills-dir": false}}"#)
        let path = home + "/.claude/settings.json"
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let bytes = FileManager.default.contents(atPath: path)
        _ = snapshot(["a@skills-dir"])
        _ = SkillInventory.scan(home: home)
        #expect(FileManager.default.contents(atPath: path) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
    }
}
