import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Today's commits for Post Update: git's arguments for the user's own commits since local midnight in every branch and
/// worktree, and the subjects read back masked, without repeats, and capped.
@Suite struct TodayCommitsTests {
    static let dhaka = TimeZone(identifier: "Asia/Dhaka") ?? .current

    static func midnight(_ zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 18)) ?? Date()
    }

    static func mask(_ value: String) -> SecretMask {
        let key = SymmetricKey(size: .bits256)
        return SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
    }

    @Test func theArgumentsAskForTheUsersOwnCommitsSinceLocalMidnightEverywhere() throws {
        let since = Self.midnight(Self.dhaka)
        let arguments = try #require(TodayCommits.arguments(since: since, email: "dev@example.com",
                                                            timeZone: Self.dhaka))
        #expect(arguments.first == "log")
        #expect(arguments.contains("--all"))
        #expect(arguments.contains("--no-merges"))
        #expect(arguments.contains("--since=2026-10-18T00:00:00+06:00"))
        // The whole address in its angle brackets: olddev@example.com or dev@example.com.au is someone else.
        #expect(arguments.contains("--author=<dev@example.com>"))
        #expect(arguments.contains("--fixed-strings"))
        #expect(arguments.contains("--regexp-ignore-case"))
        #expect(arguments.contains("--format=%s"))
        let count = try #require(arguments.firstIndex(of: "-n"))
        #expect(arguments[count + 1] == "200")
        // A stash or a note is no commit of the day's work, and its excludes must come before --all to apply.
        let all = try #require(arguments.firstIndex(of: "--all"))
        let stash = try #require(arguments.firstIndex(of: "--exclude=refs/stash"))
        #expect(stash < all)
    }

    @Test func noEmailMeansNoArguments() {
        let since = Self.midnight(Self.dhaka)
        #expect(TodayCommits.arguments(since: since, email: nil, timeZone: Self.dhaka) == nil)
        #expect(TodayCommits.arguments(since: since, email: "  \n", timeZone: Self.dhaka) == nil)
        // An email that could be read as an option, or that holds a line break, is not passed to git.
        #expect(TodayCommits.arguments(since: since, email: "a@b\nc", timeZone: Self.dhaka) == nil)
    }

    @Test func aZoneAtUTCWritesItsOffsetInFull() throws {
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        let arguments = try #require(TodayCommits.arguments(since: Self.midnight(utc), email: "d@e.f", timeZone: utc))
        #expect(arguments.contains("--since=2026-10-18T00:00:00+00:00"))
    }

    @Test func parseDropsEmptyAndRepeatedSubjectsAndMasksKeys() {
        let mask = Self.mask("sk-ant-abc123def456")
        let output = "Fix the login\n\n   \nfix token=sk-ant-abc123def456\nFix the login\n  Add retry  \n"
        let subjects = TodayCommits.parse(output, mask: { mask.mask($0) })
        #expect(subjects == ["Fix the login", "fix token=•••", "Add retry"])
    }

    @Test func parseKeepsThirtyAndSaysHowManyMore() {
        let output = (1...42).map { "Commit \($0)" }.joined(separator: "\n")
        let subjects = TodayCommits.parse(output, mask: { $0 })
        #expect(subjects.count == 31)
        #expect(subjects.first == "Commit 1")
        #expect(subjects[29] == "Commit 30")
        #expect(subjects.last == "and 12 more")
    }

    @Test func eachReasonForNoCommitsIsSaid() {
        #expect(TodayCommits.Outcome.noEmail.reason == "No commits: git has no user.email in this project.")
        #expect(TodayCommits.Outcome.subjects(["a"]).reason == nil)
        #expect(TodayCommits.Outcome.notRepository.reason != nil)
        #expect(TodayCommits.Outcome.noGit.reason != nil)
        #expect(TodayCommits.Outcome.failed.reason != nil)
        #expect(TodayCommits.Outcome.subjects(["a", "b"]).subjects == ["a", "b"])
        #expect(TodayCommits.Outcome.noEmail.subjects.isEmpty)
    }

    /// A scratch repository: a main checkout and a sibling linked worktree, each with a commit today on its own branch
    /// by the configured email, and one by someone else.
    @Test func theCommitsAreTheUsersFromEveryWorktreeReadInTheMainCheckout() throws {
        guard let git = GitRunner.locateGit() else { return }
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-today-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = base + "/shop", linked = base + "/shop-fix"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        func sh(_ args: String..., in dir: String = main, email: String = "dev@example.com") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            let settings: [String] = ["-c", "user.name=Dev", "-c", "user.email=" + email,
                                      "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"]
            process.arguments = ["-C", dir] + settings + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        sh("init", "-q")
        sh("config", "user.email", "dev@example.com")
        sh("commit", "-q", "--allow-empty", "-m", "Main work")
        sh("worktree", "add", "-q", "-b", "fix", linked)
        sh("commit", "-q", "--allow-empty", "-m", "Worktree work", in: linked)
        sh("commit", "-q", "--allow-empty", "-m", "Someone else", in: linked, email: "other@example.com")
        // Addresses that hold the user's inside them belong to other people.
        sh("commit", "-q", "--allow-empty", "-m", "Old dev", in: linked, email: "olddev@example.com")
        sh("commit", "-q", "--allow-empty", "-m", "Other country", in: linked, email: "dev@example.com.au")
        // The same address in other letter case is still the user.
        sh("commit", "-q", "--allow-empty", "-m", "Shouted work", in: linked, email: "DEV@Example.com")
        // A stash is made of commits by the user today too ("index on fix: …"): none of them is work done.
        try "draft\n".write(toFile: linked + "/notes.txt", atomically: true, encoding: .utf8)
        sh("add", "notes.txt", in: linked)
        sh("stash", "-q", in: linked)
        let before = GitRunner.runs(in: linked)
        let outcome = TodayCommits.read(project: linked, git: git, now: Date(), calendar: .current, mask: { $0 })
        #expect(Set(outcome.subjects) == ["Main work", "Worktree work", "Shouted work"])
        #expect(GitRunner.runs(in: linked) == before)
        #expect(GitRunner.runs(in: canonicalPath(main)) > 0)
        let fromMain = TodayCommits.read(project: main, git: git, now: Date(), calendar: .current, mask: { $0 })
        #expect(Set(fromMain.subjects) == ["Main work", "Worktree work", "Shouted work"])
        // An empty email in the project's own settings means no commit lines, never every author's.
        sh("config", "user.email", "")
        let none = TodayCommits.read(project: main, git: git, now: Date(), calendar: .current, mask: { $0 })
        #expect(none == .noEmail)
    }

    @Test func aFolderOutsideGitAndNoGitAreSaid() throws {
        let folder = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(TodayCommits.read(project: folder, git: nil, now: Date(), calendar: .current, mask: { $0 }) == .noGit)
        guard let git = GitRunner.locateGit() else { return }
        let outcome = TodayCommits.read(project: folder, git: git, now: Date(), calendar: .current, mask: { $0 })
        #expect(outcome == .notRepository)
    }
}
