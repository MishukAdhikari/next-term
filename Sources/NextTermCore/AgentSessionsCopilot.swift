import Foundation

/// GitHub Copilot CLI: `~/.copilot/session-state/<id>/` per session. Its `workspace.yaml` holds what a row
/// needs, as flat `key: value` lines (`id`, `cwd`, `branch`, `name`, `user_named`, `created_at`,
/// `updated_at`); `events.jsonl` is the conversation (`{type, data, timestamp}`: `user.message` with
/// `data.content`, `assistant.message` with `data.model`, `session.model_change` with `data.newModel`),
/// read only for a session with no name yet and for the model, from its two ends. While a `copilot` has a
/// session open, an `inuse.<pid>.lock` file sits in its folder. Resume with `copilot --resume=<id>`.
struct CopilotSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .copilot }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".copilot/session-state")
        var found: [AgentSession] = []
        for (name, path) in AgentStoreFiles.written(in: base, since: nil) where AgentStoreFiles.isPlainName(name) {
            if let since, (AgentStoreFiles.latest([path + "/workspace.yaml", path + "/events.jsonl"]) ?? .distantPast) < since { continue }
            guard let text = AgentSessions.readHead(path + "/workspace.yaml", bytes: 65536).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
            let workspace = Self.flatYAML(text)
            guard let cwd = workspace["cwd"], AgentSessions.matches(cwd, folder, subfolders: subfolders),
                  let session = Self.session(path, id: workspace["id"] ?? name, cwd: cwd, workspace: workspace) else { continue }
            found.append(session)
        }
        return found
    }

    static func session(_ path: String, id: String, cwd: String, workspace: [String: String]) -> AgentSession? {
        let events = AgentSessions.headAndTail(path + "/events.jsonl")
        var title = workspace["name"].flatMap { $0.isEmpty ? nil : $0 }
        for event in events?.head ?? [] where title == nil && event["type"] as? String == "user.message" {
            let content = (event["data"] as? [String: Any])?["content"] as? String ?? ""
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = content }
        }
        guard let title else { return nil } // nothing was asked
        var model: String?
        for event in events?.tail ?? [] {
            let data = event["data"] as? [String: Any]
            switch event["type"] as? String {
            case "session.model_change": model = (data?["newModel"] as? String) ?? model
            case "assistant.message": model = (data?["model"] as? String) ?? model
            default: break
            }
        }
        let written = AgentStoreFiles.latest([path + "/events.jsonl", path + "/workspace.yaml"])
        let updated = workspace["updated_at"].flatMap(AgentSessions.parseDate) ?? written ?? .distantPast
        let branch = workspace["branch"].flatMap { $0.isEmpty ? nil : $0 }
        return AgentSession(agent: .copilot, id: id, cwd: cwd, title: AgentSessions.clean(title), named: workspace["user_named"] == "true",
                            createdAt: workspace["created_at"].flatMap(AgentSessions.parseDate),
                            updatedAt: max(updated, written ?? .distantPast), gitBranch: branch, model: model,
                            isRunning: isOpen(path))
    }

    /// An `inuse.<pid>.lock` whose process is alive.
    static func isOpen(_ path: String) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return files.contains { file in
            guard file.hasPrefix("inuse."), file.hasSuffix(".lock"), let pid = Int32(file.dropFirst(6).dropLast(5)), pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }

    /// Top-level `key: value` pairs of a flat YAML file, unquoted; a long value folded onto indented lines
    /// is joined back with spaces. Nested blocks and lists are skipped.
    static func flatYAML(_ text: String) -> [String: String] {
        var pairs: [(key: String, value: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                let more = raw.trimmingCharacters(in: .whitespaces)
                if !more.isEmpty, !more.hasPrefix("-"), !more.hasPrefix("#"), let last = pairs.indices.last {
                    pairs[last].value += pairs[last].value.isEmpty ? more : " " + more
                }
                continue
            }
            guard !raw.hasPrefix("#"), let colon = raw.range(of: ":") else { continue }
            let key = String(raw[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            pairs.append((key, value))
        }
        var result: [String: String] = [:]
        for (key, value) in pairs where !value.hasPrefix("|") && !value.hasPrefix(">") { result[key] = unquoted(value) }
        return result
    }

    static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
           let decoded = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String {
            return decoded
        }
        return value
    }
}
