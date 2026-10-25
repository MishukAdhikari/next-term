import Foundation
import Testing
@testable import NextTermCore

/// The herdr commands Next Term runs: only herdr's documented verbs, every value checked and quoted, text never in the
/// script, and older herdr's verbs tried when herdr says it lacks one. The scripts are also run as a host would run them,
/// against a stand-in herdr in a temporary HOME that logs what it is asked (never a real herdr).
@Suite struct HerdrCommandTests {
    static let every: [HerdrCommand] = [
        .list, .tabs, .sessions, .read(pane: "w1:p1", source: .visible, lines: nil), .read(pane: "w1:p1", source: .recent, lines: 80),
        .prompt(pane: "w1:p1"), .text(pane: "w1:p1"), .keys(pane: "w1:p1", ["escape", "down", "enter", "y"]),
        .focus(pane: "w2:p1", tab: "w2:t1"), .focus(pane: "w2:p1", tab: nil), .version, .explain(pane: "w1:p1"), .machines,
    ]

    /// The words of each herdr call in a script (`nt_call LABEL WORDS…`), unquoted as sh reads them.
    static func calls(in script: String) -> [[String]] {
        var found: [[String]] = []
        for line in script.split(separator: "\n") {
            var rest = Substring(line)
            while let start = rest.range(of: "nt_call '") {
                let words = Self.words(rest[start.upperBound...].dropFirst(0))
                found.append(Array(words.dropFirst())) // the label is the first
                rest = rest[start.upperBound...]
            }
        }
        return found
    }

