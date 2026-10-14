import AppKit
import NextTermCore

#if DEBUG
/// "Where it came from", Open Page and the Page column, on the self-test's temporary vaults only. Pages are recorded by
/// `ServiceLinks.recordsOnly` and never opened; nothing is fetched. Keys are pressed from CGEvents (`secretsType`). Every value is made up at run time from a provider's
/// head and random filler, so no file holds a key-shaped string whole.
extension SelfTest {
    static let sourcesOpenAIPage = "https://platform.openai.com/settings/organization/api-keys"

    static func secretSourcesChecks(_ c: TerminalWindowController, base: URL) async {
        let recording = ServiceLinks.recordsOnly
        ServiceLinks.recordsOnly = true
        ServiceLinks.opened = []
        defer {
            ServiceLinks.recordsOnly = recording
            ServiceLinks.opened = []
        }
        await secretSourcesSheetChecks()
        await secretSourcesStoreChecks(base)
        await secretSourcesVouchChecks(base)
        await secretSourcesRequestChecks()
        await secretSourcesRequestUseChecks()
        await secretRotateChecks(c, base: base)
        await secretReminderChecks()
    }

    /// Add… suggests the page from the value's head, Use fills it, Save keeps it; a link with a user and password, or
    /// with the key in it, is refused under the field with Save off; the Page cell, Open Page and list_secrets.
    static func secretSourcesSheetChecks() async {
        let store = SecretsStore.shared
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible,
              let presence = store.presence as? StandInPresence else {
            return check(false, "secret sources: Window › Secrets opens its window")
        }
        defer { window.close() }
        let view = controller.secretsView
        let value = secretsValue("sk-" + "proj-")
        view.add()
        guard let sheet = view.sheet, let link = sheet.linkField else {
            return check(false, "secret sources: Add… has Where it came from")
        }
        secretsType("SOURCE_OPENAI_KEY", into: sheet.nameField)
        check(link.text.isEmpty && link.field.placeholderString == SecretLinkField.placeholder,
              "secret sources: Where it came from starts empty, with its placeholder")
        secretsType(value, into: sheet.valueField)
        let chipped: Bool = link.chipLabel.stringValue == "Suggested: OpenAI · API Keys"
        check(link.showsSuggestion && chipped && link.text.isEmpty,
              "secret sources: a value with OpenAI's head suggests its page in a chip, and fills nothing",
              link.chipLabel.stringValue)
        link.useButton.performClick(nil)
        let filled: Bool = link.text == sourcesOpenAIPage && link.linkFrom == .suggested
        check(filled && !link.showsSuggestion && sheet.saveButton.isEnabled,
              "secret sources: Use fills the page, and the chip goes", link.text)
        sheet.saveButton.performClick(nil)
        _ = await wait(10) { view.sheet == nil && store.index?.entry(named: "SOURCE_OPENAI_KEY") != nil }
        let saved = store.index?.entry(named: "SOURCE_OPENAI_KEY")
        let kept: Bool = saved?.link == sourcesOpenAIPage && saved?.linkFrom == .suggested
        check(kept && saved?.valueSet != nil,
              "secret sources: Save keeps the page and that it was the suggestion", saved?.link ?? "no link")
        await secretSourcesRefusalChecks(view)
        secretSourcesCellChecks(view)

        // Open Page names the host; with vault.json as Next Term just wrote it, it opens with no Touch ID.
        view.select("SOURCE_OPENAI_KEY")
        let title = saved.flatMap { view.pageItem(for: $0)?.title }
        let calls = presence.calls
        view.openPage()
        _ = await wait(5) { !ServiceLinks.opened.isEmpty }
        let opened: [String] = ServiceLinks.opened.map { (url: URL) -> String in url.absoluteString }
        let named: Bool = title == "Open platform.openai.com"
        check(named && opened == [sourcesOpenAIPage] && presence.calls == calls,
              "secret sources: Open platform.openai.com opens the page from the bytes Next Term wrote, with no Touch ID",
              "\(title ?? "no item"), \(ServiceLinks.opened), \(presence.calls - calls) checks")
        await secretSourcesListChecks(value: value)
        await secretSourcesDoubleClickChecks(view, "SOURCE_OPENAI_KEY", page: sourcesOpenAIPage)
        secretSourcesColumnChecks(window, view)
        _ = try? await store.perform(.delete(name: "SOURCE_OPENAI_KEY"))
        await secretSourcesEditChecks(view, presence)
        await secretSourcesHeldChecks(view, presence)
    }

