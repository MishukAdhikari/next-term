import AppKit
import NextTermCore

#if DEBUG
/// `nxtrm secret import` run by an agent or from no tab, given a FILE, refused while Secrets is busy; a password
/// manager's sheet with agent control off; and a password prompt with echo off in a tab, as `bw unlock`'s is. All on
/// the self-test's own socket, vault and files; values are made up at run time.
extension SelfTest {
    /// Run by an agent (a copy of zsh named claude runs the pipe), the sheet warns the agent may have seen the keys.
    /// Run from no tab (the pipe leaves its tab, as `( … &)` does), it says Next Term couldn't tell which tab.
    static func secretPipeOriginChecks(_ c: TerminalWindowController, _ view: SecretsView, folder: URL, list: URL) async {
        let bin: URL = folder.appendingPathComponent("agent-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent: URL = bin.appendingPathComponent("claude")
        try? FileManager.default.removeItem(at: agent)
        let tab: TerminalTab = await secretPipeTab(c, folder)
        defer { closeSecretsTabs([tab], "secret pipe") }
        let pipe: String = "cat \(secretPipeQuoted(list.path)) | \(secretPipeNxtrm) secret import --from bws -"
        if (try? FileManager.default.copyItem(atPath: "/bin/zsh", toPath: agent.path)) != nil {
            // `; true` keeps the stand-in agent above the importer: zsh would run a line's last command in its place.
            let run: String = "\(secretPipeQuoted(agent.path)) -fc \(secretPipeQuoted(pipe + "; true"))"
            MCPControl.type(run, into: tab, submit: true)
            let opened: Bool = await wait(15) { view.fileImportSheet?.isPiped == true }
            let warning: String? = secretPipeWarning(view.fileImportSheet)
            check(opened && warning == SecretImportPipe.agentWarning,
                  "secret pipe: run by an agent, the sheet warns it may have seen the keys", warning ?? "no warning")
            view.fileImportSheet?.closeSheet()
            _ = await wait(10) { secretPipeScreen(tab).contains("Nothing imported.") && !tab.status.running }
        } else {
            note("secret pipe: no copy of zsh to stand in for an agent, so the agent warning check is skipped")
        }
        tab.view.send(txt: "clear\r")
        _ = await wait(5) { !secretPipeScreen(tab).contains("Nothing imported.") }
        let late: String = "(sleep 1; cat \(secretPipeQuoted(list.path)))"
        let away: String = "( \(late) | \(secretPipeNxtrm) secret import --from bws - & )"
        MCPControl.type(away, into: tab, submit: true)
        let opened: Bool = await wait(15) { view.fileImportSheet?.isPiped == true }
        let header: String = view.fileImportSheet?.headerLabel.stringValue ?? ""
        let warning: String? = secretPipeWarning(view.fileImportSheet)
        check(opened && warning == SecretImportPipe.untracedWarning && !header.contains(" in tab "),
              "secret pipe: run from no tab Next Term knows, the sheet says it couldn't tell which tab", header)
        view.fileImportSheet?.closeSheet()
        _ = await wait(10) { view.fileImportSheet == nil && secretPipeScreen(tab).contains("Nothing imported.") }
    }

    /// `nxtrm secret import FILE`: a made-up .env opens the copy sheet, its header saying the import gave it, and
    /// Cancel prints Nothing imported. With another sheet open on Secrets it prints the busy line and opens nothing. An
    /// agent's MCP config opens the MCP-config import, and the tab says so.
    static func secretPipeFileChecks(_ c: TerminalWindowController, _ view: SecretsView, folder: URL) async {
        let savedSetup = SecretsView.importSetup
        var setup = SecretImportSheet.Setup()
        setup.home = folder.appendingPathComponent("home", isDirectory: true).path
        setup.nxtrm = ["nxtrm"]
        let fixed: SecretImportSheet.Setup = setup
        SecretsView.importSetup = { fixed }
        defer { SecretsView.importSetup = savedSetup }
        let env: URL = folder.appendingPathComponent("pipe-file.env")
        try? "PIPE_FILE_API_KEY=\(secretsValue("sk-" + "proj-"))\n".write(to: env, atomically: true, encoding: .utf8)
        let tab: TerminalTab = await secretPipeTab(c, folder)
        defer { closeSecretsTabs([tab], "secret pipe") }
        let given: String = "\(secretPipeNxtrm) secret import \(secretPipeQuoted(env.path))"
        MCPControl.type(given, into: tab, submit: true)
        let opened: Bool = await wait(15) { view.fileImportSheet != nil }
        let header: String = view.fileImportSheet?.headerLabel.stringValue ?? ""
        check(opened && view.fileImportSheet?.isPiped == false && header.contains("Given by nxtrm secret import in"),
              "secret pipe: nxtrm secret import FILE opens the copy sheet, saying the import gave it", header)
        view.fileImportSheet?.closeSheet()
        let nothing: Bool = await wait(10) { secretPipeScreen(tab).contains("Nothing imported.") && !tab.status.running }
        check(nothing, "secret pipe: Cancel prints Nothing imported in the FILE's tab", secretPipeScreen(tab))
        await secretPipeBusyCheck(view, tab, given: given)
        let project: URL = folder.appendingPathComponent("pipe-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config: URL = project.appendingPathComponent(".mcp.json")
        let token: String = secretsValue("ghp_")
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(token)"}}}}"#
        try? text.write(to: config, atomically: true, encoding: .utf8)
        tab.view.send(txt: "clear\r")
        await pause(0.5)
        MCPControl.type("\(secretPipeNxtrm) secret import \(secretPipeQuoted(config.path))", into: tab, submit: true)
        let moved: Bool = await wait(15) { view.importSheet != nil }
        let said: Bool = await wait(10) { secretPipeShows(tab, SecretImportPipe.text(.moved).line) }
        check(moved && said && view.fileImportSheet == nil,
              "secret pipe: an agent's MCP config given to it opens the MCP-config import, and the tab says so",
              secretPipeScreen(tab))
        view.importSheet?.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
    }
}

extension SelfTest {
    /// With a password manager's sheet open on Secrets, `given` prints the busy line, opens no sheet, and Secrets says
    /// why under its list.
    static func secretPipeBusyCheck(_ view: SecretsView, _ tab: TerminalTab, given: String) async {
        tab.view.send(txt: "clear\r")
        await pause(0.5)
        let item = NSMenuItem()
        item.representedObject = SecretImportPreset.bws.rawValue
        view.importFromManager(item)
        guard let sheet = view.managerSheet else {
            return check(false, "secret pipe: bws's sheet opens, for the busy check")
        }
        MCPControl.type(given, into: tab, submit: true)
        let busy: String = SecretImportPipe.text(.busy).line
        let said: Bool = await wait(10) { secretPipeShows(tab, busy) && !tab.status.running }
        check(said && view.fileImportSheet == nil && view.actionLabel.stringValue == SecretPipeImport.busyLine,
              "secret pipe: with another sheet open, nxtrm secret import says Secrets is busy and opens nothing",
              secretPipeScreen(tab))
        sheet.cancelButton.performClick(nil)
        _ = await wait(5) { view.managerSheet == nil }
    }

    /// With "Let agents control Next Term" off, a password manager's sheet says to turn it on and offers no tab.
    static func secretPipeSheetOffCheck(_ view: SecretsView) async {
        SecretsView.agentControlIsOn = { false }
        defer { SecretsView.agentControlIsOn = { AppDelegate.shared.agentControl } }
        let item = NSMenuItem()
        item.representedObject = SecretImportPreset.onePassword.rawValue
        view.importFromManager(item)
        let sheet: SecretManagerImportSheet? = view.managerSheet
        let off: Bool = sheet?.offLabel.isHidden == false && sheet?.openButton.isHidden == true
        check(off && sheet?.offLabel.stringValue == SecretManagerImportSheet.agentControlOff,
              "secret pipe: with agent control off, a password manager's sheet says to turn it on and offers no tab",
              sheet?.offLabel.stringValue ?? "no sheet")
        sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.managerSheet == nil }
    }

    /// A stand-in password prompt (sh reading a line with echo off), as bw unlock's is: the keys typed go to it unseen,
    /// command suggestions and Tab completion stay off while it has the line, and nothing records what was typed.
    static func secretPipePasswordPromptCheck(_ c: TerminalWindowController, folder: URL) async {
        let tab: TerminalTab = await secretPipeTab(c, folder)
        defer { closeSecretsTabs([tab], "secret pipe") }
        let prompt: String = "/bin/sh -c 'stty -echo; IFS= read -r answer; stty echo; echo \"read ${#answer}\"'"
        MCPControl.type(prompt, into: tab, submit: true)
        _ = await wait(5) { tab.status.running }
        await pause(0.5)
        guard await focus(c, tab, for: "secret pipe: a password prompt"), let window = c.window else { return }
        let typed: String = "madeupmasterpass"
        typeKeys(window, typed)
        pressKey(window, "\t", code: 48)
        await pause(0.8)
        let off: Bool = !CommandSuggestionController.mayAsk(tab) && CommandSuggestionPanel.current == nil
        let noList: Bool = tab.completion.list == nil
        pressKey(window, "\r", code: 36)
        let read: Bool = await wait(5) { secretPipeScreen(tab).contains("read \(typed.count + 1)") }
        let unseen: Bool = !secretPipeScreen(tab).contains(typed) && !tab.status.command.contains(typed)
        check(off && noList && read && unseen,
              "secret pipe: a password prompt with echo off gets the keys unseen, with suggestions and completion off",
              "suggestions off \(off), no list \(noList), read \(read), unseen \(unseen)")
    }
}
#endif
