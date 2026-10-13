import Foundation
import Testing
@testable import NextTermCore

/// A project's `.codex/config.toml` can write a dotted key a quarter of a million keys long, with a hundred thousand
/// keys beside it in its value. The scan reads such a file in time that grows with the file, not with the path's length
/// times the keys beside it; a key deeper than `TOMLReader.maxPath` is an env Codex never reads, so its server does not
/// move; and a scan told to stop stops inside one long value.
@Suite struct SecretImportTOMLPathTests {
    let clock = ContinuousClock()

    /// Long enough for a slow Mac running a debug build. With the path copied for each key beside it, the review's file
    /// took about 3×10^10 copies of a key, minutes at least, and nothing could stop it.
    let limit = Duration.seconds(5)

    let token = "GITHUB_TOKEN = \"\(F.github)\""

    /// A dotted key `parts` keys long: `k.k.….k`.
    func long(_ parts: Int) -> String { Array(repeating: "k", count: parts).joined(separator: ".") }

    /// An inline table of `count` keys beside each other, each a string: `{x="1",x="1",…}`.
    func beside(_ count: Int) -> String { "{" + Array(repeating: "x=\"1\"", count: count).joined(separator: ",") + "}" }

    /// The scan of a project's Codex file that holds `text` (that file alone, so each ask to stop is counted), and how
    /// long it took.
    func scanned(_ text: String, stop: @escaping () -> Bool = { false }) -> (found: SecretImport.Scan, took: Duration) {
        let home = F.Home()
        defer { home.remove() }
        let codex = home.write("proj/.codex/config.toml", text)
        let sources = F.sources(home, projects: [home.path + "/proj"]).filter { $0.path == codex }
        var found = SecretImport.Scan()
        let took = clock.measure { found = SecretImport.scan(sources, stop: stop) }
        return (found, took)
    }

    /// The review's file, about 1 MB: an inline env with a dotted key 250,000 keys long and, in its value, 125,000
    /// keys beside each other. Then each other place a long path can be: an env table's key, a dotted env key in the
    /// server's table, all the servers as one inline table, and a table header with as many keys under it. Each is read
    /// in time, and the token beside it is listed and does not move.
    @Test func aLongDottedKeyWithManyKeysBesideItIsReadInTime() {
        let path = long(250_000)
        let value = beside(125_000)
        let server = "[mcp_servers.a]\ncommand = \"npx\"\n"
        let files: [(name: String, text: String)] = [
            ("the review's inline env", server + "env = { \(token), \(path) = \(value) }\n"),
            ("an env table", server + "\n[mcp_servers.a.env]\n\(token)\n\(path) = \(value)\n"),
            ("dotted in the server's table", server + "env.\(token)\nenv.\(path) = \(value)\n"),
            ("all the servers inline",
             "mcp_servers = { a = { command = \"npx\", env = { \(token), \(path) = \(value) } } }\n"),
            ("a long table header", server + "env = { \(token) }\n\n[mcp_servers.a.env.\(path)]\n"
                + String(repeating: "x=\"1\"\n", count: 125_000)),
        ]
        for (name, text) in files {
            let (found, took) = scanned(text)
            #expect(took < limit, "\(name): the scan took \(took)")
            let finding = found.findings.first { $0.variable == "GITHUB_TOKEN" }
            #expect(finding?.value.utf8String() == F.github && finding?.movable == false, "\(name)")
            #expect(found.findings.count == 1 && found.read.count == 1 && found.unreadable.isEmpty, "\(name)")
        }
    }

    /// A key `TOMLReader.maxPath` keys down from the top is read as before; one key deeper, the env is a shape Codex
    /// never reads, so the server's token is listed and does not move. The same in an env table's key and in an inline
    /// table under one.
    @Test func aKeyDeeperThanTheReaderFollowsIsAnEnvThatDoesNotMove() {
        let deepest = SecretImport.TOMLReader.maxPath
        let table = "[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\n\(token)\n"
        // Under `mcp_servers.a.env`: the key's own keys, and the inline table's under `x`.
        let shapes: [(name: String, file: (_ deeper: Int) -> String)] = [
            ("an env table's key", { table + "\(long(deepest - 3 + $0)) = \"1\"\n" }),
            ("an inline table in one", { table + "x = { \(long(deepest - 4 + $0)) = \"1\" }\n" }),
        ]
        for (name, file) in shapes {
            let within = scanned(file(0)).found
            #expect(within.findings.count == 1 && within.findings.allSatisfy(\.movable), "\(name)")
            #expect(within.unreadable.isEmpty, "\(name)")
            let deeper = scanned(file(1)).found
            #expect(deeper.findings.map(\.notMovable) == [SecretImport.envShapeReason], "\(name)")
            #expect(deeper.unreadable.isEmpty, "\(name)")
        }
    }

    /// Reading one long value asks to stop once every `TOMLReader.stopEvery` values in it, and stops there when told
    /// to: one ask before the server and one in its env, then nothing more is read.
    @Test func readingOneLongValueStopsWhenAsked() throws {
        let toml = "[mcp_servers.a]\ncommand = \"npx\"\nenv = \(beside(20_000))\n"
        var asked = 0
        let stopped = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked > 1 }))
        #expect(stopped.isEmpty && asked == 2)
        // Not told to: before the server, then in its env (the table and its 20,000 values).
        asked = 0
        let whole = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return false }))
        #expect(whole.count == 1 && asked == 1 + 20_001 / SecretImport.TOMLReader.stopEvery)
        // A small value never asks.
        asked = 0
        let small = "[mcp_servers.a]\ncommand = \"x\"\nenv = { \(token) }\n"
        #expect(SecretImport.tomlEntries(small, stop: { asked += 1; return false })?.count == 1)
        #expect(asked == 1)
    }

    /// The scan, told to stop while it reads the review's file, stops inside the long value at once and lists nothing
    /// from the file: before the file, before its server, in the server's env (which says stop), and after the file.
    @Test func aScanToldToStopInTheReviewsFileStopsInsideTheValue() {
        let text = "[mcp_servers.a]\ncommand = \"npx\"\nenv = { \(token), \(long(250_000)) = \(beside(125_000)) }\n"
        var asked = 0
        let (found, took) = scanned(text, stop: { asked += 1; return asked > 2 })
        #expect(asked == 4)
        #expect(found.read.isEmpty && found.findings.isEmpty && found.unreadable.isEmpty)
        #expect(took < limit, "the scan took \(took)")
    }
}
