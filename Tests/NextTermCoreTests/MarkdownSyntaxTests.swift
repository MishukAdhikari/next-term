import Foundation
import Testing
@testable import NextTermCore

/// The Markdown scanner, on lines written here and on the fixtures in Fixtures/Markdown (written for Next Term).
@Suite struct MarkdownSyntaxTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Markdown")

    static let fixtureNames = [
        "rules.md", "escapes.md", "lists-tight.md", "tables-aligned.md", "tables-cjk.md", "angle-links.md", "dollars.md",
        "front-matter.md", "fences.md", "html-comments.md", "crlf.md", "numbered-headings.md", "nested-emphasis.md",
    ]

    /// A fixture as the editor holds it (a BOM taken off, CRLF made LF).
    static func fixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
        return try #require(TextFile.decode(data)).text
    }

    /// One line on its own (nothing after it), read after `state`.
    func scan(_ text: String, after state: MarkdownSyntax.LineState = .init()) -> MarkdownSyntax.Line {
        MarkdownSyntax.scan(text as NSString, range: NSRange(location: 0, length: (text as NSString).length), after: state).line
    }

    func hidden(_ text: String) -> [String] {
        scan(text).hidden.map { (text as NSString).substring(with: $0) }
    }

    /// The line as Live Preview shows it: without its hidden characters.
    func shown(_ text: String) -> String {
        shown(text, scan(text))
    }

    func shown(_ text: String, _ line: MarkdownSyntax.Line) -> String {
        let shown = NSMutableString(string: text)
        for range in line.hidden.reversed() { shown.deleteCharacters(in: range) }
        return shown as String
    }

    /// The text each span with `style` covers.
    func spans(_ text: String, _ style: MarkdownSyntax.Style) -> [String] {
        scan(text).spans.filter { $0.style.contains(style) }.map { (text as NSString).substring(with: $0.range) }
    }

    // MARK: inline

    @Test func aHeadingHidesItsHashesBothSides() {
        let line = scan("## Title ##")
        #expect(line.kind == .heading && line.headingLevel == 2)
        #expect(hidden("## Title ##") == ["## ", " ##"])
        #expect(shown("## Title ##") == "Title")
        #expect((("## Title ##" as NSString).substring(with: line.content)) == "Title")
        // A hash ending a word is the title's (C#), and seven are not a heading.
        #expect(shown("## A hash at the end of C#") == "A hash at the end of C#")
        #expect(scan("####### Seven").kind == .paragraph && scan("#Not a heading").kind == .paragraph)
        #expect(scan("###### Six").headingLevel == 6)
    }

    @Test func boldItalicStruckAndCodeHideTheirMarkers() {
        let text = "**a** _b_ ~~c~~ `d`"
        #expect(shown(text) == "a b c d")
        #expect(spans(text, .strong) == ["a"] && spans(text, .emphasis) == ["b"])
        #expect(spans(text, .strikethrough) == ["c"] && spans(text, .code) == ["d"])
        #expect(shown("__also bold__ and *also italic*") == "also bold and also italic")
        #expect(spans("__also bold__", .strong) == ["also bold"])
    }

    @Test func threeStarsAreBoldAndItalicWithAllSixHidden() {
        let text = "***x***"
        #expect(scan(text).hidden.reduce(0) { $0 + $1.length } == 6)
        #expect(shown(text) == "x")
        let x = NSRange(location: 3, length: 1)
        let styles = scan(text).spans.filter { NSIntersectionRange($0.range, x).length > 0 }.reduce(MarkdownSyntax.Style()) { $0.union($1.style) }
        #expect(styles == [.strong, .emphasis])
    }

    @Test func underscoresInsideAWordAreText() {
        #expect(hidden("snake_case_name").isEmpty)
        #expect(hidden("_a_b").isEmpty)
        // A star works inside a word, as CommonMark has it.
        #expect(shown("2*3*4") == "234" && spans("2*3*4", .emphasis) == ["3"])
        #expect(shown("a**b**c") == "abc" && shown("**a**b") == "ab")
        #expect(hidden("a * lone star").isEmpty)
    }

    @Test func charactersBeyondTheBasicPlaneFlankAsTheirKindSays() {
        // An emoji is a symbol, so stars beside it still open and close; a letter from beyond the basic plane is a letter.
        #expect(shown("😀**a**😀") == "😀a😀")
        #expect(hidden("𝐚_b_𝐚").isEmpty)
    }

    @Test func anEscapeHidesItsBackslashOnly() {
        #expect(hidden("\\*not\\*") == ["\\", "\\"])
        #expect(scan("\\*not\\*").hidden == [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)])
        #expect(shown("\\*not italic\\* and \\# not a heading") == "*not italic* and # not a heading")
        // A backslash before a letter is text.
        #expect(hidden("C:\\Users and \\n").isEmpty)
    }

    @Test func aCodeSpanHidesOnlyItsBackticks() {
        #expect(hidden("`a ** b`") == ["`", "`"])
        #expect(shown("`code with \\*stars\\*` keeps them") == "code with \\*stars\\* keeps them")
        #expect(hidden("``a ` b``") == ["``", "``"])
        // An unmatched run is text.
        #expect(hidden("a ` b").isEmpty && hidden("``a`").isEmpty)
    }

    @Test func aLinkHidesItsBracketsAndDestination() {
        let text = "[t](<path with space.md>)"
        let line = scan(text)
        #expect(hidden(text) == ["[", "](<path with space.md>)"])
        #expect(line.links.map(\.destination) == ["path with space.md"])
        #expect(line.links.map { (text as NSString).substring(with: $0.text) } == ["t"])
        #expect(spans(text, .link) == ["t"])
        #expect(shown("A [link](https://example.com \"Title\") here") == "A link here")
        #expect(scan("[a (paren) link](a(b).md)").links.map(\.destination) == ["a(b).md"])
        #expect(shown("[Nested [brackets] inside](page.md)") == "Nested [brackets] inside")
        #expect(scan("[an anchor](other.md#setup)").links.first?.destination == "other.md#setup")
    }

    @Test func autolinksImagesReferencesAndFootnotes() {
        #expect(hidden("<https://example.com/a?b=c>") == ["<", ">"])
        #expect(scan("<https://example.com/a?b=c>").links.first?.destination == "https://example.com/a?b=c")
        #expect(scan("<team@example.com>").links.first?.destination == "mailto:team@example.com")
        // Shown as written.
        let image = scan("![the icon](assets/icon.png)")
        #expect(image.hidden.isEmpty && image.links.first?.isImage == true && image.links.first?.destination == "assets/icon.png")
        #expect(hidden("A [reference link][ref] and a footnote[^1]").isEmpty)
        #expect(hidden("<span title=\"*x*\">a span</span>").isEmpty)
        #expect(hidden("[not a link](").isEmpty && hidden("[x] y").isEmpty)
    }

    @Test func dollarsAreNeverMath() {
        #expect(hidden("| $1,000 | $250 |").isEmpty)
        #expect(hidden("$x + y$ stays $x + y$").isEmpty)
    }

    @Test func emphasisInALinksTextPairsInsideIt() {
        #expect(shown("**[a bold link](page.md)**") == "a bold link")
        #expect(spans("**[a bold link](page.md)**", .strong) == ["[a bold link](page.md)"])
        #expect(shown("[a link with *italic*](page.md)") == "a link with italic")
        // A star in the destination is the destination's.
        #expect(scan("[x](a*b.md) *c*").links.first?.destination == "a*b.md")
        #expect(spans("[x](a*b.md) *c*", .emphasis) == ["c"])
    }

    @Test func aTooLongLineHidesNothing() {
        let long = "**" + String(repeating: "a", count: 6_000) + "**"
        let line = scan(long)
        #expect(line.hidden.isEmpty && line.spans.isEmpty && line.kind == .paragraph)
    }

    // MARK: blocks

    @Test func threeDashesAreARuleAnUnderlineOrFrontMatter() {
        let lines = MarkdownSyntax.lines(of: "A paragraph.\n\n---\n")
        #expect(lines[2].kind == .rule && lines[2].drawn == [.init(range: NSRange(location: 0, length: 3), drawing: .rule)])
        let underline = MarkdownSyntax.lines(of: "Tabs and panes\n---\n")
        #expect(underline[0].kind == .heading && underline[0].headingLevel == 2)
        #expect(underline[1].kind == .setextUnderline && underline[1].setextAbove == 2)
        let top = MarkdownSyntax.lines(of: "---\ntitle: x\n---\n# After\n")
        #expect(top.map(\.kind) == [.frontMatter, .frontMatter, .frontMatter, .heading, .blank])
        // Spaced dashes under text are a rule, and so are stars.
        #expect(MarkdownSyntax.lines(of: "Text\n- - -\n")[1].kind == .rule)
        #expect(MarkdownSyntax.lines(of: "Text\n===\n")[0].headingLevel == 1)
        #expect(scan("***").kind == .rule && scan("--").kind == .paragraph)
    }

    @Test func aFenceClosesOnlyWithAsManyMarkers() {
        let lines = MarkdownSyntax.lines(of: "````\n```\nstill code\n````\nafter **bold**\n")
        #expect(lines.map(\.kind) == [.fence, .code, .code, .fence, .paragraph, .blank])
        #expect(lines[4].hidden.count == 2)
        let tildes = MarkdownSyntax.lines(of: "~~~\n```\n~~~~\n")
        #expect(tildes.map(\.kind) == [.fence, .code, .fence, .blank])
        // Code shows as written.
        #expect(MarkdownSyntax.lines(of: "```\n**x**\n```\n")[1].hidden.isEmpty)
    }

    @Test func anHTMLCommentOverThreeLinesHidesNothing() {
        let lines = MarkdownSyntax.lines(of: "<!-- a comment\nover **three** lines\nthat ends -->\n**bold**\n")
        #expect(lines.map(\.kind) == [.html, .html, .html, .paragraph, .blank])
        #expect(lines[0...2].allSatisfy { $0.hidden.isEmpty })
        #expect(lines[3].hidden.count == 2)
        var state = MarkdownSyntax.LineState()
        let text = "<!-- open\nstill in it\n" as NSString
        state = MarkdownSyntax.scan(text, range: NSRange(location: 0, length: 10), after: state).state
        #expect(state.block == .htmlComment)
        let block = MarkdownSyntax.lines(of: "<div>\n**x**\n\n**y**\n").map { $0.hidden.count }
        #expect(block == [0, 0, 0, 2, 0])
    }

    @Test func listItemsTheirNumbersAndHangs() {
        let ordered = scan("2. item")
        #expect(ordered.kind == .item && ordered.item?.number == 2 && ordered.hang == 3)
        #expect(scan("10. x").hang == 4 && scan("3) y").item?.delimiter == 0x29)
        let bullet = scan("- one")
        #expect(bullet.hang == 2 && bullet.drawn == [.init(range: NSRange(location: 0, length: 1), drawing: .bullet)])
        #expect(scan("  - nested").hang == 4)
        #expect(scan("-not an item").kind == .paragraph && scan("2.not one").kind == .paragraph)
        // An ordered item interrupts a paragraph only at 1, and an empty one never.
        #expect(MarkdownSyntax.lines(of: "Text\n2. two\n")[1].kind == .paragraph)
        #expect(MarkdownSyntax.lines(of: "Text\n1. one\n")[1].kind == .item)
        #expect(MarkdownSyntax.lines(of: "Text\n-\n")[1].kind == .setextUnderline)
    }

    @Test func aTaskHasABoxAndADoneTaskIsStruck() {
        let text = "- [x] done"
        let line = scan(text)
        #expect(line.taskBox == NSRange(location: 2, length: 3) && line.item?.done == true && line.hang == 6)
        #expect(line.drawn == [.init(range: NSRange(location: 0, length: 1), drawing: .blank),
                               .init(range: NSRange(location: 2, length: 3), drawing: .checkbox(done: true))])
        #expect(spans(text, .strikethrough) == ["done"] && spans(text, .dimmed) == ["done"])
        let open = scan("- [ ] an open task")
        #expect(open.item?.done == false && open.spans.isEmpty && open.hang == 6)
        #expect(scan("- [X] capital").item?.done == true)
        #expect(scan("1. [ ] numbered").taskBox == NSRange(location: 3, length: 3))
        #expect(scan("- [ ]not a box").taskBox == nil)
    }

    @Test func quotesDrawABarForEachMarker() {
        let line = scan("> > a quote")
        #expect(line.quoteDepth == 2 && line.drawn.map(\.drawing) == [.quoteBar, .quoteBar])
        #expect(line.hang == 4 && line.kind == .paragraph)
        #expect(scan("> ## Heading").headingLevel == 2 && hidden("> ## Heading") == ["## "])
    }

    @Test func tablesShowAsSource() {
        let lines = MarkdownSyntax.lines(of: "| a | **b** |\n| - | :-: |\n| `c` | d |\n\n**e**\n")
        #expect(lines.map(\.kind) == [.table, .table, .table, .blank, .paragraph, .blank])
        #expect(lines[0...2].allSatisfy { $0.hidden.isEmpty })
        // A pipe with no delimiter row under it is text, and so is a delimiter row of another width.
        #expect(MarkdownSyntax.lines(of: "a | **b**\n")[0].hidden.count == 2)
        #expect(MarkdownSyntax.lines(of: "a | b\n| - |\n")[0].kind == .paragraph)
    }

    @Test func indentedCodeOnlyOutsideListsAndParagraphs() {
        #expect(MarkdownSyntax.lines(of: "Text\n\n    code **x**\n").map(\.kind) == [.paragraph, .blank, .code, .blank])
        #expect(MarkdownSyntax.lines(of: "Text\n    more text\n")[1].kind == .paragraph)
        #expect(MarkdownSyntax.lines(of: "- item\n\n    more of the item\n")[2].kind == .paragraph)
        #expect(MarkdownSyntax.lines(of: "- item\n\nafter\n\n    code\n")[4].kind == .code)
    }

    @Test func definitionsShowAsSource() {
        #expect(scan("[ref]: https://example.com/ref").kind == .definition)
        #expect(scan("[^1]: The footnote's text.").kind == .definition)
        #expect(scan("[ref]: https://example.com/*x*").hidden.isEmpty)
    }

    @Test func markdownFilesByName() {
        #expect(MarkdownSyntax.isMarkdown(fileName: "README.md") && MarkdownSyntax.isMarkdown(fileName: "notes.MARKDOWN"))
        #expect(!MarkdownSyntax.isMarkdown(fileName: "page.mdx") && !MarkdownSyntax.isMarkdown(fileName: "md"))
    }

    // MARK: the fixtures

    /// Whether a line of a fixture shows as written (every character).
    func isSource(_ line: MarkdownSyntax.Line) -> Bool { line.isSource || line.kind == .blank }

    @Test(arguments: fixtureNames) func everyHiddenRangeIsInsideItsLineAndOutsideCode(_ name: String) throws {
        let text = try Self.fixture(name)
        let index = LineIndex(text)
        let lines = MarkdownSyntax.lines(of: text)
        #expect(lines.count == index.count)
        for (number, line) in lines.enumerated() {
            let length = line.length
            for range in line.hidden {
                #expect(range.length > 0 && NSMaxRange(range) <= length, "\(name):\(number + 1)")
                #expect(!isSource(line), "\(name):\(number + 1) hides in a \(line.kind) line")
                for code in line.spans where code.style.contains(.code) {
                    #expect(NSIntersectionRange(range, code.range).length == 0, "\(name):\(number + 1) hides inside a code span")
                }
            }
            // In order and apart.
            for (a, b) in zip(line.hidden, line.hidden.dropFirst()) { #expect(NSMaxRange(a) < b.location, "\(name):\(number + 1)") }
            for drawn in line.drawn { #expect(NSMaxRange(drawn.range) <= length, "\(name):\(number + 1)") }
        }
    }

    /// An edit reads again from its line with the state the line before ended in: that must give what reading from the
    /// top gives.
    @Test(arguments: fixtureNames) func readingFromAnyLinesStateAgreesWithTheTop(_ name: String) throws {
        let text = try Self.fixture(name)
        let source = text as NSString
        let index = LineIndex(text)
        var states: [MarkdownSyntax.LineState] = []
        var lines: [MarkdownSyntax.Line] = []
        var state = MarkdownSyntax.LineState()
        for line in 0..<index.count {
            states.append(state)
            let read = MarkdownSyntax.scan(source, range: index.range(ofLine: line), after: state)
            lines.append(read.line)
            state = read.state
        }
        for line in 0..<index.count {
            let again = MarkdownSyntax.scan(source, range: index.range(ofLine: line), after: states[line])
            #expect(again.line == lines[line], "\(name):\(line + 1)")
            if line + 1 < index.count { #expect(again.state == states[line + 1], "\(name):\(line + 1)") }
        }
    }

    @Test func theFixturesReadAsWritten() throws {
        func kinds(_ name: String) throws -> [MarkdownSyntax.Kind] { MarkdownSyntax.lines(of: try Self.fixture(name)).map(\.kind) }
        let front = MarkdownSyntax.lines(of: try Self.fixture("front-matter.md"))
        #expect(front.prefix(7).allSatisfy { $0.kind == .frontMatter } && front[8].kind == .heading)
        #expect(front[10].hidden.count == 4) // the code span's backticks and the bold's stars
        let fences = try kinds("fences.md")
        #expect(fences[2...4] == [.fence, .code, .fence] && fences[6...10] == [.fence, .code, .code, .code, .fence])
        #expect(fences[16...17] == [.code, .code] && fences.suffix(3) == [.fence, .code, .code])
        let html = MarkdownSyntax.lines(of: try Self.fixture("html-comments.md"))
        #expect(html[2...4].allSatisfy { $0.kind == .html && $0.hidden.isEmpty })
        #expect(html[13].kind == .paragraph && html[13].hidden.count == 2)
        let tables = try kinds("tables-aligned.md")
        #expect(tables[2...6].allSatisfy { $0 == .table } && tables[8...11].allSatisfy { $0 == .table } && tables[13] == .paragraph)
        let cjk = MarkdownSyntax.lines(of: try Self.fixture("tables-cjk.md"))
        #expect(cjk[2...6].allSatisfy { $0.kind == .table && $0.hidden.isEmpty })
        let cjkText = try Self.fixture("tables-cjk.md")
        let paragraph = (cjkText as NSString).substring(with: LineIndex(cjkText).range(ofLine: 8))
        #expect(shown(paragraph.trimmingCharacters(in: .newlines), cjk[8]) == "中文段落里有粗体和斜体，还有代码。")
        let lists = MarkdownSyntax.lines(of: try Self.fixture("lists-tight.md"))
        #expect(lists[2...6].allSatisfy { $0.kind == .item } && lists[16...19].allSatisfy(\.isTask))
        #expect(lists[21].kind == .paragraph && lists[22].kind == .paragraph)
        // The trailing double space and backslash ending a line stay shown.
        let escapes = MarkdownSyntax.lines(of: try Self.fixture("escapes.md"))
        #expect(escapes[8].hidden.isEmpty && escapes[9].hidden.isEmpty)
    }

    @Test func aCRLFFileReadsTheSameWithItsCarriageReturns() throws {
        let raw = try #require(String(data: Data(contentsOf: Self.fixtures.appendingPathComponent("crlf.md")), encoding: .utf8))
        #expect(raw.contains("\r\n"))
        let held = MarkdownSyntax.lines(of: try Self.fixture("crlf.md"))
        // Each line read with its "\r" still there (as in a file with mixed line endings) gives the same syntax.
        let withCR = MarkdownSyntax.lines(of: raw)
        #expect(held.map(\.hidden) == withCR.map(\.hidden) && held.map(\.kind) == withCR.map(\.kind))
        #expect(held[2].hidden.count == 2 && held[7].hidden.count == 4 && held[5].taskBox != nil)
    }
}
