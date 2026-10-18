import Foundation
import Testing
@testable import NextTermCore

/// Password managers' exports as the import reads them: Bitwarden's JSON and `bw list items`, 1Password's `op item get`
/// JSON and its `.1pux`, and `bws secret list`. Items, fields and values are all made up.
@Suite struct SecretSourcesFormatsTests {
    typealias E = ExportFixtures
    typealias F = SecretSourcesFixtures

    static func read(_ text: String, name: String, format: SecretSources.Format? = nil,
                     stored: Set<String> = []) -> SourceReport {
        var bytes: [UInt8] = Array(text.utf8)
        return SecretSources.read(&bytes, name: name, folder: "Downloads", format: format, stored: stored)
    }

    static func read(archive: [UInt8], name: String) -> SourceReport {
        var bytes: [UInt8] = archive
        return SecretSources.read(&bytes, name: name, folder: "Downloads")
    }

    static func row(_ report: SourceReport, _ name: String) -> SourceRow? {
        report.rows.first { (row: SourceRow) -> Bool in row.name == name }
    }

    /// Whether any part of the report a person or an agent could see holds `text`: a row's value, name, kind, place,
    /// note or link, a value that isn't a key, or the purpose.
    static func holds(_ report: SourceReport, _ text: String) -> Bool {
        let wanted = SecretBytes(utf8: text)
        for row in report.rows {
            let link: String = row.link?.url.absoluteString ?? ""
            let parts: [String] = [row.name, row.kind, row.place, row.note?.sentence ?? "", link]
            if row.value == wanted || parts.contains(where: { (part: String) -> Bool in part.contains(text) }) {
                return true
            }
        }
        let others: Bool = report.notKeys.contains { (notKey: SecretSources.NotKey) -> Bool in
            notKey.name.contains(text) || notKey.place.contains(text)
        }
        return others || report.purpose.contains(text)
    }

    // MARK: Bitwarden

    @Test func bitwardensExportGivesTheKeysAndASitePasswordUnticked() throws {
        let report = Self.read(E.bitwardenExport(), name: "bitwarden_export_20261015120000.json")
        #expect(report.format == .bitwarden && report.unreadable == nil)
        #expect(report.exportedBy == "Bitwarden" && report.purpose == "From Bitwarden")
        #expect(report.rows.map(\.name) == ["TAVILY", "LINEAR_API_KEY", "BANK"])
        let tavily = try #require(Self.row(report, "TAVILY"))
        #expect(tavily.ticked && tavily.fromTitle && tavily.kind == "Tavily key")
        #expect(tavily.link == .source(try #require(URL(string: "https://app.tavily.com/home"))))
        let linear = try #require(Self.row(report, "LINEAR_API_KEY"))
        #expect(linear.ticked && !linear.fromTitle && linear.link == nil)
        let bank = try #require(Self.row(report, "BANK"))
        #expect(!bank.ticked && bank.note == .websitePassword && bank.kind == "a website password")
        #expect(SecretSources.Note.websitePassword.sentence == "A website password; usually not an API key")
        #expect(report.notKeys.isEmpty)
    }

    @Test func historyCodesUsernamesAndCardsAreNeverRead() {
        let report = Self.read(E.bitwardenExport(), name: "export.json")
        for text in [E.historyPassword, E.totpSeed, E.username, "4111111111111111", "made-up-team"] {
            #expect(!Self.holds(report, text), "never in the report: \(text.prefix(4))…")
        }
    }

    @Test func bwListItemsReadsAsTheExportsItems() {
        let piped = Self.read(E.bitwardenItems(), name: "")
        #expect(piped.format == .bitwarden && piped.purpose == "From Bitwarden")
        #expect(piped.rows.map(\.name) == ["TAVILY", "LINEAR_API_KEY", "BANK"])
        let forced = Self.read(E.bitwardenItems(), name: "", format: .bitwarden)
        #expect(forced.rows.map(\.name) == piped.rows.map(\.name))
    }

