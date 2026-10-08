import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillJSONTextTests {
    func parsed(_ text: String) throws -> SkillJSONText.Node {
        try SkillJSONText.parse(Data(text.utf8)).get()
    }

    func problem(_ text: String) -> SkillJSONText.Problem? {
        if case .failure(let problem) = SkillJSONText.parse(Data(text.utf8)) { return problem }
        return nil
    }

    /// The text a node covers, as written.
    func written(_ text: String, _ range: Range<Int>) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    @Test func membersKeepTheirPlaceAndDecodedKeys() throws {
        let text = "{\n  \"model\": \"opus\",\n  \"enabledPlugins\": {\"a@m\": true, \"b@skills-dir\": false}\n}\n"
        let root = try parsed(text)
        #expect(root.kind == .object)
        #expect(root.members.map(\.key) == ["model", "enabledPlugins"])
        #expect(written(text, root.range).hasPrefix("{") && written(text, root.range).hasSuffix("}"))
        let plugins = try #require(root.member("enabledPlugins").first?.value)
        #expect(plugins.members.map(\.key) == ["a@m", "b@skills-dir"])
        #expect(written(text, plugins.members[1].keyRange) == "\"b@skills-dir\"")
        #expect(written(text, plugins.members[1].value.range) == "false")
        #expect(plugins.members[1].value.kind == .bool)
        #expect(root.member("model").first?.value.string == "opus")
    }

    /// Comment marks, braces and escaped quotes inside strings are text, not structure.
    @Test func stringsHoldAnything() throws {
        let text = #"{"a": "{ } // /* not a comment */ \" [", "b\"c": 1, "d": "\\"}"#
        let root = try parsed(text)
        #expect(root.members.map(\.key) == ["a", "b\"c", "d"])
        #expect(root.members[0].value.string == "{ } // /* not a comment */ \" [")
        #expect(root.members[2].value.string == "\\")
    }

    @Test func escapesAreDecoded() throws {
        let root = try parsed(#"{"\u0061": "\ud83d\ude00\n\t\/"}"#)
        #expect(root.members.first?.key == "a")
        #expect(root.members.first?.value.string == "😀\n\t/")
    }

    @Test func commentsAndTrailingCommasAreNotPlainJSON() {
        #expect(problem("{\n  // a note\n  \"a\": 1\n}") == .comment)
        #expect(problem("{\"a\": 1 /* why */}") == .comment)
        #expect(problem("{\"a\": 1} // after") == .comment)
        #expect(problem("{\"a\": 1,}") == .trailingComma)
        #expect(problem("{\"a\": [1, 2,]}") == .trailingComma)
    }

    @Test func emptyTextIsNotAnObject() {
        #expect(problem("") == .empty)
        #expect(problem("  \n\t") == .empty)
    }

    @Test func brokenTextIsRefused() {
        for text in ["{a: 1}", "{\"a\": }", "{\"a\": 1} x", "{'a': 1}", "{\"a\": NaN}", "{\"a\": 01}", "{\"a\": 1",
                     "{\"a\": tru}", "{\"a\": \"line\nbreak\"}", "{\"a\": \"\\x\"}", "{\"a\" 1}", "[1 2]"] {
            #expect(problem(text) == .notJSON, "\(text)")
        }
    }

    @Test func otherValuesParse() throws {
        let root = try parsed(" [1, -2.5e+3, true, null, \"x\", {}] ")
        #expect(root.kind == .array)
        #expect(root.items.map(\.kind) == [.number, .number, .bool, .null, .string, .object])
    }

    /// Claude Code keeps the last of two equal keys and Foundation may not: a file with one is never trusted.
    @Test func duplicateKeysAreFoundAtAnyDepth() throws {
        #expect(SkillJSONText.duplicateKey(in: try parsed(#"{"a": 1, "a": 2}"#)) == "a")
        #expect(SkillJSONText.duplicateKey(in: try parsed(#"{"a": 1, "\u0061": 2}"#)) == "a")
        #expect(SkillJSONText.duplicateKey(in: try parsed(#"{"x": {"b": 1, "b": 2}}"#)) == "b")
        #expect(SkillJSONText.duplicateKey(in: try parsed(#"{"x": [{"c": 1}, {"c": 2, "c": 3}]}"#)) == "c")
        #expect(SkillJSONText.duplicateKey(in: try parsed(#"{"a": 1, "A": 2, "x": {"a": 3}}"#)) == nil)
    }

    /// Offsets count the bytes as they are, so an edit can keep a byte order mark and CRLF line ends.
    @Test func aByteOrderMarkAndCRLFAreKept() throws {
        let text = "\u{FEFF}{\r\n  \"a\": 1\r\n}\r\n"
        let result = SkillJSONText.parse(Data(text.utf8))
        let root = try result.get()
        #expect(root.range.lowerBound == 3)
        #expect(written(text, root.members[0].keyRange) == "\"a\"")
    }

    /// Deep nesting is refused, never a crash.
    @Test func deepNestingIsRefused() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(problem(deep) == .notJSON)
        let fine = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(problem(fine) == nil)
    }
}
