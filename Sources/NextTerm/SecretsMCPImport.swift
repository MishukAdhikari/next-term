import AppKit
import NextTermCore

/// `import_secrets`: an agent names a file of keys or a password manager, and the user's import window opens on the Mac
/// with a banner naming it, in the shared queue's turn, so the limits and pauses hold as for the other asking tools.
/// Checked before anything opens, by Core's `SecretSources.asked` and `checkAsked`: one of path or source; a path by
/// `checkPath` (a refusal says only its class, and a protected file answers as a missing one); an agent's MCP config,
/// which Next Term's own import moves, is left to the user. The path is checked off the main thread, so a mount that
/// stopped answering never holds up the app. The answer is names and counts (`SecretSources.answer(for:)`), never a
/// value. Remote calls are refused in `call`, before this.
extension SecretsMCP {
    static let importTool = "import_secrets"

    static func importSecrets(_ arguments: [String: Any], caller: TerminalTab?, asker: String, facts: SecretRequests.AskedBy,
                              words: String?, reply: @escaping Reply) {
        let asked: SecretSources.Asked
        switch SecretSources.asked(path: arguments["path"], source: arguments["source"]) {
        case .failure(let refusal): return reply(answer(.refused, note: refusal.note))
        case .success(let named): asked = named
        }
        let path: String
        switch asked {
        case .source(let preset):
            return askToImport(.source(preset), asker: asker, facts: facts, words: words, reply: reply)
        case .path(let named): path = named
        }
        // A relative path is the caller's tab's: a local tab's folder, never a remote one's.
        let folder: String? = caller.flatMap { (tab: TerminalTab) -> String? in tab.remote == nil ? tab.directory : nil }
        let home: String = NSHomeDirectory()
        let vault: String = SecretsStore.shared.folder.url.path
        let setup: SecretImportSheet.Setup = SecretsView.importSetup()
        let configHome: String = setup.home
        let projects: [String] = setup.projects
        Task { @MainActor in
            let checked = await Task.detached { () -> Result<String, SecretSources.AskRefusal> in
                SecretSources.checkAsked(path, home: home, vaultFolder: vault, folder: folder, configHome: configHome,
                                         projects: projects)
            }.value
            switch checked {
            case .failure(let refusal): reply(answer(.refused, note: refusal.note))
            case .success(let real): askToImport(.file(real), asker: asker, facts: facts, words: words, reply: reply)
            }
        }
    }

    /// The checked file or source's request, in the shared queue: refused there, or its sheet in its turn.
    static func askToImport(_ target: SecretImportAsk.Target, asker: String, facts: SecretRequests.AskedBy, words: String?,
                            reply: @escaping Reply) {
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered { return reply(answer(.cantOpen, note: cantOpenNote)) }
        let named: String = target.text
        var folder: String = ""
        if case .file(let path) = target { folder = (path as NSString).deletingLastPathComponent }
        let binding = SecretBinding(source: .tool, asker: asker, program: importTool, command: [importTool, named],
                                    keys: [:], folder: folder, target: named)
        let requests = SecretRequests.shared
        let command: String = SecretSources.askedCommand(named, reason: words)
        if let refusal = requests.precheck(asker: asker, binding: binding, names: [], command: command,
                                           folder: folder.isEmpty ? nil : folder) {
            return reply(MCPControl.ok(answer(for: .refused(refusal), tool: importTool)))
        }
        let request = SecretRequests.Request(binding: binding, keys: [], command: command, argv: [], folder: folder,
                                             warnings: [], agentWords: words, askedBy: facts, program: importTool,
                                             isRemote: false)
        let asking: String = SecretSources.askerText(agent: facts.agent, tab: facts.tab, project: facts.project)
        let from: String = target.shown(home: NSHomeDirectory())
        let banner: String = SecretSources.askBanner(asker: asking, from: from, reason: words)
        let ask = SecretImportAsk(target: target, banner: banner, askedBy: SecretRequests.who(request), command: command)
        request.kind = .importKeys(ask)
        let call = Call(asker: asker, tool: importTool)
        calls[call.id] = call
        requests.ask(request) { decision in resolve(call, answer(for: decision, tool: importTool)) }
        wait(call, reply: reply)
    }
}
