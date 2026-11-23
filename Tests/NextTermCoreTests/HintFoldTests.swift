import Foundation
import Testing
@testable import NextTermCore

/// H8: which repository's row the fold hint offers, and when the pinned column's rows fire it.
struct HintFoldTests {
    private static let xcloud = "/Users/sam/Code/xCloud"

    private func project(_ id: Int, _ name: String) -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .project, project: "/Users/sam/Code/" + name, name: name, title: name, lastKey: .distantPast, tabs: [])
    }

    private func worktree(_ id: Int, _ own: String) -> WindowIndex.Window {
        let name: String = WorktreeWindow.title(repository: "xCloud", folder: own)
        return WindowIndex.Window(id: id, kind: .worktree, project: "/Users/sam/Code/xCloud-wt-" + own, name: name, title: name,
                                  lastKey: .distantPast, tabs: [], repository: Self.xcloud)
    }

    private func list(_ windows: [WindowIndex.Window], folded: Set<String> = []) -> WindowColumnList {
        WindowColumnList.build(windows: windows, colors: [:], showsWorking: true, home: "/Users/sam", folded: folded)
    }

    @Test func aRepositoryWithTwoWorktreeRowsUnderItIsFoldable() {
        let one: WindowColumnList = list([project(1, "xCloud"), worktree(2, "aichat"), project(4, "shop")])
        #expect(one.foldable().isEmpty && one.foldable(atLeast: 1).map(\.row.id) == [1])
        let two: WindowColumnList = list([project(1, "xCloud"), worktree(2, "aichat"), worktree(3, "cx-8858"), project(4, "shop")])
        #expect(two.foldable().map(\.row.id) == [1] && two.foldable().first?.worktrees == 2)
        // Folded already: nothing to offer.
        let key: String = two.row(1)?.foldKey ?? ""
        #expect(list([project(1, "xCloud"), worktree(2, "aichat"), worktree(3, "cx-8858")], folded: [key]).foldable().isEmpty)
        // Worktrees with no repository window open have no row to fold into.
        #expect(list([worktree(2, "aichat"), worktree(3, "cx-8858")]).foldable().isEmpty)
    }

    @Test func thePinnedColumnFiresItWhenAFoldableRowGainsAWorktree() {
        let one: WindowColumnList = list([project(1, "xCloud"), worktree(2, "aichat")])
        let two: WindowColumnList = list([project(1, "xCloud"), worktree(2, "aichat"), worktree(3, "cx-8858")])
        let three: WindowColumnList = list([project(1, "xCloud"), worktree(2, "aichat"), worktree(3, "cx-8858"), worktree(5, "docs")])
        #expect(two.newlyFoldable(since: one)?.id == 1)
        #expect(three.newlyFoldable(since: two)?.id == 1)
        // The same rows, or one fewer: nothing new.
        #expect(two.newlyFoldable(since: two) == nil && two.newlyFoldable(since: three) == nil)
        #expect(one.newlyFoldable(since: list([project(1, "xCloud")])) == nil)
    }

    @Test func itsWordsNameTheRepositoryAndHowTheyComeBack() {
        let words = HintWords.foldWorktrees(repository: "xCloud")
        #expect(words.words == "Fold worktrees")
        #expect(words.help == "Folds xCloud’s worktrees into its row. Its arrow shows them again.")
    }
}
