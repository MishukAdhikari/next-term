import Foundation

extension MCPRedaction {
    /// YAML's own rule for a key with nothing after its `:` but spaces, a comment or a block scalar's header (`|`, `>-`):
    /// the next line with text, if it is indented more than the key's name, holds the key's value. When that line is a
    /// single plain value (no space, quote or `#` in it, 6 characters at least, and not itself a key, `name:`), maybe
    /// with a comment after it, the value is masked for the key's name (`password:` then `    Tr0ub4dor3horse`;
    /// `database:`, `  password:`, then `    Tr0ub4dor3horse`). A line at the same or a lower indent, a key or an item
    /// (`- item`) is never the value, and only a `:` reaches the next line: an `=` stays on its name's line
    /// (`bareValue`). Indented more is the key's indent (spaces and tabs; a list item's dash and the spaces after it
    /// count, `- password:`) and at least one more space or tab. Blank lines between are passed over, and two lines with
    /// text at most: comments, and in a diff a sign alone or the other side's lines. (read_file and find_in_files read
    /// back three lines with text for a value named on a line before its own: `CarriedValues`.) Of a block scalar, only
    /// its first line is read.
    ///
    /// A diff is read a side at a time, each as its own file. This pattern reads the text as it is, or a diff's context
    /// and added lines (a space or a + first), passing its removed lines over; `removedIndentedValue` reads its context and
    /// removed lines. A key's line with a sign (or a space) first takes one on its value's line; one with none takes none.
    /// The groups: a sign first on the key's line, none, its indent, the spaces after a list item's dash, no dash, the
    /// key's name (`indentedName`), the value.
    static let indentedValue: NSRegularExpression = indentedPattern(added: true)

    /// `indentedValue` for a diff's context and removed lines (a space or a - first), its added lines passed over.
    static let removedIndentedValue: NSRegularExpression = indentedPattern(added: false)

    /// The group of the key's name in `indentedValue` and `removedIndentedValue`.
    static let indentedName = 6

    /// The pattern for a diff's added side (lines with a + or a space first, the - lines passed over, and lines with no
    /// sign, the text as it is), or its removed side (a - or a space, the + lines passed over). Group 2, a key's line with
    /// no sign, matches on the added side only, so the groups are the same in each.
    private static func indentedPattern(added: Bool) -> NSRegularExpression {
        let signs: String = added ? #"[+ ]"# : #"[\- ]"#
        let ownSign: String = added ? #"\+"# : "-"
        let otherSign: String = added ? "-" : #"\+"#
        let unsigned: String = added ? "())" : "(?!)())" // a line with no sign: the text as it is
        let first: String = "(?:" + signs + "()|" + unsigned
        let key: String = "^" + first + #"([ \t]*+)(?:-([ \t]++)|())([A-Za-z0-9_.\-]{1,256}+)\h*+:"#
        let header: String = #"(?:\h++[|>](?:[1-9][+\-]?|[+\-][1-9]?)?+)?+"#
        // `(?>.*)`, not `.*+`, and lazy loops over lines: with this many groups, ICU gives up on a possessive loop a few
        // hundred thousand times round (a long comment, many blank lines), and then masks nothing after it.
        let comment: String = #"\h*+(?:(?<=\h)#(?>.*))?+"#
        let blank: String = #"(?:\R\h*+)*?"#
        // A comment, maybe after this side's sign or a space; this side's sign alone; the other side's line. Never a
        // blank line, which `blank` passes over: a line read two ways made the search grow with their product.
        let comments: String = "(?:" + signs + #"\1)?+\h*+#(?>.*)"#
        let alone: String = ownSign + #"\1\h*+$"#
        let otherSide: String = otherSign + #"\1(?>.*)"#
        let passedLines: String = comments + "|" + alone + "|" + otherSide
        let passed: String = #"\R(?:"# + passedLines + ")"
        let indent: String = "(?:" + signs + #"\1|\2)\3(?:[ \t]\4|\5)[ \t]++"#
        let plainValue: String = #"([^\s"'`#]{6,}+)(?<!:)"# + comment + "$"
        let value: String = #"\R"# + indent + plainValue
        let between: String = blank + "(?:" + passed + blank + "){0,2}?"
        return try! NSRegularExpression(pattern: key + header + comment + between + value, options: [.anchorsMatchLines])
    }
}

extension NamedValueBytes {
    /// The lines `indentedValue` (+) and `removedIndentedValue` (-) read: those with the side's own sign or a space first,
    /// the other sign's passed over, and (`plain`) lines with none, the text as it is.
    struct IndentedSide {
        let own: UInt8
        let other: UInt8
        let plain: Bool

