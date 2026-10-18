import AppKit
import NextTermCore

#if DEBUG
/// import_secrets, on the self-test's temporary vault and files under its own folder only, called in-process as a local
/// agent's call. The file's sheet opens with the banner, a key the vault has starts unticked, two rows go in under
/// the stand-in presence check, and the answer is names and counts. Refusals open nothing. No password manager's CLI
/// runs: a source's sheet is cancelled. Every value is made up at run time.
extension SelfTest {
    static func secretImportToolChecks(base: URL) async {
        let store = SecretsStore.shared
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible,
              store.presence is StandInPresence else {
            return check(false, "import_secrets: Show Secrets opens the Secrets window")
        }
        let folder: URL = base.appendingPathComponent("import-tool/shop-web", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            requests.resetForSelfTest()
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let view = controller.secretsView
        let env: URL = folder.appendingPathComponent(".env.local")
        await secretImportToolRefusals(view, env: env)
        await secretImportToolFileCheck(view, env: env)
        await secretImportToolSourceCheck(view)
        await secretImportToolLimitChecks(view, env: env)
    }

    /// Refused before anything opens: path and source both, a remote connection, a protected folder.
    static func secretImportToolRefusals(_ view: SecretsView, env: URL) async {
        try? "AE9_PROBE_KEY=\(secretsValue("sb_" + "secret_"))\n".write(to: env, atomically: true, encoding: .utf8)
        let both: [String: Any] = await secretsTool("import_secrets", ["path": env.path, "source": "bws"])
        check(both["status"] as? String == "refused" && both["note"] as? String == SecretSources.askUsage
                && !view.hasOpenSheet,
              "import_secrets: a call with both path and source is refused, and nothing opens", secretsJSON(both))
        let remote: [String: Any] = await secretsTool("import_secrets", ["path": env.path], requester: "the connection “test”")
        check(remote["status"] as? String == "refused" && remote["note"] as? String == SecretsMCP.atTheMacNote
                && !view.hasOpenSheet,
              "import_secrets: a remote connection's call is refused, and nothing opens", secretsJSON(remote))
        let ssh: [String: Any] = await secretsTool("import_secrets", ["path": "~/.ssh/config"])
        let missing: [String: Any] = await secretsTool("import_secrets", ["path": env.path + ".missing"])
        let alike: Bool = ssh["note"] as? String == missing["note"] as? String
        check(ssh["status"] as? String == "refused" && alike && !view.hasOpenSheet,
              "import_secrets: a protected folder is refused as a missing file is", secretsJSON(ssh))
    }
}

extension SelfTest {
    /// An agent's import of a `.env.local`, on the run's own names: the vault has the Stripe key, so its row starts
    /// unticked; the user imports the other two and the answer names them, with counts and nothing more.
    static func secretImportToolFileCheck(_ view: SecretsView, env: URL) async {
        let store = SecretsStore.shared
        let stripe: String = secretsValue("sk_" + "test_")
        let values: [String] = [secretsValue("sb_" + "secret_"), secretsValue("sk-" + "proj-")]
        _ = try? await store.perform(.add(name: "AE9_STRIPE_SECRET_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("sk_" + "test_"))))
        let lines: [String] = ["AE9_STRIPE_SECRET_KEY=\(stripe)", "AE9_SUPABASE_SECRET_KEY=\(values[0])",
                               "AE9_OPENAI_API_KEY=\(values[1])"]
        try? (lines.joined(separator: "\n") + "\n").write(to: env, atomically: true, encoding: .utf8)
        let reason = "Move the app's keys out of .env.local"
        let call = secretsStart("import_secrets", ["path": env.path, "reason": reason])
        guard await wait(15, { view.fileImportSheet?.asked != nil }), let sheet = view.fileImportSheet else {
            return check(false, "import_secrets: the file's sheet opens for the agent's request")
        }
        let banner: String = secretImportBannerText(sheet.window)
        let from: String = SecretSources.shownPath(canonicalPath(env.path), home: NSHomeDirectory())
        check(banner.contains("asks to import keys from \(from): \(reason)"),
              "import_secrets: the sheet's banner names who asks, the file and the reason", banner)
        let stored = sheet.rows.first { (row: FileImportRow) -> Bool in row.name == "AE9_STRIPE_SECRET_KEY" }
        let others: Bool = sheet.rows.filter { (row: FileImportRow) -> Bool in row !== stored }.allSatisfy(\.isTicked)
        check(stored?.isTicked == false && others && sheet.rows.count == 3,
              "import_secrets: a key the vault has starts unticked, the others ticked",
              sheet.rows.map { (row: FileImportRow) -> String in "\(row.name) \(row.isTicked)" }.joined(separator: ", "))
        sheet.importButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { sheet.record != nil }
        let answer: [String: Any] = await call.value
        let expected: [String: Any] = ["status": "imported", "imported": ["AE9_SUPABASE_SECRET_KEY", "AE9_OPENAI_API_KEY"],
                                       "replaced": [String](), "found": 3, "not_imported": 1, "format": "env"]
        let text: String = secretImportSorted(answer)
        let leaks: Bool = ([stripe] + values).contains { (value: String) -> Bool in text.contains(value.suffix(6)) }
        check(text == secretImportSorted(expected) && !leaks,
              "import_secrets: the answer is the names imported and counts, with no value", text)
        let audit: SecretAudit.Line? = SecretAudit.lines(in: store.folder.readAudit()).last
        let named: Bool = audit?.who != nil && audit?.command?.contains("(reason: \(reason))") == true
        check(audit?.event == .import && named, "import_secrets: the copy-in's audit line names who asked and why",
              audit?.command ?? "no line")
        sheet.doneButton.performClick(nil)
        _ = await wait(5) { view.fileImportSheet == nil }
    }

    /// The text of the import banner in `window`, if it has one.
    static func secretImportBannerText(_ window: NSWindow?) -> String {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == SecretImportAsk.bannerID { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        func texts(_ view: NSView) -> [String] {
            view.subviews.flatMap { (sub: NSView) -> [String] in (sub as? NSTextField).map { [$0.stringValue] } ?? texts(sub) }
        }
        guard let content = window?.contentView, let banner = find(content) else { return "" }
        return texts(banner).joined(separator: " ")
    }

    static func secretImportSorted(_ object: [String: Any]) -> String {
        let data: Data? = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.map { (bytes: Data) -> String in String(decoding: bytes, as: UTF8.self) } ?? ""
    }
}

extension SelfTest {
    /// A source: the password manager's sheet with the banner, and no tab or CLI; Cancel declines, and the same call
    /// at once is paused, with nothing opened.
    static func secretImportToolSourceCheck(_ view: SecretsView) async {
        let call = secretsStart("import_secrets", ["source": "bws", "reason": "Bring the team's keys in"])
        guard await wait(15, { view.managerSheet != nil }), let sheet = view.managerSheet else {
            return check(false, "import_secrets: a source opens the password manager's sheet")
        }
        let banner: String = secretImportBannerText(sheet.window)
        check(banner.contains("asks to import keys from Bitwarden Secrets Manager: Bring the team's keys in"),
              "import_secrets: the password manager's sheet has the banner", banner)
        sheet.cancelButton.performClick(nil)
        let declined: [String: Any] = await call.value
        let fixed: String = secretImportSorted(SecretSources.answer(for: .declined))
        let asFixed: Bool = secretImportSorted(declined) == fixed
        check(asFixed && view.managerSheet == nil, "import_secrets: Cancel declines, with the fixed note", secretsJSON(declined))
        let again: [String: Any] = await secretsTool("import_secrets", ["source": "bws", "reason": "Bring the team's keys in"])
        let paused: Bool = (again["note"] as? String)?.hasPrefix("paused because you declined") == true
        check(again["status"] as? String == "declined" && paused && view.managerSheet == nil,
              "import_secrets: the same request at once is paused, and nothing opens", secretsJSON(again))
    }
}

extension SelfTest {
    /// The shared limits: with the asker's count of declines reached, import_secrets gets limited and opens nothing. The
    /// banner's Decline and Stop Asking declines and stops the asker: its next request is refused, with nothing opened.
    static func secretImportToolLimitChecks(_ view: SecretsView, env: URL) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        for index in 0..<SecretLimits.perAsker {
            let request = secretsRequest(asker: "outside", command: ["count \(index)"], source: .tool, names: ["TOOL_KEY"],
                                         agent: nil)
            requests.ask(request) { _ in }
            request.panel?.declineButton.performClick(nil)
        }
        let limited: [String: Any] = await secretsTool("import_secrets", ["path": env.path])
        check(limited["status"] as? String == "limited" && !view.hasOpenSheet,
              "import_secrets: with the asker's count of declines reached, it gets limited and opens nothing",
              secretsJSON(limited))
        requests.resetForSelfTest()
        let call = secretsStart("import_secrets", ["source": "bitwarden"])
        guard await wait(15, { view.managerSheet != nil }), let sheet = view.managerSheet,
              let stop = secretImportStopButton(sheet.window) else {
            return check(false, "import_secrets: the source's sheet has the banner's Decline and Stop Asking")
        }
        stop.performClick(nil)
        let declined: [String: Any] = await call.value
        let stopped: Bool = (declined["note"] as? String)?.hasPrefix("The user chose Decline and Stop Asking") == true
        check(declined["status"] as? String == "declined" && stopped && view.managerSheet == nil,
              "import_secrets: the banner's Decline and Stop Asking declines and closes the sheet", secretsJSON(declined))
        let again: [String: Any] = await secretsTool("import_secrets", ["source": "1password"])
        let refused: Bool = (again["note"] as? String)?.hasPrefix("The user chose Decline and Stop Asking for you") == true
        check(again["status"] as? String == "declined" && refused && !view.hasOpenSheet,
              "import_secrets: after Decline and Stop Asking, the agent's next request opens nothing", secretsJSON(again))
        requests.resetForSelfTest()
    }

    /// The banner's Decline and Stop Asking in `window`, if it has one.
    static func secretImportStopButton(_ window: NSWindow?) -> SecretImportStopButton? {
        func find(_ view: NSView) -> SecretImportStopButton? {
            if let button = view as? SecretImportStopButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }
}
#endif
