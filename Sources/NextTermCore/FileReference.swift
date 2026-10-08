import Foundation

/// Where a ⌘-clicked path in terminal output points: a file, and a place in it. SwiftTerm hands over only
/// the link's own text; the line it sits in says the rest. A Python traceback writes
/// `File "/…/graph.py", line 42, in call_model`, pytest `tests/test_x.py:42: in test_x`, mypy and ruff
/// `app.py:42:7: error`, and langgraph.json names a graph `./src/agent/graph.py:graph`.
public struct FileReference: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?
    /// A name whose definition to go to (`graph.py:graph`).
    public var symbol: String?

    public init(path: String, line: Int? = nil, column: Int? = nil, symbol: String? = nil) {
        self.path = path
        self.line = line
        self.column = column
        self.symbol = symbol
    }

    /// `link` as the terminal found it; `row` the clicked line's text (wrapped rows joined), if known.
    /// `absolute` turns a path as printed into one on disk (relative paths are the tab's folder's), and
    /// `exists` says whether a file is there. nil: nothing to open.
    public static func resolve(link: String, row: String?, absolute: (String) -> String,
                               exists: (String) -> Bool) -> FileReference? {
        // The link is a file as it is: where in it, the row may say.
        let whole = absolute(link)
        if exists(whole) {
            var reference = FileReference(path: whole)
            if let row, let place = place(after: link, in: row) {
                reference.line = place.line
                reference.column = place.column
            }
            return reference
        }
        // "src/a.ts:42:7", "tests/test_x.py:42:" (the numbers are part of the link), and "src/a.ts:42-48", lines
        // as the editor's Copy Path with Line gives them, which opens at the first.
        if let range = link.range(of: #":[0-9]+(:[0-9]+|-[0-9]+)?:?$"#, options: .regularExpression) {
            let numbers = link[range].split(separator: ":").compactMap { Int($0.split(separator: "-").first ?? "") }
            let path = absolute(String(link[..<range.lowerBound]))
            if exists(path) { return FileReference(path: path, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil) }
        }
        // "./src/agent/graph.py:graph": a module and a name in it.
        if let match = link.firstMatch(of: #/^(.+\.(?:py|pyi|js|mjs|cjs|ts|mts|cts|tsx|jsx)):([A-Za-z_$][A-Za-z0-9_$]*)$/#) {
            let path = absolute(String(match.1))
            if exists(path) { return FileReference(path: path, symbol: String(match.2)) }
        }
        return nil
    }

    /// The line (and column) the row gives for `link`: a traceback's `File "<link>", line N`, or
    /// `<link>:N` / `<link>:N:M` right after it.
    static func place(after link: String, in row: String) -> (line: Int, column: Int?)? {
        // Python: File "/path/graph.py", line 42, in call_model (the link may be the path, or end it).
        for match in row.matches(of: #/File "([^"]+)", line ([0-9]+)/#) {
            let quoted = String(match.1)
            if quoted == link || quoted.hasSuffix(link) || link.hasSuffix(quoted), let line = Int(match.2) {
                return (line, nil)
            }
        }
        // pytest, mypy, ruff, compilers: path:42: / path:42:7:
        var searchFrom = row.startIndex
        while let found = row.range(of: link, range: searchFrom..<row.endIndex) {
            let rest = row[found.upperBound...]
            if let match = rest.prefixMatch(of: #/:([0-9]+)(?::([0-9]+))?/#), let line = Int(match.1) {
                return (line, match.2.flatMap { Int($0) })
            }
            searchFrom = found.upperBound
        }
        return nil
    }

    /// The 1-based line where `symbol` is defined in a Python, JavaScript or TypeScript file: `def`,
    /// `class`, `function`, `const`/`let`/`var`, or an assignment at the start of a line (`graph =`,
    /// `graph: CompiledGraph =`). nil: not found.
    public static func definitionLine(of symbol: String, in text: String) -> Int? {
        let name = NSRegularExpression.escapedPattern(for: symbol)
        let patterns = [
            #"^\s*(?:async\s+)?(?:def|class)\s+"# + name + #"\b"#,
            #"^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:async\s+)?(?:function\*?|class|const|let|var)\s+"# + name + #"\b"#,
            "^" + name + #"\s*(?::[^=\n]*)?=(?!=)"#,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
        var number = 0
        var found: Int?
        text.enumerateLines { line, stop in
            number += 1
            let range = NSRange(line.startIndex..., in: line)
            if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                found = number
                stop = true
            }
        }
        return found
    }
}
