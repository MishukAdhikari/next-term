import Foundation
import Testing
@testable import NextTermCore

@Suite struct CellDetailTests {
    @Test func keysStayInOrderAndNumbersAsWritten() throws {
        let json = #"{"name":"read_file","arguments":{"path":"a.md","limit":1.0,"big":12345678901234567890,"exp":1e3}}"#
        let pretty = try #require(JSONIndent.pretty(json))
        #expect(pretty == """
            {
              "name": "read_file",
              "arguments": {
                "path": "a.md",
                "limit": 1.0,
                "big": 12345678901234567890,
                "exp": 1e3
              }
            }
            """)
        // Only whitespace changed.
        #expect(pretty.filter { !$0.isWhitespace } == json.filter { !$0.isWhitespace })
    }

    @Test func stringsKeepWhatIsInThem() throws {
        let json = #"[ "a {b} [c]", "d, e: f", "say \"hi\", ok", "back\\slash\\", {"k": "é\n"} ]"#
        #expect(JSONIndent.pretty(json) == """
            [
              "a {b} [c]",
              "d, e: f",
              "say \\"hi\\", ok",
              "back\\\\slash\\\\",
              {
                "k": "é\\n"
              }
            ]
            """)
        #expect(JSONIndent.pretty(#"{"a":{},"b":[ ],"c":[[1,2],[]]}"#) == """
            {
              "a": {},
              "b": [],
              "c": [
                [
                  1,
                  2
                ],
                []
              ]
            }
            """)
        #expect(JSONIndent.pretty("  {}") == "{}" && JSONIndent.pretty("[]") == "[]")
    }

    @Test func onlyAWholeObjectOrArrayIsJSON() {
        for text in ["5", "\"text\"", "true", "null", "{", "{\"a\":}", "[1,]", "{'a': 1}", "not json", "", "[1] trailing", "{\"a\":1}{\"b\":2}"] {
            #expect(JSONIndent.pretty(text) == nil, "\(text)")
        }
    }

    @Test func largeJSONIsQuick() throws {
        var items: [String] = []
        var size = 0
        var i = 0
        while size < 200_000 {
            let item = #"{"id":\#(i),"text":"message \#(i) with \"quotes\" and {braces}","tags":["a","b"],"score":\#(Double(i) / 3)}"#
            items.append(item)
            size += item.utf8.count + 1
            i += 1
        }
        let json = "[" + items.joined(separator: ",") + "]"
        let start = Date()
        let pretty = JSONIndent.pretty(json)
        let elapsed = Date().timeIntervalSince(start)
        #expect(pretty != nil && elapsed < 0.05, "\(elapsed) s")
    }

    @Test func hexLines() {
        #expect(CellDetail.hex(Data(), total: 0) == "")
        #expect(CellDetail.hex(Data([0x41]), total: 1) == "00000000  41" + String(repeating: " ", count: 47) + " |A|")
        let sixteen = Data((0..<16).map { UInt8($0 + 0x41) })
        #expect(CellDetail.hex(sixteen, total: 16) == "00000000  41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  |ABCDEFGHIJKLMNOP|")
        let seventeen = CellDetail.hex(Data((0..<17).map { UInt8($0) }), total: 17).components(separatedBy: "\n")
        #expect(seventeen.count == 2 && seventeen[1].hasPrefix("00000010  10 ") && seventeen[1].hasSuffix(" |.|"))
        #expect(seventeen[0].count == seventeen[1].count + 15, "the ascii column lines up")
        let png = AgentStore.png
        let lines = CellDetail.hex(png.prefix(256), total: png.count).components(separatedBy: "\n")
        #expect(lines.first == "00000000  89 50 4e 47 0d 0a 1a 0a  00 01 02 03 04 05 06 07  |.PNG............|")
        #expect(lines.count == 17 && lines[15].hasPrefix("000000f0  ") && lines.last == "\(2816.formatted()) more bytes")
    }

    @Test func labelsForEveryKind() {
        let text = CellDetail.make(column: "content", declaredType: "TEXT", value: .text(String(repeating: "a", count: 2400), truncated: false))
        #expect(text.title == "content" && text.kind == "TEXT · \(2400.formatted()) characters" && !text.isJSON && text.declaredType == "TEXT")
        #expect(CellDetail.make(column: "c", value: .text("x", truncated: false)).kind == "TEXT · 1 character")
        let json = CellDetail.make(column: "tool_call", value: .text(AgentStore.toolCall, truncated: false))
        #expect(json.kind == "JSON" && json.isJSON && json.body.hasPrefix("{\n  \"name\": \"read_file\",\n  \"arguments\": {"))
        #expect(json.copyText == AgentStore.toolCall, "Copy gives the value as stored, not the indented view")
        let integer = CellDetail.make(column: "id", value: .integer(7))
        #expect(integer.kind == "INTEGER" && integer.body == "7" && integer.copyText == "7")
        let real = CellDetail.make(column: "created", value: .real(0.1))
        #expect(real.kind == "REAL" && real.body == "0.1" && real.copyText == "0.1")
        let null = CellDetail.make(column: "tool_call", value: .null)
        #expect(null.kind == "NULL" && null.isNull && null.copyText == nil && null.note == nil)
        let blob = CellDetail.make(column: "attachment", value: .blob(3072, head: AgentStore.png.prefix(256)))
        #expect(blob.kind == "BLOB · \(3072.formatted()) bytes" && blob.isBlob && blob.copyText == nil && blob.body.hasPrefix("00000000  89 50 4e 47"))
        #expect(CellDetail.make(column: "b", value: .blob(1, head: Data([1]))).kind == "BLOB · 1 byte")
        let tab = CellDetail.make(column: "c", value: .text("a\tb\u{1B}\r\n", truncated: false))
        #expect(tab.body == "a\tb\u{1B}\r\n" && tab.copyText == "a\tb\u{1B}\r\n", "text is shown exactly as stored")
    }

    @Test func notesSayWhatWasCut() {
        let cut = SQLiteValue.text(String(repeating: "a", count: 10_000), truncated: true)
        let fetching = CellDetail.make(column: "content", value: cut, source: .page(fetching: true, isView: false))
        #expect(fetching.note == "Reading the whole value…" && fetching.kind.hasPrefix("TEXT · more than"))
        #expect(fetching.copyText == nil && !fetching.copiesPart, "Copy waits for the whole value")
        let view = CellDetail.make(column: "content", value: cut, source: .page(fetching: false, isView: true))
        #expect(view.note?.hasPrefix("A view’s rows have no key") == true)
        let huge = CellDetail.make(column: "content", value: cut, source: .whole)
        #expect(huge.note == "Over 4 MB: only its first 4 MB are shown. Copy copies that part.")
        let unkeyed = CellDetail.make(column: "content", value: cut)
        #expect(unkeyed.note?.hasPrefix("This row has no key") == true && unkeyed.note?.hasSuffix("Copy copies that part.") == true)
        #expect(view.copiesPart && unkeyed.copiesPart && huge.copiesPart && unkeyed.copyText?.count == 10_000)
        #expect(!CellDetail.make(column: "content", value: .text("whole", truncated: false)).copiesPart)
        #expect(CellDetail.make(column: "content", value: .text("whole", truncated: false), source: .whole).note == nil)
        #expect(!CellDetail.make(column: "c", value: .text("{\"a\":1", truncated: true)).isJSON, "a cut value is never taken for JSON")
    }

    /// Invisible characters show as marks in the pane, which would otherwise draw them as nothing and
    /// reorder the text around a bidi control; Copy keeps them.
    @Test func invisibleCharactersAreShownAndSaid() {
        let spoofed = CellDetail.make(column: "file", value: .text("invoice\u{202E}fdp.exe", truncated: false))
        #expect(spoofed.body == "invoice▯fdp.exe" && spoofed.copyText == "invoice\u{202E}fdp.exe" && spoofed.invisibles == 1)
        #expect(spoofed.note == "It has 1 invisible character (bidi controls, zero-width spaces), shown as ▯. Copy and Edit keep them as stored.")
        let json = CellDetail.make(column: "meta", value: .text("{\"a\":\"x\u{200B}y\u{200B}\"}", truncated: false))
        #expect(json.isJSON && json.body == "{\n  \"a\": \"x▯y▯\"\n}" && json.invisibles == 2 && json.note?.hasPrefix("It has 2 invisible characters") == true)
        let cut = CellDetail.make(column: "c", value: .text("\u{FEFF}" + String(repeating: "a", count: 9_999), truncated: true), source: .whole)
        #expect(cut.note?.hasPrefix("Over 4 MB") == true && cut.note?.hasSuffix("Copy and Edit keep them as stored.") == true, "both notes, the cut first")
        #expect(CellDetail.make(column: "x", json: "{\"k\":\"\u{2066}v\"}").body == "{\n  \"k\": \"▯v\"\n}")
        #expect(CellDetail.make(column: "c", value: .text("emoji 👨‍👩‍👧", truncated: false)).note == nil)
    }

    @Test func dataHeadValues() {
        let object = CellDetail.make(column: "meta", json: #"{"source":"doc-1.md","n":1.50}"#)
        #expect(object.isJSON && object.body == "{\n  \"source\": \"doc-1.md\",\n  \"n\": 1.50\n}" && object.copyText == #"{"source":"doc-1.md","n":1.50}"#)
        let string = CellDetail.make(column: "text", json: #""line one\nline two""#)
        #expect(string.body == "line one\nline two" && string.kind == "TEXT · 17 characters" && string.copyText == "line one\nline two")
        #expect(CellDetail.make(column: "id", json: "12").kind == "NUMBER")
        #expect(CellDetail.make(column: "ok", json: "true").kind == "BOOLEAN")
        let null = CellDetail.make(column: "x", json: "null")
        #expect(null.isNull && null.copyText == nil)
        let field = CellDetail.make(column: "question", text: "What is \"RAG\"?\nTwo lines.", cut: false)
        #expect(field.body == "What is \"RAG\"?\nTwo lines." && field.note == nil)
        let line = CellDetail.make(column: "Text", text: "2026-10-07 INFO served", cut: true)
        #expect(line.note == "Only the first 1 MB of this record were read: it is longer. Copy copies that part." && !line.isJSON && line.copiesPart)
    }
}
