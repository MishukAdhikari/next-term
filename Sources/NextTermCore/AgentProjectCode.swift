import Darwin
import Foundation

// MARK: - The code a project config starts

extension AgentEvidence {
    /// Code that a project config `agent` reads (in `folder` or a folder above it, as `projectConfigChanged` finds
    /// them) starts again on a resume, lying in one of `within`, changed after `start`: Claude Code's hooks, status
    /// line, helpers and MCP servers, Codex's MCP servers and notify program, Qwen Code's MCP servers and tool
    /// commands. A tab can rewrite a script there while the config keeps its date. Each word of their command lines is
    /// taken as a path, from `folder` and from the config's own folder, and so is each whole argument. What cannot be
    /// followed counts as changed: a config that does not read, a variable other than the home or project folder, a
    /// command substitution, a glob (outside a web address), a quote left open, a change of folder or a working folder
    /// of its own, and a folder named inside `within` (its files' changes do not show on it). Not knowing when the
    /// agent started counts as changed.
    public static func projectCodeChanged(agent: RestoreAgent, folder: String, since start: Date?, within: [String],
                                          home: String = NSHomeDirectory()) -> Bool {
        guard let start else { return true }
        let files = agent.projectConfigFiles
        guard !files.isEmpty else { return false }
        guard folder.hasPrefix("/") else { return true }
        let absolute = within.filter { $0.hasPrefix("/") }
        // Innermost first: a path's own folders are checked from the closest of these down.
        let folders = Set(absolute.map(normalized) + absolute.map(canonicalPath)).sorted { $0.count > $1.count }
        let skip = normalized(home)
        let first = normalized(folder)
        var current = first
        while true {
            if current != skip || current == first {
                let check = ProjectCodeCheck(bases: Array(Set([first, current])), home: normalized(home), folders: folders, start: start)
                for file in files {
                    guard let lines = commandLines(in: (current == "/" ? "" : current) + "/" + file) else { return true }
                    if lines.contains(where: check.changed) { return true }
                }
            }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// The command lines and arguments a config file starts: none when it is not there, nil when it cannot be read.
    static func commandLines(in path: String) -> [String]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return isAbsent(errno) ? [] : nil }
        guard let data = AgentSessions.readHead(path, bytes: 1 << 20) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return path.hasSuffix(".toml") ? codexCommandLines(text) : jsonCommandLines(text)
    }

    /// Keys whose string is a command line, wherever they are: hooks', the status line's and MCP servers' `command`,
    /// Claude Code's helpers, Qwen Code's tool commands.
    private static let commandKeys: Set<String> = [
        "command", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper",
        "discoveryCommand", "callCommand", "toolDiscoveryCommand", "toolCallCommand",
    ]

