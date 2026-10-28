import Foundation
import Testing
@testable import NextTermCore

/// rename_tab's title (plan 010a U5a), and the tool as listed.
@Suite struct TabRenameTests {
    @Test func aTitleIsOneLineCutAt100AndEmptyGivesTheTabsOwnBack() throws {
        #expect(try TabRename.title("  API server  ").get() == "API server")
        #expect(try TabRename.title("").get() == nil)
        #expect(try TabRename.title("   ").get() == nil)
        #expect(try TabRename.title(String(repeating: "a", count: 140)).get() == String(repeating: "a", count: 100))
        for bad in ["a\nb", "a\rb", "tab\u{1b}[31m", "a\u{7f}"] {
            #expect(throws: TabRenameRefusal.self, "\(bad.debugDescription)") { try TabRename.title(bad).get() }
        }
    }

    /// Approval windows name tabs by their titles, so a title holds nothing that hides or reorders text (010a review):
    /// C1 controls, direction marks and isolates, zero-width characters, soft hyphens, line and paragraph separators.
    @Test func aTitleHoldsNothingThatHidesOrReordersText() throws {
        for bad in ["a\u{85}b", "code-ab\u{202E}evil", "api\u{2066}x\u{2069}", "a\u{200B}b", "a\u{200F}b", "a\u{AD}b",
                    "a\u{2028}b", "a\u{2029}b", "a\u{FEFF}b"] {
            #expect(throws: TabRenameRefusal.self, "\(bad.debugDescription)") { try TabRename.title(bad).get() }
        }
        #expect(try TabRename.title("Café ☕ 日本 — tests").get() == "Café ☕ 日本 — tests")
        // The zero-width joiner inside emoji is allowed.
        #expect(try TabRename.title("🧑‍💻 api · 👩‍💻").get() == "🧑‍💻 api · 👩‍💻")
        // new_tab's and new_remote_tab's title: none when not given, null or empty; otherwise rename_tab's rules.
        #expect(try TabRename.given(nil).get() == nil)
        #expect(try TabRename.given(NSNull()).get() == nil)
        #expect(try TabRename.given("  ").get() == nil)
        #expect(try TabRename.given(" api ").get() == "api")
        #expect(throws: TabRenameRefusal.self) { try TabRename.given(42).get() }
        #expect(throws: TabRenameRefusal.self) { try TabRename.given("a\u{202E}b").get() }
        // A host's name given now, which approval windows name it by, the same; an emoji name is fine.
        #expect(RemoteHost.nameProblem("web\u{202E}1")?.contains("show as themselves") == true)
        #expect(RemoteHost.nameProblem("🧑‍💻 dev box") == nil && RemoteHost.nameProblem("web-1") == nil)
        // A host saved earlier under such a name is never dropped: the check is for new names only, not `problem`.
        let old = RemoteHost(name: "web\u{202E}1", destination: "dev@203.0.113.5")
        #expect(old.problem == nil)
        #expect(RemoteHost.decodeList(RemoteHost.encodeList([old])).map(\.name) == ["web\u{202E}1"])
    }

    @Test func theToolOnlyChangesALabel() throws {
        let tool = try #require(MCPServer.tool(named: "rename_tab"))
        #expect(!tool.readOnly && !tool.destructive && tool.idempotent)
        #expect(MCPServer.scopeTags["rename_tab"] == .write)
        #expect(!MCPServer.isControlTool("rename_tab"))
        #expect(MCPRemoteReach.refusal("rename_tab", ["tab_id": "x"]) != nil)
    }

    /// The tools plan 010a adds say what they do in two short sentences at most, and add nothing to the instructions.
    @Test func theNewToolsAreTwoSentencesAtMost() throws {
        for name in ["edit_host", "end_session", "rename_tab", "start_agent"] {
            let said = try #require(MCPServer.tool(named: name)).description
            let sentences = said.components(separatedBy: ". ").count
            #expect(sentences <= 2 && said.count <= 300, "\(name): \(said)")
            #expect(MCPRemoteReach.text.contains(name), "\(name)")
            #expect(!MCPServer.instructions.contains(name), "\(name)")
        }
    }
}