    @Test func anEncryptedExportIsRefusedWhole() {
        let again = "Export again as .json (unencrypted), or use Import from Bitwarden\u{2026}"
        let sentence = "This export is encrypted. " + again
        for text in [E.bitwardenEncrypted, E.bitwardenProtected] {
            let report = Self.read(text, name: "bitwarden_encrypted_export.json")
            #expect(report.rows.isEmpty && report.unreadable == .encryptedExport)
            #expect(report.unreadable?.sentence == sentence)
            #expect(report.unreadable?.reasonClass == "an encrypted Bitwarden export")
        }
    }

    @Test func aSecureNotesLinesAreReadAsAnEnvFile() throws {
        let notes = "Made-up notes for the team.\nLINEAR_WEBHOOK_SECRET=\(E.webhook)\nREGION=eu\n"
        let report = Self.read(E.bitwardenExport(notes: notes), name: "export.json")
        let row = try #require(Self.row(report, "LINEAR_WEBHOOK_SECRET"))
        #expect(row.ticked && row.place == "Linear \u{203A} notes, line 2")
        #expect(report.notKeys.map(\.name) == ["REGION"])
    }

    @Test func anItemThatAsksForTheMasterPasswordStartsUnticked() throws {
        let report = Self.read(E.bitwardenExport(reprompt: 1), name: "export.json")
        let row = try #require(Self.row(report, "LINEAR_API_KEY"))
        #expect(!row.ticked && row.note == .reprompt)
    }

    // MARK: 1Password

    @Test func opItemGetGivesTheConcealedFieldWithTheItemsWebsite() throws {
        let report = Self.read(E.opAnthropic, name: "", format: .onePassword)
        #expect(report.format == .onePassword && report.purpose == "From 1Password")
        #expect(report.rows.map(\.name) == ["ANTHROPIC_API_KEY"])
        let row = try #require(report.rows.first)
        #expect(row.ticked && row.fromTitle && row.kind == "Anthropic key")
        #expect(row.link?.url.absoluteString == "https://console.anthropic.com/settings/keys")
        #expect(!Self.holds(report, E.username) && !Self.holds(report, E.noteToken))
    }

    @Test func severalItemsReadAsAnArrayOrOneAfterAnother() {
        let array = Self.read("[" + E.opAnthropic + "," + E.opTavily + "]", name: "", format: .onePassword)
        #expect(array.rows.map(\.name) == ["ANTHROPIC_API_KEY", "TAVILY_API_KEY"])
        #expect(array.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        let stream = Self.read(E.opAnthropic + "\n" + E.opTavily + "\n", name: "")
        #expect(stream.format == .onePassword)
        #expect(stream.rows.map(\.name) == ["ANTHROPIC_API_KEY", "TAVILY_API_KEY"])
    }

    @Test func twoConcealedFieldsAreTwoRowsAndACodeIsNone() {
        let report = Self.read(E.opDatabase, name: "made-up-db.json")
        #expect(report.format == .onePassword)
        #expect(report.rows.map(\.name) == ["MADE_UP_DB", "MADE_UP_DB_ADMIN_TOKEN"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        #expect(!Self.holds(report, E.totpSeed) && !Self.holds(report, E.username))
    }

    @Test func aFieldTheCLIKeptHiddenIsNotAKey() {
        let hidden = E.opAPICredential(title: "MADE_UP_KEY", value: "[use 'op item get madeupitem --reveal' to reveal]",
                                       site: "https://example.com/")
        let report = Self.read(hidden, name: "", format: .onePassword)
        #expect(report.rows.isEmpty)
        #expect(report.notKeys.map(\.reason) == [.concealed])
        #expect(SecretSources.NotKeyReason.concealed.sentence.contains("--reveal"))
    }

