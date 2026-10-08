import Foundation
import Testing
@testable import NextTermCore

@Suite struct AgentIDESettingsTests {
    func home() throws -> URL {
        let dir = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        return dir
    }

    func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func turnsItOnKeepingEverythingElse() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        let original = "{\n  \"theme\": \"GitHub\",\n  \"selectedAuthType\": \"oauth-personal\"\n}\n"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .enabled)
        let after = try String(contentsOf: settings, encoding: .utf8)
        #expect((json(settings)?["ide"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(json(settings)?["theme"] as? String == "GitHub" && json(settings)?["selectedAuthType"] as? String == "oauth-personal")
        // Only inserted: the original text is still there, in order.
        #expect(after.contains("\"theme\": \"GitHub\",\n  \"selectedAuthType\": \"oauth-personal\"\n}"))
        #expect(AgentIDESettings.ensureEnabled(settings) == .alreadyOn)
    }

    @Test func respectsTheUsersChoiceAndComments() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        try "{\"ide\": {\"enabled\": false}}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .leftOff)
        #expect(AgentIDESettings.ensureEnabled(settings, overridingOff: true) == .enabled) // Next Term's switch is on
        #expect((json(settings)?["ide"] as? [String: Any])?["enabled"] as? Bool == true)
        try "{\"ide\": {\"enabled\": false}}".write(to: settings, atomically: true, encoding: .utf8)
        let commented = "{\n  // my theme\n  \"theme\": \"Dracula\"\n}\n"
        try commented.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .skipped)
        #expect(try String(contentsOf: settings, encoding: .utf8) == commented)
        try "{\"ide\": {\"hasSeenNudge\": true}, \"theme\": \"x\"}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .enabled)
        #expect((json(settings)?["ide"] as? [String: Any])?["hasSeenNudge"] as? Bool == true)
        #expect((json(settings)?["ide"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func onlyTheIDESwitchChanges() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        try "{\"telemetry\": {\"enabled\": false}, \"ide\": {\"enabled\": false}}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings, overridingOff: true) == .enabled)
        #expect((json(settings)?["telemetry"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((json(settings)?["ide"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func createsTheFileOnlyWhenTheAgentIsInstalled() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let gemini = home.appendingPathComponent(".gemini/settings.json")
        #expect(AgentIDESettings.ensureEnabled(gemini) == .enabled) // folder exists, no file
        #expect((json(gemini)?["ide"] as? [String: Any])?["enabled"] as? Bool == true)
        let qwen = home.appendingPathComponent(".qwen/settings.json")
        #expect(AgentIDESettings.ensureEnabled(qwen) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".qwen").path))
        let empty = home.appendingPathComponent(".gemini/settings.json")
        try "{}".write(to: empty, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(empty) == .enabled)
    }

    @Test func deepNestingAndRepeatedKeysAreLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        // Deeper than JSONC.maxDepth: read without recursion, and skipped rather than a crash.
        let deep = "{\"a\": " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "}"
        try deep.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .skipped)
        #expect(try String(contentsOf: settings, encoding: .utf8) == deep)
        // Within the limit it is read.
        let deepish = "{\"a\": " + String(repeating: "[", count: 200) + String(repeating: "]", count: 200) + "}"
        try deepish.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .enabled)
        // Gemini reads the last of two "ide" keys; an edit would go to the first.
        let twice = "{\"ide\": {\"enabled\": false}, \"ide\": {\"enabled\": true}}"
        try twice.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings, overridingOff: true) == .skipped)
        #expect(try String(contentsOf: settings, encoding: .utf8) == twice)
        // A trailing comma is not plain JSON.
        try "{\"theme\": \"x\",}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .skipped)
    }

    @Test func onlyTheTopLevelIDESettingIsTheSwitch() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        // An "ide" inside another setting, and in a string, come before the real one: neither is it.
        let text = "{\n  \"note\": \"\\\"ide\\\": {\\\"enabled\\\": false}\",\n  \"mcpServers\": {\"x\": {\"ide\": {\"enabled\": false}}},\n  \"ide\": {\"enabled\": false}\n}\n"
        try text.write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings, overridingOff: true) == .enabled)
        let after = try String(contentsOf: settings, encoding: .utf8)
        #expect(after == text.replacingOccurrences(of: "\"ide\": {\"enabled\": false}\n}", with: "\"ide\": {\"enabled\": true}\n}"))
        let servers = json(settings)?["mcpServers"] as? [String: Any]
        #expect(((servers?["x"] as? [String: Any])?["ide"] as? [String: Any])?["enabled"] as? Bool == false)
        // An "ide" that is not an object is not ours.
        try "{\"ide\": true}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(AgentIDESettings.ensureEnabled(settings) == .skipped)
    }

    @Test func theFileKeepsItsPermissionsAndByteOrderMark() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("{\n  \"apiKey\": \"made-up\"\n}\n".utf8)).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        #expect(AgentIDESettings.ensureEnabled(settings) == .enabled)
        let data = try Data(contentsOf: settings)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect((try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path) == ["settings.json"])
        // A new file is its owner's alone.
        let qwen = home.appendingPathComponent(".qwen/settings.json")
        try FileManager.default.createDirectory(at: qwen.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(AgentIDESettings.ensureEnabled(qwen) == .enabled)
        #expect((try FileManager.default.attributesOfItem(atPath: qwen.path)[.posixPermissions] as? Int) == 0o600)
    }
}
