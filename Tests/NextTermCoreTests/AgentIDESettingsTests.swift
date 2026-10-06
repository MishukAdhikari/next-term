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
}
