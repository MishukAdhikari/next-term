import Foundation
import Testing
@testable import NextTermCore

/// What the import's YAML reader skips or refuses: aliases, tags and flows over lines are parts to skip, a tab in
/// indentation, a quote left open and nesting past the depth are refused with their line. Every file here is made up.
@Suite struct YAMLSubsetEdgeTests {
    typealias Y = YAMLSubset
    typealias T = YAMLSubsetTests

    @Test func yesAndOnAreBooleansUnlessQuoted() throws {
        let lines = ["a: yes", "b: on", "c: 'yes'", "d: Off", "e: 8080", "f: 0x1F", "g: 1.5e3", "h: ~", "i: null",
                     "j: 12ab", "k: .inf", "l: \"8080\"", "m: n"]
        let root = try #require(try T.documents(lines).first)
        let kinds: [Y.Kind?] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"].map {
            (key: String) -> Y.Kind? in root[key]?.scalar?.kind
        }
        let expected: [Y.Kind?] = [.boolean, .boolean, .string, .boolean, .number, .number, .number, .null, .null,
                                   .string, .number, .string, .boolean]
        #expect(kinds == expected)
        #expect(T.text(root["e"]) == "8080")
    }

    @Test func anAliasATagAndAFlowOverLinesArePartsToSkip() throws {
        let root = try #require(try T.documents([
            "base: &shared",
            "  LOG_LEVEL: debug",
            "copy: *shared",
            "merged:",
            "  <<: *shared",
            "tagged: !secret abc123",
            "binary: !!binary |",
            "  aGVsbG8=",
            "flow: [one, two,",
            "  three]",
            "after: x",
        ]).first)
        #expect(T.text(root["base"]?["LOG_LEVEL"]) == "debug")
        #expect(root["copy"] == .skipped(.alias, line: 3))
        #expect(root["merged"]?["<<"] == .skipped(.alias, line: 5))
        #expect(root["tagged"] == .skipped(.tag, line: 6))
        #expect(root["binary"] == .skipped(.tag, line: 7))
        #expect(root["flow"] == .skipped(.flow, line: 9))
        #expect(T.text(root["after"]) == "x")
    }

    @Test func flowCollectionsOnOneLineAreRead() throws {
        let root = try #require(try T.documents([
            #"args: ["-y", 'pkg', plain word]"#,
            #"env: {API_TOKEN: abc123, EMPTY: , 'quoted key': "v"}"#,
            "none: []",
            "nothing: {}",
            "nested: [[a, b], {c: d}]  # comment",
            "ports: [\"3000:3000\", 8080:80]",
        ]).first)
        let args: [String]? = root["args"]?.items?.compactMap { (node: Y.Node) -> String? in T.text(node) }
        #expect(args == ["-y", "pkg", "plain word"])
        #expect(T.text(root["env"]?["API_TOKEN"]) == "abc123")
        #expect(root["env"]?["EMPTY"]?.scalar?.kind == .null)
        #expect(T.text(root["env"]?["quoted key"]) == "v")
        #expect(root["none"]?.items?.isEmpty == true && root["nothing"]?.pairs?.isEmpty == true)
        #expect(T.text(root["nested"]?.items?.first?.items?.last) == "b")
        #expect(T.text(root["nested"]?.items?.last?["c"]) == "d")
        #expect(T.text(root["ports"]?.items?.last) == "8080:80")
    }

    @Test func aTabInIndentationIsRefusedWithItsLine() throws {
        let failure = try #require(T.failure(["services:", "  web:", "\tenvironment:", "      A: b"]))
        #expect(failure.line == 3 && failure.reason == .tabIndent)
        #expect(failure.sentence == "Line 3 is indented with a tab, which YAML doesn\u{2019}t allow.")
        // A tab after a key's colon, inside a value or before a comment is not indentation.
        let root = try #require(try T.documents(["key:\tvalue", "other: a\tb", "\t# a note", "last: c"]).first)
        #expect(T.text(root["key"]) == "value" && T.text(root["other"]) == "a\tb" && T.text(root["last"]) == "c")
    }

    @Test func anOpenQuoteDeepNestingAndAStrayLineAreRefused() throws {
        let open = try #require(T.failure(["a: \"open", "b: c"]))
        #expect(open.line == 1 && open.reason == .unclosedQuote)
        let deep: [String] = (0..<(Y.maxDepth + 2)).map { (level: Int) -> String in
            String(repeating: "  ", count: level) + "k\(level):"
        }
        #expect(T.failure(deep + [String(repeating: "  ", count: Y.maxDepth + 2) + "v"])?.reason == .tooDeep)
        let stray = try #require(T.failure(["a:", "    b: c", "  d: e"]))
        #expect(stray.line == 3 && stray.reason == .indentation)
        #expect(T.failure(["? complex", ": key"])?.reason == .complexKey)
        #expect(T.failure([#"a: "bad \q escape""#])?.reason == .badEscape)
    }

    @Test func aLongFileIsReadInOnePass() throws {
        let count = 60_000
        var lines: [String] = ["items:"]
        for number in 0..<count { lines.append("  - {name: K\(number), value: v\(number)}") }
        var docs: [Y.Node] = []
        let elapsed: Duration = try ContinuousClock().measure { docs = try T.documents(lines) }
        #expect(elapsed < .seconds(10), "\(elapsed)")
        #expect(docs.first?["items"]?.items?.count == count)
        let many: String = String(repeating: "- a\n", count: Y.maxNodes + 1)
        guard case .failure(let failure) = Y.documents(many) else { return #expect(Bool(false)) }
        #expect(failure.reason == .tooMany)
    }
}
