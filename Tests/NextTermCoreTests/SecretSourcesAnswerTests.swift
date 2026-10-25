import Foundation
import Testing
@testable import NextTermCore

/// What an agent that asked for an import learns: the names the user imported and counts, never a value, where a
/// value was found, or a name the user didn't import. Every value here is made up.
@Suite struct SecretSourcesAnswerTests {
    typealias F = SecretSourcesFixtures

    private static func json(_ answer: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func anImportAnswersNamesAndCountsOnly() throws {
        let now = Date()
        let report = F.report(F.shopWebEnv(now: now), name: ".env.local", folder: "shop-web",
                              stored: ["STRIPE_SECRET_KEY"], now: now)
        let outcome = SecretSources.CopyInOutcome.imported(["SUPABASE_SECRET_KEY", "OPENAI_API_KEY"], replaced: [],
                                                           from: report)
        let answer = SecretSources.answer(for: outcome)
        let expected: [String: Any] = [
            "status": "imported", "imported": ["SUPABASE_SECRET_KEY", "OPENAI_API_KEY"], "replaced": [String](),
            "found": 6, "not_imported": 4, "format": "env",
        ]
        #expect(Self.json(answer) == Self.json(expected))
    }

    @Test func otherOutcomesCarryOnlyTheirStatusAndAFixedNote() {
        let declined = SecretSources.answer(for: .declined)
        #expect(declined["status"] as? String == "declined")
        #expect(Set(declined.keys) == ["status", "note"])
        let nothing = SecretSources.answer(for: .nothingFound(format: .json))
        #expect(nothing["status"] as? String == "nothing_found")
        #expect(nothing["format"] as? String == "json")
        let unreadable = SecretSources.answer(for: .unreadable(.notJSON))
        #expect(unreadable["status"] as? String == "unreadable")
        #expect(unreadable["reason"] as? String == SecretSources.Unreadable.notJSON.reasonClass)
    }

    /// Random reports, random choices: the answer never holds a value's bytes, a row's place or a name left out.
    @Test func noValuePlaceOrUnimportedNameReachesTheAnswer() {
        var generator = SystemRandomNumberGenerator()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        func word(_ from: [Character], _ count: Int) -> String {
            String((0..<count).map { (_: Int) -> Character in from.randomElement(using: &generator) ?? "A" })
        }
        for _ in 0..<200 {
            let count = Int.random(in: 1...12, using: &generator)
            var lines: [String] = []
            for _ in 0..<count {
                let name = "N" + word(letters, 12) + "_KEY"
                let value = "Kq7" + word(alphabet, 30) + "z9K4"
                lines.append(Bool.random(using: &generator) ? "\(name)=\(value)" : "\(name): \(value)")
            }
            let report = F.report(lines.joined(separator: "\n"), name: ".env", folder: "proj")
            let chosen = report.rows.filter { (_: SourceRow) -> Bool in Bool.random(using: &generator) }
            let names = chosen.map(\.name)
            let replaced = names.filter { (_: String) -> Bool in Bool.random(using: &generator) }
            let text = Self.json(SecretSources.answer(for: .imported(names, replaced: replaced, from: report)))
            for row in report.rows {
                let value = row.value.utf8String() ?? ""
                #expect(!text.contains(value))
                #expect(!text.contains(String(value.suffix(4))))
                #expect(!text.contains(row.place))
                if !names.contains(row.name) { #expect(!text.contains(row.name)) }
            }
        }
    }

    /// Random JSON reports: a flat key, the same name in several sections, an array's strings and a name/value pair,
    /// with random choices. The same holds; a name is looked for in quotes, as the section rule makes one name another's
    /// head.
    @Test func noValuePlaceOrUnimportedNameReachesTheAnswerFromJSON() {
        var generator = SystemRandomNumberGenerator()
        let lower = Array("abcdefghijklmnopqrstuvwxyz")
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        func word(_ from: [Character], _ count: Int) -> String {
            String((0..<count).map { (_: Int) -> Character in from.randomElement(using: &generator) ?? "a" })
        }
        func value() -> String { "Kq7" + word(alphabet, 30) + "z9K4" }
        for _ in 0..<100 {
            var members: [String] = []
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                let key: String = word(lower, 10)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: members.append(#""\#(key)_api_key": "\#(value())""#)
                case 1: members.append(#""\#(key)": {"openaiApiKey": "\#(value())"}"#)
                case 2: members.append(#""\#(key)": ["\#(value())", "\#(value())"]"#)
                default: members.append(#""\#(key)": [{"name": "\#(key)_TOKEN", "value": "\#(value())"}]"#)
                }
            }
            let report = F.report("{" + members.joined(separator: ", ") + "}", name: "keys.json", folder: "proj")
            let chosen = report.rows.filter { (_: SourceRow) -> Bool in Bool.random(using: &generator) }
            let names = chosen.map(\.name)
            let replaced = names.filter { (_: String) -> Bool in Bool.random(using: &generator) }
            let text = Self.json(SecretSources.answer(for: .imported(names, replaced: replaced, from: report)))
            for row in report.rows {
                let value = row.value.utf8String() ?? ""
                #expect(!value.isEmpty && !text.contains(value))
                #expect(!text.contains(String(value.suffix(4))))
                for place in [row.place] + row.alsoAt { #expect(!text.contains(place)) }
                if !names.contains(row.name) { #expect(!text.contains("\"" + row.name + "\"")) }
            }
        }
    }
}
