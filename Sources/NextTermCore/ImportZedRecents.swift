import Foundation
import SQLite3

// Zed's recent projects: the `workspaces` table of its database (~/Library/Application Support/Zed/db/0-<channel>/
// db.sqlite, `db.rs`), read in place and read-only, never copied, as VS Code's state.vscdb is. One fixed SELECT of
// the paths column, newest first, local workspaces only; the column's older name is tried only when the newer one
// isn't there. No other table or column is read: the same database keeps editors' unsaved text and agents'
// threads. Local folders that exist, at most 20, each once.

extension ImportZed {
    /// Zed since mid-2025: each workspace's folders as text, one path per line in `paths` (sorted, with their
    /// order in `paths_order`), and a remote one with its `remote_connection_id`.
    static let recentQuery = "SELECT paths, paths_order, timestamp FROM workspaces WHERE paths IS NOT NULL AND paths != '' "
        + "AND remote_connection_id IS NULL ORDER BY timestamp DESC LIMIT 200"
    /// The same table without the remote column.
    static let recentQueryWithoutRemote = "SELECT paths, paths_order, timestamp FROM workspaces WHERE paths IS NOT NULL AND paths != '' "
        + "ORDER BY timestamp DESC LIMIT 200"
    /// Before that: `local_paths` and `local_paths_order`, encoded as bincode lists (a remote workspace had none).
    static let olderRecentQuery = "SELECT local_paths, local_paths_order, timestamp FROM workspaces WHERE local_paths IS NOT NULL "
        + "ORDER BY timestamp DESC LIMIT 200"

    static let recentLimit = 20

    /// One workspace row: its folders in the order they were opened, and when it was last used.
    struct Workspace: Equatable {
        var folders: [String]
        var timestamp: String
    }

    enum Rows: Equatable {
        case rows([Workspace])
        /// The database has no workspaces table, or none of the columns asked for.
        case missing
        case failed
    }

    /// Recent folders from every channel's database (stable, preview, nightly), newest first.
    static func recentProjects(home: String) -> (paths: [String], skipped: [SkippedItem]) {
        var workspaces: [Workspace] = []
        var failed = false
        for database in databaseFiles(home: home) where database.hasSuffix("/db.sqlite") {
            switch workspaceRows(database) {
            case .rows(let rows): workspaces += rows
            case .missing: continue
            case .failed: failed = true
            }
        }
        var result = recentProjects(workspaces.sorted { $0.timestamp > $1.timestamp })
        if failed && result.paths.isEmpty {
            result.skipped.append(SkippedItem("recent projects", "couldn't be read; quit Zed and try again"))
        }
        return result
    }

    /// The first folder of each workspace that is a folder on this Mac, each once, newest first, at most 20.
    static func recentProjects(_ workspaces: [Workspace]) -> (paths: [String], skipped: [SkippedItem]) {
        var paths: [String] = []
        var skipped: [SkippedItem] = []
        var seen = Set<String>()
        var missing = 0, secret = 0, more = 0
        for workspace in workspaces {
            guard let first = workspace.folders.first, first.hasPrefix("/") else { continue }
            let folder = canonicalPath(first)
            guard !seen.contains(folder) else { continue }
            seen.insert(folder)
            if SecretGuard.pathLooksSecret(folder) {
                secret += 1
            } else if !ImportVSCode.isDirectory(folder) {
                missing += 1
            } else if paths.count < recentLimit {
                paths.append(folder)
                if workspace.folders.count > 1 {
                    let name = (folder as NSString).lastPathComponent
                    let shown = SecretGuard.looksSecret(name) ? "a workspace" : name
                    skipped.append(SkippedItem(shown, "only a workspace's first folder comes over (\(ImportVSCode.counted(workspace.folders.count - 1, "more folder")) left out)"))
                }
            } else {
                more += 1
            }
        }
        if missing > 0 { skipped.append(SkippedItem(ImportVSCode.counted(missing, "recent project"), "the folder no longer exists")) }
        if secret > 0 { skipped.append(SkippedItem(ImportVSCode.counted(secret, "recent project"), ImportVSCode.credential)) }
        if more > 0 { skipped.append(SkippedItem(ImportVSCode.counted(more, "older recent project"), "only the \(recentLimit) most recent come over")) }
        return (paths, skipped)
    }

