import Foundation

/// The user's shortcuts as `shortcuts list --show-identifiers` prints them, one "Name (IDENTIFIER)" a line, and what a
/// run of one says when it ends. Pure: nothing here starts the command. A shortcut is run by its identifier, so a
/// renamed one still runs and a deleted one fails; its input comes from standard input.
public enum ShortcutList {
    public struct Shortcut: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// How a run ended.
    public enum Result: Equatable, Sendable {
        case finished(Int32)
        case timedOut
        /// The user pressed Cancel while it ran.
        case stopped
        case couldntStart
    }

    /// The line a run ends with, and whether the task was sent.
    public enum Line: Equatable, Sendable {
        case sent(String)
        case failed(String)
        case stopped(String)
    }

    public static let command = "/usr/bin/shortcuts"
    public static let listArguments = ["list", "--show-identifiers"]
    /// How long a run may take before it is stopped.
    public static let limit: TimeInterval = 60

    public static let goneLine = "The shortcut is gone. Choose another in Settings › Tasks."
    public static let stoppedLine = "The shortcut was stopped. Nothing more was sent."
    /// Shown once, when a shortcut is first chosen.
    public static let note = "Your shortcut receives the task’s text as its input. Use “Shortcut Input” in it, "
        + "for example with Add New Reminder."

    /// Each line's last parenthesised identifier is the id and the rest the name. A line without one, with a lower-case
    /// or short one, with text after it, with no name or with control characters in its name is skipped.
    public static func parse(_ output: String) -> [Shortcut] {
        var found: [Shortcut] = []
        for raw in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { continue }
            let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
            let id = String(inner)
            guard isIdentifier(id) else { continue }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            let hasControl = name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            guard !name.isEmpty, !hasControl else { continue }
            found.append(Shortcut(id: id, name: name))
        }
        return found
    }

    /// Whether the shortcut `id` is still in `list`.
    public static func isListed(_ id: String, in list: [Shortcut]) -> Bool {
        list.contains { $0.id == id }
    }

    /// The run's arguments, or nil unless `id` is an identifier: never a name or an option.
    public static func runArguments(id: String) -> [String]? {
        guard UUID(uuidString: id) != nil else { return nil }
        return ["run", id, "--input-path", "-"]
    }

    /// The name is the user's own label, masked like every other name a line shows.
    public static func line(_ result: Result, name raw: String,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> Line {
        let name = mask(raw)
        switch result {
        case .finished(0): return .sent("Sent to the shortcut “\(name)”.")
        case .stopped: return .stopped(stoppedLine)
        case .finished, .timedOut, .couldntStart:
            return .failed("The shortcut “\(name)” didn’t finish. Nothing more was sent.")
        }
    }

    /// The task's title, which a shortcut's input starts with on a line of its own.
    public static func title(ofInput input: String) -> String {
        let first = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        return first.map(String.init) ?? input
    }

    /// The upper-case 8-4-4-4-12 form the command prints.
    static func isIdentifier(_ text: String) -> Bool {
        guard text.count == 36, UUID(uuidString: text) != nil else { return false }
        return text == text.uppercased()
    }
}
