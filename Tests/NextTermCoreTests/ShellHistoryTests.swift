import Foundation
import Testing
@testable import NextTermCore

@Suite struct ShellHistoryTests {
    let n = "abc123"
    func parse(_ s: String) -> ShellIntegration.Event? { ShellIntegration.parse(Array(s.utf8), nonce: n) }

    /// A naming key split as the hook reads it: the kind, the length and the payload; nil when it isn't one.
    func split(_ key: [UInt8]) -> (kind: Character, length: Int, payload: String)? {
        let prefix = Array(ShellHistory.prefix.utf8)
        guard key.starts(with: prefix), key.count >= prefix.count + 7 else { return nil }
        let rest = Array(key.dropFirst(prefix.count))
        guard let length = Int(String(decoding: rest[1..<7], as: UTF8.self)), rest.count == 7 + length else { return nil }
        return (Character(UnicodeScalar(rest[0])), length, String(decoding: rest[7...], as: UTF8.self))
    }

    /// What zsh's `printf %b` makes of a payload: the line the hook keeps.
    func zshDecoded(_ payload: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", #"printf %b "$1""#, "zsh", payload]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    @Test func theKeyNamesTheLineInPrintableASCII() throws {
        let line = "claude --resume 3f2a; echo \"é\" \\c $(x)\nnext\tline"
        let key = try #require(ShellHistory.naming(line))
        let parts = try #require(split(key))
        #expect(parts.kind == "h" && parts.length == parts.payload.utf8.count)
        // Nothing the line editor would act on: no control byte, no raw `\`, `;` or byte above 0x7E.
        #expect(parts.payload.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E })
        #expect(!parts.payload.contains(";") && !parts.payload.replacingOccurrences(of: #"\x"#, with: "").contains("\\"))
        #expect(try zshDecoded(parts.payload) == Data(line.utf8))
    }

    /// Every hard line comes back from zsh's own decoder byte for byte.
    @Test(arguments: ShellQuoteTests.nasty) func namedLinesRoundTripThroughZsh(_ line: String) throws {
        let key = try #require(ShellHistory.naming(line))
        let parts = try #require(split(key))
        #expect(try zshDecoded(parts.payload) == Data(line.utf8), "\(line.debugDescription)")
    }

    @Test func aLineTooLongToNameGetsAPlainReturn() {
        let long = String(repeating: "x", count: ShellHistory.maxPayloadBytes + 1)
        #expect(ShellHistory.naming(long) == nil)
        #expect(ShellHistory.submit(typed: long, armed: true) == [0x0D])
        let most = String(repeating: "x", count: ShellHistory.maxPayloadBytes)
        #expect(ShellHistory.naming(most).flatMap { split($0)?.length } == ShellHistory.maxPayloadBytes)
        #expect(ShellHistory.naming("").flatMap { split($0)?.length } == 0)
    }

    @Test func theLineIsNamedAsZshHoldsIt() {
        // typeText makes every line break a carriage return; zsh's bracketed paste makes each a newline again.
        #expect(ShellHistory.heldLine("echo a\recho b\r\necho c\nd") == "echo a\necho b\necho c\nd")
        #expect(ShellHistory.heldLine("plain\tline") == "plain\tline")
    }

    @Test func aReturnNamesTheLineOnlyWhenArmed() throws {
        #expect(ShellHistory.submit(typed: "echo hi", armed: false) == [0x0D])
        let armed = ShellHistory.submit(typed: "echo a\recho b", armed: true)
        #expect(armed.last == 0x0D)
        let key = Array(armed.dropLast())
        #expect(key == ShellHistory.naming("echo a\necho b"))
        #expect(try zshDecoded(try #require(split(key)).payload) == Data("echo a\necho b".utf8))
    }

    @Test func readinessLastsForTheLineTheHookMarked() {
        var ready = ShellHistory.Readiness()
        #expect(!ready.armed)
        ready.marked(version: 1)
        #expect(ready.armed)
        // Keys and pastes on the line keep it; a Return inside a paste is text.
        ready.input(Array("echo hi".utf8))
        ready.input(Array("\u{1b}[200~one\rtwo\u{1b}[201~".utf8))
        #expect(ready.armed)
        // A paste split over writes: its Return is text until the paste ends.
        ready.input(Array("\u{1b}[200~one".utf8))
        ready.input([0x0D])
        #expect(ready.armed)
        ready.input(Array("two\u{1b}[201~".utf8))
        #expect(ready.armed)
        // Return, ^C, ^D, ^Z or a kitty-encoded Return end the line, and the key's turn with it.
        for ending: [UInt8] in [[0x0D], [0x03], [0x04], [0x1A], Array("\u{1b}[13u".utf8)] {
            ready.marked(version: 1)
            ready.input(ending)
            #expect(!ready.armed, "\(ending)")
        }
        // A command started, the shell was replaced: not armed until the next mark.
        ready.marked(version: 1)
        ready.disarm()
        #expect(!ready.armed)
        ready.marked(version: 0)
        #expect(!ready.armed)
    }