    /// Single-quoted words and "$T", sh's way ('it'\''s' is one word), up to an unquoted `;` or the line's end. The text
    /// starts inside the label's opening quote.
    static func words(_ text: Substring) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = true // the label's quote is open
        var quoted = true
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if quoted {
                if c == "'" { quoted = false } else { word.append(c) }
            } else if c == "'" {
                quoted = true
                inWord = true
            } else if c == "\\", text.index(after: index) < text.endIndex {
                index = text.index(after: index)
                word.append(text[index])
            } else if c == "\"", text[index...].hasPrefix("\"$T\"") {
                word += "$T"
                inWord = true
                index = text.index(index, offsetBy: 3)
            } else if c == " " || c == ";" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
                if c == ";" { return words }
            } else {
                word.append(c)
                inWord = true
            }
            index = text.index(after: index)
        }
        if inWord { words.append(word) }
        return words
    }

    @Test func everyScriptAsksHerdrOnlyTheAllowedVerbs() throws {
        for command in Self.every {
            // herdr's machines are no session's.
            let sessions: [String?] = command == .machines ? [nil] : [nil, "review"]
            for session in sessions {
                let script = try #require(command.script(session: session), "\(command)")
                let calls = Self.calls(in: script)
                #expect(!calls.isEmpty, "\(command)")
                for call in calls {
                    let verb = Array(call.prefix(call.first == "--version" ? 1 : 2))
                    #expect(HerdrCommand.allowed.contains(verb), "\(command): \(call)")
                }
                // herdr itself runs only through nt_h, with the session or without.
                let runs = script.components(separatedBy: "\n").filter { $0.contains("\"$H\" \"$@\"") || $0.contains("\"$H\" --") }
                let call = "  if [ -n \"$S\" ]; then ( unset HERDR_SOCKET_PATH HERDR_SESSION; nt_hd \"$nt_limit\" \"$H\" --session \"$S\" \"$@\" ); "
                    + "else nt_hd \"$nt_limit\" \"$H\" \"$@\"; fi"
                #expect(runs == [call], "\(runs)")
            }
            // On this Mac: the same verbs, after the executable and the session.
            for attempt in try #require(command.argv(executable: "/x/herdr", session: sessions.last!, text: "hi")) {
                for call in attempt {
                    let global = command == .machines ? ["/x/herdr"] : ["/x/herdr", "--session", "review"]
                    #expect(Array(call.prefix(global.count)) == global)
                    let verb = Array(call.dropFirst(global.count).prefix(2))
                    #expect(HerdrCommand.allowed.contains(verb), "\(call)")
                    #expect(HerdrCommand.verb(of: call) == verb.joined(separator: " "))
                }
            }
        }
        // Nothing that makes, ends or changes herdr's own things is in the list, and of herdr's machines only the list.
        let flat = HerdrCommand.allowed.map { $0.joined(separator: " ") }
        for never in ["server", "session stop", "session delete", "session attach", "agent start", "agent rename", "pane run",
                      "pane close", "tab create", "tab close", "workspace create", "update", "integration", "plugin", "worktree",
                      "machine add", "machine remove", "machine rename", "machine enable", "machine disable", "machine status",
                      "machine reconnect"] {
            #expect(!flat.contains { $0.hasPrefix(never) }, "\(never)")
        }
        #expect(flat.contains("agent explain") && flat.contains("machine list"))
        #expect(HerdrCommand.allowedOnMachine.allSatisfy { $0.first == "agent" && HerdrCommand.allowed.contains($0) })
    }

    @Test func oneOfHerdrsMachinesTakesItsAgentVerbsOnlyAndNeverASession() throws {
        let list = try #require(HerdrCommand.list.argv(executable: "/x/herdr", session: nil, machine: "m1", text: nil))
        // No pane list after it: herdr forwards only its agent commands.
        #expect(list == [[["/x/herdr", "--machine", "m1", "agent", "list"]]])
        let keys = try #require(HerdrCommand.keys(pane: "w1:p1", ["down", "enter"]).argv(executable: "h", session: nil, machine: "m1", text: nil))
        #expect(keys == [[["h", "--machine", "m1", "agent", "send-keys", "w1:p1", "down", "enter"]]])
        let prompt = try #require(HerdrCommand.prompt(pane: "w1:p1").argv(executable: "h", session: nil, machine: "m1", text: "go"))
        #expect(prompt == [[["h", "--machine", "m1", "agent", "prompt", "w1:p1", "go"]]])
        let focus = try #require(HerdrCommand.focus(pane: "w1:p1", tab: "w1:t1").argv(executable: "h", session: nil, machine: "m1", text: nil))
        #expect(focus == [[["h", "--machine", "m1", "agent", "focus", "w1:p1"]]])
        let explain = try #require(HerdrCommand.explain(pane: "w1:p1").argv(executable: "h", session: nil, machine: "m1", text: nil))
        #expect(explain == [[["h", "--machine", "m1", "agent", "explain", "w1:p1", "--json"]]])
        for call in [list, keys, prompt, focus, explain].flatMap({ $0.flatMap { $0 } }) {
            #expect(!call.contains("--session"))
            #expect(HerdrCommand.allowedOnMachine.contains(Array(call.dropFirst(3).prefix(2))))
        }
        // Never with a session, never for what is not an agent command, never an id outside herdr's rule.
        #expect(HerdrCommand.list.argv(executable: "h", session: "review", machine: "m1", text: nil) == nil)
        #expect(HerdrCommand.list.refusal(session: "review", machine: "m1") == "herdr takes a machine or a session, not both.")
        for command in [HerdrCommand.sessions, .tabs, .text(pane: "w1:p1"), .version, .machines] {
            #expect(command.argv(executable: "h", session: nil, machine: "m1", text: nil) == nil, "\(command)")
        }
        #expect(HerdrCommand.sessions.refusal(session: nil, machine: "m1") == "herdr sends only its agent commands to a saved machine.")
        #expect(HerdrCommand.list.argv(executable: "h", session: nil, machine: "m;1", text: nil) == nil)
        #expect(HerdrCommand.list.refusal(session: nil, machine: "m;1") == "“m;1” is not one of herdr's machine ids.")
    }

    @Test func herdrsMachinesAreReadOnlyAndAStateIsExplainedAsJSON() throws {
        #expect(try #require(HerdrCommand.machines.argv(executable: "h", session: nil, text: nil)) == [[["h", "machine", "list", "--json"]]])
        #expect(HerdrCommand.machines.refusal(session: "review") != nil && !HerdrCommand.machines.readsText)
        let explain = try #require(HerdrCommand.explain(pane: "w1:p1").script(session: nil))
        #expect(explain.contains("nt_call 'agent explain' 'agent' 'explain' 'w1:p1' '--json'") && !explain.contains("nt_missing; then"))
        #expect(HerdrCommand.explain(pane: "w1;p1").refusal(session: nil) != nil && !HerdrCommand.explain(pane: "w1:p1").readsText)
        #expect(HerdrCommand.explain(pane: "w1:p1").verb == "agent explain")
        let writes: [HerdrCommand] = [.prompt(pane: "p"), .text(pane: "p"), .keys(pane: "p", ["y"]), .focus(pane: "p", tab: nil)]
        let reads: [HerdrCommand] = [.list, .read(pane: "p", source: .visible, lines: nil), .explain(pane: "p"), .machines]
        #expect(writes.map(\.changesHerdr) == [true, true, true, true] && reads.map(\.changesHerdr) == [false, false, false, false])
    }

    @Test func idsAndSessionsAreCheckedAndQuotedNeverRewritten() throws {
        let read = try #require(HerdrCommand.read(pane: "w1:p1", source: .visible, lines: nil).script(session: nil))
        #expect(read.contains("'agent' 'read' 'w1:p1' '--source' 'visible'"))
        for pane in ["w1;p1", "", String(repeating: "p", count: 81), "-w1", "w1 p1", "w1/p1", "w1:p1\n"] {
            #expect(HerdrCommand.read(pane: pane, source: .visible, lines: nil).script(session: nil) == nil, "\(pane.debugDescription)")
            #expect(HerdrCommand.prompt(pane: pane).refusal(session: nil) != nil)
        }
        #expect(HerdrCommand.read(pane: String(repeating: "p", count: 80), source: .visible, lines: nil).refusal(session: nil) == nil)
        #expect(HerdrCommand.list.script(session: "a b") == nil)
        #expect(HerdrCommand.list.refusal(session: "a b") == "“a b” is not a herdr session name (letters, digits, _ and -, 64 at most).")
        #expect(HerdrCommand.list.argv(executable: "/x/herdr", session: "x;y", text: nil) == nil)
        #expect(HerdrCommand.focus(pane: "w1:p1", tab: "w1 t1").refusal(session: nil) == "“w1 t1” is not a herdr tab id.")
        let named = try #require(HerdrCommand.list.script(session: "review"))
        #expect(named.contains("S='review'"))
        #expect(try #require(HerdrCommand.list.script(session: nil)).contains("\nS=\n"))
    }

    @Test func aPromptsTextComesOnStdinAndItsOlderFormPressesEnterAfterIt() throws {
        let script = try #require(HerdrCommand.prompt(pane: "w1:p1").script(session: nil))
        #expect(script.contains("T=$(cat)"))
        #expect(script.contains("nt_call 'agent prompt' 'agent' 'prompt' 'w1:p1' \"$T\""))
        #expect(script.contains("if nt_missing; then nt_call 'pane send-text' 'pane' 'send-text' 'w1:p1' \"$T\"; [ \"$nt_x\" -ne 0 ] || nt_call 'pane send-keys' 'pane' 'send-keys' 'w1:p1' 'enter'; fi"))
        // No `--`: herdr reads the text by its place, and would take a `--` for the text.
        #expect(!script.contains("'--'"))
        // Text only: no Return. And nothing else reads stdin.
        let text = try #require(HerdrCommand.text(pane: "w1:p1").script(session: nil))
        #expect(text.contains("T=$(cat)") && !text.contains("'enter'"))
        #expect(try #require(HerdrCommand.list.script(session: nil)).contains("\nT=\n"))
        // On this Mac the text is one element, where the script has "$T".
        let argv = try #require(HerdrCommand.prompt(pane: "w1:p1").argv(executable: "/x/herdr", session: nil, text: "-rf; it's $HOME"))
        #expect(argv[0] == [["/x/herdr", "agent", "prompt", "w1:p1", "-rf; it's $HOME"]])
        #expect(argv[1] == [["/x/herdr", "pane", "send-text", "w1:p1", "-rf; it's $HOME"], ["/x/herdr", "pane", "send-keys", "w1:p1", "enter"]])
        let typed = try #require(HerdrCommand.text(pane: "w1:p1").argv(executable: "/x/herdr", session: nil, text: "--wait"))
        #expect(typed == [[["/x/herdr", "pane", "send-text", "w1:p1", "--wait"]]])
    }

    @Test func textHerdrWouldTakeForItsOwnOptionsIsRefused() {
        // herdr takes these from anywhere on its command line before the verb reads its text.
        for text in ["--handoff", "--session", "--session=work", "--remote", "--remote=me@web-1", "--remote-keybindings",
                     "--remote-keybindings=local"] {
            #expect(HerdrCommand.textRefusal(text, mask: .empty) != nil, "\(text)")
        }
        #expect(HerdrCommand.textRefusal("--session=work", mask: .empty)
            == "herdr takes --session= for one of its own options wherever it stands, so that text would not reach the agent. Nothing was sent.")
        // Flag-shaped text herdr keeps as text.
        for text in ["--wait", "--", "-rf build", "--sessions are fine", "run --remote later", "-h"] {
            #expect(HerdrCommand.textRefusal(text, mask: .empty) == nil, "\(text)")
        }
    }

    @Test func aReadFallsBackTwiceAndAsksAtMost2000Lines() throws {
        let attempts = try #require(HerdrCommand.read(pane: "w1:p1", source: .recentUnwrapped, lines: 5000)
            .argv(executable: "h", session: nil, text: nil))
        #expect(attempts.map { $0[0] } == [
            ["h", "agent", "read", "w1:p1", "--source", "recent-unwrapped", "--lines", "2000"],
            ["h", "pane", "read", "w1:p1", "--source", "recent-unwrapped", "--lines", "2000"],
            ["h", "pane", "read", "w1:p1"],
        ])
        #expect(HerdrCommand.read(pane: "w1:p1", source: .visible, lines: nil).readsText)
        #expect(!HerdrCommand.list.readsText && HerdrCommand.read(pane: "p", source: .visible, lines: 1).verb == "agent read")
    }

    @Test func keysAreHerdrsNamesAndAnUnknownOneBuildsNothing() throws {
        let keys = try #require(HerdrCommand.keys(pane: "w1:p1", ["escape", "ctrl+c", "x", "Return", "shift+tab", "space", " "])
            .argv(executable: "h", session: nil, text: nil))
        #expect(keys[0] == [["h", "agent", "send-keys", "w1:p1", "esc", "ctrl+c", "x", "enter", "shift+tab", "space", "space"]])
        #expect(keys[1][0].prefix(3) == ["h", "pane", "send-keys"])
        #expect(HerdrCommand.keys(pane: "w1:p1", ["escape", "f5"]).script(session: nil) == nil)
        #expect(HerdrCommand.keys(pane: "w1:p1", ["escape", "f5"]).refusal(session: nil) == "herdr takes no key “f5”.")
        #expect(HerdrCommand.keys(pane: "w1:p1", []).refusal(session: nil) != nil)
        #expect(HerdrKeys.map("\u{1b}") == nil && HerdrKeys.map("ab") == nil && HerdrKeys.map("é") == "é" && HerdrKeys.map("'") == "'")
    }

    @Test func focusFallsBackToItsTabOnlyWhenItHasOne() throws {
        let withTab = try #require(HerdrCommand.focus(pane: "w2:p1", tab: "w2:t1").argv(executable: "h", session: nil, text: nil))
        #expect(withTab == [[["h", "agent", "focus", "w2:p1"]], [["h", "tab", "focus", "w2:t1"]]])
        let bare = try #require(HerdrCommand.focus(pane: "w2:p1", tab: nil).script(session: nil))
        #expect(!bare.contains("'tab' 'focus'") && !bare.contains("nt_missing; then"))
    }

    @Test func argvForTheDefaultSessionHasNoSession() throws {
        let plain = try #require(HerdrCommand.tabs.argv(executable: "/opt/herdr", session: nil, text: nil))
        #expect(plain == [[["/opt/herdr", "tab", "list"]]])
        let named = try #require(HerdrCommand.sessions.argv(executable: "/opt/herdr", session: "ops", text: nil))
        #expect(named == [[["/opt/herdr", "--session", "ops", "session", "list", "--json"]]])
    }

    // MARK: run as a host runs them

    final class Host {
        let base: String
        let home: String
        let bin: String
        var log: String { base + "/herdr-calls" }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-herdrcmd-\(UUID().uuidString)").path
            home = base + "/home"
            bin = base + "/bin"
            for folder in [home, bin] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            try script(bin + "/pgrep", "exit 1") // no running herdr server, whatever runs on this Mac
            // The stand-in herdr: logs each call (its socket variable too, and stdin when there is any), and with
            // `herdr-old` beside it has no agent verbs, as herdr before 0.7.5.
            try script(bin + "/herdr", """
                printf '%s|%s\\n' "$*" "${HERDR_SOCKET_PATH:-}" >> \(RemoteShell.quote(log))
                [ "$1" = --session ] && shift 2
                [ "$1 $2 $3" = 'agent read w7:p7' ] && exec sleep 30 # a server that takes the connection and never answers
                if [ -e \(RemoteShell.quote(base + "/herdr-old")) ]; then
                  case "$1" in agent) echo "error: unrecognized subcommand '$2'" >&2; exit 2 ;; esac
                  case "$*" in *--source*) echo "error: unexpected argument '--source' found" >&2; exit 2 ;; esac
                fi
                case "$1 $2" in
                  'agent read'|'pane read') printf 'Allow rm -rf build?\\r\\n> 1. Yes\\n  2. No\\n' ;;
                  'agent prompt')
                    [ "$3" = w9:p9 ] && { echo '{"error":{"code":"agent_blocked","message":"w9:p9 waits on a decision"}}' >&2; exit 1; }
                    [ "$3" = w8:p8 ] && { echo "unknown option: $4" >&2; exit 2; } ;;
                  'agent focus') echo '{"id":"cli:agent:focus","result":{"type":"agent_info"}}' ;;
                  'session list') echo '{"sessions":[{"name":"default","default":true,"running":true}]}' ;;
                esac
                exit 0
                """)
        }

        func script(_ path: String, _ body: String) throws {
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        /// Runs `script` as sshd would (through a shell's -c), with `input` on its stdin.
        func run(_ script: String, input: String = "", environment: [String: String] = [:]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", RemoteShell.command(script)]
            process.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": ""].merging(environment) { $1 }
            let out = Pipe(), stdin = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        func calls() -> [String] {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: log)
            return text.split(separator: "\n").map(String.init)
        }
    }

    @Test func aPromptRunsWithItsTextFromStdinAndOlderHerdrTypesItThenEnter() throws {
        let host = try Host()
        let script = try #require(HerdrCommand.prompt(pane: "w1:p1").script(session: nil))
        #expect(!script.contains("run the tests"))
        let said = HerdrResult.parse(try host.run(script, input: "run the tests; it's -fine"), text: false)
        #expect(said == .json(""))
        #expect(host.calls() == ["agent prompt w1:p1 run the tests; it's -fine|"])
        // Flag-shaped text is the text.
        #expect(HerdrResult.parse(try host.run(script, input: "--wait"), text: false) == .json(""))
        #expect(host.calls() == ["agent prompt w1:p1 --wait|"])
        // herdr refuses a prompt while the agent waits on a decision: its words.
        let blocked = HerdrResult.parse(try host.run(try #require(HerdrCommand.prompt(pane: "w9:p9").script(session: nil)), input: "x"), text: false)
        #expect(blocked == .error(code: "agent_blocked", message: "w9:p9 waits on a decision"))
        _ = host.calls()
        // Older herdr: the text, then Enter.
        try host.script(host.base + "/herdr-old", "")
        #expect(HerdrResult.parse(try host.run(script, input: "go"), text: false) == .json(""))
        #expect(host.calls() == ["agent prompt w1:p1 go|", "pane send-text w1:p1 go|", "pane send-keys w1:p1 enter|"])
    }

    @Test func aUsageErrorOfHerdrsOwnAgentPromptNeverTypesTheTextAndPressesReturn() throws {
        let host = try Host()
        // A herdr that has `agent prompt` and refused how it was asked (exit 2): its words, and nothing typed.
        let script = try #require(HerdrCommand.prompt(pane: "w8:p8").script(session: nil))
        let said = HerdrResult.parse(try host.run(script, input: "run the tests"), text: false)
        #expect(said == .error(code: "", message: "unknown option: run the tests"))
        #expect(host.calls() == ["agent prompt w8:p8 run the tests|"])
    }

    @Test func aHerdrThatNeverAnswersIsGivenUpOnWithinTheLimit() throws {
        let host = try Host()
        // Run once first: macOS checks a new program the first time it runs, which can take longer than the limit.
        _ = try host.run(try #require(HerdrCommand.version.script(session: nil)))
        _ = host.calls()
        let script = try #require(HerdrCommand.read(pane: "w7:p7", source: .visible, lines: nil).script(session: nil, limit: 1))
        #expect(script.contains("nt_limit=1"))
        let start = Date()
        let said = HerdrResult.parse(try host.run(script), text: true)
        #expect(Date().timeIntervalSince(start) < 5)
        // Killed, it says so; and nothing older is tried after it.
        guard case .error(_, let message) = said else {
            Issue.record("\(said)")
            return
        }
        #expect(message.contains("herdr did not answer within 1 s"), "\(message)")
        #expect(host.calls() == ["agent read w7:p7 --source visible|"])
    }

    @Test func aReadFallsBackOnTheHostAndKeepsItsLines() throws {
        let host = try Host()
        let script = try #require(HerdrCommand.read(pane: "w1:p1", source: .visible, lines: nil).script(session: nil))
        #expect(HerdrResult.parse(try host.run(script), text: true) == .text("Allow rm -rf build?\n> 1. Yes\n  2. No\n"))
        #expect(host.calls() == ["agent read w1:p1 --source visible|"])
        try host.script(host.base + "/herdr-old", "")
        #expect(HerdrResult.parse(try host.run(script), text: true) == .text("Allow rm -rf build?\n> 1. Yes\n  2. No\n"))
        #expect(host.calls() == ["agent read w1:p1 --source visible|", "pane read w1:p1 --source visible|", "pane read w1:p1|"])
        // Focus has nothing older without a tab: this herdr lacks it.
        let focus = try #require(HerdrCommand.focus(pane: "w1:p1", tab: nil).script(session: nil))
        #expect(HerdrResult.parse(try host.run(focus), text: false) == .unsupported("agent focus"))
    }

    @Test func aNamedSessionIsAskedWithoutTheDefaultSessionsSocket() throws {
        let host = try Host()
        let socket = ["HERDR_SOCKET_PATH": "/home/me/.config/herdr/herdr.sock"]
        let named = try #require(HerdrCommand.sessions.script(session: "review"))
        guard case .json(let text) = HerdrResult.parse(try host.run(named, environment: socket), text: false) else {
            Issue.record("no answer")
            return
        }
        #expect(HerdrSession.parse(text)?.first?.isDefault == true)
        #expect(host.calls() == ["--session review session list --json|"])
        // The default session keeps the socket herdr's environment names.
        _ = try host.run(try #require(HerdrCommand.focus(pane: "w2:p1", tab: "w2:t1").script(session: nil)), environment: socket)
        #expect(host.calls() == ["agent focus w2:p1|/home/me/.config/herdr/herdr.sock"])
        // The status check's section, for a named session, the same way.
        let poll = RemoteShell.findHerdr + "\n" + RemoteShell.herdrSection(session: "review")
        #expect(RemoteShell.herdrSection(session: nil) == RemoteShell.herdrSection)
        _ = try host.run("C=\(RemoteShell.cacheDir)\n" + poll, environment: socket)
        #expect(host.calls() == ["--session review agent list|"])
    }

    @Test func noHerdrOnTheHostIsSaid() throws {
        let host = try Host()
        try FileManager.default.removeItem(atPath: host.bin + "/herdr")
        guard !RemoteFinderTests.herdrOnThisMac else { return }
        let script = try #require(HerdrCommand.tabs.script(session: nil))
        #expect(HerdrResult.parse(try host.run(script), text: false) == .unreachable("herdr was not found on the host"))
    }
}

@Suite struct HerdrTargetTests {
    @Test func anAgentIdIsATabIdASlashAndAPane() throws {
        let target = try #require(HerdrTarget.parse("5C0D9A1E-0000-4000-8000-0000000000E1/w1:p1"))
        #expect(target.tabID == "5c0d9a1e-0000-4000-8000-0000000000e1" && target.pane == "w1:p1")
        #expect(target.id == "5c0d9a1e-0000-4000-8000-0000000000e1/w1:p1")
        #expect(HerdrTarget.parse("tab") == nil && HerdrTarget.parse("/w1:p1") == nil && HerdrTarget.parse("tab/") == nil)
        let odd = try #require(HerdrTarget.parse("a/b/c"))
        #expect(odd.pane == "b/c" && !HerdrTarget.isPane(odd.pane))
        #expect(HerdrTarget.parse("t/W1:P1")?.pane == "W1:P1" && HerdrTarget.parse("t/W1:P1")?.machine == nil)
    }

    @Test func anAgentOnOneOfHerdrsMachinesCarriesTheMachinesID() throws {
        let target = try #require(HerdrTarget.parse("5C0D9A1E-0000-4000-8000-0000000000E1/@0123456789abcdef0123456789abcdef/w1:p1"))
        #expect(target.tabID == "5c0d9a1e-0000-4000-8000-0000000000e1" && target.pane == "w1:p1")
        #expect(target.machine == "0123456789abcdef0123456789abcdef" && HerdrTarget.isMachine(target.machine ?? ""))
        #expect(target.id == "5c0d9a1e-0000-4000-8000-0000000000e1/@0123456789abcdef0123456789abcdef/w1:p1")
        #expect(HerdrTarget(tabID: "T", machine: "m1", pane: "w1:p1").id == "t/@m1/w1:p1")
        // The same pane on two machines is two agents.
        #expect(HerdrTarget.parse("t/@m1/w1:p1") != HerdrTarget.parse("t/@m2/w1:p1"))
        // A machine id outside herdr's rule is refused; one with nothing in it is no id at all.
        let odd = try #require(HerdrTarget.parse("t/@m;1/w1:p1"))
        #expect(odd.machine == "m;1" && !HerdrTarget.isMachine("m;1"))
        #expect(HerdrTarget.parse("t/@/w1:p1") == nil && !HerdrTarget.isMachine("") && !HerdrTarget.isMachine("w1:p1"))
        #expect(HerdrTarget.parse("t/@m1")?.pane == "@m1" && !HerdrTarget.isPane("@m1"))
    }

    @Test func herdrsRulesForIdsNamesAndSessions() {
        for good in ["w1:p1", "1-1", "w64e95948145ed1-1", "7", "w1:t1", "a.b_c-d"] { #expect(HerdrTarget.isPane(good) && HerdrTarget.isTab(good), "\(good)") }
        for bad in ["", "-p", ":p", "w1 p1", "w1;p1", "w1/p1", "p\u{1b}", String(repeating: "x", count: 81)] {
            #expect(!HerdrTarget.isPane(bad), "\(bad.debugDescription)")
        }
        #expect(HerdrTarget.isAgentName("reviewer") && HerdrTarget.isAgentName("a1_b-c") && HerdrTarget.isAgentName(String(repeating: "a", count: 32)))
        #expect(!HerdrTarget.isAgentName("Reviewer") && !HerdrTarget.isAgentName("1a") && !HerdrTarget.isAgentName(String(repeating: "a", count: 33)))
        #expect(HerdrTarget.isSession("review") && !HerdrTarget.isSession("a b"))
    }
}
