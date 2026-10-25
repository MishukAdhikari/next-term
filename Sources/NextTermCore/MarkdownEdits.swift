import Foundation

/// Edit › Markdown: each formatting command as one edit of the text (LineEdits.Edit), worked out on the text as the
/// editor holds it. Each changes only what it must, in the markers the file already uses (MarkdownStyle), and never a
/// line it was not given: no other item is renumbered and no table re-padded. Done twice, a toggle gives back the same
/// bytes; undone, any of them does. Lines are read by `lines` (the editor keeps them as it styles; tests read the text
/// from the top), and nil means the command does nothing here (the editor's own Return or Tab then runs).
public enum MarkdownEdits {
    public typealias Edit = LineEdits.Edit
    /// A line as MarkdownSyntax reads it, by its number.
    public typealias Lines = (Int) -> MarkdownSyntax.Line

    public enum Wrap: Sendable {
        case strong, emphasis, strikethrough, code

        var style: MarkdownSyntax.Style {
            switch self {
            case .strong: return .strong
            case .emphasis: return .emphasis
            case .strikethrough: return .strikethrough
            case .code: return .code
            }
        }

        func marker(_ style: MarkdownStyle) -> String {
            switch self {
            case .strong: return style.strong
            case .emphasis: return style.emphasis
            case .strikethrough: return "~~"
            case .code: return "`"
            }
        }
    }

    // MARK: bold, italic, strikethrough, code

    /// Bold, Italic, Strikethrough or Code. A selection that is that span's text (or the span with its markers), or a
    /// caret in one, takes the markers off. Otherwise the selection is wrapped (without the spaces at its ends; in code
    /// with more backticks than any run in it), or the word at the caret, or an empty pair goes in with the caret between
    /// (and comes out again). One line at a time.
    public static func toggleWrap(_ wrap: Wrap, selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines,
                                  style: MarkdownStyle = .standard) -> Edit? {
        guard let (number, line) = oneLine(selection, index), !lines(number).isSource else { return nil }
        let read = lines(number)
        let local = NSRange(location: selection.location - line.location, length: selection.length)
        let core = trimmed(local, in: text, line: line)
        // A done task's text is struck too, by its box, not by markers.
        let spans = read.spans.filter { $0.style.contains(wrap.style) && !$0.style.contains(.dimmed) }
        func markers(_ span: MarkdownSyntax.Span) -> Int {
            guard wrap == .code else { return wrap == .emphasis ? 1 : 2 }
            var count = 0
            while span.range.location - count > 0, text.character(at: line.location + span.range.location - count - 1) == 0x60 { count += 1 }
            return count
        }
        // A code span's text, without the one space at each end that pads a backtick next to its fence.
        func content(_ span: MarkdownSyntax.Span) -> NSRange {
            let r = span.range
            guard wrap == .code, r.length > 2, text.character(at: line.location + r.location) == 0x20,
                  text.character(at: line.location + NSMaxRange(r) - 1) == 0x20,
                  text.substring(with: NSRange(location: line.location + r.location, length: r.length)).contains(where: { $0 != " " })
            else { return r }
            return NSRange(location: r.location + 1, length: r.length - 2)
        }
        let found: MarkdownSyntax.Span? = selection.length > 0
            ? spans.first { span in
                span.range == core || content(span) == core
                    || (span.range.location - markers(span) == core.location && NSMaxRange(span.range) + markers(span) == NSMaxRange(core))
            }
            : spans.filter { $0.range.location <= local.location && local.location <= NSMaxRange($0.range) }.min { $0.range.length < $1.range.length }
        if let span = found {
            let count = markers(span)
            let body = content(span)
            let opening = count + body.location - span.range.location
            let whole = NSRange(location: line.location + span.range.location - count, length: span.range.length + 2 * count)
            let inner = text.substring(with: NSRange(location: line.location + body.location, length: body.length))
            let after = selection.length > 0 ? NSRange(location: whole.location, length: body.length)
                : NSRange(location: min(max(whole.location, selection.location - opening), whole.location + body.length), length: 0)
            return edit(whole, inner, in: text, selection: after)
        }
        var marker = wrap.marker(style)
        // `_` can't open or close inside a word (snake_case stays text, and so would `_中文_段落`): there it is `*`.
        func fitted(_ target: NSRange) -> String {
            guard marker.hasPrefix("_") else { return marker }
            let before = target.location > line.location ? text.character(at: target.location - 1) : 0x20
            let after = NSMaxRange(target) < NSMaxRange(line) ? text.character(at: NSMaxRange(target)) : 0x20
            let inWord = [before, after].contains { unit in Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? true }
            return inWord ? String(repeating: "*", count: marker.count) : marker
        }
        if selection.length > 0 {
            guard core.length > 0 else { return nil }
            let target = NSRange(location: line.location + core.location, length: core.length)
            let inner = text.substring(with: target)
            // Code: a fence one backtick longer than any run inside, and a space where a backtick would touch it.
            var pad = ""
            if wrap == .code {
                marker = String(repeating: "`", count: longestBacktickRun(inner) + 1)
                if inner.hasPrefix("`") || inner.hasSuffix("`") { pad = " " }
            } else {
                marker = fitted(target)
            }
            let opening = (marker as NSString).length + (pad as NSString).length
            return Edit(range: target, text: marker + pad + inner + pad + marker,
                        selection: NSRange(location: target.location + opening, length: target.length))
        }
        let width = (marker as NSString).length
        let caret = selection.location
        // An empty pair, as the command put in: out again.
        if caret - width >= line.location, caret + width <= NSMaxRange(line),
           text.substring(with: NSRange(location: caret - width, length: width)) == marker,
           text.substring(with: NSRange(location: caret, length: width)) == marker {
            return Edit(range: NSRange(location: caret - width, length: 2 * width), text: "", selection: NSRange(location: caret - width, length: 0))
        }
        if let word = word(at: caret, in: text, line: line) {
            marker = fitted(word)
            return Edit(range: word, text: marker + text.substring(with: word) + marker,
                        selection: NSRange(location: caret + (marker as NSString).length, length: 0))
        }
        return Edit(range: NSRange(location: caret, length: 0), text: marker + marker, selection: NSRange(location: caret + width, length: 0))
    }

