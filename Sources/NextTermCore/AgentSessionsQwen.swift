import Foundation

/// Qwen Code: `~/.qwen/projects/<folder name>/chats/<id>.jsonl`, the folder name being the path with every
/// character but an ASCII letter or digit turned into "-" (Claude Code's rule, without its hash of long
/// paths). Several folders share a name, so the `cwd` each session records decides, as Qwen's own check
/// does. Records are Claude-like (`sessionId`, `timestamp`, `type` user/assistant/tool_result/system,
/// `cwd`, `gitBranch`, `model`, `message` {role, parts}); a title is a system record with subtype
/// `custom_title` (`systemPayload` {customTitle, titleSource "manual" or "auto"}), the last one counting.
/// Archived chats (`chats/archive`) and sessions another session spawned (a `parent_session` record) are
/// not listed. Resume with `qwen --resume <id>` in the same folder.
struct QwenSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .qwen }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".qwen/projects")
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let encoded = Self.folderName(folder)
        var found: [AgentSession] = []
        for directory in all where directory == encoded || (subfolders && directory.hasPrefix(encoded + "-")) {
            let chats = base + "/" + directory + "/chats"
            for (file, path) in AgentStoreFiles.written(in: chats, since: since) where Self.isTranscript(file) {
                guard let session = Self.session(path), AgentSessions.matches(session.cwd, folder, subfolders: subfolders) else { continue }
                found.append(session)
            }
        }
        return found
    }

    static func folderName(_ path: String) -> String {
        let units = path.utf16.map { unit -> UInt16 in
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) ? unit : 0x2D
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// `<uuid>.jsonl`: not a sidecar (`.ledger.jsonl`, `.worktree.json`) or a folder.
    static func isTranscript(_ file: String) -> Bool {
        file.range(of: #"^[0-9a-fA-F-]{32,36}\.jsonl$"#, options: .regularExpression) != nil
    }

    static func session(_ path: String) -> AgentSession? {
        guard let (head, tail, modified) = AgentSessions.headAndTail(path), let first = head.first,
              let id = first["sessionId"] as? String, let cwd = first["cwd"] as? String else { return nil }
        var prompt: String?
        var branch = first["gitBranch"] as? String
        for line in head {
            let type = line["type"] as? String, subtype = line["subtype"] as? String
            if type == "system", subtype == "parent_session" { return nil } // another session started this one
            if prompt == nil, type == "user", subtype == nil { prompt = userText(line) }
        }
        var title: String?, named = false, updated: Date?, model: String?
        for line in tail {
            if line["type"] as? String == "system", line["subtype"] as? String == "custom_title",
               let payload = line["systemPayload"] as? [String: Any], let custom = payload["customTitle"] as? String {
                title = custom
                named = payload["titleSource"] as? String != "auto" // a title from before the field is the user's
            }
            if let stamp = line["timestamp"] as? String, let date = AgentSessions.parseDate(stamp) { updated = date }
            if line["type"] as? String == "assistant", let name = line["model"] as? String { model = name }
            if let value = line["gitBranch"] as? String, !value.isEmpty { branch = value }
        }
        let shown = [title, prompt].compactMap { $0 }.first { !$0.isEmpty }
        guard let shown else { return nil } // nothing was asked
        return AgentSession(agent: .qwen, id: id, cwd: cwd, title: AgentSessions.clean(shown), named: named && title == shown,
                            createdAt: (first["timestamp"] as? String).flatMap(AgentSessions.parseDate),
                            updatedAt: min(updated ?? modified, modified), gitBranch: branch?.isEmpty == false ? branch : nil,
                            model: model, isRunning: false)
    }

    /// What the user typed: the shown text Qwen keeps beside an expanded prompt, else the first text part.
    static func userText(_ line: [String: Any]) -> String? {
        if let shown = (line["systemPayload"] as? [String: Any])?["displayText"] as? String {
            return shown.isEmpty ? nil : shown
        }
        let parts = (line["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.lazy.compactMap { $0["text"] as? String }.first
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }
}
