import Foundation
import Testing
@testable import NextTermCore

/// The export readers at their edges: `bw list items` with no custom field, items in the trash or the archive, a note
/// that asks for the master password again, a forced format that isn't the file's, JSON configs that only look like an
/// export, and titles that hold KEY as a part of a name. Every item and value is made up.
@Suite struct SecretSourcesManagersEdgeTests {
    typealias E = ExportFixtures
    typealias F = SecretSourcesFixtures

    static func read(_ text: String, name: String, format: SecretSources.Format? = nil) -> SourceReport {
        SecretSourcesFormatsTests.read(text, name: name, format: format)
    }

    static func row(_ report: SourceReport, _ name: String) -> SourceRow? {
        SecretSourcesFormatsTests.row(report, name)
    }

    static func holds(_ report: SourceReport, _ text: String) -> Bool {
        SecretSourcesFormatsTests.holds(report, text)
    }

    // MARK: Bitwarden

    @Test func bwListItemsWithNoCustomFieldIsStillBitwardens() throws {
        let report = Self.read(E.bwListWithoutFields, name: "items.json")
        #expect(report.format == .bitwarden && report.unreadable == nil)
        #expect(report.purpose == "From Bitwarden" && report.exportedBy == "Bitwarden")
        #expect(report.rows.map(\.name) == ["BANK", "LINEAR_WEBHOOK_SECRET"])
        let bank = try #require(Self.row(report, "BANK"))
        #expect(!bank.ticked && bank.note == .websitePassword)
        #expect(Self.row(report, "LINEAR_WEBHOOK_SECRET")?.ticked == true)
        #expect(report.notKeys.isEmpty)
        // The history, the code's seed and the username are never read; the login in the trash is skipped.
        for text in [E.historyPassword, E.totpSeed, E.username, E.tavily] {
            #expect(!Self.holds(report, text), "never in the report: \(text.prefix(4))…")
        }
    }

