import Foundation

/// What Tab completes, read from zsh's own words (CompletionProtocol.TabReport): which folder to list,
/// folders only or files too, the part of the name typed so far, and how the word around it is quoted.
/// zsh split the line; nothing here re-lexes it or evaluates anything. nil means "step back": the shell's
/// own Tab answers.
public struct CompletionContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `cd` and the like: folders only.
        case folders
        /// Files and folders.
        case paths
    }

    public var kind: Kind
    /// The folder to list, absolute.
    public var folder: String
    /// The name typed so far, unquoted: what candidates match.
    public var typed: String
    /// The word as typed up to the name (`--file=`, `src/`, `~/`, `"My Folder/`), kept as it is.
    public var keep: String
    /// The quote open where the name starts.
    public var quote: WordQuote.Context
    /// The word as typed when this was read, and the folder relative paths start from.
    public var word: String
    public var directory: String
    /// The `~/` or `$NAME/` head as typed, and what it names.
    public var head: String
    public var resolvedHead: String

    /// Commands whose arguments are folders.
    public static let folderCommands: Set<String> = ["cd", "chdir", "pushd", "rmdir", "mkdir"]
    /// Commands whose arguments are files and folders.
    public static let pathCommands: Set<String> = [
        "ls", "cat", "less", "more", "head", "tail", "open", "rm", "cp", "mv", "ln", "touch", "chmod", "chown", "du", "file",
        "stat", "wc", "diff", "source", ".", "tar", "zip", "unzip", "code", "vim", "nvim", "vi", "nano", "bat",
    ]
    /// Words before the command that don't change what it is.
    static let precommands: Set<String> = ["sudo", "env", "time", "nohup", "command", "builtin", "exec", "noglob", "nocorrect"]
    /// Words zsh's lexer gives for the end of one command and the start of the next.
    static let separators: Set<String> = ["|", "|&", ";", ";;", "&&", "||", "&", "&!", "&|", "(", "{", "$(", "!", "then", "do", "else", "elif"]
    /// Redirections; the word after one names a file.
    static let redirections: Set<String> = [">", ">>", "<", ">|", ">!", "&>", "&>>", ">&", "<&", "<>", "2>", "2>>", "1>", "&>|"]

    /// Reads a `tab` report. The command word itself (a command, or a folder under AUTO_CD), an option, `cd -`,
    /// `~user`, fzf's `**` and any word Next Term can't read without evaluating step back.
    public static func analyze(_ report: CompletionProtocol.TabReport) -> CompletionContext? {
        guard !report.unreadable, report.directory.hasPrefix("/") else { return nil }
        let blankBefore = report.word.isEmpty
        var words = report.words
        if !blankBefore {
            guard words.last == report.word else { return nil }
            words.removeLast()
        }
        // The current command: after the last separator.
        if let last = words.lastIndex(where: { separators.contains($0) }) { words = Array(words[(last + 1)...]) }
        // Assignments and precommands go; `sudo -u x` and `env -i` (options) step back.
        var index = 0
        while index < words.count {
            let word = words[index]
            guard isAssignment(word) || precommands.contains(word) else { break }
            if word == "sudo" || word == "env", index + 1 < words.count, words[index + 1].hasPrefix("-") { return nil }
            index += 1
        }
        // The word being completed is the command itself: zsh's own Tab.
        guard index < words.count else { return nil }
        let command = (unquotedPlain(words[index]) as NSString).lastPathComponent
        let arguments = words[(index + 1)...]
        let afterRedirection = arguments.last.map { redirections.contains($0) } ?? false

        var word = report.word
        var keepPrefix = ""
        if !afterRedirection, word.hasPrefix("-") {
            // `--file=./sr`: the value after `=`; any other option is zsh's.
            guard word.hasPrefix("--"), let equals = word.firstIndex(of: "=") else { return nil }
            keepPrefix = String(word[...equals])
            word = String(word[word.index(after: equals)...])
        }
        guard let split = split(word, head: report.head) else { return nil }
        let looksLikePath = word.contains("/") || word.hasPrefix("~") || word.hasPrefix(".")
        let kind: Kind
        if !keepPrefix.isEmpty || afterRedirection {
            kind = .paths
        } else if folderCommands.contains(command) {
            kind = .folders
        } else if pathCommands.contains(command) || looksLikePath {
            kind = .paths
        } else {
            return nil
        }
        // `cd -2`, fzf's `**` trigger: zsh's.
        if word.hasSuffix("**") { return nil }
        var folderPath = split.folder
        if !report.head.isEmpty {
            guard folderPath.hasPrefix(report.head) || folderPath + "/" == report.head else { return nil }
            folderPath = report.resolvedHead + String(folderPath.dropFirst(min(report.head.count, folderPath.count)))
        }
        let base = folderPath.hasPrefix("/") ? folderPath : (report.directory as NSString).appendingPathComponent(folderPath)
        let folder = folderPath.isEmpty ? report.directory : (base as NSString).standardizingPath
        return CompletionContext(kind: kind, folder: folder, typed: split.typed, keep: keepPrefix + split.keep, quote: split.quote,
                                 word: report.word, directory: report.directory, head: report.head, resolvedHead: report.resolvedHead)
    }

    /// The same completion with the word as it is now (a `line` report). nil when the word no longer names a
    /// name in the same folder (a `/` typed, a quote closed): the list closes.
    public func with(word now: String) -> CompletionContext? {
        var rest = now
        let optionKeep = keep.hasPrefix("--") ? String(keep[...(keep.firstIndex(of: "=") ?? keep.startIndex)]) : ""
        if !optionKeep.isEmpty {
            guard rest.hasPrefix(optionKeep) else { return nil }
            rest = String(rest.dropFirst(optionKeep.count))
        }
        guard let split = Self.split(rest, head: head), optionKeep + split.keep == keep, split.quote == quote else { return nil }
        var next = self
        next.typed = split.typed
        next.word = now
        return next
    }

    /// The replacement for the word: what was kept, the name quoted for where it goes, and `/` or a space.
    public func replacement(name: [UInt8], folder isFolder: Bool, shell: WordQuote.Shell = .zsh) -> String? {
        guard let quoted = WordQuote.quote(name, in: quote, shell: shell) else { return nil }
        return keep + quoted + WordQuote.ending(folder: isFolder, in: quote)
    }

    /// Hidden entries are offered only for a name typed with a leading dot.
    public var showsHidden: Bool { typed.hasPrefix(".") }

    // MARK: the word

    struct Split: Equatable {
        /// The word up to and including its last `/`, as typed.
        var keep: String
        /// That part unquoted: the folder, as typed (with its head unresolved).
        var folder: String
        /// The name after the last `/`, unquoted.
        var typed: String
        var quote: WordQuote.Context
    }

    /// Splits a word into the folder part and the name part, unquoting each. nil for what Next Term doesn't
    /// read: `$'…'`, `$` anywhere but a leading `$NAME/` head, a backtick, a quote closed before the end,
    /// a glob or a brace, `~user`.
    static func split(_ word: String, head: String) -> Split? {
        let chars = Array(word)
        var unquoted = ""
        var quote = WordQuote.Context.unquoted
        // At the last `/`: where the name starts in the word, in the unquoted text, and the quote open there.
        var keepEnd = 0
        var folderEnd = 0
        var nameQuote = WordQuote.Context.unquoted
        let headLength = head.count
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var taken: Character? = c
            switch quote {
            case .unquoted:
                if i < headLength {
                    break // the `~/` or `$NAME/` the hook resolved
                } else if c == "\\" {
                    guard i + 1 < chars.count else { return nil }
                    i += 1
                    taken = chars[i]
                } else if c == "\"" || c == "'" {
                    quote = c == "\"" ? .double : .single
                    taken = nil
                } else if "$`*?[]{}".contains(c) || (c == "~" && i == 0) {
                    return nil
                }
            case .double:
                if c == "\"" {
                    return nil // a quote closed: mixed quoting, or a finished word
                } else if c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    i += 1
                    taken = chars[i]
                } else if c == "$" || c == "`" {
                    return nil
                }
            case .single:
                if c == "'" { return nil }
            }
            if let taken {
                unquoted.append(taken)
                if taken == "/" {
                    keepEnd = i + 1
                    folderEnd = unquoted.count
                    nameQuote = quote
                }
            }
            i += 1
        }
        var keep = String(chars[..<keepEnd])
        var context = nameQuote
        if nameQuote == .unquoted, quote != .unquoted {
            // A quote opened in the name: at its start, it stays (written again before the name); later in
            // it, the name is replaced whole, unquoted.
            if keepEnd < chars.count, chars[keepEnd] == "\"" || chars[keepEnd] == "'" {
                context = quote
                keep.append(chars[keepEnd])
            }
        }
        return Split(keep: keep, folder: String(unquoted.prefix(folderEnd)), typed: String(unquoted.dropFirst(folderEnd)), quote: context)
    }

    /// `NAME=value`.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) } && !(name.first?.isNumber ?? true)
    }

    /// A command word without its quotes and backslashes (`\ls`, `'ls'`).
    static func unquotedPlain(_ word: String) -> String {
        String(word.filter { $0 != "\\" && $0 != "'" && $0 != "\"" })
    }
}
