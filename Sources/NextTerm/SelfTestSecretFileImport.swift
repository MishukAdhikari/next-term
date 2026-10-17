import AppKit
import CryptoKit
import NextTermCore

#if DEBUG
/// Import From › A File…, on the self-test's temporary vault and files under its own folder only. The open panel is
/// stood in by `SecretsView.pickedForSelfTest`; the stand-in presence check passes. Every value is made up at run time
/// from a provider's head and random filler. The Trash is never used: the export check unticks it first.
extension SelfTest {
    static func secretFileImportChecks(base: URL) async {
        let store = SecretsStore.shared
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible,
              let presence = store.presence as? StandInPresence else {
            return check(false, "secret file import: Show Secrets opens the Secrets window")
        }
        defer {
            SecretsView.pickedForSelfTest = nil
            window.close()
        }
        let view = controller.secretsView
        let folder: URL = base.appendingPathComponent("file-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The MCP-config import looks under a home of the run's own, and nothing is moved: its sheet is closed unused.
        let savedSetup = SecretsView.importSetup
        var setup = SecretImportSheet.Setup()
        setup.home = folder.appendingPathComponent("home", isDirectory: true).path
        setup.nxtrm = ["nxtrm"]
        let fixed: SecretImportSheet.Setup = setup
        SecretsView.importSetup = { fixed }
        defer { SecretsView.importSetup = savedSetup }
        let menu: [String] = view.importMenuButton.itemTitles
        check(Array(menu.prefix(3)) == [SecretsView.importMenuTitle, SecretsView.fileItemTitle, SecretsView.mcpItemTitle],
              "secret file import: Import From lists A File… and MCP Configs… first", "\(menu)")
        await secretFileImportEnvChecks(view, presence, folder: folder)
        await secretFileImportMoveCheck(view, folder: folder)
        await secretFileImportExportCheck(view, folder: folder)
    }

    /// The fixture file's SHA-256, to show the copy-in left it as it was.
    static func secretFileDigest(_ url: URL) -> String {
        let data: Data = (try? Data(contentsOf: url)) ?? Data()
        return SHA256.hash(data: data).map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined()
    }

    /// Opens the copy sheet for `url` as the open panel would, and waits for it.
    static func secretFilePick(_ view: SecretsView, _ url: URL) async -> SecretFileImportSheet? {
        SecretsView.pickedForSelfTest = url
        view.importFromFile()
        _ = await wait(10) { view.fileImportSheet != nil || view.importSheet != nil }
        return view.fileImportSheet
    }

    /// A RAG service's `.env`: three rows, ticked, and four values that aren't keys; Import copies them in under one
    /// Touch ID with origin import; the audit says what was copied; the file is byte for byte as it was; the sheet's
    /// report is released when it closes; Undo… deletes the keys still holding what was copied in and leaves one changed
    /// since.
    static func secretFileImportEnvChecks(_ view: SecretsView, _ presence: StandInPresence, folder: URL) async {
        let store = SecretsStore.shared
        let names: [String] = ["RAG_OPENAI_API_KEY", "RAG_PINECONE_API_KEY", "RAG_LANGSMITH_API_KEY"]
        let values: [String] = [secretsValue("sk-" + "proj-"), secretsValue("pcsk_"), secretsValue("lsv2_" + "pt_")]
        var lines: [String] = zip(names, values).map { (pair: (String, String)) -> String in "\(pair.0)=\(pair.1)" }
        lines += ["LANGSMITH_ENDPOINT=https://api.smith.langchain.com", "OPENAI_MODEL=gpt-5", "CHUNK_SIZE=800",
                  "DATABASE_URL=postgres://rag:${DB_PASS}@db/rag"]
        let project: URL = folder.appendingPathComponent("rag-api", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let env: URL = project.appendingPathComponent(".env")
        try? (lines.joined(separator: "\n") + "\n").write(to: env, atomically: true, encoding: .utf8)
        let before: String = secretFileDigest(env)
        guard let sheet = await secretFilePick(view, env) else {
            return check(false, "secret file import: A File… opens the copy sheet for a .env file")
        }
        let ticked: Bool = sheet.rows.count == 3 && sheet.rows.allSatisfy(\.isTicked)
        let footer: Bool = sheet.footerLabel.stringValue == "4 other values aren\u{2019}t keys."
        check(ticked && sheet.rows.map(\.name) == names && footer,
              "secret file import: a .env file gives three ticked rows and four values that aren't keys",
              "\(sheet.rows.map(\.name)), \(sheet.footerLabel.stringValue)")
        sheet.importButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        check(sheet.confirmAlert?.messageText == "Copy 3 keys into Secrets?", "secret file import: Import… asks first",
              sheet.confirmAlert?.messageText ?? "no confirm")
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { sheet.record != nil }
        let imported: Bool = names.allSatisfy { (name: String) -> Bool in
            store.index?.entry(named: name)?.origin == .import
        }
        check(imported && presence.reasons.last == "copy 3 keys from .env",
              "secret file import: one Touch ID copies the three keys in, with origin import",
              presence.reasons.last ?? "no check")
        let audit: SecretAudit.Line? = SecretAudit.lines(in: store.folder.readAudit()).last
        check(audit?.outcome == "copied 3 keys from a .env file" && secretFileDigest(env) == before,
              "secret file import: the audit says what was copied, and the file is as it was", audit?.outcome ?? "no line")
        let doneLine: String = SecretCopyIn.doneLine(names: names, file: ".env", format: .env, agent: nil) ?? ""
        check(sheet.summaryLabel.stringValue.contains(doneLine),
              "secret file import: the done view says how to start the project", sheet.summaryLabel.stringValue)
        weak var report: SourceReport?
        weak var value: SecretBytes?
        report = sheet.report
        value = sheet.report?.rows.first?.value
        sheet.doneButton.performClick(nil)
        _ = await wait(5) { view.fileImportSheet == nil && value == nil }
        // The value itself, which only wipes when nothing holds it: not the report alone, as the plan held it too.
        check(report == nil && value == nil,
              "secret file import: closing the sheet releases its report and its values, so they are wiped")
        await secretFileImportUndoCheck(view, names: names)
    }
}

extension SelfTest {
    /// Undo… in Recent imports, after one key changed: it asks first, deletes the two still holding what was copied
    /// in, and leaves the changed one, saying why.
    static func secretFileImportUndoCheck(_ view: SecretsView, names: [String]) async {
        let store = SecretsStore.shared
        let changed: String = names[2]
        let replace: SecretsStore.Action = .replace(name: changed, value: SecretBytes(utf8: secretsValue("lsv2_" + "pt_")),
                                                    writeOnly: false, origin: nil)
        _ = try? await store.perform(replace)
        view.reload()
        guard let undo = view.copyInRows.first?.undo else {
            return check(false, "secret file import: Recent imports lists the copy-in, with Undo…")
        }
        undo.performClick(nil)
        _ = await wait(5) { view.alert != nil }
        let asks: Bool = view.alert?.messageText == "Delete 2 keys this import copied in?"
        let says: Bool = view.alert?.informativeText.contains("\(changed) changed since the import") == true
        check(asks && says, "secret file import: Undo… asks first, naming the key it leaves",
              view.alert?.informativeText ?? "no confirm")
        view.alert?.buttons.first?.performClick(nil)
        _ = await wait(15) { store.index?.entry(named: names[0]) == nil }
        let gone: Bool = store.index?.entry(named: names[0]) == nil && store.index?.entry(named: names[1]) == nil
        let left: Bool = store.index?.entry(named: changed) != nil
        check(gone && left && view.actionLabel.stringValue.contains("\(changed) changed since the import, so it stays."),
              "secret file import: Undo deletes the keys copied in and leaves the one changed since",
              view.actionLabel.stringValue)
        _ = try? await store.perform(.delete(name: changed))
    }

    /// A project's `.mcp.json` opens the MCP-config import for that file alone, never the copy sheet.
    static func secretFileImportMoveCheck(_ view: SecretsView, folder: URL) async {
        let project: URL = folder.appendingPathComponent("triage-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config: URL = project.appendingPathComponent(".mcp.json")
        let token: String = secretsValue("ghp_")
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(token)"}}}}"#
        try? text.write(to: config, atomically: true, encoding: .utf8)
        let copy: SecretFileImportSheet? = await secretFilePick(view, config)
        let move: SecretImportSheet? = view.importSheet
        check(copy == nil && move != nil && move?.headerLabel.stringValue.contains(".mcp.json") == true,
              "secret file import: a .mcp.json opens the MCP-config import for that file, not the copy sheet",
              move?.headerLabel.stringValue ?? "no sheet")
        move?.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
    }

    /// A Bitwarden export: the done view offers Move Export to the Trash, ticked. It is unticked before Done here, so
    /// nothing goes to the Trash.
    static func secretFileImportExportCheck(_ view: SecretsView, folder: URL) async {
        let store = SecretsStore.shared
        let name = "LINEAR_SELFTEST_KEY"
        let field = #"{"name": "\#(name)", "value": "\#(secretsValue("lin_" + "api_"))", "type": 1, "linkedId": null}"#
        let item = #"{"id": "00000000-0000-4000-8000-000000000002", "organizationId": null, "folderId": null, "type": 2, "#
            + #""reprompt": 0, "name": "Linear", "notes": null, "favorite": false, "secureNote": {"type": 0}, "#
            + #""fields": ["# + field + "]}"
        let export: URL = folder.appendingPathComponent("bitwarden_export_made_up.json")
        let text: String = #"{"encrypted": false, "folders": [], "items": ["# + item + "]}"
        try? text.write(to: export, atomically: true, encoding: .utf8)
        guard let sheet = await secretFilePick(view, export) else {
            return check(false, "secret file import: a Bitwarden export opens the copy sheet")
        }
        check(sheet.report?.exportedBy == "Bitwarden" && sheet.rows.first?.isTicked == true,
              "secret file import: a Bitwarden export is read as one, its hidden field ticked")
        sheet.importButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { sheet.record != nil }
        let offered: Bool = sheet.trashBox.superview != nil && !sheet.doneStack.isHidden
        check(offered && sheet.trashBox.state == .on,
              "secret file import: after an export, Move Export to the Trash shows, ticked")
        sheet.trashBox.state = .off
        sheet.doneButton.performClick(nil)
        _ = await wait(5) { view.fileImportSheet == nil }
        check(FileManager.default.fileExists(atPath: export.path),
              "secret file import: unticked, the export stays where it was")
        _ = try? await store.perform(.delete(name: name))
    }
}
#endif
