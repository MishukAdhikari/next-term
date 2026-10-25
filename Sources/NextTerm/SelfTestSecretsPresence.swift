import AppKit
import LocalAuthentication

#if DEBUG
/// A context that never shows a sheet: its evaluation waits for `answer(_:)`, and `invalidate()` ends it as
/// LocalAuthentication's does, with `appCancel`, unless `endsOnInvalidate` is off (an approval already on its way).
final class HeldContext: LAContext, @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool, (any Error)?) -> Void)?
    private var invalidations = 0
    private var ends = true

    var endsOnInvalidate: Bool {
        get { locked { ends } }
        set { locked { ends = newValue } }
    }
    var isAsking: Bool { locked { reply != nil } }
    var wasInvalidated: Bool { locked { invalidations > 0 } }

    override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, (any Error)?) -> Void) {
        locked { self.reply = reply }
    }

    override func evaluateAccessControl(_ accessControl: SecAccessControl, operation: LAAccessControlOperation, localizedReason: String,
                                        reply: @escaping (Bool, (any Error)?) -> Void) {
        locked { self.reply = reply }
    }

    override func invalidate() {
        super.invalidate()
        let endsNow = locked { () -> Bool in
            invalidations += 1
            return ends
        }
        if endsNow { answer(LAError(.appCancel)) }
    }

    /// Ends the evaluation: approved with nil, else refused with `error`.
    func answer(_ error: (any Error)?) {
        let done = locked { () -> ((Bool, (any Error)?) -> Void)? in
            defer { reply = nil }
            return reply
        }
        done?(error == nil, error)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// One presence check run to its end: approved, or how it failed.
@MainActor
final class PresenceOutcome {
    private(set) var done = false
    private(set) var approved = false
    private(set) var failure: UserPresence.Failure?

    func run(_ presence: UserPresence) async {
        do {
            let token = try await presence.confirm(reason: "show SELFTEST_KEY", accessControl: nil)
            presence.finish(token)
            approved = true
        } catch {
            failure = error as? UserPresence.Failure
        }
        done = true
    }
}

/// `UserPresence` itself, with stand-in contexts so no sheet shows: a caller that gives up closes its sheet (the context
/// is invalidated) and gets `cancelled`, an approval that races the cancel counts as cancelled, and a check cancelled
/// while it waited its turn asks nothing and passes the turn on.
extension SelfTest {
    static func secretsPresenceCancelChecks() async {
        let presence = UserPresence()
        var made: [HeldContext] = []
        presence.standInContext = {
            let context = HeldContext()
            made.append(context)
            return context
        }
        defer {
            for context in made { context.answer(LAError(.userCancel)) } // none left waiting, whatever failed
        }

        // The caller gives up while the sheet is up: the sheet closes, and the check is cancelled.
        let gaveUp = PresenceOutcome()
        let first = Task { await gaveUp.run(presence) }
        let asking = await wait(5) { made.count == 1 && made[0].isAsking }
        first.cancel()
        let ended = await wait(5) { gaveUp.done }
        check(asking && ended && made.first?.wasInvalidated == true && gaveUp.failure == .cancelled,
              "secrets: a Touch ID check whose caller gives up closes its sheet and is cancelled",
              "asking \(asking), ended \(ended), invalidated \(made.first?.wasInvalidated == true)")

        // Approved just as the caller gave up: cancelled, so the approval reveals nothing.
        let raced = PresenceOutcome()
        let second = Task { await raced.run(presence) }
        let askingRace = await wait(5) { made.count == 2 && made[1].isAsking }
        made.last?.endsOnInvalidate = false
        second.cancel()
        made.last?.answer(nil)
        let endedRace = await wait(5) { raced.done }
        check(askingRace && endedRace && !raced.approved && raced.failure == .cancelled,
              "secrets: a Touch ID approved as its caller gave up counts as cancelled",
              "asking \(askingRace), ended \(endedRace), approved \(raced.approved)")

        // Cancelled while it waited its turn: it asks nothing, and the turn passes on.
        let holder = PresenceOutcome()
        let waiter = PresenceOutcome()
        let next = PresenceOutcome()
        _ = Task { await holder.run(presence) }
        let up = await wait(5) { made.count == 3 && made[2].isAsking }
        let queued = Task { await waiter.run(presence) }
        await pause(0.2)
        queued.cancel()
        made.last?.answer(nil)
        let both = await wait(5) { holder.done && waiter.done }
        _ = Task { await next.run(presence) }
        let nextUp = await wait(5) { made.count == 4 && made[3].isAsking }
        made.last?.answer(nil)
        let nextDone = await wait(5) { next.done }
        check(up && both && holder.approved && waiter.failure == .cancelled && nextUp && nextDone && next.approved,
              "secrets: a Touch ID check cancelled while it waited its turn asks nothing, and the turn passes on",
              "\(made.count) sheets, waiter \(String(describing: waiter.failure)), next \(nextUp)")
    }
}
#endif