    /// Claude Code's and Qwen Code's JSON (comments allowed): each command key's string, and the `args` beside a
    /// `command`. A command that is not a string, arguments that are not strings, or a `cwd` beside a command make it
    /// unreadable.
    static func jsonCommandLines(_ text: String) -> [String]? {
        guard JSONC.isShallow(text), let plain = JSONC.plain(text),
              let root = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) else { return nil }
        var lines: [String] = []
        var readable = true
        func walk(_ value: Any, key: String?) {
            if let key, commandKeys.contains(key) {
                guard let line = value as? String else {
                    readable = false
                    return
                }
                lines.append(line)
            } else if let object = value as? [String: Any] {
                if object["command"] != nil {
                    if object["cwd"] != nil { readable = false }
                    if let args = object["args"] {
                        guard let words = args as? [String] else {
                            readable = false
                            return
                        }
                        lines += words
                    }
                }
                for (key, item) in object where key != "args" { walk(item, key: key) }
            } else if let array = value as? [Any] {
                for item in array { walk(item, key: nil) }
            }
        }
        walk(root, key: nil)
        return readable ? lines : nil
    }

    /// Codex's config.toml: `notify`, and each `[mcp_servers.<name>]` table's `command` and `args`. A server given as
    /// one value or with a `cwd`, a hooks table, and a value that is not a single-line string or an array of them make
    /// it unreadable.
    static func codexCommandLines(_ text: String) -> [String]? {
        guard let outline = TOMLOutline(text) else { return nil }
        if outline.headers.contains(where: { $0.path.first == "hooks" }) { return nil }
        var lines: [String] = []
        for key in outline.keys {
            let path = key.table + key.path
            if path.first == "hooks" { return nil }
            let server = path.count == 3 && path[0] == "mcp_servers"
            if path == ["notify"] || server && (path[2] == "command" || path[2] == "args") {
                guard let strings = tomlStrings(outline, at: key.value) else { return nil }
                lines += strings
            } else if path.first == "mcp_servers", path.count < 3 || server && path[2] == "cwd" {
                return nil
            }
        }
        return lines
    }

    /// A TOML value that is one single-line string, or an array of them over any number of lines: its strings.
    private static func tomlStrings(_ outline: TOMLOutline, at index: String.Index) -> [String]? {
        if let string = outline.string(at: index) { return [string.value] }
        let scalars = outline.text.unicodeScalars
        guard index < scalars.endIndex, scalars[index] == "[" else { return nil }
        var i = scalars.index(after: index)
        func skipSpace() {
            while i < scalars.endIndex {
                if scalars[i] == "#" {
                    while i < scalars.endIndex, scalars[i] != "\n" { i = scalars.index(after: i) }
                } else if scalars[i].properties.isWhitespace {
                    i = scalars.index(after: i)
                } else {
                    return
                }
            }
        }
        var strings: [String] = []
        while true {
            skipSpace()
            guard i < scalars.endIndex else { return nil }
            if scalars[i] == "]" { return strings }
            guard let string = outline.string(at: i) else { return nil }
            strings.append(string.value)
            i = string.range.upperBound
            skipSpace()
            guard i < scalars.endIndex else { return nil }
            if scalars[i] == "," {
                i = scalars.index(after: i)
            } else if scalars[i] != "]" {
                return nil
            }
        }
    }
}

/// The paths a config's command lines name, checked against the folders a tab can write.
private struct ProjectCodeCheck {
    /// Where a relative word is taken from, and what the project folder variable can be: the agent's folder and the
    /// config's.
    let bases: [String]
    let home: String
    /// The folders a tab can write, innermost first.
    let folders: [String]
    let start: Date

    /// `line` names a path in `folders` that changed after `start` or cannot be told, or cannot be followed.
    func changed(_ line: String) -> Bool {
        guard let words = ShellWords.split(line) else { return true }
        // As an argument, the line is one path, spaces and all.
        let whole = ShellWords.Word(root: nil, text: line)
        for word in words + [whole] {
            for path in paths(word) where changedInside(path) { return true }
        }
        return false
    }

    /// The paths a word can name: itself, and what follows its first `=` (`--config=./x`). A web address names none.
    private func paths(_ word: ShellWords.Word) -> [String] {
        switch word.root {
        case .home: return [home + word.text]
        case .project: return bases.map { $0 + word.text }
        case nil: break
        }
        var texts = [word.text]
        if let equals = word.text.firstIndex(of: "=") { texts.append(String(word.text[word.text.index(after: equals)...])) }
        return texts.flatMap { text -> [String] in
            if text.isEmpty || text.contains("://") { return [] }
            if text.hasPrefix("/") { return [text] }
            if text == "~" || text.hasPrefix("~/") { return [home + text.dropFirst()] }
            return bases.map { $0 + "/" + text }
        }
    }

    /// `path`, as written or by its real path, lies inside one of `folders` and it or a folder on the way to it from
    /// there changed after `start`, cannot be read, or it is a folder.
    private func changedInside(_ path: String) -> Bool {
        let plain = AgentEvidence.normalized(path)
        for candidate in Set([plain, canonicalPath(plain)]) {
            let inside = folders.first { folder in
                candidate != folder && candidate.hasPrefix(folder == "/" ? "/" : folder + "/")
            }
            guard let folder = inside else { continue }
            let relative = String(candidate.dropFirst(folder == "/" ? 1 : folder.count + 1))
            if AgentEvidence.changed(relative, in: folder, after: start) { return true }
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return true }
        }
        return false
    }
}