    /// A line typed as a new prompt comes gets its Return once the hook has marked that line, `markWait` at most.
    @Test func aReturnWaitsForTheNewLinesMark() {
        var ready = ShellHistory.Readiness()
        #expect(!ready.awaitsMark(at: 0))
        // The first prompt: the hook loads at it, so its mark is waited for, until it comes.
        ready.prompted(at: 10)
        #expect(ready.awaitsMark(at: 10.2) && !ready.armed)
        ready.marked(version: 1)
        #expect(!ready.awaitsMark(at: 10.3) && ready.armed)
        // A command ran and ended: the next prompt's mark is waited for, but never past markWait.
        ready.input([0x0D])
        ready.disarm()
        ready.prompted(at: 20)
        #expect(ready.awaitsMark(at: 20.5) && !ready.armed)
        #expect(!ready.awaitsMark(at: 20 + ShellHistory.markWait))
        // Anything that ends the line meanwhile ends the wait: the Return that comes is a plain one.
        ready.prompted(at: 30)
        ready.input(Array("x".utf8))
        #expect(ready.awaitsMark(at: 30.1))
        ready.input([0x03])
        #expect(!ready.awaitsMark(at: 30.1))
        ready.prompted(at: 40)
        ready.disarm()
        #expect(!ready.awaitsMark(at: 40.1))
    }

    /// A shell whose first prompt brought no mark (no hook) is never waited for again; a new shell starts over.
    @Test func aShellWithoutTheHookIsWaitedForOnce() {
        var ready = ShellHistory.Readiness()
        ready.prompted(at: 1)
        #expect(ready.awaitsMark(at: 1.1))
        ready.prompted(at: 1.2)
        #expect(!ready.awaitsMark(at: 1.3))
        // The hook marks a later line after all (a plugin had taken zle-line-init at the first prompt): from then on.
        ready.marked(version: 1)
        ready.prompted(at: 9)
        #expect(ready.awaitsMark(at: 9.1))
        ready.shellReplaced()
        #expect(ready == ShellHistory.Readiness())
    }

    @Test func parsesTheHistMark() {
        #expect(parse("\(n);hist;1") == .history(version: 1))
        #expect(parse("\(n);hist;2") == .history(version: 2))
        #expect(parse("\(n);hist;0") == nil)
        #expect(parse("\(n);hist;") == nil)
        #expect(parse("\(n);hist;x") == nil)
        #expect(parse("\(n);hist;1;more") == nil)
        #expect(parse("hist;1") == nil)
        #expect(parse("wrong;hist;1") == nil)
    }

    /// The hook's literals are ShellHistory's (scripts/zsh-integration-test.py reads the hook from its source too).
    @Test func theHookSaysWhatTheConstantsSay() {
        let script = ZshHistoryScript.script
        let key = ShellHistory.prefix.replacingOccurrences(of: "\u{1b}", with: #"\e"#)
        #expect(script.contains("__nextterm_hkey=$'\(key)'"))
        #expect(script.contains(#"printf '\033]6973;%s;hist;\#(ShellHistory.version)\007'"#))
        #expect(script.contains("len <= \(ShellHistory.maxPayloadBytes)"))
        #expect(script.contains("read -t \(CompletionProtocol.frameWait) -k 1 kind"))
        #expect(script.contains("[[ $kind == h ]]") && ShellHistory.nameKind == UInt8(ascii: "h"))
        // Tab completion's key is the other hook's: each keeps its own.
        #expect(ShellHistory.prefix != CompletionProtocol.prefix)
        // zshaddhistory keeps out only the line named, and through a history list of its own.
        #expect(script.contains("add-zsh-hook zshaddhistory __nextterm_haddhistory"))
        #expect(script.contains(#"[[ -n $named && ${1%$'\n'} == "$line" ]] || return 0"#) && script.contains("  fc -p\n  return 1\n"))
        // It never changes the user's history options or files, and never evaluates text.
        for word in ["setopt", "unsetopt", "SAVEHIST", "HISTSIZE", "fc -W", "fc -A", "fc -P", "print -s"] {
            #expect(!script.contains(word), "the hook says \(word)")
        }
        // HISTFILE only for its export, which `fc -p` drops and preexec puts back: never its value.
        let lines = script.split(separator: "\n").filter { !$0.drop(while: { $0 == " " }).hasPrefix("#") }
        let code = lines.joined(separator: "\n")
        let uses = code.components(separatedBy: "HISTFILE").count - 1
        #expect(uses == 2 && code.contains("[[ ${(t)HISTFILE-} == *-export* ]] && __nextterm_hexport=1\n  fc -p\n"))
        #expect(code.contains("[[ -n $__nextterm_hexport ]] && export HISTFILE\n"))
        #expect(script.contains("add-zsh-hook preexec __nextterm_hpreexec"))
        #expect(script.range(of: #"\beval\b"#, options: .regularExpression) == nil, "the hook evaluates text")
    }

    @Test func installWritesTheHookAndTheIntegrationLoadsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let zdotdir = try ShellIntegration.install(in: dir)
        let hook = try String(contentsOf: zdotdir.appendingPathComponent("history.zsh"), encoding: .utf8)
        #expect(hook == ZshHistoryScript.script)
        let env = try String(contentsOf: zdotdir.appendingPathComponent(".zshenv"), encoding: .utf8)
        #expect(env.contains(#"builtin source "$__nextterm_dir/history.zsh""#))
        // A line the hook kept out reaches preexec with no typed text: the integration takes the hook's.
        #expect(env.contains("local line=${1:-${__nextterm_hran-}}") && hook.contains("__nextterm_hran=$line"))
    }
}
