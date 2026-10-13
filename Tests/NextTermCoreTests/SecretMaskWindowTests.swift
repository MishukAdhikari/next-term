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

/// A screen's rows, and which of them the last mask read.
private struct Screen {
    var rows: [String]
    var read = Set<Int>()

    mutating func masked(_ mask: SecretMask, _ window: ClosedRange<Int>) -> [String] {
        var asked = Set<Int>()
        let rows = rows
        let result = mask.mask(window: window, rows: 0...(rows.count - 1)) { row in
            asked.insert(row)
            return rows[row]
        }
        read = asked
        return result
    }
}

@Suite struct SecretMaskWindowTests {
    /// A 10-column screen where `printenv` printed `stored` (24 characters) across four rows: the terminal's own wrap, or
    /// an agent UI's newlines, the rows the same.
    fileprivate func screen() -> Screen {
        let value = Array(stored)
        return Screen(rows: ["$ printenv", "K: " + String(value[0..<7]), String(value[7..<17]), String(value[17..<24]) + " ok", "$"])
    }

    /// read_tab's window can start on a row that holds the tail of a key whose start is above it: the rows above are
    /// masked with it, so the key's tail is never shown.
    @Test func aWindowStartingInsideAKeyShowsNoPartOfIt() {
        let m = storedMask([stored])
        var s = screen()
        // The rows alone, as before: the key's start is above them, so nothing matches.
        #expect(showsPart(of: stored, in: m.mask(rows: Array(s.rows[2...4])).joined()))
        let masked = s.masked(m, 2...4)
        #expect(masked == ["•••", "••• ok", "$"])
        #expect(!showsPart(of: stored, in: masked.joined()))
        #expect(s.masked(m, 3...4) == ["••• ok", "$"])
    }

    /// A window ending inside a key that goes on below it is masked with the rows below.
    @Test func aWindowEndingInsideAKeyShowsNoPartOfIt() {
        let m = storedMask([stored])
        var s = screen()
        let masked = s.masked(m, 0...2)
        #expect(masked == ["$ printenv", "K: •••", "•••"])
        #expect(!showsPart(of: stored, in: masked.joined()))
        #expect(s.masked(m, 2...2) == ["•••"])
    }

    /// An agent UI that wraps a key to its own box, narrower than the terminal, puts it on more rows than the terminal's
    /// width would, with newlines: a window starting on its second row, or its last, is masked with all the rows above
    /// that hold the rest.
    @Test func aKeyHardWrappedNarrowerThanTheTerminalShowsNoPartOfIt() {
        let m = storedMask([stored])
        let value = Array(stored)
        let pieces = stride(from: 0, to: value.count, by: 5).map { String(value[$0..<min($0 + 5, value.count)]) }
        var s = Screen(rows: ["$ cat key"] + pieces + ["$"])
        let last = pieces.count
        #expect(s.masked(m, 2...(last + 1)) == Array(repeating: "•••", count: last - 1) + ["$"])
        let masked = s.masked(m, last...(last + 1))
        #expect(masked == ["•••", "$"])
        #expect(!showsPart(of: stored, in: s.masked(m, (last - 1)...(last + 1)).joined()))
    }

    /// The walk past the window stops after the bytes the longest form can have outside it, and a blank row counts as
    /// one; with no marks nothing outside the window is read, and no row outside the screen ever is.
    @Test func theWalkIsBounded() {
        let m = storedMask([stored])
        #expect(m.longest >= stored.count)
        var s = Screen(rows: (0..<20_000).map { "row \($0) xxxx" }) // 13 bytes each near the window
        let window = 9_000...9_009
        #expect(s.masked(m, window).count == 10)
        let reach = (m.longest - 1 + 12) / 13
        #expect((s.read.min() ?? 0) >= window.lowerBound - reach && (s.read.max() ?? .max) <= window.upperBound + reach)
        var blank = Screen(rows: Array(repeating: "", count: 20_000))
        #expect(blank.masked(m, window) == Array(repeating: "", count: 10))
        #expect(blank.read.count == window.count + 2 * (m.longest - 1))
        var edge = screen()
        #expect(edge.masked(m, 0...1) == ["$ printenv", "K: •••"])
        #expect(edge.read.isSubset(of: Set(0...4)))
        var plain = screen()
        #expect(plain.masked(.empty, 2...4) == Array(plain.rows[2...4]))
        #expect(plain.read == Set(2...4))
    }
}
