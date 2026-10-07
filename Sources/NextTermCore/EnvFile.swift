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
public enum EnvFile {
    /// Files larger than this are not env files anyone wrote by hand.
    static let maxSize = 512 * 1024

    /// `.env`, `.env.*`, `*.env` and `.flaskenv`: the files whose values the editor can hide.
    public static func isEnvFile(named name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".env.") || lower.hasSuffix(".env") || lower == ".flaskenv"
    }

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

    /// Where each value is, in UTF-16 offsets as NSString counts them: from the first character after
    /// the `=` (and the blanks after it) to the value's end, quotes included. Keys, comment lines, a
    /// ` # comment` after a value, and empty values are left out. A quoted value ends where `parse` ends
    /// it, so one that goes on over several lines (a private key) is one range across them. Only the
    /// key has to look like one (no blanks), and `KEY=#x` counts as a value, as some readers take it:
    /// a line that might hold a secret is hidden rather than shown.
    public static func valueRanges(in text: String) -> [NSRange] {
        let u = Array(text.utf16)
        let space: UInt16 = 0x20, tab: UInt16 = 0x09, newline: UInt16 = 0x0A, cr: UInt16 = 0x0D
        let hash: UInt16 = 0x23, equals: UInt16 = 0x3D, backslash: UInt16 = 0x5C
        let export = Array("export".utf16)
        func isBlank(_ c: UInt16) -> Bool { c == space || c == tab }
        /// Where the line from `start` ends: its line break, or the end of the text.
        func lineEnd(from start: Int) -> Int {
            var i = start
            while i < u.count, u[i] != newline { i += 1 }
            return i
        }
        /// The end of a line's text, without the CR of a CRLF.
        func contentEnd(_ start: Int, _ end: Int) -> Int { end > start && u[end - 1] == cr ? end - 1 : end }
        /// The closing quote in start..<end, as `parse` finds it: one with only blanks or a comment after it.
        func closing(_ quote: UInt16, from start: Int, to end: Int) -> Int? {
            var escaped = false
            var i = start
            while i < end {
                let c = u[i]
                if escaped {
                    escaped = false
                } else if c == backslash && quote == 0x22 {
                    escaped = true
                } else if c == quote {
                    var after = i + 1
                    while after < end, isBlank(u[after]) { after += 1 }
                    if after == end || u[after] == hash { return i }
                }
                i += 1
            }
            return nil
        }

        var ranges: [NSRange] = []
        var start = u.first == 0xFEFF ? 1 : 0 // a byte-order mark
        while start <= u.count {
            let end = lineEnd(from: start)
            let content = contentEnd(start, end)
            var next = end + 1
            defer { start = next }
            var i = start
            while i < content, isBlank(u[i]) { i += 1 }
            guard i < content, u[i] != hash else { continue }
            // `export KEY=…`
            if content - i > export.count, u[i..<i + export.count].elementsEqual(export), isBlank(u[i + export.count]) {
                i += export.count
                while i < content, isBlank(u[i]) { i += 1 }
            }
            guard let sign = u[i..<content].firstIndex(of: equals) else { continue }
            var keyEnd = sign
            while keyEnd > i, isBlank(u[keyEnd - 1]) { keyEnd -= 1 }
            guard keyEnd > i, !u[i..<keyEnd].contains(where: isBlank) else { continue }
            var value = sign + 1
            while value < content, isBlank(u[value]) { value += 1 }
            guard value < content else { continue }
            let quote = u[value]
            if quote == 0x22 || quote == 0x27 || quote == 0x60 { // " ' `
                if let close = closing(quote, from: value + 1, to: content) {
                    ranges.append(NSRange(location: value, length: close + 1 - value))
                    continue
                }
                // On a later line, within 200 (as `parse` looks); those lines are part of the value.
                var lineStart = end + 1
                var found = false
                for _ in 0..<200 where lineStart <= u.count {
                    let laterEnd = lineEnd(from: lineStart)
                    if let close = closing(quote, from: lineStart, to: contentEnd(lineStart, laterEnd)) {
                        ranges.append(NSRange(location: value, length: close + 1 - value))
                        next = laterEnd + 1
                        found = true
                        break
                    }
                    lineStart = laterEnd + 1
                }
                if found { continue }
                // Never closed: the rest of the line is the value.
                var last = content
                while last > value, isBlank(u[last - 1]) { last -= 1 }
                ranges.append(NSRange(location: value, length: last - value))
                continue
            }
            // Unquoted: up to a `#` with a blank before it, without the blanks at the end.
            var last = value
            while last < content, !(u[last] == hash && isBlank(u[last - 1])) { last += 1 }
            while last > value, isBlank(u[last - 1]) { last -= 1 }
            if last > value { ranges.append(NSRange(location: value, length: last - value)) }
        }
        return ranges
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
