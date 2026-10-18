import AppKit
import NextTermCore

#if DEBUG
/// An import asked for while another sheet is open on Secrets (Add… here) opens nothing, now or later, and whoever
/// asked hears busy: `nxtrm secret import`'s importer and an agent's import_secrets request once their file is read,
/// and an MCP config given to `nxtrm secret import`, which the MCP-config import would take. The files are made up in
/// the self-test's folder, with values made up at run time; no importer runs and nothing is typed into a tab.
extension SelfTest {
    static func secretBusyOpenChecks(_ view: SecretsView, folder: URL) async {
        let savedSetup = SecretsView.importSetup
        var setup = SecretImportSheet.Setup()
        setup.home = folder.appendingPathComponent("home", isDirectory: true).path
        setup.nxtrm = ["nxtrm"]
        let fixed: SecretImportSheet.Setup = setup
        SecretsView.importSetup = { fixed }
        defer { SecretsView.importSetup = savedSetup }
        let env: URL = folder.appendingPathComponent("busy-open.env")
        try? "BUSY_OPEN_API_KEY=\(secretsValue("sk-" + "proj-"))\n".write(to: env, atomically: true, encoding: .utf8)
        let project: URL = folder.appendingPathComponent("busy-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config: URL = project.appendingPathComponent(".mcp.json")
        let token: String = secretsValue("ghp_")
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(token)"}}}}"#
        try? text.write(to: config, atomically: true, encoding: .utf8)
        view.add()
        guard let add = view.sheet else { return check(false, "secret busy open: Add… opens, for the busy checks") }
        let report: SourceReport = SecretSources.readFile(env.path)
        secretBusyClientCheck(view, path: env.path, report: report)
        secretBusyAskedCheck(view, path: env.path, report: report)
        await secretBusyMoveCheck(view, config: config)
        add.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        // A sheet begun on a window that shows one waits, unseen, until that one ends: none may come up now.
        let queued: Bool = await wait(2) { view.window?.attachedSheet != nil }
        check(!queued && view.fileImportSheet == nil && view.importSheet == nil,
              "secret busy open: once Add… closes, no import sheet comes up from behind it",
              view.window?.attachedSheet?.title ?? "none")
    }

    /// An importer that is told nothing but what the sheet would tell it: no socket behind it.
    static func secretBusyClient() -> SecretImportClient {
        SecretImportClient(origin: SecretPipeImport.Origin(piped: false), channel: SecretPipeSocket.Channel(fd: -1))
    }

    /// `nxtrm secret import FILE`'s importer, once its file is read: busy, and the copy sheet doesn't open.
    static func secretBusyClientCheck(_ view: SecretsView, path: String, report: SourceReport) {
        let client: SecretImportClient = secretBusyClient()
        view.say("")
        view.openFileImport(path: path, report: report, inGit: false, client: client)
        let said: String = view.actionLabel.stringValue
        check(client.hasEnded && view.fileImportSheet == nil && said == SecretPipeImport.busyLine,
              "secret busy open: with Add… open, nxtrm secret import FILE opens nothing and its importer hears busy",
              said)
    }

    /// An agent's import_secrets request, once its file is read: busy, and the copy sheet doesn't open.
    static func secretBusyAskedCheck(_ view: SecretsView, path: String, report: SourceReport) {
        let asked = SecretImportAsk(target: .file(path), banner: "A made-up agent asks to import keys.",
                                    askedBy: "a made-up agent", command: "import_secrets")
        view.say("")
        view.openFileImport(path: path, report: report, inGit: false, asked: asked)
        let said: String = view.actionLabel.stringValue
        check(asked.hasEnded && view.fileImportSheet == nil && said == SecretImportAsk.busyLine,
              "secret busy open: with Add… open, an agent's import_secrets opens nothing and hears busy", said)
    }

    /// An agent's MCP config given to `nxtrm secret import`, read while Add… is open: busy, and the MCP-config import
    /// doesn't open.
    static func secretBusyMoveCheck(_ view: SecretsView, config: URL) async {
        // Read as the list reads it: a move target, so the check below is the move's, not a copy's.
        let setup: SecretImportSheet.Setup = SecretsView.importSetup()
        let picked = SecretSources.readPicked(config.path, home: setup.home, projects: setup.projects)
        guard case .move = picked else {
            return check(false, "secret busy open: the made-up MCP config is one the MCP-config import takes")
        }
        let client: SecretImportClient = secretBusyClient()
        view.say("")
        view.readPicked(config, client: client)
        let ended: Bool = await wait(10) { client.hasEnded }
        let said: String = view.actionLabel.stringValue
        check(ended && view.importSheet == nil && said == SecretPipeImport.busyLine,
              "secret busy open: with Add… open, an MCP config given to nxtrm opens nothing and hears busy",
              said)
    }
}
#endif
