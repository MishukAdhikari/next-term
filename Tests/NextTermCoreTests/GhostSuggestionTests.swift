import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostSuggestionTests {
    @Test func theRestOfTheCommandShows() throws {
        let suggestion = try #require(GhostSuggestion(typed: "git ch", command: "git checkout main"))
        #expect(suggestion.remainder == "eckout main" && suggestion.acceptAll == "git checkout main")
        #expect(GhostSuggestion(typed: "git ch", command: "git ch") == nil)
        #expect(GhostSuggestion(typed: "git x", command: "git checkout main") == nil)
        #expect(GhostSuggestion(typed: "", command: "ls") == nil)
    }

    /// Case-blind unless a capital was typed; accepting takes the command's own case.
    @Test func smartCase() throws {
        let suggestion = try #require(GhostSuggestion(typed: "cd ~/code", command: "cd ~/Code/next-term"))
        #expect(suggestion.remainder == "/next-term" && suggestion.acceptAll == "cd ~/Code/next-term")
        #expect(GhostSuggestion(typed: "cd ~/Code", command: "cd ~/code/x") == nil)
        #expect(GhostSuggestion(typed: "échO", command: "écho x") == nil)
    }

    @Test func aWordAtATime() throws {
        #expect(GhostSuggestion.nextWord("eckout main") == "eckout")
        #expect(GhostSuggestion.nextWord(" main") == " main")
        #expect(GhostSuggestion.nextWord("ode/next-term/x") == "ode/")
        #expect(GhostSuggestion.nextWord("/next-term/x") == "/next-term/")
        #expect(GhostSuggestion.nextWord("  ") == "  ")
        // ⌥→ twice on `git ch`: `git checkout`, then `git checkout main`.
        let first = try #require(GhostSuggestion(typed: "git ch", command: "git checkout main"))
        #expect(first.acceptWord == "git checkout")
        let second = try #require(GhostSuggestion(typed: first.acceptWord, command: first.command))
        #expect(second.acceptWord == "git checkout main")
        // In the command's case.
        #expect(GhostSuggestion(typed: "cd ~/code", command: "cd ~/Code/next-term/x")?.acceptWord == "cd ~/Code/next-term/")
    }

    @Test func typingThroughTrims() throws {
        let suggestion = try #require(GhostSuggestion(typed: "git ch", command: "git cherry-pick abc"))
        #expect(suggestion.typedThrough("git che")?.remainder == "rry-pick abc")
        #expect(suggestion.typedThrough("git chc") == nil)
        #expect(suggestion.typedThrough("git c") == nil)
        // The whole command typed: nothing left to show.
        #expect(suggestion.typedThrough("git cherry-pick abc") == nil)
        // A capital typed after a case-blind match is asked for again.
        let blind = try #require(GhostSuggestion(typed: "make", command: "make Test"))
        #expect(blind.typedThrough("make T") == nil && blind.typedThrough("make ")?.remainder == "Test")
    }

    @Test func itFitsTheRow() {
        #expect(GhostClip.fit("eckout main", available: 20) == "eckout main")
        #expect(GhostClip.fit("eckout main", available: 11) == "eckout main")
        #expect(GhostClip.fit("eckout main", available: 5) == "ecko…")
        #expect(GhostClip.fit("eckout main", available: 1) == nil)
        // A wide character at the cut is not split.
        #expect(GhostClip.fit("ab日本語", available: 4) == "ab…")
        #expect(GhostClip.fit("ab日本語", available: 5) == "ab日…" && GhostClip.fit("ab日本語", available: 6) == "ab日…")
        #expect(GhostClip.fit("日本", available: 2) == nil)
    }
}
