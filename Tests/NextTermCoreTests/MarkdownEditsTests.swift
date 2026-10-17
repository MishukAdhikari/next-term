import Foundation
import Testing
@testable import NextTermCore

/// Edit › Markdown's commands, on texts written with the selection in them: "|" is the caret, "«" and "»" go around a
/// selection (Markdown has its own brackets). And on every line of the fixtures in Fixtures/Markdown.
@Suite struct MarkdownEditsTests {
    typealias Make = (NSRange, NSString, LineIndex, MarkdownEdits.Lines) -> LineEdits.Edit?

    /// A selection first, so a table's "|"s can be text around one.
    static func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let units = marked as NSString
        let open = units.range(of: "«"), close = units.range(of: "»")
        if open.location != NSNotFound {
            let text = marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            return (text, NSRange(location: open.location, length: close.location - open.location - 1))
        }
        let caret = units.range(of: "|")
        return (units.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
    }

    static func mark(_ text: String, _ selection: NSRange) -> String {
        let units = NSMutableString(string: text)
        if selection.length == 0 {
            units.insert("|", at: selection.location)
        } else {
            units.insert("»", at: NSMaxRange(selection))
            units.insert("«", at: selection.location)
        }
        return units as String
    }

    /// The edit on `text`, its lines read from the top.
    static func edit(_ text: String, _ selection: NSRange, _ make: Make) -> LineEdits.Edit? {
        let lines = MarkdownSyntax.lines(of: text)
        return make(selection, text as NSString, LineIndex(text)) { lines[$0] }
    }

    static func apply(_ edit: LineEdits.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }

    /// The marked text after the command, or nil when it does nothing.
    func run(_ marked: String, _ make: Make) -> String? {
        let (text, selection) = Self.parse(marked)
        guard let edit = Self.edit(text, selection, make) else { return nil }
        return Self.mark(Self.apply(edit, to: text), edit.selection)
    }

    static func wrap(_ wrap: MarkdownEdits.Wrap, _ style: MarkdownStyle = .standard) -> Make {
        { MarkdownEdits.toggleWrap(wrap, selection: $0, in: $1, $2, lines: $3, style: style) }
    }
    static let bold = wrap(.strong), italic = wrap(.emphasis), strike = wrap(.strikethrough), code = wrap(.code)
    static let link: Make = { MarkdownEdits.link(selection: $0, in: $1, $2, lines: $3) }
    static func heading(_ level: Int) -> Make { { MarkdownEdits.heading(level, selection: $0, in: $1, $2, lines: $3) } }
    static let bullets: Make = { MarkdownEdits.toggleBullets(selection: $0, in: $1, $2, lines: $3) }
    static let numbers: Make = { MarkdownEdits.toggleNumbers(selection: $0, in: $1, $2, lines: $3) }
    static let task: Make = { MarkdownEdits.toggleTask(selection: $0, in: $1, $2, lines: $3) }
    static let quote: Make = { MarkdownEdits.toggleQuote(selection: $0, in: $1, $2, lines: $3) }
    static let codeBlock: Make = { MarkdownEdits.codeBlock(selection: $0, in: $1, $2, lines: $3) }
    static let newline: Make = { MarkdownEdits.newline(at: $0, in: $1, $2, lines: $3) }
    static let nest: Make = { MarkdownEdits.nest(1, selection: $0, in: $1, $2, lines: $3) }
    static let unnest: Make = { MarkdownEdits.nest(-1, selection: $0, in: $1, $2, lines: $3) }

    // MARK: wrapping

