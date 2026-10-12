import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A mask made from stored values' marks, as the app makes it. Never `SecretMask.current`: tests run in parallel.
private func storedMask(_ values: [String]) -> SecretMask {
    let key = SymmetricKey(size: .bits256)
    return SecretMask(key: key, marks: values.flatMap { SecretMask.marks(for: SecretBytes(utf8: $0), key: key) })
}

/// A random value no pattern catches.
private let stored = "Rk7vQp2xLm9nWz4cTb8hYq3s"

/// Whether `text` shows any 5 characters in a row of `value`.
private func showsPart(of value: String, in text: String) -> Bool {
    let characters = Array(value)
    return (0...(characters.count - 5)).contains { text.contains(String(characters[$0..<$0 + 5])) }
}

/// A screen of `columns` columns: each row's text and whether it continues the row above (a wrap).
private struct Screen {
    var rows: [(text: String, wrapped: Bool)]
    var read = Set<Int>()

    mutating func masked(_ mask: SecretMask, _ window: ClosedRange<Int>, columns: Int) -> [String] {
        var asked = Set<Int>()
        let rows = rows
        let result = mask.mask(window: window, columns: columns,
                               wrapped: { row in asked.insert(row); return rows.indices.contains(row) && rows[row].wrapped },
                               text: { row in asked.insert(row); return rows.indices.contains(row) ? rows[row].text : "" })
        read = asked
        return result
    }
}

@Suite struct SecretMaskWindowTests {
    /// A 10-column screen where `printenv` printed `stored` (24 characters) across four rows.
    fileprivate func screen() -> Screen {
        let value = Array(stored)
        return Screen(rows: [
            ("$ printenv", false),
            ("K: " + String(value[0..<7]), false),
            (String(value[7..<17]), true),
            (String(value[17..<24]) + " ok", true),
            ("$", false),
        ])
    }

    /// read_tab's window can start on a row that continues a line wrapped above it: the rows above are masked with it,
    /// so the key's tail is never shown.
    @Test func aWindowStartingInsideAWrappedKeyShowsNoPartOfIt() {
        let m = storedMask([stored])
        var s = screen()
        // The rows alone, as before: the key's start is above them, so nothing matches.
        #expect(showsPart(of: stored, in: m.mask(rows: s.rows[2...4].map(\.text)).joined()))
        let masked = s.masked(m, 2...4, columns: 10)
        #expect(masked == ["•••", "••• ok", "$"])
        #expect(!showsPart(of: stored, in: masked.joined()))
        #expect(s.masked(m, 3...4, columns: 10) == ["••• ok", "$"])
    }

    /// A window ending inside a key that wraps on below it is masked with the rows the wrap joins to it.
    @Test func aWindowEndingInsideAWrappedKeyShowsNoPartOfIt() {
        let m = storedMask([stored])
        var s = screen()
        let masked = s.masked(m, 0...2, columns: 10)
        #expect(masked == ["$ printenv", "K: •••", "•••"])
        #expect(!showsPart(of: stored, in: masked.joined()))
    }

    /// The walk past the window is bounded by the longest form over the width, even in a line wrapped thousands of
    /// times; with no marks nothing outside the window is read.
    @Test func theWalkIsBounded() {
        let m = storedMask([stored])
        var s = Screen(rows: (0..<20_000).map { ("row \($0) xxxx", $0 > 0) })
        let window = 9_000...9_009
        #expect(s.masked(m, window, columns: 10).count == 10)
        let reach = m.longest / 10 + 2
        #expect(m.longest >= stored.count && (s.read.min() ?? 0) >= window.lowerBound - reach)
        #expect((s.read.max() ?? .max) <= window.upperBound + reach + 1)
        var plain = screen()
        #expect(plain.masked(.empty, 2...4, columns: 10) == plain.rows[2...4].map(\.text))
        #expect(plain.read.isSubset(of: Set(2...4)))
    }
}
