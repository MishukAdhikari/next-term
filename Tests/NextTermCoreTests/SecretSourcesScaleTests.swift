import Foundation
import Testing
@testable import NextTermCore

/// What a large or crafted file costs the import: a `.env` past the editor's size, a file past the values read, and the
/// same name in thousands of sections, each refused or read in a few seconds. Every value here is made up.
@Suite struct SecretSourcesScaleTests {
    typealias F = SecretSourcesFixtures

    /// A made-up value of 30 characters, different for each number: its tail in base 36 after dashes, which no digit
    /// of it is.
    private static func value(_ number: Int) -> String {
        let tail = String(number, radix: 36)
        return "Qm4Rt8Vx2Bn6Lp9Zc3Hd7" + String(repeating: "-", count: 9 - tail.count) + tail
    }

    @Test func theSameNameInThousandsOfSectionsIsNamedInOnePass() {
        let count = 12_000
        let rows: [SourceRow] = (0..<count).map { (number: Int) -> SourceRow in
            SourceRow(name: "OPENAI_API_KEY", text: Self.value(number), kind: "OpenAI key",
                      place: "s\(number).OPENAI_API_KEY", line: nil, ticked: true, scope: "s\(number)")
        }
        var named: [SourceRow] = []
        let elapsed: Duration = ContinuousClock().measure { named = SecretSources.sectioned(rows) }
        #expect(elapsed < .seconds(5), "\(elapsed)")
        #expect(named.count == count)
        #expect(Set(named.map(\.name)).count == count)
        #expect(named.first?.name == "OPENAI_API_KEY_S0")
    }

    @Test func aDotEnvPastTheEditorsSizeIsRefusedUnread() {
        var data: [UInt8] = Array(String(repeating: "K=\"x\n", count: EnvFile.maxSize / 5 + 1).utf8)
        var report: SourceReport?
        let elapsed: Duration = ContinuousClock().measure { report = SecretSources.read(&data, name: ".env") }
        #expect(elapsed < .seconds(2), "\(elapsed)")
        #expect(report?.unreadable == .envTooLarge)
        #expect(report?.unreadable?.reasonClass == "too large")
        #expect(data.allSatisfy { (byte: UInt8) -> Bool in byte == 0 })
    }

    @Test func aFilePastTheValuesReadStopsReadingThere() {
        // 10 bytes a line: past the values read, under the editor's size.
        let lines = String(repeating: "A=Qm4Rt8X\n", count: SecretSources.maxValues + 2)
        #expect(lines.utf8.count <= EnvFile.maxSize)
        #expect(SecretSources.envFound(lines, file: ".env").count == SecretSources.maxValues + 1)
        #expect(F.report(lines, name: ".env").unreadable == .tooMany)
        // A quote left open on each line has the reader look 200 lines ahead from each: refused before it reads.
        let unclosed = String(repeating: "K=\"x\n", count: SecretSources.maxValues + 1)
        var report: SourceReport?
        let elapsed: Duration = ContinuousClock().measure { report = F.report(unclosed, name: ".env") }
        #expect(elapsed < .seconds(2), "\(elapsed)")
        #expect(report?.unreadable == .tooMany)
    }

    @Test func aFiveMegabyteJSONFileIsRefusedInSeconds() {
        var entries: [String] = []
        var size = 2
        var number = 0
        while size < SecretSources.maxBytes - 100 {
            let entry = #"{"OPENAI_API_KEY":""# + Self.value(number) + #""}"#
            entries.append(entry)
            size += entry.utf8.count + 1
            number += 1
        }
        var data: [UInt8] = Array(("[" + entries.joined(separator: ",") + "]").utf8)
        #expect(data.count <= SecretSources.maxBytes)
        var report: SourceReport?
        let elapsed: Duration = ContinuousClock().measure { report = SecretSources.read(&data, name: "keys.json") }
        #expect(elapsed < .seconds(10), "\(elapsed)")
        #expect(report?.unreadable == .tooMany)
    }
}