    @Test func boldWrapsAndUnwraps() {
        #expect(run("a «sel» b", Self.bold) == "a **«sel»** b")
        #expect(run("a **«sel»** b", Self.bold) == "a «sel» b")
        #expect(run("a «**sel**» b", Self.bold) == "a «sel» b")
        // The word at the caret, and back.
        #expect(run("wo|rd x", Self.bold) == "**wo|rd** x")
        #expect(run("**wo|rd** x", Self.bold) == "wo|rd x")
        // With no word, an empty pair, and out again.
        #expect(run("a | b", Self.bold) == "a **|** b")
        #expect(run("a **|** b", Self.bold) == "a | b")
        // The spaces at a selection's ends stay outside.
        #expect(run("a « sel » b", Self.italic) == "a  _«sel»_  b")
        // Inside a word, `_` would be text: italic and bold there are stars.
        #expect(run("snake«case»name", Self.italic) == "snake*«case»*name")
        #expect(run("中文«粗体»段落", Self.wrap(.strong, MarkdownStyle(strong: "__"))) == "中文**«粗体»**段落")
        // Over lines, nothing.
        #expect(run("«a\nb»", Self.bold) == nil)
    }

    @Test func eachWrapTakesOnlyItsOwnMarkers() {
        #expect(run("***«x»***", Self.bold) == "*«x»*")
        #expect(run("***x|***", Self.italic) == "**x|**")
        #expect(run("**bo|ld**", Self.italic) == "**_bo|ld_**")
        #expect(run("a «struck» b", Self.strike) == "a ~~«struck»~~ b")
        #expect(run("a ~~st|ruck~~ b", Self.strike) == "a st|ruck b")
        #expect(run("x «code» y", Self.code) == "x `«code»` y")
        #expect(run("x `co|de` y", Self.code) == "x co|de y")
        #expect(run("x ``a ` b|`` y", Self.code) == "x a ` b| y")
        // In code, a table or HTML, nothing.
        #expect(run("```\nwo|rd\n```", Self.bold) == nil)
        #expect(run("| a | «word» |\n| - | - |", Self.bold) == nil)
    }

    @Test func theFilesOwnMarkers() {
        let style = MarkdownStyle.detect(in: "__a__ and *b* and __c__\n* x\n* y\n1) z\n")
        #expect(style == MarkdownStyle(strong: "__", emphasis: "*", bullet: "*", orderedDelimiter: ")"))
        #expect(run("a «b» c", Self.wrap(.strong, style)) == "a __«b»__ c")
        #expect(run("a «b» c", Self.wrap(.emphasis, style)) == "a *«b»* c")
        // Without any, what common formatters write; a tie keeps those.
        #expect(MarkdownStyle.detect(in: "plain text\n") == .standard)
        #expect(MarkdownStyle.detect(in: "**a** __b__\n").strong == "**")
        let bullets: Make = { MarkdownEdits.toggleBullets(selection: $0, in: $1, $2, lines: $3, style: style) }
        #expect(run("«one»", bullets) == "* «one»")
    }

    @Test func linksWrapAndUnwrap() {
        #expect(run("see «docs» here", Self.link) == "see [docs](|) here")
        #expect(run("see [d|ocs](x.md) here", Self.link) == "see d|ocs here")
        #expect(run("see «[docs](x.md)» here", Self.link) == "see «docs» here")
        #expect(run("a | b", Self.link) == "a [|]() b")
        let withAddress: Make = { MarkdownEdits.link(selection: $0, in: $1, $2, lines: $3, destination: "https://a.b") }
        #expect(run("see «docs» here", withAddress) == "see [docs](https://a.b)| here")
    }

    @Test func pastingAnAddressOverTextMakesALink() {
        func paste(_ pasted: String, _ marked: String) -> String? {
            let (text, selection) = Self.parse(marked)
            let lines = MarkdownSyntax.lines(of: text)
            return MarkdownEdits.pastedLink(pasted, over: selection, in: text as NSString, LineIndex(text), lines: { lines[$0] })
                .map { Self.mark(Self.apply($0, to: text), $0.selection) }
        }
        #expect(paste("https://a.b/c", "see «docs» here") == "see [docs](https://a.b/c)| here")
        #expect(paste("  https://a.b/c\n", "«docs»") == "[docs](https://a.b/c)|")
        // A plain paste: two addresses, over lines, nothing selected, not an address, over an address, in code.
        #expect(paste("https://a.b https://c.d", "«docs»") == nil)
        #expect(paste("https://a.b", "«do\ncs»") == nil)
        #expect(paste("https://a.b", "do|cs") == nil)
        #expect(paste("ftp://a.b", "«docs»") == nil && paste("words", "«docs»") == nil)
        #expect(paste("https://a.b", "«https://c.d»") == nil)
        #expect(paste("https://a.b", "`«docs»`") == nil)
    }

