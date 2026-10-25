import AppKit
import NextTermCore

#if DEBUG
/// A stand-in for whether the Claude app runs, which a check flips. The scan and the plan read it off the main thread.
final class SelfTestOpenApp: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}

extension SelfTest {
    /// Whether the Claude app runs is asked again when Move plans, not kept from the scan (review finding #17). On the
    /// fixture home of `secretsImportChecks`: the Claude app's file is scanned while the app is closed, the app opens
    /// before Move, and the move leaves the file as it is, stores no key and asks no Touch ID.
    static func secretsImportOpenAppChecks(view: SecretsView, home: URL) async {
        let store = SecretsStore.shared
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let file = library.appendingPathComponent("Application Support/Claude/claude_desktop_config.json")
        let value = "selftest-app-" + secretsValue("")
        let text = "{\"mcpServers\": {\"app\": {\"command\": \"srv-app\", \"env\": {\"APP_TOKEN\": \"\(value)\"}}}}\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let app = SelfTestOpenApp()
        let saved = SecretsView.importSetup
        var setup = saved()
        setup.isOpen = { [app] bundle in bundle == MCPRegistrar.claudeAppBundle && app.isOpen }
        SecretsView.importSetup = { setup }
        defer {
            SecretsView.importSetup = saved
            try? FileManager.default.removeItem(at: library)
        }

        view.importKeys()
        guard let sheet = view.importSheet else {
            return check(false, "secrets: Import from MCP Configs… opens its sheet for the check of the Claude app opened after the scan")
        }
        let listed = await wait(10) { sheet.groupRows.contains { $0.group.name == "APP_TOKEN" } }
        sheet.tick("APP_TOKEN")
        app.isOpen = true
        let presence = store.presence as? StandInPresence
        let asked = presence?.calls ?? 0
        sheet.moveButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { !sheet.summaryLabel.isHidden }
        let result: String = sheet.groupRows.first { $0.group.name == "APP_TOKEN" }?.result.stringValue ?? ""
        let after: String = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let noKey: Bool = store.index?.entry(named: "APP_TOKEN") == nil && presence?.calls == asked
        check(listed && result.contains(SecretImport.claudeAppOpenReason) && after == text && noKey,
              "secrets: with the Claude app opened after the scan, Move leaves its file, stores no key and asks no Touch ID", result)
        sheet.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
    }
}
#endif
