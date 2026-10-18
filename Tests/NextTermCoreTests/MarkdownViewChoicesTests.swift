import Foundation
import Testing
@testable import NextTermCore

/// View › Markdown Live Preview's memory of each file's choice.
@Suite struct MarkdownViewChoicesTests {
    @Test func aFilesChoiceIsKeptAndTheRestFollowSettings() {
        var choices = MarkdownViewChoices()
        #expect(choices.choice(for: "/p/README.md") == nil)
        choices.set(false, for: "/p/README.md")
        choices.set(true, for: "/p/notes.md")
        #expect(choices.choice(for: "/p/README.md") == false && choices.choice(for: "/p/notes.md") == true)
        // Chosen again, it is the newest, once.
        choices.set(true, for: "/p/README.md")
        #expect(choices.entries.map(\.path) == ["/p/README.md", "/p/notes.md"] && choices.choice(for: "/p/README.md") == true)
        // A renamed file is a new path: it follows Settings.
        #expect(choices.choice(for: "/p/READ-ME.md") == nil)
    }

    @Test func theNewest500AreKept() {
        var choices = MarkdownViewChoices()
        for n in 0..<520 { choices.set(n % 2 == 0, for: "/p/\(n).md") }
        #expect(choices.entries.count == 500)
        #expect(choices.entries.first?.path == "/p/519.md" && choices.choice(for: "/p/20.md") == true)
        #expect(choices.choice(for: "/p/19.md") == nil)
    }

    @Test func savedAndReadBackAndACorruptValueIsEmpty() {
        var choices = MarkdownViewChoices()
        choices.set(false, for: "/p/a.md")
        choices.set(true, for: "/p/b.md")
        #expect(MarkdownViewChoices.decode(choices.encoded()) == choices)
        #expect(MarkdownViewChoices.decode(Data("not json".utf8)) == MarkdownViewChoices())
        #expect(MarkdownViewChoices.decode(Data("{\"path\": 1}".utf8)).entries.isEmpty)
        #expect(MarkdownViewChoices.decode(nil).entries.isEmpty)
    }
}
