import Foundation
import Testing
@testable import NextTermCore

/// The edges of the import's model: the last four counted in characters, values trimmed, a link that holds another
/// key, a name the section rule would make twice, an array's strings, a file that only starts like JSON, a `{name,
/// value}` whose value is an object, an expired token, and keys in one case that hold three x's. Every value here is
/// made up.
@Suite struct SecretSourcesEdgeTests {
    typealias F = SecretSourcesFixtures

    private static func json(_ text: String, name: String = "secrets.json") -> SourceReport {
        F.report(text, name: name)
    }

    private static func names(_ report: SourceReport) -> [String] { report.rows.map(\.name) }

    private static func row(_ report: SourceReport, _ name: String) -> SourceRow? {
        report.rows.first { (row: SourceRow) -> Bool in row.name == name }
    }

    // MARK: The last four

    @Test func theLastFourAreCharactersAndAShortValueShowsOnlyDots() {
        // Eight and nine characters of two or three bytes each: under 12 characters, so dots only.
        let report = F.report("DB_PASSWORD=密码密码密码密码\nADMIN_PASSWORD=ключ-ключ\n", name: ".env")
        #expect(Self.names(report) == ["DB_PASSWORD", "ADMIN_PASSWORD"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.lastFour == nil })
        #expect(SecretSources.lastFour(of: "🔑🔑🔑") == nil)
        #expect(SecretSources.lastFour(of: "密码密码密码密码密码密码") == "密码密码")
        #expect(SecretSources.lastFour(of: "Qm4Rt8Vx2Bn6") == "2Bn6")
        #expect(SecretSources.lastFour(of: "Qm4Rt8Vx2Bn") == nil)
    }

