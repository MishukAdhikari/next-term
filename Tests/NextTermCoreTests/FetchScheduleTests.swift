import Foundation
import Testing
@testable import NextTermCore

@Suite struct FetchScheduleTests {
    let repo = "/r/.git"
    let start = Date(timeIntervalSince1970: 1_760_000_000)

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Fetches at `minutes`, as the app would: started, then fetched.
    func fetch(_ schedule: inout FetchSchedule, at minutes: Double, _ outcome: FetchSchedule.Outcome = .fetched) {
        schedule.started(repo, at: at(minutes))
        schedule.finished(repo, at: at(minutes), outcome)
    }

    @Test func everyIntervalWhileActive() {
        var schedule = FetchSchedule()
        #expect(schedule.interval == 600)
        #expect(schedule.decision(for: repo, .timer, now: at(0), active: true) == .fetch) // never fetched
        fetch(&schedule, at: 0)
        #expect(schedule.decision(for: repo, .timer, now: at(9.9), active: true) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(10), active: true) == .fetch)
        #expect(schedule.decision(for: repo, .timer, now: at(10), active: false) == .skip(.inactive))
        #expect(schedule.lastFetch(of: repo) == at(0))
        // Another repository has a schedule of its own.
        #expect(schedule.decision(for: "/other/.git", .timer, now: at(1), active: true) == .fetch)
    }

