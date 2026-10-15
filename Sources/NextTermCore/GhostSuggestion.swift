import Foundation

/// A suggestion while typing: a command you ran that starts with what is typed. What shows after the cursor is the rest of
/// it (`remainder`); → takes it all, in the command's own case (`acceptAll`), and ⌥→ one word (`acceptWord`).
public struct GhostSuggestion: Equatable, Sendable {
    /// The line as typed.
    public let typed: String
    /// The command it is the start of.
    public let command: String

    /// nil unless `command` is longer than `typed` and starts with it: case-blind unless what was typed has a capital (smart
    /// case, ASCII letters only, as the record matches).
    public init?(typed: String, command: String) {
        guard !typed.isEmpty, Self.starts(command, with: typed), command.utf8.count > typed.utf8.count else { return nil }
        self.typed = typed
        self.command = command
    }

    static func starts(_ command: String, with typed: String) -> Bool {
        let line = Array(command.utf8), prefix = Array(typed.utf8)
        guard line.count >= prefix.count else { return false }
        let exact = prefix.contains { $0 >= 0x41 && $0 <= 0x5A }
        for i in prefix.indices {
            let x = line[i], y = prefix[i]
            if x == y { continue }
            if exact || CommandHistory.fold(x) != CommandHistory.fold(y) { return false }
        }
        return true
    }

    /// What shows after the cursor: the command past what was typed (the same length in bytes, as only ASCII letters fold).
    public var remainder: String { String(decoding: command.utf8.dropFirst(typed.utf8.count), as: UTF8.self) }

    /// The line → and End make: the whole command, in its own case where the case typed differed.
    public var acceptAll: String { command }

    /// The line ⌥→ makes: the command up to the end of the remainder's next word.
    public var acceptWord: String {
        let word = Self.nextWord(remainder)
        return String(decoding: command.utf8.prefix(typed.utf8.count + word.utf8.count), as: UTF8.self)
    }

    /// The next word of `remainder`: its leading blanks, then at least one character, up to and including the next `/`, or
    /// up to the next blank.
    public static func nextWord(_ remainder: String) -> String {
        var word = String.UnicodeScalarView()
        var scalars = remainder.unicodeScalars.makeIterator()
        var started = false
        while let scalar = scalars.next() {
            let blank = scalar == " " || scalar == "\t"
            if blank, started { break }
            word.append(scalar)
            if !blank {
                if started, scalar == "/" { break }
                started = true
            }
        }
        return String(word)
    }

    /// The same suggestion after `typed` grew by characters its remainder starts with (typing through it): nil when it
    /// didn't, or when a capital typed after a case-blind match changes how it matches (it is asked for again).
    public func typedThrough(_ newTyped: String) -> GhostSuggestion? {
        guard newTyped.utf8.count > typed.utf8.count, newTyped.utf8.starts(with: typed.utf8) else { return nil }
        let added = String(decoding: newTyped.utf8.dropFirst(typed.utf8.count), as: UTF8.self)
        guard remainder.utf8.starts(with: added.utf8) else { return nil }
        let caseBlind = !typed.utf8.contains { $0 >= 0x41 && $0 <= 0x5A }
        if caseBlind, added.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) { return nil }
        return GhostSuggestion(typed: newTyped, command: command)
    }
}

/// Fitting a suggestion into the cells left on its row.
public enum GhostClip {
    public static let ellipsis = "…"

    /// `remainder` as it fits in `available` cells: whole, or cut with "…" in the last cell, never splitting a character
    /// (a wide one at the cut is left out). nil when not even one character and the "…" fit.
    public static func fit(_ remainder: String, available: Int, width: (Character) -> Int = cells) -> String? {
        guard available > 0, !remainder.isEmpty else { return nil }
        let total = remainder.reduce(0) { $0 + width($1) }
        if total <= available { return remainder }
        guard available >= 2 else { return nil }
        var used = 0
        var kept = ""
        for character in remainder {
            let cells = width(character)
            if used + cells > available - 1 { break }
            used += cells
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept + ellipsis
    }

    /// The cells a character takes, as the terminal shows it (GhostScreen.cells); one for anything it shows otherwise.
    public static func cells(_ character: Character) -> Int { GhostScreen.cells(String(character)) ?? 1 }
}