    @Test func aValueIsTrimmedBeforeItIsJudgedAndKept() throws {
        let report = Self.json(#"{"OPENAI_API_KEY": "  \#(F.openAI)  ", "PINECONE_API_KEY": "\#(F.pinecone)\n"}"#)
        let openAI = try #require(Self.row(report, "OPENAI_API_KEY"))
        #expect(openAI.value == SecretBytes(utf8: F.openAI))
        #expect(openAI.lastFour == "s0Ea")
        // A line break at the end is a copy's, not the key's: kept without it, and ticked.
        let pinecone = try #require(Self.row(report, "PINECONE_API_KEY"))
        #expect(pinecone.refusal == nil && pinecone.ticked)
        #expect(pinecone.value == SecretBytes(utf8: F.pinecone))
        #expect(pinecone.lastFour == "4De8")
    }

    // MARK: Links

    @Test func aCommentsLinkThatHoldsAnotherKeyInTheFileIsDropped() throws {
        let password = "Tr0ub4dor" + "Xhorse7Yz"
        let text = """
            # https://example.com/p/\(password)
            OPENAI_API_KEY=\(F.openAI)
            DB_PASSWORD=\(password)
            # https://example.com/p/rag-project
            PINECONE_API_KEY=\(F.pinecone)

            """
        let report = F.report(text, name: ".env")
        let openAI = try #require(Self.row(report, "OPENAI_API_KEY"))
        // The page its value suggests stands in for the link that holds DB_PASSWORD's value.
        #expect(openAI.link?.page?.id == "openai")
        let pinecone = try #require(Self.row(report, "PINECONE_API_KEY"))
        #expect(pinecone.link?.url.absoluteString == "https://example.com/p/rag-project")
        #expect(pinecone.link?.page == nil)
    }

    // MARK: Names

    @Test func aNameTheSectionRuleMakesIsNeverOneTheFileHas() {
        let suffixed = Self.json("""
            {"OPENAI_API_KEY_PRODUCTION": "\(F.openAI)",
             "production": {"OPENAI_API_KEY": "\(F.openAIOld)"},
             "staging": {"OPENAI_API_KEY": "\(F.openAIOld.reversedText)"}}
            """)
        let expected = ["OPENAI_API_KEY_PRODUCTION", "OPENAI_API_KEY_PRODUCTION_2", "OPENAI_API_KEY_STAGING"]
        #expect(Self.names(suffixed) == expected)
        let numbered = Self.json("""
            {"OPENAI_API_KEY_2": "\(F.openAI)",
             "envs": [{"OPENAI_API_KEY": "\(F.openAIOld)"}, {"OPENAI_API_KEY": "\(F.openAIOld.reversedText)"}]}
            """)
        #expect(Self.names(numbered) == ["OPENAI_API_KEY_2", "OPENAI_API_KEY", "OPENAI_API_KEY_3"])
        for report in [suffixed, numbered] {
            let ticked: [String] = report.rows.filter(\.ticked).map(\.name)
            #expect(ticked.count == 3 && Set(ticked).count == ticked.count)
        }
    }

    @Test func anArraysStringsAreKeysOfTheirOwn() {
        let keys = Self.json(#"{"keys": ["\#(F.openAI)", "\#(F.openAIOld)"]}"#)
        #expect(Self.names(keys) == ["KEYS", "KEYS_2"])
        #expect(keys.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == nil })
        let root = Self.json(#"["\#(F.openAI)", "\#(F.pinecone)"]"#)
        #expect(Self.names(root) == ["KEY", "KEY_2"])
        // The same value twice is one key, found in both places.
        let same = Self.json(#"{"keys": ["\#(F.openAI)", "\#(F.openAI)"]}"#)
        #expect(Self.names(same) == ["KEYS"])
        #expect(same.rows.first?.alsoAt == ["keys[1]"])
    }

    @Test func aNameValuePairWhoseValueIsAnObjectIsWalked() {
        let report = Self.json(#"[{"name": "cfg", "value": {"OPENAI_API_KEY": "\#(F.openAI)"}}]"#)
        #expect(Self.names(report) == ["OPENAI_API_KEY"])
        #expect(report.rows.first?.place == "[0].value.OPENAI_API_KEY")
        let listed = Self.json(#"[{"key": "keys", "value": ["\#(F.pinecone)"]}]"#)
        #expect(listed.rows.map(\.place) == ["[0].value[0]"])
    }

    // MARK: Formats

    @Test func textThatOnlyStartsLikeJSONIsReadAsAnEnvFile() {
        let secret = "Wq8Lm2Np7Rt4Vx9Bc3Df6Gh1Jk5Mn0Pq2Rs4Tu6"
        let lines = ["[default]", "aws_access_key_id = AKIA" + "Q4RT8VX2BN6LP9ZC", "aws_secret_access_key = \(secret)",
                     "region = us-east-1", ""]
        let text = lines.joined(separator: "\n")
        let report = F.report(text, name: "credentials")
        #expect(report.format == .env && report.unreadable == nil)
        #expect(Self.names(report) == ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
        // Named as JSON, it is JSON that doesn't read; and so is text with no line a .env has.
        #expect(F.report(text, name: "credentials.json").unreadable == .notJSON)
        #expect(F.report("[1, 2", name: "keys").unreadable == .notJSON)
    }

    @Test func aJSONCArrayReadsAsJSONWithItsStringsAsWritten() throws {
        let lines = ["[", #"  // a note, with a " in it"#,
                     #"  {"name": "OPENAI_API_KEY", "value": "\#(F.openAI)"}, /* gone */"#,
                     #"  "https://example.invalid/a//b/*kept*/",\#u{00A0}"#, "]"]
        let text = lines.joined(separator: "\n")
        let plain: [UInt8] = SecretSources.plainJSON(Array(text.utf8))
        let parsed = try #require(try? JSONSerialization.jsonObject(with: Data(plain)) as? [Any])
        #expect(parsed.count == 2)
        #expect(parsed.last as? String == "https://example.invalid/a//b/*kept*/")
        let report = Self.json(text)
        #expect(Self.names(report) == ["OPENAI_API_KEY"])
        #expect(report.notKeys.count == 1)
    }

    @Test func aJSONNameWinsOverADotEnvOne() {
        #expect(SecretSources.detect(text: F.dopplerJSON, name: ".env.json") == .json)
        let report = F.report(F.dopplerJSON, name: ".env.json")
        #expect(report.format == .json)
        #expect(Self.names(report) == ["OPENAI_API_KEY", "PINECONE_API_KEY"])
    }

    // MARK: Notes

    @Test func anExpiredTokenExpiresWithinHoursAsAE8Says() throws {
        let now = Date()
        // Pulled two days ago: its 12 hours are over.
        let report = F.report(F.shopWebEnv(now: now.addingTimeInterval(-2 * 86_400)), name: ".env.local", now: now)
        let oidc = try #require(Self.row(report, "VERCEL_OIDC_TOKEN"))
        #expect(!oidc.ticked && oidc.note == .shortLived)
        #expect(oidc.note?.sentence == "Expires within hours")
    }

    // MARK: Placeholders

    @Test func aKeyInOneCaseThatHoldsThreeXsIsStillAKey() {
        let aws = "AKIA" + "Q4RTXXX2BN6LP9ZC"
        let lower = "k7m2" + "xxxq9p4r8t3v6w1y5z0b2c7d9f3g6h1j"
        #expect(!SecretImport.isPlaceholder(aws) && !SecretImport.isPlaceholder(lower))
        // The MCP-config import's move finds them too.
        #expect(SecretImport.detect(name: "AWS_ACCESS_KEY_ID", value: aws) != nil)
        #expect(SecretImport.detect(name: "SERVICE_API_KEY", value: lower) != nil)
        let report = F.report("AWS_ACCESS_KEY_ID=\(aws)\nSERVICE_API_KEY=\(lower)\n", name: ".env")
        #expect(Self.names(report) == ["AWS_ACCESS_KEY_ID", "SERVICE_API_KEY"])
        #expect(report.rows.map(\.ticked) == [true, true])
        // Mostly x's is still a placeholder, in either case.
        for value in ["AKIA" + "XXXXXXXXXXXXXXXX", "xoxb-" + "xxxx-xxxx-xxxx", "sk-" + "xxx"] {
            #expect(SecretImport.isPlaceholder(value), "\(value)")
        }
    }
}