    // MARK: links

    /// Link: the selection (or the word at the caret) becomes `[text](destination)`, with the caret between the
    /// parentheses when there is no destination yet; with nothing to wrap, `[](…)` with the caret in the brackets. On a
    /// link's text, or the whole link, it takes the link off and leaves the text.
    public static func link(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines, destination: String = "") -> Edit? {
        guard let (number, line) = oneLine(selection, index), !lines(number).isSource else { return nil }
        let read = lines(number)
        let local = NSRange(location: selection.location - line.location, length: selection.length)
        let core = trimmed(local, in: text, line: line)
        let found = read.links.filter { !$0.isImage }.first { link in
            selection.length > 0 ? link.text == core || link.range == core
                : link.text.location <= local.location && local.location <= NSMaxRange(link.text)
        }
        if let link = found {
            let whole = NSRange(location: line.location + link.range.location, length: link.range.length)
            let inner = text.substring(with: NSRange(location: line.location + link.text.location, length: link.text.length))
            let offset = link.text.location - link.range.location
            let after = selection.length > 0 ? NSRange(location: whole.location, length: link.text.length)
                : NSRange(location: min(max(whole.location, selection.location - offset), whole.location + link.text.length), length: 0)
            return edit(whole, inner, in: text, selection: after)
        }
        let target: NSRange
        if selection.length > 0 {
            guard core.length > 0 else { return nil }
            target = NSRange(location: line.location + core.location, length: core.length)
        } else {
            target = word(at: selection.location, in: text, line: line) ?? NSRange(location: selection.location, length: 0)
        }
        let label = text.substring(with: target)
        let replacement = "[" + label + "](" + destination + ")"
        let length = (replacement as NSString).length
        let caret: Int
        if target.length == 0 {
            caret = target.location + 1 // in the brackets
        } else if destination.isEmpty {
            caret = target.location + length - 1 // between the parentheses
        } else {
            caret = target.location + length
        }
        return Edit(range: target, text: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// One web address pasted over selected text on one line: `[text](address)`. Nil (a plain paste) for anything else:
    /// no selection, a selection over lines or in code, more than one address, or an address pasted over an address.
    public static func pastedLink(_ pasted: String, over selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        guard selection.length > 0, NSMaxRange(selection) <= text.length, let (number, line) = oneLine(selection, index) else { return nil }
        let read = lines(number)
        guard !read.isSource else { return nil }
        let local = NSRange(location: selection.location - line.location, length: selection.length)
        let core = trimmed(local, in: text, line: line)
        guard core.length > 0 else { return nil }
        if read.spans.contains(where: { $0.style.contains(.code) && NSIntersectionRange($0.range, core).length > 0 }) { return nil }
        let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = NSRange(location: line.location + core.location, length: core.length)
        let label = text.substring(with: target)
        guard isWebAddress(address), !isWebAddress(label) else { return nil }
        let replacement = "[" + label + "](" + address + ")"
        return Edit(range: target, text: replacement, selection: NSRange(location: target.location + (replacement as NSString).length, length: 0))
    }

    /// One http or https address, with a host and no space in it.
    public static func isWebAddress(_ text: String) -> Bool {
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host.map { !$0.isEmpty } ?? false
    }

    // MARK: headings

    /// Heading 1 to 6, or Body Text (0): only the `#`s at the start of each line change, after any quote and indent, so a
    /// numbered line keeps its number as text (`## 2. item`). Lines already that heading go back to body text.
    public static func heading(_ level: Int, selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        let numbers = Array(LineEdits.lines(touching: selection, in: index))
        let candidates = numbers.filter { !lines($0).isSource && (numbers.count == 1 || lines($0).kind != .blank) }
        guard !candidates.isEmpty else { return nil }
        let atx = candidates.map { number -> (range: NSRange, level: Int) in
            let line = content(of: number, in: index)
            let start = textStart(of: line, in: text)
            var end = start
            while end < NSMaxRange(line), text.character(at: end) == 0x23 { end += 1 }
            let hashes = end - start
            guard (1...6).contains(hashes), end == NSMaxRange(line) || isSpace(text.character(at: end)) else {
                return (NSRange(location: start, length: 0), 0)
            }
            while end < NSMaxRange(line), isSpace(text.character(at: end)) { end += 1 }
            return (NSRange(location: start, length: end - start), hashes)
        }
        let target = level > 0 && atx.allSatisfy { $0.level == level } ? 0 : level
        let prefix = target > 0 ? String(repeating: "#", count: target) + " " : ""
        return combine(atx.map { Replacement(range: $0.range, text: prefix) }, in: text, selection: selection)
    }

    // MARK: lists, tasks and quotes

    /// Bulleted List: lines that are all bullet items lose their markers (a task its box too); otherwise every line gets
    /// the file's bullet, a numbered item in the place of its number.
    public static func toggleBullets(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines,
                                     style: MarkdownStyle = .standard) -> Edit? {
        let candidates = listLines(selection, index, lines)
        guard !candidates.isEmpty else { return nil }
        if candidates.allSatisfy({ lines($0).item.map { !$0.isOrdered } ?? false }) {
            return combine(candidates.compactMap { removal($0, index, lines) }, in: text, selection: selection)
        }
        let replacements = candidates.compactMap { number -> Replacement? in
            let line = content(of: number, in: index)
            guard let item = lines(number).item else {
                return Replacement(range: NSRange(location: textStart(of: line, in: text), length: 0), text: style.bullet + " ")
            }
            guard item.isOrdered else { return nil }
            return Replacement(range: NSRange(location: line.location + item.marker.location, length: item.marker.length), text: style.bullet)
        }
        return combine(replacements, in: text, selection: selection)
    }

    /// Numbered List: lines that are all numbered items lose their numbers; otherwise they are numbered in turn from 1,
    /// or from the number of an item just above, and numbered items among them keep theirs (the count goes on from it).
    public static func toggleNumbers(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines,
                                     style: MarkdownStyle = .standard) -> Edit? {
        let candidates = listLines(selection, index, lines)
        guard let first = candidates.first else { return nil }
        if candidates.allSatisfy({ lines($0).item?.isOrdered ?? false }) {
            return combine(candidates.compactMap { removal($0, index, lines) }, in: text, selection: selection)
        }
        var next = first > 0 ? (lines(first - 1).item?.number).map { $0 + 1 } ?? 1 : 1
        var replacements: [Replacement] = []
        for number in candidates {
            let line = content(of: number, in: index)
            if let item = lines(number).item {
                if let own = item.number {
                    next = own + 1
                    continue
                }
                replacements.append(Replacement(range: NSRange(location: line.location + item.marker.location, length: item.marker.length),
                                                text: "\(next)" + style.orderedDelimiter))
            } else {
                replacements.append(Replacement(range: NSRange(location: textStart(of: line, in: text), length: 0),
                                                text: "\(next)" + style.orderedDelimiter + " "))
            }
            next += 1
        }
        return combine(replacements, in: text, selection: selection)
    }

    /// Toggle Task: on tasks, ticks them (unticks them when all are done), one character each; an item without a box
    /// gets `[ ] `, and a line that is no item the file's bullet and a box.
    public static func toggleTask(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines,
                                  style: MarkdownStyle = .standard) -> Edit? {
        let candidates = listLines(selection, index, lines)
        guard !candidates.isEmpty else { return nil }
        if candidates.allSatisfy({ lines($0).isTask }) {
            let tick = !candidates.allSatisfy { lines($0).item?.done ?? false }
            let replacements = candidates.compactMap { number -> Replacement? in
                guard let item = lines(number).item, let box = item.box, item.done != tick else { return nil }
                return Replacement(range: NSRange(location: content(of: number, in: index).location + box.location + 1, length: 1), text: tick ? "x" : " ")
            }
            return combine(replacements, in: text, selection: selection)
        }
        let replacements = candidates.compactMap { number -> Replacement? in
            let line = content(of: number, in: index)
            guard let item = lines(number).item else {
                return Replacement(range: NSRange(location: textStart(of: line, in: text), length: 0), text: style.bullet + " [ ] ")
            }
            guard item.box == nil else { return nil }
            let at = line.location + item.content
            // An empty item (`- `) may have no space after its marker yet.
            let spaced = item.content > NSMaxRange(item.marker) ? "" : " "
            return Replacement(range: NSRange(location: at, length: 0), text: spaced + "[ ] ")
        }
        return combine(replacements, in: text, selection: selection)
    }

    /// A click on a task's box (`box`, in the text): the one character between the brackets flips, and the selection
    /// stays where it is.
    public static func tick(box: NSRange, in text: NSString, selection: NSRange) -> Edit? {
        guard box.length == 3, NSMaxRange(box) <= text.length, text.character(at: box.location) == 0x5B else { return nil }
        let middle = NSRange(location: box.location + 1, length: 1)
        return Edit(range: middle, text: text.substring(with: middle) == " " ? "x" : " ", selection: selection)
    }

    /// Quote: lines that are all quoted lose one `>` (and the space after it); otherwise each gets `> ` (a blank line
    /// among them `>`, so the quote goes on).
    public static func toggleQuote(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        let numbers = Array(LineEdits.lines(touching: selection, in: index))
        let candidates = numbers.filter { !lines($0).isSource || lines($0).quoteDepth > 0 }
        guard !candidates.isEmpty else { return nil }
        let quoted = candidates.filter { lines($0).kind != .blank || lines($0).quoteDepth > 0 }
        if !quoted.isEmpty, quoted.allSatisfy({ lines($0).quoteDepth > 0 }) {
            let replacements = quoted.compactMap { number -> Replacement? in
                let line = content(of: number, in: index)
                var at = line.location
                while at < NSMaxRange(line), text.character(at: at) == 0x20, at - line.location < 3 { at += 1 }
                guard at < NSMaxRange(line), text.character(at: at) == 0x3E else { return nil }
                let length = at + 1 < NSMaxRange(line) && isSpace(text.character(at: at + 1)) ? 2 : 1
                return Replacement(range: NSRange(location: at, length: length), text: "")
            }
            return combine(replacements, in: text, selection: selection)
        }
        let replacements = candidates.compactMap { number -> Replacement? in
            let line = content(of: number, in: index)
            let read = lines(number)
            guard read.quoteDepth == 0 else { return nil }
            let blank = read.kind == .blank && candidates.count > 1
            return Replacement(range: NSRange(location: line.location, length: 0), text: blank ? ">" : "> ")
        }
        return combine(replacements, in: text, selection: selection)
    }

    /// Code Block: the lines go between fence lines (longer than any run of backticks in them, and indented and quoted
    /// as the first line is); lines that are a fence's whole code come out of it.
    public static func codeBlock(selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        let numbers = LineEdits.lines(touching: selection, in: index)
        let first = numbers.lowerBound, last = numbers.upperBound
        // The code of a fence, whole: the fence lines go.
        if first > 0, last + 1 < index.count, lines(first - 1).kind == .fence, lines(last + 1).kind == .fence,
           numbers.allSatisfy({ lines($0).kind == .code }) {
            let opening = index.range(ofLine: first - 1)
            let closingLine = content(of: last + 1, in: index)
            let closing = NSRange(location: closingLine.location - 1, length: closingLine.length + 1)
            return combine([Replacement(range: opening, text: ""), Replacement(range: closing, text: "")], in: text, selection: selection)
        }
        guard numbers.allSatisfy({ !lines($0).isSource }) else { return nil }
        let start = index.starts[first]
        let end = LineEdits.end(of: last, in: index)
        let longest = longestBacktickRun(text.substring(with: NSRange(location: start, length: end - start)))
        let firstLine = content(of: first, in: index)
        let prefix = text.substring(with: NSRange(location: firstLine.location, length: textStart(of: firstLine, in: text) - firstLine.location))
        let fence = prefix + String(repeating: "`", count: max(3, longest + 1))
        let opening = fence + "\n"
        let after = NSRange(location: selection.location + (opening as NSString).length, length: selection.length)
        return combine([Replacement(range: NSRange(location: start, length: 0), text: opening),
                        Replacement(range: NSRange(location: end, length: 0), text: "\n" + fence)], in: text, selection: after, mapSelection: false)
    }

    // MARK: Return and Tab

    /// Return in a list item makes the next one: the same bullet, or the next number (the items after it keep theirs),
    /// and an open box after a task; in a quote, the next line of the quote. Return on an empty item, or an empty quote
    /// line, takes its marker off, which ends the list or the quote. Nil anywhere else (the editor's own Return).
    public static func newline(at selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        guard selection.length == 0 else { return nil }
        let number = index.line(at: selection.location)
        let line = content(of: number, in: index)
        let read = lines(number)
        let caret = selection.location - line.location
        let quoteEnd = read.drawn.filter { $0.drawing == .quoteBar }.last.map { bar -> Int in
            let after = NSMaxRange(bar.range)
            return after < read.length && isSpace(text.character(at: line.location + after)) ? after + 1 : after
        } ?? 0
        if let item = read.item {
            guard caret >= item.content else { return nil }
            if read.content.length == 0 {
                // An empty item: the list ends here.
                let from = NSRange(location: line.location + quoteEnd, length: line.length - quoteEnd)
                return Edit(range: from, text: "", selection: NSRange(location: from.location, length: 0))
            }
            let lead = text.substring(with: NSRange(location: line.location, length: item.marker.location))
            let marker = item.number.map { "\($0 + 1)" + String(decoding: [item.delimiter], as: UTF16.self) }
                ?? text.substring(with: NSRange(location: line.location + item.marker.location, length: item.marker.length))
            let gapEnd = item.box?.location ?? item.content
            var spacing = text.substring(with: NSRange(location: line.location + NSMaxRange(item.marker), length: gapEnd - NSMaxRange(item.marker)))
            if spacing.isEmpty { spacing = " " }
            var insertion = "\n" + lead + marker + spacing
            if let box = item.box {
                let gap = text.substring(with: NSRange(location: line.location + NSMaxRange(box), length: item.content - NSMaxRange(box)))
                insertion += "[ ]" + (gap.isEmpty ? " " : gap)
            }
            return Edit(range: NSRange(location: selection.location, length: 0), text: insertion,
                        selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        }
        guard read.quoteDepth > 0, !read.isSource || read.kind == .blank, caret >= quoteEnd else { return nil }
        if read.kind == .blank {
            // Only the quote's markers: the quote ends here.
            return Edit(range: line, text: "", selection: NSRange(location: line.location, length: 0))
        }
        let insertion = "\n" + text.substring(with: NSRange(location: line.location, length: quoteEnd))
        return Edit(range: NSRange(location: selection.location, length: 0), text: insertion,
                    selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// Tab (`step` 1) on a list item nests it under the item above, by that item's text column; ⇧Tab (-1) takes it back
    /// out to its parent's column. Nil anywhere else, and over several lines (the editor's own Tab indents them).
    public static func nest(_ step: Int, selection: NSRange, in text: NSString, _ index: LineIndex, lines: Lines) -> Edit? {
        guard LineEdits.lines(touching: selection, in: index).count == 1 else { return nil }
        let number = index.line(at: selection.location)
        guard let item = lines(number).item else { return nil }
        let line = content(of: number, in: index)
        let start = indentStart(of: line, in: text)
        let indent = line.location + item.marker.location - start
        func markerIndent(_ other: Int) -> Int? {
            guard let item = lines(other).item else { return nil }
            let line = content(of: other, in: index)
            return line.location + item.marker.location - indentStart(of: line, in: text)
        }
        // Up the list: items, their indented text and blank lines; a line of text at the margin ends it.
        func walkUp(_ visit: (_ line: Int, _ markerIndent: Int) -> Bool) {
            var above = number - 1
            while above >= 0 {
                if let other = markerIndent(above) {
                    if visit(above, other) { return }
                } else if lines(above).kind != .blank {
                    let line = content(of: above, in: index)
                    if textStart(of: line, in: text) == indentStart(of: line, in: text) { return }
                }
                above -= 1
            }
        }
        if step > 0 {
            // Under the text of the item above at the same depth, or by its own marker's width when it is the first.
            var width = max((item.box?.location ?? item.content) - item.marker.location, item.marker.length + 1)
            walkUp { above, other in
                guard other <= indent, let sibling = lines(above).item else { return false }
                if other == indent { width = (sibling.box?.location ?? sibling.content) - sibling.marker.location }
                return true
            }
            return combine([Replacement(range: NSRange(location: start + indent, length: 0), text: String(repeating: " ", count: width))],
                           in: text, selection: selection)
        }
        guard indent > 0 else { return nil }
        // Out to the column of the item it is in.
        var target = 0
        walkUp { _, other in
            guard other < indent else { return false }
            target = other
            return true
        }
        return combine([Replacement(range: NSRange(location: start + target, length: indent - target), text: "")], in: text, selection: selection)
    }

    // MARK: the parts

    struct Replacement {
        var range: NSRange
        var text: String
    }

    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }

    /// A line's text, without its line break.
    static func content(of line: Int, in index: LineIndex) -> NSRange {
        let start = index.starts[line]
        return NSRange(location: start, length: LineEdits.end(of: line, in: index) - start)
    }

    /// The line a selection is on, if it is on one.
    static func oneLine(_ selection: NSRange, _ index: LineIndex) -> (Int, NSRange)? {
        let number = index.line(at: selection.location)
        let line = content(of: number, in: index)
        return NSMaxRange(selection) <= NSMaxRange(line) ? (number, line) : nil
    }

    /// Where the indentation after a line's quote markers starts.
    static func indentStart(of line: NSRange, in text: NSString) -> Int {
        var at = line.location, quoteEnd = line.location
        while true {
            var probe = at
            while probe < NSMaxRange(line), text.character(at: probe) == 0x20, probe - at < 3 { probe += 1 }
            guard probe < NSMaxRange(line), text.character(at: probe) == 0x3E else { break }
            at = probe + 1
            if at < NSMaxRange(line), isSpace(text.character(at: at)) { at += 1 }
            quoteEnd = at
        }
        return quoteEnd
    }

    /// Where a line's text starts: after its quote markers and its indent.
    static func textStart(of line: NSRange, in text: NSString) -> Int {
        var at = indentStart(of: line, in: text)
        while at < NSMaxRange(line), isSpace(text.character(at: at)) { at += 1 }
        return at
    }

    /// A selection without the spaces at either end, relative to the line.
    static func trimmed(_ local: NSRange, in text: NSString, line: NSRange) -> NSRange {
        var start = local.location, end = NSMaxRange(local)
        while start < end, isSpace(text.character(at: line.location + start)) { start += 1 }
        while end > start, isSpace(text.character(at: line.location + end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The most backticks in a row in a text: a fence around it needs one more.
    static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0, run = 0
        for unit in text.utf16 {
            run = unit == 0x60 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// The word the caret is in or at the end of, if any.
    static func word(at caret: Int, in text: NSString, line: NSRange) -> NSRange? {
        var found: NSRange?
        text.enumerateSubstrings(in: line, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if range.location <= caret, caret <= NSMaxRange(range) {
                found = range
                stop.pointee = true
            } else if range.location > caret {
                stop.pointee = true
            }
        }
        return found
    }

    /// The lines a list or task command changes: those the selection touches but blank ones and code, tables and the
    /// like; a caret on a blank line is that line.
    static func listLines(_ selection: NSRange, _ index: LineIndex, _ lines: Lines) -> [Int] {
        let numbers = Array(LineEdits.lines(touching: selection, in: index))
        if numbers.count == 1, lines(numbers[0]).kind == .blank, lines(numbers[0]).quoteDepth == 0 { return numbers }
        return numbers.filter { !lines($0).isSource && lines($0).kind != .blank }
    }

    /// An item's marker, spaces and box, up to its text.
    static func removal(_ number: Int, _ index: LineIndex, _ lines: Lines) -> Replacement? {
        guard let item = lines(number).item else { return nil }
        let line = content(of: number, in: index)
        return Replacement(range: NSRange(location: line.location + item.marker.location, length: item.content - item.marker.location), text: "")
    }

    /// Several replacements as one edit, from the first to the last with the text between kept. The selection moves
    /// with the text around it (or is given as it is after, with `mapSelection` false). Nil when nothing changes.
    static func combine(_ replacements: [Replacement], in text: NSString, selection: NSRange, mapSelection: Bool = true) -> Edit? {
        let changes = replacements.enumerated()
            .filter { text.substring(with: $0.element.range) != $0.element.text }
            .sorted { ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset) }
            .map(\.element)
        guard let first = changes.first, let last = changes.last else { return nil }
        let start = first.range.location, end = NSMaxRange(last.range)
        var body = ""
        var at = start
        for change in changes {
            body += text.substring(with: NSRange(location: at, length: change.range.location - at)) + change.text
            at = NSMaxRange(change.range)
        }
        func map(_ position: Int) -> Int {
            var shift = 0
            for change in changes {
                let added = (change.text as NSString).length
                if position >= NSMaxRange(change.range) {
                    shift += added - change.range.length
                    continue
                }
                if position > change.range.location { return change.range.location + shift + min(position - change.range.location, added) }
                break
            }
            return position + shift
        }
        var after = selection
        if mapSelection {
            let from = map(selection.location), to = map(NSMaxRange(selection))
            after = NSRange(location: from, length: max(0, to - from))
        }
        return edit(NSRange(location: start, length: end - start), body, in: text, selection: after)
    }

    /// `range` becomes `replacement`, as the smallest edit that does it (what both share at either end is left out).
    static func edit(_ range: NSRange, _ replacement: String, in text: NSString, selection: NSRange) -> Edit {
        let old = text.substring(with: range) as NSString, new = replacement as NSString
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        // Never between the halves of a surrogate pair.
        while prefix > 0, (prefix < old.length && UTF16.isTrailSurrogate(old.character(at: prefix)))
                || (prefix < new.length && UTF16.isTrailSurrogate(new.character(at: prefix))) { prefix -= 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        while suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
        let kept = NSRange(location: prefix, length: new.length - prefix - suffix)
        return Edit(range: NSRange(location: range.location + prefix, length: old.length - prefix - suffix), text: new.substring(with: kept),
                    selection: selection)
    }
}
