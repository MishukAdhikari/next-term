import Foundation
import Testing
@testable import NextTermCore

private func wrapperBinding(_ change: (inout SecretBinding) -> Void = { _ in }) -> SecretBinding {
    var binding = SecretBinding(
        source: .wrapper, asker: "wrapper:/usr/local/bin/codex:ab12", program: "codex", agentPath: "/usr/local/bin/codex",
        agentIdentity: SecretFileIdentity(device: 1, inode: 10, size: 100, modified: 1_000), agentScript: nil,
        executable: "/usr/local/bin/npx", executableIdentity: SecretFileIdentity(device: 1, inode: 20, size: 200, modified: 2_000),
        command: ["npx", "-y", "@modelcontextprotocol/server-github@1.2.3"], keys: ["GITHUB_TOKEN": "GITHUB_TOKEN"],
        folder: "/Users/me/api", warned: ["NODE_OPTIONS": "d1"], envDigest: "none")
    change(&binding)
    return binding
}

private func toolBinding(tab: String = "tab-2", target: String = "new") -> SecretBinding {
    SecretBinding(source: .tool, asker: tab, program: "claude", command: ["npm test"], keys: ["OPENAI_API_KEY": "OPENAI_API_KEY"],
                  folder: "/Users/me/api", target: target, envDigest: "none")
}

@Suite struct SecretGrantTests {
    let start = ContinuousClock.now

    @Test func aGrantMatchesOnlyTheIdenticalRequest() {
        let grant = SecretGrant(kind: .fifteenMinutes, binding: wrapperBinding(), made: start)
        #expect(grant.matches(wrapperBinding(), at: start))
        let different: [(String, SecretBinding)] = [
            ("command", wrapperBinding { $0.command = ["npx", "-y", "@modelcontextprotocol/server-github@1.2.4"] }),
            ("folder", wrapperBinding { $0.folder = "/Users/me/web" }),
            ("key", wrapperBinding { $0.keys = ["GITHUB_PAT": "GITHUB_TOKEN"] }),
            ("ENVNAME", wrapperBinding { $0.keys = ["GITHUB_TOKEN": "GH_TOKEN"] }),
            ("agent path", wrapperBinding { $0.agentPath = "/opt/codex" }),
            ("agent file", wrapperBinding { $0.agentIdentity = SecretFileIdentity(device: 1, inode: 10, size: 101, modified: 1_000) }),
            ("agent script", wrapperBinding { $0.agentScript = "/tmp/other.js" }),
            ("executable file", wrapperBinding { $0.executableIdentity = SecretFileIdentity(device: 1, inode: 21, size: 200, modified: 2_000) }),
            ("warned digest", wrapperBinding { $0.warned = ["NODE_OPTIONS": "d2"] }),
            (".env digest", wrapperBinding { $0.envDigest = "e3b0" }),
            ("asker", wrapperBinding { $0.asker = "wrapper:/opt/claude:cd34" }),
        ]
        for (label, binding) in different {
            #expect(!grant.matches(binding, at: start), "\(label)")
        }
    }

    @Test func expiryOnAnInjectedClock() {
        let grant = SecretGrant(kind: .fifteenMinutes, binding: wrapperBinding(), made: start)
        #expect(grant.matches(wrapperBinding(), at: start.advanced(by: .seconds(899))))
        #expect(!grant.matches(wrapperBinding(), at: start.advanced(by: .seconds(901))))
        let untilLock = SecretGrant(kind: .untilLock, binding: wrapperBinding(), made: start)
        #expect(untilLock.matches(wrapperBinding(), at: start.advanced(by: .seconds(86_400))))
        // Q1's one use, for 2 minutes.
        var book = SecretGrantBook()
        book.add(SecretGrant(kind: .oneUse, binding: wrapperBinding(), made: start))
        #expect(book.take(wrapperBinding(), at: start.advanced(by: .seconds(30))) != nil)
        #expect(book.take(wrapperBinding(), at: start.advanced(by: .seconds(31))) == nil)
        var late = SecretGrantBook()
        late.add(SecretGrant(kind: .oneUse, binding: wrapperBinding(), made: start))
        #expect(late.take(wrapperBinding(), at: start.advanced(by: .seconds(121))) == nil)
        #expect(late.expire(at: start.advanced(by: .seconds(121))).count == 1 && late.grants.isEmpty)
    }

