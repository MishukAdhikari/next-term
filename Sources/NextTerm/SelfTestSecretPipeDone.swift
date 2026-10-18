import AppKit
import NextTermCore

#if DEBUG
/// `nxtrm secret import`'s done view and where its keys came from, on the self-test's own socket and temporary vault.
/// No password manager's CLI ever runs: a shell function named op or bw stands in for it on the same line (a function
/// comes before any program on PATH, and a line whose function doesn't parse runs nothing), and prints a made-up
/// answer from a file. Values are made up at run time, and never typed on a tab's line.
extension SelfTest {
    /// `nxtrm` as the preset lines run it, quoted for zsh.
    static var secretPipeNxtrm: String {
        SecretManagerImportSheet.nxtrmWords.map(secretPipeQuoted).joined(separator: " ")
    }

    /// A tab in `folder`, at its prompt.
    static func secretPipeTab(_ c: TerminalWindowController, _ folder: URL) async -> TerminalTab {
        let tab: TerminalTab = c.addTab(directory: folder.path, select: false)
        _ = await wait(10) { tab.status.integrated }
        return tab
    }

    /// Whether the tab shows `text`, spaces and row breaks aside: a long sentence wraps where the width says.
    static func secretPipeShows(_ tab: TerminalTab, _ text: String) -> Bool {
        let bare: (String) -> String = { (line: String) -> String in line.filter { !$0.isWhitespace } }
        return bare(secretPipeScreen(tab)).contains(bare(text))
    }

    /// The warning under the copy sheet's header, if it has one.
    static func secretPipeWarning(_ sheet: SecretFileImportSheet?) -> String? {
        guard let stack = sheet?.headerLabel.superview as? NSStackView else { return nil }
        let warnings: [String] = [SecretImportPipe.agentWarning, SecretImportPipe.untracedWarning]
        let texts: [String] = stack.arrangedSubviews.compactMap { (view: NSView) -> String? in
            (view as? NSTextField)?.stringValue
        }
        return texts.first { (text: String) -> Bool in warnings.contains(text) }
    }

    /// In bws's preset tab, its line wiped (^U) and a pipe of the made-up list run in its place (the self-test types
    /// it; agents can't): the sheet doesn't name bws, as the tab didn't run its line as typed, and once the pipe has
    /// ended the tab still refuses agents.
    static func secretPresetAfterPipeChecks(_ view: SecretsView, _ tab: TerminalTab, list: URL) async {
        tab.view.send(txt: "\u{15}")
        await pause(0.3)
        let line: String = "cat \(secretPipeQuoted(list.path)) | \(secretPipeNxtrm) secret import --from bws -"
        secretPipeTypeAsUser(line, into: tab)
        let opened: Bool = await wait(15) { view.fileImportSheet?.isPiped == true }
        let sheet: SecretFileImportSheet? = view.fileImportSheet
        let header: String = sheet?.headerLabel.stringValue ?? ""
        let origin: SecretPipeImport.Origin? = sheet?.client?.origin
        let unnamed: Bool = origin?.preset == nil && origin?.tabPreset == .bws && !header.contains("through bws")
        check(opened && unnamed && header.contains("piped into nxtrm secret import"),
              "secret pipe: a pipe typed in bws's tab in place of its line isn't named as bws's", header)
        sheet?.closeSheet()
        _ = await wait(10) { secretPipeScreen(tab).contains("Nothing imported.") && !tab.status.running }
        await secretPresetRefusalChecks(tab, .bws, afterPipe: true)
    }

    /// One `op item get --format json` item, made up.
    static func secretPipeOpItem(_ title: String, _ value: String) -> [String: Any] {
        let field: [String: String] = ["id": "credential", "type": "CONCEALED", "label": "credential", "value": value]
        return ["id": "madeupitem00000000000000\(title.count)", "title": title, "category": "API_CREDENTIAL",
                "fields": [field]]
    }

    /// One `bw list items` item, made up: a secure note with a hidden field.
    static func secretPipeBwItem(_ name: String, _ value: String) -> [String: Any] {
        let field: [String: Any] = ["name": name, "value": value, "type": 1]
        return ["id": "00000000-0000-4000-8000-000000000016", "type": 2, "name": "Made-up note",
                "secureNote": ["type": 0], "fields": [field]]
    }

    static func secretPipeDoneChecks(_ c: TerminalWindowController, _ view: SecretsView, folder: URL) async {
        await secretPipeOnePasswordCheck(c, view, folder: folder)
        await secretPipeBitwardenCheck(c, view, folder: folder)
    }

