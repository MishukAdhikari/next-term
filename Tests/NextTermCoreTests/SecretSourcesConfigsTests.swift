import Foundation
import Testing
@testable import NextTermCore

/// TOML configs and agents' JSON configs as the import reads them: Codex's `config.toml`, Streamlit's and Cargo's
/// secrets, and Zed's, Devin Desktop's and Claude Code's settings, which keep their keys after a copy. Everything here
/// is made up.
@Suite struct SecretSourcesConfigsTests {
    typealias C = ConfigFixtures
    typealias F = SecretSourcesFixtures

    static func read(_ text: String, name: String, folder: String? = "made-up",
                     format: SecretSources.Format? = nil) -> SourceReport {
        var bytes: [UInt8] = Array(text.utf8)
        return SecretSources.read(&bytes, name: name, folder: folder, format: format)
    }

    static func names(_ report: SourceReport) -> [String] { report.rows.map(\.name) }

    static func row(_ report: SourceReport, _ name: String) -> SourceRow? {
        report.rows.first { (row: SourceRow) -> Bool in row.name == name }
    }

    // MARK: TOML

    @Test func codexGivesItsEnvsItsShellsSetAndABearerToken() throws {
        let report = Self.read(C.codexTOML, name: "config.toml", folder: ".codex")
        #expect(report.format == .toml && report.unreadable == nil && report.agent == "Codex")
        let names = ["AZURE_OPENAI_API_KEY", "GITHUB_PERSONAL_ACCESS_TOKEN", "TAVILY_API_KEY", "OPENAI_API_KEY"]
        #expect(Self.names(report) == names)
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .stillInFile })
        let azure = try #require(Self.row(report, "AZURE_OPENAI_API_KEY"))
        #expect(azure.place == "model_providers.azure.experimental_bearer_token" && azure.line == 8)
        let github = try #require(Self.row(report, "GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(github.place == "mcp_servers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN" && github.line == 13)
        // `bearer_token_env_var` names the variable that holds a key: no row, and not counted.
        #expect(!report.rows.contains { (row: SourceRow) -> Bool in row.place.hasSuffix("bearer_token_env_var") })
        #expect(report.notKeys.map(\.name) == ["LOG_LEVEL", "PATH_EXTRA"])
        let sentence = "This file still holds the key; Next Term can\u{2019}t rewrite it yet"
        #expect(SecretSources.Note.stillInFile.sentence == sentence)
    }

    @Test func streamlitsRootKeysAreRowsAndItsSectionsNameTheirKeys() throws {
        let report = Self.read(C.streamlitTOML, name: "secrets.toml", folder: ".streamlit")
        #expect(report.format == .toml && report.unreadable == nil && report.agent == nil)
        #expect(Self.names(report) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "CONNECTIONS_POSTGRESQL_PASSWORD"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == nil })
        let pinecone = try #require(Self.row(report, "PINECONE_API_KEY"))
        #expect(pinecone.place == "pinecone.api_key" && pinecone.line == 5)
        #expect(report.notKeys.count == 4)
    }

    @Test func cargosTokensAreNamedAsCargoReadsThem() {
        let report = Self.read(C.cargoTOML, name: "credentials.toml", folder: ".cargo")
        #expect(Self.names(report) == ["CARGO_REGISTRY_TOKEN", "CARGO_REGISTRIES_MADE_UP_REGISTRY_TOKEN"])
        #expect(report.rows.allSatisfy(\.ticked) && report.agent == nil)
        // Cargo's older file has no extension: TOML by its content.
        #expect(SecretSources.detect(text: C.cargoTOML, name: "credentials") == .toml)
        #expect(Self.read(C.cargoTOML, name: "credentials").format == .toml)
    }

    @Test func tomlThatDoesntReadIsRefusedWithItsLine() {
        let report = Self.read("a = 1\nb = \n", name: "secrets.toml")
        #expect(report.format == .toml && report.unreadable == .notTOML(line: 2))
        #expect(report.unreadable?.sentence == "It isn\u{2019}t TOML Next Term can read (line 2).")
        #expect(report.unreadable?.reasonClass == "not TOML Next Term can read")
        let large = String(repeating: "# made up\n", count: TOMLReader.maxBytes / 10 + 1)
        #expect(Self.read(large, name: "big.toml").unreadable == .configTooLarge)
        let pem = F.privateKeyHead + "\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASC\n" + F.privateKeyTail
        let lines = Self.read("PRIVATE_KEY = \"\"\"\n" + pem + "\"\"\"\n", name: "a.toml")
        #expect(lines.rows.map(\.name) == ["PRIVATE_KEY"] && lines.rows.first?.refusal == .lineBreaks)
    }

    @Test func aTOMLFileIsKnownByItsNameOrItsTables() {
        #expect(SecretSources.detect(text: "A = \"b\"", name: "secrets.toml") == .toml)
        #expect(SecretSources.detect(text: "[openai]\napi_key = \"x\"\n", name: "") == .toml)
        // A .env with quotes reads as TOML too, so its name wins; an INI file's bare values don't read as TOML.
        #expect(SecretSources.detect(text: "A=\"b\"\n", name: ".env") == .env)
        #expect(SecretSources.detect(text: "[default]\nregion = us-east-1\n", name: "credentials") == .json)
    }

    // MARK: Agents' JSON

    @Test func agentConfigsInJSONAreCopiedWithTheNote() {
        let cases: [(text: String, name: String, agent: String, names: [String])] = [
            (C.zedJSON, "settings.json", "Zed", ["GITHUB_PERSONAL_ACCESS_TOKEN", "TAVILY_API_KEY", "LINEAR_API_KEY"]),
            (C.devinJSON, "mcp_config.json", "Devin Desktop", ["TAVILY_API_KEY"]),
            (C.claudeSettingsJSON, "settings.json", "Claude Code", ["ANTHROPIC_API_KEY"]),
        ]
        for item in cases {
            let report = Self.read(item.text, name: item.name)
            #expect(report.format == .json && report.unreadable == nil && report.agent == item.agent)
            #expect(Self.names(report) == item.names)
            #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .stillInFile })
        }
        let zed = Self.read(C.zedJSON, name: "settings.json")
        #expect(Self.row(zed, "TAVILY_API_KEY")?.place == "context_servers.older-shape.command.env.TAVILY_API_KEY")
        #expect(Self.row(zed, "GITHUB_PERSONAL_ACCESS_TOKEN")?.line == 9)
        // The theme, commands and arguments are an agent's settings, not counted.
        #expect(zed.notKeys.isEmpty)
        let claude = Self.read(C.claudeSettingsJSON, name: "settings.json")
        #expect(claude.notKeys.map(\.name) == ["CLAUDE_CODE_ENABLE_TELEMETRY"])
    }

    @Test func plainJSONWithAnEnvIsStillPlainJSON() {
        let report = Self.read(#"{"env": {"OPENAI_API_KEY": "\#(F.openAI)"}}"#, name: "app.json")
        #expect(report.agent == nil && Self.names(report) == ["OPENAI_API_KEY"])
        #expect(report.rows.first?.note == nil)
    }
}
