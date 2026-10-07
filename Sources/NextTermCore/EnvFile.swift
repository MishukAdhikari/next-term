import Foundation

/// One `KEY=value` line of a dotenv file, as Laravel (phpdotenv) and Next.js (dotenv) read it.
struct EnvEntry: Equatable, Sendable {
    let key: String
    let value: String
    /// 1-based, where the key is.
    let line: Int
}

/// Reads `.env` files without running anything: no command substitution, no shell, and only `${NAME}`
/// references to keys earlier in the same file (never the app's own environment).
enum EnvFile {
    /// Files larger than this are not env files anyone wrote by hand.
    static let maxSize = 512 * 1024

    /// The file's entries, or nil if it is missing, not a plain file, or too large.
    static func read(_ path: String) -> [EnvEntry]? {
        guard isRegularFile(path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), size <= maxSize,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Entries in file order. A key set twice keeps both entries; `values` keeps the last, as dotenv does.
    static func parse(_ text: String) -> [EnvEntry] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        var entries: [EnvEntry] = []
        var known: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let number = index + 1
            var line = lines[index].drop { $0 == " " || $0 == "\t" }
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = line.dropFirst(7).drop { $0 == " " || $0 == "\t" } }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isKey(key) else { continue }
            let rest = line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
            var value: String
            var expand = true
            if let quote = rest.first, quote == "\"" || quote == "'" || quote == "`" {
                let (text, consumed) = quoted(rest.dropFirst(), quote: quote, following: lines[index...])
                index += consumed
                value = quote == "\"" ? unescape(text) : text
                expand = quote == "\""
            } else {
                value = String(unquoted(rest))
            }
            if expand { value = interpolate(value, known) }
            known[key] = value
            entries.append(EnvEntry(key: key, value: value, line: number))
        }
        return entries
    }

    /// The last value of each key.
    static func values(_ entries: [EnvEntry]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries { result[entry.key] = entry.value }
        return result
    }

    static func isKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first), first.isASCII else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
    }

    /// An unquoted value ends at ` #` (a comment) and loses trailing blanks.
    private static func unquoted(_ rest: Substring) -> Substring {
        var end = rest.endIndex
        var previous: Character = " "
        for i in rest.indices {
            if rest[i] == "#", previous == " " || previous == "\t" {
                end = i
                break
            }
            previous = rest[i]
        }
        var value = rest[..<end]
        while let last = value.last, last == " " || last == "\t" { value = value.dropLast() }
        return value
    }

    /// The text up to the closing quote, which may be on a later line (a private key in double quotes).
    /// A closing quote counts only when nothing but blanks or a comment follows it. Without one, the
    /// rest of the line is the value and no further lines are taken.
    private static func quoted(_ start: Substring, quote: Character, following: ArraySlice<Substring>) -> (String, Int) {
        func closing(in text: Substring) -> String.Index? {
            var escaped = false
            for i in text.indices {
                let c = text[i]
                if escaped { escaped = false; continue }
                if c == "\\" && quote == "\"" { escaped = true; continue }
                guard c == quote else { continue }
                let after = text[text.index(after: i)...].drop { $0 == " " || $0 == "\t" }
                if after.isEmpty || after.hasPrefix("#") { return i }
            }
            return nil
        }
        if let end = closing(in: start) { return (String(start[..<end]), 0) }
        var collected = String(start)
        var consumed = 0
        for line in following.prefix(200) {
            consumed += 1
            if let end = closing(in: line) {
                collected += "\n" + line[..<end]
                return (collected, consumed)
            }
            collected += "\n" + line
        }
        return (String(start), 0)
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaped = false
        for c in text {
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                result.append(c)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// `${NAME}` from keys earlier in the file. Unknown names are left as written.
    private static func interpolate(_ value: String, _ known: [String: String]) -> String {
        guard value.contains("${") else { return value }
        var result = ""
        var rest = value[...]
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = String(rest[open.upperBound..<close])
            result += known[name] ?? "${\(name)}"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
