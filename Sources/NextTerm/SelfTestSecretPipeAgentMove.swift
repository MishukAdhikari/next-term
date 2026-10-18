import AppKit
import NextTermCore

#if DEBUG
/// `nxtrm secret import` of an MCP config, run by an agent or by a process no tab of Next Term's is above: moving keys
/// out of the file rewrites it, so only the user starts that, and the run is refused before anything opens or comes
/// forward. On the self-test's own socket, vault and files; the config, its server and its key are made up at run time.
extension SelfTest {
    /// A link named claude to /bin/zsh stands in for the agent, as in the origin checks; a run that leaves its tab, as
    /// `( … & )` makes it, is the untraced one. Each run is checked in a tab of its own.
    static func secretPipeAgentMoveCheck(_ c: TerminalWindowController, _ view: SecretsView, folder: URL) async {
        let savedSetup = SecretsView.importSetup
        var setup = SecretImportSheet.Setup()
        setup.home = folder.appendingPathComponent("home", isDirectory: true).path
        setup.nxtrm = ["nxtrm"]
        let fixed: SecretImportSheet.Setup = setup
        SecretsView.importSetup = { fixed }
        defer { SecretsView.importSetup = savedSetup }
        let project: URL = folder.appendingPathComponent("pipe-agent-move", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config: URL = project.appendingPathComponent(".mcp.json")
        let value: String = "made-up-value-" + UUID().uuidString.lowercased()
        let server: String = #"{"command": "made-up-server", "env": {"MADE_UP_TOKEN": "\#(value)"}}"#
        let written: String = #"{"mcpServers": {"made-up": \#(server)}}"#
        try? written.write(to: config, atomically: true, encoding: .utf8)
        let given: String = "\(secretPipeNxtrm) secret import \(secretPipeQuoted(config.path))"
        if let agent = secretPipeAgentLink(folder) {
            // `; true` keeps the stand-in agent above the importer: zsh would run a line's last command in its place.
            let run: String = "\(secretPipeQuoted(agent.path)) -fc \(secretPipeQuoted(given + "; true"))"
            await secretPipeMoveRefusedCheck(c, view, folder: folder, run: run, config: config, written: written,
                                             who: "an agent's nxtrm secret import")
        } else {
            note("secret pipe: no link to zsh to stand in for an agent, so the agent's MCP config check is skipped")
        }
        // The importer starts a second after the subshell around it has ended, so no tab of Next Term's is above it.
        let away: String = "( ( sleep 1; \(given) ) & )"
        await secretPipeMoveRefusedCheck(c, view, folder: folder, run: away, config: config, written: written,
                                         who: "nxtrm secret import run from no tab Next Term knows")
    }

    /// `run`, typed into a new tab, prints the refusal; no sheet opens on Secrets, Secrets stays behind a cover window
    /// of the self-test's own, the cover keeps the keyboard, and the config is as `written`.
    static func secretPipeMoveRefusedCheck(_ c: TerminalWindowController, _ view: SecretsView, folder: URL, run: String,
                                           config: URL, written: String, who: String) async {
        let tab: TerminalTab = await secretPipeTab(c, folder)
        defer { closeSecretsTabs([tab], "secret pipe") }
        let cover: NSWindow = await secretsMenuCover()
        defer { cover.close() }
        MCPControl.type(run, into: tab, submit: true)
        let refusal: String = SecretImportPipe.text(.moveRefused).line
        let said: Bool = await wait(15) { secretPipeShows(tab, refusal) && !tab.status.running }
        // A sheet or a window coming forward late would show by now.
        await pause(0.5)
        let noSheet: Bool = view.importSheet == nil && view.fileImportSheet == nil && view.window?.attachedSheet == nil
        let behind: Bool = secretPipeBehind(view.window, cover: cover)
        let kept: Bool = (try? String(contentsOf: config, encoding: .utf8)) == written
        let detail: String = "refusal said \(said), no sheet \(noSheet), Secrets behind the cover \(behind), cover key "
            + "\(NSApp.keyWindow === cover), file unchanged \(kept)"
        check(said && noSheet && behind && kept,
              "secret pipe: \(who) of an MCP config is refused with the line, nothing opens, the keyboard stays where "
                + "it was, and the file is unchanged", said ? detail : detail + ": " + secretPipeScreen(tab))
    }

    /// The agent stand-in: a link named claude to /bin/zsh (a copy of zsh is a platform binary off the system volume,
    /// which launch constraints kill as it starts); nil when it can't be made.
    static func secretPipeAgentLink(_ folder: URL) -> URL? {
        let bin: URL = folder.appendingPathComponent("agent-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent: URL = bin.appendingPathComponent("claude")
        try? FileManager.default.removeItem(at: agent)
        let link: Void? = try? FileManager.default.createSymbolicLink(atPath: agent.path, withDestinationPath: "/bin/zsh")
        return link == nil ? nil : agent
    }

    /// `window` stayed behind `cover`, which kept the keyboard.
    static func secretPipeBehind(_ window: NSWindow?, cover: NSWindow) -> Bool {
        guard let window else { return false }
        let behind: Bool = !window.isVisible || window.orderedIndex > cover.orderedIndex
        return behind && NSApp.keyWindow === cover && !window.isKeyWindow
    }
}
#endif
