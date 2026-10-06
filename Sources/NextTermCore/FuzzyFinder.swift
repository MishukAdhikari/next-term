import Foundation

/// Go to File's matcher: the letters you type, in order, anywhere in a path ("usrctl" finds
/// app/Http/Controllers/UserController.php). Matches are scored the way people read paths: letters in
/// the file name beat letters in folder names, the start of a word or a camelCase hump beats the middle
/// of one, and runs of consecutive letters beat scattered ones. Every path is kept as lowercase bytes in
/// one buffer, with a bonus per byte computed once, so a search over 100,000 paths is a tight loop.
public final class FuzzyIndex: @unchecked Sendable {
    public let paths: [String]
    private let bytes: [UInt8]
    private let bonuses: [Int16]
    private let starts: [Int]
    private let lengths: [Int]
    private let nameStarts: [Int]

    public struct Match: Sendable, Equatable {
        public let index: Int
        public let score: Int
        public init(index: Int, score: Int) {
            self.index = index
            self.score = score
        }
    }

    static let matchScore = 16
    static let consecutiveBonus = 6
    static let gapOpen = 3
    static let gapExtend = 1
    static let fileNameBonus = 24
    /// Paths longer than this are matched on their last part (where the file name is).
    static let maxLength = 512

    public init(paths: [String]) {
        self.paths = paths
        var bytes: [UInt8] = []
        var bonuses: [Int16] = []
        var starts: [Int] = [], lengths: [Int] = [], nameStarts: [Int] = []
        bytes.reserveCapacity(paths.count * 48)
        bonuses.reserveCapacity(paths.count * 48)
        for path in paths {
            var original = Array(path.utf8)
            if original.count > Self.maxLength { original = Array(original.suffix(Self.maxLength)) }
            starts.append(bytes.count)
            lengths.append(original.count)
            let name = (original.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
            nameStarts.append(name)
            for (j, byte) in original.enumerated() {
                bytes.append(Self.lower(byte))
                bonuses.append(Self.bonus(at: j, in: original, nameStart: name))
            }
        }
        self.bytes = bytes
        self.bonuses = bonuses
        self.starts = starts
        self.lengths = lengths
        self.nameStarts = nameStarts
    }

    @inline(__always) static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    /// How much a letter at `j` is worth beyond matching: the start of the file name, of a folder, of a
    /// word (after - _ . or space), a camelCase hump, a digit after a letter.
    static func bonus(at j: Int, in s: [UInt8], nameStart: Int) -> Int16 {
        let current = s[j]
        let previous: UInt8 = j == 0 ? UInt8(ascii: "/") : s[j - 1]
        func isLower(_ b: UInt8) -> Bool { b >= 97 && b <= 122 }
        func isUpper(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        var bonus: Int16 = 0
        if previous == UInt8(ascii: "/") {
            bonus = 9
        } else if previous == UInt8(ascii: "_") || previous == UInt8(ascii: "-") || previous == UInt8(ascii: ".") || previous == UInt8(ascii: " ") {
            bonus = 7
        } else if isLower(previous) && isUpper(current) {
            bonus = 7
        } else if isDigit(current) && !isDigit(previous) {
            bonus = 3
        }
        if j == nameStart { bonus += 6 }
        if j >= nameStart { bonus += 1 }
        return bonus
    }

    /// The query as the matcher uses it: lowercase, without spaces (they only separate words you type).
    public static func normalize(_ query: String) -> [UInt8] {
        query.utf8.filter { $0 != UInt8(ascii: " ") }.map(lower)
    }

    /// Every path matching `query`, scored (unsorted). `among`: only these indexes (the matches of a
    /// shorter query this one extends). `cancelled` is polled now and then.
    public func search(_ query: String, among: [Int]? = nil, cancelled: () -> Bool = { false }) -> [Match]? {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return (among ?? Array(paths.indices)).map { Match(index: $0, score: 0) } }
        var results: [Match] = []
        var previous = [Int32](repeating: 0, count: Self.maxLength + 1)
        var current = [Int32](repeating: 0, count: Self.maxLength + 1)
        let candidates = among ?? Array(paths.indices)
        for (n, index) in candidates.enumerated() {
            if n & 4095 == 4095, cancelled() { return nil }
            if let score = score(q, index, &previous, &current) { results.append(Match(index: index, score: score)) }
        }
        return results
    }

    /// Best first: score, then the shorter path, then alphabetical.
    public func sorted(_ matches: [Match], limit: Int) -> [Match] {
        let ordered = matches.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if lengths[a.index] != lengths[b.index] { return lengths[a.index] < lengths[b.index] }
            return paths[a.index] < paths[b.index]
        }
        return Array(ordered.prefix(limit))
    }

