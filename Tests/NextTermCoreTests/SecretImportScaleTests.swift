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
}
