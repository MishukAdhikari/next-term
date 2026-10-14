import Foundation
import Testing
@testable import NextTermCore

/// A hex value, the same on every run: no long-run pattern masks it, only its name does.
private func hexLine(_ count: Int) -> String {
    let digits = Array("0123456789abcdef")
    var state: UInt64 = 0x1405_7B7E_F767_814F
    return String((0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return digits[Int(state >> 60)]
    })
}

/// Whether `text` shows any 5 characters in a row of `value`.
private func showsAny(of value: String, in text: String) -> Bool {
    let characters = Array(value)
    return (0...(characters.count - 5)).contains { text.contains(String(characters[$0..<$0 + 5])) }
}

@Suite struct CarriedValueToolTests {
    /// read_file: a value on the line after its name, as a formatter writes a long assignment. The text whole masked
    /// it, but the cut at 2,000 characters looked at its line alone and kept 1,999 of its characters without the
    /// closing quote; read from an offset at its line, the name was not read at all. It is ••• in its line now.
    @Test func readFileMasksAValueNamedOnALineBefore() throws {
        let f = try ProjectFixture()
        let long = hexLine(2320)
        try f.write("api/src/config.ts", "const apiKey =\n  \"" + long + "\";\nexport default apiKey;\n")
        let whole = json(MCPProjectTools.readFile(["path": "src/config.ts", "project": "api"], in: f.both, mask: .empty))
        let text = try #require(whole["text"] as? String)
        #expect(!showsAny(of: long, in: text), "\(text.prefix(80))")
        #expect(text == "const apiKey =\n  \"•••\";\nexport default apiKey;")
        #expect(whole["redacted"] as? Int == 1 && whole["long_lines_cut"] == nil)
        let from = json(MCPProjectTools.readFile(["path": "src/config.ts", "project": "api", "offset": 2], in: f.both, mask: .empty))
        #expect(from["text"] as? String == "  \"•••\";\nexport default apiKey;" && from["redacted"] as? Int == 1)

        try f.write("api/deploy.yaml", "database:\n  password:\n\n    \"Tr0ub4dor3horse\"\n  port: 5432\n")
        let yaml = json(MCPProjectTools.readFile(["path": "deploy.yaml", "project": "api", "offset": 4], in: f.both, mask: .empty))
        #expect(yaml["text"] as? String == "    \"•••\"\n  port: 5432" && yaml["redacted"] as? Int == 1)
    }

    /// find_in_files: a match's line was redacted alone, so a value on the line after its name came back as it is,
    /// though read_file masked it in the same file. Short or long, the line shows ••• for it now, at the match's own
    /// line and column.
    @Test func findInFilesMasksAValueNamedOnALineBefore() throws {
        let f = try ProjectFixture()
        try f.write("api/src/config.ts", "const apiKey =\n  \"Tr0ub4dor&3!horse-staple\";\n")
        let short = json(MCPProjectTools.findInFiles(["query": "Tr0ub", "glob": "config.ts", "project": "api"], in: f.both,
                                                     git: nil, mask: .empty))
        let match = try #require((short["matches"] as? [[String: Any]])?.first)
        #expect(match["text"] as? String == "\"•••\";", "\(match)")
        #expect(match["line"] as? Int == 2 && match["column"] as? Int == 4 && short["redacted"] as? Int == 1)

        let long = hexLine(1500)
        try f.write("api/deploy.yaml", "password:\n  \"" + long + "\"\n")
        for probe in [String(long.prefix(12)), String(long.dropFirst(700).prefix(12)), String(long.suffix(12))] {
            let found = json(MCPProjectTools.findInFiles(["query": probe, "glob": "deploy.yaml", "project": "api"], in: f.both,
                                                         git: nil, mask: .empty))
            let text = try #require((found["matches"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(text == "\"•••\"" && !showsAny(of: long, in: text), "\(text.prefix(80))")
        }

        let quoted = hexLine(900)
        try f.write("api/src/keys.ts", "const apiKey =\n  \"" + quoted + "\"; // needle " + String(repeating: "note ", count: 80) + "\n")
        let wide = json(MCPProjectTools.findInFiles(["query": "needle", "glob": "keys.ts", "project": "api"], in: f.both,
                                                    git: nil, mask: .empty))
        let wideMatch = try #require((wide["matches"] as? [[String: Any]])?.first)
        let wideText = try #require(wideMatch["text"] as? String)
        #expect(wideText.hasPrefix("\"•••\"; // needle note") && !showsAny(of: quoted, in: wideText), "\(wideText.prefix(80))")
        #expect(wideMatch["column"] as? Int == 910)
    }
}