    @Test func aOnePUXExportGivesItsActiveItems() throws {
        let report = Self.read(archive: ZipFixture.onePUX(E.onePUXData), name: "1PasswordExport-MADEUP-20261015.1pux")
        #expect(report.format == .onePassword && report.unreadable == nil && report.exportedBy == "1Password")
        #expect(report.rows.map(\.name) == ["ANTHROPIC", "BANK", "TAVILY"])
        let anthropic = try #require(Self.row(report, "ANTHROPIC"))
        #expect(anthropic.ticked && anthropic.link?.url.absoluteString == "https://console.anthropic.com/settings/keys")
        let bank = try #require(Self.row(report, "BANK"))
        #expect(!bank.ticked && bank.note == .websitePassword)
        #expect(Self.row(report, "TAVILY")?.link?.url.absoluteString == "https://app.tavily.com/home")
        for text in [E.webhook, E.historyPassword, E.noteToken, E.username] { #expect(!Self.holds(report, text)) }
        // Its `export.data` alone reads the same.
        let data = Self.read(E.onePUXData, name: "export.data")
        #expect(data.rows.map(\.name) == report.rows.map(\.name))
    }

    @Test func anArchiveWithoutTheExportIsNotOne() {
        let other = ZipFixture.archive([ZipFixture.Entry(name: "notes.txt", data: Array("made up".utf8))])
        let report = Self.read(archive: other, name: "archive.1pux")
        #expect(report.unreadable == .notAnExport(from: "1Password"))
        #expect(report.unreadable?.reasonClass == "not a 1Password export")
        let entry = ZipFixture.Entry(name: "export.data", data: Array(E.onePUXData.utf8))
        let wide = ZipFixture.archive([entry], bend: ZipFixture.Bend(zip64: true))
        #expect(Self.read(archive: wide, name: "x.1pux").unreadable == .archive(.zip64))
    }

    // MARK: Bitwarden Secrets Manager

    @Test func bwsSecretsAreEachTickedWithTheManagersPurpose() {
        let report = Self.read(E.bwsList, name: "", format: .bws)
        #expect(report.format == .bws && report.purpose == "From Bitwarden Secrets Manager")
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "DB_PASSWORD"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        #expect(!Self.holds(report, E.noteToken) && !Self.holds(report, "Rotated by hand"))
        let detected = Self.read(E.bwsList, name: "bws-secrets.json")
        #expect(detected.format == .bws && detected.rows.count == 3)
    }

    // MARK: Purposes

    @Test func noPurposeHoldsATitleANoteOrALabel() {
        let reports: [SourceReport] = [
            Self.read(E.bitwardenExport(notes: "LINEAR_WEBHOOK_SECRET=\(E.webhook)"), name: "export.json"),
            Self.read(E.opDatabase, name: "made-up-db.json"),
            Self.read(archive: ZipFixture.onePUX(E.onePUXData), name: "export.1pux"),
            Self.read(E.bwsList, name: "", format: .bws),
            Self.read(E.bitwardenCSV, name: "bitwarden_export.csv"),
            Self.read(E.keePassXCCSV, name: "keepass.csv"),
        ]
        let words = ["Tavily", "Linear", "Bank", "Anthropic", "made-up-db", "credential", "admin token", "notes",
                     "Groq", "Rotated", E.noteToken, "LINEAR"]
        for report in reports {
            #expect(!words.contains { (word: String) -> Bool in report.purpose.contains(word) }, "\(report.purpose)")
        }
    }

    // MARK: What an agent and the vault see

    @Test func anExportsAnswerNamesItsFormatAndNothingOfItsRows() {
        let report = Self.read(E.bitwardenExport(), name: "export.json", stored: ["TAVILY"])
        #expect(Self.row(report, "TAVILY")?.ticked == false)
        #expect(Self.row(report, "TAVILY")?.note == .replaces)
        let outcome = SecretSources.CopyInOutcome.imported(["LINEAR_API_KEY"], replaced: [], from: report)
        let answer = SecretSources.answer(for: outcome)
        #expect(answer["format"] as? String == "bitwarden")
        #expect(answer["found"] as? Int == 3 && answer["not_imported"] as? Int == 2)
        let text = String(describing: answer)
        for part in [E.linear, E.tavily, "Tavily", "Bank", "app.tavily.com"] { #expect(!text.contains(part)) }
        let unreadable = SecretSources.answer(for: .unreadable(.csv(.ragged(line: 3))))
        #expect(unreadable["reason"] as? String == "not a CSV Next Term can read")
        let encrypted = SecretSources.answer(for: .unreadable(.encryptedExport))
        #expect(encrypted["reason"] as? String == "an encrypted Bitwarden export")
        #expect(SecretSources.Format.onePassword.rawValue == "1password")
    }
}

