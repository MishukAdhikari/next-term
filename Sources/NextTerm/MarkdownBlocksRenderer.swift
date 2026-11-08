import AppKit
import NextTermCore

/// Markdown blocks (`ReleaseNotes.blocks`) as attributed text: headings, nested lists, paragraphs, fenced code, and
/// bold, italics, inline code and web links inside them. The update window's release notes and a chat tab's agent
/// messages both draw through it; each passes its own sizes and spacing (`Style`).
enum MarkdownBlocksRenderer {
    /// The sizes and spacing one reader of Markdown draws with. The defaults are the update window's.
    struct Style {
        var body: CGFloat = 13
        /// Level 1 and 2 headings; deeper ones use `smallHeading`.
        var largeHeading: CGFloat = 15
        var smallHeading: CGFloat = 13
        var code: CGFloat = 12
        var color: NSColor = .labelColor
        var indentStep: CGFloat = 18
        var lineSpacing: CGFloat = 2
        var paragraphAfter: CGFloat = 6
        var listAfter: CGFloat = 4
        var headingBefore: CGFloat = 12
        var headingAfter: CGFloat = 4
        var codeBefore: CGFloat = 2
        var codeAfter: CGFloat = 8
        /// Fenced code's inset from the left, and from the right when `codeAttributes` gives it a panel.
        var codeInset: CGFloat = 8
        /// Headings sit one level lower (a release's notes under its own version heading).
        var nested = false
        /// Extra attributes over each fenced code block, such as a chat's tinted panel. Code lines are separate
        /// paragraphs; with these set, only the first takes `codeBefore` and only the last `codeAfter`, so the block
        /// reads as one.
        var codeAttributes: [NSAttributedString.Key: Any]?
        /// Every paragraph's extra indent, for a block quote's text.
        var leading: CGFloat = 0
    }

    /// `block` appended to `out`, each paragraph ending in a line break.
    static func render(_ block: ReleaseNotes.Block, style: Style, into out: NSMutableAttributedString) {
        let body = NSFont.systemFont(ofSize: style.body)
        switch block {
        case let .heading(level, text):
            let size = level + (style.nested ? 1 : 0) <= 2 ? style.largeHeading : style.smallHeading
            let paragraph = self.paragraph(style, before: out.length == 0 ? 0 : style.headingBefore, after: style.headingAfter)
            append(out, text, font: .systemFont(ofSize: size, weight: .semibold), color: style.color, style: paragraph, markdown: true)
        case let .bullet(depth, text):
            append(out, (depth == 0 ? "\u{2022}" : "\u{25E6}") + "\t" + text, font: body, color: style.color,
                   style: list(style, depth: depth), markdown: true)
        case let .numbered(depth, number, text):
            append(out, number + ".\t" + text, font: body, color: style.color, style: list(style, depth: depth), markdown: true)
        case let .paragraph(depth, text):
            let paragraph = self.paragraph(style, before: 0, after: style.paragraphAfter)
            paragraph.firstLineHeadIndent = style.leading + CGFloat(depth) * style.indentStep
            paragraph.headIndent = paragraph.firstLineHeadIndent
            append(out, text, font: body, color: style.color, style: paragraph, markdown: true)
        case let .code(text):
            code(text, style: style, into: out)
        }
    }

