import Foundation
import Testing
@testable import NextTermCore

/// Connect a Tracker's catalog: each agent's own add line for a tracker's MCP server, copied from the tracker's or the
/// agent's own page, or held with its reason. A line is one command, never chained, and holds no token.
@Suite struct TrackerLinesTests {
    var everyLine: [(TrackerLines.Tracker, AgentKind, String, URL)] {
        var found: [(TrackerLines.Tracker, AgentKind, String, URL)] = []
        for tracker in TrackerLines.catalog {
            for agent in TrackerLines.agents {
                if case .line(let line, let source) = tracker.cell(for: agent) { found.append((tracker, agent, line, source)) }
            }
        }
        return found
    }

    func tracker(_ name: String) throws -> TrackerLines.Tracker {
        try #require(TrackerLines.catalog.first { $0.name == name })
    }

    @Test func everyLineIsItsAgentsAddWithTheTrackersURLAndAnOwnSource() throws {
        #expect(everyLine.count >= 12)
        for (tracker, agent, line, source) in everyLine {
            let program = try #require(TrackerLines.program(agent))
            #expect(line.hasPrefix(program + " mcp add "), "\(line)")
            let url = try #require(tracker.url)
            let words: [String] = line.split(separator: " ").map(String.init)
            #expect(words.contains(url), "\(line)")
            let host = try #require(source.host)
            let domains: [String] = tracker.domains + TrackerLines.agentDomains(agent)
            let own = domains.contains { (domain: String) -> Bool in host == domain || host.hasSuffix("." + domain) }
            #expect(own && source.scheme == "https", "\(source)")
        }
    }

    @Test func claudeLinesAreForEveryProjectAndCodexLinesHaveNoScope() {
        for (_, agent, line, _) in everyLine {
            let scopes = line.components(separatedBy: "--scope user").count - 1
            switch agent {
            case .claude: #expect(scopes == 1 && line.components(separatedBy: "--scope").count == 2, "\(line)")
            case .codex: #expect(!line.contains("--scope") && !line.contains(" -s "), "\(line)")
            default: Issue.record("only Claude Code and Codex have lines: \(line)")
            }
        }
    }

