import Foundation

/// What a sign-in says, in one place: the sentences an agent is told when a need of a signed-in server can't be met
/// (the `isError` text of mcp_call and the direct tools), the notice for a lapse, and the R15 panel. An agent is never
/// told to sign in itself, and never starts one: it asks the user to, in Next Term.
public enum MCPHubSignInWords {
    static let settings = "Next Term \u{203A} Settings \u{203A} MCP Servers"

    /// The server asked for a sign-in Next Term doesn't have.
    public static func needsSignIn(_ name: String) -> String {
        "\(name) needs a sign-in. Ask the user to sign in to \(name) in \(settings); Next Term then keeps it signed in for every agent. Nothing was sent."
    }

    /// The sign-in lapsed: refused at the server, or its refresh token spent.
    public static func lapsed(_ name: String) -> String {
        "\(name)\u{2019}s sign-in in Next Term has lapsed, so nothing was sent. Ask the user to choose Reconnect for \(name) in \(settings) "
            + "(Next Term has shown them a notice), then call again."
    }

    /// The server asked for more access than the sign-in has.
    public static func moreAccess(_ name: String, scopes: [String]) -> String {
        let named = scopes.isEmpty ? "" : " (\(scopes.joined(separator: " ")))"
        return "\(name) needs more access for this\(named). Ask the user to choose Reconnect for \(name) in \(settings), then call again."
    }

    /// The user chose Don't Allow for this agent.
    public static func declined(agent: String, _ name: String) -> String {
        "The user didn\u{2019}t allow \(agent) to use their \(name) sign-in, so nothing was sent."
    }

    /// The caller isn't an agent in one of this Mac's tabs, so it can't be asked about.
    public static func notAnAgent(_ name: String) -> String {
        "Next Term uses its sign-in to \(name) only for an agent in one of this Mac\u{2019}s tabs."
    }

    /// The panel is up and the call stopped waiting for it.
    public static func asking(agent: String, _ name: String) -> String {
        "Next Term is asking the user on the Mac to let \(agent) use their \(name) sign-in. Call again once they have answered."
    }

    /// The sign-ins were changed outside Next Term (SignInFile's MAC), so every one reads as signed out.
    public static func tampered(_ name: String) -> String {
        "Next Term\u{2019}s sign-ins were changed outside Next Term, so it doesn\u{2019}t use them, and nothing was sent to \(name). "
            + "Ask the user to choose Reconnect for \(name) in \(settings)."
    }

    /// The sign-in server couldn't be reached for a refresh, and nothing was spent.
    public static func unreachable(_ name: String) -> String {
        "Next Term couldn\u{2019}t reach \(name)\u{2019}s sign-in server; try again in a moment."
    }

    /// The user didn't let Next Term open its sign-ins (Touch ID cancelled).
    public static func notUnlocked(_ name: String) -> String {
        "The user didn\u{2019}t let Next Term use its sign-ins just now, so nothing was sent to \(name). Call again to be asked again."
    }

    /// `text` with each of a need's sign-in tokens hidden, as written and as JSON writes it (`/` as `\/`), should a
    /// server quote one back: for what the agent is told, Settings' line, and the cached tool list.
    public static func hiding(_ tokens: [String], in text: String) -> String {
        tokens.reduce(text) { text, token in
            guard !token.isEmpty else { return text }
            let escaped = token.replacingOccurrences(of: "/", with: "\\/")
            return text.replacingOccurrences(of: token, with: "\u{2022}\u{2022}\u{2022}")
                .replacingOccurrences(of: escaped, with: "\u{2022}\u{2022}\u{2022}")
        }
    }

    // MARK: the user's

    /// The notice for a lapse: one for each, never a modal.
    public static func notice(_ name: String) -> (title: String, body: String) {
        ("\(name) signed out", "Reconnect in Next Term so your agents can use it.")
    }

    /// The R15 panel: who wants which sign-in, and what Allow means. Allow is its one primary.
    public static func consent(agent: String, _ name: String) -> (title: String, details: String) {
        ("\(agent) wants to use your \(name) sign-in",
         "\(agent) can then use \(name)\u{2019}s tools as you, in every project where \(name) applies. Next Term asks once for each agent.")
    }

    /// Settings' line while the browser is out.
    public static func finishing(_ name: String, at host: String?) -> String {
        "Finish signing in to \(name) in your browser" + (host.map { " (\($0))" } ?? "") + "."
    }

    /// The agents allowed, as Settings' detail lists them: "Used by Claude Code, Codex".
    public static func usedBy(_ agents: [String]) -> String? {
        agents.isEmpty ? nil : "Used by " + agents.map(agentTitle).joined(separator: ", ")
    }

    /// Who "an agent" is for R15: the agent kind the caller's tab runs, lowercased (`claude`, `codex`), or for an agent
    /// outside the known kinds its name as Next Term knows it. Any program named like that agent counts as it (D5).
    public static func agentKey(program: String) -> String {
        AgentKind(program: program)?.rawValue.lowercased() ?? AgentName.of(program: program).lowercased()
    }

    /// An agent's name as the user knows it, from its lowercased key.
    public static func agentTitle(_ key: String) -> String {
        AgentKind.allCases.first { $0.rawValue.lowercased() == key }?.name ?? key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Revoking at the server isn't possible (GitHub has no revocation endpoint): the user ends it there.
    public static func revokeByHand(_ name: String, host: String) -> String {
        "Signed out of \(name) in Next Term. To end \(host)\u{2019}s access too, remove Next Term in \(host)\u{2019}s settings for authorized apps."
    }
}
