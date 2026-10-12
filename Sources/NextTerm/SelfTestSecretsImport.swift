import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// What the import sheet says when a move or a scan doesn't go as planned, on the fixture home of
    /// `secretsImportChecks` (its files as they were, the token stored under GITHUB_TOKEN): a move that changes no file
    /// doesn't leave the sheet waiting for Touch ID (K4 problem 2); a file it couldn't check is listed, and the sheet
    /// never says no keys were found (review finding 16, K4 problem 3).
    static func secretsImportReportChecks(view: SecretsView, home: URL, token: String, cursorText: String, codexText: String) async {
        let fm = FileManager.default
        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        let codex = home.appendingPathComponent(".codex/config.toml")
        let gemini = home.appendingPathComponent(".gemini/settings.json")
        defer {
            try? cursorText.write(to: cursor, atomically: true, encoding: .utf8)
            try? codexText.write(to: codex, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: gemini.deletingLastPathComponent())
        }

        // The key ticked, then rotated in both files before Move: both are left, no Touch ID is asked, and the line above
        // the rows doesn't wait for one (K4 problem 2).
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        view.importKeys()
        guard let refused = view.importSheet else { return check(false, "secrets: Import from MCP Configs… opens its sheet again") }
        _ = await wait(10) { !refused.groupRows.isEmpty }
        let name = refused.groupRows.first?.group.name ?? ""
        refused.tick(name)
        let rotated = "ghp_" + "Rotated" + secretsValue("")
        let cursorRotated = cursorText.replacingOccurrences(of: token, with: rotated)
        let codexRotated = codexText.replacingOccurrences(of: token, with: rotated)
        try? cursorRotated.write(to: cursor, atomically: true, encoding: .utf8)
        try? codexRotated.write(to: codex, atomically: true, encoding: .utf8)
        let presence = SecretsStore.shared.presence as? StandInPresence
        let asked = presence?.calls ?? 0
        refused.moveButton.performClick(nil)
        _ = await wait(5) { refused.confirmAlert != nil }
        refused.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { !refused.summaryLabel.isHidden }
        let result = refused.groupRows.first?.result.stringValue ?? ""
        check(name == "GITHUB_TOKEN_2" && refused.summaryLabel.stringValue.hasPrefix("Moved 0 keys from 0 files.")
              && result.contains("GITHUB_TOKEN changed since the scan") && read(cursor) == cursorRotated && read(codex) == codexRotated
              && presence?.calls == asked && SecretsStore.shared.index?.entry(named: name) == nil,
              "secrets: a key rotated in its files after the scan is left in both, with no Touch ID and nothing saved", result)
        check(refused.statusLabel.isHidden && refused.statusLabel.stringValue != SecretImportSheet.touchIDLine,
              "secrets: after a move that changed no file, the sheet doesn't wait for Touch ID", refused.statusLabel.stringValue)
        refused.closeSheet()
        _ = await wait(5) { view.importSheet == nil }

        // No key anywhere, and one file that is not JSON: listed as not checked, and no "No keys … were found".
        try? fm.createDirectory(at: gemini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{\"mcpServers\": ".write(to: gemini, atomically: true, encoding: .utf8)
        try? "{\"mcpServers\": {}}\n".write(to: cursor, atomically: true, encoding: .utf8)
        try? "model = \"gpt-5\"\n".write(to: codex, atomically: true, encoding: .utf8)
        view.importKeys()
        guard let unchecked = view.importSheet else { return check(false, "secrets: Import from MCP Configs… opens its sheet again") }
        _ = await wait(10) { unchecked.scan != nil }
        let row = unchecked.listed.first { $0.contains(".gemini/settings.json") }
        let status = unchecked.statusLabel.stringValue
        check(row?.contains("\(SecretImportSheet.notChecked) (not JSON Next Term can read)") == true && unchecked.groupRows.isEmpty
              && status != SecretImportSheet.noKeysLine && status.contains("1 file couldn't be checked for keys"),
              "secrets: a file the import couldn't read is listed as not checked, and the sheet doesn't say no keys were found",
              "\(status) | \(unchecked.listed)")
        unchecked.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
    }
}
#endif
