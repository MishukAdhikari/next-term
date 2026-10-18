import Foundation
import Testing
@testable import NextTermCore

/// The copy sheet builds a row for each row a report lists, on the main thread, so a report lists no more than
/// `maxListed`: a file of more keys, picked, piped in or named by an agent, is reported as too many, as the MCP-config
/// import reports one, and no row of it reaches the sheet. A password manager's or a browser's website passwords, which
/// start unticked, are counted past that many, not listed, so a vault of thousands of sign-ins still lists its keys.
/// Show Them lists the first values that aren't keys, then how many more. The sheet finds ticked rows that share a name
/// in one pass. Every value here is made up.
@Suite struct SecretSourcesListCapTests {
    typealias F = SecretSourcesFixtures

    /// A made-up value of 30 characters, different for each number.
    private static func value(_ number: Int) -> String {
        let tail = String(number, radix: 36)
        return "Qm4Rt8Vx2Bn6Lp9Zc3Hd7" + String(repeating: "-", count: 9 - tail.count) + tail
    }

    /// A `.env` of `count` keys, each with its own name and value.
    private static func env(_ count: Int) -> String {
        let lines: [String] = (0..<count).map { (number: Int) -> String in
            "SVC_\(number)_API_KEY=" + value(number)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A browser's CSV of `sites` sign-ins whose passwords have no key's shape, then a sign-in for each of `keys`.
    private static func browserCSV(sites: Int, keys: [String]) -> [UInt8] {
        var lines: [String] = ["name,url,username,password,note"]
        let passwords: [String] = (0..<sites).map(value) + keys
        for (number, password) in passwords.enumerated() {
            let site = "site\(number).example.com"
            lines.append("\(site),https://\(site)/login,made-up-user,\(password),")
        }
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// A Bitwarden export of the same sign-ins.
    private static func bitwardenExport(sites: Int, keys: [String]) -> [UInt8] {
        let passwords: [String] = (0..<sites).map(value) + keys
        var items: [String] = []
        for (number, password) in passwords.enumerated() {
            let login = #"{"uris": [{"uri": "https://site\#(number).example.com/"}], "password": "\#(password)"}"#
            items.append(#"{"type": 1, "name": "Site \#(number)", "login": \#(login)}"#)
        }
        let export = #"{"encrypted": false, "folders": [], "items": ["# + items.joined(separator: ",") + "]}"
        return Array(export.utf8)
    }

    /// `bws secret list` of `count` secrets, as a pipe gives it.
    private static func bwsList(_ count: Int) -> [UInt8] {
        let secrets: [String] = (0..<count).map { (number: Int) -> String in
            let head = #"{"object":"secret","id":"made-up-\#(number)","projectId":"made-up-project","#
            return head + #""key":"SVC_\#(number)_TOKEN","value":"\#(value(number))","note":""}"#
        }
        return Array(("[" + secrets.joined(separator: ",") + "]").utf8)
    }

    @Test func aFileOfAsManyKeysAsTheSheetListsIsListed() {
        let report: SourceReport = F.report(Self.env(SecretSources.maxListed), name: ".env")
        #expect(report.unreadable == nil && report.unlisted == 0)
        #expect(report.rows.count == SecretSources.maxListed)
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
    }

    @Test func aFileOfMoreKeysThanTheSheetListsIsReportedAsTooMany() {
        var data: [UInt8] = Array(Self.env(SecretSources.maxListed + 1).utf8)
        let report: SourceReport = SecretSources.read(&data, name: ".env", folder: "rag-api")
        #expect(report.unreadable == .tooManyToList)
        #expect(report.rows.isEmpty && report.notKeys.isEmpty && report.unlisted == 0)
        #expect(report.format == .env && report.purpose == "From .env in rag-api")
        #expect(data.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
        // What the sheet says, for a file or a pipe alike, and what an agent's import_secrets hears: a class, no name
        // or count from the file.
        let most: String = SecretSources.maxListed.formatted()
        let held = "It holds more than \(most) keys, more than Next Term lists at once."
        #expect(report.unreadable?.sentence == held + " Import them in smaller parts.")
        let answer: [String: Any] = SecretSources.answer(for: .unreadable(.tooManyToList))
        #expect(answer["status"] as? String == "unreadable")
        #expect(answer["reason"] as? String == "too many keys to list")
    }

    /// Keys piped in (`nxtrm secret import -`) are read as a file is, and a password manager's secrets, which are keys
    /// and start ticked, are capped alike: only website passwords are counted past the list.
    @Test func keysPipedInAndAManagersSecretsAreCappedAlike() {
        var piped: [UInt8] = Array(Self.env(SecretSources.maxListed + 1).utf8)
        let fromPipe: SourceReport = SecretSources.read(&piped, name: "standard input", format: .env)
        #expect(fromPipe.unreadable == .tooManyToList && fromPipe.rows.isEmpty)
        var list: [UInt8] = Self.bwsList(SecretSources.maxListed + 1)
        let bws: SourceReport = SecretSources.read(&list, name: "standard input", format: .bws)
        #expect(bws.unreadable == .tooManyToList && bws.rows.isEmpty && bws.unlisted == 0)
        #expect(bws.exportedBy == "Bitwarden Secrets Manager")
        var listed: [UInt8] = Self.bwsList(SecretSources.maxListed)
        let all: SourceReport = SecretSources.read(&listed, name: "standard input", format: .bws)
        #expect(all.unreadable == nil && all.rows.count == SecretSources.maxListed && all.unlisted == 0)
    }

    /// A browser's CSV and a Bitwarden export of more sign-ins than the sheet lists, with two keys last: the sheet
    /// lists both keys, ticked, and the website passwords in the file's order up to the most it lists; the rest are
    /// counted, and the footer says how many. An agent's answer counts every row found, and a check against the vault
    /// keeps the count.
    @Test func websitePasswordsPastTheListAreCountedNotListed() {
        let keys: [String] = [F.openAI, F.pinecone]
        let sites: Int = SecretSources.maxListed + 200
        var csv: [UInt8] = Self.browserCSV(sites: sites, keys: keys)
        var json: [UInt8] = Self.bitwardenExport(sites: sites, keys: keys)
        let browser: SourceReport = SecretSources.read(&csv, name: "Chrome Passwords.csv")
        let bitwarden: SourceReport = SecretSources.read(&json, name: "bitwarden.json")
        #expect(browser.exportedBy == "Chrome" && bitwarden.format == .bitwarden)
        let unlisted: Int = sites + keys.count - SecretSources.maxListed
        for report in [browser, bitwarden] {
            #expect(report.unreadable == nil)
            #expect(report.rows.count == SecretSources.maxListed && report.unlisted == unlisted)
            let ticked: [SourceRow] = report.rows.filter { (row: SourceRow) -> Bool in row.ticked }
            #expect(ticked.count == keys.count)
            #expect(Array(report.rows.suffix(keys.count)).allSatisfy { (row: SourceRow) -> Bool in row.ticked })
            #expect(report.checked(against: []).unlisted == unlisted)
        }
        let lastSite: Int = SecretSources.maxListed - keys.count - 1
        #expect(browser.rows[lastSite].link?.url.host == "site\(lastSite).example.com")
        let most: String = SecretSources.maxListed.formatted()
        let footer = "\(unlisted) more website passwords aren\u{2019}t listed: Next Term lists \(most) at most."
        #expect(browser.footer == footer)
        let outcome = SecretSources.CopyInOutcome.imported(["SITE_KEY"], replaced: [], from: browser)
        let answer: [String: Any] = SecretSources.answer(for: outcome)
        #expect(answer["found"] as? Int == sites + keys.count)
        #expect(answer["not_imported"] as? Int == sites + keys.count - 1)
        #expect(csv.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
        var one: [UInt8] = Self.browserCSV(sites: SecretSources.maxListed + 1, keys: [])
        let past: SourceReport = SecretSources.read(&one, name: "Chrome Passwords.csv")
        #expect(past.unlisted == 1)
        let single = "1 more website password isn\u{2019}t listed: Next Term lists \(most) at most."
        #expect(past.footer == single)
    }

    /// Show Them lists the first values that aren't keys, a line each, then how many more: a crafted file may hold tens
    /// of thousands, and the sheet lays the text out on the main thread.
    @Test func showThemListsTheFirstValuesThatArentKeys() {
        let lines: [String] = (0..<30).map { (number: Int) -> String in "FLAG_\(number)=true" }
        let report: SourceReport = F.report(lines.joined(separator: "\n") + "\n", name: ".env")
        #expect(report.rows.isEmpty && report.notKeys.count == 30)
        let shown: [String] = report.notKeysText(limit: 20).components(separatedBy: "\n")
        #expect(shown.count == 21)
        #expect(shown.first == "FLAG_0, line 1: A setting")
        #expect(shown.last == "And 10 more.")
        let all: [String] = report.notKeysText(limit: 30).components(separatedBy: "\n")
        #expect(all.count == 30 && all.last == "FLAG_29, line 30: A setting")
        #expect(SourceReport.notKeysShown < SecretSources.maxListed)
    }

    /// The names more than one ticked row has: the sheet marks each such row, in one pass over the names however many
    /// rows it lists.
    @Test func tickedRowsThatShareANameAreFoundInOnePass() {
        let names: [String] = ["A_KEY", "B_KEY", "A_KEY", "C_KEY", "A_KEY", "B_KEY"]
        #expect(SecretCopyIn.repeatedNames(names) == ["A_KEY", "B_KEY"])
        #expect(SecretCopyIn.repeatedNames(["A_KEY", "C_KEY"]).isEmpty)
        #expect(SecretCopyIn.repeatedNames([]).isEmpty)
        let many: [String] = (0..<50_000).map { (number: Int) -> String in "KEY_\(number)" } + ["KEY_7", "KEY_49999"]
        var repeated: Set<String> = []
        let elapsed: Duration = ContinuousClock().measure { repeated = SecretCopyIn.repeatedNames(many) }
        #expect(elapsed < .seconds(2), "\(elapsed)")
        #expect(repeated == ["KEY_7", "KEY_49999"])
    }
}
