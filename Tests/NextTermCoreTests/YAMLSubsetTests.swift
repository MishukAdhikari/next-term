import Foundation
import Testing
@testable import NextTermCore

/// The YAML the import reads: block maps and lists, scalars in their styles, comments and documents, with what it
/// can't follow (an alias, a tag, a flow over lines) kept as a part to skip. Every file here is made up.
@Suite struct YAMLSubsetTests {
    typealias Y = YAMLSubset

    static func documents(_ lines: [String]) throws -> [Y.Node] {
        try Y.documents(lines.joined(separator: "\n")).get()
    }

    static func text(_ node: Y.Node?) -> String? { node?.scalar?.text }

    static func failure(_ lines: [String]) -> Y.Failure? {
        guard case .failure(let failure) = Y.documents(lines.joined(separator: "\n")) else { return nil }
        return failure
    }

    @Test func mapsListsOfMapsScalarsAndComments() throws {
        let docs = try Self.documents([
            "# made up for a test",
            "name: rag-api   # a comment",
            "plain: some words here",
            "single: 'it''s # not a comment'",
            #"double: "tab\there é \"q\"""#,
            "url: https://example.invalid/a#b",
            "\"quoted key\": v",
            "servers:",
            "  - name: search",
            "    env:",
            "      SEARCH_KEY: abc123",
            "  - name: fetch",
            "    args:",
            "    - -y",
            "    - fetch-server",
            "empty:",
            "",
        ])
        #expect(docs.count == 1)
        let root = docs[0]
        #expect(Self.text(root["name"]) == "rag-api")
        #expect(Self.text(root["plain"]) == "some words here")
        #expect(Self.text(root["single"]) == "it's # not a comment")
        #expect(root["single"]?.scalar?.style == .singleQuoted)
        #expect(Self.text(root["double"]) == "tab\there \u{e9} \"q\"")
        #expect(Self.text(root["url"]) == "https://example.invalid/a#b")
        #expect(Self.text(root["quoted key"]) == "v")
        let servers = try #require(root["servers"]?.items)
        #expect(servers.count == 2)
        #expect(Self.text(servers[0]["env"]?["SEARCH_KEY"]) == "abc123")
        let args: [String]? = servers[1]["args"]?.items?.compactMap { (node: Y.Node) -> String? in Self.text(node) }
        #expect(args == ["-y", "fetch-server"])
        #expect(root["empty"]?.scalar?.kind == .null)
        #expect(root["name"]?.scalar?.line == 2)
        #expect(servers[0]["env"]?["SEARCH_KEY"]?.scalar?.line == 11)
        #expect(root.pairs?.map(\.key) == ["name", "plain", "single", "double", "url", "quoted key", "servers", "empty"])
    }

    @Test func twoDocumentsAndADirective() throws {
        let docs = try Self.documents(["%YAML 1.2", "---", "kind: Secret", "---", "# only a comment", "---",
                                       "kind: ConfigMap", "...", ""])
        #expect(docs.count == 2)
        #expect(Self.text(docs[0]["kind"]) == "Secret")
        #expect(Self.text(docs[1]["kind"]) == "ConfigMap")
        #expect(docs[1]["kind"]?.scalar?.line == 7)
    }

    @Test func aListMayStandAtItsKeysIndent() throws {
        let docs = try Self.documents(["list:", "- a", "- b: c", "  d: e", "next: f"])
        let items = try #require(docs[0]["list"]?.items)
        #expect(items.count == 2 && Self.text(items[0]) == "a")
        #expect(Self.text(items[1]["d"]) == "e")
        #expect(Self.text(docs[0]["next"]) == "f")
    }

    @Test func blockScalarsKeepTheirLineBreaks() throws {
        let docs = try Self.documents([
            "literal: |",
            "  first line",
            "  second line",
            "",
            "folded: >-",
            "  one",
            "  two",
            "",
            "  three",
            "kept: |+",
            "  end",
            "",
            "single: |-",
            "  only-one-line",
            "after: x",
        ])
        let root = docs[0]
        #expect(Self.text(root["literal"]) == "first line\nsecond line\n")
        #expect(root["literal"]?.scalar?.style == .literal)
        #expect(Self.text(root["folded"]) == "one two\nthree")
        #expect(Self.text(root["kept"]) == "end\n\n")
        #expect(Self.text(root["single"]) == "only-one-line")
        #expect(Self.text(root["after"]) == "x")
    }

    @Test func quotedAndPlainValuesGoOnOverLines() throws {
        let docs = try Self.documents(["a: \"one", "  two\"", "b: plain", "  more words", "c:",
                                       "  value on its own line", "d: 'x", "", "  y'", "e: last"])
        let root = docs[0]
        #expect(Self.text(root["a"]) == "one two")
        #expect(Self.text(root["b"]) == "plain more words")
        #expect(Self.text(root["c"]) == "value on its own line")
        #expect(Self.text(root["d"]) == "x\ny")
        #expect(Self.text(root["e"]) == "last")
    }
}
