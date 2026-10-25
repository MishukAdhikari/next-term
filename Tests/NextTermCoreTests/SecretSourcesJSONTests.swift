import Foundation
import Testing
@testable import NextTermCore

/// JSON and JSONC as the import reads them: flat objects, nested ones whose path names the key, name/value and
/// key/value arrays, references that only point at a key, and a whole credential file. Every value here is made up.
@Suite struct SecretSourcesJSONTests {
    typealias F = SecretSourcesFixtures

    private static func json(_ text: String, name: String = "secrets.json", stored: Set<String> = []) -> SourceReport {
        F.report(text, name: name, stored: stored)
    }

    @Test func aFlatObjectNamesEachKeyByItsMember() {
        let report = Self.json(F.dopplerJSON)
        #expect(report.format == .json)
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        #expect(report.rows.map(\.line) == [6, 7])
        #expect(report.notKeys.count == 4)
    }

    @Test func aNestedObjectsPathNamesTheKey() {
        let report = Self.json(#"{"openai":{"apiKey":"\#(F.openAI)"}}"#)
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY"])
        #expect(report.rows.first?.place == "openai.apiKey")
        let settings = Self.json(F.appSettingsJSON, name: "appsettings.json")
        #expect(settings.unreadable == nil)
        #expect(settings.rows.map(\.name) == ["OPENAI_API_KEY"])
        #expect(settings.notKeys.count == 4)
        #expect(settings.rows.first?.link?.page?.id == "openai")
    }

    @Test func numbersAndBooleansAreOtherValues() {
        let report = Self.json(#"{"debug": true, "port": 8080, "empty": null, "blank": ""}"#)
        #expect(report.rows.isEmpty)
        #expect(report.notKeys.map(\.name) == ["DEBUG", "PORT"])
        #expect(report.footer == "2 other values aren\u{2019}t keys.")
    }

    @Test func nameValueArraysNameByTheirMember() {
        let report = Self.json(#"[{"name":"STRIPE_KEY","value":"\#(F.stripeSecret)","slotSetting":false}]"#)
        #expect(report.rows.map(\.name) == ["STRIPE_KEY"])
        let keyed = Self.json(#"[{"key":"openai-api-key","value":"\#(F.openAI)"}]"#)
        #expect(keyed.rows.map(\.name) == ["OPENAI_API_KEY"])
        let ecs = Self.json(F.ecsTaskJSON, name: "task-definition.json")
        #expect(ecs.rows.map(\.name) == ["OPENAI_API_KEY"])
        #expect(ecs.rows.first?.place == "containerDefinitions[0].environment[0]")
        let pointer = ecs.notKeys.first { (notKey: SecretSources.NotKey) -> Bool in notKey.name == "PINECONE_API_KEY" }
        #expect(pointer?.reason == .reference)
        #expect(ecs.notKeys.count == 5)
    }

    @Test func kubernetesValueFromIsAReference() {
        let text = """
            {"env": [
              {"name": "OPENAI_API_KEY", "valueFrom": {"secretKeyRef": {"name": "openai", "key": "api-key"}}},
              {"name": "PINECONE_API_KEY", "value": "\(F.pinecone)"}
            ]}
            """
        let report = Self.json(text)
        #expect(report.rows.map(\.name) == ["PINECONE_API_KEY"])
        #expect(report.notKeys.map(\.name) == ["OPENAI_API_KEY"])
        #expect(report.notKeys.first?.reason == .reference)
    }

    @Test func aServiceAccountFileIsOneRefusedRow() throws {
        let report = Self.json(F.serviceAccountJSON, name: "made-up-project-0123.json")
        #expect(report.rows.count == 1)
        let row = try #require(report.rows.first)
        #expect(!row.ticked && row.refusal == .credentialFile)
        #expect(row.refusal?.sentence == "A credential file; not importable yet")
        #expect(row.value.isEmpty && row.lastFour == nil)
        #expect(report.notKeys.isEmpty)
    }

    @Test func referencesAndEncryptedValuesInJSON() {
        let text = """
            {
              "OPENAI_API_KEY": "${{ secrets.OPENAI }}",
              "STRIPE_KEY": "ENC[AES256_GCM,data:Zm9vYmFy,iv:bWFkZS11cA==,tag:dGFnLXRhZw==,type:str]",
              "GITHUB_TOKEN": "op://dev/github/credential"
            }
            """
        let report = Self.json(text)
        #expect(report.rows.map(\.name) == ["STRIPE_KEY"])
        #expect(report.rows.first?.refusal == .encryptedSops)
        #expect(report.notKeys.map(\.reason) == [.reference, .reference])
    }

    @Test func theSameNameInTwoSectionsGetsTheSectionsName() {
        let text = """
            {
              "production": {"OPENAI_API_KEY": "\(F.openAI)"},
              "staging": {"OPENAI_API_KEY": "\(F.openAIOld)"},
              "preview": {"OPENAI_API_KEY": "\(F.openAI)"}
            }
            """
        let report = Self.json(text)
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY_PRODUCTION", "OPENAI_API_KEY_STAGING"])
        // The same value twice is one row, found in both places.
        #expect(report.rows.first?.alsoAt == ["preview.OPENAI_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        let same = Self.json(#"{"a": {"OPENAI_API_KEY": "\#(F.openAI)"}, "b": {"OPENAI_API_KEY": "\#(F.openAI)"}}"#)
        #expect(same.rows.map(\.name) == ["OPENAI_API_KEY"])
    }

    @Test func aRepeatedMemberIsSetAgainAsJSONReadsIt() {
        let text = "{\n  \"OPENAI_API_KEY\": \"\(F.openAIOld)\",\n  \"OPENAI_API_KEY\": \"\(F.openAI)\"\n}"
        let report = Self.json(text)
        #expect(report.rows.map(\.ticked) == [false, true])
        #expect(report.rows.first?.note?.sentence == "Set again on line 3")
    }

    @Test func textThatIsntJSONIsUnreadableWhenNamedSo() {
        #expect(Self.json("{ not json", name: "keys.json").unreadable == .notJSON)
        // Without a JSON name, the content decides: a `.env`.
        #expect(Self.json("OPENAI_API_KEY=\(F.openAI)\n", name: "keys.txt").format == .env)
        #expect(SecretSources.detect(text: "  // c\n{\"a\": 1}", name: "x") == .json)
        #expect(SecretSources.detect(text: "[1, 2]", name: ".env") == .env)
    }
}
