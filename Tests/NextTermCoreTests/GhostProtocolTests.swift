import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostProtocolTests {
    let n = "abc123"
    func parse(_ s: String) -> ShellIntegration.Event? { ShellIntegration.parse(Array(s.utf8), nonce: n) }
    func message(_ s: String) -> GhostProtocol.Message? {
        if case let .ghost(message) = parse(s) { return message }
        return nil
    }
    func buffer(_ s: String) -> GhostProtocol.BufferReport? {
        if case let .buffer(report)? = message(s) { return report }
        return nil
    }

    /// The hook's encoder: every byte outside `!`…`~`, and `%`, `;` and `,`, as `%HH`.
    func percent(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            let keep = byte >= 0x21 && byte <= 0x7E && byte != UInt8(ascii: "%") && byte != UInt8(ascii: ";") && byte != UInt8(ascii: ",")
            out += keep ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return out
    }

    @Test func aBufferReportGivesEachField() {
        let report = buffer("\(n);buf;3;41;6;main;start;;git ch;eckout main")
        #expect(report == GhostProtocol.BufferReport(line: 3, gen: 41, cursor: 6, buffer: "git ch", postdisplay: "eckout main"))
        #expect(report?.atEnd == true)
        let vi = buffer("\(n);buf;3;42;2;viins;cont;ri;ls;")
        #expect(vi?.keymap == "viins" && vi?.context == "cont" && vi?.region == true && vi?.isearch == true)
        #expect(vi?.buffer == "ls" && vi?.postdisplay == "" && vi?.atEnd == true)
        #expect(buffer("\(n);buf;3;43;1;main;start;;ls;")?.atEnd == false)
    }

    /// Printable ASCII goes as it is but for `%` and `;` (the hook's fast path); anything else as the full encoder sends it.
    @Test func textFieldsDecode() {
        #expect(buffer("\(n);buf;1;2;10;main;start;;echo 50%25%3B x;")?.buffer == "echo 50%; x")
        let line = "echo héllo; 50%"
        let report = buffer("\(n);buf;1;2;15;main;start;;\(percent(line));\(percent("…, \u{1b}"))")
        #expect(report?.buffer == line && report?.postdisplay == "…, \u{1b}" && report?.atEnd == true)
        // zsh's CURSOR counts code points: a combining accent is one more.
        #expect(buffer("\(n);buf;1;2;6;main;start;;\(percent("cafe\u{301}"));")?.atEnd == false)
        #expect(buffer("\(n);buf;1;2;5;main;start;;\(percent("cafe\u{301}"));")?.atEnd == true)
    }

    @Test func aLineNextTermCantReadHasNoText() {
        // Not valid UTF-8: no text, so nothing is matched against it.
        let bad = buffer("\(n);buf;1;2;1;main;start;;%FF;%FE")
        #expect(bad != nil && bad?.buffer == nil && bad?.postdisplay == nil && bad?.atEnd == false)
        // Over the hook's cap: sent empty, flagged.
        let long = buffer("\(n);buf;1;2;3000;main;start;l;;eckout")
        #expect(long?.buffer == nil && long?.postdisplay == "eckout")
        #expect(buffer("\(n);buf;1;2;3;main;start;L;git;")?.postdisplay == nil)
    }

    @Test func malformedReportsAreRefused() {
        #expect(buffer("\(n);buf;1;2;3;main;start;;git") == nil) // a field short
        #expect(buffer("\(n);buf;1;2;3;main;start;;git;;x") == nil) // one too many
        #expect(buffer("\(n);buf;1;1234567890;3;main;start;;git;") == nil) // 10 digits
        #expect(buffer("\(n);buf;x;2;3;main;start;;git;") == nil)
        #expect(buffer("\(n);buf;1;-2;3;main;start;;git;") == nil)
        #expect(buffer("\(n);buf;1;2;;main;start;;git;") == nil)
        // The wrong nonce, or none.
        #expect(ShellIntegration.parse(Array("other;buf;1;2;3;main;start;;git;".utf8), nonce: n) == nil)
        #expect(ShellIntegration.parse(Array("buf;1;2;3;main;start;;git;".utf8), nonce: n) == nil)
    }

    @Test func theHookMarkNamesThePlugin() {
        #expect(message("\(n);ghost;1;;0;") == .hook(GhostProtocol.Hook()))
        let atuin = message("\(n);ghost;1;zsh-autosuggestions;1;\(percent("atuin history"))")
        #expect(atuin == .hook(GhostProtocol.Hook(plugin: "zsh-autosuggestions", enabled: true, strategies: ["atuin", "history"])))
        #expect(message("\(n);ghost;2;zsh-autosuggestions;0;history") == .hook(GhostProtocol.Hook(version: 2, plugin: "zsh-autosuggestions",
                                                                                                   strategies: ["history"])))
        #expect(message("\(n);ghost;0;;0;") == nil)
        #expect(message("\(n);ghost;1;;2;") == nil)
        #expect(message("\(n);ghost;1;;0") == nil)
    }

    @Test func aFallbackAnswerMayBeNone() {
        #expect(message("\(n);gfb;12;\(percent("kubectl get pods"))") == .fallback(gen: 12, line: "kubectl get pods"))
        #expect(message("\(n);gfb;12;") == .fallback(gen: 12, line: nil))
        #expect(message("\(n);gfb;12;%FF") == .fallback(gen: 12, line: nil))
        #expect(message("\(n);gfb;;x") == nil)
    }

    /// The placeholders are plain literals (the zsh test reads them too): each must say what the constant says.
    @Test func placeholdersMatchTheConstants() {
        let values = Dictionary(uniqueKeysWithValues: ZshGhostScript.values)
        #expect(values["@NG_PREFIX@"]?.replacingOccurrences(of: #"\e"#, with: "\u{1b}") == GhostProtocol.prefix)
        #expect(values["@NG_VERSION@"] == String(GhostProtocol.version))
        #expect(values["@NG_MAX_LINE@"] == String(GhostProtocol.maxLineBytes))
        #expect(values["@NG_FRAME_WAIT@"].flatMap(Double.init) == GhostProtocol.frameWait)
        #expect(values.keys.allSatisfy { ZshGhostScript.template.contains($0) })
        #expect(!ZshGhostScript.script.contains("@NG_"))
        // Each hook keeps a key of its own.
        #expect(Set([GhostProtocol.prefix, CompletionProtocol.prefix, ShellHistory.prefix]).count == 3)
    }

    /// The hook reports and binds; it never changes the history, starts a process or evaluates the line.
    @Test func theHookOnlyReports() {
        let script = ZshGhostScript.script
        for word in ["setopt", "unsetopt", "HISTFILE", "SAVEHIST", "HISTSIZE", "fc ", "print -s", "command "] {
            #expect(!script.contains(word), "the hook says \(word)")
        }
        let code = script.split(separator: "\n").filter { !$0.drop(while: { $0 == " " }).hasPrefix("#") }.joined(separator: "\n")
        #expect(!code.contains("`") && code.range(of: #"\$\([^(]"#, options: .regularExpression) == nil, "the hook substitutes a command")
        #expect(script.range(of: #"\beval\b"#, options: .regularExpression) == nil, "the hook evaluates text")
        #expect(script.contains("(( PENDING || ${KEYS_QUEUED_COUNT:-0} )) && return 0"))
        #expect(script.contains("add-zle-hook-widget $hook $fn") && script.contains("line-pre-redraw __nextterm_gredraw"))
    }

    @Test func installWritesTheHookAndTheIntegrationLoadsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-ghost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let zdotdir = try ShellIntegration.install(in: dir)
        let file = zdotdir.appendingPathComponent("ghost.zsh")
        #expect(try String(contentsOf: file, encoding: .utf8) == ZshGhostScript.script)
        let env = try String(contentsOf: zdotdir.appendingPathComponent(".zshenv"), encoding: .utf8)
        #expect(env.contains(#"builtin source "$__nextterm_dir/ghost.zsh""#) && env.contains("unset NEXTTERM_GHOST"))
        #expect(ShellIntegration.ghostVariable == "NEXTTERM_GHOST")
        // Written only when it changed: a second install leaves the file as it was.
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        _ = try ShellIntegration.install(in: dir)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(written != nil && after == Date(timeIntervalSince1970: 1_000_000))
    }
}