    // MARK: headings

    @Test func headingsChangeOnlyTheHashes() {
        #expect(run("2. it|em", Self.heading(2)) == "## 2. it|em")
        #expect(run("## Ti|tle", Self.heading(2)) == "Ti|tle")
        #expect(run("## Ti|tle", Self.heading(3)) == "### Ti|tle")
        #expect(run("#### T|", Self.heading(0)) == "T|")
        #expect(run("|", Self.heading(1)) == "# |")
        #expect(run("> quo|te", Self.heading(2)) == "> ## quo|te")
        #expect(run("«one\n\ntwo»", Self.heading(1)) == "# «one\n\n# two»")
        #expect(run("plain|", Self.heading(0)) == nil)
    }

    // MARK: lists, tasks, quotes and code blocks

    @Test func bulletedAndNumberedLists() {
        #expect(run("«one\ntwo»", Self.bullets) == "- «one\n- two»")
        #expect(run("«- one\n- two»", Self.bullets) == "«one\ntwo»")
        #expect(run("1. a|", Self.bullets) == "- a|")
        #expect(run("- [ ] t|", Self.bullets) == "t|")
        #expect(run("«one\ntwo»", Self.numbers) == "1. «one\n2. two»")
        // The count goes on from an item above, and the items after are left as they are.
        #expect(run("1. a\n«b\nc»\n7. d", Self.numbers) == "1. a\n2. «b\n3. c»\n7. d")
        #expect(run("«1. a\n2. b»", Self.numbers) == "«a\nb»")
        #expect(run("- a|", Self.numbers) == "1. a|")
    }

    @Test func toggleTaskTicksAndAddsBoxes() {
        #expect(run("- [ ] a|", Self.task) == "- [x] a|")
        #expect(run("- [x] a|", Self.task) == "- [ ] a|")
        #expect(run("- a|", Self.task) == "- [ ] a|")
        #expect(run("pla|in", Self.task) == "- [ ] pla|in")
        #expect(run("- |", Self.task) == "- [ ] |")
        #expect(run("|", Self.task) == "- [ ] |")
        // All done: untick them all; any open: tick the open ones.
        #expect(run("«- [x] a\n- [ ] b»", Self.task) == "«- [x] a\n- [x] b»")
        #expect(run("«- [x] a\n- [X] b»", Self.task) == "«- [ ] a\n- [ ] b»")
    }

    @Test func aTickFlipsOneCharacterAndKeepsTheCaret() {
        let text = "- [ ] a\n- [X] b\n" as NSString
        let open = MarkdownEdits.tick(box: NSRange(location: 2, length: 3), in: text, selection: NSRange(location: 15, length: 0))
        #expect(open == LineEdits.Edit(range: NSRange(location: 3, length: 1), text: "x", selection: NSRange(location: 15, length: 0)))
        let done = MarkdownEdits.tick(box: NSRange(location: 10, length: 3), in: text, selection: NSRange(location: 0, length: 0))
        #expect(done?.range == NSRange(location: 11, length: 1) && done?.text == " ")
        #expect(MarkdownEdits.tick(box: NSRange(location: 0, length: 3), in: text, selection: NSRange()) == nil)
    }

    @Test func quotesAndCodeBlocks() {
        #expect(run("«a\n\nb»", Self.quote) == "> «a\n>\n> b»")
        #expect(run("«> a\n>\n> b»", Self.quote) == "«a\n\nb»")
        #expect(run("|", Self.quote) == "> |")
        #expect(run("«a\nb»", Self.codeBlock) == "```\n«a\nb»\n```")
        #expect(run("```\n«a\nb»\n```", Self.codeBlock) == "«a\nb»")
        #expect(run("|", Self.codeBlock) == "```\n|\n```")
        #expect(run("x ``` y|", Self.codeBlock) == "````\nx ``` y|\n````")
        #expect(run("- item\n  co|de", Self.codeBlock) == "- item\n  ```\n  co|de\n  ```")
    }

