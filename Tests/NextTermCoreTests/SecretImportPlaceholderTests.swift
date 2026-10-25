import Foundation
import Testing
@testable import NextTermCore

/// What the MCP-config import skips besides references: a placeholder a README told the user to fill in, and a value
/// sops or dotenvx encrypted, which the server decrypts itself. And the grouping by value both imports share. No value
/// here is a real key.
@Suite struct SecretImportPlaceholderTests {
    typealias F = SecretImportFixtures

    @Test func placeholdersAreNotKeys() {
        let placeholders = ["your-openai-api-key-here", "YOUR_GITHUB_TOKEN_GOES_HERE", "<your-key-from-the-dashboard>",
                            "sk-" + "proj-xxxxxxxxxxxxxxxxxxxx", "ghp_" + "XXXXXXXXXXXXXXXXXXXXXXXX",
                            "change-me-before-deploy", "replace_me", "sk-" + "proj-...", "sk-" + "ant-…"]
        for value in placeholders {
            #expect(SecretImport.isPlaceholder(value), "\(value)")
            #expect(SecretImport.detect(name: "API_KEY", value: value) == nil, "\(value)")
        }
        for value in [F.github, F.openai, "Qm4Rt8xxxVx2Bn6Lp9Zc3Hd7Kf1", "correct horse battery", "yo-ur-key-Zq8Lm2Np"] {
            #expect(!SecretImport.isPlaceholder(value), "\(value)")
        }
        #expect(SecretImport.detect(name: "DB_PASSWORD", value: "correct horse battery") == "a key, by its name")
    }

    @Test func encryptedValuesAreReferencesTheMoveLeaves() {
        let sops = "ENC[AES256_GCM,data:Zm9vYmFy,iv:bWFkZS11cA==,tag:dGFnLXRhZw==,type:str]"
        let dotenvx = "encrypted:" + "BHLTq2Lm9Np4Rs8Tv3Wx6Yz1Ab5Cd7Ef9Gh2Jk4Lm6Np8Qr0St"
        for value in [sops, dotenvx, "${{ secrets.OPENAI }}", "${env:OPENAI_API_KEY}", "${file:./key}"] {
            #expect(SecretImport.isReference(value), "\(value)")
            #expect(SecretImport.detect(name: "API_KEY", value: value) == nil, "\(value)")
        }
    }

    @Test func theMCPImportsScanSkipsThem() {
        let home = F.Home()
        defer { home.remove() }
        let sops = "ENC[AES256_GCM,data:Zm9vYmFy,iv:bWFkZS11cA==,tag:dGFnLXRhZw==,type:str]"
        let config = """
            {"mcpServers": {"a": {"command": "npx", "args": ["a"],
              "env": {"A_TOKEN": "\(sops)", "B_TOKEN": "your-b-token-goes-here", "C_TOKEN": "\(F.github)"}}}}
            """
        home.write(".cursor/mcp.json", config)
        let scan = SecretImport.scan(F.sources(home))
        #expect(scan.findings.map(\.variable) == ["C_TOKEN"])
    }

    private struct Item: GroupableValue {
        let value: SecretBytes
        let place: String
        let label: String
        var groupPlace: AnyHashable { AnyHashable(place) }
    }

    @Test func groupingByValueTakesOneOfEachPlace() {
        let a = SecretBytes(utf8: "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh")
        let b = SecretBytes(utf8: "Hd7Kf1Wj5Ys0EaQm4Rt8Vx2")
        let items = [Item(value: a, place: "x", label: "1"), Item(value: b, place: "x", label: "2"),
                     Item(value: SecretBytes(utf8: "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh"), place: "y", label: "3"),
                     Item(value: SecretBytes(utf8: "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh"), place: "y", label: "4")]
        let groups = SecretImport.byValue(items)
        let labels: [[String]] = groups.map { (group: (value: SecretBytes, items: [Item])) -> [String] in
            group.items.map(\.label)
        }
        // The fourth holds the first's value, but its place has one already: a group of its own.
        #expect(labels == [["1", "3"], ["2"], ["4"]])
    }
}
