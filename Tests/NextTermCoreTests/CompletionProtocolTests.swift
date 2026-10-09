import Foundation
import Testing
@testable import NextTermCore

@Suite struct CompletionProtocolTests {
    let n = "abc123"
    func parse(_ s: String) -> ShellIntegration.Event? { ShellIntegration.parse(Array(s.utf8), nonce: n) }
    func message(_ s: String) -> CompletionProtocol.Message? {
        if case let .completion(message) = parse(s) { return message }
        return nil
    }

    /// What the shell gets from a frame: the kind, the id and the fields, decoded as `printf %b` decodes them.
    struct Decoded: Equatable {
        var kind: Character
        var id: Int
        var fields: [String]
    }

    func decode(_ frame: [UInt8]) -> Decoded? {
        let prefix = Array(CompletionProtocol.prefix.utf8)
        guard frame.starts(with: prefix), frame.count >= prefix.count + 13 else { return nil }
        let rest = Array(frame.dropFirst(prefix.count))
        guard let id = Int(String(decoding: rest[1..<7], as: UTF8.self)), let length = Int(String(decoding: rest[7..<13], as: UTF8.self)),
              rest.count == 13 + length else { return nil }
        let payload = Array(rest[13...])
        let fields = payload.isEmpty ? [] : payload.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false).map { slice -> String in
            let field = Array(slice)
            var bytes: [UInt8] = []
            var i = 0
            while i < field.count {
                if field[i] == UInt8(ascii: "\\"), i + 4 <= field.count, field[i + 1] == UInt8(ascii: "x"),
                   let byte = UInt8(String(decoding: field[(i + 2)..<(i + 4)], as: UTF8.self), radix: 16) {
                    bytes.append(byte)
                    i += 4
                } else {
                    bytes.append(field[i])
                    i += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return Decoded(kind: Character(UnicodeScalar(rest[0])), id: id, fields: fields)
    }

    func percent(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            let keep = byte >= 0x21 && byte <= 0x7E && byte != UInt8(ascii: "%") && byte != UInt8(ascii: ";") && byte != UInt8(ascii: ",")
            out += keep ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return out
    }

    @Test func parsesEachKind() {
        let arm = message("\(n);arm;2;main;start;1;0;expand-or-complete;builtin;;0")
        #expect(arm == .arm(CompletionProtocol.Arm()))
        // A server's hook from before going into folders says 1: it is sent none of those keys.
        let older = message("\(n);arm;1;main;start;1;0;expand-or-complete;builtin;;0")
        #expect(older == .arm(CompletionProtocol.Arm(version: 1)))
        let plugins = message("\(n);arm;1;viins;start;1;1;complete-word;\(percent("completion:.complete-word:_main_complete"));\(percent("autocomplete fzf-tab"));1")
        guard case let .arm(a)? = plugins else { Issue.record("no arm"); return }
        #expect(a.keymap == "viins" && a.completionSystem && a.plugins == ["autocomplete", "fzf-tab"] && a.quieted && a.takesKey)
        #expect(a.tabWidgetDefinition == "completion:.complete-word:_main_complete")

        let words = ["cd", "So"].map(percent).joined(separator: " ")
        let tab = message("\(n);tab;000007;\(percent("/tmp/a b"));\(percent("cd So"));;;\(words);So;So;;")
        #expect(tab == .tab(CompletionProtocol.TabReport(id: 7, directory: "/tmp/a b", lbuffer: "cd So", words: ["cd", "So"], word: "So",
                                                        unquoted: "So")))
        #expect(message("\(n);done;000007;native") == .done(id: 7, outcome: .native))
        #expect(message("\(n);done;000007;inserted") == .done(id: 7, outcome: .inserted))
        #expect(message("\(n);line;000007;0;Sou;Sou") == .line(.init(id: 7, left: false, word: "Sou", unquoted: "Sou")))
        #expect(message("\(n);line;000007;1") == .line(.init(id: 7, left: true)))
        #expect(message("\(n);sync;000012") == .sync(id: 12))
        #expect(message("\(n);into;000009") == .into(id: 9))
        let items = "Sources,,,d \(percent("My Fo'lder $x")),\(percent("a folder")),\(percent("local, dirs")),d main,\(percent("main  -- [HEAD]  init")),,"
        let comp = message("\(n);comp;000008;3;1;1;\(percent("My\\ F/"));\(percent("My F/"));\(items)")
        guard case let .comp(chunk)? = comp else { Issue.record("no comp"); return }
        #expect(chunk.total == 3 && chunk.matches.map(\.text) == ["Sources", "My Fo'lder $x", "main"])
        #expect(chunk.matches[1].description == "a folder" && chunk.matches[1].group == "local, dirs" && chunk.matches[2].kind == .other)
        #expect(chunk.stem == "My\\ F/" && chunk.stemUnquoted == "My F/")
        // zsh's display string, without the match it starts with.
        #expect(chunk.matches[2].description == "[HEAD]  init")
    }

    @Test func edgeCases() {
        // An empty LBUFFER and no words.
        guard case let .tab(empty)? = message("\(n);tab;000001;%2F;;;;;;;;") else { Issue.record("no tab"); return }
        #expect(empty.lbuffer == "" && empty.words == [] && empty.word == "" && !empty.unreadable)
        // An emoji and a combining accent, byte for byte.
        let word = "cafe\u{301}🙂"
        guard case let .tab(accent)? = message("\(n);tab;000002;%2F;\(percent("ls " + word));;;\(percent("ls")) \(percent(word));\(percent(word));\(percent(word));;")
        else { Issue.record("no tab"); return }
        #expect(accent.word == word && accent.words == ["ls", word] && Array(accent.word.utf8) == Array(word.utf8))
        // A field that is not valid UTF-8 is marked, not dropped.
        guard case let .tab(bad)? = message("\(n);tab;000003;%2F;ls%20%FF;;;ls %FF;%FF;%FF;;") else { Issue.record("dropped"); return }
        #expect(bad.unreadable && bad.id == 3)
        // A `line` whose word can't be read counts as the cursor leaving it.
        #expect(message("\(n);line;000003;0;%FF;%FF") == .line(.init(id: 3, left: true)))
    }

    @Test func rejectsMalformedMarks() {
        #expect(parse("arm;1;main;start;1;0;w;d;;0") == nil)                 // no nonce
        #expect(parse("wrong;arm;1;main;start;1;0;w;d;;0") == nil)          // another tab's
        #expect(message("\(n);nope;000001") == nil)                        // an unknown kind
        #expect(message("\(n);done;abc;native") == nil)                    // a non-numeric id
        #expect(message("\(n);done;-1;native") == nil)
        #expect(message("\(n);done;000001;maybe") == nil)
        #expect(message("\(n);line;000001;0;x") == nil)
        #expect(message("\(n);comp;000001;1;2;1;;;a,b,c,d") == nil)        // chunk 2 of 1
        #expect(message("\(n);comp;000001;1;1;1;;;a,b") == nil)            // an item with two fields
        #expect(message("\(n);comp;000001;1;1;1;a,b,c,d") == nil)          // no stem
        #expect(message("\(n);tab;000001;/") == nil)
        let huge = String(repeating: "A", count: 70_000)
        #expect(parse("\(n);tab;000001;\(huge);;;;;;;;") == nil)          // over 64 KiB
    }

    @Test func framesReadBackAsSent() {
        let frame = CompletionProtocol.frame(.tab, id: 42)
        #expect(frame == Array("\u{1b}[6973~t000042000000".utf8))
        #expect(decode(frame) == Decoded(kind: "t", id: 42, fields: []))
        #expect(decode(CompletionProtocol.nativeAnswer(id: 1)) == Decoded(kind: "a", id: 1, fields: ["n"]))
        #expect(decode(CompletionProtocol.openAnswer(id: 1)) == Decoded(kind: "a", id: 1, fields: ["o"]))
        let nasty = "My Fo'lder $x;\\c\n\t\u{1b}[201~café 🙂"
        #expect(decode(CompletionProtocol.insertAnswer(id: 9, word: nasty)) == Decoded(kind: "a", id: 9, fields: ["i", nasty]))
        #expect(decode(CompletionProtocol.takeWord(id: 9, old: "So", new: nasty)) == Decoded(kind: "k", id: 9, fields: ["w", "So", nasty]))
        #expect(decode(CompletionProtocol.takeMatch(id: 9, old: "", index: 12)) == Decoded(kind: "k", id: 9, fields: ["m", "", "12"]))
        #expect(decode(CompletionProtocol.close(id: 9)) == Decoded(kind: "k", id: 9, fields: ["c"]))
        #expect(decode(CompletionProtocol.frame(.config, id: 0, fields: ["q1"])) == Decoded(kind: "c", id: 0, fields: ["q1"]))
        // Suggest a Command's whole line, several lines and a `;` in it, comes back as one field.
        let line = "cd /tmp && ls; echo \"$HOME\"\nmake"
        #expect(decode(CompletionProtocol.takeLine(line)) == Decoded(kind: "k", id: 0, fields: ["l", line]))
    }

    @Test func payloadsAreASCIIWithEscapes() {
        let text = "a\\b\\c;\u{0}\u{7}\n\r\u{7f}\u{85}é🙂 x"
        let frame = CompletionProtocol.insertAnswer(id: 1, word: text)
        let payload = frame.dropFirst(CompletionProtocol.prefix.utf8.count + 13)
        // Every payload byte is printable ASCII; a `\` only starts `\xHH`; the length counts the bytes sent.
        #expect(payload.allSatisfy { $0 >= 0x21 && $0 <= 0x7E })
        let ascii = String(decoding: payload, as: UTF8.self)
        #expect(ascii.replacingOccurrences(of: #"\\x[0-9a-f]{2}"#, with: "", options: .regularExpression).contains("\\") == false)
        #expect(!ascii.contains("\\c") || ascii.contains("\\x5c"))
        let length = Int(String(decoding: frame[(CompletionProtocol.prefix.utf8.count + 7)..<(CompletionProtocol.prefix.utf8.count + 13)], as: UTF8.self))
        #expect(length == payload.count)
        #expect(decode(frame)?.fields == ["i", text])
    }

    @Test func idsWrapAtSixDigits() {
        #expect(decode(CompletionProtocol.frame(.tab, id: 1_000_001))?.id == 1)
    }

    @Test func chunksAssembleInAnyOrder() {
        func chunk(_ number: Int, _ count: Int, _ texts: [String], id: Int = 5) -> CompletionProtocol.CompChunk {
            .init(id: id, total: 3000, number: number, count: count, matches: texts.map { .init(text: $0, index: 0) })
        }
        let all = (1...2000).map { "file-\($0)" }
        var assembler = CompAssembler()
        #expect(assembler.add(chunk(3, 3, Array(all[1400...]))) == nil)
        #expect(assembler.isIncomplete(5))
        #expect(assembler.add(chunk(1, 3, Array(all[..<700]))) == nil)
        let list = assembler.add(chunk(2, 3, Array(all[700..<1400])))
        #expect(list?.map(\.text) == all && list?.first?.index == 1 && list?.last?.index == 2000 && assembler.total == 3000)
        // Another id starts over: an incomplete set is never shown.
        #expect(assembler.add(chunk(1, 2, ["a"], id: 6)) == nil)
        #expect(assembler.add(chunk(2, 2, ["b"], id: 7)) == nil)
        #expect(assembler.isIncomplete(7) && !assembler.isIncomplete(6))
    }

    @Test func installWritesBothFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zdotdir = try ShellIntegration.install(in: dir)
        let hook = try String(contentsOf: zdotdir.appendingPathComponent("completion.zsh"), encoding: .utf8)
        #expect(hook == ZshCompletionScript.script)
        #expect(!hook.contains("@NT_"), "a placeholder is left in the installed hook")
        #expect(hook.range(of: #"\beval\b"#, options: .regularExpression) == nil, "the hook evaluates text")
        let env = try String(contentsOf: zdotdir.appendingPathComponent(".zshenv"), encoding: .utf8)
        #expect(env.contains("NEXTTERM_COMPLETION") && env.contains("completion.zsh"))
    }

    /// The placeholders are plain literals (the zsh test reads them too): each must say what the constant says.
    @Test func placeholdersMatchTheConstants() {
        let values = Dictionary(uniqueKeysWithValues: ZshCompletionScript.values)
        #expect(values["@NT_PREFIX@"]?.replacingOccurrences(of: #"\e"#, with: "\u{1b}") == CompletionProtocol.prefix)
        #expect(values["@NT_VERSION@"] == String(CompletionProtocol.version))
        #expect(values["@NT_WAIT@"].flatMap(Double.init) == CompletionProtocol.shellWait)
        #expect(values["@NT_MAX_LINE@"] == String(CompletionProtocol.maxLineBytes))
        #expect(values["@NT_MAX_MATCHES@"] == String(CompletionProtocol.maxMatches))
        #expect(values["@NT_CHUNK@"] == String(CompletionProtocol.chunkBytes))
        #expect(values["@NT_FRAME_WAIT@"].flatMap(Double.init) == CompletionProtocol.frameWait)
        #expect(CompletionProtocol.answerWithin < CompletionProtocol.shellWait)
        // Every placeholder has a use, and none is left once filled.
        #expect(values.keys.allSatisfy { ZshCompletionScript.template.contains($0) })
        #expect(!ZshCompletionScript.script.contains("@NT_"))
    }

    /// The prefix is never the start of a reply a terminal sends (DA, CPR, DECRQSS, window reports, kitty
    /// keyboard flags), so a reply waiting in the input queue can't run the hook's widget.
    @Test func prefixIsNoReply() {
        let replies = ["\u{1b}[?1;2c", "\u{1b}[>0;276;0c", "\u{1b}[24;80R", "\u{1b}P1$r0m\u{1b}\\", "\u{1b}[8;24;80t", "\u{1b}[4;600;800t",
                       "\u{1b}[?0u", "\u{1b}[?1;2$y", "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\"]
        for reply in replies {
            #expect(!reply.hasPrefix(CompletionProtocol.prefix) && !CompletionProtocol.prefix.hasPrefix(reply))
        }
    }
}
