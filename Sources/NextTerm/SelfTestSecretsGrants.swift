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
                                          writeOnly: true, value: SecretBytes(utf8: value)))

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
    }
}
#endif
