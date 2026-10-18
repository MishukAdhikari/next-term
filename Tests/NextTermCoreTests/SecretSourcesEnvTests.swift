import Foundation
import Testing
@testable import NextTermCore

/// The `.env` family as the import reads it: dotenv's reading, `KEY: value` lines, `.envrc`'s exports, a link in the
/// comment above a key, and duplicates as dotenv takes them. Nothing in a file is run. Every value here is made up.
@Suite struct SecretSourcesEnvTests {
    typealias F = SecretSourcesFixtures

    private static func row(_ report: SourceReport, _ name: String, line: Int? = nil) -> SourceRow? {
        report.rows.first { (row: SourceRow) -> Bool in row.name == name && (line == nil || row.line == line) }
    }

    @Test func aRAGServicesEnvGivesThreeKeysAndFourOtherValues() throws {
        let report = F.report(F.ragAPIEnv, name: ".env", folder: "rag-api")
        #expect(report.format == .env)
        #expect(report.unreadable == nil)
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == nil && row.refusal == nil })
        #expect(report.rows.map(\.kind) == ["OpenAI key", "Pinecone key", "LangSmith key"])
        #expect(report.rows.map(\.lastFour) == ["s0Ea", "4De8", "3e7b"])
        let pages = report.rows.map { (row: SourceRow) -> String? in row.link?.page?.id }
        #expect(pages == ["openai", "pinecone", "langsmith"])
        #expect(report.notKeys.map(\.name) == ["LANGSMITH_ENDPOINT", "OPENAI_MODEL", "CHUNK_SIZE", "DATABASE_URL"])
        let database = try #require(report.notKeys.last)
        #expect(database.reason.sentence == "Built from DB_PASS")
        #expect(report.footer == "4 other values aren\u{2019}t keys.")
        #expect(report.purpose == "From .env in rag-api")
        #expect(report.rows.first?.place == "line 2")
    }

    @Test func aNextAppsEnvLocalTicksItsKeysAndNotesTheRest() throws {
        let now = Date()
        let report = F.report(F.shopWebEnv(now: now), name: ".env.local", folder: "shop-web", now: now)
        #expect(report.rows.count == 6)
        let stripe = try #require(Self.row(report, "STRIPE_SECRET_KEY"))
        #expect(stripe.ticked && stripe.note == nil)
        #expect(stripe.link?.url.absoluteString == "https://dashboard.stripe.com/apikeys")
        #expect(Self.row(report, "SUPABASE_SECRET_KEY")?.ticked == true)
        let early = try #require(Self.row(report, "OPENAI_API_KEY", line: 4))
        let late = try #require(Self.row(report, "OPENAI_API_KEY", line: 19))
        #expect(!early.ticked && early.note?.sentence == "Set again on line 19")
        #expect(late.ticked && late.note == nil)
        let publishable = try #require(Self.row(report, "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY"))
        #expect(!publishable.ticked && publishable.note == .publishable)
        let oidc = try #require(Self.row(report, "VERCEL_OIDC_TOKEN"))
        #expect(!oidc.ticked && oidc.note == .shortLived)
        #expect(!report.rows.contains { (row: SourceRow) -> Bool in row.name.hasSuffix("_URL") })
        let notKeys: [String] = report.notKeys.map { (notKey: SecretSources.NotKey) -> String in notKey.name }
        #expect(notKeys.contains("NEXT_PUBLIC_SUPABASE_URL"))
    }

    @Test func aStoredNameStartsUntickedAndSaysItReplaces() throws {
        let now = Date()
        let report = F.report(F.shopWebEnv(now: now), name: ".env.local", stored: ["STRIPE_SECRET_KEY", "OPENAI_API_KEY"],
                              now: now)
        let stripe = try #require(Self.row(report, "STRIPE_SECRET_KEY"))
        #expect(!stripe.ticked && stripe.note?.sentence == "Replaces your key")
        // A row set again further down still says so: that's why it isn't the one dotenv reads.
        #expect(Self.row(report, "OPENAI_API_KEY", line: 4)?.note == .setAgain(line: 19, place: "line 19"))
        #expect(Self.row(report, "OPENAI_API_KEY", line: 19)?.note == .replaces)
    }

    @Test func colonLinesAreReadAndEnvFileStillSkipsThem() {
        let text = "OPENAI_API_KEY: \(F.openAI)\nexport PINECONE_API_KEY: '\(F.pinecone)'\nNOTE:not-a-line\nA=b: c\n"
        let report = F.report(text, name: ".env")
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY"])
        #expect(report.rows.map(\.line) == [1, 2])
        #expect(report.notKeys.map(\.name) == ["A"])
        // The editor's reader is unchanged.
        #expect(EnvFile.parse(text, interpolating: false).map(\.key) == ["A"])
    }

    @Test func anEnvrcGivesOnlyItsExportsAndRunsNothing() {
        let text = """
            export A=1
            eval "$(direnv dotenv bash .env.secret)"
            source .env.secret
            PINECONE_API_KEY=\(F.pinecone)
            dotenv_if_exists .env.local
            export FROM_FILE=$(cat ./made-up-secret.txt)

            """
        let report = F.report(text, name: ".envrc")
        #expect(report.rows.isEmpty)
        #expect(report.notKeys.map(\.name) == ["A", "FROM_FILE"])
        let keyed = F.report("export OPENAI_API_KEY=\(F.openAI)\nexport  LOG=debug\n", name: ".envrc")
        #expect(keyed.rows.map(\.name) == ["OPENAI_API_KEY"])
    }

    @Test func aLinkInTheCommentAboveAKeyIsItsSourceLink() throws {
        let text = """
            # made at https://platform.openai.com/settings/organization/api-keys (project rag)
            OPENAI_API_KEY=\(F.openAI)
            # an old note: http://keys.example.invalid/openai
            OPENAI_ADMIN_KEY=\(F.openAIOld)
            # [where](https://user:pw@dashboard.stripe.com/apikeys)
            STRIPE_SECRET_KEY=\(F.stripeSecret)

            """
        let report = F.report(text, name: ".env")
        let openAI = try #require(Self.row(report, "OPENAI_API_KEY"))
        #expect(openAI.link?.url.absoluteString == "https://platform.openai.com/settings/organization/api-keys")
        #expect(openAI.link?.page == nil)
        // A link the rules refuse is dropped: http to another host, a user and password. The suggestion stands in.
        #expect(Self.row(report, "OPENAI_ADMIN_KEY")?.link?.page?.id == "openai")
        #expect(Self.row(report, "STRIPE_SECRET_KEY")?.link?.page?.id == "stripe")
    }

    @Test func aDollarSignOtherLoadersReadIsNoted() throws {
        let text = "DB_PASSWORD=Tr0ub4dor$horse3\nDB_PASSWORD_QUOTED='Tr0ub4dor$horse3'\n"
        let report = F.report(text, name: ".env")
        #expect(Self.row(report, "DB_PASSWORD")?.note == .loaderReadsDollar)
        #expect(Self.row(report, "DB_PASSWORD")?.ticked == true)
        #expect(Self.row(report, "DB_PASSWORD_QUOTED")?.note == nil)
    }

    @Test func aMultiLineKeyIsListedWithItsReason() throws {
        let body = "\(F.privateKeyHead)\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASC\nNote: kept\n\(F.privateKeyTail)"
        let text = "PRIVATE_KEY=\"\(body)\"\nAFTER=1\n"
        let report = F.report(text, name: ".env")
        let key = try #require(Self.row(report, "PRIVATE_KEY"))
        #expect(!key.ticked && key.refusal == .lineBreaks)
        // A line inside the quoted value is not read as a `KEY: value` line.
        #expect(report.rows.count == 1)
        #expect(report.notKeys.map(\.name) == ["AFTER"])
    }

    @Test func dotenvxFilesListTheirEncryptedValues() throws {
        let text = """
            #/-------------------[DOTENV_PUBLIC_KEY]--------------------/
            #/       [how it works](https://dotenvx.com/encryption)     /
            #/----------------------------------------------------------/
            DOTENV_PUBLIC_KEY="03f8a1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2"
            OPENAI_API_KEY="encrypted:BHLTq2Lm9Np4Rs8Tv3Wx6Yz1Ab5Cd7Ef9Gh2Jk4Lm6Np8Qr0St"

            """
        let report = F.report(text, name: ".env")
        #expect(Self.row(report, "DOTENV_PUBLIC_KEY")?.note == .publishable)
        let key = try #require(Self.row(report, "OPENAI_API_KEY"))
        #expect(!key.ticked && key.refusal == .encryptedDotenvx)
        #expect(key.refusal?.sentence.contains("dotenvx") == true)
    }

    @Test func theBufferIsWipedAndLargeFilesRefused() {
        var data: [UInt8] = Array(F.ragAPIEnv.utf8)
        _ = SecretSources.read(&data, name: ".env")
        #expect(data.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
        var large: [UInt8] = Array(repeating: UInt8(ascii: "a"), count: SecretSources.maxBytes + 1)
        let report = SecretSources.read(&large, name: ".env")
        #expect(report.unreadable == .tooLarge && report.rows.isEmpty)
        var binary: [UInt8] = [0xFF, 0xFE, 0x00, 0x41]
        #expect(SecretSources.read(&binary, name: "keys.bin").unreadable == .notText)
    }
}
