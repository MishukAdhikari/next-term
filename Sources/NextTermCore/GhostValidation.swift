import Foundation

/// Whether a command from the record is still worth suggesting where it would run now, as a suggestion that would fail
/// when run is worse than none:
/// 1. it ran well once at least, and its last run found its program (exit 127 is "command not found");
/// 2. `cd` with one word: the folder (`~` expanded, relative to the working folder) is there, and is not the working folder;
/// 3. a program named by a path (`./build.sh`) is there and can run;
/// 4. a later word that is a path is there: one starting `/`, `./`, `../` or `~/`, or one with a `/` whose first part is
///    there (`src/main.swift`, while `origin/main` names no file and is no path).
/// A word with something the shell expands (`$HOME/x`, a glob, a backtick) is not checked, nor a URL, a flag or an
/// assignment. Nothing here runs anything: `FileProbe` is what is asked of the disk.
public enum GhostValidation {
    /// What the checks ask of the disk, by absolute path.
    public struct FileProbe: Sendable {
        public var exists: @Sendable (String) -> Bool
        public var isFolder: @Sendable (String) -> Bool
        public var isExecutable: @Sendable (String) -> Bool

        public init(exists: @escaping @Sendable (String) -> Bool, isFolder: @escaping @Sendable (String) -> Bool,
                    isExecutable: @escaping @Sendable (String) -> Bool) {
            self.exists = exists
            self.isFolder = isFolder
            self.isExecutable = isExecutable
        }
    }

    /// The record's facts about a command: it ever ran well, and its last run didn't fail to find its program. A command
    /// never seen to end is not held against it.
    public static func ranWell(_ entry: CommandHistory.Entry) -> Bool {
        if entry.lastExit == 127 { return false }
        return entry.everSucceeded || entry.lastExit == nil
    }

    /// The first of `candidates` (best first) that may be suggested from `cwd`: it ran well, may be kept (no secret, which a
    /// key stored since the line was recorded makes it hold), and passes `check`.
    public static func first(_ candidates: [CommandHistory.Entry], cwd: String, home: String, probe: FileProbe,
                             mayShow: (String) -> Bool = CommandSecrets.mayKeep) -> CommandHistory.Entry? {
        candidates.first { ranWell($0) && mayShow($0.line) && check($0.line, cwd: cwd, home: home, probe: probe) }
    }

    /// Rules 2 to 4 for one command line.
    public static func check(_ command: String, cwd: String, home: String, probe: FileProbe) -> Bool {
        for simple in simpleCommands(words(command)) {
            var rest = simple[...]
            // Assignments before the command (FOO=1 make) are not its words.
            while let first = rest.first, first.plain, isAssignment(first.text) { rest = rest.dropFirst() }
            guard let program = rest.first else { continue }
            let arguments = rest.dropFirst()
            if program.plain, program.text == "cd" {
                if arguments.count == 1, let target = arguments.first, target.plain, target.text != "-", !target.text.hasPrefix("-") {
                    let folder = absolute(target.text, cwd: cwd, home: home)
                    guard let folder, probe.isFolder(folder), standard(folder) != standard(cwd) else { return false }
                }
                continue
            }
            if program.plain, program.text.contains("/") {
                guard let path = absolute(program.text, cwd: cwd, home: home), probe.exists(path), probe.isExecutable(path) else { return false }
            }
            for word in arguments where word.plain {
                guard let path = pathArgument(word.text, cwd: cwd, home: home, probe: probe) else { continue }
                if !probe.exists(path) { return false }
            }
        }
        return true
    }

    /// The absolute path a word names when it is a path argument (rule 4), else nil.
    static func pathArgument(_ text: String, cwd: String, home: String, probe: FileProbe) -> String? {
        guard text.contains("/"), !text.hasPrefix("-"), !text.contains("://"), !isAssignment(text) else { return nil }
        let explicit = text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("~/")
        guard let path = absolute(text, cwd: cwd, home: home) else { return nil }
        if explicit { return path }
        guard let first = text.split(separator: "/").first, let head = absolute(String(first), cwd: cwd, home: home) else { return nil }
        return probe.exists(head) ? path : nil
    }

    /// `text` as an absolute path: `~` and `~/` from `home`, anything else not starting `/` from `cwd`. nil for `~user`.
    static func absolute(_ text: String, cwd: String, home: String) -> String? {
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home + text.dropFirst() }
        if text.hasPrefix("~") { return nil }
        if text.hasPrefix("/") { return text }
        return (cwd as NSString).appendingPathComponent(text)
    }

    static func standard(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// `NAME=value`.
    static func isAssignment(_ text: String) -> Bool {
        guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return false }
        let name = text[..<equals]
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) } && !(name.first?.isNumber ?? true)
    }

    // MARK: words

    /// A word of a command line, unquoted as the shell would read it, and whether nothing in it is expanded (`plain`): no
    /// unquoted `$`, backtick, glob or brace, no `$` inside double quotes. Shell operators (`|`, `&&`, `;`, `>`) are words of
    /// their own, `operator`.
    struct Word: Equatable {
        var text: String
        var plain: Bool
        var isOperator = false
    }

    static func words(_ line: String) -> [Word] {
        var words: [Word] = []
        var text = ""
        var plain = true
        var started = false
        var quote: Character?
        var characters = Array(line)[...]
        func finish() {
            if started { words.append(Word(text: text, plain: plain)) }
            text = ""
            plain = true
            started = false
        }
        while let c = characters.first {
            characters = characters.dropFirst()
            if let open = quote {
                if c == open {
                    quote = nil
                } else if open == "\"", c == "\\", let next = characters.first, "\"\\$`".contains(next) {
                    text.append(next)
                    characters = characters.dropFirst()
                } else {
                    if open == "\"", c == "$" || c == "`" { plain = false }
                    text.append(c)
                }
                continue
            }
            switch c {
            case " ", "\t":
                finish()
            case "\\":
                if let next = characters.first {
                    text.append(next)
                    characters = characters.dropFirst()
                }
                started = true
            case "'", "\"":
                quote = c
                started = true
            case "|", "&", ";", "<", ">", "(", ")":
                finish()
                var op = String(c)
                while let next = characters.first, "|&;<>".contains(next) {
                    op.append(next)
                    characters = characters.dropFirst()
                }
                words.append(Word(text: op, plain: false, isOperator: true))
            default:
                if "$`*?[]{}".contains(c) { plain = false }
                text.append(c)
                started = true
            }
        }
        finish()
        // An unclosed quote: the line is not read as words at all.
        return quote == nil ? words : []
    }

    /// The simple commands of a line's words: split at its operators, the word after a redirection left out (a file that
    /// may not be there yet, being written).
    static func simpleCommands(_ words: [Word]) -> [[Word]] {
        var commands: [[Word]] = [[]]
        var skipNext = false
        for word in words {
            if word.isOperator {
                if word.text.contains(">") || word.text.contains("<") {
                    skipNext = true
                } else {
                    commands.append([])
                }
                continue
            }
            if skipNext {
                skipNext = false
                continue
            }
            commands[commands.count - 1].append(word)
        }
        return commands.filter { !$0.isEmpty }
    }
}