    /// The workspaces in one database, read in place and read-only. A WAL database whose -wal and -shm are gone
    /// can't be opened read-only (SQLite would have to make the -shm); with no -wal, every committed row is in the
    /// file itself, so it is then read as immutable.
    static func workspaceRows(_ path: String) -> Rows {
        guard isRegularFile(path) else { return .failed }
        let attempt = workspaceRows(path, immutable: false)
        guard attempt.rows == .failed, attempt.code & 0xFF == SQLITE_CANTOPEN,
              !FileManager.default.fileExists(atPath: path + "-wal") else { return attempt.rows }
        return workspaceRows(path, immutable: true).rows
    }

    private static func workspaceRows(_ path: String, immutable: Bool) -> (rows: Rows, code: Int32) {
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return (.failed, SQLITE_MISUSE) }
        var db: OpaquePointer?
        let uri = "file:\(escaped)?mode=ro" + (immutable ? "&immutable=1" : "")
        let opened = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let db else {
            sqlite3_close(db)
            return (.failed, opened)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        // The first statement this database's schema has (a missing table or column fails to prepare, reading nothing).
        for (query, encoded) in [(recentQuery, false), (recentQueryWithoutRemote, false), (olderRecentQuery, true)] {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(db, query, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                if prepared & 0xFF == SQLITE_ERROR { continue } // no such table or column
                return (.failed, prepared)
            }
            defer { sqlite3_finalize(statement) }
            return step(statement, encoded: encoded)
        }
        return (.missing, SQLITE_OK)
    }

    private static func step(_ statement: OpaquePointer, encoded: Bool) -> (rows: Rows, code: Int32) {
        var rows: [Workspace] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return (.rows(rows), SQLITE_OK) }
            guard step == SQLITE_ROW else { return (.failed, step) }
            let paths = column(statement, 0), order = column(statement, 1)
            let stamp = column(statement, 2).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let paths else { continue }
            let folders = encoded ? bincodePaths(paths) : textPaths(paths)
            let indices = encoded ? order.flatMap(bincodeIndices) : order.flatMap(textIndices)
            rows.append(Workspace(folders: opened(folders, order: indices), timestamp: stamp))
        }
    }

    /// A column's bytes (text or blob), at most 1 MiB.
    private static func column(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, count <= 1 << 20, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// "/a\n/b": one path per line.
    static func textPaths(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// "1,0": the order the folders were opened in, by their place in the sorted list.
    static func textIndices(_ data: Data) -> [Int]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let indices = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return indices.isEmpty ? nil : indices
    }

    /// A bincode list of paths: a little-endian UInt64 count, then each path's UInt64 length and its UTF-8 bytes.
    static func bincodePaths(_ data: Data) -> [String] {
        var reader = Bincode(data)
        guard let count = reader.integer(), count <= 1_000 else { return [] }
        var paths: [String] = []
        for _ in 0..<count {
            guard let length = reader.integer(), let bytes = reader.bytes(length), let path = String(data: bytes, encoding: .utf8) else { return [] }
            paths.append(path)
        }
        return paths
    }

    /// A bincode list of UInt64 indices.
    static func bincodeIndices(_ data: Data) -> [Int]? {
        var reader = Bincode(data)
        guard let count = reader.integer(), count <= 1_000 else { return nil }
        var indices: [Int] = []
        for _ in 0..<count {
            guard let index = reader.integer() else { return nil }
            indices.append(index)
        }
        return indices
    }

    /// The folders in the order they were opened: `order[i]` is the place the i-th sorted folder had. Without a
    /// usable order, as stored.
    static func opened(_ sorted: [String], order: [Int]?) -> [String] {
        guard let order, order.count == sorted.count, Set(order) == Set(0..<sorted.count) else { return sorted }
        var folders = sorted
        for (index, place) in order.enumerated() { folders[place] = sorted[index] }
        return folders
    }

    struct Bincode {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }

        mutating func integer() -> Int? {
            guard let bytes = bytes(8) else { return nil }
            var value: UInt64 = 0
            for (shift, byte) in bytes.enumerated() { value |= UInt64(byte) << (8 * UInt64(shift)) }
            return value <= UInt64(Int32.max) ? Int(value) : nil
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return data.subdata(in: start..<start + count)
        }
    }
}
