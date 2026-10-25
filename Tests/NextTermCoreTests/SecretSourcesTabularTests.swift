import Foundation
import Testing
@testable import NextTermCore

/// CSV exports as the import reads them: each known header picks its app's columns; a site's password starts unticked
/// unless it has a key's shape, and a name never carries the account. Every row here is made up.
@Suite struct SecretSourcesTabularTests {
    typealias E = ExportFixtures
    typealias F = SecretSourcesFixtures

    static func read(_ text: String, name: String = "export.csv", stored: Set<String> = []) -> SourceReport {
        SecretSourcesFormatsTests.read(text, name: name, stored: stored)
    }

    static func row(_ report: SourceReport, _ name: String) -> SourceRow? {
        SecretSourcesFormatsTests.row(report, name)
    }

    @Test func eachHeaderPicksItsApp() {
        let cases: [(String, String?)] = [
            (E.bitwardenCSV, "Bitwarden"), (E.chromeCSV, "Chrome"), (E.appleCSV, "Apple Passwords"),
            (E.firefoxCSV, "Firefox"), (E.keePassXCCSV, "KeePassXC"), (E.lastPassCSV, "LastPass"),
            (E.onePasswordCSV, "1Password"), (E.plainCSV, nil),
        ]
        for (text, app) in cases {
            let report = Self.read(text)
            #expect(report.format == .csv && report.unreadable == nil)
            #expect(report.exportedBy == app)
            if let app { #expect(report.purpose == "From " + app) }
        }
    }

    @Test func bitwardensCSVReadsItsLoginsFieldsAndNotes() throws {
        let report = Self.read(E.bitwardenCSV, name: "bitwarden_export_20261015.csv")
        #expect(report.rows.map(\.name) == ["TAVILY", "LINEAR_API_KEY", "LINEAR_WEBHOOK_SECRET", "BANK"])
        let tavily = try #require(Self.row(report, "TAVILY"))
        #expect(tavily.ticked && tavily.link?.url.absoluteString == "https://app.tavily.com/home")
        #expect(Self.row(report, "LINEAR_API_KEY")?.ticked == true)
        #expect(Self.row(report, "LINEAR_WEBHOOK_SECRET")?.ticked == true)
        let bank = try #require(Self.row(report, "BANK"))
        #expect(!bank.ticked && bank.note == .websitePassword)
        #expect(bank.link?.url.absoluteString == "https://bank.example.com/login")
        for text in [E.username, E.totpSeed] { #expect(!SecretSourcesFormatsTests.holds(report, text)) }
    }

    @Test func browserRowsAreNamedByTheirSiteAndTickedOnlyWithAKeysShape() throws {
        let chrome = Self.read(E.chromeCSV, name: "Chrome Passwords.csv")
        #expect(chrome.rows.map(\.name) == ["GITHUB", "API_EXAMPLE"])
        #expect(Self.row(chrome, "GITHUB")?.note == .websitePassword)
        let key = try #require(Self.row(chrome, "API_EXAMPLE"))
        #expect(key.ticked && key.kind == "OpenAI key" && key.fromTitle)
        let apple = Self.read(E.appleCSV, name: "Passwords.csv")
        #expect(apple.rows.map(\.name) == ["GITHUB", "CONSOLE_EXAMPLE"])
        #expect(apple.rows.map(\.ticked) == [false, true])
        // The title names the account; the name never does.
        #expect(!apple.rows.contains { (row: SourceRow) -> Bool in row.name.contains("MADE_UP") })
        let firefox = Self.read(E.firefoxCSV, name: "logins.csv")
        #expect(firefox.rows.map(\.name) == ["BANK_EXAMPLE"])
        #expect(firefox.rows.first?.ticked == false)
        #expect(!SecretSourcesFormatsTests.holds(firefox, "kSync"))
    }

    @Test func aManagersTitleThatNamesAKeyTicksIt() {
        let keePass = Self.read(E.keePassXCCSV, name: "Passwords.csv")
        #expect(keePass.rows.map(\.name) == ["GROQ_TOKEN", "OPENAI", "MAIL"])
        #expect(keePass.rows.map(\.ticked) == [true, true, false])
        #expect(Self.row(keePass, "GROQ_TOKEN")?.link?.url.absoluteString == "https://console.groq.com/keys")
        let lastPass = Self.read(E.lastPassCSV, name: "lastpass_export.csv")
        #expect(lastPass.rows.map(\.name) == ["BANK", "OPENAI_API_KEY"])
        #expect(lastPass.rows.map(\.ticked) == [false, true])
        let onePassword = Self.read(E.onePasswordCSV, name: "1PasswordExport.csv")
        #expect(onePassword.rows.map(\.name) == ["TAVILY_API"])
        #expect(onePassword.rows.first?.ticked == true)
        #expect(!SecretSourcesFormatsTests.holds(onePassword, E.tavily.reversedText))
    }

    @Test func aPlainNameValueFileReadsAsAnEnvFileDoes() throws {
        let report = Self.read(E.plainCSV, name: "keys.csv")
        #expect(report.purpose == "From keys.csv in Downloads")
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
        #expect(!report.rows.contains { (row: SourceRow) -> Bool in row.fromTitle })
        let openAI = try #require(Self.row(report, "OPENAI_API_KEY"))
        #expect(openAI.link == .source(try #require(URL(string: E.plainLink))))
        #expect(openAI.place == "line 2" && openAI.line == 2)
        #expect(report.notKeys.map(\.name) == ["OPENAI_MODEL"])
        let keyed = Self.read("key,value\nOPENAI_API_KEY,\(F.openAI)\n")
        #expect(keyed.rows.map(\.name) == ["OPENAI_API_KEY"])
    }

    @Test func aHeaderNextTermDoesntKnowIsRefused() {
        let report = Self.read("first,second,third\nOPENAI_API_KEY,\(F.openAI),x\n")
        #expect(report.rows.isEmpty && report.unreadable == .unknownColumns)
        #expect(report.unreadable?.sentence == "Next Term can\u{2019}t tell which column holds the keys.")
        let ragged = Self.read("name,value\nA,1\nB\n")
        #expect(ragged.unreadable == .csv(.ragged(line: 3)))
        #expect(ragged.unreadable?.reasonClass == "not a CSV Next Term can read")
    }

    @Test func aKnownHeaderIsReadWhateverTheFilesName() {
        #expect(Self.read(E.chromeCSV, name: "passwords.txt").format == .csv)
        #expect(Self.read(E.plainCSV, name: "keys").format == .csv)
        // A .env's name wins over its content.
        #expect(Self.read("name,value\nA=1\n", name: ".env").format == .env)
    }
}
