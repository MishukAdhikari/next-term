import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommandHistoryTests {
    /// A deterministic generator, so a property's cases are the same every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func lines(_ entries: [CommandHistory.Entry]) -> [String] { entries.map(\.line) }

    @Test func theNewestMatchComesFirst() {
        var history = CommandHistory()
        history.record("git checkout main", folder: "/p", repo: nil, at: 1_000)
        history.record("git cherry-pick abc", folder: "/p", repo: nil, at: 2_000)
        history.record("ls", folder: "/p", repo: nil, at: 3_000)
        #expect(lines(history.query(prefix: "git ch")) == ["git cherry-pick abc", "git checkout main"])
        #expect(lines(history.query(prefix: "git chec")) == ["git checkout main"])
        #expect(history.query(prefix: "git chx").isEmpty && history.query(prefix: "").isEmpty)
        // Running one again makes it the newest.
        history.record("git checkout main", folder: "/p", repo: nil, at: 4_000)
        #expect(lines(history.query(prefix: "git ch")) == ["git checkout main", "git cherry-pick abc"])
        #expect(lines(history.query(prefix: "git ch", limit: 1)) == ["git checkout main"])
    }

    @Test func aLineIsNoSuggestionForItself() {
        var history = CommandHistory()
        history.record("ls", folder: nil, repo: nil, at: 1)
        history.record("ls -la", folder: nil, repo: nil, at: 2)
        #expect(lines(history.query(prefix: "ls")) == ["ls -la"])
        #expect(history.query(prefix: "ls -la").isEmpty)
    }

    /// Case-blind unless what was typed has a capital, ASCII letters only.
    @Test func smartCase() {
        var history = CommandHistory()
        history.record("Makefile-run x", folder: nil, repo: nil, at: 1)
        history.record("make test", folder: nil, repo: nil, at: 2)
        history.record("MAKE all", folder: nil, repo: nil, at: 3)
        #expect(lines(history.query(prefix: "make")) == ["MAKE all", "make test", "Makefile-run x"])
        #expect(lines(history.query(prefix: "Make")) == ["Makefile-run x"])
        #expect(lines(history.query(prefix: "MA")) == ["MAKE all"])
        history.record("écho é", folder: nil, repo: nil, at: 4)
        history.record("Écho É", folder: nil, repo: nil, at: 5)
        #expect(lines(history.query(prefix: "é")) == ["écho é"])
        #expect(lines(history.query(prefix: "É")) == ["Écho É"])
    }

    @Test func oneEntryALine() {
        var history = CommandHistory()
        history.record("npm test", folder: "/a", repo: "/a/.git", at: 10)
        let twice = history.record("npm test  ", folder: "/b", repo: nil, at: 20)
        #expect(twice?.count == 2 && twice?.lastRun == 20 && twice?.folder == "/b" && twice?.repo == nil && twice?.line == "npm test")
        #expect(history.count == 1)
        // A run recorded late keeps the newer time and place.
        let late = history.record("npm test", folder: "/c", repo: nil, at: 15)
        #expect(late?.count == 3 && late?.lastRun == 20 && late?.folder == "/b")
    }

    @Test func linesThatAreNeverKept() {
        var history = CommandHistory()
        #expect(history.record(" ls", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.record("\tls", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.record("echo a\necho b", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.record("   ", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.record("", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.record("export GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyzAB", folder: nil, repo: nil, at: 1) == nil)
        // A stored key's value anywhere in the line.
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: "hunter2-stored-value"), key: key))
        #expect(history.record("curl -u me:hunter2-stored-value x", folder: nil, repo: nil, at: 1, mask: mask) == nil)
        #expect(!CommandHistory.keeps(" ls") && CommandHistory.keeps("ls"))
        let most = "echo " + String(repeating: "abc ", count: 510) + "abc"
        #expect(most.utf8.count == CommandHistory.maxLineBytes)
        #expect(history.record(most, folder: nil, repo: nil, at: 1) != nil)
        #expect(history.record(most + "x", folder: nil, repo: nil, at: 1) == nil)
        #expect(history.count == 1)
    }

    @Test func exitsSayWhetherItEverSucceeded() {
        var history = CommandHistory()
        history.record("npm run dev", folder: nil, repo: nil, at: 1)
        history.ended("npm run dev", exit: 130)
        history.record("false", folder: nil, repo: nil, at: 2)
        history.ended("false", exit: 1)
        history.record("make", folder: nil, repo: nil, at: 3)
        history.ended("make", exit: 0)
        history.record("make", folder: nil, repo: nil, at: 4)
        history.ended("make", exit: 127)
        history.record("tail -f x", folder: nil, repo: nil, at: 5)
        let entries = Dictionary(uniqueKeysWithValues: history.entries().map { ($0.line, $0) })
        #expect(entries["npm run dev"]?.everSucceeded == true && entries["npm run dev"]?.lastExit == 130)
        #expect(entries["false"]?.everSucceeded == false && entries["false"]?.lastExit == 1)
        #expect(entries["make"]?.everSucceeded == true && entries["make"]?.lastExit == 127 && entries["make"]?.count == 2)
        #expect(entries["tail -f x"]?.lastExit == nil)
        #expect([0, 129, 130, 141, 143].allSatisfy { CommandHistory.succeeded(exit: $0) } && !CommandHistory.succeeded(exit: 1))
    }

    @Test func forgetAndClear() {
        var history = CommandHistory()
        history.record("git checkout main", folder: nil, repo: nil, at: 1)
        history.record("git checkout dev", folder: nil, repo: nil, at: 2)
        history.forget("git checkout dev")
        #expect(lines(history.query(prefix: "git")) == ["git checkout main"] && history.count == 1)
        history.record("git checkout dev", folder: nil, repo: nil, at: 3)
        #expect(lines(history.query(prefix: "git")) == ["git checkout dev", "git checkout main"])
        history.clear()
        #expect(history.count == 0 && history.query(prefix: "git").isEmpty)
    }

    /// At the same millisecond, the asking folder's comes first, then its repository's, then the one run more often.
    @Test func tiesGoByPlace() {
        var history = CommandHistory()
        history.record("make a", folder: "/one", repo: "/r1", at: 5)
        history.record("make b", folder: "/two", repo: "/r2", at: 5)
        history.record("make b", folder: "/two", repo: "/r2", at: 5)
        #expect(lines(history.query(prefix: "make", folder: "/one")) == ["make a", "make b"])
        #expect(lines(history.query(prefix: "make", folder: "/two")) == ["make b", "make a"])
        #expect(lines(history.query(prefix: "make", folder: "/x", repo: "/r1")) == ["make a", "make b"])
        #expect(lines(history.query(prefix: "make")) == ["make b", "make a"])
    }

    @Test func theLeastRecentlyRunGoPastTheCap() {
        var history = CommandHistory()
        let entries = (0..<CommandHistory.maxEntries).map { CommandHistory.Entry(line: "echo \($0)", lastRun: Int64($0)) }
        history.load(entries)
        #expect(history.count == CommandHistory.maxEntries)
        history.record("echo newest", folder: nil, repo: nil, at: 1_000_000)
        #expect(history.count == CommandHistory.maxEntries + 1 - CommandHistory.maxEntries / 100)
        let kept = Set(history.entries().map(\.line))
        #expect(!kept.contains("echo 0") && !kept.contains("echo 999") && kept.contains("echo 1000") && kept.contains("echo newest"))
        #expect(lines(history.query(prefix: "echo newe")) == ["echo newest"])
        #expect(lines(history.query(prefix: "echo 9999", limit: 1)) == ["echo 99999"])
        #expect(!history.query(prefix: "echo 999").isEmpty && history.query(prefix: "echo 99").count == CommandHistory.queryLimit)
    }

    /// A query costs its two binary searches and its range, never the whole record.
    @Test func aQueryLooksOnlyAtItsRange() {
        var history = CommandHistory()
        let entries = (0..<CommandHistory.maxEntries).map { CommandHistory.Entry(line: "cmd-\($0 % 977) arg \($0)", lastRun: Int64($0)) }
        history.load(entries)
        let n = Double(history.count)
        let probes = 2 * Int(log2(n).rounded(.up))
        for prefix in ["cmd-12 ", "cmd-5", "cmd-976 arg 9", "zzz", "c"] {
            let range = entries.filter { $0.line.hasPrefix(prefix) }.count
            let result = history.search(prefix: prefix, folder: nil, repo: nil, limit: 8)
            #expect(result.examined <= range + probes, "\(prefix): \(result.examined) for a range of \(range)")
            #expect(result.entries.count == min(8, range))
        }
    }

    /// The newest match for a longer prefix is the newest for the shorter one whenever that still matches it: typing
    /// through a suggestion needs no new query.
    @Test func typingThroughKeepsTheSameSuggestion() {
        var random = Seeded(state: 42)
        var history = CommandHistory()
        let alphabet = Array("abAB c/")
        var made: [String] = []
        for _ in 0..<3000 {
            let length = Int.random(in: 1...10, using: &random)
            let line = String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] })
            let at = Int64.random(in: 0..<500, using: &random)
            let folder = ["/a", "/b", nil][Int.random(in: 0..<3, using: &random)]
            if history.record(line, folder: folder, repo: nil, at: at) != nil { made.append(line) }
        }
        var checked = 0
        for line in made.prefix(400) {
            for cut in 1..<max(1, line.count) {
                let prefix = String(line.prefix(cut))
                guard let top = history.query(prefix: prefix, folder: "/a", limit: 1).first else { continue }
                for longer in (prefix.count + 1)..<top.line.count {
                    let next = String(top.line.prefix(longer))
                    guard next.last != " ", next.last != "\t" else { continue }
                    #expect(history.query(prefix: next, folder: "/a", limit: 1).first?.line == top.line, "\(prefix) → \(next)")
                    checked += 1
                }
            }
        }
        #expect(checked > 100)
    }

    @Test func loadingKeepsTheLastStateOfALine() {
        var history = CommandHistory()
        history.load([CommandHistory.Entry(line: "make", lastRun: 1, count: 1, successes: 0, lastExit: 2, folder: "/a"),
                      CommandHistory.Entry(line: "ls", lastRun: 2),
                      CommandHistory.Entry(line: "make", lastRun: 3, count: 2, successes: 1, lastExit: 0, folder: "/b"),
                      CommandHistory.Entry(line: " hidden", lastRun: 4)])
        let entries = history.entries()
        #expect(entries.count == 2 && entries.first { $0.line == "make" } == CommandHistory.Entry(line: "make", lastRun: 3, count: 2,
                                                                                                   successes: 1, lastExit: 0, folder: "/b"))
        #expect(lines(history.query(prefix: "m")) == ["make"])
    }
}
