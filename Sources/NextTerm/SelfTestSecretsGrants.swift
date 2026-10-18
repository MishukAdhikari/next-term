import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// One "Allow once" starts one command, however many identical requests took its panel over (review finding 4).
    static func secretsAllowOnceChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        let value = secretsValue("once")
        _ = try? await store.perform(.add(name: "PANEL_KEY", purpose: "the Allow once checks", purposeBy: .agent, origin: .settings,
                                          writeOnly: true, value: SecretBytes(utf8: value), asksEveryUse: false))

        // Two run_with_secrets calls with the same command and folder get the same binding (a new tab each): the second
        // takes the first's panel over. One Allow once starts one of them; the other is told it was used already.
        let firstAnswers = SecretsAnswers()
        let secondAnswers = SecretsAnswers()
        let first = secretsRequest(asker: "selftest-tab-twice", command: ["./deploy.sh"], source: .tool, agent: "Claude Code")
        let second = secretsRequest(asker: "selftest-tab-twice", command: ["./deploy.sh"], source: .tool, agent: "Claude Code")
        requests.ask(first) { firstAnswers.take($0) }
        let secondWaits = requests.ask(second) { secondAnswers.take($0) }
        let tookOver = secondWaits?.request === first && second.panel == nil
        let onceChosen = first.panel?.durationChoice[.once]?.state == .on
        first.panel?.allowButton.performClick(nil)
        _ = await wait(10) { !firstAnswers.all.isEmpty && !secondAnswers.all.isEmpty }
        let started = [firstAnswers.last, secondAnswers.last].filter { secretsAllowed($0) != nil }.count
        let usedAlready = { if case .usedAlready? = secondAnswers.last { return true }; return false }()
        check(tookOver && onceChosen && started == 1 && secretsAllowed(firstAnswers.last)?.how == .once && usedAlready,
              "secrets: one Allow once starts one command when an identical run_with_secrets call took its panel over",
              "took over \(tookOver), once \(onceChosen), started \(started), \(firstAnswers.all.count)/\(secondAnswers.all.count) answers")
        let toolAnswer = SecretsMCP.answer(for: .usedAlready, tool: "run_with_secrets")
        check(toolAnswer["status"] as? String == "refused", "secrets: the call whose Allow once was used already hears nothing ran",
              secretsJSON(toolAnswer))
        await secretsLeftCallerChecks()
        await secretsGrantEndChecks(store)
        await secretsOtherCopyGrantChecks()
        _ = try? await store.perform(.delete(name: "PANEL_KEY"))
    }

    /// A wrapper that left in the moment before "Allow once", its leaving not yet passed on by the socket's poll, does
    /// not take the one use: the identical wrapper still waiting gets the keys, and with none waiting, the one-use grant
    /// is made, as when it leaves during Touch ID.
    static func secretsLeftCallerChecks() async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let leftAnswers = SecretsAnswers()
        let waitingAnswers = SecretsAnswers()
        let gone = secretsRequest(asker: "wrapper:selftest-left", command: ["node", "left.js"], tab: "tab 3")
        let waiting = secretsRequest(asker: "wrapper:selftest-left", command: ["node", "left.js"], tab: "tab 3")
        requests.ask(gone, left: { true }) { leftAnswers.take($0) }
        let tookOver = requests.ask(waiting) { waitingAnswers.take($0) }?.request === gone
        gone.panel?.durationChoice[.once]?.performClick(nil)
        gone.panel?.allowButton.performClick(nil)
        _ = await wait(10) { !waitingAnswers.all.isEmpty }
        check(tookOver && secretsAllowed(waitingAnswers.last)?.how == .once && leftAnswers.all.isEmpty && requests.book.grants.isEmpty,
              "secrets: Allow once passes over a wrapper that left the moment before, to the identical one still waiting",
              "took over \(tookOver), \(leftAnswers.all.count)/\(waitingAnswers.all.count) answers, \(requests.book.grants.count) grants")

        let lone = secretsRequest(asker: "wrapper:selftest-lone", command: ["node", "lone.js"], tab: "tab 3")
        let loneAnswers = SecretsAnswers()
        requests.ask(lone, left: { true }) { loneAnswers.take($0) }
        let lonePanel = lone.panel
        lonePanel?.durationChoice[.once]?.performClick(nil)
        lonePanel?.allowButton.performClick(nil)
        let oneUse = await wait(10) { requests.book.grants.contains { $0.kind == .oneUse && $0.binding == lone.binding } }
        let lingers = lonePanel?.window.map { $0.isVisible && texts($0.contentView).contains(SecretApprovalPanel.stoppedDuringApprovalText) }
        check(oneUse && lingers == true && loneAnswers.all.isEmpty,
              "secrets: a lone wrapper that left the moment before Allow once gets the one-use approval, and its panel says so",
              "one use \(oneUse), lingers \(String(describing: lingers)), \(loneAnswers.all.count) answers")
        lonePanel?.close()
        requests.resetForSelfTest()
    }

    /// Two identical `nxtrm secret run` wrappers on one panel, the second having taken it over: "Allow once" starts one,
    /// and the other ends with its own line and exit 1; "Allow for 15 minutes" starts both; and when the first left
    /// before Allow, the one still waiting runs. Each run adds its word to `runs` in `out`.
    static func secretsWrapperTwinsChecks(_ out: URL) async {
        let requests = SecretRequests.shared
        func ran(_ word: String) -> Int {
            let text = (try? String(contentsOf: out.appendingPathComponent("runs"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").filter { $0 == word }.count
        }
        func twins(_ word: String) -> (SecretsWrapperRun, SecretsWrapperRun) {
            let arguments = ["WRAP_KEY=K", "--", "/bin/sh", "-c", "echo \(word) >> runs"]
            return (SecretsWrapperRun(arguments, directory: out), SecretsWrapperRun(arguments, directory: out))
        }
        // The first's panel up, then the second on it.
        func onOnePanel(_ first: SecretsWrapperRun, _ second: SecretsWrapperRun) async -> SecretRequests.Request? {
            guard first.start(), await wait(15, { requests.showing?.panel != nil }), let request = requests.showing else { return nil }
            guard second.start(), await wait(15, { request.callers == 2 }) else { return nil }
            return request
        }

        let (first, second) = twins("once")
        let once = await onOnePanel(first, second)
        once?.panel?.durationChoice[.once]?.performClick(nil)
        once?.panel?.allowButton.performClick(nil)
        let firstExit = await first.finish()
        let secondExit = await second.finish()
        let usedLine = "nxtrm: an identical command used this Allow once, so no key was given. Restart this command to ask again."
        check(once != nil && firstExit == 0 && secondExit == 1 && second.errorText == usedLine && ran("once") == 1,
              "secrets: one Allow once starts one of two identical wrappers, and the other says an identical command used it",
              "exits \(String(describing: firstExit)) and \(String(describing: secondExit)), ran \(ran("once")), \(second.errorText)")

        let (third, fourth) = twins("lasting")
        let lasting = await onOnePanel(third, fourth)
        lasting?.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        lasting?.panel?.allowButton.performClick(nil)
        let thirdExit = await third.finish()
        let fourthExit = await fourth.finish()
        check(lasting != nil && thirdExit == 0 && fourthExit == 0 && ran("lasting") == 2,
              "secrets: Allow for 15 minutes starts both identical wrappers waiting on its panel",
              "exits \(String(describing: thirdExit)) and \(String(describing: fourthExit)), ran \(ran("lasting"))")
        requests.revokeAll()

        let (gone, staying) = twins("left")
        let left = await onOnePanel(gone, staying)
        if left != nil { kill(gone.process.processIdentifier, SIGKILL) }
        let heard = await wait(10) { left?.callers == 1 }
        left?.panel?.durationChoice[.once]?.performClick(nil)
        left?.panel?.allowButton.performClick(nil)
        _ = await gone.finish()
        let stayingExit = await staying.finish()
        let oneUse = requests.book.grants.contains { $0.kind == .oneUse }
        check(left != nil && heard && stayingExit == 0 && ran("left") == 1 && !oneUse,
              "secrets: when the first of two identical wrappers left before Allow once, the one still waiting runs",
              "heard \(heard), exit \(String(describing: stayingExit)), ran \(ran("left")), one-use grant \(oneUse)")
        requests.resetForSelfTest()
    }

    /// Two run_with_secrets calls with the same command and folder, each through its own tab, ticket, redeem and
    /// wrapper: the second takes the first's panel over, and one "Allow once" starts the command in one tab only. The
    /// other call answers refused, saying an identical call used it, and its tab shows the wrapper's line.
    static func secretsRunTwiceChecks(arguments: [String: Any], value: String, opened: inout [TerminalTab]) async {
        let requests = SecretRequests.shared
        let app = AppDelegate.shared!
        let before = Set(app.controllers.flatMap(\.tabs).map(\.id))
        func screen(_ tab: TerminalTab) -> String { tab.screenTail().joined(separator: "\n") }
        let length = String(value.utf8.count)
        func ran(_ tab: TerminalTab) -> Bool { screen(tab).contains("\(length)LEN") || screen(tab).contains("\(length)\nLEN") }
        let first = secretsStart("run_with_secrets", arguments)
        let second = secretsStart("run_with_secrets", arguments)
        let onOnePanel = await wait(20) { requests.queue.count == 1 && requests.showing?.callers == 2 }
        requests.showing?.panel?.durationChoice[.once]?.performClick(nil)
        requests.showing?.panel?.allowButton.performClick(nil)
        let firstAnswer = await first.value
        let secondAnswer = await second.value
        let tabs = app.controllers.flatMap(\.tabs).filter { !before.contains($0.id) }
        opened += tabs
        let statuses = [firstAnswer, secondAnswer].map { $0["status"] as? String ?? "" }.sorted()
        let note = [firstAnswer, secondAnswer].first { $0["status"] as? String == "refused" }?["note"] as? String ?? ""
        let oneRan = await wait(15) { tabs.filter(ran).count == 1 }
        let words = secretsUnwrapped("nxtrm: an identical command used this Allow once")
        let said = await wait(10) { tabs.contains { secretsUnwrapped(screen($0)).contains(words) } }
        _ = await wait(2) { false } // a second run would show by now
        check(onOnePanel && statuses == ["refused", "started"] && note.contains("an identical call used it") && oneRan
              && tabs.filter(ran).count == 1 && said,
              "secrets: of two identical run_with_secrets calls on one panel, one Allow once runs the command in one tab only, "
                  + "and the other call answers refused and its tab says why",
              "on one panel \(onOnePanel), \(secretsJSON(firstAnswer)) \(secretsJSON(secondAnswer)), ran in \(tabs.filter(ran).count), said \(said)")
    }

    /// A grant's values go the moment it ends on its own or is used, with no request after it (review finding 9).
    static func secretsGrantEndChecks(_ store: SecretsStore) async {
        let requests = SecretRequests.shared
        func ended(_ outcome: String, after before: Int) -> Bool {
            secretsAudit(store).dropFirst(before).contains { $0.event == .grantEnd && $0.outcome == outcome }
        }

        // "Allow for 15 minutes", and nothing asks after it. Its timer fires in 3 seconds here, by when the clock has
        // moved past the grant's end: the grant goes, its values with it, with a grant-end line.
        SecretRequests.grantTimer = 3
        let start = ContinuousClock.now
        requests.now = { start }
        let timed = secretsRequest(asker: "wrapper:selftest-timed", command: ["node", "timed.js"], tab: "tab 3")
        requests.ask(timed) { _ in }
        timed.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        timed.panel?.allowButton.performClick(nil)
        let made = await wait(10) { !requests.heldGrants.isEmpty }
        requests.now = { start.advanced(by: SecretGrant.fifteenMinutes + .seconds(1)) }
        let before = secretsAudit(store).count
        let wiped = await wait(10) { requests.heldGrants.isEmpty && requests.book.grants.isEmpty }
        let expiredLine = await wait(5) { ended("expired", after: before) }
        check(made && wiped && expiredLine,
              "secrets: a 15-minute grant ends at its own time with nothing asking after it: its values go, with a grant-end line",
              "made \(made), wiped \(wiped), line \(expiredLine)")

        // A one-use grant (its wrapper left during Touch ID after Allow once) goes the moment it is used.
        let leaving = secretsRequest(asker: "wrapper:selftest-used", command: ["node", "used.js"], tab: "tab 3")
        let leavingWaits = requests.ask(leaving) { _ in }
        let leavingPanel = leaving.panel
        leavingPanel?.allowButton.performClick(nil)
        if let leavingWaits { requests.wrapperLeft(leavingWaits) }
        let oneUse = await wait(10) { requests.book.grants.contains { $0.kind == .oneUse } }
        leavingPanel?.close()
        let beforeUse = secretsAudit(store).count
        let restartAnswers = SecretsAnswers()
        let restarted = secretsRequest(asker: "wrapper:selftest-used", command: ["node", "used.js"], tab: "tab 3")
        requests.ask(restarted) { restartAnswers.take($0) }
        let gone = requests.book.grants.isEmpty && requests.heldGrants.isEmpty
        let usedLine = await wait(5) { ended("used", after: beforeUse) }
        check(oneUse && secretsAllowed(restartAnswers.last)?.how == .grant && gone && usedLine,
              "secrets: a one-use grant and its values go the moment it is used, with a grant-end line",
              "made \(oneUse), gone \(gone), line \(usedLine)")

        // A one-use grant never used: its timer ends it at its 2 minutes, with nothing asking after it, and its values go.
        let unusedStart = ContinuousClock.now
        requests.now = { unusedStart }
        SecretRequests.grantTimer = 3
        let unused = secretsRequest(asker: "wrapper:selftest-unused", command: ["node", "unused.js"], tab: "tab 3")
        let unusedWaits = requests.ask(unused) { _ in }
        let unusedPanel = unused.panel
        unusedPanel?.allowButton.performClick(nil)
        if let unusedWaits { requests.wrapperLeft(unusedWaits) }
        let unusedMade = await wait(10) { requests.book.grants.contains { $0.kind == .oneUse } && !requests.heldGrants.isEmpty }
        unusedPanel?.close()
        let beforeEnd = secretsAudit(store).count
        requests.now = { unusedStart.advanced(by: SecretGrant.oneUseWindow + .seconds(1)) }
        let unusedWiped = await wait(10) { requests.heldGrants.isEmpty && requests.book.grants.isEmpty }
        let unusedLine = await wait(5) { ended("expired", after: beforeEnd) }
        check(unusedMade && unusedWiped && unusedLine,
              "secrets: a one-use grant never used ends at its 2 minutes with nothing asking after it: its values go, with a grant-end line",
              "made \(unusedMade), wiped \(unusedWiped), line \(unusedLine)")
    }
}
#endif
