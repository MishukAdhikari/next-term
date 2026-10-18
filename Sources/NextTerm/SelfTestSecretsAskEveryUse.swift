import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// Settings › Secrets' New keys defaults, "Never show this key" and "Ask for Touch ID every time it's used": a key
    /// that asks is offered only Allow once, and ticking the box ends the approvals holding it. Every value is made up.
    static func secretsAskEveryUseChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        let suiteName = "nt-selftest-new-keys-\(getpid())"
        let saved = SecretReminderRecords.defaults
        SecretReminderRecords.defaults = UserDefaults(suiteName: suiteName) ?? saved
        defer {
            requests.resetForSelfTest()
            SecretReminderRecords.defaults = saved
            UserDefaults().removePersistentDomain(forName: suiteName)
            NotificationCenter.default.post(name: SecretNewKeySettingsView.changed, object: nil)
        }
        secretsNewKeyDefaultsChecks()
        await secretsAskOnceChecks()
        await secretsAskTickChecks()
        await secretsNeverShowStaysChecks()
        let value = SecretBytes(utf8: secretsValue("never-shown"))
        _ = try? await store.perform(.add(name: "NEVER_KEY", purpose: "the lock checks", purposeBy: .user, origin: .settings,
                                          writeOnly: true, value: value))
        if let entry = store.index?.entry(named: "NEVER_KEY") {
            let cell: NSView = SecretsView.neverShownCell(entry)
            let hasLock: Bool = (cell as? NSImageView)?.image != nil
            check(hasLock && cell.toolTip == SecretNewKeyDefaults.neverShownHelp,
                  "secrets: a key never shown has a lock in the list, its tooltip Never shown")
        } else {
            check(false, "secrets: a key saved never shown is listed")
        }
        for name in ["ASK_KEY", "LASTING_KEY", "NEVER_KEY"] { _ = try? await store.perform(.delete(name: name)) }
    }

    /// The New keys group starts with values shown and Touch ID asked every time, and Add… starts as it says.
    private static func secretsNewKeyDefaultsChecks() {
        let settings = SecretNewKeySettingsView()
        let add = SecretEditSheet(.add) { _ in }
        let startsShown: Bool = settings.neverShowBox.state == .off && add.writeOnlyBox.state == .off
        let startsAsking: Bool = settings.asksBox.state == .on && add.asksBox?.state == .on
        let titled: Bool = add.writeOnlyBox.title == SecretNewKeyDefaults.keyNeverShowTitle
            && add.asksBox?.title == SecretNewKeyDefaults.keyAsksTitle
        check(startsShown && startsAsking && titled,
              "secrets: New keys start shown and asking for Touch ID every time, and Add… has both boxes so")
        settings.neverShowBox.performClick(nil)
        settings.asksBox.performClick(nil)
        let ticked = SecretEditSheet(.add) { _ in }
        let saved: Bool = SecretNewKeyDefaults.neverShow && !SecretNewKeyDefaults.asksEveryUse
        check(saved && ticked.writeOnlyBox.state == .on && ticked.asksBox?.state == .off,
              "secrets: New keys pre-ticks Add…'s Never show this key, and unticks its Ask for Touch ID every time")
        settings.neverShowBox.performClick(nil)
        settings.asksBox.performClick(nil)
        check(!SecretNewKeyDefaults.neverShow && SecretNewKeyDefaults.asksEveryUse,
              "secrets: New keys' boxes set the defaults back")
    }

    /// A key that asks every time: the panel offers only Allow once and says why; a wrapper that stops waiting keeps it
    /// on, and its Allow once waits 2 minutes for the restart as a one-use approval, which ticking nothing ends.
    private static func secretsAskOnceChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        _ = try? await store.perform(.add(name: "ASK_KEY", purpose: "the ask checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("ask"))))
        let asks = secretsRequest(asker: "wrapper:selftest-ask", command: ["node", "ask.js"], names: ["ASK_KEY"], tab: "tab 3")
        let waits = requests.ask(asks) { _ in }
        let panel: SecretApprovalPanel? = asks.panel
        let shown: String = texts(panel?.window?.contentView)
        let onlyOnce: Bool = panel?.durationChoice.count == 1 && panel?.durationChoice[.once]?.state == .on
        check(store.index?.entry(named: "ASK_KEY")?.asksEveryUse == true && onlyOnce
              && shown.contains(SecretApprovalPanel.askingNote(["ASK_KEY"])),
              "secrets: a key that asks for Touch ID every time is offered only Allow once, and the panel says why", shown)
        if let waits { requests.wrapperLeft(waits) }
        check(asks.gone && panel?.durationChoice[.once]?.isEnabled == true,
              "secrets: a pending card for a key that asks every time keeps Allow once on")
        panel?.allowButton.performClick(nil)
        let oneUse: Bool = await wait(10) { requests.grants.contains { $0.kind == .oneUse && $0.names == ["ASK_KEY"] } }
        let lasting: Bool = requests.grants.contains { $0.kind != .oneUse }
        check(oneUse && !lasting,
              "secrets: Allow once on that card waits for the restart as one use, and no lasting approval is made")
        requests.resetForSelfTest()
    }

    /// A key that lets approvals last is offered them; ticking its box in Edit… ends the approval holding it.
    private static func secretsAskTickChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        _ = try? await store.perform(.add(name: "LASTING_KEY", purpose: "the lasting checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("lasting")), asksEveryUse: false))
        guard let entry = store.index?.entry(named: "LASTING_KEY") else {
            return check(false, "secrets: a key saved with Ask every time unticked is listed")
        }
        let edit = SecretEditSheet(.edit(entry)) { _ in }
        check(edit.asksBox?.state == .off, "secrets: Edit… shows a key's Ask for Touch ID every time unticked when it is")
        let request = secretsRequest(asker: "wrapper:selftest-lasting", command: ["node", "lasting.js"], names: ["LASTING_KEY"],
                                     tab: "tab 3")
        requests.ask(request) { _ in }
        let offersLasting: Bool = request.panel?.durationChoice[.untilLock] != nil
        request.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        request.panel?.allowButton.performClick(nil)
        let granted: Bool = await wait(10) { requests.grants.contains { $0.names == ["LASTING_KEY"] } }
        let tick: SecretsStore.Action = .edit(name: "LASTING_KEY", newName: nil, purpose: nil, purposeBy: .user, asksEveryUse: true)
        _ = try? await store.perform(tick)
        let ended: Bool = await wait(5) { !requests.grants.contains { $0.names == ["LASTING_KEY"] } }
        check(offersLasting && granted && ended && store.index?.entry(named: "LASTING_KEY")?.asksEveryUse == true,
              "secrets: ticking Ask for Touch ID every time ends the approval holding the key",
              "offered \(offersLasting), granted \(granted), ended \(ended)")
        requests.resetForSelfTest()
    }
}
#endif
