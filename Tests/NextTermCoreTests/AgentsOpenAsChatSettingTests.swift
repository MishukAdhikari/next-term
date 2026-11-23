import Testing
@testable import NextTermCore

/// settings_set agents_open_as_chat: a list of chat agents' ids, kept sorted; anything else refused.
@Suite struct AgentsOpenAsChatSettingTests {
    private func value(_ raw: Any) -> String? {
        guard case .success(let changes) = MCPSettings.changes(["agents_open_as_chat": raw]), let change = changes.first,
              case .choice(let text) = change.1 else { return nil }
        return text
    }

    @Test func aListOfAgentsIsTakenSorted() {
        #expect(value(["codex", "claude"]) == "claude,codex")
        #expect(value(["claude", "claude"]) == "claude")
        #expect(value([String]()) == "")
        #expect(value("opencode, cursor") == "cursor,opencode")
    }

    @Test func anAgentWithNoChatOrNotAListIsRefused() {
        #expect(value(["aider"]) == nil)
        #expect(value(["claude", 3]) == nil)
        #expect(value(true) == nil)
        if case .failure(let error) = MCPSettings.changes(["agents_open_as_chat": ["nope"]]) {
            #expect(error.text.contains("a list of any of") && error.text.contains("claude"))
        } else {
            Issue.record("refused")
        }
    }

    @Test func itIsOnTheAllowlist() {
        #expect(MCPSettings.setting("agents_open_as_chat")?.kind == .ids(ChatFirst.agentIDs.sorted()))
    }
}
