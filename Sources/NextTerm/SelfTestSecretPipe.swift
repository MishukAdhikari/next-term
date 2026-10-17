import AppKit
import NextTermCore

#if DEBUG
/// `nxtrm secret import` and Import From's password managers, on the self-test's own socket and temporary vault. No
/// password manager's CLI ever runs: each preset's line is typed, read back unrun, and its tab closed; the pipe check
/// pipes a made-up `bws` list from a file with cat. Values are made up at run time, and never typed on a tab's line.
extension SelfTest {
    static func secretPipeChecks(_ c: TerminalWindowController, base: URL) async {
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible else {
            return check(false, "secret pipe: Window › Secrets opens its window")
        }
        defer { window.close() }
        let folder: URL = base.appendingPathComponent("pipe-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = controller.secretsView
        let titles: [String] = view.importMenuButton.itemTitles
        let managers: [String] = SecretImportPreset.allCases.map(SecretsView.managerItemTitle)
        let listed: Bool = managers.allSatisfy { (title: String) -> Bool in titles.contains(title) }
        check(listed, "secret pipe: Import From lists 1Password…, Bitwarden… and Bitwarden Secrets Manager…", "\(titles)")
        let values: [String] = [secretsValue("sk-" + "proj-"), secretsValue("pcsk_")]
        let list: URL = folder.appendingPathComponent("bws-list.json")
        try? Data(secretPipeList(values).utf8).write(to: list)
        for preset in SecretImportPreset.allCases { await secretPresetChecks(view, preset, list: list) }
        await secretPipeImportCheck(c, view, list: list, folder: folder, values: values)
        await secretPipeEagerCheck(view, list: list, mode: "1")
        await secretPipeEagerCheck(view, list: list, mode: "pause")
        await secretPipeStrangerCheck(view)
        await secretPipeDoneChecks(c, view, folder: folder)
        await secretPipeOriginChecks(c, view, folder: folder, list: list)
        await secretPipeFileChecks(c, view, folder: folder)
        await secretPipeSheetOffCheck(view)
        await secretPipePasswordPromptCheck(c, folder: folder)
    }

    /// A made-up `bws secret list --output json` with two secrets.
    static func secretPipeList(_ values: [String]) -> String {
        let names: [String] = ["PIPE_OPENAI_API_KEY", "PIPE_PINECONE_API_KEY"]
        let items: [String] = zip(names, values).map { (pair: (String, String)) -> String in
            "{\"object\":\"secret\",\"id\":\"\(UUID().uuidString.lowercased())\",\"organizationId\":\"made-up-org\","
                + "\"projectId\":\"made-up-project\",\"key\":\"\(pair.0)\",\"value\":\"\(pair.1)\",\"note\":\"\"}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// A tool called in this process, as the socket calls it, with no caller tab.
    static func secretPipeTool(_ name: String, _ arguments: [String: Any]) async -> MCPServer.CallResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MCPServer.CallResult, Never>) in
            MCPControl.call(name, arguments, caller: nil) { (result: MCPServer.CallResult) in continuation.resume(returning: result) }
        }
    }

    /// The tab's rows as read_tab reads them, unmasked, joined with nothing between them so a wrap can't split a word.
    static func secretPipeScreen(_ tab: TerminalTab) -> String {
        tab.screenTail(200).joined()
    }

