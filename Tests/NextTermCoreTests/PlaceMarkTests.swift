import Foundation
import Testing
@testable import NextTermCore

/// The mark and its words: Elsewhere against the window's checkout, a switch under a chat, list_tabs' sync.
@Suite struct PlaceMarkTests {
    let main = Checkout(path: "/Code/xCloud", head: .branch("fix/7611-3ds"), commit: "a1", isMain: true)
    let nested = Checkout(path: "/Code/xCloud/.claude/worktrees/pr-7050", head: .branch("fix/7027-sso"), commit: "b2")
    static let repo = "/Code/xCloud/.git"
    func when(_ date: Date) -> String { "2 min ago" }

    @Test func anAgentInANestedWorktreeIsElsewhere() {
        let place = AgentPlace(repository: Self.repo, checkout: nested, workingBranch: .branch("fix/7027-sso"), switched: nil)
        let mark = PlaceMark.of(place, shownRepository: Self.repo, shown: main)
        #expect(mark?.elsewhere == true && mark?.label == "this tab: fix/7027-sso")
        #expect(mark?.facts(agent: "Claude Code", when: when)
                == "Claude Code works in worktree pr-7050, on fix/7027-sso. This window shows xCloud, on fix/7611-3ds.")
        #expect(PlaceMark.sync(place, shownRepository: Self.repo, shown: main) == "elsewhere")
        // The window shows that worktree, or another repository: nothing to mark.
        #expect(PlaceMark.of(place, shownRepository: Self.repo, shown: nested) == nil)
        #expect(PlaceMark.sync(place, shownRepository: Self.repo, shown: nested) == "same")
        #expect(PlaceMark.of(place, shownRepository: "/Code/other/.git", shown: main) == nil)
        #expect(PlaceMark.sync(place, shownRepository: nil, shown: nil) == "other_repository")
        let detached = Checkout(path: nested.path, head: .detached("abc1234def"), commit: "abc1234def")
        let there = PlaceMark.of(AgentPlace(repository: Self.repo, checkout: detached, workingBranch: nil, switched: nil), shownRepository: Self.repo, shown: main)
        #expect(there?.label == "this tab: detached at abc1234")
        #expect(there?.facts(agent: "Codex", when: when).hasPrefix("Codex works in worktree pr-7050, detached at abc1234.") == true)
    }

    @Test func aSwitchUnderAChatSaysWhoAndWhen() {
        let now = main.on(.branch("fix/7050-pr"))
        func mark(_ by: SwitchAuthor) -> PlaceMark? {
            let switched = BranchSwitch(from: .branch("fix/7611-3ds"), to: .branch("fix/7050-pr"), at: Date(), by: by)
            let place = AgentPlace(repository: Self.repo, checkout: now, workingBranch: .branch("fix/7611-3ds"), switched: switched)
            return PlaceMark.of(place, shownRepository: Self.repo, shown: now)
        }
        #expect(mark(.you)?.elsewhere == false && mark(.you)?.label == "chat was on fix/7611-3ds")
        #expect(mark(.you)?.facts(agent: "Claude Code", when: when) == "The chat was on fix/7611-3ds; xCloud is now on fix/7050-pr: you switched it 2 min ago.")
        #expect(mark(.agent(key: "k", title: "7"))?.facts(agent: "Codex", when: when).hasSuffix("the agent in the tab “7” switched it 2 min ago.") == true)
        #expect(mark(.tab(key: "k", title: "zsh"))?.facts(agent: "Codex", when: when).hasSuffix("the tab “zsh” switched it 2 min ago.") == true)
        #expect(mark(.unknown(working: 2))?.facts(agent: "Codex", when: when).hasSuffix("switched 2 min ago, while 2 agents were working there.") == true)
        #expect(mark(.unknown(working: 0))?.facts(agent: "Codex", when: when).hasSuffix("Next Term can’t tell by whom.") == true)
        let place = AgentPlace(repository: Self.repo, checkout: now, workingBranch: .branch("fix/7611-3ds"),
                               switched: BranchSwitch(from: .branch("fix/7611-3ds"), to: .branch("fix/7050-pr"), at: Date(), by: .you))
        #expect(PlaceMark.sync(place, shownRepository: Self.repo, shown: now) == "switched_under")
    }
}
