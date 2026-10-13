import Foundation
import Testing
@testable import NextTermCore

/// A project's `.codex/config.toml` can write a dotted key a quarter of a million keys long, with a hundred thousand
/// keys beside it in its value, or a server's name 400,000 characters long, with 40,000 keys under it. The scan reads
/// such a file in time that grows with the file, not with the path's or the name's length times the keys beside it or
/// under it. An env that is not strings four keys down (`mcp_servers.NAME.env.KEY`) is one Codex refuses, so its server
/// does not move. A scan told to stop stops inside one long value, and in an env of many short keys.
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
    /// server's table, all the servers as one inline table, and a table header with as many keys under it; and the
    /// token after the long key in the same inline table, where the path is cut back from under the long key to find the
    /// token's name.
    ///
    /// Then a server's name 400,000 characters long with 40,000 keys under it (the second review's files, 0.7 to
    /// 1.1 MB): dotted env keys in its table, a table of its own under it, an env table with no server table, and
    /// `mcp_servers = {…}`. With the name hashed again for each key under it, each of these took about 10 seconds in a
    /// debug build, four times as long for each doubling of the file, and nothing could stop it.
    ///
    /// Each is read in time, and the token is listed under its own name and does not move.
    @Test func aLongDottedKeyWithManyKeysBesideItIsReadInTime() {
        let path = long(250_000)
        let value = beside(125_000)
        let server = "[mcp_servers.a]\ncommand = \"npx\"\n"
        let longName = "\"" + String(repeating: "n", count: 400_000) + "\""
        let keys = 40_000
        let files: [(name: String, text: String)] = [
            ("the review's inline env", server + "env = { \(token), \(path) = \(value) }\n"),
            ("the review's inline env, the token last", server + "env = { \(path) = \(value), \(token) }\n"),
            ("an env table", server + "\n[mcp_servers.a.env]\n\(token)\n\(path) = \(value)\n"),
            ("dotted in the server's table", server + "env.\(token)\nenv.\(path) = \(value)\n"),
            ("all the servers inline",
             "mcp_servers = { a = { command = \"npx\", env = { \(token), \(path) = \(value) } } }\n"),
            ("all the servers inline, the token last",
             "mcp_servers = { a = { command = \"npx\", env = { \(path) = \(value), \(token) } } }\n"),
            ("a long table header", server + "env = { \(token) }\n\n[mcp_servers.a.env.\(path)]\n"
                + String(repeating: "x=\"1\"\n", count: 125_000)),
            ("a long name, dotted env keys in its table", "[mcp_servers.\(longName)]\ncommand = \"npx\"\nenv.\(token)\n"
                + String(repeating: "env.X = \"1\"\n", count: keys)),
            ("a long name, a table of its own under it", "[mcp_servers.\(longName)]\ncommand = \"npx\"\nenv = { \(token) }\n\n"
                + "[mcp_servers.\(longName).x]\n" + String(repeating: "y = \"1\"\n", count: keys)),
            ("a long name, an env table with no server table", "[mcp_servers.\(longName).env]\n\(token)\n"
                + String(repeating: "X = \"1\"\n", count: keys)),
            ("a long name, all the servers inline", "mcp_servers = { \(longName) = { command = \"npx\", env = { \(token)"
                + String(repeating: ", X = \"1\"", count: keys) + " } } }\n"),
        ]
        for (name, text) in files {
            let (found, took) = scanned(text)
            #expect(took < limit, "\(name): the scan took \(took)")
            let finding = found.findings.first { $0.variable == "GITHUB_TOKEN" }
            #expect(finding?.value.utf8String() == F.github && finding?.movable == false, "\(name)")
            #expect(found.findings.count == 1 && found.read.count == 1 && found.unreadable.isEmpty, "\(name)")
        }
    }

    /// Codex reads `env` as a map of strings, four keys down (`mcp_servers.NAME.env.KEY`), and refuses the whole file
    /// when anything else is in it. So an env table with a key below a variable, a table, a number, true or a list in it,
    /// or a dotted key 61 keys deep, is an env Codex refuses: the server's token is listed and does not move. Inline, it
    /// was already so. A string beside the token, single-line or multi-line, is an env Codex reads, and the token moves.
    @Test func anEnvThatIsNotStringsFourKeysDownDoesNotMove() {
        let table = "[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\n\(token)\n"
        for read in ["X = \"1\"", "X = '1'", "X = \"\"\"\n1\n\"\"\""] {
            let moves = scanned(table + read + "\n").found
            #expect(moves.findings.count == 1 && moves.findings.allSatisfy(\.movable), "\(read)")
            #expect(moves.unreadable.isEmpty, "\(read)")
        }
        let refused = ["X.Y = \"1\"", "X = { Y = \"1\" }", "X = {}", "X = 1", "X = true", "X = [\"1\"]", "\(long(61)) = \"1\"",
                       "\(long(250_000)) = \"1\""]
        for shape in refused {
            let found = scanned(table + shape + "\n").found
            let label = String(shape.prefix(20))
            #expect(found.findings.map(\.variable) == ["GITHUB_TOKEN"], "\(label)")
            #expect(found.findings.map(\.notMovable) == [SecretImport.envShapeReason], "\(label)")
            #expect(found.unreadable.isEmpty, "\(label)")
        }
        let inline = "[mcp_servers.a]\ncommand = \"npx\"\nenv = { \(token), X = { Y = \"1\" } }\n"
        #expect(scanned(inline).found.findings.map(\.notMovable) == [SecretImport.envShapeReason])
    }

    /// Reading a value keeps only the strings four keys down, so an env variable that is a table of 10,000 strings keeps
    /// none of them (a 7 MB file of 1.2 million kept them all, 207 MB). In `mcp_servers = {…}`, the strings are kept
    /// with the keys below the value's key, and those under one server's name share where its element starts.
    @Test func readingAValueKeepsOnlyTheStringsFourKeysDown() throws {
        let deep = try #require(TOMLOutline("[mcp_servers.a.env]\nX = \(beside(10_000))\n"))
        var read = 0
        let reader = SecretImport.TOMLReader(deep)
        let none = try #require(reader.leaves(at: deep.keys[0].value, want: 0, read: &read, stop: { false }))
        #expect(none.found.isEmpty && none.offShape && !none.stopped && read == 10_001)
        let servers = "mcp_servers = { a = { command = \"npx\", args = [\"x\"], "
            + "env = { T = \"1\", U = { V = \"2\" }, W = \"3\" } }, b.env.T = \"4\" }\n"
        let inline = try #require(TOMLOutline(servers))
        read = 0
        let inlineReader = SecretImport.TOMLReader(inline)
        let found = try #require(inlineReader.leaves(at: inline.keys[0].value, want: 3, read: &read, stop: { false }))
        #expect(found.found.map(\.path) == [["a", "env", "T"], ["a", "env", "W"], ["b", "env", "T"]])
        #expect(found.found.map(\.value) == ["1", "3", "4"] && found.offShape)
        let outer = found.found.map(\.outer)
        #expect(outer[0] == outer[1] && outer[1] != outer[2])
    }

    /// Reading one long value asks to stop once every `TOMLReader.stopEvery` values in it, and stops there when told
    /// to: one ask before the server and one in its env, then nothing more is read. The variables it holds are checked
    /// with the same count.
    @Test func readingOneLongValueStopsWhenAsked() throws {
        let toml = "[mcp_servers.a]\ncommand = \"npx\"\nenv = \(beside(20_000))\n"
        var asked = 0
        let stopped = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked > 1 }))
        #expect(stopped.isEmpty && asked == 2)
        // Not told to: before the server, then in its env (the table and its 20,000 values read, then its 20,000
        // variables checked).
        asked = 0
        let whole = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return false }))
        #expect(whole.count == 1 && asked == 1 + (20_001 + 20_000) / SecretImport.TOMLReader.stopEvery)
        // A small value never asks.
        asked = 0
        let small = "[mcp_servers.a]\ncommand = \"x\"\nenv = { \(token) }\n"
        #expect(SecretImport.tomlEntries(small, stop: { asked += 1; return false })?.count == 1)
        #expect(asked == 1)
    }

    /// The values a file's envs hold are counted across all their keys, not from nothing in each key, and so are the
    /// variables checked after them, so an env of 20,000 short keys asks to stop as it goes too, and stops there when
    /// told to: in an env table, in dotted env keys in the server's table, and in an env table with no server table
    /// (one more ask, before that server is listed). Counted for each key alone, a million of them, 8 MB, were read
    /// with no ask between them, 13 seconds in a debug build; counted only as they were read, the last 9 seconds of it,
    /// checking them, had no ask.
    @Test func anEnvOfManyShortKeysAsksToStopAsItGoes() throws {
        let many = 20_000
        let shapes: [(name: String, text: String, after: Int)] = [
            ("an env table", "[mcp_servers.a]\ncommand = \"npx\"\n[mcp_servers.a.env]\n\(token)\n"
                + String(repeating: "X = \"1\"\n", count: many), 0),
            ("dotted env keys", "[mcp_servers.a]\ncommand = \"npx\"\nenv.\(token)\n"
                + String(repeating: "env.X = \"1\"\n", count: many), 0),
            ("no server table", "[mcp_servers.a.env]\n\(token)\n" + String(repeating: "X = \"1\"\n", count: many), 1),
        ]
        let every = SecretImport.TOMLReader.stopEvery
        for (name, toml, after) in shapes {
            // Before the server's table, if it has one, and then once every `stopEvery` of its 20,001 values read and
            // its 20,001 variables checked.
            let before = after == 0 ? 1 : 0
            var asked = 0
            let whole = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return false }), "\(name)")
            #expect(whole.count == 1 && whole[0].detected.count == 1, "\(name)")
            #expect(asked == before + 2 * (many + 1) / every + after, "\(name)")
            // Told to stop at the first ask in the values: nothing more is read, and nothing is listed.
            let all = asked
            asked = 0
            let stopped = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked > before }), "\(name)")
            #expect(stopped.isEmpty && asked == before + 1, "\(name)")
            // Told to stop at the last ask, among the variables checked: nothing more is checked, and nothing is listed.
            asked = 0
            let late = try #require(SecretImport.tomlEntries(toml, stop: { asked += 1; return asked == all }), "\(name)")
            #expect(late.isEmpty && asked == all, "\(name)")
        }
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