    /// The tab's screen as an agent's read_tab gets it.
    static func secretPipeReadTab(_ tab: TerminalTab) async -> String {
        let read = await secretPipeTool("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": 20])
        let answer = (try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any]
        return answer?["screen"] as? String ?? read.text
    }

    /// Whether `screen` ends with `line`, as typed and nothing after it: spaces and row breaks aside, since a wrap
    /// breaks a row where the terminal's width says and read_tab trims each row's end.
    static func secretPipeEndsWith(_ screen: String, _ line: String) -> Bool {
        let bare: (String) -> String = { (text: String) -> String in text.filter { !$0.isWhitespace } }
        return !line.isEmpty && bare(screen).hasSuffix(bare(line))
    }

    /// The sheet shows the preset's line; Open in a New Tab types it into a new tab titled for it, with no Return; and
    /// send_to_tab, press_keys, answer_agent and close_tab refuse that tab until it closes.
    static func secretPresetChecks(_ view: SecretsView, _ preset: SecretImportPreset, list: URL) async {
        let item = NSMenuItem()
        item.representedObject = preset.rawValue
        view.importFromManager(item)
        guard let sheet = view.managerSheet else { return check(false, "secret pipe: \(preset.app)… opens its sheet") }
        let expected: String? = SecretManagerImportSheet.line(preset, shell: SecretManagerImportSheet.newTabShell)
        check(expected != nil && sheet.commandField.stringValue == expected && !sheet.openButton.isHidden,
              "secret pipe: \(preset.app)…'s sheet shows its line and Open in a New Tab", sheet.commandField.stringValue)
        let before: Set<UUID> = Set(AppDelegate.shared.controllers.flatMap(\.tabs).map(\.id))
        sheet.openButton.performClick(nil)
        let isNew: (TerminalTab) -> Bool = { (tab: TerminalTab) -> Bool in
            !before.contains(tab.id) && tab.userTitle == preset.tabTitle
        }
        let found: Bool = await wait(10) { AppDelegate.shared.controllers.flatMap(\.tabs).contains(where: isNew) }
        let tabs: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs)
        guard found, let tab = tabs.first(where: isNew) else {
            return check(false, "secret pipe: Open in a New Tab opens a tab titled \(preset.tabTitle)")
        }
        defer { closeSecretsTabs([tab], "secret pipe") }
        let tail: String = "secret import --from \(preset.format.rawValue) -"
        _ = await wait(10) { tab.status.integrated }
        _ = await wait(8) { secretPipeScreen(tab).contains(tail) }
        await pause(1)
        let typed: String = SecretManagerImportSheet.line(preset, shell: SecretsMCP.shellName(of: tab)) ?? ""
        let screen: String = await secretPipeReadTab(tab)
        check(secretPipeEndsWith(screen, typed) && tab.status.commandsRun == 0 && !tab.status.running,
              "secret pipe: \(preset.app)'s tab, read with read_tab, ends with exactly its line, not run", screen)
        check(view.managerSheet == nil && tab.directory == NSHomeDirectory(),
              "secret pipe: the sheet goes, and the tab is in the home folder", tab.directory)
        check(view.actionLabel.stringValue == SecretManagerImportSheet.typedLine,
              "secret pipe: the list says the line is in the tab once it is typed", view.actionLabel.stringValue)
        await secretPresetRefusalChecks(tab, preset)
        if preset == .bws { await secretPresetAfterPipeChecks(view, tab, list: list) }
    }

    /// Agents can't type into a preset's tab, press its keys, answer in it or close it: before its Return, and after
    /// a pipe in it ended (`afterPipe`), until it closes.
    static func secretPresetRefusalChecks(_ tab: TerminalTab, _ preset: SecretImportPreset, afterPipe: Bool = false) async {
        let id: String = tab.id.uuidString.lowercased()
        let typed = await secretPipeTool("send_to_tab", ["tab_id": id, "text": "echo made-up"])
        let pressed = await secretPipeTool("press_keys", ["tab_id": id, "keys": ["enter"]])
        let answered = await secretPipeTool("answer_agent", ["tab_id": id, "question_id": "made-up", "choice": 1])
        let closed = await secretPipeTool("close_tab", ["tab_id": id, "force": true])
        let results: [MCPServer.CallResult] = [typed, pressed, answered, closed]
        let refused: Bool = results.allSatisfy { (result: MCPServer.CallResult) -> Bool in
            result.isError && result.text.contains("Import from \(preset.app)")
        }
        let open: Bool = AppDelegate.shared.controllers.flatMap(\.tabs).contains { $0 === tab }
        let held: Bool = afterPipe || tab.status.commandsRun == 0
        let when: String = afterPipe ? "after its pipe ended" : "before its Return"
        check(refused && open && held,
              "secret pipe: send_to_tab, press_keys, answer_agent and close_tab refuse \(preset.app)'s tab \(when)",
              results.map(\.text).joined(separator: " / "))
    }

    /// `cat list | nxtrm secret import --from bws -` in a tab opens the copy sheet with the list's two keys, named for
    /// the pipe; the tab says how many were found and, once the sheet is cancelled, that nothing was imported, and never
    /// shows a value. Typed with a terminal on standard input, it prints its usage and exits 2.
    static func secretPipeImportCheck(_ c: TerminalWindowController, _ view: SecretsView, list: URL, folder: URL,
                                      values: [String]) async {
        let tab: TerminalTab = c.addTab(directory: folder.path, select: false)
        defer { closeSecretsTabs([tab], "secret pipe") }
        _ = await wait(10) { tab.status.integrated }
        let nxtrm: String = SecretManagerImportSheet.nxtrmWords.map(secretPipeQuoted).joined(separator: " ")
        MCPControl.type("cat \(secretPipeQuoted(list.path)) | \(nxtrm) secret import --from bws -", into: tab, submit: true)
        let opened: Bool = await wait(15) { view.fileImportSheet?.isPiped == true }
        let sheet: SecretFileImportSheet? = view.fileImportSheet
        let header: String = sheet?.headerLabel.stringValue ?? ""
        let rows: Int = sheet?.report?.rows.count ?? 0
        check(opened && rows == 2 && header.contains("piped into nxtrm secret import"),
              "secret pipe: a piped bws list opens the copy sheet with its keys", "\(rows) rows; \(header)")
        _ = await wait(5) { secretPipeScreen(tab).contains("2 keys found") }
        sheet?.closeSheet()
        _ = await wait(10) { secretPipeScreen(tab).contains("Nothing imported.") }
        let screen: String = secretPipeScreen(tab)
        let leaked: Bool = values.contains { (value: String) -> Bool in screen.contains(value) || screen.contains(String(value.suffix(4))) }
        check(screen.contains(SecretImportPipe.text(.found(2)).line) && screen.contains("Nothing imported.") && !leaked,
              "secret pipe: the tab says only how many keys were found and that none were imported", screen)
        check(view.fileImportSheet == nil && SecretsStore.shared.index?.entry(named: "PIPE_OPENAI_API_KEY") == nil,
              "secret pipe: Cancel closes the sheet and stores nothing")
        MCPControl.type("\(nxtrm) secret import; echo \"exit=$?\"", into: tab, submit: true)
        _ = await wait(10) { secretPipeScreen(tab).contains("exit=2") }
        let usage: String = secretPipeScreen(tab)
        check(usage.contains(SecretImportPipe.usage) && usage.contains("exit=2") && view.fileImportSheet == nil,
              "secret pipe: with a terminal on standard input it prints its usage and exits 2", usage)
    }

    static func secretPipeQuoted(_ word: String) -> String {
        SecretRun.typedLine([word], shell: "zsh") ?? word
    }

    /// Next Term's own importer that sends its keys before `ready`: refused, and no sheet opens. With `mode` "1" they
    /// follow the header at once, and one read of the socket's line reader may take both (only the route could keep
    /// them out: the importer is refused as it reads `ready` as one). With "pause" they come 50 ms after it, apart, and
    /// the app sees them waiting: the audit names that.
    static func secretPipeEagerCheck(_ view: SecretsView, list: URL, mode: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--cli", "secret", "import", "--from", "bws", "-"]
        var environment: [String: String] = ProcessInfo.processInfo.environment
        environment[MCPServer.socketVariable] = MCPControlServer.shared.path
        environment[SecretPipe.eagerVariable] = mode
        process.environment = environment
        process.standardInput = FileHandle(forReadingAtPath: list.path)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return check(false, "secret pipe: the eager importer starts") }
        let ended: Bool = await wait(20) { !process.isRunning }
        if !ended { process.terminate() }
        let said: String = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(ended && process.terminationStatus == 1 && said.contains(SecretImportPipe.text(.refused).line)
                  && view.fileImportSheet == nil,
              "secret pipe: keys sent before Next Term is ready for them (\(mode)) are refused, and no sheet opens", said)
        guard mode == "pause" else { return }
        let pid: Int32 = process.processIdentifier
        let refusedEarly: () -> Bool = {
            SecretAudit.lines(in: SecretsStore.shared.folder.readAudit()).contains { (line: SecretAudit.Line) -> Bool in
                let who: String = line.who ?? ""
                let early: Bool = line.outcome == SecretPipeSocket.earlyReason
                return line.event == .refused && early && who.hasSuffix("(process \(pid))")
            }
        }
        let audited: Bool = await wait(5, refusedEarly)
        check(audited, "secret pipe: keys that come apart from the header, before ready, are seen waiting and refused for it")
    }

    /// A program that isn't Next Term at the socket, sending an importer's header: refused, and no sheet opens.
    static func secretPipeStrangerCheck(_ view: SecretsView) async {
        let app: String = "/Applications/Next Term.app/Contents/MacOS/NextTerm"
        let header = SecretImportPipe.Request(format: "bws", bytes: 4, path: nil, directory: "/",
                                              argvFull: [app, "--cli", "secret", "import", "-"])
        let netcat: String = "/usr/bin/nc"
        guard let line = header.line(), FileManager.default.isExecutableFile(atPath: netcat) else {
            return note("secret pipe: no nc on this Mac, so the check of another program at the socket is skipped")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: netcat)
        process.arguments = ["-U", "-w", "3", MCPControlServer.shared.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return check(false, "secret pipe: nc starts") }
        input.fileHandleForWriting.write(line)
        try? input.fileHandleForWriting.close()
        let ended: Bool = await wait(10) { !process.isRunning }
        if !ended { process.terminate() }
        let answer: String = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(answer.contains("\"refused\"") && view.fileImportSheet == nil,
              "secret pipe: another program sending an importer's header is refused, and no sheet opens", answer)
    }
}
#endif