    private static func code(_ text: String, style: Style, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: style.code, weight: .regular)
        guard let extra = style.codeAttributes else {
            let paragraph = self.paragraph(style, before: style.codeBefore, after: style.codeAfter)
            paragraph.firstLineHeadIndent = style.leading + style.codeInset
            paragraph.headIndent = paragraph.firstLineHeadIndent
            append(out, text, font: font, color: style.color, style: paragraph)
            return
        }
        let lines = text.components(separatedBy: "\n")
        let start = out.length
        for (index, line) in lines.enumerated() {
            let paragraph = self.paragraph(style, before: index == 0 ? style.codeBefore : 0,
                                           after: index == lines.count - 1 ? style.codeAfter : 0)
            paragraph.firstLineHeadIndent = style.leading + style.codeInset
            paragraph.headIndent = paragraph.firstLineHeadIndent
            paragraph.tailIndent = -style.codeInset
            append(out, line, font: font, color: style.color, style: paragraph)
        }
        out.addAttributes(extra, range: NSRange(location: start, length: out.length - start))
    }

    static func paragraph(_ style: Style, before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.lineSpacing = style.lineSpacing
        return paragraph
    }

    /// The marker hangs in the margin; wrapped lines line up with the text after it.
    private static func list(_ style: Style, depth: Int) -> NSMutableParagraphStyle {
        let paragraph = self.paragraph(style, before: 0, after: style.listAfter)
        let start = style.leading + CGFloat(depth) * style.indentStep
        paragraph.firstLineHeadIndent = start
        paragraph.headIndent = start + style.indentStep
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: start + style.indentStep)]
        paragraph.defaultTabInterval = style.indentStep
        return paragraph
    }

    static func append(_ out: NSMutableAttributedString, _ text: String, font: NSFont, color: NSColor,
                       style: NSParagraphStyle, markdown: Bool = false) {
        let line = markdown ? inline(text, font: font, color: color)
            : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let piece = NSMutableAttributedString(attributedString: line)
        piece.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        out.append(piece)
    }

    /// Bold, italics, code and links inside one block. Only web links are followed.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
                }
            }
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
                attributes[.toolTip] = link.absoluteString
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    // MARK: an agent's message

    /// The parts of an agent's message that `ReleaseNotes.blocks` doesn't know: block quotes and tables, found outside
    /// fenced code.
    enum Part: Equatable {
        case markdown(String)
        case quote(String)
        case table([String])
    }

    static func parts(_ markdown: String) -> [Part] {
        var parts: [Part] = []
        var lines: [String] = []
        var kind = 0 // 0 Markdown, 1 quote, 2 table
        var fenced = false

        func flush() {
            guard !lines.isEmpty else { return }
            switch kind {
            case 1: parts.append(.quote(lines.joined(separator: "\n")))
            case 2: parts.append(.table(lines))
            default: parts.append(.markdown(lines.joined(separator: "\n")))
            }
            lines = []
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var lineKind = 0
            var line = raw
            if fenced {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced = false }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenced = true
            } else if trimmed.hasPrefix(">") {
                lineKind = 1
                line = String(trimmed.dropFirst())
                if line.hasPrefix(" ") { line.removeFirst() }
            } else if trimmed.hasPrefix("|"), trimmed.count > 1 {
                lineKind = 2
                line = trimmed
            }
            if lineKind != kind {
                flush()
                kind = lineKind
            }
            lines.append(line)
        }
        flush()
        return parts
    }

    /// An agent's message: Markdown, with block quotes behind a bar (`quoteAttributes`) and tables in aligned
    /// columns. A fence still open (a message still streaming) is drawn as code already, so the text doesn't jump
    /// when it closes.
    static func message(_ markdown: String, style: Style, quoteAttributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for part in parts(markdown) {
            switch part {
            case .markdown(let text):
                for block in ReleaseNotes.blocks(text, keepingEverySection: true) { render(block, style: style, into: out) }
            case .quote(let text):
                var quoted = style
                quoted.leading += 14
                quoted.color = .secondaryLabelColor
                let start = out.length
                for block in ReleaseNotes.blocks(text, keepingEverySection: true) { render(block, style: quoted, into: out) }
                if out.length > start { out.addAttributes(quoteAttributes, range: NSRange(location: start, length: out.length - start)) }
            case .table(let rows):
                table(rows, style: style, into: out)
            }
        }
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// A Markdown table's rows in aligned monospaced columns, the header row bold and its rule drawn as a line.
    private static func table(_ rows: [String], style: Style, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: style.code, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: style.code, weight: .semibold)
        let cells: [[String]] = rows.map(tableCells)
        let isRule: [Bool] = cells.map { row in
            !row.isEmpty && row.allSatisfy { cell in
                let bare = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !bare.isEmpty && bare.allSatisfy { $0 == "-" }
            }
        }
        let header = isRule.count > 1 && isRule[1]
        var rendered: [[NSAttributedString]] = []
        for (index, row) in cells.enumerated() {
            let rowFont = header && index == 0 ? bold : font
            rendered.append(row.map { inline($0, font: rowFont, color: style.color) })
        }
        var widths: [Int] = []
        for (index, row) in rendered.enumerated() where !isRule[index] {
            for (column, cell) in row.enumerated() {
                if column >= widths.count { widths.append(0) }
                widths[column] = max(widths[column], cell.length)
            }
        }
        for (index, row) in rendered.enumerated() {
            let line = NSMutableAttributedString()
            if isRule[index] {
                let rule = widths.map { String(repeating: "\u{2500}", count: max($0, 1)) }.joined(separator: "\u{2500}\u{2500}")
                line.append(NSAttributedString(string: rule, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            } else {
                for (column, cell) in row.enumerated() {
                    if column > 0 { line.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
                    line.append(cell)
                    let pad = (column < widths.count ? widths[column] : 0) - cell.length
                    if pad > 0, column < row.count - 1 {
                        line.append(NSAttributedString(string: String(repeating: " ", count: pad), attributes: [.font: font]))
                    }
                }
            }
            let paragraph = self.paragraph(style, before: index == 0 ? style.codeBefore : 0,
                                           after: index == rendered.count - 1 ? style.codeAfter : 0)
            paragraph.firstLineHeadIndent = style.leading
            paragraph.headIndent = style.leading
            line.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
    }

    /// One table row's cells, trimmed, without the outer bars.
    static func tableCells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
