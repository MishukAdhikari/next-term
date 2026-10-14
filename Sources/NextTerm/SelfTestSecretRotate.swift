import AppKit
import NextTermCore

#if DEBUG
/// Rotate…, on the self-test's temporary vault only: step 1 opens GitHub's new-token form (recorded by
/// `ServiceLinks.recordsOnly`, never opened; nothing is fetched), the key the user has now is refused as it is typed, a
/// new one is saved with the stand-in's Touch ID, the old one stays masked, grants end, the clipboard is cleared, and
/// Remind Me Tomorrow keeps its day in a defaults suite of the run's own. Every value is made up at run time.
extension SelfTest {
    static let rotatePage = "https://github.com/settings/personal-access-tokens"

    static func secretRotateChecks() async {
        let store = SecretsStore.shared
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible,
              let presence = store.presence as? StandInPresence else {
            return check(false, "secret rotate: Window › Secrets opens its window")
        }
        defer { window.close() }
        let suiteName = "nt-selftest-rotate-\(getpid())"
        let saved = SecretReminderRecords.defaults
        SecretReminderRecords.defaults = UserDefaults(suiteName: suiteName) ?? saved
        defer {
            SecretReminderRecords.defaults = saved
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let view = controller.secretsView
        let name = "ROTATE_GITHUB_TOKEN"
        let old = secretsValue("github_" + "pat_")
        let add: SecretsStore.Action = .add(name: name, purpose: "triage-agent", purposeBy: .user, origin: .settings,
                                            writeOnly: false, value: SecretBytes(utf8: old), link: rotatePage, linkFrom: .suggested)
        do {
            try await store.perform(add)
        } catch {
            return check(false, "secret rotate: a made-up key with GitHub's tokens page is saved", "\(error)")
        }
        view.reload()
        view.select(name)
        check(view.rotateButton.isEnabled, "secret rotate: Rotate… is on for the selected key")
        view.rotateKey()
        guard let sheet = view.rotateSheet else { return check(false, "secret rotate: Rotate… opens its sheet") }
        await secretRotateOpenChecks(sheet, presence)
        await secretRotateSaveChecks(view, sheet, presence, old: old)
        _ = try? await store.perform(.delete(name: name))
        await secretRotateNoPageChecks(view)
    }

    /// Step 1: Open github.com opens the new-token form filled with the key's name and today's date, from the bytes
    /// Next Term wrote, with no Touch ID.
    static func secretRotateOpenChecks(_ sheet: SecretRotateSheet, _ presence: StandInPresence) async {
        ServiceLinks.opened = []
        let calls = presence.calls
        check(sheet.linkField == nil && sheet.openButton.title == "Open github.com" && sheet.openButton.isEnabled,
              "secret rotate: step 1 names the page's host", sheet.openButton.title)
        sheet.openButton.performClick(nil)
        _ = await wait(5) { !ServiceLinks.opened.isEmpty }
        let opened: [String] = ServiceLinks.opened.map { (url: URL) -> String in url.absoluteString }
        let stamp: String = SecretAge.day(Date())
        let form = rotatePage + "/new?name=" + sheet.name + "%20" + stamp + "&expires_in=90"
        check(opened == [form] && presence.calls == calls,
              "secret rotate: Open github.com opens GitHub's new-token form, filled in, with no Touch ID",
              "\(opened), \(presence.calls - calls) checks")
    }

    /// Step 2 and 3: the key it has now is refused as typed; a new one, pasted, is saved with one Touch ID ("rotate
    /// NAME"); the old one stays masked; its grants end; the clipboard is cleared; step 3 opens the page again and
    /// keeps Remind Me Tomorrow's day.
    static func secretRotateSaveChecks(_ view: SecretsView, _ sheet: SecretRotateSheet, _ presence: StandInPresence,
                                       old: String) async {
        let name = sheet.name
        secretsType(old, into: sheet.valueField)
        check(sheet.checkLabel.stringValue == SecretRotateSheet.currentLine && !sheet.checkLabel.isHidden
              && !sheet.saveButton.isEnabled,
              "secret rotate: the key it has now is refused as it is typed, and Save stays off", sheet.checkLabel.stringValue)
        let new = secretsValue("github_" + "pat_")
        let pasteboard = SecretClipboard.shared.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(new, forType: .string)
        secretsType(new, into: sheet.valueField)
        sheet.recordPaste()
        check(sheet.checkLabel.isHidden && sheet.saveButton.isEnabled, "secret rotate: a new key turns Save on")
        let ended = SelfTestLines()
        let observer = NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: nil, queue: nil) { note in
            for changed in note.userInfo?["names"] as? [String] ?? [] { ended.append(changed) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        sheet.saveButton.performClick(nil)
        _ = await wait(10) { sheet.isSaved }
        let entry = SecretsStore.shared.index?.entry(named: name)
        let reason: String? = presence.reasons.last
        check(sheet.isSaved && reason == "rotate \(name)" && entry?.retired != nil,
              "secret rotate: Save asks for Touch ID once, to rotate the key, and keeps the old key's marks",
              reason ?? "no check")
        let rotated: String = entry.map { (saved: SecretVault.Entry) -> String in SecretAge.text(entry: saved, now: Date()) } ?? ""
        check(rotated == "Today", "secret rotate: the Rotated column reads Today", rotated)
        let masked: String = SecretMask.current.mask("printed \(old) and \(new)")
        check(masked == "printed ••• and •••", "secret rotate: the old key stays masked beside the new one")
        check(ended.lines.contains(name), "secret rotate: the grants holding the key end", "\(ended.lines)")
        let line: String = sheet.doneLabel.stringValue
        let says: Bool = line.contains(SecretRotateSheet.deleteLine) && line.contains(SecretRotation.keptMaskedLine)
            && line.contains(SecretRotateSheet.restartLine)
        check(says && pasteboard.string(forType: .string) == nil && line.contains(SecretClipboard.clearedLine),
              "secret rotate: step 3 says what to do at the page and what to restart, and the pasted key left the clipboard",
              line)
        check(sheet.doneButton.isEnabled && !sheet.saveButton.isEnabled && !sheet.valueField.isEnabled,
              "secret rotate: after Save, step 3 is on and the paste field off")
        ServiceLinks.opened = []
        sheet.openAgainButton.performClick(nil)
        _ = await wait(5) { !ServiceLinks.opened.isEmpty }
        check(ServiceLinks.opened.map(\.absoluteString) == [rotatePage], "secret rotate: Open Page Again opens the tokens page itself",
              "\(ServiceLinks.opened)")
        sheet.remindTomorrowButton.performClick(nil)
        _ = await wait(5) { view.rotateSheet == nil }
        let calendar = Calendar.current
        let tomorrow: Date? = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        check(view.rotateSheet == nil && SecretReminderRecords.remindOn[name] == tomorrow,
              "secret rotate: Remind Me Tomorrow closes the sheet and keeps tomorrow for that key")
    }

    /// A key with no page: step 1 is "Where it came from", Open names the page typed there, a key that looks like
    /// another provider's is warned about with Save on, and the page is saved with the new key.
    static func secretRotateNoPageChecks(_ view: SecretsView) async {
        let store = SecretsStore.shared
        let name = "ROTATE_PLAIN_KEY"
        let page = sourcesOpenAIPage
        let add: SecretsStore.Action = .add(name: name, purpose: "rag-api", purposeBy: .user, origin: .settings, writeOnly: false,
                                            value: SecretBytes(utf8: secretsValue("made-up-")))
        _ = try? await store.perform(add)
        view.reload()
        view.openRotate(named: name)
        guard let sheet = view.rotateSheet, let link = sheet.linkField else {
            return check(false, "secret rotate: a key with no page gets Where it came from in step 1")
        }
        check(!sheet.openButton.isEnabled, "secret rotate: with no page yet, step 1's button is off")
        secretsType(page, into: link.field)
        ServiceLinks.opened = []
        check(sheet.openButton.isEnabled && sheet.openButton.title == "Open platform.openai.com",
              "secret rotate: a page typed in step 1 names its host", sheet.openButton.title)
        sheet.openButton.performClick(nil)
        check(ServiceLinks.opened.map(\.absoluteString) == [page], "secret rotate: the typed page opens as it is")
        secretsType(secretsValue("sk_" + "test_"), into: sheet.valueField)
        let warning = "This key looks like one from Stripe, but its page is OpenAI\u{2019}s."
        check(sheet.checkLabel.stringValue == warning && sheet.saveButton.isEnabled,
              "secret rotate: a key that looks like another provider's is named, and Save stays on", sheet.checkLabel.stringValue)
        sheet.saveButton.performClick(nil)
        _ = await wait(10) { sheet.isSaved }
        let entry = store.index?.entry(named: name)
        check(entry?.link == page && entry?.linkFrom == .user && sheet.openAgainButton.isHidden == false,
              "secret rotate: the page typed in step 1 is saved with the new key", entry?.link ?? "no link")
        sheet.doneButton.performClick(nil)
        _ = await wait(5) { view.rotateSheet == nil }
        check(view.actionLabel.stringValue == "Rotated \(name).", "secret rotate: Done closes the sheet", view.actionLabel.stringValue)
        _ = try? await store.perform(.delete(name: name))
    }
}
#endif
