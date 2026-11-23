import Foundation
import Testing
@testable import NextTermCore

/// The record of where each agent tab's agent works: writes count at once, folder moves after their hold and only
/// when the folder changes, a worktree it made once git lists it, and what came before this version is the baseline.
@Suite struct WorktreeLifecycleTests {
    static let repo = "/Code/xCloud/.git"
    let main = "/Code/xCloud"
    let sibling = "/Code/xcloud-wt-11650"
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func checkouts(_ extra: [String] = []) -> [Checkout] {
        [Checkout(path: main, head: .branch("main"), commit: "a1", isMain: true),
         Checkout(path: sibling, head: .branch("fix/11650"), commit: "b2")]
            + extra.map { Checkout(path: $0, head: .branch("new/" + ($0 as NSString).lastPathComponent), commit: "c3") }
    }

    func sighting(_ folder: String?, writes: [DatedWrite] = [], extra: [String] = [], startedAt: Date = .distantPast) -> PlaceSighting {
        var seen = PlaceSighting()
        seen.repositories[Self.repo] = checkouts(extra)
        seen.agents = [PlaceSighting.Agent(key: "7", title: "tab 7", repository: Self.repo, folder: folder, working: false,
                                           startedAt: startedAt, writes: writes)]
        return seen
    }

    func write(_ path: String, _ kind: WriteSignal.Kind = .file, at seconds: Double) -> DatedWrite {
        DatedWrite(signal: WriteSignal(path: path, kind: kind), at: at(seconds))
    }

    /// One look a second from `from` to `to` (inclusive), each seeing `seen`.
    func run(_ lifecycle: inout WorktreeLifecycle, _ seen: PlaceSighting, from: Double, to: Double) {
        var second = from
        while second <= to {
            lifecycle.update(seen, at: at(second)) { _, _, _ in .switched }
            second += 1
        }
    }

    func place(_ lifecycle: WorktreeLifecycle) -> String? { lifecycle.places["7"]?.checkout.path }

    /// Every line of Claude Code's transcript names the project folder, while the agent writes in a sibling
    /// worktree. The write places it there at once, and the project folder repeated on later lines doesn't pull it back.
    @Test func aWriteInASiblingWorktreeCountsAtOnceAndHolds() {
        var lifecycle = WorktreeLifecycle(since: at(-3600))
        run(&lifecycle, sighting(main), from: 0, to: 0)
        #expect(place(lifecycle) == main)
        run(&lifecycle, sighting(main, writes: [write(sibling + "/tests/Feature/A.php", at: 1)]), from: 1, to: 1)
        #expect(place(lifecycle) == sibling)
        #expect(lifecycle.places["7"]?.checkout.head == .branch("fix/11650"))
        #expect(lifecycle.placements["7"] == .init(checkout: sibling, how: .wrote, at: at(1), baseline: false))
        run(&lifecycle, sighting(main), from: 2, to: 20)
        #expect(place(lifecycle) == sibling)
        #expect(lifecycle.history["7"] == [sibling])
    }

    @Test func aFolderMoveHoldsAndAnUnchangedFolderDoesNotUndoAWrite() {
        var lifecycle = WorktreeLifecycle(since: at(-3600))
        run(&lifecycle, sighting(main), from: 0, to: 2)
        run(&lifecycle, sighting(sibling + "/app"), from: 3, to: 5)
        #expect(place(lifecycle) == main) // held 2 s so far
        run(&lifecycle, sighting(sibling + "/app"), from: 6, to: 6)
        #expect(place(lifecycle) == sibling && lifecycle.placements["7"]?.how == .moved)
        #expect(lifecycle.history["7"] == [sibling])
        // A write back in the main checkout counts at once; the folder, still in the sibling, doesn't pull it back.
        run(&lifecycle, sighting(sibling + "/app", writes: [write(main + "/a.txt", at: 7)]), from: 7, to: 7)
        #expect(place(lifecycle) == main)
        run(&lifecycle, sighting(sibling + "/app"), from: 8, to: 20)
        #expect(place(lifecycle) == main)
        // The same write read again (a record read anew) is no new signal: a later move stays.
        run(&lifecycle, sighting(sibling), from: 21, to: 21)
        run(&lifecycle, sighting(main), from: 22, to: 25)
        #expect(place(lifecycle) == main)
        run(&lifecycle, sighting(sibling + "/app", writes: [write(sibling + "/b.txt", at: 26)]), from: 26, to: 26)
        run(&lifecycle, sighting(sibling + "/app", writes: [write(main + "/a.txt", at: 7)]), from: 27, to: 27)
        #expect(place(lifecycle) == sibling)
    }

