import Foundation

/// The word left of the cursor in a server tab whose shell has no hook (RemoteCompletion), read off the screen.
/// Only a plain word is read: no quotes, backslashes, `$`, backticks, globs or anything else a shell would read
/// as more than its letters, and no quote or backslash before it on its line, so the name on screen is the name
/// the shell sees. What it lists comes from the command before it: folders after `cd` and the like, files and
/// folders after `ls` and the like, and files and folders for any word that looks like a path. Anything else is
/// nil: the shell's own Tab.
public struct ScreenWord: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folders
        case paths
    }

    public var kind: Kind
    /// The line left of the word: the prompt and the command so far. A list stays open only while it is the same.
    public var before: String
    /// The word as on screen.
    public var word: String
    /// The word up to and including its last `/` ("" when there is none): the folder to list, as typed.
    public var folder: String
    /// The name typed after it.
    public var typed: String

    /// Characters that make a word more than its letters, anywhere in it.
    static let special: Set<Character> = ["'", "\"", "\\", "$", "`", "*", "?", "[", "]", "{", "}", "(", ")", "<", ">", ";", "&", "|",
                                          "!", "#", "^"]
    /// Words that end one command and start the next.
    static let separators: Set<String> = ["|", "||", "|&", "&&", "&", ";", "(", "{", "then", "do", "else"]

    /// Reads the text left of the cursor on its line (wrapped rows joined). nil: not a plain word after a
    /// command Next Term lists for, nor a path.
    public static func read(_ left: String) -> ScreenWord? {
        let start = left.lastIndex(where: { $0 == " " }).map { left.index(after: $0) } ?? left.startIndex
        // A word with no blank before it is the prompt's own text.
        guard start > left.startIndex else { return nil }
        let word = String(left[start...])
        let before = String(left[..<start])
        guard isPlain(word) else { return nil }
        let folder = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
        let typed = String(word.dropFirst(folder.count))
        let looksLikePath = word.contains("/") || word.hasPrefix(".")
        let kind: Kind
        switch command(before) {
        case .blocked: return nil
        case .lists(let listed): kind = listed
        case .other:
            guard looksLikePath else { return nil }
            kind = .paths
        }
        return ScreenWord(kind: kind, before: before, word: word, folder: folder, typed: typed)
    }

    /// The same completion with the line as it is now: nil when the line left of the word changed, the word left
    /// its folder, or it is no longer plain.
    public func next(_ left: String) -> ScreenWord? {
        guard let now = Self.read(left), now.before == before, now.folder == folder else { return nil }
        return now
    }

    /// A word whose letters are all it says: no blank, control or special character, no option, and `~` only as
    /// a leading `~/`.
    static func isPlain(_ word: String) -> Bool {
        if word.hasPrefix("-") || word.hasPrefix("=") { return false }
        if word.hasPrefix("~"), !word.hasPrefix("~/") { return false }
        if word.dropFirst().contains("~") { return false }
        for scalar in word.unicodeScalars where ShellQuote.isControl(scalar) || WordQuote.isHidden(scalar) { return false }
        return !word.contains { special.contains($0) || $0.isWhitespace }
    }

    enum Command: Equatable {
        /// A folder or path command: what it lists.
        case lists(Kind)
        /// Another command, or none: only a word that looks like a path is listed.
        case other
        /// A quote, a backslash or a backtick on the way could reach the word.
        case blocked
    }

    /// The last folder or path command before the word, back to a separator. A quote, a backslash or a backtick
    /// anywhere before it blocks: a separator may be inside the quote, and the screen doesn't say where the prompt
    /// ends, so one in the prompt counts too, and Tab is the shell's own.
    static func command(_ before: String) -> Command {
        if before.contains(where: { "'\"\\`".contains($0) }) { return .blocked }
        for token in before.split(separator: " ").reversed() {
            if separators.contains(String(token)) { break }
            let name = (String(token) as NSString).lastPathComponent
            if CompletionContext.folderCommands.contains(name) { return .lists(.folders) }
            if CompletionContext.pathCommands.contains(name) { return .lists(.paths) }
        }
        return .other
    }
}
