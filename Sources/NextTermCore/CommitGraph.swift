import Foundation

/// One row of the commit graph: the column of the commit's dot and the lines crossing the row, by
/// column. A line in the top half runs from the row's top edge to its middle; one in the bottom half,
/// from the middle to the bottom edge. Rows drawn one under another join into the whole graph.
public struct GraphRow: Equatable, Sendable {
    public struct Line: Equatable, Hashable, Sendable {
        public let from: Int
        public let to: Int
        /// An index into the palette (0..<CommitGraph.colorCount).
        public let color: Int

        public init(from: Int, to: Int, color: Int) {
            self.from = from
            self.to = to
            self.color = color
        }
    }

    public let column: Int
    public let color: Int
    public let isMerge: Bool
    /// Lanes passing through (from == to), and lanes ending in the dot (to == column): the commit's
    /// children, or branches that started from it.
    public let top: [Line]
    /// Lanes passing through, and lines from the dot (from == column) to the lanes of its parents.
    public let bottom: [Line]
    /// Columns this row uses.
    public let width: Int

    public init(column: Int, color: Int, isMerge: Bool, top: [Line], bottom: [Line], width: Int) {
        self.column = column
        self.color = color
        self.isMerge = isMerge
        self.top = top
        self.bottom = bottom
        self.width = width
    }
}

/// Lays out commits in lanes, row by row, for commits listed with every commit after all of its
/// children (`git log --topo-order`). A lane waits for one commit: a commit takes the leftmost lane
/// waiting for it (a branch tip, which nothing waits for, takes the first free lane), the lanes of its
/// other children end in it, its first parent continues its lane, and each further parent joins the
/// lane already waiting for it or starts one. Free lanes are reused, so branches that end make room.
/// The state carries over from page to page: `add` the next page and the lines go on.
public struct CommitGraph: Sendable {
    public static let colorCount = 8
    /// Wider than this, the rightmost lanes share the last column: the graph stays readable.
    public let maxColumns: Int
    /// Without lines (a log filtered by message or author, where parents are mostly not listed):
    /// every commit is a dot in the first column.
    public let connected: Bool

    /// The commit each lane waits for; nil for a free one.
    private var lanes: [String?] = []
    private var colors: [Int] = []
    private var nextColor = 0

    public init(maxColumns: Int = 24, connected: Bool = true) {
        self.maxColumns = max(1, maxColumns)
        self.connected = connected
    }

    /// Lanes still waiting for a commit (lines that go on below the last row).
    public var openLanes: Int { lanes.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    public mutating func add(_ commits: [Commit]) -> [GraphRow] {
        commits.map { add(sha: $0.sha, parents: $0.parents) }
    }

    public mutating func add(sha: String, parents: [String]) -> GraphRow {
        guard connected else { return GraphRow(column: 0, color: 0, isMerge: parents.count > 1, top: [], bottom: [], width: 1) }
        let before = lanes
        let incoming = lanes.indices.filter { lanes[$0] == sha }
        let column: Int
        let color: Int
        if let first = incoming.first {
            column = first
            color = colors[first]
        } else {
            column = freeLane()
            color = takeColor()
            colors[column] = color
        }

        var top: [GraphRow.Line] = []
        for (i, waiting) in before.enumerated() where waiting != nil {
            top.append(.init(from: i, to: waiting == sha ? column : i, color: colors[i]))
        }

        for i in incoming { lanes[i] = nil }
        var fromDot: [Int] = []
        if let first = parents.first {
            lanes[column] = first
            colors[column] = color
            fromDot.append(column)
        }
        for parent in parents.dropFirst() {
            if let waiting = lanes.firstIndex(where: { $0 == parent }) {
                if !fromDot.contains(waiting) { fromDot.append(waiting) }
            } else {
                let lane = freeLane()
                lanes[lane] = parent
                colors[lane] = takeColor()
                fromDot.append(lane)
            }
        }

        var bottom: [GraphRow.Line] = []
        for (i, waiting) in lanes.enumerated() where waiting != nil && i < before.count && before[i] == waiting && waiting != sha {
            bottom.append(.init(from: i, to: i, color: colors[i]))
        }
        for lane in fromDot { bottom.append(.init(from: column, to: lane, color: colors[lane])) }

        while let last = lanes.last, last == nil {
            lanes.removeLast()
            colors.removeLast()
        }
        let last = maxColumns - 1
        let cap = { (c: Int) in min(c, last) }
        let clamp = { (line: GraphRow.Line) in GraphRow.Line(from: cap(line.from), to: cap(line.to), color: line.color) }
        let widest = (top + bottom).reduce(column) { max($0, $1.from, $1.to) }
        return GraphRow(column: cap(column), color: color, isMerge: parents.count > 1, top: top.map(clamp), bottom: bottom.map(clamp),
                        width: cap(widest) + 1)
    }

    /// The first free lane, or a new one at the right.
    private mutating func freeLane() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        colors.append(0)
        return lanes.count - 1
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor % Self.colorCount
    }
}
