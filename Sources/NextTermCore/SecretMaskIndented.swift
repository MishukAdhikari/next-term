import Foundation

extension MCPRedaction {
    /// YAML's own rule for a key with nothing after its `:` (`password:` alone on its line): the next line with text,
    /// if it is indented more than the key's line, holds the key's value. When that line is a single plain value (no
    /// space, quote or `#` in it, 6 characters at least, and not itself a key, `name:`), the value is masked for the
    /// key's name (`password:` then `    Tr0ub4dor3horse`; `database:`, `  password:`, then `    Tr0ub4dor3horse`). A
    /// line at the same or a lower indent, a key or an item (`- item`) is never the value, and only a `:` reaches the
    /// next line: an `=` stays on its name's line (`bareValue`). Indented more is the key's indent (spaces and tabs)
    /// and at least one more space or tab; blank lines between are passed over. In a diff, context lines (a space
    /// first) line up so; lines that start with their + or - do not. The groups: the key's indent, its name, the value.
    static let indentedValue: NSRegularExpression = {
        let key: String = #"^([ \t]*+)"# + assignedName + #"\h*+:\h*+"#
        let blankLines: String = #"(?:\R\h*+)*?"#
        let value: String = #"\R\1[ \t]++([^\s"'`#]{6,}+)(?<!:)\h*+$"#
        return try! NSRegularExpression(pattern: key + blankLines + value, options: [.anchorsMatchLines])
    }()
}

extension NamedValueBytes {
    /// `indentedValue`, at each line's start: a key's indent of spaces and tabs, its name, `:` with spaces on its line,
    /// then, past blank lines, a line that starts with the key's indent and at least one more space or tab, and holds a
    /// value of 6 characters at least with no space, quote or `#` in it, not ending with `:`, and only spaces after it.
    func indentedValues() -> [Found] {
        var found: [Found] = []
        var lineStart = 0
        while lineStart < count {
            if let indented = indentedValue(key: lineStart) {
                let end: Int = indented.lineEnd + lineEnd(indented.lineEnd)
                found.append(Found(start: lineStart, value: indented.value, end: end))
            }
            var at = lineStart
            while at < count, lineEnd(at) == 0 { at += 1 }
            guard at < count else { break }
            lineStart = at + lineEnd(at)
        }
        return found
    }

    /// The value of the key whose line starts at `start`, and where the line's end after it and its spaces is (the
    /// text's end when none is).
    private func indentedValue(key start: Int) -> (value: Range<Int>, lineEnd: Int)? {
        var at = start
        while at < count, bytes[at] == 0x20 || bytes[at] == 0x09 { at += 1 }
        let indent = start..<at
        while at < count, Self.isName(bytes[at]) { at += 1 }
        guard at > indent.upperBound else { return nil }
        let name = indent.upperBound..<at
        at = skipBlanks(at)
        guard at < count, bytes[at] == 0x3A else { return nil }
        at = skipBlanks(at + 1)
        guard lineEnd(at) > 0 else { return nil } // something after the `:`, or no line after it
        var line = at + lineEnd(at)
        while line < count {
            if let value = indentedLine(at: line, indent: indent) {
                return MCPRedaction.isSecretName(text(name)) ? value : nil
            }
            // Only a blank line is passed over: the first line with text is the value's, or there is none.
            let after = skipBlanks(line)
            guard lineEnd(after) > 0 else { return nil }
            line = after + lineEnd(after)
        }
        return nil
    }

    /// The value on the line that starts at `line`, if it starts with `indent` and at least one more space or tab.
    private func indentedLine(at line: Int, indent: Range<Int>) -> (value: Range<Int>, lineEnd: Int)? {
        guard line + indent.count <= count else { return nil }
        guard (0..<indent.count).allSatisfy({ bytes[line + $0] == bytes[indent.lowerBound + $0] }) else { return nil }
        let deeper = line + indent.count
        var first = deeper
        while first < count, bytes[first] == 0x20 || bytes[first] == 0x09 { first += 1 }
        guard first > deeper else { return nil }
        var end = first
        while end < count, space(end) == 0, !Self.endsABareValue(bytes[end]) { end += 1 }
        guard holds(first..<end, atLeast: 6), bytes[end - 1] != 0x3A else { return nil }
        let rest = skipBlanks(end)
        guard rest == count || lineEnd(rest) > 0 else { return nil }
        return (first..<end, rest)
    }
}
