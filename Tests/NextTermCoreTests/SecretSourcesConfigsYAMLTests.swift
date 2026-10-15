import Foundation
import Testing
@testable import NextTermCore

/// YAML configs as the import reads them: Compose's `environment`, Kubernetes Secrets and env, goose's and Continue's
/// configs, and any other YAML by its paths. Everything here is made up.
@Suite struct SecretSourcesConfigsYAMLTests {
    typealias C = ConfigFixtures
    typealias F = SecretSourcesFixtures
    typealias T = SecretSourcesConfigsTests

    @Test func composesMapAndListGiveTheSameRows() {
        let map = T.read(C.composeMap, name: "compose.yaml", folder: "rag-api")
        let list = T.read(C.composeList, name: "docker-compose.yml", folder: "rag-api")
        for report in [map, list] {
            #expect(report.format == .yaml && report.unreadable == nil && report.agent == nil)
            #expect(T.names(report) == ["OPENAI_API_KEY"])
            #expect(report.rows.first?.ticked == true && report.rows.first?.note == .composeInGit)
            // `${PINECONE_API_KEY}` is a reference, and a name alone takes the shell's value: neither is a row.
            #expect(report.notKeys.map(\.name) == ["LOG_LEVEL", "PINECONE_API_KEY", "FROM_SHELL"])
            let reasons: [SecretSources.NotKeyReason] = [.setting, .builtFrom(["PINECONE_API_KEY"]), .reference]
            #expect(report.notKeys.map(\.reason) == reasons)
        }
        #expect(map.rows.first?.value == list.rows.first?.value)
        #expect(map.rows.first?.place == "services.api.environment.OPENAI_API_KEY")
        #expect(list.rows.first?.place == "services.api.environment[0]")
        #expect(SecretSources.Note.composeInGit.sentence == "Compose files are often in git")
    }

    @Test func aKubernetesSecretDecodesItsDataAndStringDataWins() throws {
        let report = T.read(C.kubernetesYAML, name: "secrets.yaml", folder: "deploy")
        #expect(report.format == .yaml && report.unreadable == nil)
        #expect(T.names(report) == ["OPENAI_API_KEY", "OPENAI_ORG_ID", "OPENAI_BINARY", "WEB_TLS", "LANGSMITH_API_KEY"])
        let openAI = try #require(T.row(report, "OPENAI_API_KEY"))
        #expect(openAI.value == SecretBytes(utf8: F.openAI) && openAI.ticked && openAI.place == "stringData.api-key")
        let org = try #require(T.row(report, "OPENAI_ORG_ID"))
        #expect(org.value == SecretBytes(utf8: "org-made-up-0000") && org.ticked && org.line == 10)
        let binary = try #require(T.row(report, "OPENAI_BINARY"))
        #expect(binary.refusal == .notText && !binary.ticked)
        #expect(SecretSources.Refusal.notText.sentence == "It doesn\u{2019}t decode to text Secrets can keep")
        let tls = try #require(T.row(report, "WEB_TLS"))
        #expect(tls.refusal == .typedSecret("TLS") && !tls.ticked)
        #expect(tls.refusal?.sentence == "A Kubernetes TLS secret; not importable yet")
        #expect(T.row(report, "LANGSMITH_API_KEY")?.ticked == true)
        #expect(report.notKeys.map(\.name) == ["PINECONE_API_KEY"])
        #expect(report.notKeys.map(\.reason) == [.reference])
    }

    @Test func goosesAndContinuesConfigsAreCopiedWithTheNote() {
        let goose = T.read(C.gooseYAML, name: "config.yaml", folder: "goose")
        #expect(goose.format == .yaml && goose.agent == "goose")
        #expect(T.names(goose) == ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        #expect(goose.rows.first?.ticked == true && goose.rows.first?.note == .stillInFile)
        #expect(goose.rows.first?.place == "extensions.github.envs.GITHUB_PERSONAL_ACCESS_TOKEN")
        let continued = T.read(C.continueYAML, name: "config.yaml", folder: ".continue")
        #expect(continued.agent == "Continue")
        #expect(T.names(continued) == ["ANTHROPIC_API_KEY", "TAVILY_API_KEY"])
        #expect(continued.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .stillInFile })
        #expect(continued.rows.first?.place == "models[0].apiKey")
        #expect(continued.notKeys.map(\.name) == ["SHARED"] && continued.notKeys.first?.reason == .reference)
    }

    @Test func anyOtherYAMLIsReadByItsPaths() throws {
        let text = ["# made up", "openai:", "  apiKey: \(F.openAI)", "  model: gpt-5", "debug: yes",
                    "private_key: |", "  \(F.privateKeyHead)", "  MIIBVQIBADANBgkqhkiG9w0BAQEFAASC",
                    "  \(F.privateKeyTail)", "shared: *anchor", ""].joined(separator: "\n")
        let report = T.read(text, name: "settings.yml")
        #expect(report.format == .yaml && report.agent == nil)
        #expect(T.names(report) == ["OPENAI_API_KEY", "PRIVATE_KEY", "SHARED"])
        #expect(T.row(report, "OPENAI_API_KEY")?.line == 3)
        #expect(T.row(report, "PRIVATE_KEY")?.refusal == .lineBreaks)
        let skipped = try #require(T.row(report, "SHARED"))
        #expect(skipped.refusal == .unreadablePart && skipped.kind == "a YAML alias" && !skipped.ticked)
        #expect(SecretSources.Refusal.unreadablePart.sentence == "Next Term can\u{2019}t read this part")
        #expect(report.notKeys.map(\.name) == ["OPENAI_MODEL", "DEBUG"])
    }

    @Test func yamlIsKnownByItsNameOrItsNestingAndRefusedWithItsLine() {
        #expect(SecretSources.detect(text: "a: b", name: "compose.yaml") == .yaml)
        #expect(SecretSources.detect(text: C.composeMap, name: "") == .yaml)
        #expect(SecretSources.detect(text: "---\nkind: Secret\n", name: "") == .yaml)
        // Flat `KEY: value` lines are a .env's as much as YAML's: read as a .env, as before.
        #expect(SecretSources.detect(text: "OPENAI_API_KEY: x\n", name: "") == .env)
        let tabbed = T.read("services:\n\tapi:\n", name: "compose.yaml")
        let failure = YAMLSubset.Failure(line: 2, reason: .tabIndent)
        #expect(tabbed.unreadable == .notYAML(failure))
        let tab = "Line 2 is indented with a tab, which YAML doesn\u{2019}t allow."
        let sentence = "It isn\u{2019}t YAML Next Term can read. " + tab
        #expect(tabbed.unreadable?.sentence == sentence)
        #expect(tabbed.unreadable?.reasonClass == "not YAML Next Term can read")
        #expect(T.read("a: b\n", name: "x.yaml", format: .toml).unreadable == .notTOML(line: 1))
    }
}
