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
        // A fetch in a terminal that succeeded (FETCH_HEAD is newer than the failure) resumes it.
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

    @Test func theCommandLeavesFetchHeadAlone() {
        #expect(FetchSchedule.arguments(remote: "origin") == ["fetch", "--no-write-fetch-head", "--no-auto-maintenance", "--porcelain", "origin"])
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
        let theirs = sh(["commit-tree", "main^{tree}", "-p", "main", "-m", "theirs"], in: remote)
        sh(["update-ref", "refs/heads/main", theirs], in: remote)
        let output = sh(FetchSchedule.arguments(remote: "origin"), in: work)
        #expect(output.hasSuffix("refs/remotes/origin/main") && output.contains(theirs), "\(output)")
        #expect(sh(["rev-parse", "origin/main"], in: work) == theirs)
        #expect(!FileManager.default.fileExists(atPath: work + "/.git/FETCH_HEAD"))
        #expect(GitRunner.snapshot(for: work, git: git)?.behind == 1)
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