    @Test func whatEndsAGrant() {
        func book() -> SecretGrantBook {
            var book = SecretGrantBook()
            book.add(SecretGrant(kind: .fifteenMinutes, binding: wrapperBinding(), made: start, id: "wrapper"))
            book.add(SecretGrant(kind: .untilLock, binding: wrapperBinding { $0.folder = "/x" }, made: start, id: "lock"))
            book.add(SecretGrant(kind: .fifteenMinutes, binding: toolBinding(tab: "tab-3"), made: start, id: "tool-3"))
            book.add(SecretGrant(kind: .fifteenMinutes, binding: toolBinding(tab: "tab-4", target: "tab-3"), made: start, id: "tool-4"))
            return book
        }
        for event in [SecretGrantEvent.screenLocked, .systemSleep, .sessionResigned, .quit, .revokeAll, .hourPause] {
            var all = book()
            #expect(all.end(event).count == 4 && all.grants.isEmpty, "\(event)")
        }
        var sleeping = book()
        #expect(sleeping.end(.displaySleep).isEmpty && sleeping.grants.count == 4)
        var revoked = book()
        #expect(revoked.end(.revoke("lock")).map(\.id) == ["lock"])
        var replaced = book()
        #expect(replaced.end(.keyChanged("GITHUB_TOKEN")).map(\.id).sorted() == ["lock", "wrapper"])
        #expect(replaced.end(.keyChanged("STRIPE_KEY")).isEmpty)
        var typed = book()
        #expect(typed.end(.tabGotInput("tab-3")).map(\.id) == ["tool-3"])
        #expect(typed.end(.tabGotInput("wrapper")).isEmpty)
    }
}

@Suite struct SecretLimitsTests {
    let start = ContinuousClock.now

    @Test func theQueueHoldsFive() {
        #expect(!SecretLimits.isBusy(waiting: 4))
        #expect(SecretLimits.isBusy(waiting: 5)) // the sixth waiting request
    }

