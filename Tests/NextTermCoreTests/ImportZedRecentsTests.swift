import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// Zed's recent projects, its settings Next Term now has too and its keys for the commands it now maps, from the
/// hand-written fixture home in Fixtures/Import/Zed (never a real Mac's). The database is built from the fixture's
/// workspaces.sql in the temp copy.
@Suite struct ImportZedRecentsTests {
    var fm: FileManager { .default }

    /// The fixture, copied, with its project folders and (unless `database` is false) its database.
    func fixture(database: Bool = true) throws -> String {
        let home = try ImportFixtures.copy("Zed")
        for name in ["app", "both-a", "both-b"] {
            try fm.createDirectory(atPath: home + "/Code/" + name, withIntermediateDirectories: true)
        }
        if database {
            let sql = try String(contentsOfFile: home + "/workspaces.sql", encoding: .utf8).replacingOccurrences(of: "HOME/", with: home + "/")
            try makeDatabase(home + "/Library/Application Support/Zed/db/0-stable/db.sqlite", sql: sql)
        }
        return home
    }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func makeDatabase(_ path: String, sql: String, blobs: [(String, Data, Data)] = []) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        for (stamp, paths, order) in blobs {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO workspaces(local_paths, local_paths_order, timestamp) VALUES (?1, ?2, ?3)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = paths.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(paths.count), transient) }
            _ = order.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(order.count), transient) }
            sqlite3_bind_text(statement, 3, stamp, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    func plan(_ home: String) throws -> ImportPlan {
        let app = try #require(ImportZed.detect(home: home, applications: []).first)
        return ImportZed.plan(for: app, home: home, fonts: testFonts)
    }

    // MARK: recent projects

    @Test func recentLocalFoldersNewestFirst() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try plan(home)
        #expect(plan.recentProjects == [home + "/Code/both-b", home + "/Code/app"])
        #expect(plan.skipped.contains(SkippedItem("both-b", "only a workspace's first folder comes over (1 more folder left out)")))
        #expect(plan.skipped.contains(SkippedItem("1 recent project", "the folder no longer exists")))
        #expect(plan.skipped.contains(SkippedItem("1 recent project", "looked like a credential")))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        #expect(!String(describing: plan).contains("/srv/deploy") && !String(describing: plan).contains("Dotenv"))
    }

    @Test func atMostTwentyComeOver() throws {
        let home = try fixture(database: false)
        defer { remove(home) }
        var rows: [String] = []
        for n in 0..<25 {
            try fm.createDirectory(atPath: home + "/Code/p\(n)", withIntermediateDirectories: true)
            rows.append("('\(home)/Code/p\(n)', '0', NULL, '2026-10-01 10:\(String(format: "%02d", n)):00')")
        }
        let sql = "CREATE TABLE workspaces(workspace_id INTEGER PRIMARY KEY, paths TEXT, paths_order TEXT, remote_connection_id INTEGER, "
            + "timestamp TEXT NOT NULL); INSERT INTO workspaces(paths, paths_order, remote_connection_id, timestamp) VALUES "
            + rows.joined(separator: ", ") + ";"
        try makeDatabase(home + "/Library/Application Support/Zed/db/0-preview/db.sqlite", sql: sql)
        let recents = ImportZed.recentProjects(home: home)
        #expect(recents.paths.count == 20 && recents.paths.first == home + "/Code/p24")
        let older: [SkippedItem] = [SkippedItem("5 older recent projects", "only the 20 most recent come over")]
        #expect(recents.skipped == older)
    }

    @Test func olderZedKeptPathsAsBincode() throws {
        let home = try fixture(database: false)
        defer { remove(home) }
        func bincode(_ values: [Data]) -> Data {
            var data = Data()
            func integer(_ value: Int) { withUnsafeBytes(of: UInt64(value).littleEndian) { data.append(contentsOf: $0) } }
            integer(values.count)
            for value in values {
                integer(value.count)
                data.append(value)
            }
            return data
        }
        func indices(_ values: [Int]) -> Data {
            var data = Data()
            for value in [values.count] + values { withUnsafeBytes(of: UInt64(value).littleEndian) { data.append(contentsOf: $0) } }
            return data
        }
        let paths = bincode([home + "/Code/both-a", home + "/Code/both-b"].map { Data($0.utf8) })
        let sql = "CREATE TABLE workspaces(workspace_id INTEGER PRIMARY KEY, local_paths BLOB, local_paths_order BLOB, "
            + "ssh_project_id INTEGER, timestamp TEXT NOT NULL);"
        try makeDatabase(home + "/Library/Application Support/Zed/db/0-stable/db.sqlite", sql: sql,
                         blobs: [("2026-01-02 10:00:00", paths, indices([1, 0])),
                                 ("2026-01-01 10:00:00", bincode([Data((home + "/Code/app").utf8)]), indices([0]))])
        #expect(ImportZed.recentProjects(home: home).paths == [home + "/Code/both-b", home + "/Code/app"])
        // A list that runs past its end reads as nothing.
        #expect(ImportZed.bincodePaths(paths.prefix(20)).isEmpty)
    }

    @Test func aDatabaseThatCantBeReadIsSaidSo() throws {
        let home = try fixture(database: false)
        defer { remove(home) }
        let path = home + "/Library/Application Support/Zed/db/0-stable/db.sqlite"
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))
        #expect(ImportZed.recentProjects(home: home).skipped == [SkippedItem("recent projects", "couldn't be read; quit Zed and try again")])
        // Zed's global database has no workspaces table: nothing to say.
        try fm.removeItem(atPath: path)
        try makeDatabase(home + "/Library/Application Support/Zed/db/0-global/db.sqlite", sql: "CREATE TABLE kv_store(key TEXT, value TEXT);")
        let global = ImportZed.recentProjects(home: home)
        #expect(global.paths.isEmpty && global.skipped.isEmpty)
    }

    @Test func foldersInTheOrderTheyWereOpened() {
        let three: [String] = ["/a", "/b", "/c"], two: [String] = ["/a", "/b"]
        let reordered: [String] = ["/b", "/c", "/a"]
        #expect(ImportZed.opened(three, order: [2, 0, 1]) == reordered)
        #expect(ImportZed.opened(two, order: [0, 0]) == two)
        #expect(ImportZed.opened(two, order: nil) == two)
    }

    // MARK: settings and keys

    @Test func settingsNextTermNowHas() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try plan(home)
        let settings: [ImportedSetting] = [.fontSize(14), .terminalFontSize(12), .launchOpens("welcome"), .currentLineBlame(true)]
        #expect(plan.settings.map(\.setting) == settings)
        let sources: [String] = ["buffer_font_size 14", "terminal.font_size 12", "restore_on_startup none", "git.inline_blame.enabled true"]
        #expect(plan.settings.map(\.source) == sources)
        for key in ["terminal.env", "context_servers", "language_models"] {
            #expect(plan.skipped.contains(SkippedItem(key, "never imported: can hold secrets")), "\(key)")
        }
        let text = #"{"restore_on_startup": "last_session", "git": {"inline_blame": {"enabled": "no"}}}"#
        guard let document = JSONC(text), case .object(let root)? = document.root else { return #expect(Bool(false)) }
        let rows = ImportZed.settingsRows(root.members, in: text, usKeyboard: true, home: home)
        #expect(rows.settings.map(\.setting) == [.launchOpens("lastProjects")])
        #expect(rows.skipped == [SkippedItem("git.inline_blame.enabled", "value not recognised")])
    }

    @Test func keysForTheCommandsNowMapped() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try plan(home)
        let commands = Set(plan.shortcuts.map(\.command))
        #expect(commands.isSuperset(of: ["copyFilePath:", "gitCommit:", "gitPush:", "showBranches:", "reopenClosedTab:"]))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }
}
