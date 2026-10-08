import Foundation

/// Gemini CLI: `~/.gemini/tmp/<project>/chats/session-<time>-<id prefix>.jsonl` (`~/.cache/.gemini` when it
/// runs under macOS's sandbox-exec). `<project>` is the folder's short name in `~/.gemini/projects.json`
/// (`{"projects": {"<path>": "<name>"}}`, since v0.29), or the SHA-256 of the path for a folder Gemini has
/// not run in since. The first line is the session's metadata (`sessionId`, `startTime`, `lastUpdated`,
/// `kind`); then messages (`type` user or gemini, gemini's with their `model`) and `$set` updates (the AI
/// `summary`, `lastUpdated`). Sessions from before v0.39, one JSON file each (`.json`), are not listed:
/// their metadata is not at either end, so it could only be had by reading the whole conversation.
/// Sub-agents' chats sit in a folder per parent session and are never listed, nor are sessions with
/// nothing but slash commands. Resume with `gemini --resume <sessionId>` in the same folder.
struct GeminiSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .gemini }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        var found: [AgentSession] = []
        var seen = Set<String>()
        for root in [".gemini", ".cache/.gemini"].map({ (home as NSString).appendingPathComponent($0) }) {
            for project in projects(root: root, folder: folder, subfolders: subfolders) {
                let chats = root + "/tmp/" + project.name + "/chats"
                for (file, path) in AgentStoreFiles.written(in: chats, since: since) where file.hasPrefix("session-") && file.hasSuffix(".jsonl") {
                    if let session = Self.session(path, cwd: project.path), seen.insert(session.id).inserted { found.append(session) }
                }
            }
        }
        return found
    }

    /// The folders under `tmp` that hold `folder`'s chats (and its subfolders'), with the path each is for.
    func projects(root: String, folder: String, subfolders: Bool) -> [(path: String, name: String)] {
        var result: [(path: String, name: String)] = []
        let registry = AgentStoreFiles.json(root + "/projects.json", bytes: 4 << 20)?["projects"] as? [String: Any] ?? [:]
        for (path, value) in registry {
            guard let name = value as? String, AgentStoreFiles.isPlainName(name),
                  AgentSessions.matches(path, folder, subfolders: subfolders) else { continue }
            // The folder says whose it is; a name that has gone to another path is not this one's.
            let marker = root + "/tmp/" + name + "/.project_root"
            if let owner = AgentSessions.readHead(marker, bytes: 4096).map({ String(decoding: $0, as: UTF8.self) }),
               owner.trimmingCharacters(in: .whitespacesAndNewlines) != path { continue }
            result.append((path, name))
        }
        let hashed = AgentStoreFiles.sha256(folder)
        if FileManager.default.fileExists(atPath: root + "/tmp/" + hashed) { result.append((folder, hashed)) }
        return result
    }

    /// What Gemini's own list skips: nothing typed, a slash command, a `?` help request, injected context.
    static func isPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("?") || trimmed.hasPrefix("<session_context>")
                 || trimmed.hasPrefix("<hook_context>"))
    }

    static func session(_ path: String, cwd: String) -> AgentSession? {
        guard let (head, tail, modified) = AgentSessions.headAndTail(path), let header = head.first,
              let id = header["sessionId"] as? String, header["kind"] as? String != "subagent" else { return nil }
        var firstPrompt: String?
        for line in head where firstPrompt == nil && line["type"] as? String == "user" {
            if let text = AgentStoreFiles.text(line["content"]), isPrompt(text) { firstPrompt = text }
        }
        var summary = header["summary"] as? String
        var updated = (header["lastUpdated"] as? String).flatMap(AgentSessions.parseDate)
        var model: String?
        for line in tail {
            if let set = line["$set"] as? [String: Any] {
                summary = (set["summary"] as? String) ?? summary
                updated = (set["lastUpdated"] as? String).flatMap(AgentSessions.parseDate) ?? updated
            }
            if let stamp = line["timestamp"] as? String, let date = AgentSessions.parseDate(stamp), date > (updated ?? .distantPast) {
                updated = date
            }
            if line["type"] as? String == "gemini", let name = line["model"] as? String { model = name }
        }
        let title = [summary, firstPrompt].compactMap { $0 }.first { !$0.isEmpty }
        guard let title else { return nil } // nothing was asked
        return AgentSession(agent: .gemini, id: id, cwd: cwd, title: AgentSessions.clean(title), named: false,
                            createdAt: (header["startTime"] as? String).flatMap(AgentSessions.parseDate),
                            updatedAt: min(updated ?? modified, modified), gitBranch: nil, model: model, isRunning: false)
    }
}