    // MARK: Return and Tab

    @Test func returnContinuesAListOrAQuote() {
        #expect(run("- a|", Self.newline) == "- a\n- |")
        #expect(run("3. a|", Self.newline) == "3. a\n4. |")
        // The items after keep their numbers.
        #expect(run("10. x|\n11. y", Self.newline) == "10. x\n11. |\n11. y")
        #expect(run("- [x] a|", Self.newline) == "- [x] a\n- [ ] |")
        #expect(run("> a|", Self.newline) == "> a\n> |")
        #expect(run("> - a|", Self.newline) == "> - a\n> - |")
        #expect(run("  * a|", Self.newline) == "  * a\n  * |")
        #expect(run("- ab|cd", Self.newline) == "- ab\n- |cd")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(run("- |", Self.newline) == "|")
        #expect(run("1. |", Self.newline) == "|")
        #expect(run("- [ ] |", Self.newline) == "|")
        #expect(run("> |", Self.newline) == "|")
        #expect(run("> - |", Self.newline) == "> |")
        // In a fence, a paragraph, or before an item's text: the editor's own Return.
        #expect(run("```\n- a|\n```", Self.newline) == nil)
        #expect(run("a|", Self.newline) == nil)
        #expect(run("|- a", Self.newline) == nil)
    }

    @Test func tabNestsAnItemUnderTheOneAbove() {
        #expect(run("- one\n- tw|o", Self.nest) == "- one\n  - tw|o")
        #expect(run("1. one\n2. tw|o", Self.nest) == "1. one\n   2. tw|o")
        #expect(run("- [ ] one\n- [ ] tw|o", Self.nest) == "- [ ] one\n  - [ ] tw|o")
        #expect(run("- one\n  - a\n- tw|o", Self.nest) == "- one\n  - a\n  - tw|o")
        #expect(run("- one\n  - tw|o", Self.unnest) == "- one\n- tw|o")
        #expect(run("1. one\n   - tw|o", Self.unnest) == "1. one\n- tw|o")
        #expect(run("- o|ne", Self.unnest) == nil)
        #expect(run("text|", Self.nest) == nil)
        #expect(run("«- one\n- two»", Self.nest) == nil)
    }

    // MARK: every line of every fixture

    /// The text of a line, without its line break.
    static func line(_ number: Int, of text: String) -> NSRange {
        MarkdownEdits.content(of: number, in: LineIndex(text))
    }

    /// The command run twice from `selection`, the second time where the first left the selection.
    static func twice(_ text: String, _ selection: NSRange, _ make: Make) -> (once: String, twice: String)? {
        guard let first = edit(text, selection, make) else { return nil }
        let once = apply(first, to: text)
        guard let second = edit(once, first.selection, make) else { return (once, once) }
        return (once, apply(second, to: once))
    }