    /// A link with a user and password, then one holding the key being added: each refused under the field, Save off.
    static func secretSourcesRefusalChecks(_ view: SecretsView) async {
        view.add()
        guard let sheet = view.sheet, let link = sheet.linkField else {
            return check(false, "secret sources: Add… opens again")
        }
        let value = secretsValue("source-refused-")
        secretsType("SOURCE_REFUSED_KEY", into: sheet.nameField)
        secretsType(value, into: sheet.valueField)
        func type(_ text: String) { secretsType(text, into: link.field) }
        type("https://u:p@example.com")
        let credentials: Bool = link.refusalLabel.stringValue == SecretLink.Refusal.userOrPassword.sentence
        check(!link.refusalLabel.isHidden && credentials && !sheet.saveButton.isEnabled,
              "secret sources: a link with a user name and password is refused under the field, and Save is off",
              link.refusalLabel.stringValue)
        type("https://dashboard.example.com/keys/" + value)
        let holds: Bool = link.refusalLabel.stringValue == SecretLink.Refusal.holdsAKey.sentence
        check(holds && !sheet.saveButton.isEnabled,
              "secret sources: a link holding the key being added is refused", link.refusalLabel.stringValue)
        type("")
        check(link.refusalLabel.isHidden && sheet.saveButton.isEnabled, "secret sources: with no link, Save is on again")
        sheet.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
    }

    /// The Page cell shows the host, with the whole link as its tooltip; the Rotated cell, that it was added today.
    static func secretSourcesCellChecks(_ view: SecretsView) {
        guard let row = view.entries.firstIndex(where: { $0.name == "SOURCE_OPENAI_KEY" }) else {
            return check(false, "secret sources: the key is listed")
        }
        func cell(_ id: String) -> NSTextField? {
            let column = view.table.tableColumns.first { $0.identifier.rawValue == id }
            return view.tableView(view.table, viewFor: column, row: row) as? NSTextField
        }
        let page = cell("page")
        let host: Bool = page?.stringValue == "platform.openai.com"
        check(host && page?.toolTip == sourcesOpenAIPage,
              "secret sources: the Page cell shows the host, and the whole link as its tooltip", page?.stringValue ?? "no cell")
        let rotated = cell("rotated")?.stringValue
        check(rotated == "Added today", "secret sources: the Rotated cell says the key was added today", rotated ?? "no cell")
    }

    /// list_secrets names the page's provider, the day and whether a reminder is due, and never the link.
    static func secretSourcesListChecks(value: String) async {
        let listed = await secretsTool("list_secrets", [:])
        let rows = listed["secrets"] as? [[String: Any]] ?? []
        let row = rows.first { $0["name"] as? String == "SOURCE_OPENAI_KEY" }
        let today = SecretAge.day(Date())
        let hidden = ["link", "url", "page"].allSatisfy { (member: String) -> Bool in row?[member] == nil }
        let text = secretsJSON(listed)
        let service: Bool = row?["service"] as? String == "OpenAI"
        let rotated: Bool = row?["rotated"] as? String == today
        let due: Bool = row?["rotate_due"] as? Bool == false
        let leaks: Bool = text.contains("platform.openai.com") || text.contains(value)
        check(service && rotated && due && hidden && !leaks,
              "secret sources: list_secrets gives the service, the day and rotate_due, and no link or value", text)
    }
}

