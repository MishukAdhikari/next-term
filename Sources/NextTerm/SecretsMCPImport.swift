import AppKit
import NextTermCore

/// `import_secrets`: an agent names a file of keys or a password manager, and the user's import window opens on the Mac
/// with a banner naming it, in the shared queue's turn, so the limits and pauses hold as for the other asking tools.
/// Checked before anything opens: one of path or source; a path by `SecretSources.checkPath` (a refusal says only its
/// class, and a protected file answers as a missing one); an agent's MCP config, which Next Term's own import moves, is
/// left to the user. The answer is names and counts (`SecretSources.answer(for:)`), never a value. Remote calls are
/// refused in `call`, before this.
extension SecretsMCP {
    static let importTool = "import_secrets"
    static let importUsage = "Give path (a file of keys) or source (1password, bitwarden or bws), not both."
    static let importSourceUsage = "Give source as 1password, bitwarden or bws."
    static let importPathUsage = "Give path: a file's path, at most 4,096 characters."
    static let moveTargetNote = "That file is an agent's MCP config, whose keys Next Term's own import moves into "
        + "Secrets. The user starts that import in Settings › Secrets with Import From › MCP Configs…"

    static func importSecrets(_ arguments: [String: Any], caller: TerminalTab?, asker: String, facts: SecretRequests.AskedBy,
                              words: String?, reply: @escaping Reply) {
        let target: SecretImportAsk.Target
        switch importTarget(arguments, caller: caller) {
        case .failure(let refusal): return reply(answer(.refused, note: refusal.note))
        case .success(let named): target = named
        }
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered { return reply(answer(.cantOpen, note: cantOpenNote)) }
        let named: String = target.text
        var folder: String = ""
        if case .file(let path) = target { folder = (path as NSString).deletingLastPathComponent }
        let binding = SecretBinding(source: .tool, asker: asker, program: importTool, command: [importTool, named],
                                    keys: [:], folder: folder, target: named)
        let requests = SecretRequests.shared
        if let refusal = requests.precheck(asker: asker, binding: binding, names: [], command: importTool + " " + named,
                                           folder: folder.isEmpty ? nil : folder) {
            return reply(MCPControl.ok(answer(for: .refused(refusal), tool: importTool)))
        }
        let command: String = importCommand(named, words: words)
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

    /// The file or password manager a call names, or why it is refused before anything opens.
    static func importTarget(_ arguments: [String: Any], caller: TerminalTab?) -> Result<SecretImportAsk.Target, Refusal> {
        let path: String? = (arguments["path"] as? String).flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
        let source: String? = (arguments["source"] as? String).flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
        guard (path == nil) != (source == nil) else { return .failure(Refusal(importUsage)) }
        if let source {
            guard let preset = SecretImportPreset(rawValue: source) else { return .failure(Refusal(importSourceUsage)) }
            return .success(.source(preset))
        }
        guard let path, path.count <= SecretSources.maxPathLength, !path.contains("\0") else {
            return .failure(Refusal(importPathUsage))
        }
        // A relative path is the caller's tab's: a local tab's folder, never a remote one's.
        let folder: String? = caller.flatMap { (tab: TerminalTab) -> String? in tab.remote == nil ? tab.directory : nil }
        let vault: String = SecretsStore.shared.folder.url.path
        switch SecretSources.checkPath(path, home: NSHomeDirectory(), vaultFolder: vault, folder: folder) {
        case .failure(let refusal): return .failure(Refusal(refusal.note))
        case .success(let real):
            let setup: SecretImportSheet.Setup = SecretsView.importSetup()
            let moves: Bool = SecretSources.isMoveTarget(path: real, home: setup.home, projects: setup.projects)
            return moves ? .failure(Refusal(moveTargetNote)) : .success(.file(real))
        }
    }

    /// The audit lines' command: the tool, what it names, and the agent's reason, cut as the log cuts a command.
    static func importCommand(_ named: String, words: String?) -> String {
        let said: String = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? importTool + " " + named : importTool + " " + named + " (reason: " + said + ")"
    }
}
