import Foundation
import Testing
@testable import NextTermCore

/// The user's connected servers reach every agent with no step of its own: named in the instructions, their tools kept
/// loaded (never behind Claude Code's tool search), a server just connected listed as direct tools in the very first
/// session (MCPHubSession.warm), agents outside Next Term's tabs given the user's servers, and every built-in skill
/// saying how to use them.
@Suite struct MCPHubReachTests {
    @Test func theInstructionsNameTheConnectedServers() {
        for inTab in [false, true] {
            for tabs in [false, true] {
                let base = MCPServer.instructions(inTab: inTab, offeringTabs: tabs)
                #expect(MCPServer.instructions(inTab: inTab, offeringTabs: tabs, hubServers: []) == base)
                let said = MCPServer.instructions(inTab: inTab, offeringTabs: tabs, hubServers: ["weather", "linear"])
                #expect(said.contains("weather, linear") && said.contains("<server>__<tool>") && said.contains("mcp_call"))
                // Secrets' line stays first: Codex shows a deferred server's first line.
                #expect(said.hasPrefix(base.prefix { $0 != "\n" } + "\n"))
                #expect(said.utf16.count <= MCPServer.instructionsLimit)
                // Many servers: names that don't fit are counted, within the limit.
                let many = (1...200).map { "server-number-\($0)" }
                let crowded = MCPServer.instructions(inTab: inTab, offeringTabs: tabs, hubServers: many)
                #expect(crowded.utf16.count <= MCPServer.instructionsLimit && crowded.contains("more") && crowded.contains("server-number-1"))
            }
        }
    }

    @Test func catalogAndDirectToolsAreKeptLoaded() {
        #expect(MCPHubCatalog.tools.allSatisfy { $0.alwaysLoad })
        let entry = MCPHubDirect.Entry(name: "s__t", server: "s", tool: MCPHubManifest.Tool(name: "t"))
        #expect(MCPHubDirect.listed(entry).alwaysLoad)
    }

    @Test func anAgentOutsideTheTabsGetsAFolder() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-reach-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: made) }
        #expect(MCPHubPlan.outsideFolder(made, home: "/") == canonicalPath(made))
        #expect(MCPHubPlan.outsideFolder(nil, home: made) == canonicalPath(made))
        #expect(MCPHubPlan.outsideFolder("relative/path", home: made) == canonicalPath(made))
        #expect(MCPHubPlan.outsideFolder(made + "/missing", home: made) == canonicalPath(made))
    }

    @Test func everyBuiltInSkillSaysHowToUseConnectedServers() {
        for skill in BuiltInSkill.all {
            for word in ["<server>__<tool>", "mcp_servers", "mcp_tools", "mcp_call", "list_mcp_servers", "add_mcp_server"] {
                #expect(skill.text.contains(word), "\(skill.name): \(word)")
            }
        }
    }

    /// A server just connected (no cached tool list): the first session starts it before its tool list, and its tools
    /// are that session's own, called straight through.
    @Test func aServerJustConnectedIsDirectInItsFirstSession() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-warm-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: made) }
        let script = made + "/fake.sh"
        try MCPHubSessionTests.fake.write(toFile: script, atomically: true, encoding: .utf8)
        let server = MCPHubPlan.Server(name: "fake", state: .ready, command: "/bin/sh", args: [script], list: "/u/mcp.json")
        let plan = MCPHubPlan(folder: canonicalPath(made), path: ["/usr/bin", "/bin"], servers: [server])
        let learned = Learned()
        let session = MCPHubSession(plan: plan, refresh: { plan }, nxtrm: ["/usr/bin/true"], environment: ["HOME": NSHomeDirectory()],
                                    version: "0.0.0", remember: { name, _, manifest in learned.add(name, manifest.count) })
        defer { session.stop() }
        #expect(session.unlisted == ["fake"] && session.tools.map(\.name) == MCPHubCatalog.tools.map(\.name))
        session.warm(seconds: 10)
        let names = session.tools.map(\.name)
        #expect(names.contains("fake__echo") && names.contains("fake__where"))
        #expect(session.serverNames == ["fake"])
        let result = session.call("fake__echo", [:])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text == "hello from fake" && result["isError"] as? Bool != true)
        // The app is told, so the next sessions have them from the cache.
        #expect(learned.all == ["fake": 6])
    }

    @Test func warmingLeavesASessionWithCachedListsAlone() {
        let cached = MCPHubPlan.Server(name: "c", state: .ready, command: "/bin/false", list: "/u", manifest: "d", cachedTools: 1,
                                       tools: [MCPHubManifest.Tool(name: "t")])
        let plan = MCPHubPlan(folder: "/", servers: [cached])
        let session = MCPHubSession(plan: plan, refresh: { plan }, nxtrm: [], environment: [:], version: "0")
        #expect(session.unlisted.isEmpty)
        session.warm(seconds: 1)
        #expect(session.tools.map(\.name) == MCPHubCatalog.tools.map(\.name) + ["c__t"])
    }

    final class Learned: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: Int] = [:]
        func add(_ name: String, _ count: Int) { lock.lock(); found[name] = count; lock.unlock() }
        var all: [String: Int] { lock.lock(); defer { lock.unlock() }; return found }
    }
}