    @Test func aDeclinePausesThatRequestOnly() {
        var limits = SecretLimits()
        let declined = toolBinding()
        let other = SecretBinding(source: .tool, asker: "tab-2", program: "claude", command: ["npm run e2e"],
                                  keys: ["OPENAI_API_KEY": "OPENAI_API_KEY"], folder: "/Users/me/api", target: "new")
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        limits.record(.declined, asker: "tab-2", binding: declined, at: start, date: at)
        #expect(limits.admit(asker: "tab-2", binding: declined, at: start.advanced(by: .seconds(599)))
                == .paused(declinedAt: at, until: at.addingTimeInterval(600)))
        #expect(limits.admit(asker: "tab-2", binding: other, at: start.advanced(by: .seconds(1))) == nil)
        #expect(limits.admit(asker: "tab-2", binding: declined, at: start.advanced(by: .seconds(601))) == nil)
        limits.resume(declined)
        #expect(limits.admit(asker: "tab-2", binding: declined, at: start) == nil)
    }

    /// run_with_secrets checks the limits before it opens a tab, when the tab's warned variables are not known yet: a
    /// declined request is paused whatever its tab warned about, and a different command still asks.
    @Test func aPauseHoldsBeforeTheTabExists() {
        var limits = SecretLimits()
        var declined = toolBinding()
        declined.warned = ["NODE_OPTIONS": "d1"]
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        limits.record(.declined, asker: "tab-2", binding: declined, at: start, date: at)
        #expect(limits.admitBeforeTab(asker: "tab-2", binding: toolBinding(), at: start.advanced(by: .seconds(10)))
                == .paused(declinedAt: at, until: at.addingTimeInterval(600)))
        #expect(limits.admit(asker: "tab-2", binding: toolBinding(), at: start.advanced(by: .seconds(10))) == nil)
        var other = toolBinding()
        other.command = ["npm run e2e"]
        #expect(limits.admitBeforeTab(asker: "tab-2", binding: other, at: start.advanced(by: .seconds(10))) == nil)
        #expect(limits.admitBeforeTab(asker: "tab-2", binding: toolBinding(), at: start.advanced(by: .seconds(601))) == nil)
        limits.stop("tab-3")
        #expect(limits.admitBeforeTab(asker: "tab-3", binding: other, at: start) == .stopped)
        limits.pauseForAnHour(at: start, date: at)
        #expect(limits.admitBeforeTab(asker: "tab-4", binding: other, at: start) == .declining(until: at.addingTimeInterval(3600)))
    }

    @Test func countsPerAskerAndOverall() {
        var limits = SecretLimits()
        for index in 0..<10 {
            #expect(limits.admit(asker: "a", binding: wrapperBinding { $0.folder = "/\(index)" }, at: start) == nil)
            limits.record(index.isMultiple(of: 2) ? .declined : .unanswered, asker: "a", binding: wrapperBinding { $0.folder = "/\(index)" },
                          at: start)
        }
        // The eleventh from that asker is refused, whatever it asks; another asker still asks.
        #expect(limits.admit(asker: "a", binding: wrapperBinding { $0.folder = "/new" }, at: start) == .limited)
        #expect(limits.admit(asker: "b", binding: wrapperBinding { $0.folder = "/new" }, at: start) == nil)
        for asker in ["b", "c"] {
            for index in 0..<10 { limits.record(.unanswered, asker: asker, binding: wrapperBinding { $0.folder = "/\(asker)\(index)" }, at: start) }
        }
        // Thirty across askers: the thirty-first is refused, from an asker that never asked.
        #expect(limits.total == 30)
        #expect(limits.admit(asker: "d", binding: wrapperBinding { $0.folder = "/d" }, at: start) == .limited)
        #expect(limits.limitedAskers == ["a", "b", "c"])
        limits.resume(asker: "a")
        #expect(limits.admit(asker: "a", binding: wrapperBinding { $0.folder = "/new" }, at: start) == nil)
    }

    @Test func onlyDeclinedAndUnansweredCount() {
        var limits = SecretLimits()
        for outcome in [SecretLimits.Outcome.allowed, .answeredByGrant, .tookOver, .refusedByLimits] {
            limits.record(outcome, asker: "a", binding: wrapperBinding(), at: start)
        }
        #expect(limits.total == 0 && limits.counts.isEmpty && limits.pauses.isEmpty)
        // A pending card dropped after 30 minutes, and a ticket not redeemed in time: one each.
        limits.record(.unanswered, asker: "a", binding: wrapperBinding(), at: start)
        limits.record(.unanswered, asker: "tab-2", binding: toolBinding(), at: start)
        #expect(limits.total == 2 && limits.counts["a"] == 1 && limits.counts["tab-2"] == 1)
        #expect(limits.admit(asker: "a", binding: wrapperBinding(), at: start) == nil) // unanswered pauses nothing
    }

    @Test func stopAndTheHourPause() {
        var limits = SecretLimits()
        limits.stop("tab-2")
        #expect(limits.admit(asker: "tab-2", binding: toolBinding(), at: start) == .stopped)
        #expect(limits.admit(asker: "tab-3", binding: toolBinding(tab: "tab-3"), at: start) == nil)
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        limits.pauseForAnHour(at: start, date: at)
        #expect(limits.admit(asker: "tab-3", binding: toolBinding(tab: "tab-3"), at: start.advanced(by: .seconds(3599)))
                == .declining(until: at.addingTimeInterval(3600)))
        #expect(limits.admit(asker: "tab-3", binding: toolBinding(tab: "tab-3"), at: start.advanced(by: .seconds(3601))) == nil)
        limits.pauseForAnHour(at: start, date: at)
        limits.resumeAsking()
        limits.resume(asker: "tab-2")
        #expect(limits.admit(asker: "tab-2", binding: toolBinding(), at: start) == nil)
    }
}