extension SelfTest {
    /// A page opens with no unlock only from the bytes of vault.json Next Term last wrote or checked: after a launch,
    /// one unlock checks them first; after another process rewrote the file and set its date back, the unlock that
    /// opening asks for reports the vault as changed outside Next Term.
    static func secretSourcesVouchChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, presence) = secretsStore(base, "vouch", keyring: keyring)
        let added = (try? await store.perform(.add(name: "VOUCH_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                                   writeOnly: false, value: SecretBytes(utf8: secretsValue("vouch-")),
                                                   link: sourcesOpenAIPage))) != nil
        let calls = presence.calls
        let written = try? await store.checkedPage(of: "VOUCH_KEY")
        let writtenPage: Bool = written?.absoluteString == sourcesOpenAIPage
        check(added && writtenPage && presence.calls == calls,
              "secret sources: a page opens with no Touch ID from the bytes Next Term last wrote",
              "\(presence.calls - calls) checks")

        // As after a launch: no bytes vouched for yet.
        let freshPresence = StandInPresence()
        let fresh = SecretsStore(folder: store.folder, presence: freshPresence, newKeyring: { keyring }, keyring: { _ in keyring },
                                 record: store.record)
        await fresh.load()
        let first = try? await fresh.checkedPage(of: "VOUCH_KEY")
        let afterFirst = freshPresence.calls
        let second = try? await fresh.checkedPage(of: "VOUCH_KEY")
        let firstPage: Bool = first?.absoluteString == sourcesOpenAIPage
        check(firstPage && afterFirst == 1 && second == first && freshPresence.calls == 1,
              "secret sources: after a launch one unlock checks vault.json before a page opens, then none",
              "\(afterFirst), then \(freshPresence.calls) checks")

        // Another process writes a new link with the old modification date.
        let path = store.folder.path(SecretFolder.vaultName)
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard let file = FileManager.default.contents(atPath: path), let date,
              let planted = secretsTampered(file, { $0["link"] = "https://platform.openai.com/planted" }) else {
            return check(false, "secret sources: the changed vault.json is planted")
        }
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        var refusal: SecretsStore.Failure?
        do { _ = try await fresh.checkedPage(of: "VOUCH_KEY") } catch { refusal = error as? SecretsStore.Failure }
        let reported: Bool = refusal == .vault(.tampered) && fresh.protection == .tampered
        check(reported && freshPresence.calls == 2,
              "secret sources: a link changed outside Next Term asks for an unlock first, which reports the vault as changed",
              "\(String(describing: refusal)), \(freshPresence.calls) checks, \(fresh.protection)")
    }

    /// request_secret's window starts with Where it came from empty, and a link argument from the agent neither fills
    /// it nor sets one.
    static func secretSourcesRequestChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        let planted = "https://dashboard.example.com/keys"
        let call = secretsStart("request_secret", ["name": "SOURCE_ASKED_KEY", "reason": "the page checks", "link": planted])
        _ = await wait(10) { requests.showing?.requestWindow != nil }
        guard let window = requests.showing?.requestWindow else {
            return check(false, "secret sources: request_secret opens its window")
        }
        check(window.linkField.text.isEmpty, "secret sources: request_secret's window has Where it came from, empty")
        secretsType(secretsValue("asked-"), into: window.valueField)
        window.saveButton.performClick(nil)
        let answer = await call.value
        let entry = store.index?.entry(named: "SOURCE_ASKED_KEY")
        let saved: Bool = answer["status"] as? String == "saved" && entry != nil
        let noLink: Bool = entry?.link == nil && !secretsJSON(answer).contains("example.com")
        check(saved && noLink,
              "secret sources: an agent's link argument sets no link", secretsJSON(answer))
        window.close()
        _ = try? await store.perform(.delete(name: "SOURCE_ASKED_KEY"))
    }
}
#endif
