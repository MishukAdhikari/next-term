import Foundation
import Testing
@testable import NextTermCore

/// A repository opened as a project can ship a large MCP config. The scan, the groups and a plan take time that grows
/// with the file, not with its square; a scan whose task is cancelled stops between files; and a file that lists more
/// keys than the import shows is reported, not listed row by row.
@Suite struct SecretImportScaleTests {
    let clock = ContinuousClock()

    /// Long enough for a slow Mac running a debug build (about a second here); the quadratic scan took minutes.
    let limit = Duration.seconds(5)

    @Test func aLargeJSONConfigIsScannedAndPlannedInTime() throws {
        let home = F.Home()
        defer { home.remove() }
        var servers: [String] = []
        for index in 0..<10_000 { servers.append("\"s\(index)\": {\"command\": \"x\", \"args\": [\"a\", \"b\"]}") }
        // The one key, at the far end of the file.
        servers.append("\"last\": {\"command\": \"npx\", \"args\": [\"-y\", \"gh\"], \"env\": {\"GITHUB_TOKEN\": \"\(F.github)\"}}")
        home.write("proj/.mcp.json", "{\"mcpServers\": {\n" + servers.joined(separator: ",\n") + "\n}}\n")
        let sources = F.sources(home, projects: [home.path + "/proj"])
        var found = SecretImport.Scan()
        let scanning = clock.measure { found = SecretImport.scan(sources) }
        let finding = try #require(found.findings.first { $0.location.server == "last" })
        #expect(scanning < limit, "the scan took \(scanning)")

        var planned: (edits: [SecretImport.FileEdit], failures: [SecretImport.PlanFailure]) = ([], [])
        let planning = clock.measure {
            planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [finding])], nxtrm: F.nxtrm)
        }
        #expect(planned.edits.count == 1 && planned.failures.isEmpty)
        #expect(planning < limit, "the plan took \(planning)")
        let text = try #require(planned.edits.first?.plan.text)
        #expect(!text.contains(F.github) && text.contains("\"s9999\": {\"command\": \"x\", \"args\": [\"a\", \"b\"]}"))
    }

    @Test func aLargeTOMLConfigIsScannedInTime() throws {
        let home = F.Home()
        defer { home.remove() }
        var text = ""
        for index in 0..<6_000 { text += "[mcp_servers.s\(index)]\ncommand = \"x\"\nargs = [\"a\"]\n\n" }
        // Servers written with dotted keys, each listed on its own.
        text += "[mcp_servers]\n"
        for index in 0..<4_000 { text += "d\(index).command = \"x\"\n" }
        text += "d0.env.D_TOKEN = \"\(F.github)\"\n"
        home.write("proj/.codex/config.toml", text)
        let sources = F.sources(home, projects: [home.path + "/proj"])
        var found = SecretImport.Scan()
        let scanning = clock.measure { found = SecretImport.scan(sources) }
        #expect(scanning < limit, "the scan took \(scanning)")
        let dotted = found.findings.first { $0.location.server == "d0" }
        #expect(dotted?.variable == "D_TOKEN" && dotted?.movable == false && found.unreadable.isEmpty)
    }

    /// A project file that writes one server's table, and its env table, thousands of times (TOML Codex refuses): each
    /// place is read with its own keys, so the scan and a plan take time that grows with the file. Read as one list of
    /// keys for the name, which every place then walked, it took time that grows with the square of the places.
    @Test func aTOMLConfigThatRepeatsATableThousandsOfTimesIsScannedInTime() throws {
        let home = F.Home()
        defer { home.remove() }
        var text = ""
        for _ in 0..<3_000 { text += "[mcp_servers.a]\ncommand = \"x\"\nargs = [\"a\"]\n\n[mcp_servers.a.env]\nLOG = \"1\"\n\n" }
        text += "[mcp_servers.b]\ncommand = \"npx\"\nargs = [\"-y\", \"gh\"]\nenv = { GITHUB_TOKEN = \"\(F.github)\" }\n"
        home.write("proj/.codex/config.toml", text)
        let sources = F.sources(home, projects: [home.path + "/proj"])
        var found = SecretImport.Scan()
        let scanning = clock.measure { found = SecretImport.scan(sources) }
        #expect(scanning < limit, "the scan took \(scanning)")
        let finding = try #require(found.findings.first { $0.location.server == "b" })
        #expect(finding.movable && found.findings.count == 1 && found.unreadable.isEmpty)

        var planned: (edits: [SecretImport.FileEdit], failures: [SecretImport.PlanFailure]) = ([], [])
        let planning = clock.measure {
            planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [finding])], nxtrm: F.nxtrm)
        }
        #expect(planning < limit, "the plan took \(planning)")
        #expect(planned.edits.count == 1 && planned.failures.isEmpty)
    }

    /// Plans one group's move out of `relative` and writes it, each in time, and gives the file as written.
    func moveAll(_ home: F.Home, _ relative: String, count: Int) throws -> String {
        let found = SecretImport.scan(F.sources(home, projects: [home.path + "/proj"]))
        let group = try #require(SecretImport.groups(found.findings, stored: []).first)
        #expect(group.findings.count == count && group.summary == "Same value in \(count) servers")
        var planned: (edits: [SecretImport.FileEdit], failures: [SecretImport.PlanFailure]) = ([], [])
        let planning = clock.measure {
            planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: group.findings)], nxtrm: F.nxtrm)
        }
        #expect(planning < limit, "the plan took \(planning)")
        #expect(planned.failures.isEmpty && planned.edits.count == 1)
        let edit = try #require(planned.edits.first)
        #expect(edit.backups.count == count && Set(edit.servers).count == count)
        var applied: SecretImport.Applied?
        let writing = clock.measure { applied = SecretImport.apply(edit) }
        #expect(writing < limit, "the write took \(writing)")
        #expect(applied == .written)
        return home.read(relative)
    }

    /// Many keys in one large file: the plan reads the file once for all of them, and the write checks it once. Planned
    /// entry by entry (each parsed the whole file about four times), 40 entries in a 277 KB file took 19 seconds.
    @Test func manyEntriesInALargeJSONConfigArePlannedAndWrittenInTime() throws {
        let home = F.Home()
        defer { home.remove() }
        var servers: [String] = []
        for index in 0..<5_000 {
            servers.append("\"s\(index)\": {\"command\": \"x\", \"args\": [\"a\", \"b\"]}")
            if index % 125 == 0 {
                servers.append("\"k\(index)\": {\"command\": \"npx\", \"args\": [\"-y\", \"gh\"], \"env\": {\"GITHUB_TOKEN\": \"\(F.github)\", \"LOG\": \"1\"}}")
            }
        }
        home.write("proj/.mcp.json", "{\"mcpServers\": {\n" + servers.joined(separator: ",\n") + "\n}}\n")
        let text = try moveAll(home, "proj/.mcp.json", count: 40)
        #expect(!text.contains(F.github) && text.components(separatedBy: "\"secret\",\"run\",\"GITHUB_TOKEN\",\"--\",\"npx\"").count == 41)
        #expect(text.contains("\"s4999\": {\"command\": \"x\", \"args\": [\"a\", \"b\"]}\n}}\n"))
    }

    @Test func manyEntriesInALargeTOMLConfigArePlannedAndWrittenInTime() throws {
        let home = F.Home()
        defer { home.remove() }
        var text = "model = \"gpt-5\"\n\n"
        for index in 0..<3_000 {
            text += "[mcp_servers.s\(index)]\ncommand = \"x\"\nargs = [\"a\"]\n\n"
            if index % 75 == 0 {
                text += "[mcp_servers.k\(index)]\ncommand = \"npx\"\nargs = [\"-y\", \"gh\"]\nenv = { GITHUB_TOKEN = \"\(F.github)\", LOG = \"1\" }\n\n"
            }
        }
        text += "[profiles.fast]\nmodel = \"gpt-5-mini\"\n"
        home.write("proj/.codex/config.toml", text)
        let written = try moveAll(home, "proj/.codex/config.toml", count: 40)
        #expect(!written.contains(F.github) && written.components(separatedBy: "startup_timeout_sec = 30").count == 41)
        #expect(written.components(separatedBy: "env = { LOG = \"1\" }").count == 41)
        #expect(written.hasSuffix("[mcp_servers.s2999]\ncommand = \"x\"\nargs = [\"a\"]\n\n[profiles.fast]\nmodel = \"gpt-5-mini\"\n"))
    }

    @Test func manyFindingsAreGroupedInTime() {
        let source = SecretImport.Source(path: "/p/.mcp.json", client: .claudeCode, format: .json, containers: [["mcpServers"]])
        var findings: [SecretImport.Finding] = []
        for index in 0..<6_000 {
            // Two servers share each value: 3,000 groups of two.
            let value = SecretBytes(utf8: String(format: "%@%06d", F.github, index / 2))
            let location = SecretImport.Location(container: ["mcpServers"], server: "s\(index)")
            findings.append(SecretImport.Finding(id: "\(index)", source: source, location: location, field: .env("API_KEY"), variable: "API_KEY",
                                                 value: value, kind: "GitHub token", notMovable: nil, shared: false, loses: false))
        }
        var groups: [SecretImport.Group] = []
        let grouping = clock.measure { groups = SecretImport.groups(findings, stored: []) }
        #expect(grouping < limit, "grouping took \(grouping)")
        #expect(groups.count == 3_000 && groups.allSatisfy { $0.findings.count == 2 })
        #expect(groups[0].name == "API_KEY" && groups[1].name == "API_KEY_2" && groups[2_999].name == "API_KEY_3000")
    }

    /// 1,001 keys in one file: the file is reported with its reason, and none of its keys is listed. 1,000 are listed.
    @Test func aFileWithMoreKeysThanTheImportShowsIsReported() throws {
        let home = F.Home()
        defer { home.remove() }
        func config(_ count: Int) -> String {
            let servers = (0..<count).map { "\"s\($0)\": {\"command\": \"x\", \"env\": {\"API_KEY\": \"\(F.github)\($0)\"}}" }
            return "{\"mcpServers\": {" + servers.joined(separator: ", ") + "}}"
        }
        home.write("proj/.mcp.json", config(1_001))
        home.write("proj/.cursor/mcp.json", config(1_000))
        let found = SecretImport.scan(F.sources(home, projects: [home.path + "/proj"]))
        let crowded = home.file("proj/.mcp.json")
        #expect(found.findings.allSatisfy { $0.source.path != crowded })
        #expect(found.unreadable.contains { $0.source.path == crowded && $0.reason == SecretImport.tooManyReason })
        #expect(found.findings.filter { $0.source.path == home.file("proj/.cursor/mcp.json") }.count == 1_000)
    }

    /// A file the scan can't read is reported with its reason, never passed over as if it were not there: one over the
    /// 8 MB the import reads, and one this account can't open. A file that is not there, a folder and a link to nothing
    /// are passed over.
    @Test func aFileTooLargeOrClosedToTheScanIsReported() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", String(repeating: " ", count: 8 * 1024 * 1024) + F.cursorJSON)
        home.write(".codex/config.toml", F.codexTOML)
        chmod(home.file(".codex/config.toml"), 0)
        try FileManager.default.createDirectory(atPath: home.file(".gemini/settings.json"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.file(".qwen"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.file(".qwen/settings.json"), withDestinationPath: home.file("nowhere.json"))
        let found = SecretImport.scan(F.sources(home))
        let reasons = Dictionary(found.unreadable.map { ($0.source.path, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(reasons == [home.file(".cursor/mcp.json"): SecretImport.tooLargeReason, home.file(".codex/config.toml"): SecretImport.cantReadReason])
        #expect(found.findings.isEmpty && found.read.isEmpty)
    }

    /// The sheet cancels its scan when it closes: a cancelled scan reads no further file.
    @Test func aCancelledScanStopsBetweenFiles() async {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        home.write(".codex/config.toml", F.codexTOML)
        let sources = F.sources(home)
        let task = Task { () -> SecretImport.Scan in
            withUnsafeCurrentTask { $0?.cancel() }
            return SecretImport.scan(sources)
        }
        let found = await task.value
        #expect(found.read.isEmpty && found.findings.isEmpty)
        #expect(!SecretImport.scan(sources).findings.isEmpty)
    }

    /// A scan cancelled while it reads a file stops in it, and lists nothing from it: what it read of the file so far is
    /// not all the file holds.
    @Test func aScanCancelledInAFileStopsThereAndListsNothingFromIt() async {
        let home = F.Home()
        defer { home.remove() }
        var text = ""
        for index in 0..<500 { text += "[mcp_servers.s\(index)]\ncommand = \"x\"\nenv = { S_TOKEN = \"\(F.github)\" }\n\n" }
        home.write(".codex/config.toml", text)
        home.write(".cursor/mcp.json", F.cursorJSON)
        let codex = home.file(".codex/config.toml")
        let sources = F.sources(home)
        let task = Task { () -> SecretImport.Scan in
            SecretImport.scan(sources, read: { path in
                // The sheet closes as the scan reads Codex's file.
                if path == codex { withUnsafeCurrentTask { $0?.cancel() } }
                return SecretImport.readFile(path)
            })
        }
        let found = await task.value
        #expect(found.findings.allSatisfy { $0.source.path != codex } && !found.read.contains { $0.path == codex })
        #expect(found.unreadable.isEmpty)
        #expect(SecretImport.scan(sources).findings.filter { $0.source.path == codex }.count == 500)
    }

    /// Reading a file's servers is asked to stop before each one, not only once the file is done, and asks no more once
    /// told to.
    @Test func readingAFilesServersStopsWhenAsked() throws {
        let toml = (0..<100).map { "[mcp_servers.s\($0)]\ncommand = \"x\"\n" }.joined(separator: "\n")
        var asked = 0
        let tables = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked > 3 }))
        #expect(tables.count == 3 && asked == 4)
        let json = "{\"mcpServers\": {" + (0..<100).map { "\"s\($0)\": {\"command\": \"x\"}" }.joined(separator: ", ") + "}}"
        let source = SecretImport.Source(path: "/p/.mcp.json", client: .claudeCode, format: .json, containers: [["mcpServers"]])
        asked = 0
        let members = try #require(SecretImport.jsonEntries(json, source: source, stop: { asked += 1; return asked > 3 }))
        #expect(members.count < 3 && asked == 4)
        #expect(SecretImport.tomlEntries(toml)?.count == 100 && SecretImport.jsonEntries(json, source: source)?.count == 100)
    }

    /// Servers written with dotted keys only, and `~/.claude.json`'s projects with no servers in theirs, are asked about
    /// one by one too.
    @Test func readingDottedServersAndEmptyProjectsStopsWhenAsked() throws {
        let toml = "[mcp_servers]\n" + (0..<100).map { "d\($0).command = \"x\"\n" }.joined()
        var asked = 0
        let dotted = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked > 3 }))
        #expect(dotted.count == 3 && asked == 4)
        #expect(SecretImport.tomlEntries(toml)?.count == 100)
        let projects = (0..<100).map { "\"/p\($0)\": {\"mcpServers\": {}}" }.joined(separator: ", ")
        let claude = SecretImport.Source(path: "/h/.claude.json", client: .claudeCode, format: .json, containers: nil)
        asked = 0
        let none = try #require(SecretImport.jsonEntries("{\"projects\": {\(projects)}}", source: claude, stop: { asked += 1; return asked > 3 }))
        #expect(none.isEmpty && asked == 4)
    }

    /// The scan asks its own `stop` (the task's cancel, in the app) between files and inside each one: told to stop in
    /// a file, it stops there, a few servers in, and lists nothing from it.
    @Test func aScanToldToStopInAFileStopsThereAndListsNothingFromIt() {
        let home = F.Home()
        defer { home.remove() }
        var text = ""
        for index in 0..<500 { text += "[mcp_servers.s\(index)]\ncommand = \"x\"\nenv = { S_TOKEN = \"\(F.github)\" }\n\n" }
        home.write(".codex/config.toml", text)
        home.write(".cursor/mcp.json", F.standard(container: "mcpServers", variable: "GITHUB_TOKEN", value: F.github))
        let all = F.sources(home)
        let sources = [".codex/config.toml", ".cursor/mcp.json"].compactMap { relative in all.first { $0.path == home.file(relative) } }
        #expect(sources.map(\.client) == [.codex, .cursor])
        // Once before the file, before each of 10 servers (the 10th says stop), and once after the file.
        var asked = 0
        let found = SecretImport.scan(sources, stop: { asked += 1; return asked > 10 })
        #expect(asked == 12 && found.read.isEmpty && found.findings.isEmpty && found.unreadable.isEmpty)
        // Not stopped: before, in and after each file (Cursor's: its servers' object, then its one server). In Codex's,
        // once in its envs too: their 1,000 values read and 500 variables checked, one `stopEvery` of them.
        asked = 0
        let whole = SecretImport.scan(sources, stop: { asked += 1; return false })
        #expect(whole.findings.count == 501 && whole.read.count == 2 && asked == (1 + 500 + 1 + 1) + (1 + 1 + 1 + 1))
    }
}

