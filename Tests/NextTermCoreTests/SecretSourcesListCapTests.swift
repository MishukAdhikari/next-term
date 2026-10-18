import Foundation
import Testing
@testable import NextTermCore

/// The copy sheet builds a row for each key a report lists, on the main thread, so a report lists no more than the sheet
/// shows: a file of more keys, picked, piped in or named by an agent, is reported as too many, as the MCP-config import
/// reports one, and no row of it reaches the sheet. The sheet finds ticked rows that share a name in one pass. Every
/// value here is made up.
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

    @Test func aFileOfAsManyKeysAsTheSheetListsIsListed() {
        let report: SourceReport = F.report(Self.env(SecretSources.maxListed), name: ".env")
        #expect(report.unreadable == nil)
        #expect(report.rows.count == SecretSources.maxListed)
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked })
    }

    @Test func aFileOfMoreKeysThanTheSheetListsIsReportedAsTooMany() {
        var data: [UInt8] = Array(Self.env(SecretSources.maxListed + 1).utf8)
        let report: SourceReport = SecretSources.read(&data, name: ".env", folder: "rag-api")
        #expect(report.unreadable == .tooManyToList)
        #expect(report.rows.isEmpty && report.notKeys.isEmpty)
        #expect(report.format == .env && report.purpose == "From .env in rag-api")
        #expect(data.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
        // What the sheet says, and what an agent's import_secrets hears: a class, no name or count from the file.
        let sentence: String? = report.unreadable?.sentence
        #expect(sentence == "It holds more than 1,000 keys, more than Next Term lists. Import from a smaller file.")
        let answer: [String: Any] = SecretSources.answer(for: .unreadable(.tooManyToList))
        #expect(answer["status"] as? String == "unreadable")
        #expect(answer["reason"] as? String == "too many keys to list")
    }

    /// Keys piped in (`nxtrm secret import -`) are read as a file is, and a password manager's export, whose rows the
    /// sheet lists too, is capped alike and still says which app wrote it.
    @Test func keysPipedInAndAnExportAreCappedAlike() {
        var piped: [UInt8] = Array(Self.env(SecretSources.maxListed + 1).utf8)
        let fromPipe: SourceReport = SecretSources.read(&piped, name: "standard input", format: .env)
        #expect(fromPipe.unreadable == .tooManyToList && fromPipe.rows.isEmpty)
        var lines: [String] = ["name,url,username,password,note"]
        for number in 0...SecretSources.maxListed {
            let site = "site\(number).example.com"
            lines.append("\(site),https://\(site)/login,made-up-user,\(Self.value(number)),")
        }
        var csv: [UInt8] = Array((lines.joined(separator: "\n") + "\n").utf8)
        let browser: SourceReport = SecretSources.read(&csv, name: "Chrome Passwords.csv")
        #expect(browser.unreadable == .tooManyToList && browser.rows.isEmpty)
        #expect(browser.format == .csv && browser.exportedBy == "Chrome")
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