        static let both: [IndentedSide] = [
            IndentedSide(own: 0x2B, other: 0x2D, plain: true), IndentedSide(own: 0x2D, other: 0x2B, plain: false),
        ]
    }

    /// A key's line as one way through the pattern reads it: with its side's sign or a space first, or none; its indent;
    /// the spaces after a list item's dash (nil for none); its name; and the line's end after it.
    struct IndentedKey {
        let signed: Bool
        let indent: Range<Int>
        let dash: Range<Int>?
        let name: Range<Int>
        let end: Int
    }

    /// `indentedValue` and `removedIndentedValue`, at each line's start: a key (maybe after its side's sign or a space,
    /// with its indent and a list item's dash), its name, `:` with spaces, a block scalar's header and a comment on its
    /// line, then, past blank lines and two lines with text at most that the pattern passes over, a line that starts as
    /// the key's does and with at least one more space or tab, and holds a value of 6 characters at least with no space,
    /// quote or `#` in it, not ending with `:`, and only spaces and a comment after it.
    func indentedValues() -> [Found] {
        var found: [Found] = []
        var lineStart = 0
        while lineStart < count {
            for side in IndentedSide.both {
                if let indented = indentedValue(key: lineStart, side: side) {
                    let end: Int = indented.lineEnd + lineEnd(indented.lineEnd)
                    found.append(Found(start: lineStart, value: indented.value, end: end))
                }
            }
            var at = lineStart
            while at < count, lineEnd(at) == 0 { at += 1 }
            guard at < count else { break }
            lineStart = at + lineEnd(at)
        }
        return found
    }

    /// The value of the key whose line starts at `start`, as `side`'s pattern finds it: the first way through it that
    /// reaches a value (a sign first, then none; a list item's dash, then none), and where the line's end after the value
    /// and what follows it is (the text's end when none is). Nil when that way's name is no secret's.
    private func indentedValue(key start: Int, side: IndentedSide) -> (value: Range<Int>, lineEnd: Int)? {
        guard start < count else { return nil }
        var ways: [Bool] = []
        if bytes[start] == side.own || bytes[start] == 0x20 { ways.append(true) }
        if side.plain { ways.append(false) }
        for signed in ways {
            for dash in [true, false] {
                guard let key = indentedKey(at: start, signed: signed, dash: dash) else { continue }
                guard let value = indentedValue(after: key, side: side) else { continue }
                return MCPRedaction.isSecretName(text(key.name)) ? value : nil
            }
        }
        return nil
    }
}

extension NamedValueBytes {
    /// The key's line at `start`, read with its side's sign (or a space) first or none, and with a list item's dash or
    /// none; nil when it is no key with nothing after its `:` but spaces, a block scalar's header and a comment.
    private func indentedKey(at start: Int, signed: Bool, dash: Bool) -> IndentedKey? {
        var at = pastIndent(signed ? start + 1 : start)
        let indent = (signed ? start + 1 : start)..<at
        var spaces: Range<Int>?
        if dash {
            guard at < count, bytes[at] == 0x2D else { return nil }
            let after = pastIndent(at + 1)
            guard after > at + 1 else { return nil }
            spaces = at + 1..<after
            at = after
        }
        let first = at
        while at < count, Self.isName(bytes[at]) { at += 1 }
        guard at > first else { return nil }
        let name = first..<at
        at = skipBlanks(at)
        guard at < count, bytes[at] == 0x3A else { return nil }
        at = pastComment(pastBlockHeader(at + 1))
        guard lineEnd(at) > 0 else { return nil } // something after the `:`, or no line after it
        return IndentedKey(signed: signed, indent: indent, dash: spaces, name: name, end: at)
    }

    /// The value under `key`: past blank lines, and two lines the pattern passes over at most with blank lines after
    /// each, the next line's, if it is indented more than the key's name and holds one plain value.
    private func indentedValue(after key: IndentedKey, side: IndentedSide) -> (value: Range<Int>, lineEnd: Int)? {
        var at = pastBlankLines(key.end)
        var passed = 0
        while passed < 2, at < count, let end = passedLine(at: at + lineEnd(at), key: key, side: side) {
            at = pastBlankLines(end)
            passed += 1
        }
        guard at < count else { return nil }
        return valueLine(at: at + lineEnd(at), key: key, side: side)
    }

