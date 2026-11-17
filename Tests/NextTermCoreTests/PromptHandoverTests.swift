import Foundation
import Testing
@testable import NextTermCore

/// Plan 042: which session prompts typed into the wrong tab were meant for, and what that session is given.
@Suite struct PromptHandoverTests {
    typealias H = PromptHandover

    let codingSessions = H.Candidate(id: "tab-cs", open: true, agent: "Claude Code", folder: "/Users/u/Code/coding-sessions",
                                     title: "coding-sessions", branch: "main", recentPrompts: ["cs list --all should group servers"])
    let xcloud = H.Candidate(id: "tab-x", open: true, agent: "Claude Code", folder: "/Users/u/Code/xCloud",
                             title: "Xcloud AI assistant issues", branch: "fix/avijit-revenue-report-access")
    let nextTerm = H.Candidate(id: "tab-nt", open: true, agent: "Claude Code", folder: "/Users/u/Code/next-term", title: "release 0.11.58")
    let nextTermSite = H.Candidate(id: "tab-site", open: true, agent: "Codex", folder: "/Users/u/Code/next-term-site", title: "site")

    @Test func aShortNameFindsItsProjectAsAClearMatch() {
        // The owner's second case: "hey wait find the cs tab", three prompts about cs --live --all.
        let prompts = ["great now cs --live --all should show all just the name and 1/2 sentence to each /typography with /grill-with-docs",
                       "or judge with research", "dont forget to add support for mutlipel server not srure how to"]
        let ranking = H.rank([xcloud, codingSessions, nextTerm], hint: "hey wait find the cs tab in next term", prompts: prompts)
        #expect(ranking.best?.id == "tab-cs")
        #expect(ranking.clear)
    }

    @Test func theShortNamesAreInitialsAndTheWordsRunTogether() {
        #expect(H.shortNames("coding-sessions") == ["codingsessions", "cs"])
        #expect(H.shortNames("NextTerm") == ["nextterm", "nt"])
        #expect(H.shortNames("xCloud") == ["xcloud", "xc"])
        #expect(H.shortNames("api") == ["api"])
    }

    @Test func twoTabsThatFitAlikeAreTheUsersToChoose() {
        let ranking = H.rank([nextTerm, nextTermSite], hint: "the next term tab", prompts: ["update the release notes for next term"])
        #expect(!ranking.clear)
    }

    @Test func promptsAloneCanPointTheWay() {
        let ranking = H.rank([xcloud, codingSessions], hint: "", prompts: ["make cs list --all group sessions by server"])
        #expect(ranking.best?.id == "tab-cs")
    }

    @Test func nothingToGoOnIsNoMatch() {
        #expect(H.rank([], hint: "the cs tab", prompts: ["x"]).ranked.isEmpty)
        let ranking = H.rank([xcloud, codingSessions], hint: "find the other tab", prompts: ["or what maybe best"])
        #expect(!ranking.clear)
    }

    @Test func anOpenTabWinsATieOverAClosedSession() {
        var closed = codingSessions
        closed.id = "claude:abc"
        closed.open = false
        let ranking = H.rank([closed, codingSessions], hint: "cs", prompts: [])
        #expect(ranking.best?.id == "tab-cs")
    }

    @Test func theMessageCarriesTheNoteThenThePromptsInOrder() {
        let text = H.message(prompts: ["great now cs --live --all /typography", "  or judge with research  ", ""],
                             from: "Slack review requests", note: "I read coding-sessions' source and changed nothing.",
                             images: ["/tmp/shot one.png"])
        let parts = text.components(separatedBy: "\n\n")
        #expect(parts.count == 4)
        #expect(parts[0] == "(Moved here from the \u{201C}Slack review requests\u{201D} tab, where the user typed this by mistake. "
            + "There: I read coding-sessions' source and changed nothing.)")
        #expect(parts[1] == "great now cs --live --all /typography")
        #expect(parts[2] == "or judge with research")
        #expect(parts[3] == "'/tmp/shot one.png'")
    }

    @Test func aMessageWithNoNoteSaysOnlyWhereItCameFrom() {
        #expect(H.message(prompts: ["hi"], from: "", note: nil)
            == "(Moved here from the \u{201C}other\u{201D} tab, where the user typed this by mistake.)\n\nhi")
    }
}
