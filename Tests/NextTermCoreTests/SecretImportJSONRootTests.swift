import Foundation
import Testing
@testable import NextTermCore

/// A key written twice on the way to a file's servers (`mcpServers`, `projects`, a project, a project's `mcpServers`):
/// JSON parsers read the last copy, and the import read only the first. Every copy is listed now, so a key in either is
/// never missed, and none moves, so a key is never taken from, or put back in, a copy its agent doesn't read.
@Suite struct SecretImportJSONRootTests {
    static func server(_ variable: String, _ value: String) -> String {
        "{\"command\": \"npx\", \"args\": [\"-y\", \"one\"], \"env\": {\"\(variable)\": \"\(value)\"}}"
    }

    /// Each key `~/.claude.json` with `text` holds, and whether it moves.
    func listed(_ text: String) -> [String: Bool] {
        let home = F.Home()
        defer { home.remove() }
        home.write(".claude.json", text)
        let found = SecretImport.scan(F.sources(home))
        #expect(found.unreadable.isEmpty)
        return Dictionary(found.findings.map { ($0.variable, $0.movable) }, uniquingKeysWith: { $0 && $1 })
    }

    @Test func aServersObjectWrittenTwiceIsListedCopyByCopyAndNotMovable() {
        let home = F.Home()
        defer { home.remove() }
        // The review's case: the key is in the copy its agent reads. And the other way round.
        home.write(".cursor/mcp.json", "{\"mcpServers\": {}, \"mcpServers\": {\"a\": \(Self.server("GITHUB_TOKEN", F.github))}}")
        home.write(".gemini/settings.json", "{\"mcpServers\": {\"b\": \(Self.server("OPENAI_API_KEY", F.openai))}, \"mcpServers\": {}}")
        let found = SecretImport.scan(F.sources(home))
        #expect(found.findings.map(\.variable).sorted() == ["GITHUB_TOKEN", "OPENAI_API_KEY"])
        #expect(found.findings.allSatisfy { $0.notMovable == "repeated keys" } && found.unreadable.isEmpty)
    }

    @Test func claudeCodesServersWrittenTwiceOnTheWayAreListedAndNotMovable() {
        let (one, two) = (Self.server("ONE_TOKEN", F.openai), Self.server("TWO_TOKEN", F.stripe))
        let q = "\"/q\": {\"mcpServers\": {\"q\": \(Self.server("Q_TOKEN", F.github))}}"
        // `projects` twice: the top-level servers still move.
        let projects = "{\"mcpServers\": {\"top\": \(Self.server("TOP_TOKEN", F.github))}, \"projects\": {\"/p\": {\"mcpServers\": {\"one\": \(one)}}}, "
            + "\"projects\": {\"/p\": {\"mcpServers\": {\"two\": \(two)}}}}"
        #expect(listed(projects) == ["TOP_TOKEN": true, "ONE_TOKEN": false, "TWO_TOKEN": false])
        // A project twice in one `projects` (its second was never read), and a project's `mcpServers` twice.
        let project = "{\"projects\": {\"/p\": {\"mcpServers\": {\"one\": \(one)}}, \(q), \"/p\": {\"mcpServers\": {\"two\": \(two)}}}}"
        #expect(listed(project) == ["ONE_TOKEN": false, "TWO_TOKEN": false, "Q_TOKEN": true])
        let servers = "{\"projects\": {\"/p\": {\"mcpServers\": {\"one\": \(one)}, \"mcpServers\": {\"two\": \(two)}}, \(q)}}"
        #expect(listed(servers) == ["ONE_TOKEN": false, "TWO_TOKEN": false, "Q_TOKEN": true])
        // The top-level `mcpServers` twice: the projects' servers still move.
        let top = "{\"mcpServers\": {\"one\": \(one)}, \"projects\": {\(q)}, \"mcpServers\": {\"two\": \(two)}}"
        #expect(listed(top) == ["ONE_TOKEN": false, "TWO_TOKEN": false, "Q_TOKEN": true])
    }

    /// `mcpServers` and `projects` each written 20,000 times: every copy is read, in time that grows with the file.
    @Test func aRootKeyWrittenThousandsOfTimesIsReadInTime() {
        var copies: [String] = []
        for index in 0..<20_000 { copies += ["\"mcpServers\": {}", "\"projects\": {\"/p\(index)\": {\"mcpServers\": {}}}"] }
        copies.append("\"projects\": {\"/last\": {\"mcpServers\": {\"a\": \(Self.server("LAST_TOKEN", F.github))}}}")
        var found: [String: Bool] = [:]
        let took = ContinuousClock().measure { found = listed("{" + copies.joined(separator: ", ") + "}") }
        #expect(took < .seconds(5), "the scan took \(took)")
        #expect(found == ["LAST_TOKEN": false])
    }

    /// Written twice after the scan: the plan refuses, as the scan would. Written twice after the move: Undo leaves it.
    @Test func aServersObjectWrittenAgainIsNeitherMovedNorPutBack() throws {
        let home = F.Home()
        defer { home.remove() }
        let once = "{\"mcpServers\": {\"a\": \(Self.server("GITHUB_TOKEN", F.github))}}"
        home.write(".cursor/mcp.json", once)
        let finding = try #require(SecretImport.scan(F.sources(home)).findings.first)
        #expect(finding.movable)
        let move = SecretImport.Move(name: "GITHUB_TOKEN", findings: [finding])
        home.write(".cursor/mcp.json", String(once.dropLast()) + ", \"mcpServers\": {}}")
        let planned = SecretImport.plan([move], nxtrm: F.nxtrm)
        #expect(planned.edits.isEmpty && planned.failures.map(\.reason) == ["repeated keys"])

        home.write(".cursor/mcp.json", once)
        let edit = try #require(SecretImport.plan([move], nxtrm: F.nxtrm).edits.first)
        #expect(SecretImport.apply(edit) == .written)
        let moved = home.read(".cursor/mcp.json")
        let backup = try #require(edit.backups.first)
        let values = ["GITHUB_TOKEN": SecretBytes(utf8: F.github)]
        #expect(SecretImport.undoPlan(backup, current: moved, values: values, kept: []) != .changedSince)
        #expect(moved.hasSuffix("}}"))
        let twice = String(moved.dropLast()) + ", \"mcpServers\": {}}"
        #expect(SecretImport.undoPlan(backup, current: twice, values: values, kept: []) == .changedSince)
    }
}
