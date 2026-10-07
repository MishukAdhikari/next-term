import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommitGraphTests {
    typealias Line = GraphRow.Line

    func layout(_ commits: [(String, [String])], maxColumns: Int = 24) -> [GraphRow] {
        var graph = CommitGraph(maxColumns: maxColumns)
        return commits.map { graph.add(sha: $0.0, parents: $0.1) }
    }

    @Test func aStraightLine() {
        let rows = layout([("c", ["b"]), ("b", ["a"]), ("a", [])])
        #expect(rows.map(\.column) == [0, 0, 0] && rows.allSatisfy { $0.width == 1 && !$0.isMerge })
        #expect(rows[0].top.isEmpty && rows[0].bottom == [Line(from: 0, to: 0, color: rows[0].color)]) // a tip: nothing above
        #expect(rows[1].top.count == 1 && rows[1].bottom.count == 1)
        #expect(rows[2].bottom.isEmpty) // the first commit: nothing below
        #expect(Set(rows.map(\.color)).count == 1)
    }

    /// m merges b into a; a and b both start from r.
    @Test func aBranchAndItsMerge() {
        let rows = layout([("m", ["a", "b"]), ("a", ["r"]), ("b", ["r"]), ("r", [])])
        let m = rows[0], a = rows[1], b = rows[2], r = rows[3]
        #expect(m.isMerge && m.column == 0 && m.width == 2)
        #expect(m.bottom == [Line(from: 0, to: 0, color: m.color), Line(from: 0, to: 1, color: b.color)]) // the merge line to b's lane
        #expect(a.column == 0 && a.color == m.color) // the first parent keeps the lane and its colour
        #expect(a.top == [Line(from: 0, to: 0, color: a.color), Line(from: 1, to: 1, color: b.color)])
        #expect(b.column == 1 && b.color != a.color)
        #expect(b.bottom == [Line(from: 0, to: 0, color: a.color), Line(from: 1, to: 1, color: b.color)])
        // Where the branch started, its lane ends in the dot.
        #expect(r.column == 0 && r.top == [Line(from: 0, to: 0, color: a.color), Line(from: 1, to: 0, color: b.color)] && r.bottom.isEmpty)
    }

    @Test func anOctopusMerge() {
        let rows = layout([("o", ["p1", "p2", "p3"]), ("p1", ["r"]), ("p2", ["r"]), ("p3", ["r"]), ("r", [])])
        #expect(rows[0].isMerge && rows[0].bottom.map(\.to) == [0, 1, 2] && rows[0].bottom.allSatisfy { $0.from == 0 })
        #expect(Set(rows[0].bottom.map(\.color)).count == 3)
        #expect(rows[1...3].map(\.column) == [0, 1, 2])
        #expect(rows[4].top.map(\.to) == [0, 0, 0] && rows[4].top.map(\.from) == [0, 1, 2])
    }

    /// A merge whose second parent a lane already waits for joins that lane instead of starting one.
    @Test func aMergeJoinsTheLaneWaitingForItsParent() {
        var graph = CommitGraph()
        let t = graph.add(sha: "t", parents: ["c"])
        let m = graph.add(sha: "m", parents: ["a", "c"])
        #expect(t.column == 0 && m.column == 1)
        #expect(m.bottom.contains(Line(from: 1, to: 0, color: t.color)) && m.bottom.contains(Line(from: 0, to: 0, color: t.color)))
        #expect(graph.openLanes == 2 && m.width == 2)
        _ = graph.add(sha: "a", parents: ["c"])
        let c = graph.add(sha: "c", parents: [])
        #expect(c.column == 0 && c.top.map(\.to) == [0, 0] && graph.openLanes == 0)
    }

    /// Lanes free up when a branch ends, and the next branch reuses them.
    @Test func branchesEndAndLanesAreReused() {
        let rows = layout([("m", ["a", "x"]), ("x", []), ("a", ["r"]), ("t", ["r"]), ("r", [])])
        #expect(rows[1].column == 1 && rows[1].bottom == [Line(from: 0, to: 0, color: rows[0].color)]) // x has no parent: its lane ends there
        #expect(rows[2].width == 1 && rows[2].top.count == 1) // a: only its own lane is left
        #expect(rows[3].column == 1) // t, a new tip, takes the freed lane
        let unrelated = layout([("x", []), ("y", [])])
        #expect(unrelated.map(\.column) == [0, 0])
    }

    /// Lanes past maxColumns share one overflow column, with no line through it: a line there would
    /// join commits of unrelated branches.
    @Test func manyParallelBranchesOverflow() {
        let tips = (0..<40).map { ("t\($0)", ["r"]) }
        let rows = layout(tips + [("r", [])], maxColumns: 10)
        #expect(rows.allSatisfy { $0.width <= 11 && $0.column <= 10 })
        #expect(rows[9].column == 9 && !rows[9].isOverflow && rows[10].column == 10 && rows[10].isOverflow)
        // t39: the ten lanes on the left pass through; the 29 others, and its own, are not drawn.
        #expect(rows[39].column == 10 && rows[39].top.count == 10 && rows[39].bottom.count == 10)
        #expect((rows[10...39]).allSatisfy { row in (row.top + row.bottom).allSatisfy { min($0.from, $0.to) < 10 } })
        // r: every lane ends in it; from the overflow, once a colour.
        let r = rows[40]
        #expect(r.column == 0 && !r.isOverflow && r.top.allSatisfy { $0.to == 0 } && r.width == 11)
        #expect(r.top.filter { $0.from < 10 }.count == 10 && r.top.filter { $0.from == 10 }.count == CommitGraph.colorCount)
        #expect(Set(r.top).count == r.top.count)
    }

    /// A merge in a lane drawn in full whose second parent waits in the overflow: the line ends at the
    /// overflow column, and the parent's dot is there, with only the lanes on the left through its row.
    @Test func aLineIntoTheOverflow() {
        let rows = layout([("a", ["p"]), ("b", ["r"]), ("c", ["x"]), ("p", ["r", "x"]), ("x", [])], maxColumns: 2)
        let c = rows[2], p = rows[3], x = rows[4]
        #expect(c.isOverflow && c.column == 2 && c.width == 3)
        #expect(!p.isOverflow && p.column == 0 && p.bottom.contains(Line(from: 0, to: 2, color: c.color, isCut: true)) && p.width == 3)
        #expect((p.top + p.bottom).allSatisfy { min($0.from, $0.to) < 2 })
        #expect(x.isOverflow && x.column == 2 && x.top.map(\.from) == [0, 1] && x.bottom.map(\.from) == [0, 1])
        // Lines into its dot, in the overflow column, end in the dot: they are not cut.
        #expect(!(x.top + x.bottom).contains { $0.isCut })
    }

    /// p's line to x, which waits in lane 2, and the line into q from e's lane 3 both end at the overflow
    /// column, on the edge between their rows: they stop short of it, or they would look like one line.
    @Test func linesCutAtTheOverflowStopShortOfTheEdge() {
        let rows = layout([("a", ["p"]), ("b", ["q"]), ("c", ["x"]), ("e", ["q"]), ("p", ["r", "x"]), ("q", ["r"]), ("x", ["r"]), ("r", [])], maxColumns: 2)
        let c = rows[2], e = rows[3], p = rows[4], q = rows[5]
        #expect(c.isOverflow && e.isOverflow && !p.isOverflow && !q.isOverflow)
        #expect(p.bottom.contains(Line(from: 0, to: 2, color: c.color, isCut: true)))
        #expect(q.top.contains(Line(from: 2, to: 1, color: e.color, isCut: true)))
        // No line reaches a row's edge in the overflow column; every other line does, where the next goes on.
        for row in rows {
            #expect(row.top.allSatisfy { $0.isCut == ($0.from == 2) })
            #expect(row.bottom.allSatisfy { $0.isCut == ($0.to == 2 && $0.from != 2) })
        }
        let lanes: [(String, [String])] = (0..<6).map { ("t\($0)", ["r"]) } + [("r", [])]
        #expect(layout(lanes, maxColumns: 24).allSatisfy { row in !(row.top + row.bottom).contains { $0.isCut } })
    }

    @Test func pagesCarryTheLanesOver() {
        let commits: [(String, [String])] = [("m", ["a", "b"]), ("a", ["r"]), ("b", ["r"]), ("r", ["q"]), ("q", [])]
        var paged = CommitGraph()
        let first = commits.prefix(2).map { paged.add(sha: $0.0, parents: $0.1) }
        #expect(paged.openLanes == 2)
        let second = commits.dropFirst(2).map { paged.add(sha: $0.0, parents: $0.1) }
        #expect(first + second == layout(commits))
    }

    @Test func coloursStayWithTheirLane() {
        let rows = layout([("m2", ["m1", "f2"]), ("f2", ["f1"]), ("m1", ["r"]), ("f1", ["r"]), ("r", [])])
        #expect(rows[0].color == rows[2].color && rows[1].color == rows[3].color && rows[0].color != rows[1].color)
        #expect(rows.allSatisfy { (0..<CommitGraph.colorCount).contains($0.color) })
    }

    @Test func withoutLines() {
        var graph = CommitGraph(connected: false)
        let rows = graph.add([Commit(sha: "a", parents: ["b", "c"]), Commit(sha: "d", parents: ["e"])])
        #expect(rows.allSatisfy { $0.column == 0 && $0.top.isEmpty && $0.bottom.isEmpty && $0.width == 1 })
        #expect(rows[0].isMerge && !rows[1].isMerge)
    }
}
