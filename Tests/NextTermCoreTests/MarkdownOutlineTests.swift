import Foundation
import Testing
@testable import NextTermCore

/// Go to Heading's list, a link's anchors, and the counts in its footer.
@Suite struct MarkdownOutlineTests {
    @Test func headingsAndTheirAnchors() {
        let text = "# Next Term\n\n## Set up: the API\n\nText\n\n## Setup\n\n### **Bold** `code` title ##\n\n## Setup\n\n## Setup\n"
        let headings = MarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["Next Term", "Set up: the API", "Setup", "Bold code title", "Setup", "Setup"])
        #expect(headings.map(\.anchor) == ["next-term", "set-up-the-api", "setup", "bold-code-title", "setup-1", "setup-2"])
        #expect(headings.map(\.level) == [1, 2, 2, 3, 2, 2])
        #expect(headings.map(\.line) == [0, 2, 6, 8, 10, 12])
        #expect(MarkdownOutline.heading(named: "Set-Up-The-API", in: text)?.line == 2)
        #expect(MarkdownOutline.heading(named: "setup-1", in: text)?.line == 10)
        #expect(MarkdownOutline.heading(named: "missing", in: text) == nil)
    }

    @Test func slugsKeepLettersOfAnyScriptAndDropPunctuation() {
        #expect(MarkdownOutline.slug("Set up: the API") == "set-up-the-api")
        #expect(MarkdownOutline.slug("What's new in 0.12?") == "whats-new-in-012")
        #expect(MarkdownOutline.slug("snake_case and kebab-case") == "snake_case-and-kebab-case")
        #expect(MarkdownOutline.slug("ターミナル の タブ") == "ターミナル-の-タブ")
        #expect(MarkdownOutline.slug("Ünïcödé Straße") == "ünïcödé-straße")
    }

    @Test func noHeadingInAFenceButSetextOnesCount() {
        let text = "```\n# not a heading\n```\n\nTabs and panes\n==============\n\nAgents\n------\n\n<!--\n# nor this\n-->\n"
        let headings = MarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["Tabs and panes", "Agents"] && headings.map(\.level) == [1, 2])
        #expect(headings.map(\.line) == [4, 7])
    }

    @Test func wordsCharactersAndReadingTimeLeaveOutFrontMatterAndCode() {
        let text = "---\ntitle: \"not counted here\"\n---\n# Two words\n\nThree **more** words.\n\n```\nnot counted either\n```\n"
        let stats = MarkdownOutline.stats(of: text)
        #expect(stats.words == 5)
        // "Two words" and "Three more words.", without the hashes and stars.
        #expect(stats.characters == 9 + 17)
        #expect(stats.minutes == 1)
        #expect(MarkdownOutline.stats(of: "").minutes == 0 && MarkdownOutline.stats(of: "").words == 0)
        let long = String(repeating: "word ", count: 461)
        #expect(MarkdownOutline.stats(of: long).minutes == 3)
    }

    @Test func aSelectionsCounts() {
        let text = "one two three\nfour five\n"
        #expect(MarkdownOutline.stats(of: text, in: NSRange(location: 4, length: 9)).words == 2)
        #expect(MarkdownOutline.stats(of: text, in: NSRange(location: 8, length: 10)).words == 2)
        #expect(MarkdownOutline.stats(of: text, in: NSRange(location: 4, length: 3)).characters == 3)
    }

    @Test func aCJKParagraphCountsItsWords() {
        let stats = MarkdownOutline.stats(of: "中文段落里有粗体和斜体。\n")
        #expect(stats.words > 3)
        #expect(stats.characters == 12)
    }
}