    @Test func aNoteThatAsksForTheMasterPasswordStartsUntickedInTheCSV() {
        let report = Self.read(E.bitwardenCSVRepromptNote, name: "bitwarden_export.csv")
        #expect(report.rows.map(\.name) == ["LINEAR_API_KEY", "LINEAR_WEBHOOK_SECRET"])
        for row in report.rows { #expect(!row.ticked && row.note == .reprompt, "\(row.name)") }
    }

    @Test func keyAsAPartOfANameIsNotAKeysTitle() throws {
        for title in ["KeyBank", "YubiKey 5 NFC", "YubiKeys", "Monkey", "Keycloak admin"] {
            #expect(!SecretSources.titleSaysKey(title), "\(title)")
        }
        let keys = ["Groq token", "OpenAI API", "GROQ_API_KEY", "openai-key", "Stripe keys", "GroqApiKey", "APIKey"]
        for title in keys { #expect(SecretSources.titleSaysKey(title), "\(title)") }
        let login = #"[{"object": "item", "type": 1, "name": "KeyBank", "login": {"uris": [], "password": ""#
        let report = Self.read(login + E.bankPassword + #""}}]"#, name: "items.json")
        let bank = try #require(Self.row(report, "KEY_BANK"))
        #expect(!bank.ticked && bank.note == .websitePassword)
    }

    // MARK: Which manager wrote it

    @Test func aForcedFormatThatIsntTheFilesIsRefusedByName() {
        let cases: [(String, SecretSources.Format, String)] = [
            (E.opAnthropic, .bitwarden, "Bitwarden"),
            (E.bitwardenItems(), .onePassword, "1Password"),
            (E.bitwardenExport(), .bws, "Bitwarden Secrets Manager"),
        ]
        for (text, format, app) in cases {
            let report = Self.read(text, name: "", format: format)
            #expect(report.format == format && report.unreadable == .notAnExport(from: app))
            #expect(report.rows.isEmpty)
        }
    }

    @Test func aConfigThatOnlyLooksLikeAnExportIsReadAsJSON() {
        let key: String = F.openAI
        let configs: [String] = [
            #"{"encrypted": false, "data": {"OPENAI_API_KEY": "\#(key)"}}"#,
            #"{"encrypted": true, "data": {"OPENAI_API_KEY": "\#(key)"}}"#,
            #"{"encrypted": false, "items": [{"name": "OPENAI_API_KEY", "value": "\#(key)"}]}"#,
            #"{"category": "service", "fields": [{"name": "OPENAI_API_KEY", "value": "\#(key)"}]}"#,
            #"{"category": "form", "fields": [{"id": "OPENAI_API_KEY", "type": "text", "value": "\#(key)"}]}"#,
        ]
        let wanted = SecretBytes(utf8: key)
        for config in configs {
            let report = Self.read(config, name: "config.json")
            #expect(report.format == .json && report.unreadable == nil, "\(config.prefix(40))")
            #expect(report.exportedBy == nil)
            #expect(report.rows.contains { (row: SourceRow) -> Bool in row.value == wanted && row.ticked })
        }
    }

    @Test func aForcedOnePasswordItemWithNoSecretIsAnEmptyReport() {
        let username: [String: String] = E.opField("username", "STRING", E.username, purpose: "USERNAME")
        let item: String = E.opItem("Made-up login", category: "LOGIN", fields: [username])
        let forced = Self.read(item, name: "", format: .onePassword)
        #expect(forced.format == .onePassword && forced.unreadable == nil && forced.rows.isEmpty)
        #expect(Self.read(item, name: "item.json").format == .json)
    }
}

// MARK: - 1Password and the archive's limits

extension SecretSourcesManagersEdgeTests {
    @Test func anArchivedOrDeletedOpItemIsSkipped() {
        let credential: [String: String] = E.opField("credential", "CONCEALED", E.webhook)
        let archived: String = E.opItem("OLD_KEY", category: "API_CREDENTIAL", fields: [credential], state: "ARCHIVED")
        let deleted: String = E.opItem("GONE_KEY", category: "API_CREDENTIAL", fields: [credential], state: "DELETED")
        let report = Self.read("[" + archived + "," + deleted + "," + E.opTavily + "]", name: "items.json")
        #expect(report.format == .onePassword)
        #expect(report.rows.map(\.name) == ["TAVILY_API_KEY"])
        #expect(!Self.holds(report, E.webhook))
    }

    @Test func anOpLoginsSitePasswordStartsUntickedUnlessItsTitleNamesAKey() throws {
        let username: [String: String] = E.opField("username", "STRING", E.username, purpose: "USERNAME")
        let password: [String: String] = E.opField("password", "CONCEALED", E.bankPassword, purpose: "PASSWORD")
        let groqPassword: [String: String] = E.opField("password", "CONCEALED", "made-up-groq-pass-99",
                                                        purpose: "PASSWORD")
        let site = "https://bank.example.com/login"
        let bank: String = E.opItem("Bank", category: "LOGIN", fields: [username, password], site: site)
        let groq: String = E.opItem("Groq token", category: "LOGIN", fields: [username, groqPassword])
        let report = Self.read(bank + "\n" + groq + "\n", name: "")
        #expect(report.format == .onePassword)
        #expect(report.rows.map(\.name) == ["BANK", "GROQ_TOKEN"])
        let bankRow = try #require(Self.row(report, "BANK"))
        #expect(!bankRow.ticked && bankRow.note == .websitePassword && bankRow.kind == "a website password")
        #expect(bankRow.link?.url.absoluteString == site)
        #expect(Self.row(report, "GROQ_TOKEN")?.ticked == true)
        #expect(!Self.holds(report, E.username))
    }

    /// A Secure Note's concealed fields are read, as a Bitwarden note's hidden fields are; its text never is.
    @Test func aSecureNotesConcealedFieldIsReadAndItsTextIsNot() {
        let text: [String: String] = E.opField("notesPlain", "STRING", "Made-up note naming \(E.noteToken)",
                                                purpose: "NOTES")
        var hidden: [String: String] = E.opField("madeupfield1", "CONCEALED", E.webhook)
        hidden["label"] = "LINEAR_WEBHOOK_SECRET"
        let note: String = E.opItem("Linear notes", category: "SECURE_NOTE", fields: [text, hidden])
        let report = Self.read(note, name: "")
        #expect(report.format == .onePassword)
        #expect(report.rows.map(\.name) == ["LINEAR_WEBHOOK_SECRET"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        #expect(!Self.holds(report, E.noteToken) && !Self.holds(report, "Made-up note"))
    }

    @Test func anArchivePastTheLimitIsRefusedUnread() {
        var bytes = [UInt8](repeating: 0x41, count: SecretSources.maxArchiveBytes + 1)
        bytes.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x03, 0x04])
        let report = SecretSources.read(&bytes, name: "1PasswordExport-MADEUP.1pux", folder: "Downloads")
        #expect(report.format == .onePassword && report.unreadable == .archive(.tooLarge))
        #expect(report.rows.isEmpty)
        #expect(bytes.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
    }
}

// MARK: - Fixtures

extension ExportFixtures {
    /// `bw list items` with no custom field on any item: a login "Bank" with its history and a one-time code's seed, a
    /// secure note with a `KEY=value` line, and a login with a key's shape in the trash.
    static var bwListWithoutFields: String {
        """
        [
          {"passwordHistory": [{"lastUsedDate": "2026-01-01T00:00:00.000Z", "password": "\(historyPassword)"}],
           "revisionDate": "2026-10-01T00:00:00.000Z", "creationDate": "2026-01-01T00:00:00.000Z",
           "deletedDate": null, "object": "item", "id": "00000000-0000-4000-8000-000000000011",
           "organizationId": null, "folderId": null, "type": 1, "reprompt": 0, "name": "Bank", "notes": null,
           "favorite": false,
           "login": {"uris": [{"match": null, "uri": "https://bank.example.com/login"}], "username": "\(username)",
                     "password": "\(bankPassword)", "totp": "\(totpSeed)", "passwordRevisionDate": null},
           "collectionIds": []},
          {"passwordHistory": null, "revisionDate": "2026-10-01T00:00:00.000Z", "deletedDate": null,
           "object": "item", "id": "00000000-0000-4000-8000-000000000012", "type": 2, "reprompt": 0,
           "name": "Linear", "notes": "LINEAR_WEBHOOK_SECRET=\(webhook)", "secureNote": {"type": 0}},
          {"passwordHistory": null, "revisionDate": "2026-10-01T00:00:00.000Z",
           "deletedDate": "2026-10-02T00:00:00.000Z", "object": "item", "id": "00000000-0000-4000-8000-000000000013",
           "type": 1, "reprompt": 0, "name": "Old Tavily",
           "login": {"uris": [], "username": null, "password": "\(tavily)", "totp": null}}
        ]
        """
    }

    /// Bitwarden's `.csv` export with one secure note that asks for the master password again: a custom field and a
    /// `KEY=value` line.
    static var bitwardenCSVRepromptNote: String {
        """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,,note,Linear,"LINEAR_WEBHOOK_SECRET=\(webhook)","LINEAR_API_KEY: \(linear)",1,,,,

        """
    }

    /// One `op item get --format json` item, written by Foundation's writer.
    static func opItem(_ title: String, category: String, fields: [[String: String]], state: String? = nil,
                       site: String? = nil) -> String {
        var item: [String: Any] = ["id": "madeupitem0000000000000001", "title": title, "category": category]
        item["fields"] = fields
        if let state { item["state"] = state }
        if let site { item["urls"] = [["label": "website", "primary": true, "href": site] as [String: Any]] }
        let data: Data = (try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// An `op` field: its id (also its label), its type and value, and its purpose when it has one.
    static func opField(_ id: String, _ type: String, _ value: String, purpose: String? = nil) -> [String: String] {
        var field: [String: String] = ["id": id, "type": type, "label": id, "value": value]
        if let purpose { field["purpose"] = purpose }
        return field
    }
}
