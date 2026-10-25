import Foundation
import Testing
@testable import NextTermCore

/// How a config is told for an agent's or Compose's, and what the rest of it gives: a shape is known by members only it
/// has, every value outside the places its reader knows is read as any file's are, and a whole file's note stays on the
/// report when a row's own note takes its place. Everything here is made up.
@Suite struct SecretSourcesConfigsShapeTests {
    typealias C = ConfigFixtures
    typealias E = ExportFixtures
    typealias F = SecretSourcesFixtures
    typealias T = SecretSourcesConfigsTests

    @Test func jsonWithAModelAndAnEnvIsPlainJSON() {
        let text = #"{"model":"gpt-5","env":{"LOG_LEVEL":"debug"},"openai":{"apiKey":"\#(F.openAI)"}}"#
        let report = T.read(text, name: "app.json")
        #expect(report.agent == nil && report.fileNote == nil)
        #expect(T.names(report) == ["OPENAI_API_KEY"] && report.rows.first?.ticked == true)
        #expect(report.notKeys.map(\.name).contains("LOG_LEVEL"))
    }

    @Test func anAgentsConfigGivesItsOtherKeysToo() throws {
        let claude = T.read(#"""
            {"permissions": {"allow": []}, "env": {"ANTHROPIC_API_KEY": "\#(E.anthropic)"},
             "openai": {"apiKey": "\#(F.openAI)"}}
            """#, name: "settings.local.json")
        #expect(claude.agent == "Claude Code" && claude.fileNote == .stillInFile)
        #expect(T.names(claude) == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
        #expect(claude.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .stillInFile })
        let remote = #"{"url": "https://mcp.example.invalid/mcp", "headers": "#
            + #"{"Authorization": "Bearer \#(C.github)", "X-Api-Key": "\#(E.linear)"}}"#
        let devin = T.read(#"{"mcpServers": {"remote": \#(remote)}, "openai": {"apiKey": "\#(F.openAI)"}}"#,
                           name: "mcp_config.json")
        #expect(devin.agent == "Devin Desktop")
        #expect(T.names(devin) == ["REMOTE_TOKEN", "X_API_KEY", "OPENAI_API_KEY"])
        let token = try #require(T.row(devin, "REMOTE_TOKEN"))
        #expect(token.value == SecretBytes(utf8: C.github) && token.ticked)
        #expect(token.place == "mcpServers.remote.headers.Authorization")
        // A member named `mcpServers` that holds no server is any JSON's.
        let plain = T.read(#"{"mcpServers": {"enabled": true}, "token": "\#(C.github)"}"#, name: "mcp_config.json")
        #expect(plain.agent == nil && T.names(plain) == ["TOKEN"])
    }

    @Test func yamlThatOnlyLooksLikeComposeOrContinueIsReadByItsPaths() {
        let services = T.read("services:\n  stripe:\n    secret_key: \(F.stripeSecret)\n", name: "app.yaml")
        #expect(services.agent == nil && services.fileNote == nil)
        #expect(T.names(services) == ["SERVICES_STRIPE_SECRET_KEY"] && services.rows.first?.note == nil)
        let models = T.read("models:\n  - name: local\n    path: /made-up/model\napi_token: \(C.github)\n",
                            name: "app.yaml")
        #expect(models.agent == nil && T.names(models) == ["API_TOKEN"])
        #expect(models.notKeys.count == 2)
    }

    @Test func composeAnchorsGiveTheirKeysOnce() {
        let text: String = [
            "x-env: &env", "  OPENAI_API_KEY: \(F.openAI)", "  LOG_LEVEL: info",
            "x-common: &common", "  image: example.invalid/worker:1", "  environment:",
            "    PINECONE_API_KEY: \(F.pinecone)",
            "services:", "  api:", "    image: example.invalid/rag-api:1.4", "    environment: *env",
            "  worker:", "    <<: *common",
            "  web:", "    image: example.invalid/web:1", "    environment:", "      <<: *env",
            "      LANGSMITH_API_KEY: \(F.langSmith)", "",
        ].joined(separator: "\n")
        let report = T.read(text, name: "compose.yaml")
        #expect(report.unreadable == nil && report.fileNote == .composeInGit)
        #expect(T.names(report) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .composeInGit })
        #expect(T.row(report, "OPENAI_API_KEY")?.place == "x-env.OPENAI_API_KEY")
        #expect(report.notKeys.map(\.name).contains("LOG_LEVEL"))
    }

    @Test func aListOfKubernetesSecretsGivesEachOnesKeys() {
        let text: String = [
            "apiVersion: v1", "kind: List", "items:",
            "  - apiVersion: v1", "    kind: Secret", "    metadata:", "      name: openai",
            "    data:", "      api-key: \(C.base64(F.openAI))",
            "  - apiVersion: v1", "    kind: Secret", "    metadata:", "      name: pinecone",
            "    stringData:", "      api-key: \(F.pinecone)",
            "metadata:", "  resourceVersion: \"\"", "",
        ].joined(separator: "\n")
        let report = T.read(text, name: "secrets.yaml")
        #expect(T.names(report) == ["OPENAI_API_KEY", "PINECONE_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
    }

    @Test func theFilesNoteStaysWhenARowsOwnTakesItsPlace() {
        var bytes: [UInt8] = Array(C.zedJSON.utf8)
        let report = SecretSources.read(&bytes, name: "settings.json", stored: ["TAVILY_API_KEY"])
        #expect(report.agent == "Zed" && report.fileNote == .stillInFile)
        #expect(T.row(report, "TAVILY_API_KEY")?.note == .replaces)
        #expect(T.row(report, "LINEAR_API_KEY")?.note == .stillInFile)
        #expect(T.read(C.composeList, name: "compose.yaml").fileNote == .composeInGit)
        #expect(T.read(C.streamlitTOML, name: "secrets.toml").fileNote == nil)
    }
}