/// The words of a shell command line, as far as the check of a project's code follows one: blanks and the shell's
/// operators between words, quotes, backslashes, comments, and the home folder (`~`, `$HOME`) or the project folder
/// (`$CLAUDE_PROJECT_DIR`) at a word's start. nil for what it cannot follow: any other expansion, a command
/// substitution, a glob or brace pattern (outside a web address), a quote left open, or `cd`.
enum ShellWords {
    enum Root { case home, project }

    struct Word {
        /// The folder the word starts with; `text` follows it.
        var root: Root?
        var text: String
    }

    private static func isName(_ c: Unicode.Scalar) -> Bool {
        c == "_" || ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    static func split(_ line: String) -> [Word]? {
        let scalars = Array(line.unicodeScalars)
        var words: [Word] = []
        var word = Word(root: nil, text: "")
        var started = false
        var pattern = false
        var quoted = false
        var i = 0
        func end() -> Bool {
            defer {
                word = Word(root: nil, text: "")
                started = false
                pattern = false
            }
            guard started else { return true }
            let plain = word.root == nil
            if pattern, !(plain && ["[", "[[", "{", "{}"].contains(word.text)), !word.text.contains("://") { return false }
            if plain, word.text == "cd" || word.text == "pushd" { return false }
            words.append(word)
            return true
        }
        /// `$HOME` or `$CLAUDE_PROJECT_DIR`, braced or not, at a word's start: where the word goes on.
        func root(at dollar: Int) -> Int? {
            guard word.text.isEmpty, word.root == nil, dollar + 1 < scalars.count else { return nil }
            let braced = scalars[dollar + 1] == "{"
            var j = dollar + (braced ? 2 : 1)
            var name = ""
            while j < scalars.count, isName(scalars[j]) {
                name.unicodeScalars.append(scalars[j])
                j += 1
            }
            if braced {
                guard j < scalars.count, scalars[j] == "}" else { return nil }
                j += 1
            }
            switch name {
            case "HOME": word.root = .home
            case "CLAUDE_PROJECT_DIR": word.root = .project
            default: return nil
            }
            return j
        }
        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                switch c {
                case "\"":
                    quoted = false
                    i += 1
                case "\\":
                    guard i + 1 < scalars.count else { return nil }
                    let next = scalars[i + 1]
                    if "$`\"\\".unicodeScalars.contains(next) {
                        word.text.unicodeScalars.append(next)
                    } else if next != "\n" {
                        word.text.unicodeScalars.append(contentsOf: [c, next])
                    }
                    i += 2
                case "`":
                    return nil
                case "$":
                    guard let after = root(at: i) else { return nil }
                    i = after
                default:
                    word.text.unicodeScalars.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case " ", "\t", "\n", "\r", ";", "&", "|", "<", ">", "(", ")":
                guard end() else { return nil }
                i += 1
            case "#" where !started:
                while i < scalars.count, scalars[i] != "\n" { i += 1 }
            case "'":
                started = true
                guard let close = scalars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.text.unicodeScalars.append(contentsOf: scalars[(i + 1)..<close])
                i = close + 1
            case "\"":
                started = true
                quoted = true
                i += 1
            case "\\":
                guard i + 1 < scalars.count else { return nil }
                if scalars[i + 1] != "\n" {
                    started = true
                    word.text.unicodeScalars.append(scalars[i + 1])
                }
                i += 2
            case "`":
                return nil
            case "$":
                started = true
                guard let after = root(at: i) else { return nil }
                i = after
            case "~" where !started:
                let next = i + 1 < scalars.count ? scalars[i + 1] : " "
                guard next == "/" || " \t\n\r;&|<>()".unicodeScalars.contains(next) else { return nil }
                started = true
                word.root = .home
                i += 1
            default:
                if "*?[{".unicodeScalars.contains(c) { pattern = true }
                started = true
                word.text.unicodeScalars.append(c)
                i += 1
            }
        }
        guard !quoted, end() else { return nil }
        return words
    }
}
