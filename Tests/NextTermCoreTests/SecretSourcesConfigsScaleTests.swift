import Foundation
import Testing
@testable import NextTermCore

/// What a large or crafted TOML or YAML file costs the import: each is read or refused in seconds. Every value here is
/// made up.
@Suite struct SecretSourcesConfigsScaleTests {
    typealias T = SecretSourcesConfigsTests

    static func timed(_ text: String, name: String) -> (report: SourceReport, elapsed: Duration) {
        var report: SourceReport?
        let elapsed: Duration = ContinuousClock().measure { report = T.read(text, name: name) }
        return (report ?? T.read("", name: name), elapsed)
    }

    @Test func aFileOfBlankLinesAndOnePastTheSizeAreQuick() {
        let blank = String(repeating: "\n", count: SecretSources.configMaxBytes)
        let read = Self.timed(blank, name: "blank.yaml")
        #expect(read.elapsed < .seconds(5), "\(read.elapsed)")
        #expect(read.report.unreadable == nil && read.report.rows.isEmpty)
        let past = Self.timed(blank + "\n", name: "past.yaml")
        #expect(past.report.unreadable == .configTooLarge && past.elapsed < .seconds(2))
    }

    @Test func valuesPastTheLimitAreRefusedInSeconds() {
        let count = SecretSources.maxValues + 10
        var lines: [String] = []
        lines.reserveCapacity(count)
        for number in 0..<count { lines.append("k\(number): v\(number)") }
        let read = Self.timed(lines.joined(separator: "\n"), name: "many.yaml")
        #expect(read.elapsed < .seconds(10), "\(read.elapsed)")
        #expect(read.report.unreadable == .tooMany)
    }

    @Test func aliasesThatWouldMultiplyAreNeverFollowed() {
        var lines: [String] = ["a0: &a0 [x, x, x, x, x, x, x, x, x, x]"]
        for level in 1..<40 {
            let refs: String = Array(repeating: "*a\(level - 1)", count: 10).joined(separator: ", ")
            lines.append("a\(level): &a\(level) [\(refs)]")
        }
        let read = Self.timed(lines.joined(separator: "\n"), name: "laughs.yaml")
        #expect(read.elapsed < .seconds(2), "\(read.elapsed)")
        #expect(read.report.unreadable == nil)
        #expect(!read.report.rows.isEmpty)
        #expect(read.report.rows.allSatisfy { (row: SourceRow) -> Bool in row.refusal == .unreadablePart })
    }

    @Test func manyArraysOfTablesAreLinedUpInOnePass() {
        var lines: [String] = []
        for number in 0..<12_000 {
            lines.append("[[servers]]")
            lines.append("[[servers.env\(number)]]")
            lines.append("TOKEN = \"v\(number)\"")
        }
        let read = Self.timed(lines.joined(separator: "\n"), name: "arrays.toml")
        #expect(read.elapsed < .seconds(10), "\(read.elapsed)")
        #expect(read.report.unreadable == nil)
        #expect(read.report.notKeys.count == 12_000)
        let last = SecretSources.tomlLines(lines.suffix(6).joined(separator: "\n"))
        #expect(last[SecretSources.tomlKey(["servers", "[1]", "env11999", "[0]", "TOKEN"])] == 6)
    }
}
