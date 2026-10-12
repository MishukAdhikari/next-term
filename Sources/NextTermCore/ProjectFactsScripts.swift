import Foundation

// Start commands: a script, task, process, target or recipe that runs a tool the catalog knows, and the port it names.
// A script line can hold a secret inline (`OPENAI_API_KEY=… next dev`, a database URL with its password, a Makefile's
// `export TOKEN=…`), so only the file, the script's name, the start words, the port and a `--studio-url`'s origin
// are kept; the line is dropped as soon as it is read.

extension ProjectFacts {
    /// `Procfile`, `Procfile.dev`, `Makefile` and `justfile`. `package.json`'s scripts and `pyproject.toml`'s tasks
    /// are read with those files.
    mutating func readScripts(_ reader: inout FactReader, startWords: [String]) {
        for file in ["Procfile", "Procfile.dev"] {
            guard let text = reader.text(file) else { continue }
            for line in Self.lines(text) where !line.hasPrefix("#") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                startCommands += Self.startCommands(in: String(line[line.index(after: colon)...]), file: file,
                                                    script: name, words: startWords)
            }
        }
        if let text = reader.text("Makefile") { startCommands += Self.recipes(text, file: "Makefile", words: startWords) }
        if let text = reader.text("justfile") { startCommands += Self.recipes(text, file: "justfile", words: startWords) }
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r\n" || c == "\r" })
    }

    /// A Makefile's targets or a justfile's recipes: a name at the start of a line, then `:` (not `:=`), and the
    /// indented lines under it. A line that ends in `\` goes on with the next, however that one is indented, as the
    /// shell reads it. The joined line is dropped as each one is.
    static func recipes(_ text: String, file: String, words: [String]) -> [StartCommand] {
        var found: [StartCommand] = []
        var current: String?
        var continued: String?
        for line in lines(text) {
            let indented: Bool = line.first == "\t" || line.first == " "
            if continued == nil, !indented {
                current = recipeName(line)
                continue
            }
            guard let script = current else { continue }
            let piece: String = continued == nil ? recipeCommand(line) : String(line)
            let command: String = (continued ?? "") + " " + piece
            if command.hasSuffix("\\") {
                continued = String(command.dropLast())
                continue
            }
            continued = nil
            found += startCommands(in: command, file: file, script: script, words: words)
        }
        if let command = continued, let script = current {
            found += startCommands(in: command, file: file, script: script, words: words)
        }
        return found
    }

    /// A recipe's command without its indent and the prefixes Make and just read before it, in any order: `@`
    /// (quiet), `-` (ignore errors) and `+` (always run). A comment, which the shell skips, is no command.
    static func recipeCommand(_ line: Substring) -> String {
        let command = line.drop { (c: Character) -> Bool in c == " " || c == "\t" || c == "@" || c == "-" || c == "+" }
        return command.hasPrefix("#") ? "" : String(command)
    }

    /// `run:`, `run: deps`, `serve port='8001':`, `@test:`; not `X := 1`, `X = 1`, a comment or `export TOKEN=…`.
    static func recipeName(_ line: Substring) -> String? {
        let body = line.hasPrefix("@") ? line.dropFirst() : line
        let name = body.prefix { (c: Character) -> Bool in c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c)) }
        guard !name.isEmpty, let colon = body.firstIndex(of: ":") else { return nil }
        let after = body[body.index(after: colon)...]
        let between = body[name.endIndex..<colon]
        let assigns: Bool = after.hasPrefix("=") || between.contains("=") && !between.contains("'") && !between.contains("\"")
        guard !assigns, !between.contains(":") else { return nil }
        return String(name)
    }

    /// The tools a command line runs, by the catalog's start words, each with the port it names. The line is cut
    /// into commands at `&&`, `||`, `;`, `|`, `&`, quotes and parentheses, and a word is matched whole, or as the last
    /// part of a path (`bin/rails`, `./node_modules/.bin/next`). A word that ends in `=` is a variable the tool reads
    /// (`GRADIO_SERVER_PORT=`), matched at the start of a word, and its value is the port. Nothing of the line is
    /// kept but what is returned.
    static func startCommands(in line: String, file: String, script: String, words: [String]) -> [StartCommand] {
        let wordLists = words.map { (word: String) -> [Substring] in word.split(separator: " ") }
        let scriptName = plainText(script) ?? ""
        var found: [StartCommand] = []
        for segment in line.split(whereSeparator: { (c: Character) -> Bool in commandBreaks.contains(c) }) {
            let tokens = segment.split(whereSeparator: { (c: Character) -> Bool in c == " " || c == "\t" })
            guard let hit = firstStart(tokens, wordLists) else { continue }
            let before = tokens[..<hit.start]
            let after = tokens[(hit.start + hit.words.count)...]
            let word = hit.words.joined(separator: " ")
            if isVariable(word) {
                let port = ComposeFile.portNumber(tokens[hit.start].dropFirst(word.count))
                found.append(StartCommand(file: file, script: scriptName, word: word, port: port))
                continue
            }
            let runserver: Bool = hit.words.last == "runserver"
            let flagged: Int? = flagPort(after, names: ["--port", "-p", "--server.port"])
            let served: Int? = runserver ? serverPort(after) : nil
            let port: Int? = flagged ?? served ?? leadingPort(before)
            let uiPort: Int? = flagPort(after, names: ["--ui-port"])
            let studio = flagValue(after, name: "--studio-url").flatMap { (value: Substring) -> SafeWebLink.Origin? in
                SafeWebLink.address(of: String(value))
            }
            found.append(StartCommand(file: file, script: scriptName, word: word, port: port, uiPort: uiPort,
                                      studio: studio))
        }
        return found
    }

    private static let commandBreaks: Set<Character> = ["&", "|", ";", "\"", "'", "`", "(", ")"]

    /// The first token where a start word begins, with the longest of the words that begin there.
    static func firstStart(_ tokens: [Substring], _ lists: [[Substring]]) -> (start: Int, words: [Substring])? {
        for start in tokens.indices {
            var best: [Substring]?
            for list in lists where !list.isEmpty && start + list.count <= tokens.count {
                let fits = list.indices.allSatisfy { (offset: Int) -> Bool in tokenIs(tokens[start + offset], list[offset]) }
                if fits, list.count > (best?.count ?? 0) { best = list }
            }
            if let best { return (start, best) }
        }
        return nil
    }

    /// A token is a word as written, or as the last part of a path; a variable, as the start of an assignment.
    static func tokenIs(_ token: Substring, _ word: Substring) -> Bool {
        if isVariable(word) { return token.hasPrefix(word) }
        return token == word || token.split(separator: "/").last == word
    }

    /// `GRADIO_SERVER_PORT=`: a start word that names a variable the tool reads, not a command.
    static func isVariable<Text: StringProtocol>(_ word: Text) -> Bool {
        word.hasSuffix("=")
    }

    /// `--name value` or `--name=value`, for the first time the command gives it.
    static func flagValue(_ tokens: ArraySlice<Substring>, name: String) -> Substring? {
        for index in tokens.indices {
            let token = tokens[index]
            if token == name, index + 1 < tokens.endIndex { return tokens[index + 1] }
            if token.hasPrefix(name + "=") { return token.dropFirst(name.count + 1) }
        }
        return nil
    }

    /// `--port N` or `--port=N`, for the first of `names` the command gives.
    static func flagPort(_ tokens: ArraySlice<Substring>, names: [String]) -> Int? {
        for index in tokens.indices {
            let token = tokens[index]
            for name in names {
                if token == name, index + 1 < tokens.endIndex { return ComposeFile.portNumber(tokens[index + 1]) }
                if token.hasPrefix(name + "=") { return ComposeFile.portNumber(token.dropFirst(name.count + 1)) }
            }
        }
        return nil
    }

    /// `runserver 8001` or `runserver 0.0.0.0:8001`: the first word after it that is not a flag.
    static func serverPort(_ tokens: ArraySlice<Substring>) -> Int? {
        guard let address = tokens.first(where: { (token: Substring) -> Bool in !token.hasPrefix("-") }) else { return nil }
        let port = address.split(separator: ":", omittingEmptySubsequences: false).last ?? address
        return ComposeFile.portNumber(port)
    }

    /// `PORT=4100` or `GRADIO_SERVER_PORT=7861` before the command.
    static func leadingPort(_ tokens: ArraySlice<Substring>) -> Int? {
        for token in tokens {
            for name in ["PORT=", "GRADIO_SERVER_PORT="] where token.hasPrefix(name) {
                return ComposeFile.portNumber(token.dropFirst(name.count))
            }
        }
        return nil
    }
}
