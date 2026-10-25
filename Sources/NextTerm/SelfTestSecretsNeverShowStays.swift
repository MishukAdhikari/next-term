import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// "Never show this key" can't be undone: `request_secret`'s window and Replace… keep a never-shown key's box ticked
    /// and dimmed, and a new value keeps the flag. Also the import's Never show, the reason an Edit… gives when it
    /// unticks Ask every time beside another change, and the approval a use's audit line records. Runs on the New keys
    /// suite `secretsAskEveryUseChecks` sets. Every value is made up.
    static func secretsNeverShowStaysChecks() async {
        let store = SecretsStore.shared
        let added = try? await store.perform(.add(name: "STAYS_KEY", purpose: "the never-show checks", purposeBy: .user,
                                                  origin: .settings, writeOnly: true,
                                                  value: SecretBytes(utf8: secretsValue("stays"))))
        guard added != nil, let entry = store.index?.entry(named: "STAYS_KEY") else {
            return check(false, "secrets: a key saved never shown is listed, for the never-show checks")
        }
        secretsNeverShowWindowChecks()
        let replace = SecretEditSheet(.replace(entry)) { _ in }
        check(replace.writeOnlyBox.state == .on && !replace.writeOnlyBox.isEnabled,
              "secrets: Replace… of a key never shown keeps Never show this key ticked and dimmed")
        let typed: SecretsStore.Action = .replace(name: "STAYS_KEY", value: SecretBytes(utf8: secretsValue("stays-new")),
                                                  writeOnly: false, origin: .request)
        _ = try? await store.perform(typed)
        let stays: Bool = store.index?.entry(named: "STAYS_KEY")?.writeOnly == true
        let refused: Bool = (try? await store.perform(.reveal(name: "STAYS_KEY"))) == nil
        check(stays && refused, "secrets: a new value for a key never shown leaves it never shown, and Reveal refused")
        await secretsNeverShowImportChecks()
        secretsUntickReasonChecks()
        await secretsRecordedApprovalChecks()
        _ = try? await store.perform(.delete(name: "STAYS_KEY"))
    }

    /// `request_secret`'s window: a stored key never shown has its box ticked and dimmed, and Save says never shown; a
    /// new name has the box as the user left it, and New keys' Never show their values ticks it to start.
    private static func secretsNeverShowWindowChecks() {
        var saved: SecretRequestWindow.Form?
        let content = SecretRequestWindow.Content(title: "Codex asks you to add STAYS_KEY", askedBy: "Codex in tab 3",
                                                  agentWords: nil, name: "STAYS_KEY", purpose: "")
        let window = SecretRequestWindow(content, onSave: { saved = $0 }, onDecline: { _ in })
        let box: NSButton = window.writeOnlyBox
        let locked: Bool = box.state == .on && !box.isEnabled
        let typed = Notification(name: NSControl.textDidChangeNotification, object: window.nameField)
        window.nameField.stringValue = "OTHER_STAYS_KEY"
        window.controlTextDidChange(typed)
        let freed: Bool = box.state == .off && box.isEnabled
        window.nameField.stringValue = "STAYS_KEY"
        window.controlTextDidChange(typed)
        window.valueField.stringValue = secretsValue("stays-typed")
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: window.valueField))
        window.saveButton.performClick(nil)
        check(locked && freed && saved?.writeOnly == true,
              "secrets: request_secret's window keeps Never show this key ticked and dimmed for a key never shown",
              "locked \(locked), freed \(freed), saved \(String(describing: saved?.writeOnly))")
        window.finish()
        SecretNewKeyDefaults.neverShow = true
        let fresh = SecretRequestWindow(SecretRequestWindow.Content(title: "Codex asks you to add FRESH_KEY", askedBy: "Codex",
                                                                    agentWords: nil, name: "FRESH_KEY", purpose: ""),
                                        onSave: { _ in }, onDecline: { _ in })
        let ticked: Bool = fresh.writeOnlyBox.state == .on && fresh.writeOnlyBox.isEnabled
        SecretNewKeyDefaults.neverShow = false
        fresh.finish()
        check(ticked, "secrets: New keys' Never show their values starts request_secret's box ticked for a new name")
    }

    /// The MCP-config move: a row ticked Never show is saved never shown, the others shown, and each asks every time
    /// as New keys says.
    private static func secretsNeverShowImportChecks() async {
        let store = SecretsStore.shared
        let keys: [SecretsStore.ImportKey] = [
            SecretsStore.ImportKey(name: "MOVED_NEVER_KEY", purpose: "", value: SecretBytes(utf8: secretsValue("moved-never")),
                                   writeOnly: true),
            SecretsStore.ImportKey(name: "MOVED_SHOWN_KEY", purpose: "", value: SecretBytes(utf8: secretsValue("moved-shown"))),
        ]
        _ = try? await store.performImport(keys, kept: [:], reason: SecretReason.moveOut(keys.count))
        let never = store.index?.entry(named: "MOVED_NEVER_KEY")
        let shown = store.index?.entry(named: "MOVED_SHOWN_KEY")
        let asks: Bool = never?.asksEveryUse == true && shown?.asksEveryUse == true
        check(never?.writeOnly == true && shown?.writeOnly == false && asks,
              "secrets: the MCP-config move saves a row ticked Never show never shown, and its keys ask every time",
              "never \(String(describing: never?.writeOnly)), shown \(String(describing: shown?.writeOnly)), asks \(asks)")
        for key in keys { _ = try? await store.perform(.delete(name: key.name)) }
    }

    /// Edit… that unticks Ask for Touch ID every time beside a rename or another change names the untick at Touch ID.
    private static func secretsUntickReasonChecks() {
        let renamed: SecretsStore.Action = .edit(name: "A_KEY", newName: "B_KEY", purpose: nil, purposeBy: .user,
                                                 asksEveryUse: false)
        let detailed: SecretsStore.Action = .edit(name: "A_KEY", newName: nil, purpose: "staging", purposeBy: .user,
                                                  asksEveryUse: false)
        let alone: SecretsStore.Action = .edit(name: "A_KEY", newName: nil, purpose: nil, purposeBy: .user, asksEveryUse: false)
        let ticked: SecretsStore.Action = .edit(name: "A_KEY", newName: "B_KEY", purpose: nil, purposeBy: .user,
                                                asksEveryUse: true)
        let reasons: [String] = [renamed.reason, detailed.reason, alone.reason, ticked.reason]
        let expected: [String] = ["rename A_KEY to B_KEY and stop asking every time it\u{2019}s used",
                                  "change what A_KEY is for and stop asking every time it\u{2019}s used",
                                  "stop asking every time A_KEY is used",
                                  "rename A_KEY to B_KEY"]
        check(reasons == expected, "secrets: Edit… names unticking Ask every time at Touch ID, beside a rename or another change",
              reasons.joined(separator: "; "))
    }

    /// A use asked with a lasting approval for a key that asks every time is recorded as Allow once, as Allow keeps it.
    private static func secretsRecordedApprovalChecks() async {
        let store = SecretsStore.shared
        let facts = SecretsStore.Facts(who: "the self-test", command: "node stays.js", folder: "/tmp/stays",
                                       approval: .fifteenMinutes)
        _ = try? await store.perform(.use(names: ["STAYS_KEY"]), facts: facts)
        let line: SecretAudit.Line? = secretsAudit(store).last
        check(line?.event == .use && line?.approval == .once,
              "secrets: a use of a key that asks every time is recorded as Allow once, whatever was chosen before Touch ID",
              line?.approval?.rawValue ?? "none")
    }
}
#endif
