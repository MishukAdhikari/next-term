import Foundation
import Testing
@testable import NextTermCore

/// Settings' states for a server at a URL Next Term signs in to, and the sentences an agent is told.
struct MCPHubSignInStatesTests {
    // MARK: Settings' states

    func row(_ run: MCPHubOverview.Run?, _ signIn: MCPHubOverview.SignIn?) -> MCPHubOverview.State {
        let server = MCPHubServer.remote("linear", url: "https://mcp.linear.app/mcp")
        let runs = run.map { [MCPHubOverview.runKey(list: "/l", server: "linear"): $0] } ?? [:]
        let signIns = signIn.map { [MCPHubOverview.signInKey("HTTPS://mcp.linear.app/mcp"): $0] } ?? [:]
        return MCPHubOverview.ran(server, "/l", runs, signIns)
    }

    @Test func aServerAtAURLShowsItsSignIn() {
        #expect(row(nil, nil) == .ready(tools: nil))
        #expect(row(.init(failure: "x", tools: 0, needsSignIn: true), nil) == .needsSignIn)
        #expect(row(.init(failure: "x", tools: 0, needsSignIn: true), .signedIn) == .signedIn(tools: nil))
        #expect(row(.init(failure: nil, tools: 12), .signedIn) == .signedIn(tools: 12))
        #expect(row(.init(failure: "boom", tools: 0), .signedIn) == .failed("boom"))
        #expect(row(.init(failure: nil, tools: 12), .signedOut) == .signedOut)
        #expect(row(nil, .needsMoreAccess(["files:write"])) == .needsMoreAccess(["files:write"]))
        #expect(MCPHubOverview.SignIn(.refreshing(spent: "x")) == .signedIn)

        #expect(MCPHubOverview.stateText(.needsSignIn) == "Needs sign-in")
        #expect(MCPHubOverview.stateText(.signedIn(tools: 12)) == "Signed in \u{00B7} 12 tools")
        #expect(MCPHubOverview.stateText(.signedOut) == "Signed out")
        #expect(MCPHubOverview.stateText(.needsMoreAccess([])) == "Needs more access")
        #expect(MCPHubOverview.stateTip(.signedIn(tools: nil)).contains("never get the sign-in"))
        #expect(MCPServer.stateFields(.signedOut)["state"] as? String == "signed_out")
    }

    // MARK: words

    @Test func theAgentsSentencesSendItToTheUser() {
        #expect(MCPHubSignInWords.needsSignIn("Linear")
            == "Linear needs a sign-in. Ask the user to sign in to Linear in Next Term \u{203A} Settings \u{203A} MCP Servers; Next Term then keeps it signed in for every agent. Nothing was sent.")
        #expect(MCPHubSignInWords.lapsed("Linear").hasPrefix("Linear\u{2019}s sign-in in Next Term has lapsed, so nothing was sent. Ask the user to choose Reconnect"))
        #expect(MCPHubSignInWords.moreAccess("Linear", scopes: ["files:write"]).hasPrefix("Linear needs more access for this (files:write)."))
        #expect(MCPHubSignInWords.declined(agent: "Codex", "Linear") == "The user didn\u{2019}t allow Codex to use their Linear sign-in, so nothing was sent.")
        let panel = MCPHubSignInWords.consent(agent: "Codex", "Linear")
        #expect(panel.title == "Codex wants to use your Linear sign-in")
        #expect(panel.details.hasSuffix("Next Term asks once for each agent."))
        #expect(MCPHubSignInWords.notice("Linear") == ("Linear signed out", "Reconnect in Next Term so your agents can use it."))
        #expect(MCPHubSignInWords.agentKey(program: "claude") == "claude" && MCPHubSignInWords.agentKey(program: "codex") == "codex")
        #expect(MCPHubSignInWords.agentKey(program: "command-code") == "commandcode")
        #expect(MCPHubSignInWords.usedBy(["claude", "codex", "commandcode"]) == "Used by Claude Code, Codex, Command Code")
        #expect(MCPHubSignInWords.usedBy([]) == nil)
        // A token Next Term signed in for, refused at the server: a Reconnect, never "check the key".
        let refused = MCPHubRemote(name: "Linear", clientVersion: "1").unauthorized(401, challenge: nil, keyed: false, signedIn: true)
        #expect(refused.text.contains("refused Next Term\u{2019}s sign-in (HTTP 401)") && refused.text.contains("Reconnect"))
    }
}
