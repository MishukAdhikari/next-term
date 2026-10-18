import Foundation
import Testing
@testable import NextTermCore

/// The names configs give their keys when the file doesn't name them: a Codex provider with no usable `env_key`, a
/// Continue model with no provider, an HTTP server's token. Everything here is made up.
@Suite struct SecretSourcesConfigsNamesTests {
    typealias C = ConfigFixtures
    typealias E = ExportFixtures
    typealias T = SecretSourcesConfigsTests

    @Test func aCodexProviderWithNoUsableEnvKeyIsNamedByItself() {
        let other: String = String(C.azure.reversed())
        let text: String = [
            "[model_providers.made-up]", "name = \"Made up\"", "experimental_bearer_token = \"\(C.azure)\"", "",
            "[model_providers.other]", "env_key = \"not a name!\"", "experimental_bearer_token = \"\(other)\"", "",
            "[mcp_servers.remote]", "url = \"https://mcp.example.invalid/mcp\"",
            "http_headers = { Authorization = \"Bearer \(C.github)\" }", "",
        ].joined(separator: "\n")
        let report = T.read(text, name: "config.toml", folder: ".codex")
        #expect(report.agent == "Codex")
        #expect(T.names(report) == ["MADE_UP_API_KEY", "OTHER_API_KEY", "REMOTE_TOKEN"])
        #expect(T.row(report, "REMOTE_TOKEN")?.value == SecretBytes(utf8: C.github))
        #expect(T.row(report, "REMOTE_TOKEN")?.place == "mcp_servers.remote.http_headers.Authorization")
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in !row.fromTitle })
    }

    @Test func aContinueModelWithNoProviderIsNamedByItsNameAndSaysAgentsSeeIt() {
        let text: String = [
            "models:", "  - name: Claude", "    provider: anthropic", "    apiKey: \(E.anthropic)",
            "  - name: Team Gateway", "    model: made-up", "    apiKey: \(E.linear)", "",
        ].joined(separator: "\n")
        let report = T.read(text, name: "config.yaml", folder: ".continue")
        #expect(report.agent == "Continue")
        #expect(T.names(report) == ["ANTHROPIC_API_KEY", "TEAM_GATEWAY_API_KEY"])
        #expect(T.row(report, "ANTHROPIC_API_KEY")?.fromTitle == false)
        #expect(T.row(report, "TEAM_GATEWAY_API_KEY")?.fromTitle == true)
    }
}