    @Test func theSettingDecides() {
        var schedule = FetchSchedule(frequency: .thirtyMinutes)
        fetch(&schedule, at: 0)
        #expect(schedule.decision(for: repo, .timer, now: at(29), active: true) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(30), active: true) == .fetch)
        schedule.frequency = .fiveMinutes
        #expect(schedule.interval == 300 && schedule.decision(for: repo, .timer, now: at(5), active: true) == .fetch)
        schedule.frequency = .onPopup
        #expect(schedule.decision(for: repo, .timer, now: at(60), active: true) == .skip(.off))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(60), active: true) == .fetch)
        schedule.frequency = .off
        #expect(schedule.decision(for: repo, .timer, now: at(60), active: true) == .skip(.off))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(60), active: true) == .skip(.off))
        #expect(FetchFrequency.standard == .tenMinutes)
        #expect(FetchFrequency.allCases.map(\.title) == ["Every 5 minutes", "Every 10 minutes", "Every 30 minutes",
                                                         "Only when opening the branch popup", "Off"])
    }

    @Test func thePopupFetchesWhenTheLastFetchIsOverFiveMinutesOld() {
        var schedule = FetchSchedule()
        #expect(schedule.decision(for: repo, .popupOpened, now: at(0), active: true) == .fetch)
        fetch(&schedule, at: 0)
        #expect(schedule.decision(for: repo, .popupOpened, now: at(5), active: true) == .skip(.recent))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(5.1), active: true) == .fetch)
        // A fetch in a terminal counts: FETCH_HEAD is newer.
        #expect(schedule.decision(for: repo, .popupOpened, now: at(8), active: true, fetchedOnDisk: at(6)) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(12), active: true, fetchedOnDisk: at(6)) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(16), active: true, fetchedOnDisk: at(6)) == .fetch)
    }

    @Test func skipsWhileAnotherFetchRuns() {
        var schedule = FetchSchedule()
        schedule.started(repo, at: at(0))
        #expect(schedule.isRunning(repo))
        #expect(schedule.decision(for: repo, .timer, now: at(20), active: true) == .skip(.running))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(20), active: true) == .skip(.running))
        schedule.finished(repo, at: at(1), .fetched)
        #expect(schedule.decision(for: repo, .timer, now: at(20), active: true, otherFetchRunning: true) == .skip(.running))
        #expect(schedule.decision(for: repo, .timer, now: at(20), active: true) == .fetch)
    }

    @Test func aFailedAttemptWaitsForTheNextInterval() {
        var schedule = FetchSchedule()
        fetch(&schedule, at: 0, .failed)
        #expect(schedule.lastFetch(of: repo) == nil)
        #expect(schedule.decision(for: repo, .timer, now: at(5), active: true) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(10), active: true) == .fetch)
        fetch(&schedule, at: 10, .nothingToFetch)
        #expect(schedule.decision(for: repo, .timer, now: at(15), active: true) == .skip(.recent))
        #expect(!schedule.isPausedForPerson(repo))
    }

    @Test func pausesAfterAnAuthenticationFailureUntilAFetchByHand() {
        var schedule = FetchSchedule()
        fetch(&schedule, at: 0, .needsPerson)
        #expect(schedule.isPausedForPerson(repo))
        #expect(schedule.decision(for: repo, .timer, now: at(60), active: true) == .skip(.needsPerson))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(60), active: true) == .skip(.needsPerson))
        // A fetch in a terminal that worked (a FETCH_HEAD with something in it, newer than the failure) resumes it.
        #expect(schedule.decision(for: repo, .timer, now: at(60), active: true, fetchedOnDisk: at(30)) == .fetch)
        #expect(schedule.decision(for: repo, .timer, now: at(60), active: true, fetchedOnDisk: at(-5)) == .skip(.needsPerson))
        // So does one started in Next Term.
        schedule.fetchedByHand(repo, at: at(61))
        #expect(!schedule.isPausedForPerson(repo) && schedule.lastFetch(of: repo) == at(61))
        #expect(schedule.decision(for: repo, .timer, now: at(65), active: true) == .skip(.recent))
        #expect(schedule.decision(for: repo, .timer, now: at(71), active: true) == .fetch)
        // A background fetch that works again ends the pause too.
        fetch(&schedule, at: 80, .needsPerson)
        fetch(&schedule, at: 81, .fetched)
        #expect(!schedule.isPausedForPerson(repo))
    }

    @Test func pausesInLowPowerModeAndOnCostlyNetworks() {
        var schedule = FetchSchedule()
        schedule.conditions.lowPowerMode = true
        #expect(schedule.decision(for: repo, .timer, now: at(0), active: true) == .skip(.lowPower))
        #expect(schedule.decision(for: repo, .popupOpened, now: at(0), active: true) == .skip(.lowPower))
        schedule.conditions = FetchSchedule.Conditions(expensiveNetwork: true)
        #expect(schedule.decision(for: repo, .timer, now: at(0), active: true) == .skip(.network))
        schedule.conditions = FetchSchedule.Conditions(constrainedNetwork: true)
        #expect(schedule.decision(for: repo, .popupOpened, now: at(0), active: true) == .skip(.network))
        schedule.conditions = FetchSchedule.Conditions(offline: true)
        #expect(schedule.decision(for: repo, .timer, now: at(0), active: true) == .skip(.network))
        schedule.conditions = FetchSchedule.Conditions()
        #expect(schedule.decision(for: repo, .timer, now: at(0), active: true) == .fetch)
    }

    @Test func theCommandLeavesFetchHeadAndSubmodulesAlone() {
        let options = ["fetch", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules"]
        #expect(FetchSchedule.arguments(remote: "origin", porcelain: true) == options + ["--porcelain", "origin"])
        #expect(FetchSchedule.arguments(remote: "origin", porcelain: false) == options + ["origin"])
    }

    /// `git fetch --porcelain` came with git 2.41; the Command Line Tools of macOS 13 and 14 have 2.39.
    @Test func porcelainOnlyWithGit241OrLater() {
        #expect(GitRunner.version("git version 2.39.5 (Apple Git-154)\n") == [2, 39, 5])
        #expect(GitRunner.version("git version 2.50.1 (Apple Git-155)") == [2, 50, 1])
        #expect(GitRunner.version("git version 2.41.0.windows.1") == [2, 41, 0])
        #expect(GitRunner.version("git version 2.42.0-rc1") == [2, 42])
        #expect(GitRunner.version("usage: git [-v | --version]") == nil)
        #expect(GitRunner.version("") == nil)
        #expect(!FetchSchedule.hasPorcelainFetch([2, 39, 5]) && !FetchSchedule.hasPorcelainFetch([2, 40, 9]))
        #expect(FetchSchedule.hasPorcelainFetch([2, 41, 0]) && FetchSchedule.hasPorcelainFetch([2, 41]))
        #expect(FetchSchedule.hasPorcelainFetch([2, 50, 1]) && FetchSchedule.hasPorcelainFetch([3]))
        #expect(!FetchSchedule.hasPorcelainFetch(nil)) // not known: the form every git takes
        // What 2.39 says to --porcelain. Nothing in it reads as a password prompt, so it would only ever fail.
        let refused = "error: unknown option `porcelain'\nusage: git fetch [<options>] [<repository> [<refspec>...]]"
        #expect(FetchSchedule.outcome(status: 129, output: refused) == .failed)
    }

    @Test func checksTheScheduleATenthOfTheIntervalApart() {
        var schedule = FetchSchedule()
        #expect(schedule.checkEvery == 60)
        schedule.interval = 1
        #expect(schedule.checkEvery == 0.5)
        schedule.frequency = .off
        #expect(schedule.checkEvery == nil)
    }

    /// A clone of a local bare remote that gets a new commit: the fetch brings it in, and FETCH_HEAD never appears.
    @Test func aRealFetchFromALocalRemote() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-bgfetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = base.appendingPathComponent("remote.git").path
        let work = base.appendingPathComponent("work").path
        @discardableResult func sh(_ args: [String], in dir: String) -> String {
            let config = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"]
            let out = GitRunner.run(git, ["-C", dir] + config + args, timeout: 20)
            #expect(out != nil, "git \(args.joined(separator: " "))")
            return out.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        sh(["init", "-q", "--bare", remote], in: base.path)
        sh(["init", "-q"], in: work)
        sh(["commit", "-q", "--allow-empty", "-m", "one"], in: work)
        sh(["remote", "add", "origin", remote], in: work)
        sh(["push", "-q", "-u", "origin", "main"], in: work)
        sh(["branch", "local-only"], in: work)
        #expect(FetchSchedule.trackedRemotes(at: work, git: git) == ["origin"])
        // Someone else's commit lands on the remote.
        func theirs(_ message: String) -> String {
            let commit = sh(["commit-tree", "main^{tree}", "-p", "main", "-m", message], in: remote)
            sh(["update-ref", "refs/heads/main", commit], in: remote)
            return commit
        }
        // The form every git takes brings it in.
        let first = theirs("theirs")
        sh(FetchSchedule.arguments(remote: "origin", porcelain: false), in: work)
        #expect(sh(["rev-parse", "origin/main"], in: work) == first)
        var behind = 1
        // With git 2.41 or later, --porcelain too: a line for each ref.
        if FetchSchedule.hasPorcelainFetch(GitRunner.version(git: git)) {
            let second = theirs("theirs again")
            let output = sh(FetchSchedule.arguments(remote: "origin", porcelain: true), in: work)
            #expect(output.hasSuffix("refs/remotes/origin/main") && output.contains(second), "\(output)")
            #expect(sh(["rev-parse", "origin/main"], in: work) == second)
            behind = 2
        }
        #expect(!FileManager.default.fileExists(atPath: work + "/.git/FETCH_HEAD"))
        #expect(GitRunner.snapshot(for: work, git: git)?.behind == behind)
    }

    /// A submodule's remote is another server: the background fetch leaves it alone, in both forms, where
    /// a plain `git fetch` would fetch it as well.
    @Test func submodulesAreNotFetched() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-bgfetch-sub-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        @discardableResult func sh(_ args: [String], in dir: String) -> String {
            let config = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
                          "-c", "protocol.file.allow=always"]
            let out = GitRunner.run(git, ["-C", dir] + config + args, timeout: 20)
            #expect(out != nil, "git \(args.joined(separator: " "))")
            return out.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        for folder in ["lib", "app"] { try FileManager.default.createDirectory(atPath: "\(base)/\(folder)", withIntermediateDirectories: true) }
        sh(["init", "-q", "--bare", "lib.git"], in: base)
        sh(["init", "-q", "--bare", "app.git"], in: base)
        sh(["init", "-q"], in: "\(base)/lib")
        sh(["commit", "-q", "--allow-empty", "-m", "lib one"], in: "\(base)/lib")
        sh(["push", "-q", "\(base)/lib.git", "main"], in: "\(base)/lib")
        sh(["init", "-q"], in: "\(base)/app")
        sh(["submodule", "-q", "add", "\(base)/lib.git", "lib"], in: "\(base)/app")
        sh(["commit", "-q", "-m", "app one"], in: "\(base)/app")
        sh(["push", "-q", "\(base)/app.git", "main"], in: "\(base)/app")
        sh(["clone", "-q", "--recurse-submodules", "\(base)/app.git", "clone"], in: base)
        let clone = "\(base)/clone", sub = "\(base)/clone/lib"
        // The library moves on, and the app's remote points at its new commit.
        sh(["commit", "-q", "--allow-empty", "-m", "lib two"], in: "\(base)/lib")
        sh(["push", "-q", "\(base)/lib.git", "main"], in: "\(base)/lib")
        sh(["-C", "lib", "pull", "-q", "\(base)/lib.git", "main"], in: "\(base)/app")
        sh(["commit", "-q", "-am", "app two"], in: "\(base)/app")
        sh(["push", "-q", "\(base)/app.git", "main"], in: "\(base)/app")
        let before = sh(["rev-parse", "origin/main"], in: sub), appBefore = sh(["rev-parse", "origin/main"], in: clone)
        var forms = [false]
        if FetchSchedule.hasPorcelainFetch(GitRunner.version(git: git)) { forms.append(true) }
        for porcelain in forms {
            sh(["update-ref", "refs/remotes/origin/main", appBefore], in: clone)
            sh(FetchSchedule.arguments(remote: "origin", porcelain: porcelain), in: clone)
            #expect(sh(["rev-parse", "origin/main"], in: clone) != appBefore, "the app's own remote is fetched")
            #expect(sh(["rev-parse", "origin/main"], in: sub) == before, "porcelain \(porcelain): the submodule is left alone")
        }
        // A plain fetch of the same change would have fetched the submodule too.
        sh(["update-ref", "refs/remotes/origin/main", appBefore], in: clone)
        sh(["fetch", "-q", "origin"], in: clone)
        #expect(sh(["rev-parse", "origin/main"], in: sub) != before, "a plain git fetch reaches the submodule's remote")
    }

    /// After git needed a person, a fetch in a terminal ends the pause only if it worked, in any work tree
    /// of the repository: a failed one still writes FETCH_HEAD (empty), and a linked worktree's is its own.
    @Test func onlyAFetchThatWorksInATerminalEndsThePause() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-bgfetch-pause-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = base + "/main", linked = base + "/linked"
        @discardableResult func sh(_ args: [String], in dir: String) -> Bool {
            let config = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"]
            return GitRunner.run(git, ["-C", dir] + config + args, timeout: 20) != nil
        }
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        #expect(sh(["init", "-q", "--bare", base + "/remote.git"], in: base))
        #expect(sh(["init", "-q"], in: main))
        #expect(sh(["commit", "-q", "--allow-empty", "-m", "one"], in: main))
        #expect(sh(["remote", "add", "origin", base + "/remote.git"], in: main))
        #expect(sh(["push", "-q", "-u", "origin", "main"], in: main))
        #expect(sh(["worktree", "add", "-q", "-b", "side", linked], in: main))

        var schedule = FetchSchedule()
        let paused = Date().addingTimeInterval(-1)
        schedule.started(repo, at: paused)
        schedule.finished(repo, at: paused, .needsPerson)
        func decision() -> FetchSchedule.Decision {
            schedule.decision(for: repo, .timer, now: Date().addingTimeInterval(3600), active: true,
                              fetchedOnDisk: GitRunner.lastSuccessfulFetch(root: main))
        }
        #expect(decision() == .skip(.needsPerson))
        // A fetch in a tab that fails: git writes FETCH_HEAD all the same, empty.
        #expect(sh(["remote", "add", "gone", base + "/nowhere.git"], in: main))
        #expect(!sh(["fetch", "gone"], in: main))
        #expect(FileManager.default.fileExists(atPath: main + "/.git/FETCH_HEAD"))
        #expect(decision() == .skip(.needsPerson))
        // One that works, in the linked worktree, which has a FETCH_HEAD of its own.
        #expect(sh(["fetch", "-q", "origin"], in: linked))
        #expect(FileManager.default.fileExists(atPath: main + "/.git/worktrees/linked/FETCH_HEAD"))
        #expect(decision() == .fetch)
        #expect(GitRunner.lastSuccessfulFetch(root: linked) != nil)
        #expect(GitRunner.lastSuccessfulFetch(root: linked) == GitRunner.lastSuccessfulFetch(root: main))
    }

    @Test func theRemotesLocalBranchesTrack() {
        let output = "origin\n\nupstream\norigin\n.\n--upload-pack=x\nhttps://example.com/r.git\nfork\n"
        #expect(FetchSchedule.trackedRemotes(output) == ["origin", "upstream", "fork"])
        #expect(FetchSchedule.trackedRemotes("\n\n").isEmpty)
    }

    @Test func outcomesFromGitsWords() {
        #expect(FetchSchedule.outcome(status: 0, output: " abc123 def456 refs/remotes/origin/main") == .fetched)
        #expect(FetchSchedule.outcome(status: 128, output: "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == .needsPerson)
        let https = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
        #expect(FetchSchedule.outcome(status: 128, output: https) == .needsPerson)
        #expect(FetchSchedule.outcome(status: 128, output: "Host key verification failed.\nfatal: Could not read from remote repository.") == .needsPerson)
        #expect(FetchSchedule.outcome(status: 128, output: "ssh: Could not resolve host: github.com") == .failed)
        #expect(FetchSchedule.outcome(status: 124, output: "Stopped after 3 minutes.") == .failed)
    }

    @Test func fetchesTypedInATab() {
        for line in ["git fetch", "git pull --rebase", "git -C app pull", "cd app && git fetch --all", "git -c http.proxy=x fetch origin",
                     "git remote update", "GIT_TRACE=1 git pull", "time git fetch"] {
            #expect(FetchSchedule.isFetchCommand(line), "\(line)")
        }
        for line in ["git status", "git push", "git log --grep fetch", "git remote -v", "echo git fetch", "gitk", "git-lfs fetch"] {
            #expect(!FetchSchedule.isFetchCommand(line), "\(line)")
        }
    }
}
