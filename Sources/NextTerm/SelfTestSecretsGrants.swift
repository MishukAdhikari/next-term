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
        _ = try? await store.perform(.delete(name: "PANEL_KEY"))
    }
}
#endif