    @Test(arguments: MarkdownSyntaxTests.fixtureNames) func togglingTwiceGivesBackTheSameBytes(_ name: String) throws {
        let text = try MarkdownSyntaxTests.fixture(name)
        let index = LineIndex(text)
        let lines = MarkdownSyntax.lines(of: text)
        let source = text as NSString
        for number in 0..<index.count {
            let read = lines[number]
            let line = Self.line(number, of: text)
            let at = "\(name):\(number + 1)"
            guard !read.isSource, line.length > 0 else { continue }
            // A caret in the line's first word (bold, italic, strike, code), and the whole line selected (lists).
            if let word = MarkdownEdits.word(at: line.location + max(0, read.content.location) + 1, in: source, line: line),
               word.length > 1 {
                let caret = NSRange(location: word.location + 1, length: 0)
                for make in [Self.bold, Self.italic, Self.strike, Self.code] {
                    guard let first = Self.edit(text, caret, make) else { continue }
                    let added = (first.text as NSString).length > first.range.length
                    if added, let result = Self.twice(text, caret, make) { #expect(result.twice == text, "\(at)") }
                }
            }
            let whole = NSRange(location: line.location, length: line.length)
            // Heading 2 on body text, or on a heading written `## `, both ways.
            let written = source.substring(with: line)
            if read.headingLevel == 0 || (read.headingLevel == 2 && written.hasPrefix("## ") && !written.hasPrefix("##  ")),
               let result = Self.twice(text, whole, Self.heading(2)) {
                #expect(result.twice == text, "\(at) heading")
            }
            // Ticked twice, a task is as it was (a tick writes a small x).
            if let box = read.taskBox, source.substring(with: NSRange(location: line.location + box.location, length: 3)) != "[X]",
               let result = Self.twice(text, whole, Self.task) { #expect(result.twice == text, "\(at) task") }
            // Lists and quotes, on lines the command adds to, or written as it writes them.
            let unlisted = read.kind != .rule && read.kind != .setextUnderline
            let bulletForm = read.item.map { !$0.isOrdered && written.hasPrefix("- ") && $0.box == nil } ?? unlisted
            if bulletForm, read.quoteDepth == 0, let result = Self.twice(text, whole, Self.bullets) { #expect(result.twice == text, "\(at) bullets") }
            let quoteForm = read.quoteDepth == 0 || written.hasPrefix("> ")
            if quoteForm, let result = Self.twice(text, whole, Self.quote) { #expect(result.twice == text, "\(at) quote") }
            if read.item == nil, read.quoteDepth == 0, unlisted, let result = Self.twice(text, whole, Self.numbers) {
                #expect(result.twice == text, "\(at) numbers")
            }
        }
    }

    /// Each command changes only the line it is on: its edit lies inside that line, and every byte outside it is the same.
    @Test(arguments: MarkdownSyntaxTests.fixtureNames) func anEditStaysInItsLine(_ name: String) throws {
        let text = try MarkdownSyntaxTests.fixture(name)
        let index = LineIndex(text)
        let commands: [Make] = [Self.bold, Self.italic, Self.strike, Self.code, Self.link, Self.heading(1), Self.heading(0), Self.bullets,
                                Self.numbers, Self.task, Self.quote, Self.newline, Self.nest, Self.unnest]
        for number in 0..<index.count {
            let line = Self.line(number, of: text)
            for caret in [line.location, line.location + line.length / 2, NSMaxRange(line)] {
                for make in commands {
                    guard let edit = Self.edit(text, NSRange(location: caret, length: 0), make) else { continue }
                    #expect(edit.range.location >= line.location && NSMaxRange(edit.range) <= NSMaxRange(line), "\(name):\(number + 1)")
                    let after = Self.apply(edit, to: text) as NSString
                    #expect(after.substring(to: edit.range.location) == (text as NSString).substring(to: edit.range.location))
                    let tail = (text as NSString).length - NSMaxRange(edit.range)
                    #expect(after.substring(from: after.length - tail) == (text as NSString).substring(from: NSMaxRange(edit.range)))
                }
            }
        }
    }

    /// The editor holds a CRLF file with plain newlines; formatting it and back, it saves to the same bytes.
    @Test func aCRLFFileRoundTripsThroughSaving() throws {
        let data = try Data(contentsOf: MarkdownSyntaxTests.fixtures.appendingPathComponent("crlf.md"))
        let (held, format) = try #require(TextFile.decode(data))
        #expect(format.lineEnding == .crlf)
        var text = held
        for number in 0..<LineIndex(text).count {
            let line = Self.line(number, of: text)
            guard line.length > 0 else { continue }
            for make in [Self.bold, Self.italic, Self.quote] {
                let caret = NSRange(location: line.location + 1, length: 0)
                if let result = Self.twice(text, caret, make) { text = result.twice }
            }
        }
        #expect(text == held)
        #expect(TextFile.encode(text, as: format) == data)
    }
}
