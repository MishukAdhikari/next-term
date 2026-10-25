import Foundation

// The `.env` family for the import: `.env`, `.env.local`, `.env.*`, `*.env`, and `.envrc`, whose `export K=v` lines are
// read and which is never run. Lines are read the dotenv way, through the editor's reader (`EnvFile.parse`), which is
// left as it is: the import adds the `KEY: value` lines Node's dotenv and Compose accept, the link in the comment line
// just above a key, and a note where other loaders read a value differently.

extension SecretSources {
    /// Each `KEY=value` (and `KEY: value`, except in `.envrc`) with its line, as written: a `${…}` in a value is kept, so
    /// a value built from another is told from a key. Stops one past `maxValues`.
    static func envFound(_ text: String, file: String) -> [Found] {
        let envrc: Bool = isEnvrc(file.lowercased())
        let lines: [Substring] = envLines(text)
        let body: String = envrc ? text : withColonLines(text, lines: lines)
        var found: [Found] = []
        for entry in EnvFile.parse(body, interpolating: false) {
            guard found.count <= maxValues else { break }
            let index: Int = entry.line - 1
            let raw: Substring = index < lines.count ? lines[index] : ""
            let start: Substring = raw.drop { (character: Character) -> Bool in character == " " || character == "\t" }
            if envrc && !isExport(start) { continue }
            let link: String? = index >= 1 ? commentLink(lines[index - 1]) : nil
            let note: Note? = readsDollar(entry.value, line: start) ? .loaderReadsDollar : nil
            let item = Found(name: envName(entry.key), value: entry.value, place: "line \(entry.line)", line: entry.line,
                             link: link, note: note)
            found.append(item)
        }
        return found
    }

    /// A `.env` key as a key's name: as it is when it is one, else in capitals with `_` (`api-key` is API_KEY).
    static func envName(_ key: String) -> String {
        StoredSecretName.isValid(key) ? key : StoredSecretName.suggested(from: key)
    }

    /// The file's lines as `EnvFile.parse` splits them: at a line break or a CRLF, without a CR left at the end.
    static func envLines(_ text: String) -> [Substring] {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: { (character: Character) -> Bool in
            character == "\n" || character == "\r\n"
        })
        return rows.map { (line: Substring) -> Substring in line.hasSuffix("\r") ? line.dropLast() : line }
    }

    static func isBlank(_ character: Character) -> Bool { character == " " || character == "\t" }

    static func isExport(_ line: Substring) -> Bool {
        guard line.hasPrefix("export") else { return false }
        return line.dropFirst(6).first.map(isBlank) ?? false
    }

    /// The text with each `KEY: value` line written `KEY=value`, line for line, so `EnvFile.parse` reads it as dotenv
    /// does. A line inside a value that goes on over several lines (a quoted private key) is left as it is. A file with
    /// no such line is given back as it is, unparsed.
    static func withColonLines(_ text: String, lines: [Substring]) -> String {
        var colons: [Int: String] = [:]
        for (offset, line) in lines.enumerated() {
            if let written = colonLine(line) { colons[offset] = written }
        }
        guard !colons.isEmpty else { return text }
        let inside: Set<Int> = linesInsideValues(text)
        var changed = false
        let written: [String] = lines.enumerated().map { (pair: (offset: Int, element: Substring)) -> String in
            guard !inside.contains(pair.offset), let line = colons[pair.offset] else { return String(pair.element) }
            changed = true
            return line
        }
        return changed ? written.joined(separator: "\n") : text
    }

    /// `KEY: value` (or `export KEY: value`) as `KEY=value`: a key, a colon, then a blank, as dotenv reads it. Nil for
    /// any other line.
    static func colonLine(_ line: Substring) -> String? {
        var rest: Substring = line.drop(while: isBlank)
        var lead = ""
        if isExport(rest) {
            lead = "export "
            rest = rest.dropFirst(6).drop(while: isBlank)
        }
        let key: Substring = rest.prefix { (character: Character) -> Bool in
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        }
        guard !key.isEmpty, EnvFile.isKey(String(key)) else { return nil }
        let after: Substring = rest.dropFirst(key.count)
        guard after.first == ":", let blank = after.dropFirst().first, isBlank(blank) else { return nil }
        var written: String = lead
        written += key
        written += "="
        written += after.dropFirst().drop(while: isBlank)
        return written
    }

    /// The lines (0-based) after the first of each value that goes on over several lines, from `EnvFile.valueRanges`.
    static func linesInsideValues(_ text: String) -> Set<Int> {
        let ranges: [NSRange] = EnvFile.valueRanges(in: text)
        guard !ranges.isEmpty else { return [] }
        var starts: [Int] = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        func line(of offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }
        var inside = Set<Int>()
        for range in ranges where range.length > 0 {
            let first: Int = line(of: range.location)
            let last: Int = line(of: NSMaxRange(range) - 1)
            if last > first { inside.formUnion((first + 1)...last) }
        }
        return inside
    }
}

// MARK: - The comment above a key, and other loaders

extension SecretSources {
    static let commentURL = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#)

    /// The first web address in a comment line, without the punctuation after it: where the key below was made, as
    /// people note it. The link rules judge it before it is kept.
    static func commentLink(_ line: Substring) -> String? {
        let text: String = String(line.drop(while: isBlank))
        guard text.hasPrefix("#") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = commentURL.firstMatch(in: text, range: range),
              let found = Range(match.range, in: text) else { return nil }
        var url: Substring = text[found]
        while let last = url.last, ".,;:!?".contains(last) { url = url.dropLast() }
        return String(url)
    }

    /// Whether Next.js, Vite (dotenv-expand) or Compose would read a `$` in the value as the start of a variable, where
    /// dotenv keeps it: a `$` before a letter, a digit, `_` or `{`, in a value that isn't in single quotes.
    static func readsDollar(_ value: String, line: Substring) -> Bool {
        guard value.contains("$") else { return false }
        var rest: Substring = line
        if isExport(rest) { rest = rest.dropFirst(6).drop(while: isBlank) }
        guard let sign = rest.firstIndex(where: { (character: Character) -> Bool in character == "=" || character == ":" })
        else { return false }
        let opening: Character? = rest[rest.index(after: sign)...].drop(while: isBlank).first
        if opening == "'" { return false }
        let characters: [Character] = Array(value)
        for (index, character) in characters.enumerated() where character == "$" && index + 1 < characters.count {
            let next: Character = characters[index + 1]
            if next == "{" || next == "_" || (next.isASCII && (next.isLetter || next.isNumber)) { return true }
        }
        return false
    }
}
