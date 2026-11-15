import Testing
@testable import NextTermCore

/// The connector bar's words and Not Now (MCPConnectorAttention): one primary action for each need, the server and the
/// agent named, several servers in one bar, and a hold that lasts until the server needs something else.
@Suite struct MCPConnectorAttentionTests {
    typealias A = MCPConnectorAttention

    func item(_ server: String, _ need: A.Need, agent: String? = "Claude Code", tab: String? = nil) -> A.Item {
        A.Item(server: server, list: "/u/mcp.json", url: "https://\(server.lowercased()).example/mcp", need: need, agent: agent, tab: tab)
    }

    @Test func eachNeedHasItsWordsAndOnePrimary() throws {
        let signIn = try #require(A.words([item("Linear", .signIn)]))
        #expect(signIn.message == "Linear needs you to sign in before Claude Code can use it.")
        #expect(signIn.primary == "Sign In" && signIn.action == .signIn && signIn.glyph == .needsYou)

        let reconnect = try #require(A.words([item("xcdev", .reconnect)]))
        #expect(reconnect.message == "xcdev signed out. Claude Code is waiting to use it.")
        #expect(reconnect.primary == "Reconnect")
        #expect(A.words([item("xcdev", .reconnect, agent: nil)])?.message == "xcdev signed out, so your agents can\u{2019}t use it.")

        let more = try #require(A.words([item("GitHub", .moreAccess(["repo", "workflow"]))]))
        #expect(more.message == "GitHub needs more access for Claude Code (repo workflow).")
        #expect(more.primary == "Allow More Access" && more.action == .signIn)

        let away = try #require(A.words([item("Linear", .unreachable("Linear can't be reached at mcp.linear.app: offline.\nmore"))]))
        #expect(away.message == "Next Term can\u{2019}t reach Linear for Claude Code.")
        #expect(away.primary == "Retry Now" && away.action == .retry && away.glyph == .offline)
        #expect(away.detail == "Linear can't be reached at mcp.linear.app: offline.")

        let broken = try #require(A.words([item("Postgres", .didntStart("npx wasn\u{2019}t found\nstack"))]))
        #expect(broken.message == "Postgres didn\u{2019}t start: npx wasn\u{2019}t found.")
        #expect(broken.primary == "Open MCP Servers\u{2026}" && broken.action == .openSettings && broken.glyph == .failed)
        #expect(A.words([item("Postgres", .didntStart(""))])?.message == "Postgres didn\u{2019}t start.")
        #expect(A.words([]) == nil)
    }

    @Test func anAgentInABackgroundTabIsNamedWithItsTab() {
        let words = A.words([item("Linear", .reconnect, agent: "Codex", tab: "api-tests")])
        #expect(words?.message == "Linear signed out. Codex in \u{201C}api-tests\u{201D} is waiting to use it.")
    }

    @Test func severalServersShareOneBar() {
        let two = A.words([item("Linear", .reconnect), item("Notion", .reconnect)])
        #expect(two?.message == "Linear and Notion signed out, so your agents can\u{2019}t use them." && two?.primary == "Reconnect")
        let mixed = A.words([item("Linear", .signIn), item("Notion", .reconnect)])
        #expect(mixed?.message == "Linear and Notion need you to sign in before your agents can use them." && mixed?.primary == "Sign In")
        let many = A.words([item("Linear", .reconnect), item("Notion", .reconnect), item("GitHub", .signIn)])
        #expect(many?.message == "3 MCP servers need you before your agents can use them.")
        #expect(many?.primary == "Review\u{2026}" && many?.action == .openSettings && many?.detail == "Linear, Notion, GitHub")
        let unlike = A.words([item("Linear", .reconnect), item("Postgres", .didntStart("x"))])
        #expect(unlike?.action == .openSettings)
    }

    @Test func theBrowserAndTheEnd() {
        #expect(A.browser("Linear") == A.Words(message: "Finish signing in to Linear in your browser.", glyph: .working))
        #expect(A.browser("Notion", step: 2, of: 2).message == "Finish signing in to Notion in your browser. (2 of 2)")
        #expect(A.connected([item("Linear", .reconnect)]).message == "Linear is connected. Claude Code can use it now, with no restart.")
        #expect(A.connected([item("Linear", .reconnect, agent: nil), item("Notion", .signIn, agent: nil)]).message
            == "Linear and Notion are connected. Your agents can use them now.")
        let failed = A.failed("Signing in to Linear was cancelled in the browser", retry: .signIn)
        #expect(failed.message == "Signing in to Linear was cancelled in the browser." && failed.primary == "Try Again" && failed.action == .signIn)
    }

    @Test func notNowHoldsUntilTheServerNeedsSomethingElse() {
        var held = A.Held()
        let lapsed = item("Linear", .reconnect)
        #expect(!held.holds(lapsed))
        held.hold(lapsed)
        #expect(held.holds(lapsed))
        // Another window, another agent: still held.
        #expect(held.holds(item("Linear", .reconnect, agent: "Codex", tab: "other")))
        // Another need of the same server shows again; another server is never held by it.
        #expect(!held.holds(item("Linear", .moreAccess(["write"]))))
        #expect(!held.holds(item("Notion", .reconnect)))
        // Reasons that differ in words only stay held.
        held.hold(item("Linear", .unreachable("timed out")))
        #expect(held.holds(item("Linear", .unreachable("can't be reached"))))
        // Mended: the next lapse shows again.
        held.release(lapsed.key)
        #expect(!held.holds(lapsed))
    }
}