    /// Runs `line` in a new tab, imports every ticked row, and gives the sheet in its done view, with the tab; nil
    /// when a step didn't happen (a failed check says which).
    static func secretPipeImported(_ c: TerminalWindowController, _ view: SecretsView, folder: URL,
                                   line: String, what: String) async -> (SecretFileImportSheet, TerminalTab)? {
        let tab: TerminalTab = await secretPipeTab(c, folder)
        secretPipeTypeAsUser(line, into: tab)
        let opened: Bool = await wait(15) { view.fileImportSheet?.isPiped == true }
        guard opened, let sheet = view.fileImportSheet, sheet.importButton.isEnabled else {
            closeSecretsTabs([tab], "secret pipe")
            check(false, "secret pipe: \(what) opens the copy sheet with keys ticked")
            return nil
        }
        sheet.importButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        sheet.confirmAlert?.buttons.first?.performClick(nil)
        _ = await wait(15) { sheet.record != nil }
        let count: Int = sheet.record?.names.count ?? 0
        let imported: String = SecretImportPipe.text(.imported(count)).line
        // Said while the done view is up, not when it closes.
        let early: Bool = await wait(10) { secretPipeScreen(tab).contains(imported) }
        check(count > 0 && early && view.fileImportSheet === sheet,
              "secret pipe: \(what): the tab says \(imported) as the done view shows, before it closes",
              secretPipeScreen(tab))
        return (sheet, tab)
    }
}

extension SelfTest {
    /// op's pipe, with a function named op printing two made-up items: the done view says to close the tab, with
    /// Close Tab, which ends the sheet and closes the tab the import ran in.
    static func secretPipeOnePasswordCheck(_ c: TerminalWindowController, _ view: SecretsView, folder: URL) async {
        let names: [String] = ["PIPE_OP_FIRST_API_KEY", "PIPE_OP_SECOND_API_KEY"]
        let values: [String] = [secretsValue("sk-" + "ant-" + "api03-"), secretsValue("tvly-" + "dev-")]
        let items: [[String: Any]] = zip(names, values).map { (pair: (String, String)) -> [String: Any] in
            secretPipeOpItem(pair.0, pair.1)
        }
        let file: URL = folder.appendingPathComponent("op-items.json")
        guard let data = try? JSONSerialization.data(withJSONObject: items), (try? data.write(to: file)) != nil else {
            return check(false, "secret pipe: the made-up op items are written")
        }
        let stand: String = "op() { cat \(secretPipeQuoted(file.path)); }; "
        let pipe: String = "op item get made-up --format json --reveal | \(secretPipeNxtrm) secret import "
            + "--from 1password -"
        let line: String = stand + pipe
        guard let done = await secretPipeImported(c, view, folder: folder, line: line, what: "op's pipe") else { return }
        let (sheet, tab) = done
        let stored: [String] = sheet.record?.names ?? []
        let summary: String = sheet.summaryLabel.stringValue
        let buttons: [NSButton] = sheet.doneStack.arrangedSubviews.compactMap { (view: NSView) -> NSButton? in
            view as? NSButton
        }
        let closeTab: NSButton? = buttons.first { (button: NSButton) -> Bool in
            button.title == SecretFileImportSheet.closeTabTitle
        }
        check(summary.contains(SecretImportPreset.onePasswordLine) && closeTab != nil,
              "secret pipe: after op's pipe the done view says to close the tab, with Close Tab", summary)
        closeTab?.performClick(nil)
        let closed: Bool = await wait(5) {
            view.fileImportSheet == nil && !AppDelegate.shared.controllers.flatMap(\.tabs).contains { $0 === tab }
        }
        check(closed, "secret pipe: Close Tab ends the sheet and closes the tab the import ran in")
        closeSecretsTabs([tab], "secret pipe")
        for name in stored { _ = try? await SecretsStore.shared.perform(.delete(name: name)) }
    }

    /// The Bitwarden preset's own line, with a function named bw that prints a made-up item for bw list and nothing
    /// else (so its unlock gives an empty session and its lock does nothing): the done view says Bitwarden is locked
    /// again, as the line ends with bw lock, and offers no Close Tab.
    static func secretPipeBitwardenCheck(_ c: TerminalWindowController, _ view: SecretsView, folder: URL) async {
        let item: [String: Any] = secretPipeBwItem("PIPE_BW_LINEAR_API_KEY", secretsValue("lin_" + "api_"))
        let file: URL = folder.appendingPathComponent("bw-items.json")
        guard let data = try? JSONSerialization.data(withJSONObject: [item]), (try? data.write(to: file)) != nil else {
            return check(false, "secret pipe: the made-up bw items are written")
        }
        let nxtrm: [String] = SecretManagerImportSheet.nxtrmWords
        guard let preset = SecretImportPreset.bitwarden.line(nxtrm: nxtrm, shell: "zsh") else {
            return check(false, "secret pipe: Bitwarden's line for zsh")
        }
        let stand: String = "bw() { [ \"$1\" = list ] && cat \(secretPipeQuoted(file.path)); true; }; "
        let line: String = stand + preset
        guard let done = await secretPipeImported(c, view, folder: folder, line: line, what: "bw's line") else { return }
        let (sheet, tab) = done
        let stored: [String] = sheet.record?.names ?? []
        let summary: String = sheet.summaryLabel.stringValue
        let buttons: [NSButton] = sheet.doneStack.arrangedSubviews.compactMap { (view: NSView) -> NSButton? in
            view as? NSButton
        }
        check(summary.contains(SecretImportPreset.lockedLine) && buttons.isEmpty,
              "secret pipe: after Bitwarden's line the done view says it is locked again, with no Close Tab", summary)
        sheet.doneButton.performClick(nil)
        _ = await wait(5) { view.fileImportSheet == nil }
        closeSecretsTabs([tab], "secret pipe")
        for name in stored { _ = try? await SecretsStore.shared.perform(.delete(name: name)) }
    }
}
#endif