    private static let impossible: Int32 = -1_000_000

    /// The best alignment's score: over the whole path, or within the file name (worth more).
    private func score(_ q: [UInt8], _ index: Int, _ previous: inout [Int32], _ current: inout [Int32]) -> Int? {
        let start = starts[index], length = lengths[index], name = nameStarts[index]
        guard q.count <= length else { return nil }
        // Quick test: are the letters there in order at all?
        var k = 0
        bytes.withUnsafeBufferPointer { b in
            var j = start
            let end = start + length
            while j < end && k < q.count {
                if b[j] == q[k] { k += 1 }
                j += 1
            }
        }
        guard k == q.count else { return nil }
        let whole = align(q, start: start, from: 0, to: length, &previous, &current)
        let inName = q.count <= length - name ? align(q, start: start, from: name, to: length, &previous, &current) : Self.impossible
        var best = max(Int(whole), inName > Self.impossible / 2 ? Int(inName) + Self.fileNameBonus : Int.min)
        guard best > Int(Self.impossible / 2) else { return nil }
        // Exactly the file's name ("user" for User.php, or "user.php"): what you most likely mean.
        if isExactName(q, start: start + name, end: start + length) { best += Self.exactNameBonus }
        return best
    }

    static let exactNameBonus = 30

    /// The query is the whole file name, or the name before its extension.
    private func isExactName(_ q: [UInt8], start: Int, end: Int) -> Bool {
        let count = end - start
        guard q.count <= count else { return false }
        for k in 0..<q.count where bytes[start + k] != q[k] { return false }
        return q.count == count || bytes[start + q.count] == UInt8(ascii: ".")
    }

    /// Smith-Waterman-style: the best score for the query's letters at positions in [from, to), where
    /// each letter earns its match score and its position's bonus, a letter right after the previous
    /// one earns the consecutive bonus, and a gap costs more the longer it is.
    private func align(_ q: [UInt8], start: Int, from: Int, to: Int, _ previous: inout [Int32], _ current: inout [Int32]) -> Int32 {
        let n = to - from
        guard n >= q.count else { return Self.impossible }
        return bytes.withUnsafeBufferPointer { b in
            bonuses.withUnsafeBufferPointer { bonus in
                previous.withUnsafeMutableBufferPointer { previousRow in
                    current.withUnsafeMutableBufferPointer { currentRow in
                        // Rows swap places each letter (the buffers themselves must stay put).
                        var prev = previousRow, cur = currentRow
                        let base = start + from
                        for i in 0..<q.count {
                            let letter = q[i]
                            var gap = Self.impossible // best (previous letter's score - gap cost) for a gap ending before j
                            for j in 0..<n {
                                var value = Self.impossible
                                if b[base + j] == letter {
                                    let own = Int32(Self.matchScore) + Int32(bonus[base + j])
                                    if i == 0 {
                                        value = own
                                    } else if j > 0 {
                                        let consecutive = prev[j - 1] > Self.impossible / 2 ? prev[j - 1] + Int32(Self.consecutiveBonus) : Self.impossible
                                        let best = max(consecutive, gap)
                                        if best > Self.impossible / 2 { value = own + best }
                                    }
                                }
                                // The gap for j + 1: extend the old one, or open one after the previous letter at j - 1.
                                if i > 0 {
                                    let opened = j > 0 && prev[j - 1] > Self.impossible / 2 ? prev[j - 1] - Int32(Self.gapOpen) : Self.impossible
                                    gap = max(gap > Self.impossible / 2 ? gap - Int32(Self.gapExtend) : Self.impossible, opened)
                                }
                                cur[j] = value
                            }
                            swap(&prev, &cur)
                        }
                        var best = Self.impossible
                        for j in 0..<n where prev[j] > best { best = prev[j] }
                        return best
                    }
                }
            }
        }
    }

