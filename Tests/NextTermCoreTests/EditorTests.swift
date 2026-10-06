import Foundation
import Testing
@testable import NextTermCore

@Suite struct TextFileTests {
    @Test func roundTripsEveryFormatByteForByte() throws {
        let samples: [Data] = [
            Data("a\nb\n".utf8),
            Data("a\r\nb\r\n".utf8),                         // Windows
            Data("a\r\nb\nc".utf8),                          // mixed: kept as is
            Data("a\rb\r".utf8),                             // old Mac
            Data([0xEF, 0xBB, 0xBF]) + Data("bom\n".utf8),
            Data([0xFF, 0xFE]) + "utf16 ✓\r\n".data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + "utf16 be\n".data(using: .utf16BigEndian)!,
            Data("no final newline".utf8),
            Data("emoji 👨‍👩‍👧 and café\n".utf8),
        ]
        for data in samples {
            let (text, format) = try #require(TextFile.decode(data))
            #expect(TextFile.encode(text, as: format) == data)
        }
    }

    @Test func windowsLineEndingsBecomeNewlinesWhileEditing() throws {
        let (text, format) = try #require(TextFile.decode(Data("one\r\ntwo\r\n".utf8)))
        #expect(text == "one\ntwo\n" && format.lineEnding == .crlf)
        // A line typed in the editor, and a pasted CRLF, both save as CRLF.
        #expect(TextFile.encode(text + "three\nfour\r\n", as: format) == Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8))
        let mixed = try #require(TextFile.decode(Data("a\r\nb\n".utf8)))
        #expect(mixed.format.lineEnding == nil && mixed.text == "a\r\nb\n")
    }

    @Test func binaryAndUnknownEncodingsAreRefused() {
        #expect(TextFile.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])) == nil) // zip
        #expect(TextFile.decode(Data([0x63, 0x61, 0x66, 0xE9])) == nil)             // Latin-1 "café"
        #expect(TextFile.decode(Data()) != nil)                                      // empty is text
    }

    @Test func writeKeepsPermissionsAndSymlinks() throws {
        let dir = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("run.sh")
        try Data("echo 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)

        try TextFile.write(Data("echo 2\n".utf8), to: link)
        #expect(try String(contentsOf: script, encoding: .utf8) == "echo 2\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == script.path)
        #expect((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func stampsChangeWhenTheFileDoes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nt-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let before = try #require(FileStamp(path: file.path))
        #expect(FileStamp(path: file.path) == before)
        try Data("three".utf8).write(to: file, options: .atomic)
        #expect(FileStamp(path: file.path) != before)
        #expect(FileStamp(path: file.path + ".missing") == nil)
    }
}

@Suite struct LineIndexTests {
    /// The index after any edit must equal one built from scratch.
    @Test func incrementalEditsMatchAFullRebuild() {
        var text = "one\ntwo\n\nfour" as NSString
        var index = LineIndex(text as String)
        #expect(index.starts == [0, 4, 8, 9] && index.count == 4)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 3, length: 0), "\nnew"),     // split a line
            (NSRange(location: 0, length: 4), ""),          // delete a whole line
            (NSRange(location: 2, length: 6), "x\ny\nz"),   // replace across lines
            (NSRange(location: (text.length), length: 0), "\n"),
            (NSRange(location: 0, length: 0), "👋\n"),      // a surrogate pair is two offsets
        ]
        for (range, replacement) in edits {
            let clamped = NSRange(location: min(range.location, text.length), length: min(range.length, text.length - min(range.location, text.length)))
            text = text.replacingCharacters(in: clamped, with: replacement) as NSString
            index.replace(clamped, with: replacement)
            #expect(index == LineIndex(text as String), "after replacing \(clamped) with \(replacement.debugDescription)")
        }
    }

    @Test func findsLinesAndTheirRanges() {
        let index = LineIndex("ab\ncd\n")
        #expect(index.line(at: 0) == 0 && index.line(at: 2) == 0 && index.line(at: 3) == 1 && index.line(at: 6) == 2)
        #expect(index.range(ofLine: 1) == NSRange(location: 3, length: 3))
        #expect(index.range(ofLine: 2) == NSRange(location: 6, length: 0))
    }
}

@Suite struct EditorLanguageTests {
    @Test func picksGrammarsByNameExtensionAndShebang() {
        #expect(EditorLanguage.id(forFileName: "welcome.blade.php") == "blade")
        #expect(EditorLanguage.id(forFileName: "Alertable.php") == "php")
        #expect(EditorLanguage.id(forFileName: "Dockerfile") == "docker")
        #expect(EditorLanguage.id(forFileName: "Dockerfile.prod") == "docker")
        #expect(EditorLanguage.id(forFileName: ".env.local") == "dotenv")
        #expect(EditorLanguage.id(forFileName: "tsconfig.json") == "jsonc")
        #expect(EditorLanguage.id(forFileName: "App.TSX") == "tsx")
        #expect(EditorLanguage.id(forFileName: "deploy", firstLine: "#!/usr/bin/env bash") == "shellscript")
        #expect(EditorLanguage.id(forFileName: "tool", firstLine: "#!/usr/bin/env -S python3.12 -u") == "python")
        #expect(EditorLanguage.id(forFileName: "artisan") == "php")
        #expect(EditorLanguage.id(forFileName: "notes") == nil)
    }

    @Test func togglesLineComments() {
        let php = EditorLanguage.commentStyle(for: "php")!
        let lines = ["    if ($a) {", "", "        run();", "    }"]
        let commented = EditorLanguage.toggleComment(lines, style: php)
        #expect(commented == ["    // if ($a) {", "", "    //     run();", "    // }"])
        #expect(EditorLanguage.toggleComment(commented, style: php) == lines)
        // Mixed: some commented, some not, comments all of them.
        #expect(EditorLanguage.toggleComment(["// a", "b"], style: php) == ["// // a", "// b"])
    }

    @Test func togglesMarkupComments() {
        let html = EditorLanguage.commentStyle(for: "html")!
        #expect(EditorLanguage.toggleComment(["  <b>x</b>"], style: html) == ["  <!-- <b>x</b> -->"])
        #expect(EditorLanguage.toggleComment(["  <!-- <b>x</b> -->"], style: html) == ["  <b>x</b>"])
        #expect(EditorLanguage.commentStyle(for: "json") == nil)
    }

    @Test func detectsIndentation() {
        #expect(EditorLanguage.indentUnit(of: "a\n\tb\n\t\tc\n") == "\t")
        #expect(EditorLanguage.indentUnit(of: "a:\n  b:\n    c: 1\n  d: 2\n") == "  ")
        #expect(EditorLanguage.indentUnit(of: "class A {\n    fn() {\n        x\n    }\n}\n") == "    ")
        #expect(EditorLanguage.indentUnit(of: "flat\ntext\n") == "    ")
    }
}
