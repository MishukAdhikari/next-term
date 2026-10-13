import Foundation
import Testing
@testable import NextTermCore

/// Where OpenCode keeps its config folder and its session databases, from made-up homes and variables (the rules
/// of OpenCode's own `Global.Path` and `Database.path()`).
@Suite struct OpencodePathsTests {
    let home = "/Users/someone"

    func folder() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-opencode-paths-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func touch(_ path: String, minutesAgo: Double) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    // MARK: Folders

    @Test func foldersWithNoVariables() {
        #expect(OpencodePaths.configFolder(home: home, environment: [:]) == "/Users/someone/.config/opencode")
        #expect(OpencodePaths.dataFolder(home: home, environment: [:]) == "/Users/someone/.local/share/opencode")
        #expect(OpencodePaths.database(home: home, environment: [:]) == "/Users/someone/.local/share/opencode/opencode.db")
    }

    @Test func xdgFoldersWhenAbsolute() {
        let moved = ["XDG_DATA_HOME": "/x", "XDG_CONFIG_HOME": "/Volumes/Data/config/"]
        #expect(OpencodePaths.dataFolder(home: home, environment: moved) == "/x/opencode")
        #expect(OpencodePaths.configFolder(home: home, environment: moved) == "/Volumes/Data/config/opencode")
        #expect(OpencodePaths.database(home: home, environment: moved) == "/x/opencode/opencode.db")
        // A relative or empty value is ignored, as the XDG rules say.
        for ignored in [["XDG_DATA_HOME": "x", "XDG_CONFIG_HOME": "rel/config"], ["XDG_DATA_HOME": "", "XDG_CONFIG_HOME": ""]] {
            #expect(OpencodePaths.dataFolder(home: home, environment: ignored) == "/Users/someone/.local/share/opencode")
            #expect(OpencodePaths.configFolder(home: home, environment: ignored) == "/Users/someone/.config/opencode")
        }
    }

    @Test func opencodeDBPicksTheDatabase() {
        func database(_ value: String, data: String? = nil) -> String? {
            var environment = ["OPENCODE_DB": value]
            if let data { environment["XDG_DATA_HOME"] = data }
            return OpencodePaths.database(home: home, environment: environment)
        }
        #expect(database("/y/z.db") == "/y/z.db")
        #expect(database("custom.db") == "/Users/someone/.local/share/opencode/custom.db")
        #expect(database("custom.db", data: "/x") == "/x/opencode/custom.db")
        #expect(database("sub/../custom.db") == "/Users/someone/.local/share/opencode/custom.db")
        #expect(database(":memory:") == nil) // nothing on disk
        #expect(database("") == "/Users/someone/.local/share/opencode/opencode.db") // set but empty: unset
    }

    // MARK: Databases on disk

    @Test func channelDatabasesFollowTheMainOneNewestFirst() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let data = home + "/.local/share/opencode"
        try touch(data + "/opencode.db", minutesAgo: 600)
        try touch(data + "/opencode-beta.db", minutesAgo: 50)
        try touch(data + "/opencode-dev.db", minutesAgo: 10)
        try touch(data + "/opencode-local.db", minutesAgo: 300)
        try touch(data + "/opencode-old.db", minutesAgo: 200)
        try touch(data + "/opencode-1.2_x.db", minutesAgo: 100)
        try touch(data + "/opencode-old.db-wal", minutesAgo: 1) // written to most lately, through its log
        // Not channel databases: sidecars, other names, a channel name OpenCode would have replaced, a folder.
        for name in ["opencode.db-wal", "opencode-dev.db-shm", "notes.db", "opencode-.db", "opencode-a b.db", "opencode.json"] {
            try touch(data + "/" + name, minutesAgo: 0)
        }
        try FileManager.default.createDirectory(atPath: data + "/opencode-folder.db", withIntermediateDirectories: true)

        let found = OpencodePaths.databases(home: home, environment: [:])
        // At most four channel files, after opencode.db: the 300-minute one is left out.
        let names = ["opencode.db", "opencode-old.db", "opencode-dev.db", "opencode-beta.db", "opencode-1.2_x.db"]
        #expect(found == names.map { data + "/" + $0 })
        for value in ["1", "true"] {
            #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DISABLE_CHANNEL_DB": value]) == [data + "/opencode.db"])
        }
        #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DISABLE_CHANNEL_DB": "0"]) == found)
    }

    @Test func channelDatabasesWithoutTheMainOne() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let data = home + "/xdg/opencode"
        try touch(data + "/opencode-dev.db", minutesAgo: 5)
        #expect(OpencodePaths.databases(home: home, environment: ["XDG_DATA_HOME": home + "/xdg"]) == [data + "/opencode-dev.db"])
        #expect(OpencodePaths.databases(home: home, environment: [:]).isEmpty) // nothing under ~/.local/share
    }

    @Test func opencodeDBGivesOnlyItself() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let data = home + "/.local/share/opencode"
        try touch(data + "/opencode.db", minutesAgo: 5)
        try touch(data + "/opencode-dev.db", minutesAgo: 5)
        try touch(data + "/custom.db", minutesAgo: 5)
        try touch(home + "/elsewhere/sessions.db", minutesAgo: 5)
        #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DB": "custom.db"]) == [data + "/custom.db"])
        let elsewhere = home + "/elsewhere/sessions.db"
        #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DB": elsewhere]) == [elsewhere])
        #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DB": home + "/missing.db"]).isEmpty)
        #expect(OpencodePaths.databases(home: home, environment: ["OPENCODE_DB": ":memory:"]).isEmpty)
    }

    // MARK: The login shell's variables

    @Test func shellValuesKeepOnlyOneLineValuesOfItsNames() {
        let printed = ["XDG_DATA_HOME": "/Volumes/Data/xdg\n", "XDG_CONFIG_HOME": "", "OPENCODE_DB": "a.db\nFAKE=1\n",
                       "OPENCODE_DISABLE_CHANNEL_DB": "1\n", "PATH": "/bin\n"]
        #expect(OpencodePaths.shellValues(printed) == ["XDG_DATA_HOME": "/Volumes/Data/xdg", "OPENCODE_DISABLE_CHANNEL_DB": "1"])
        #expect(OpencodePaths.shellValues(["OPENCODE_DB": "custom.db"]) == ["OPENCODE_DB": "custom.db"]) // no newline: as it is
        #expect(OpencodePaths.shellValues(["OPENCODE_DB": "x.db\r\n"]).isEmpty)
        #expect(OpencodePaths.variables == ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "OPENCODE_DB", "OPENCODE_DISABLE_CHANNEL_DB"])
    }

    @Test func theShellsVariablesDecideOnlyForTheUsersOwnHome() throws {
        let other = try folder()
        defer { try? FileManager.default.removeItem(atPath: other) }
        let before = OpencodePaths.shellEnvironment
        defer { OpencodePaths.shellEnvironment = before }
        OpencodePaths.shellEnvironment = ["XDG_DATA_HOME": "/nt-made-up/data"]
        #expect(OpencodePaths.environment(home: NSHomeDirectory()) == ["XDG_DATA_HOME": "/nt-made-up/data"])
        #expect(OpencodePaths.environment(home: NSHomeDirectory() + "/") == ["XDG_DATA_HOME": "/nt-made-up/data"])
        #expect(OpencodePaths.environment(home: other).isEmpty) // a test's or the self-test's own home
    }
}
