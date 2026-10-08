import Foundation

/// Cursor Agent (`cursor-agent`): `~/.cursor/chats/<MD5 of the folder>/<chat id>/store.db`, one SQLite file
/// per chat. Newer builds keep a `meta.json` beside it (`createdAtMs`, `updatedAtMs`, `hasConversation`,
/// `isSubagent`, `title`, `cwd`); without one, the store's own `meta` row "0" (the hex of a JSON object
/// with `name`, `createdAt`, `lastUsedModel` and `latestRootBlobId`, empty for a chat with nothing in it)
/// says the same. Sub-agents' chats and empty ones are not listed. A subfolder's chats are found by the
/// `cwd` their `meta.json` records. Resume with `cursor-agent --resume=<chat id>` in the same folder.
struct CursorSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .cursor }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".cursor/chats")
        guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let own = AgentStoreFiles.md5(folder)
        var found: [AgentSession] = []
        for hash in hashes where hash == own || subfolders {
            for (chat, path) in AgentStoreFiles.written(in: base + "/" + hash, since: nil) where AgentStoreFiles.isPlainName(chat) {
                let files = [path + "/meta.json", path + "/store.db", path + "/store.db-wal"]
                if let since, (AgentStoreFiles.latest(files) ?? .distantPast) < since { continue }
                // Another folder's hash: only a chat whose meta.json puts it inside this one is read on.
                if hash != own {
                    guard let cwd = AgentStoreFiles.json(path + "/meta.json")?["cwd"] as? String,
                          AgentSessions.matches(cwd, folder, subfolders: true) else { continue }
                }
                guard let session = Self.session(path, id: chat, folder: hash == own ? folder : nil),
                      AgentSessions.matches(session.cwd, folder, subfolders: subfolders) else { continue }
                found.append(session)
            }
        }
        return found
    }

    /// One chat; `folder` is the one its hash says, or nil when only its `meta.json` can say.
    static func session(_ path: String, id: String, folder: String?) -> AgentSession? {
        let meta = AgentStoreFiles.json(path + "/meta.json") ?? [:]
        if meta["isSubagent"] as? Bool == true || meta["hasConversation"] as? Bool == false { return nil }
        guard let cwd = (meta["cwd"] as? String) ?? folder else { return nil }
        var title = meta["title"] as? String
        var created = AgentStoreFiles.date(milliseconds: meta["createdAtMs"])
        var model: String?
        if title?.isEmpty != false || meta["hasConversation"] == nil {
            // An older build's chat: its store says.
            guard let store = storeMeta(path + "/store.db"), store["latestRootBlobId"] as? String != "" else { return nil }
            title = title?.isEmpty == false ? title : store["name"] as? String
            created = created ?? AgentStoreFiles.date(milliseconds: store["createdAt"])
            model = store["lastUsedModel"] as? String
        }
        guard let title, !title.isEmpty else { return nil }
        let written = AgentStoreFiles.latest([path + "/store.db", path + "/store.db-wal", path + "/meta.json"])
        let updated = AgentStoreFiles.date(milliseconds: meta["updatedAtMs"]) ?? written ?? created ?? .distantPast
        return AgentSession(agent: .cursor, id: id, cwd: cwd, title: AgentSessions.clean(title), named: false, createdAt: created,
                            updatedAt: updated, gitBranch: nil, model: model?.isEmpty == false ? model : nil, isRunning: false)
    }

    /// The store's `meta` row "0": hex-encoded JSON.
    static func storeMeta(_ path: String) -> [String: Any]? {
        guard let db = try? AgentStoreDatabase(path),
              let hex = db.rows("SELECT value FROM meta WHERE key = '0'").first?.first ?? nil,
              let data = bytes(hex: hex) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func bytes(hex: String) -> Data? {
        let text = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard text.count % 2 == 0 else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = 0
        while index < text.count {
            guard let byte = UInt8(String(decoding: text[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        return data
    }
}
