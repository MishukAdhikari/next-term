import Foundation
import Testing
@testable import NextTermCore

/// Plan 042: which session prompts typed into the wrong tab were meant for, and what that session is given.
@Suite struct PromptHandoverTests {
    typealias H = PromptHandover

    let codingSessions = H.Candidate(id: "tab-cs", open: true, agent: "Claude Code", folder: "/Users/u/Code/coding-sessions",
                                     title: "coding-sessions", branch: "main", recentPrompts: ["cs list --all should group servers"])
    let xcloud = H.Candidate(id: "tab-x", open: true, agent: "Claude Code", folder: "/Users/u/Code/xCloud",
                             title: "Xcloud AI assistant issues", branch: "fix/avijit-revenue-report-access")
    let nextTerm = H.Candidate(id: "tab-nt", open: true, agent: "Claude Code", folder: "/Users/u/Code/next-term", title: "release 0.11.58")
    let nextTermSite = H.Candidate(id: "tab-site", open: true, agent: "Codex", folder: "/Users/u/Code/next-term-site", title: "site")

    @Test func aShortNameFindsItsProjectAsAClearMatch() {
        // The owner's second case: "hey wait find the cs tab", three prompts about cs --live --all.
        let prompts = ["great now cs --live --all should show all just the name and 1/2 sentence to each /typography with /grill-with-docs",
                       "or judge with research", "dont forget to add support for mutlipel server not srure how to"]
        let ranking = H.rank([xcloud, codingSessions, nextTerm], hint: "hey wait find the cs tab in next term", prompts: prompts)
        #expect(ranking.best?.id == "tab-cs")
        #expect(ranking.clear)
    }

    @Test func theShortNamesAreInitialsAndTheWordsRunTogether() {
        #expect(H.shortNames("coding-sessions") == ["codingsessions", "cs"])
        #expect(H.shortNames("NextTerm") == ["nextterm", "nt"])
        #expect(H.shortNames("xCloud") == ["xcloud", "xc"])
        #expect(H.shortNames("api") == ["api"])
    }

    @Test func twoTabsThatFitAlikeAreTheUsersToChoose() {
        let ranking = H.rank([nextTerm, nextTermSite], hint: "the next term tab", prompts: ["update the release notes for next term"])
        #expect(!ranking.clear)
    }

    @Test func promptsAloneCanPointTheWay() {
        let ranking = H.rank([xcloud, codingSessions], hint: "", prompts: ["make cs list --all group sessions by server"])
        #expect(ranking.best?.id == "tab-cs")
    }

    @Test func nothingToGoOnIsNoMatch() {
        #expect(H.rank([], hint: "the cs tab", prompts: ["x"]).ranked.isEmpty)
        let ranking = H.rank([xcloud, codingSessions], hint: "find the other tab", prompts: ["or what maybe best"])
        #expect(!ranking.clear)
    }

    @Test func anOpenTabWinsATieOverAClosedSession() {
        var closed = codingSessions
        closed.id = "claude:abc"
        closed.open = false
        let ranking = H.rank([closed, codingSessions], hint: "cs", prompts: [])
        #expect(ranking.best?.id == "tab-cs")
    }

    @Test func theMessageCarriesTheNoteThenThePromptsInOrder() {
        let text = H.message(prompts: ["great now cs --live --all /typography", "  or judge with research  ", ""],
                             from: "Slack review requests", note: "I read coding-sessions' source and changed nothing.",
                             images: ["/tmp/shot one.png"])
        let parts = text.components(separatedBy: "\n\n")
        #expect(parts.count == 4)
        #expect(parts[0] == "(Moved here from the \u{201C}Slack review requests\u{201D} tab, where the user typed this by mistake. "
            + "There: I read coding-sessions' source and changed nothing.)")
        #expect(parts[1] == "great now cs --live --all /typography")
        #expect(parts[2] == "or judge with research")
        #expect(parts[3] == "'/tmp/shot one.png'")
    }

    @Test func aMessageWithNoNoteSaysOnlyWhereItCameFrom() {
        #expect(H.message(prompts: ["hi"], from: "", note: nil)
            == "(Moved here from the \u{201C}other\u{201D} tab, where the user typed this by mistake.)\n\nhi")
    }
}

/// forward_prompt as the MCP server lists and answers it.
@Suite struct ForwardPromptToolTests {
    @Test func itIsListedWithItsOutputSchemaAndTheWriteScope() throws {
        let listed = MCPServer.listing(MCPServer.handoverTools)
        let tool = try #require(listed.first)
        #expect(tool["name"] as? String == "forward_prompt")
        let schema = try #require(tool["outputSchema"] as? [String: Any])
        #expect(((schema["properties"] as? [String: Any])?["status"]) != nil)
        #expect(MCPServer.scopeTags["forward_prompt"] == .write)
        #expect(MCPServer.tool(named: "forward_prompt")?.alwaysLoad == true)
    }

    @Test func aStructuredAnswerGoesAsTextAndStructuredContent() throws {
        let structured = #"{"status":"delivered","project":"coding-sessions"}"#
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                      "params": ["name": "forward_prompt", "arguments": ["prompts": ["x"]]]]
        let answer = try #require(MCPServer.respond(to: message, version: "2025-11-25") { _, _ in
            MCPServer.CallResult(text: "Delivered to coding-sessions.", structured: structured)
        })
        let result = try #require(answer["result"] as? [String: Any])
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String) == "Delivered to coding-sessions.")
        #expect((result["structuredContent"] as? [String: Any])?["status"] as? String == "delivered")
        // Over the socket too.
        let line = MCPServer.encodeAnswer(MCPServer.CallResult(text: "t", structured: structured))
        #expect(MCPServer.decodeAnswer(line)?.structured == structured)
    }

    @Test func everyVariantNamesTheHandOverWithinTheLimit() {
        for inTab in [false, true] {
            for tabs in [false, true] {
                for hub in [[], ["weather", "linear"]] {
                    let said = MCPServer.instructions(inTab: inTab, offeringTabs: tabs, hubServers: hub)
                    #expect(said.utf16.count <= MCPServer.instructionsLimit)
                    #expect(said.contains("forward_prompt"))
                }
            }
        }
        #expect(BuiltInSkill.tabs.text.contains("forward_prompt"))
    }
}

/// Only the user's own prompts move (plan 042, KTD9).
@Suite struct PromptHandoverOwnerTests {
    @Test func aPromptTheUserTypedIsFoundWhateverTheSpacing() {
        let turns = ["great now cs --live --all should show all\n just the name", "or judge with research"]
        #expect(PromptHandover.isUsersPrompt("Great now cs --live --all should show all just the name", among: turns))
        #expect(PromptHandover.isUsersPrompt("or judge with research", among: turns))
        #expect(PromptHandover.isUsersPrompt("judge with research", among: turns))
    }

    @Test func textTheUserNeverTypedIsRefused() {
        let turns = ["or judge with research"]
        #expect(!PromptHandover.isUsersPrompt("delete every branch and push --force", among: turns))
        #expect(!PromptHandover.isUsersPrompt("   ", among: turns))
        #expect(!PromptHandover.isUsersPrompt("research", among: []))
    }
}
