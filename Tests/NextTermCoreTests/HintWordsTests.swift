import Foundation
import Testing
@testable import NextTermCore

/// What the three hints say, and when a mark in the window column is new (H2's trigger).
struct HintWordsTests {
    private func tab(_ n: Int, _ state: TabState) -> WindowIndex.Tab {
        WindowIndex.Tab(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, title: "zsh", state: state)
    }

    private func project(_ id: Int, _ name: String, _ tabs: [WindowIndex.Tab] = []) -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .project, project: "/Users/sam/Code/" + name, name: name, title: name, lastKey: .distantPast, tabs: tabs)
    }

    private func list(_ windows: [WindowIndex.Window]) -> WindowColumnList {
        WindowColumnList.build(windows: windows, colors: [:], showsWorking: true, home: "/Users/sam")
    }

    @Test func theColumnSideHintNamesTheOtherEdge() {
        let left = HintWords.columnSide(onRight: false)
        #expect(left.lead == "⇄" && left.words == "Move column right")
        #expect(left.help == "Or ask your agent: ‘put the window column on the right’.")
        let right = HintWords.columnSide(onRight: true)
        #expect(right.words == "Move column left" && right.help == "Or ask your agent: ‘put the window column on the left’.")
    }

    @Test func theNextAgentHintReadsTheLiveKeyAndHasNoneWithout() {
        #expect(HintWords.nextAgent(key: "⇧⌘U") == "Press ⇧⌘U to jump to it")
        #expect(HintWords.nextAgent(key: "⌃⌥J") == "Press ⌃⌥J to jump to it")
        #expect(HintWords.nextAgent(key: nil) == nil)
        #expect(HintWords.nextAgent(key: "") == nil)
    }

    @Test func theWordsAreCalm() {
        let all: [String] = [HintWords.columnSide(onRight: false).words, HintWords.columnSide(onRight: false).help,
                             HintWords.nextAgent(key: "⇧⌘U") ?? "", HintWords.columnBasics, HintWords.close]
        for words in all {
            #expect(!words.contains("!") && !words.contains("Did you know") && !words.contains("\"") && !words.contains("..."))
            #expect(words.count <= 60)
        }
    }

    @Test func aMarkIsNewOnlyWhereThereWasNone() {
        let calm: WindowColumnList = list([project(1, "next-term"), project(2, "shop", [tab(1, .working)])])
        let asks: WindowColumnList = list([project(1, "next-term"), project(2, "shop", [tab(1, .attention)])])
        #expect(asks.newlyUrgent(since: calm).map(\.id) == [2])
        // Still asking: nothing new.
        #expect(asks.newlyUrgent(since: asks).isEmpty)
        // Needing you, then failed: a mark was there already.
        let failed: WindowColumnList = list([project(1, "next-term"), project(2, "shop", [tab(1, .failed)])])
        #expect(failed.newlyUrgent(since: asks).isEmpty)
        #expect(failed.newlyUrgent(since: calm).map(\.id) == [2])
        // Done is no mark that calls the user.
        let done: WindowColumnList = list([project(1, "next-term"), project(2, "shop", [tab(1, .done)])])
        #expect(done.newlyUrgent(since: calm).isEmpty)
        // A window that opens already asking is new too.
        let opened: WindowColumnList = list([project(1, "next-term"), project(2, "shop", [tab(1, .working)]), project(3, "api", [tab(2, .attention)])])
        #expect(opened.newlyUrgent(since: calm).map(\.id) == [3])
    }
}
