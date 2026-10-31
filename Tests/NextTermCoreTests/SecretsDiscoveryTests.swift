import Foundation
import Testing
@testable import NextTermCore

/// Agents look in Secrets first when something needs a key (2026-10-31: Codex, connecting an MCP server that wanted a
/// bearer token, grepped ~/.zshrc and told the user to export it, though Secrets held it). Every agent's first line of
/// the MCP instructions says where keys are and when to look; the secret tools say it in the words agents search for;
/// and every recipe keeps the value out of command lines and pins its packages.
@Suite struct SecretsDiscoveryTests {
    /// Codex shows a deferred server as its first line, cut at 250 characters: that line is Secrets', whole, in every
    /// variant, with "call list_secrets" in its first hundred characters.
    @Test func everyAgentsFirstLineSaysWhereKeysAreAndWhenToLook() {
        for inTab in [false, true] {
            for offering in [false, true] {
                let said = MCPServer.instructions(inTab: inTab, offeringTabs: offering)
                let first = said.components(separatedBy: "\n")[0]
                #expect(first == MCPServer.secretsLead, "in a tab: \(inTab), offering tabs: \(offering)")
                #expect(first.count <= 247)
            }
        }
        let lead = MCPServer.secretsLead
        let call: Range<String.Index>? = lead.range(of: "call list_secrets first")
        #expect(call.map { (found: Range<String.Index>) -> Bool in lead.distance(from: lead.startIndex, to: found.upperBound) <= 100 } == true)
        for words in ["API keys, tokens and passwords", "MCP server", "shell profiles", ".env files", "asking the user"] {
            #expect(lead.contains(words), "\(words)")
        }
        // Outside a tab, Next Term is named on the second line; in a tab, the skills paragraph says where the agent runs.
        #expect(MCPServer.instructions.contains("\nNext Term is the terminal and editor this agent may run in. list_tabs"))
        // How keys are used ends every variant, and a login prompt goes to run_command, not Secrets.
        #expect(MCPServer.secretsUse.contains("no tool returns a key's value") && MCPServer.secretsUse.contains("a password prompt: run_command"))
        #expect(MCPServer.secretsUse.contains("request_secret, not the chat"))
    }

    /// list_secrets carries the trigger in the words an agent thinks in, first, where OpenCode's 120 and Qwen's 160
    /// characters of a tool line reach, and both MCP server forms at its end.
    @Test func listSecretsSaysWhenAndHow() throws {
        let tool = try #require(MCPServer.tool(named: "list_secrets"))
        #expect(tool.title.contains("API keys, tokens and passwords"))
        let said = tool.description
        #expect(said.hasPrefix("The user's API keys, tokens and passwords"))
        let head = String(said.prefix(120))
        #expect(head.contains("API keys, tokens and passwords") && head.contains("Call it first"))
        for words in ["before reading shell profiles", "asking the user", "token", "password", "bearer token",
                      "nxtrm secret run NAME=ENVNAME -- command", "NXTRM_NAME", MCPServer.mcpRemote,
                      "'Authorization: Bearer ${NXTRM_NAME}'", "get_skill next-term-secrets"] {
            #expect(said.contains(words), "\(words)")
        }
        #expect(said.utf16.count <= 2_048)
    }

    @Test func theOtherSecretToolsPointAtTheRightOne() throws {
        let run = try #require(MCPServer.tool(named: "run_with_secrets")).description
        #expect(run.contains("stored API keys, tokens or passwords (names from list_secrets)"))
        #expect(run.contains("Not for a program another app starts later, such as an MCP server in an agent's config"))
        let request = try #require(MCPServer.tool(named: "request_secret")).description
        #expect(request.contains("API key, token or password") && request.contains("in place of asking in the chat"))
        let store = try #require(MCPServer.tool(named: "store_secret")).description
        #expect(store.contains("one the user pasted into the chat anyway"))
        for name in ["list_secrets", "request_secret", "store_secret", "run_with_secrets"] {
            #expect((MCPServer.tool(named: name)?.description.utf16.count ?? 0) <= 2_048, "\(name)")
        }
    }

    /// The note with each list_secrets answer: both forms and the skill when keys are listed; the user's own setup and an
    /// offer when nothing is stored, so an agent of someone who keeps keys elsewhere isn't sent on a detour.
    @Test func theAnswersNotesSayHowToUseAKeyOrWhatToDoWithout() {
        let note = MCPServer.secretsListNote
        for words in ["Values are never returned", "run_with_secrets", "nxtrm secret run NAME=ENVNAME -- command",
                      "a name only the wrapper sets", "nxtrm secret run NAME=NXTRM_NAME", MCPServer.mcpRemote,
                      "request_secret", "get_skill next-term-secrets"] {
            #expect(note.contains(words), "\(words)")
        }
        let none = MCPServer.secretsNoneNote
        #expect(none.contains("Nothing is stored") && none.contains("the user's own setup") && none.contains("never into the chat"))
    }

    /// The recipes agents copy: the key under a name only the wrapper sets (an agent's own ${…} fills leave it alone, so
    /// no value lands in a command line), and no package Next Term's approval panel would warn about as unpinned.
    @Test func theRecipesKeepValuesOutOfCommandLinesAndPinTheirPackages() {
        #expect(MCPServer.wrapperPrefix == "NXTRM_")
        #expect(!SecretVault.refusedEnvPrefixes.contains { "NXTRM_API_TOKEN".hasPrefix($0) })
        let url = ["npx", "-y", MCPServer.mcpRemote, "https://mcp.example.com/mcp", "--header", "Authorization: Bearer ${NXTRM_API_TOKEN}"]
        let local = ["docker", "run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server"]
        #expect(SecretRun.warnings(argv: url).isEmpty, "\(SecretRun.warnings(argv: url))")
        #expect(SecretRun.warnings(argv: local).isEmpty, "\(SecretRun.warnings(argv: local))")
        // The help gives the same forms, for both agents' add commands.
        let help = SecretRun.help
        for words in ["NXTRM_API_TOKEN", MCPServer.mcpRemote, "'Authorization: Bearer ${NXTRM_API_TOKEN}'",
                      "codex mcp add docs -- nxtrm secret run", "claude mcp add docs -- nxtrm secret run",
                      "ghcr.io/github/github-mcp-server", "Pin each package to a version", "never set or export them"] {
            #expect(help.contains(words), "\(words)")
        }
        #expect(!help.contains("server-github\n"))
        // nxtrm --help names the wrapper, so an agent that finds nxtrm on PATH learns of it.
        #expect(CommandLineOpen.usage.contains("nxtrm secret run NAME -- command") && CommandLineOpen.usage.contains("nxtrm secret help"))
    }

    /// The skill tools name next-term-secrets, so an agent outside a tab, which gets no skills paragraph, still finds it.
    @Test func theSkillToolsNameTheSecretsSkill() throws {
        let list = try #require(MCPServer.tool(named: "list_skills")).description
        let get = try #require(MCPServer.tool(named: "get_skill")).description
        #expect(list.contains("next-term-secrets: using the user's keys by name"))
        #expect(get.contains("next-term-secrets when something needs an API key, token or password"))
        #expect(BuiltInSkill.named("next-term-secrets") == BuiltInSkill.secrets)
    }
}