    @Test func aWorktreeItMadeCountsOnceGitListsIt() {
        var lifecycle = WorktreeLifecycle(since: at(-3600))
        let made = "/Code/xcloud-wt-11700", never = "/Code/xcloud-wt-never"
        run(&lifecycle, sighting(main), from: 0, to: 0)
        run(&lifecycle, sighting(main, writes: [write(made, .created, at: 1)]), from: 1, to: 1)
        run(&lifecycle, sighting(main), from: 2, to: 3)
        #expect(place(lifecycle) == main)
        run(&lifecycle, sighting(main, extra: [made]), from: 4, to: 4)
        #expect(place(lifecycle) == made && lifecycle.placements["7"]?.how == .created)
        // One git never lists within the wait is dropped.
        run(&lifecycle, sighting(main, writes: [write(never, .created, at: 5)], extra: [made]), from: 5, to: 5)
        run(&lifecycle, sighting(main, extra: [made]), from: 6, to: 16)
        run(&lifecycle, sighting(main, extra: [made, never]), from: 17, to: 17)
        #expect(place(lifecycle) == made)
        #expect(lifecycle.history["7"] == [made])
    }

    @Test func aWriteOutsideTheRepositoryItStartedInIsIgnored() {
        var lifecycle = WorktreeLifecycle(since: at(-3600))
        run(&lifecycle, sighting(main), from: 0, to: 0)
        run(&lifecycle, sighting(main, writes: [write("/Code/other/x.txt", at: 1), write("/tmp/notes.md", at: 1)]), from: 1, to: 5)
        #expect(place(lifecycle) == main && lifecycle.placements["7"]?.how == .moved)
        #expect(lifecycle.history["7"] == nil)
    }

    /// A transcript read for the first time 10 s after its session made a worktree and wrote there: its lines are
    /// dated after this version first ran, so they are not the baseline.
    @Test func aFirstReadOfLinesAfterTheFirstRunIsNotTheBaseline() {
        var lifecycle = WorktreeLifecycle(since: at(0))
        let made = "/Code/xcloud-wt-11700"
        let writes = [write(made, .created, at: 1), write(made + "/a.txt", at: 2)]
        run(&lifecycle, sighting(main, writes: writes, extra: [made], startedAt: at(0.5)), from: 10, to: 10)
        #expect(place(lifecycle) == made)
        #expect(lifecycle.placements["7"]?.baseline == false)
        #expect(lifecycle.history["7"] == [made])
    }

    /// Lines dated before this version first ran set the record but are the baseline: no history.
    @Test func linesFromBeforeTheFirstRunAreTheBaseline() {
        var lifecycle = WorktreeLifecycle(since: at(100))
        run(&lifecycle, sighting(main, writes: [write(sibling + "/a.txt", at: 1)], startedAt: at(0)), from: 200, to: 200)
        #expect(place(lifecycle) == sibling && lifecycle.placements["7"]?.baseline == true)
        #expect(lifecycle.history["7"] == nil)
        // A worktree it makes later is not.
        let made = "/Code/xcloud-wt-11700"
        run(&lifecycle, sighting(main, writes: [write(made + "/b.txt", at: 201)], extra: [made], startedAt: at(0)), from: 201, to: 201)
        #expect(place(lifecycle) == made && lifecycle.placements["7"]?.baseline == false)
        #expect(lifecycle.history["7"] == [made])
        // An agent already in a worktree when it is first seen, started before the first run: baseline too.
        var later = WorktreeLifecycle(since: at(100))
        run(&later, sighting(sibling, startedAt: at(0)), from: 200, to: 200)
        #expect(later.placements["7"]?.baseline == true && later.history["7"] == nil)
    }

    @Test func theLastAgentEndingKeepsTheHistoryAndReportsItsTab() {
        var lifecycle = WorktreeLifecycle(since: at(-3600))
        run(&lifecycle, sighting(main, writes: [write(sibling + "/a.txt", at: 0)]), from: 0, to: 1)
        #expect(lifecycle.ended.isEmpty)
        lifecycle.update(PlaceSighting(), at: at(2)) { _, _, _ in .switched }
        #expect(lifecycle.ended == ["7"])
        #expect(lifecycle.places.isEmpty && lifecycle.placements.isEmpty)
        #expect(lifecycle.history["7"] == [sibling])
        lifecycle.update(PlaceSighting(), at: at(3)) { _, _, _ in .switched }
        #expect(lifecycle.ended.isEmpty && lifecycle.history["7"] == [sibling])
    }
}
