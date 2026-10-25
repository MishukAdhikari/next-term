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

    @Test func theToolOnlyChangesALabel() throws {
        let tool = try #require(MCPServer.tool(named: "rename_tab"))
        #expect(!tool.readOnly && !tool.destructive && tool.idempotent)
        #expect(MCPServer.scopeTags["rename_tab"] == .write)
        #expect(!MCPServer.isControlTool("rename_tab"))
        #expect(MCPRemoteReach.refusal("rename_tab", ["tab_id": "x"]) != nil)
    }

    /// The tools plan 010a adds say what they do in two short sentences at most, and add nothing to the instructions.
    @Test func theNewToolsAreTwoSentencesAtMost() throws {
        for name in ["edit_host", "end_session", "rename_tab"] {
            let said = try #require(MCPServer.tool(named: name)).description
            let sentences = said.components(separatedBy: ". ").count
            #expect(sentences <= 2 && said.count <= 300, "\(name): \(said)")
            #expect(!MCPServer.instructions.contains(name), "\(name)")
        }
    }
}
