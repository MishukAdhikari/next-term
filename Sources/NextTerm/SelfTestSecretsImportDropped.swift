import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// A wrapped entry drops a variable named like a key in Secrets, since nxtrm secret run would take it out at start
    /// (review finding #18, from its check). On the fixture home of `secretsImportChecks`, GITHUB_TOKEN stored by its
    /// earlier move: the confirm names a value not ticked that goes so, before the write, and the summary names what left
    /// which server. No move here has that name, so both show only when the sheet hands the vault's names to the plan.
    static func secretsImportDroppedChecks(view: SecretsView, home: URL) async {
        let store = SecretsStore.shared
        let gemini = home.appendingPathComponent(".gemini/settings.json")
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        guard store.index?.entry(named: "GITHUB_TOKEN") != nil else {
            return check(false, "secrets: GITHUB_TOKEN is in Secrets for the checks of a variable a wrapped entry drops")
        }
        let dropValue = "selftest-drop-" + secretsValue("")
        let otherValue = "selftest-other-" + secretsValue("")
        let env = "{\"DROP_TOKEN\": \"\(dropValue)\", \"GITHUB_TOKEN\": \"\(otherValue)\", \"LOG_LEVEL\": \"debug\"}"
        let text = "{\"mcpServers\": {\"dropping\": {\"command\": \"srv-dropping\", \"env\": \(env)}}}\n"
        try? FileManager.default.createDirectory(at: gemini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: gemini, atomically: true, encoding: .utf8)
        let backupsBefore: Set<String> = Set(store.recentBackups().map(\.id))
        defer {
            for backup in store.recentBackups() where !backupsBefore.contains(backup.id) { store.removeBackup(backup) }
        }

        view.importKeys()
        guard let sheet = view.importSheet else {
            return check(false, "secrets: Import from MCP Configs… opens its sheet for the checks of a variable a wrapped entry drops")
        }
        _ = await wait(10) { !sheet.groupRows.isEmpty }
        sheet.tick("DROP_TOKEN")
        sheet.moveButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        let warning: String = SecretImport.droppedWarning([(variable: "GITHUB_TOKEN", server: "dropping")]) ?? "none"
        let informative: String = sheet.confirmAlert?.informativeText ?? ""
        check(informative.contains(warning),
              "secrets: before the write, the confirm names a value not ticked that its wrapped entry drops, since a key in Secrets "
                  + "has its name", informative)
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { !sheet.summaryLabel.isHidden }
        let summary: String = sheet.summaryLabel.stringValue
        let line: String = SecretImport.droppedText([(server: "dropping", variables: ["GITHUB_TOKEN"])]) ?? "none"
        let after: String = read(gemini)
        let leftTheFile: Bool = !after.contains(otherValue) && !after.contains(dropValue) && after.contains("LOG_LEVEL")
        check(summary.contains(line) && leftTheFile,
              "secrets: the move takes out a variable named like a key in Secrets from the entry it wraps, and the summary says so",
              summary)
        sheet.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
        _ = try? await store.perform(.delete(name: "DROP_TOKEN"))
    }
}
#endif