    /// Where the query's letters are in a path (UTF-8 offsets), for highlighting: the same alignment the
    /// score came from.
    public func positions(of query: String, in index: Int) -> [Int] {
        let q = Self.normalize(query)
        guard !q.isEmpty, index < paths.count else { return [] }
        let start = starts[index], length = lengths[index], name = nameStarts[index]
        let offset = Array(paths[index].utf8).count - length // a long path is matched on its end
        let whole = trace(q, start: start, from: 0, to: length)
        let inName = trace(q, start: start, from: name, to: length)
        let pick: (score: Int, positions: [Int])?
        if let inName, inName.score + Self.fileNameBonus >= (whole?.score ?? Int.min) {
            pick = inName
        } else {
            pick = whole
        }
        return pick?.positions.map { $0 + offset } ?? []
    }

    private func trace(_ q: [UInt8], start: Int, from: Int, to: Int) -> (score: Int, positions: [Int])? {
        let n = to - from, m = q.count
        guard n >= m else { return nil }
        let none = Int.min / 4
        var score = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var back = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for i in 0..<m {
            var gap = none, gapFrom = -1
            for j in 0..<n {
                if i > 0 {
                    // Gap ending before j: from the previous letter at k <= j - 2.
                    if j >= 2, score[i - 1][j - 2] > none {
                        let opened = score[i - 1][j - 2] - Self.gapOpen
                        let extended = gap > none ? gap - Self.gapExtend : none
                        if opened >= extended { gap = opened; gapFrom = j - 2 } else { gap = extended }
                    } else if gap > none {
                        gap -= Self.gapExtend
                    }
                }
                guard bytes[start + from + j] == q[i] else { continue }
                let own = Self.matchScore + Int(bonuses[start + from + j])
                if i == 0 {
                    score[i][j] = own
                    continue
                }
                let consecutive = j > 0 && score[i - 1][j - 1] > none ? score[i - 1][j - 1] + Self.consecutiveBonus : none
                if consecutive >= gap, consecutive > none {
                    score[i][j] = own + consecutive
                    back[i][j] = j - 1
                } else if gap > none {
                    score[i][j] = own + gap
                    back[i][j] = gapFrom
                }
            }
        }
        guard let end = (0..<n).max(by: { score[m - 1][$0] < score[m - 1][$1] }), score[m - 1][end] > none else { return nil }
        var positions: [Int] = []
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions.append(from + j)
            j = back[i][j]
            if i > 0 && j < 0 { return nil }
        }
        return (score[m - 1][end], positions.reversed())
    }
}

/// Files under a folder for Go to File when git cannot list them: a quick walk that leaves out hidden
/// folders and the usual dependency and build folders, and stops at a limit.
public enum FileWalker {
    static let skipped: Set<String> = ["node_modules", "vendor", ".build", "build", "dist", "DerivedData", ".next", ".venv",
                                       "__pycache__", "Pods", "target", ".gradle", "Library",
                                       // State that ML and agent tools write next to a project.
                                       ".langgraph_api", "mlruns", "mlartifacts", ".ipynb_checkpoints", "wandb"]

    /// Paths relative to `root`, and whether the walk saw everything.
    public static func files(in root: String, limit: Int = 200_000, seconds: TimeInterval = 5) -> (paths: [String], complete: Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        var result: [String] = []
        guard let walker = FileManager.default.enumerator(atPath: root) else { return ([], true) }
        var complete = true
        while let relative = walker.nextObject() as? String {
            if result.count >= limit || (result.count & 1023 == 0 && Date() > deadline) { complete = false; break }
            let name = (relative as NSString).lastPathComponent
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if name.hasPrefix(".") || skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard type == .typeRegular, name != ".DS_Store" else { continue }
            result.append(relative)
        }
        return (result, complete)
    }
}