extension SecretImportScaleTests {
    /// A server named with millions of characters: the file is reported, as one that lists too many keys is, and none of
    /// its keys is listed. Listed, the sheet would read the name again for each key's row, place and group, on the main
    /// thread. A name of 1,000 characters is listed, its entry's place worked out once, each key's id what it was.
    @Test func aNameTooLongToShowIsReported() throws {
        let home = F.Home()
        defer { home.remove() }
        let long = String(repeating: "s", count: 6_000_000)
        let env = (0..<1_000).map { "\"K\($0)_TOKEN\": \"made-up-value-\($0)\"" }.joined(separator: ", ")
        let crowded = home.write("proj/.mcp.json", "{\"mcpServers\": {\"" + long + "\": {\"command\": \"x\", \"env\": {" + env + "}}}}\n")
        // A wrapped entry is listed too, and a project's path is part of a place.
        let wrapped = "{\"command\": \"/usr/local/bin/nxtrm\", \"args\": [\"secret\", \"run\", \"A_TOKEN\", \"--\", \"x\"]}"
        let cursor = home.write("proj/.cursor/mcp.json", "{\"mcpServers\": {\"" + String(long.prefix(1_001)) + "\": " + wrapped + "}}\n")
        let project = "/" + String(repeating: "p", count: 1_001)
        let claude = home.write(".claude.json", "{\"projects\": {\"" + project + "\": {\"mcpServers\": {\"a\": "
            + "{\"command\": \"x\", \"env\": {\"API_TOKEN\": \"made-up-value-1\"}}}}}}\n")
        let found = SecretImport.scan(F.sources(home, projects: [home.path + "/proj"]))
        for path in [crowded, cursor, claude] {
            #expect(found.unreadable.contains { $0.source.path == path && $0.reason == SecretImport.longNameReason }, "\(path)")
        }
        #expect(found.findings.isEmpty && found.wrapped.isEmpty)

        // At the limit, listed; a long name with no key in it is never shown, so the file is read.
        let named = String(long.prefix(1_000))
        home.write("proj/.mcp.json", "{\"mcpServers\": {\"" + named + "\": {\"command\": \"x\", \"env\": {" + env + "}}}}\n")
        home.write("proj/.cursor/mcp.json", "{\"mcpServers\": {\"" + long + "\": {\"command\": \"x\"}}}\n")
        home.write(".claude.json", "{}\n")
        let listed = SecretImport.scan(F.sources(home, projects: [home.path + "/proj"]))
        #expect(listed.findings.count == 1_000 && listed.unreadable.isEmpty, "\(listed.unreadable)")
        let first = try #require(listed.findings.first)
        let id: String = [first.source.path, first.location.description, "\(first.field)"].joined(separator: "\u{0}")
        #expect(first.id == SecretRun.digest(Data(id.utf8)) && Set(listed.findings.map(\.id)).count == 1_000)
    }

    /// A row's server name is cut at 60 characters, as the confirm's are.
    @Test func aRowShowsAServerNameCut() {
        let sixty = String(repeating: "n", count: 60)
        #expect(SecretImport.shownServer(sixty) == sixty && SecretImport.shownServer("github") == "github")
        #expect(SecretImport.shownServer(sixty + "xyz") == sixty + "…")
    }
}
