import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// What the import sheet says when a move or a scan doesn't go as planned, on the fixture home of
    /// `secretsImportChecks` (its files as they were, the token stored under GITHUB_TOKEN): a file it couldn't check is
    /// listed, and the sheet never says no keys were found (review finding 16, K4 problem 3).
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