    @Test func noLineHoldsATokenOrAHeader() throws {
        for (_, _, line, _) in everyLine {
            for word in ["Bearer", "Authorization", "--client-secret", "-H", "--header"] {
                #expect(!line.contains(word), "\(line)")
            }
            #expect(MCPRedaction.redact(line, mask: .empty).count == 0, "\(line)")
            #expect(!ScrollbackText.holdsSecret(typed: line), "\(line)")
        }
        let github = try tracker("GitHub")
        guard case .line(let line, _) = github.cell(for: .codex) else {
            Issue.record("GitHub has a Codex line")
            return
        }
        #expect(line.hasSuffix(" --bearer-token-env-var GITHUB_PAT_TOKEN"))
        #expect(line.components(separatedBy: "GITHUB_PAT_TOKEN").count == 2)
        #expect(github.note(for: .codex) == "Codex reads your token from GITHUB_PAT_TOKEN in its environment; "
            + "Next Term doesn\u{2019}t set it or see it.")
    }

    @Test func heldPairsSayWhy() throws {
        let github = try tracker("GitHub")
        #expect(github.cell(for: .claude).reason == "GitHub\u{2019}s line writes your token into Claude Code\u{2019}s settings file.")
        for agent in TrackerLines.agents where agent != .opencode {
            #expect(try tracker("Asana").cell(for: agent).reason == "Asana\u{2019}s server needs an OAuth app of your own.")
            #expect(try tracker("ClickUp").cell(for: agent).reason == "No line from ClickUp\u{2019}s own page yet.")
            #expect(try tracker("Azure DevOps").cell(for: agent).reason == "No line from Azure DevOps\u{2019}s own page yet.")
        }
        for tracker in TrackerLines.catalog {
            #expect(tracker.cell(for: .gemini).reason == "No line from \(tracker.name)\u{2019}s own page yet."
                || tracker.name == "Asana", "\(tracker.name)")
            guard case .showHow(let page) = tracker.cell(for: .opencode) else {
                Issue.record("opencode has no line for \(tracker.name)")
                continue
            }
            #expect(page == TrackerLines.opencodePage)
        }
    }

    @Test func linearGivesOneCommandPerAgentEndingAtItsURL() throws {
        let linear = try tracker("Linear")
        guard case .line(let claude, _) = linear.cell(for: .claude), case .line(let codex, _) = linear.cell(for: .codex) else {
            Issue.record("Linear has a Claude Code and a Codex line")
            return
        }
        #expect(claude == "claude mcp add --transport http --scope user linear-server https://mcp.linear.app/mcp")
        #expect(codex == "codex mcp add linear --url https://mcp.linear.app/mcp")
        for line in [claude, codex] {
            #expect(line.hasSuffix(" https://mcp.linear.app/mcp"))
            for mark in [";", "&&", "|", "\n", "`", "$("] { #expect(!line.contains(mark), "\(line)") }
        }
        #expect(TrackerLines.signIn(.claude, line: claude) == "Then, in Claude Code: /mcp")
        #expect(TrackerLines.signIn(.codex, line: codex) == "Then: codex mcp login linear")
    }

    @Test func aTokenLineHasNoSignInStepAndItsRowSaysWhereTheTokenComesFrom() throws {
        let github = try tracker("GitHub")
        guard case .line(let line, _) = github.cell(for: .codex) else {
            Issue.record("GitHub has a Codex line")
            return
        }
        #expect(TrackerLines.signIn(.codex, line: line) == nil)
        #expect(github.notes(for: .codex, line: line) == [try #require(github.note(for: .codex))])
        let linear = try tracker("Linear")
        let codex = "codex mcp add linear --url https://mcp.linear.app/mcp"
        #expect(linear.notes(for: .codex, line: codex) == ["Then: codex mcp login linear"])
        let claude = "claude mcp add --transport http --scope user linear-server https://mcp.linear.app/mcp"
        #expect(linear.notes(for: .claude, line: claude) == ["Then, in Claude Code: /mcp"])
    }

    @Test func theTrackersNotListedYetEachSayWhy() {
        let rows: [String] = TrackerLines.heldSummary
        #expect(rows.count == TrackerLines.held.count)
        #expect(Set(rows) == [
            "Asana: Asana\u{2019}s server needs an OAuth app of your own.",
            "Azure DevOps: No line from Azure DevOps\u{2019}s own page yet.",
            "ClickUp: No line from ClickUp\u{2019}s own page yet.",
        ])
    }

    @Test func theListIsLinearFirstThenAlphabeticalAndOnlyTrackersWithALine() {
        let names: [String] = TrackerLines.shown.map(\.name)
        #expect(names.first == "Linear")
        let rest: [String] = Array(names.dropFirst())
        #expect(rest == rest.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        for tracker in TrackerLines.shown { #expect(tracker.hasLine) }
        #expect(!names.contains("Asana") && !names.contains("ClickUp") && !names.contains("Azure DevOps"))
        #expect(Set(TrackerLines.held.map(\.name)) == ["Asana", "ClickUp", "Azure DevOps"])
        #expect(names == ["Linear", "GitHub", "Jira", "Notion", "Plane", "Shortcut", "TickTick", "Todoist"])
    }

    @Test func theSheetRunsNothingWritesNoConfigAndReachesNoNetwork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = ["Sources/NextTermCore/TrackerLines.swift", "Sources/NextTermCore/TrackerLinesCatalog.swift",
                     "Sources/NextTerm/ConnectTrackerSheet.swift", "Sources/NextTerm/ConnectTrackerSheetBuild.swift",
                     "Sources/NextTerm/ConnectTrackerSheetActions.swift"]
        let banned = ["print(", "NSLog", "os_log", "Logger", "Process(", "NSTask", "URLSession", "URLRequest",
                      "NWConnection", "import Network", "createFile", "write(to", "contentsOfFile", ".claude.json",
                      "config.toml", "settings.json", "opencode.json"]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in banned { #expect(!source.contains(word), "\(file): \(word)") }
        }
    }

    @Test func everyLineIsPlainEnoughForAnyShell() {
        for (_, _, line, _) in everyLine {
            let plain = line.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
                scalar.isASCII && scalar.value >= 0x20 && !"'\"\\$*?#~!{}[]()<>".unicodeScalars.contains(scalar)
            }
            #expect(plain, "\(line)")
        }
    }
}
