import Foundation
import Testing
@testable import NextTermCore

/// The TOML reader the terminal importers share: TOML 1.0 as written, and hostile files refused whole without
/// going deep or slow.
@Suite struct ImportTOMLTests {
    func parse(_ text: String) -> [String: TOMLValue]? {
        if case .success(let root) = TOMLReader.parse(text) { return root }
        return nil
    }

    func error(_ text: String) -> TOMLError? {
        if case .failure(let error) = TOMLReader.parse(text) { return error }
        return nil
    }

    @Test func tablesKeysAndValues() throws {
        let root = try #require(parse("""
            # a comment
            title = "Alacritty" # trailing comment
            "quoted key" = 'literal \\n stays'
            a.b.c = 1
            [font]
            size = 14.5
            normal = { family = "Fira Code", style = "Regular" }
            [font.bold]
            family = "Hack"
            [[keyboard.bindings]]
            key = "T"
            [[keyboard.bindings]]
            key = "N"
            mods = "Command|Shift"
            """))
        let value = TOMLValue.table(root)
        #expect(value["title"] == .string("Alacritty"))
        #expect(value["quoted key"] == .string("literal \\n stays"))
        #expect(value["a", "b", "c"] == .integer(1))
        #expect(value["font", "size"] == .float(14.5))
        #expect(value["font", "normal", "family"]?.string == "Fira Code")
        #expect(value["font", "bold", "family"]?.string == "Hack")
        let bindings = try #require(value["keyboard", "bindings"]?.array)
        #expect(bindings.count == 2)
        #expect(bindings[1].table?["mods"] == .string("Command|Shift"))
    }

    @Test func numbersStringsAndArrays() throws {
        let root = try #require(parse(#"""
            hex = 0xFF
            octal = 0o17
            binary = 0b101
            big = 1_000_000
            negative = -42
            float = 6.02e23
            inf = -inf
            yes = true
            date = 1979-05-27T07:32:00Z
            spaced = 1979-05-27 07:32:00
            time = 07:32:00
            escaped = "tab\there \u00e9 \"q\""
            multi = """
            one \
              two"""
            raw = '''
            C:\path\'''
            list = [ 1, 2,
              3, # a comment
            ]
            nested = [[1, 2], ["a"]]
            inline = {
              a = 1,
              b.c = "x",
            }
            """#))
        let value = TOMLValue.table(root)
        #expect(value["hex"] == .integer(255))
        #expect(value["octal"] == .integer(15))
        #expect(value["binary"] == .integer(5))
        #expect(value["big"] == .integer(1_000_000))
        #expect(value["negative"] == .integer(-42))
        #expect(value["float"] == .float(6.02e23))
        #expect(value["inf"] == .float(-.infinity))
        #expect(value["yes"] == .bool(true))
        #expect(value["date"] == .datetime("1979-05-27T07:32:00Z"))
        #expect(value["spaced"] == .datetime("1979-05-27 07:32:00"))
        #expect(value["time"] == .datetime("07:32:00"))
        #expect(value["escaped"] == .string("tab\there é \"q\""))
        #expect(value["multi"] == .string("one two"))
        #expect(value["raw"] == .string("C:\\path\\"))
        #expect(value["list"] == .array([.integer(1), .integer(2), .integer(3)]))
        let nested: Int? = value["nested"]?.array?.count
        #expect(nested == 2)
        #expect(value["inline", "b", "c"] == .string("x"))
    }

    @Test func invalidFilesAreRefusedWhole() {
        let bad = [
            "a = ",                       // no value
            "a = 1\na = 2",               // a key twice
            "[t]\nx = 1\n[t]",            // a table twice
            "a = \"open",                 // a string left open
            "a = [1, 2",                  // an array left open
            "a = { b = 1 }\na.c = 2",     // an inline table is closed
            "a = 1 b = 2",                // two values on a line
            "a = 01",                     // a leading zero
            "a = 1__0",                   // underscores not between digits
            "a = 99999999999999999999",   // out of range
            "a = \"\\q\"",                // an escape TOML doesn't have
            "a = 1.",                     // a point without digits after it
            "= 1",                        // no key
            "a = nope",                   // a bare word
            "a = \"bell\u{7}\"",          // a control character
        ]
        for text in bad {
            #expect(error(text) != nil, "\(text)")
        }
        #expect(error("a = 1\nb = \n")?.line == 2)
    }

    /// A hostile file: deep nesting, long dotted keys, a huge file. Each is refused quickly, never followed down.
    @Test func hostileInput() {
        let deepArray = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(error("a = " + deepArray)?.message == "arrays and tables too deep")
        let deepTable = String(repeating: "{ a = ", count: 5_000) + "1" + String(repeating: " }", count: 5_000)
        #expect(error("x = " + deepTable) != nil)
        let longKey = (0..<1_000).map { "k\($0)" }.joined(separator: ".")
        #expect(error(longKey + " = 1") != nil)
        #expect(error("[" + longKey + "]") != nil)
        let huge = String(repeating: "# filler line\n", count: TOMLReader.maxBytes / 14 + 10)
        #expect(error(huge)?.message == "the file is too large")
        // At the limit, nesting is still read.
        let ok = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        #expect(parse("a = " + ok) != nil)
        // A very long line of numbers is fine, and quick.
        let many = "a = [" + (0..<20_000).map(String.init).joined(separator: ",") + "]"
        let count: Int? = parse(many)?["a"]?.array?.count
        #expect(count == 20_000)
    }

    @Test func byteOrderMarkAndLineEndings() throws {
        let root = try #require(parse("\u{FEFF}a = 1\r\n[b]\r\nc = \"x\"\r\n"))
        #expect(TOMLValue.table(root)["b", "c"] == .string("x"))
    }
}