    /// Past the line at `line` when the pattern passes over it between a key and its value: a comment, after the side's
    /// sign or a space when the key's line has one; or, when the key's line has one, that sign alone, or a line of the
    /// diff's other side, whatever it holds. Nil for another line, and for a blank one.
    private func passedLine(at line: Int, key: IndentedKey, side: IndentedSide) -> Int? {
        var at = line
        if key.signed, at < count, bytes[at] == side.own || bytes[at] == 0x20 { at += 1 }
        at = skipBlanks(at)
        if at < count, bytes[at] == 0x23 { return pastLine(at) }
        guard key.signed, line < count else { return nil }
        if bytes[line] == side.own, case let end = skipBlanks(line + 1), end == count || lineEnd(end) > 0 { return end }
        return bytes[line] == side.other ? pastLine(line) : nil
    }

    /// The value on the line at `line`, if the line starts as the key's does (the side's sign or a space when the key's
    /// line has one, the key's indent, and for a list item's dash a space or tab and the spaces after the dash), then
    /// at least one more space or tab, and holds one plain value with only spaces and a comment after it.
    private func valueLine(at line: Int, key: IndentedKey, side: IndentedSide) -> (value: Range<Int>, lineEnd: Int)? {
        var at = line
        if key.signed {
            guard at < count, bytes[at] == side.own || bytes[at] == 0x20 else { return nil }
            at += 1
        }
        guard repeats(key.indent, at: at) else { return nil }
        at += key.indent.count
        if let dash = key.dash {
            guard at < count, bytes[at] == 0x20 || bytes[at] == 0x09, repeats(dash, at: at + 1) else { return nil }
            at += 1 + dash.count
        }
        let first = pastIndent(at)
        guard first > at else { return nil }
        var end = first
        while end < count, space(end) == 0, !Self.endsABareValue(bytes[end]) { end += 1 }
        guard holds(first..<end, atLeast: 6), bytes[end - 1] != 0x3A else { return nil }
        let rest = pastComment(end)
        guard rest == count || lineEnd(rest) > 0 else { return nil }
        return (first..<end, rest)
    }
}

extension NamedValueBytes {
    /// Past `(?:\h++[|>](?:[1-9][+\-]?|[+\-][1-9]?)?+)?+` at `index`, just after a key's `:`: a block scalar's header,
    /// spaces then `|` or `>`, with an indentation indicator and a chomping one, in either order.
    private func pastBlockHeader(_ index: Int) -> Int {
        let at = skipBlanks(index)
        guard at > index, at < count, bytes[at] == 0x7C || bytes[at] == 0x3E else { return index }
        func digit(_ place: Int) -> Bool { place < count && bytes[place] >= 0x31 && bytes[place] <= 0x39 }
        func chomping(_ place: Int) -> Bool { place < count && (bytes[place] == 0x2B || bytes[place] == 0x2D) }
        var end = at + 1
        if digit(end) {
            end += 1
            if chomping(end) { end += 1 }
        } else if chomping(end) {
            end += 1
            if digit(end) { end += 1 }
        }
        return end
    }

    /// Past `\h*+(?:(?<=\h)#(?>.*))?+` at `index`: spaces, and a comment after one of them, to its line's end. Just after a
    /// key's `:`, a block scalar's header or a value, the character before `index` is none of those spaces.
    private func pastComment(_ index: Int) -> Int {
        let at = skipBlanks(index)
        guard at > index, at < count, bytes[at] == 0x23 else { return at }
        return pastLine(at)
    }

    /// Past the blank lines after `index`, a line's end (`(?:\R\h*+)*?` before a line's end): where it stops is a line's
    /// end, or the text's end.
    private func pastBlankLines(_ index: Int) -> Int {
        var at = index
        while at < count, lineEnd(at) > 0 {
            let next = skipBlanks(at + lineEnd(at))
            guard next == count || lineEnd(next) > 0 else { break }
            at = next
        }
        return at
    }

    /// Where the line that holds `index` ends (`(?>.*)`): at its line's end, or the text's end.
    private func pastLine(_ index: Int) -> Int {
        var at = index
        while at < count, lineEnd(at) == 0 { at += 1 }
        return at
    }

    /// Past the spaces and tabs at `index`.
    private func pastIndent(_ index: Int) -> Int {
        var at = index
        while at < count, bytes[at] == 0x20 || bytes[at] == 0x09 { at += 1 }
        return at
    }

    /// Whether the bytes at `index` are those in `range` (a backreference to a group of spaces and tabs).
    private func repeats(_ range: Range<Int>, at index: Int) -> Bool {
        index + range.count <= count && (0..<range.count).allSatisfy { bytes[index + $0] == bytes[range.lowerBound + $0] }
    }
}
