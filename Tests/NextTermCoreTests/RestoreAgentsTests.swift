import Foundation
import Testing
@testable import NextTermCore

/// The restore's agent matrix: each agent's program, id pattern and resume form, the put-back line, the options a
/// resume carries or leaves off, and the gate that lets Claude Code, Codex and Qwen Code resume by themselves.
@Suite struct RestoreAgentsTests {
    typealias Evidence = SessionSnapshot.Evidence
    static let uuid = "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c"
    var uuid: String { Self.uuid }

    /// An id each agent's pattern takes.
    static func sampleID(_ agent: RestoreAgent) -> String {
        switch agent {
        case .claude, .codex, .qwen, .gemini, .copilot: return uuid
        case .opencode: return "ses_6a3f2b9c1d"
        case .amp: return "T-" + uuid
        case .cursor, .junie, .commandCode, .kiro, .goose: return "s-42_a.b"
        case .agy, .aider, .unknown: return ""
        }
    }

    static let automatic: [RestoreAgent] = [.claude, .codex, .qwen]

    // MARK: the matrix

    @Test func everyAgentKnowsItsProgramAndName() throws {
        for agent in RestoreAgent.allCases where agent != .unknown {
            let program = try #require(agent.program)
            #expect(RestoreAgent(program: program) == agent, "\(agent)")
            #expect(!agent.name.isEmpty)
        }
        #expect(RestoreAgent.unknown.program == nil)
        #expect(RestoreAgent(program: "claude-code") == .claude && RestoreAgent(program: "commandcode") == .commandCode)
        #expect(RestoreAgent(program: "kiro") == .kiro && RestoreAgent(program: "vim") == nil)
        for kind in AgentKind.allCases {
            #expect(RestoreAgent(kind: kind).kind == kind)
            #expect(RestoreAgent(kind: kind).name == kind.name)
        }
        #expect(RestoreAgent.amp.kind == nil && RestoreAgent.agy.kind == nil)
        let automatic: [RestoreAgent] = RestoreAgent.allCases.filter(\.resumesAutomatically)
        #expect(automatic == Self.automatic)
        let formless: [RestoreAgent] = RestoreAgent.allCases.filter { !$0.hasResumeForm }
        #expect(formless == [.agy, .aider, .unknown])
    }

    @Test func agyIsAnAgentEverywhere() {
        #expect(CommandClassifier.kind(of: "agy") == .agent)
        #expect(CommandClassifier.programName("cd ~/app && agy") == "agy")
        #expect(CommandClassifier.kind(of: ForegroundProcess(isShell: false, name: "agy", arguments: ["agy"])) == .agent)
    }

    @Test func envUnsetIsReadAsAnOption() {
        #expect(CommandClassifier.parse("env -u CLAUDE_CODE_RESUME_PROMPT claude --resume x").name == "claude")
        #expect(CommandClassifier.parse("/usr/bin/env -u A -u B /opt/bin/codex resume x").name == "codex")
        #expect(CommandClassifier.parse("env --unset=A claude").name == "claude")
        #expect(CommandClassifier.parse("env -C /tmp make").name == "make")
        #expect(CommandClassifier.programName("env -u A claude --resume x") == "claude")
    }

    // MARK: ids

    @Test func idsWithShellOrInvisibleCharactersFailTheirPattern() {
        let pieces = [";", "\n", " ", "\u{202E}", "\u{200B}", "$(id)", "`id`", "/", "'", "\u{0}", "\u{2028}", "\u{FEFF}"]
        for agent in RestoreAgent.allCases where agent.hasResumeForm {
            let good = Self.sampleID(agent)
            #expect(agent.isSessionID(good), "\(agent)")
            for piece in pieces {
                #expect(!agent.isSessionID(good + piece), "\(agent) \(piece.unicodeScalars.map(\.value))")
                #expect(!agent.isSessionID(piece + good), "\(agent) \(piece.unicodeScalars.map(\.value))")
            }
            #expect(!agent.isSessionID(""))
            #expect(!agent.isSessionID(String(repeating: "a", count: 129)))
        }
        #expect(!RestoreAgent.claude.isSessionID("chat-1"))
        #expect(!RestoreAgent.opencode.isSessionID(uuid) && !RestoreAgent.amp.isSessionID(uuid))
        for agent in [RestoreAgent.agy, .aider, .unknown] { #expect(!agent.isSessionID(uuid)) }
    }

    // MARK: the put-back line

    @Test func aPutBackLineIsTheResumeFormWithTheIDAndNothingElse() {
        let lines: [(RestoreAgent, String)] = [
            (.claude, "claude --resume \(uuid)"),
            (.codex, "codex resume \(uuid) -C /Users/x/app"),
            (.qwen, "qwen --resume \(uuid)"),
            (.copilot, "copilot --resume=\(uuid)"),
            (.gemini, "gemini --resume \(uuid)"),
            (.cursor, "cursor-agent --resume s-42_a.b"),
            (.opencode, "opencode -s ses_6a3f2b9c1d"),
            (.amp, "amp threads continue T-\(uuid)"),
            (.junie, "junie --session-id s-42_a.b --resume"),
            (.commandCode, "command-code --resume s-42_a.b"),
            (.kiro, "kiro-cli chat --resume-id s-42_a.b"),
            (.goose, "goose session --resume --session-id s-42_a.b"),
        ]
        let withForm: [RestoreAgent] = RestoreAgent.allCases.filter(\.hasResumeForm)
        #expect(lines.count == withForm.count)
        for (agent, line) in lines {
            #expect(agent.putBackLine(id: Self.sampleID(agent), folder: "/Users/x/app") == line)
        }
    }

    @Test func noIDOrABadOneLeavesTheProgramAlone() {
        for agent in RestoreAgent.allCases where agent.hasResumeForm {
            #expect(agent.putBackLine(id: nil) == agent.program)
            #expect(agent.putBackLine(id: "x; rm -rf ~") == agent.program)
            #expect(agent.putBackLine(id: Self.sampleID(agent) + "\u{202E}") == agent.program)
        }
        #expect(RestoreAgent.claude.putBackLine(id: "not-a-uuid") == "claude")
        for agent in [RestoreAgent.agy, .aider, .unknown] { #expect(agent.putBackLine(id: uuid) == nil) }
    }

    @Test func codexNamesItsFolderOnlyWhenThePathIsPlain() {
        #expect(RestoreAgent.codex.putBackLine(id: uuid) == "codex resume \(uuid)")
        #expect(RestoreAgent.codex.putBackLine(id: uuid, folder: "/Users/x/My App") == "codex resume \(uuid) -C '/Users/x/My App'")
        #expect(RestoreAgent.codex.putBackLine(id: uuid, folder: "/Users/x/a\u{202E}b") == "codex resume \(uuid)")
        #expect(RestoreAgent.codex.putBackLine(id: uuid, folder: "/Users/x/a\u{1B}b") == "codex resume \(uuid)")
        #expect(RestoreAgent.codex.putBackLine(id: uuid, folder: "relative/path") == "codex resume \(uuid)")
        let long = "/Users/x/" + String(repeating: "a", count: 4090)
        #expect(RestoreAgent.codex.putBackLine(id: uuid, folder: long) == "codex resume \(uuid)")
    }

    @Test func everyResumeFormClassifiesAsItsAgent() throws {
        for agent in RestoreAgent.allCases where agent.hasResumeForm {
            for line in [agent.putBackLine(id: Self.sampleID(agent), folder: "/Users/x/app"), agent.putBackLine(id: nil)] {
                let line = try #require(line)
                #expect(CommandClassifier.kind(of: line) == .agent, "\(line)")
                #expect(RestoreAgent(program: CommandClassifier.programName(line)) == agent, "\(line)")
            }
        }
        for evidence in [claudeBinary, claudeScript, codexBinary] {
            let command = try #require(evidence.resumeCommand)
            #expect(CommandClassifier.kind(of: command) == .agent, "\(command)")
            #expect(RestoreAgent(program: CommandClassifier.programName(command)) == evidence.agent, "\(command)")
        }
    }

    // MARK: the automatic resume command

    var claudeBinary: Evidence {
        Evidence(agent: .claude, sessionID: uuid, source: .sessionFile, sessionFolder: "/Users/x/app",
                 executable: "/Users/x/.local/bin/claude", options: [])
    }

    var claudeScript: Evidence {
        Evidence(agent: .claude, sessionID: uuid, source: .sessionFile, sessionFolder: "/Users/x/app",
                 executable: "/opt/homebrew/bin/node", interpreter: "/opt/homebrew/bin/node",
                 script: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", options: [])
    }

    var codexBinary: Evidence {
        Evidence(agent: .codex, sessionID: uuid, source: .openRollout, sessionFolder: "/Users/x/app", executable: "/opt/homebrew/bin/codex",
                 options: [])
    }

    @Test func theResumeRunsTheRecordedPathWithAutoContinueUnset() {
        let unset = RestoreAgent.claude.autoContinueVariables.map { "-u " + $0 }.joined(separator: " ")
        #expect(RestoreAgent.claude.autoContinueVariables.contains("CLAUDE_CODE_RESUME_INTERRUPTED_TURN"))
        #expect(claudeBinary.resumeCommand == "/usr/bin/env \(unset) /Users/x/.local/bin/claude --resume \(uuid)")
        let script = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        #expect(claudeScript.resumeCommand == "/usr/bin/env \(unset) /opt/homebrew/bin/node \(script) --resume \(uuid)")
        #expect(codexBinary.resumeCommand == "/usr/bin/env /opt/homebrew/bin/codex resume \(uuid) -C /Users/x/app")
        var spaced = claudeBinary
        spaced.executable = "/Users/x/My Tools/claude"
        #expect(spaced.resumeCommand == "/usr/bin/env \(unset) '/Users/x/My Tools/claude' --resume \(uuid)")
        var carried = claudeBinary
        carried.options = [SessionSnapshot.LaunchOption(["--model", "opus"])]
        #expect(carried.resumeCommand?.hasSuffix("--resume \(uuid) --model opus") == true)
        var unknown = claudeBinary
        unknown.options = nil
        #expect(unknown.resumeCommand == nil)
        var noPath = claudeBinary
        noPath.executable = nil
        #expect(noPath.resumeCommand == nil)
    }

    // MARK: the user's launch, put back (KTD7)

    typealias Launcher = SessionSnapshot.Launcher
    typealias LaunchOption = SessionSnapshot.LaunchOption

    /// Evidence of `agent` run with `options` as argv gave them (the ones at `unclear` followed by a word that may be a
    /// prompt's), started by `launcher` when one is given.
    func launch(_ agent: RestoreAgent, _ options: [[String]], launcher: Launcher? = nil, unclear: Set<Int> = []) -> Evidence {
        var evidence = Evidence(agent: agent)
        evidence.options = options.enumerated().map { (index: Int, words: [String]) -> LaunchOption in
            LaunchOption(words, unclear: unclear.contains(index))
        }
        evidence.launcher = launcher
        return evidence
    }

    /// AE29: with no launcher to replay, the line is rebuilt from argv: the program, the subcommand its options belong
    /// to, argv's options in order, then the resume form. With no id, or one outside its pattern, the same launch
    /// without the resume form.
    @Test func aLineIsRebuiltFromArgvsOptionsBeforeTheResumeForm() {
        let cases: [(RestoreAgent, [String], String)] = [
            (.claude, ["--dangerously-skip-permissions"], "claude --dangerously-skip-permissions --resume \(uuid)"),
            (.codex, ["--yolo"], "codex --yolo resume \(uuid) -C /Users/x/app"),
            (.qwen, ["-y"], "qwen -y --resume \(uuid)"),
            (.copilot, ["--allow-all"], "copilot --allow-all --resume=\(uuid)"),
            (.gemini, ["--approval-mode=yolo"], "gemini --approval-mode=yolo --resume \(uuid)"),
            (.cursor, ["-f"], "cursor-agent -f --resume s-42_a.b"),
            (.opencode, ["--auto"], "opencode --auto -s ses_6a3f2b9c1d"),
            (.amp, ["--dangerously-allow-all"], "amp --dangerously-allow-all threads continue T-\(uuid)"),
            (.junie, ["--brave"], "junie --brave --session-id s-42_a.b --resume"),
            (.commandCode, ["--yolo"], "command-code --yolo --resume s-42_a.b"),
            (.kiro, ["--trust-all-tools"], "kiro-cli chat --trust-all-tools --resume-id s-42_a.b"),
            (.goose, ["--debug"], "goose session --debug --resume --session-id s-42_a.b"),
        ]
        let withForm: [RestoreAgent] = RestoreAgent.allCases.filter(\.hasResumeForm)
        #expect(cases.map(\.0) == withForm)
        for (agent, option, line) in cases {
            let evidence = launch(agent, [option])
            let found = evidence.putBack(id: Self.sampleID(agent), folder: "/Users/x/app")
            #expect(found == PutBack(line: line, namesSession: true, leftOff: []), "\(agent)")
            let bare = ([agent.program ?? ""] + agent.cli.subcommand + option).joined(separator: " ")
            #expect(evidence.putBack(id: nil) == PutBack(line: bare, namesSession: false, leftOff: []), "\(agent)")
            #expect(evidence.putBack(id: "x; rm -rf ~")?.line == bare, "\(agent)")
            // Options not known, or none: the resume form alone.
            #expect(launch(agent, []).putBack(id: Self.sampleID(agent), folder: "/Users/x/app")?.line == agent.putBackLine(
                id: Self.sampleID(agent), folder: "/Users/x/app"), "\(agent)")
            #expect(Evidence(agent: agent).putBack(id: nil)?.line == agent.program, "\(agent)")
        }
        for agent in [RestoreAgent.agy, .aider, .unknown] {
            #expect(launch(agent, [["--yes-always"]]).putBack(id: uuid) == nil, "\(agent)")
        }
    }

    /// AE24, AE27: a launcher that passes its arguments on is replayed with the options typed after it, and brings its
    /// own options and any variable it sets back itself. Kiro's and Goose's options belong to a subcommand a launcher may
    /// hold or not, which nothing shows, so theirs is rebuilt from argv.
    @Test func aLauncherIsReplayedWithTheOptionsTypedAfterIt() {
        for agent in RestoreAgent.allCases where agent.hasResumeForm {
            let id = Self.sampleID(agent)
            let replayed = launch(agent, [["--verbose"]], launcher: Launcher(word: "my-agent", typed: 0))
            let form: [String] = agent.cli.resumeWords(id: id, folder: "/Users/x/app") ?? []
            let line: [String]
            if agent.cli.subcommand.isEmpty {
                line = ["my-agent"] + form
                #expect(replayed.putBack(id: nil)?.line == "my-agent", "\(agent)")
            } else {
                line = [agent.program ?? ""] + agent.cli.subcommand + ["--verbose"] + form
            }
            let found = replayed.putBack(id: id, folder: "/Users/x/app")
            #expect(found == PutBack(line: line.joined(separator: " "), namesSession: true, leftOff: []), "\(agent)")
        }
        let cad = launch(.claude, [["--dangerously-skip-permissions"], ["--model", "opus[1m]"]], launcher: Launcher(word: "cad", typed: 1))
        #expect(cad.putBack(id: uuid)?.line == "cad --model 'opus[1m]' --resume \(uuid)")
        #expect(cad.putBack(id: nil)?.line == "cad --model 'opus[1m]'")
        let path = launch(.codex, [["--yolo"]], launcher: Launcher(word: "/Users/x/bin/cx", typed: 0))
        #expect(path.putBack(id: uuid, folder: "/Users/x/app")?.line == "/Users/x/bin/cx resume \(uuid) -C /Users/x/app")
        // The agent's own program typed with its options is a launcher too, and replays as the rebuild would.
        let typed = launch(.copilot, [["--allow-all"]], launcher: Launcher(word: "copilot", typed: 1))
        #expect(typed.putBack(id: uuid) == PutBack(line: "copilot --allow-all --resume=\(uuid)", namesSession: true, leftOff: []))
    }

    /// KTD7, AE30: an option the table does not know is kept with its value when that is plain (joined by `=`, or none
    /// before another option or the end). One followed by a word that may be a prompt's is left off with that word, and
    /// its note names it.
    @Test func anUnknownOptionIsKeptOnlyWhenItsValueIsPlain() {
        let unclear = launch(.claude, [["--newflag"], ["--model", "opus"]], unclear: [0])
        let left = PutBack(line: "claude --model opus --resume \(uuid)", namesSession: true, leftOff: ["--newflag"])
        #expect(unclear.putBack(id: uuid) == left)
        #expect(unclear.putBack(id: nil) == PutBack(line: "claude --model opus", namesSession: false, leftOff: ["--newflag"]))
        let joined = launch(.claude, [["--newflag=value"]])
        #expect(joined.putBack(id: uuid) == PutBack(line: "claude --newflag=value --resume \(uuid)", namesSession: true, leftOff: []))
        let alone = launch(.claude, [["--newflag"], ["--verbose"], ["--other"]])
        #expect(alone.putBack(id: uuid)?.line == "claude --newflag --verbose --other --resume \(uuid)")
        // A launcher brings its own back: only an unclear option typed after it is left off, and each is named once.
        let typedAfter = launch(.claude, [["--newflag"], ["--other"], ["--other"]], launcher: Launcher(word: "cad", typed: 2),
                                unclear: [0, 1, 2])
        #expect(typedAfter.putBack(id: uuid) == PutBack(line: "cad --resume \(uuid)", namesSession: true, leftOff: ["--other"]))
        // The table of the build that restores reads the record again: an option it knows to take no value is plain.
        let known = launch(.claude, [["--verbose"]], unclear: [0])
        #expect(known.putBack(id: uuid) == PutBack(line: "claude --verbose --resume \(uuid)", namesSession: true, leftOff: []))
        let valued = launch(.claude, [["--model"]], unclear: [0])
        #expect(valued.putBack(id: uuid) == PutBack(line: "claude --resume \(uuid)", namesSession: true, leftOff: ["--model"]))
    }

    /// R8, KTD20: the build that restores reads a record with its own table. A word capture's table read as an option's
    /// value, which this table reads as no value of it, is a prompt word now: it never reaches the line, and nothing runs
    /// by itself. An option this table no longer knows, kept with a word after it, is left off with that word, and named.
    @Test func wordsAnOptionNoLongerTakesNeverReachALine() {
        let fewer = launch(.claude, [["--model", "opus", "Xyzzy fix the tests"]])
        #expect(fewer.putBack(id: uuid) == PutBack(line: "claude --model opus --resume \(uuid)", namesSession: true, leftOff: []))
        #expect(!fewer.launch.allowed)
        let none = launch(.claude, [["--verbose", "Xyzzy fix the tests"], ["--dangerously-skip-permissions"]])
        #expect(none.putBack(id: uuid)?.line == "claude --verbose --dangerously-skip-permissions --resume \(uuid)")
        let gone = launch(.claude, [["--zq1", "Xyzzy fix the tests"], ["--model", "opus"]])
        #expect(gone.putBack(id: uuid) == PutBack(line: "claude --model opus --resume \(uuid)", namesSession: true, leftOff: ["--zq1"]))
        #expect(!gone.launch.allowed)
        // A launcher brings its own back: only what was typed after it is read.
        let replayed = launch(.claude, [["--dangerously-skip-permissions"], ["--model", "opus", "Xyzzy fix"]],
                              launcher: Launcher(word: "cad", typed: 1))
        #expect(replayed.putBack(id: uuid)?.line == "cad --model opus --resume \(uuid)")
    }

    /// R8: a form, a one-shot option or an old resume form never reaches a line, whatever the record holds, as the table
    /// of the build that restores reads it again.
    @Test func formsAndOneShotOptionsNeverReachALine() {
        let claude = launch(.claude, [["--resume", uuid], ["--continue"], ["-p"], ["--fork-session"], ["--model", "opus"]])
        #expect(claude.putBack(id: uuid)?.line == "claude --model opus --resume \(uuid)")
        let codex = launch(.codex, [["--last"], ["-C", "/Users/x/old"], ["--yolo"]])
        #expect(codex.putBack(id: uuid, folder: "/Users/x/app")?.line == "codex --yolo resume \(uuid) -C /Users/x/app")
        let qwen = launch(.qwen, [["-p", "fix it"], ["-y"]])
        #expect(qwen.putBack(id: uuid)?.line == "qwen -y --resume \(uuid)")
    }

    /// Capture keeps argv's options without its prompt words, and a line rebuilt from them holds none.
    @Test func promptWordsNeverReachALine() throws {
        let launches: [(RestoreAgent, [String], String)] = [
            (.claude, ["fix the login bug", "--model", "opus", "--resume", uuid, "--verbose"], "claude --model opus --verbose --resume \(uuid)"),
            (.codex, ["resume", uuid, "-C", "/Users/x/app", "-m", "gpt-5"], "codex -m gpt-5 resume \(uuid) -C /Users/x/app"),
            (.qwen, ["--model=qwen3-coder", "-r", uuid, "explain this"], "qwen --model=qwen3-coder --resume \(uuid)"),
            (.gemini, ["--yolo", "-m", "gemini-3", "--resume", uuid, "fix it"], "gemini --yolo -m gemini-3 --resume \(uuid)"),
            (.claude, ["--", "--dangerously-skip-permissions"], "claude --resume \(uuid)"),
        ]
        for (agent, arguments, line) in launches {
            var evidence = Evidence(agent: agent)
            evidence.options = try #require(agent.launchOptions(in: arguments))
            #expect(evidence.putBack(id: uuid, folder: "/Users/x/app")?.line == line, "\(arguments)")
        }
    }

    // MARK: what an automatic resume carries (KTD5)

    /// `name`'s words with values its pattern takes.
    static func words(_ name: String, _ option: AgentCLI.Option) -> [String] {
        switch option.values {
        case .none: return [name]
        case .one: return [name, "value"]
        case .many: return [name, "Edit", "Bash(git *)"]
        }
    }

    /// AE15, AE23, AE25, AE26: a permission option is carried only when argv and the typed or alias-expanded line both
    /// show it, after the plain options. Argv alone or the typed line alone gives "on the line".
    @Test func aPermissionOptionIsCarriedOnlyWhenArgvAndTheTypedLineBothShowIt() throws {
        for agent in Self.automatic {
            for name in agent.cli.names(.permission) {
                let option = try #require(agent.cli.options[name])
                var forms = [Self.words(name, option)]
                if option.values == .one { forms.append([name + "=value"]) }
                for words in forms {
                    let (base, facts) = passing(agent)
                    var evidence = base
                    evidence.options = [LaunchOption(words)]
                    evidence.confirmed = [LaunchOption(words)]
                    guard case .resume(let command) = evidence.gate(facts) else {
                        Issue.record("\(agent) did not resume with \(words)")
                        continue
                    }
                    let carried = words.map(ShellQuote.quote).joined(separator: " ")
                    #expect(command.hasSuffix(" " + carried), "\(command)")
                    #expect(evidence.launch.permissions == [words], "\(agent) \(words)")
                    evidence.confirmed = []
                    #expect(evidence.gate(facts) == .onTheLine([.flags]), "argv alone: \(agent) \(words)")
                    evidence.options = []
                    evidence.confirmed = [LaunchOption(words)]
                    #expect(evidence.gate(facts) == .onTheLine([.flags]), "the typed line alone: \(agent) \(words)")
                    // Both, with a guessed id: on the line.
                    evidence.options = [LaunchOption(words)]
                    evidence.source = .guess
                    #expect(evidence.gate(facts) == .onTheLine([.sessionFile]), "a guess: \(agent) \(words)")
                }
            }
            // A value its pattern does not take, on both lines, is not carried.
            if let mode = agent.cli.names(.permission).first(where: { agent.cli.options[$0]?.values == .one }) {
                let (base, facts) = passing(agent)
                var evidence = base
                evidence.options = [LaunchOption([mode, "plan;id"])]
                evidence.confirmed = evidence.options ?? []
                #expect(evidence.gate(facts) == .onTheLine([.flags]), "\(agent) \(mode)")
            }
        }
        // Plain options first, then permission options, each in argv's order.
        let (base, facts) = passing(.claude)
        var claude = base
        claude.options = [LaunchOption(["--permission-mode", "bypassPermissions"]), LaunchOption(["--model", "opus[1m]"]),
                          LaunchOption(["--dangerously-skip-permissions"])]
        claude.confirmed = [LaunchOption(["--dangerously-skip-permissions"]), LaunchOption(["--permission-mode", "bypassPermissions"])]
        let suffix = "--resume \(uuid) --model 'opus[1m]' --permission-mode bypassPermissions --dangerously-skip-permissions"
        #expect(claude.resumeCommand?.hasSuffix(suffix) == true, "\(claude.resumeCommand ?? "none")")
        #expect(claude.gate(facts) == .resume(claude.resumeCommand ?? "none"))
        // The same option twice needs the typed line to show it twice.
        claude.options = [LaunchOption(["--dangerously-skip-permissions"]), LaunchOption(["--dangerously-skip-permissions"])]
        claude.confirmed = [LaunchOption(["--dangerously-skip-permissions"])]
        #expect(claude.gate(facts) == .onTheLine([.flags]))
    }

    /// AE28, AE30: a code-loading option, an option the table does not know, or one whose value may be a prompt's, gives
    /// "on the line", whatever the typed line shows; so do options not known. The line carries them back.
    @Test func codeLoadingAndUnknownOptionsGoOnTheLine() throws {
        for agent in Self.automatic {
            let (base, facts) = passing(agent)
            for name in agent.cli.names(.codeLoading) {
                let words = Self.words(name, try #require(agent.cli.options[name]))
                var evidence = base
                evidence.options = [LaunchOption(words)]
                evidence.confirmed = [LaunchOption(words)]
                #expect(evidence.gate(facts) == .onTheLine([.flags]), "\(agent) \(words)")
                #expect(evidence.putBack(id: Self.sampleID(agent))?.line.contains(words.map(ShellQuote.quote).joined(separator: " ")) == true)
            }
            for (options, unclear) in [([["--newflag=value"]], Set<Int>()), ([["--newflag"]], [0]), ([["--newflag"]], [])] {
                var evidence = launch(agent, options, unclear: unclear)
                evidence.sessionID = base.sessionID
                evidence.source = base.source
                evidence.sessionFolder = base.sessionFolder
                evidence.store = base.store
                evidence.executable = base.executable
                evidence.startedAt = base.startedAt
                evidence.routingMatchesShell = true
                evidence.autoContinueOff = true
                evidence.ranAsTyped = true
                #expect(evidence.gate(facts) == .onTheLine([.flags]), "\(agent) \(options)")
            }
            var unknown = base
            unknown.options = nil
            #expect(unknown.gate(facts) == .onTheLine([.flags]), "\(agent)")
        }
        // Forms are dropped, not carried: no resume holds `--continue` or `--last`.
        let (codexBase, facts) = passing(.codex)
        var codex = codexBase
        codex.options = [LaunchOption(["--last"]), LaunchOption(["-m", "gpt-5"])]
        #expect(codex.gate(facts) == .resume("/usr/bin/env /Users/x/.local/bin/codex resume \(uuid) -C /Users/x/app -m gpt-5"))
        var claude = passing(.claude).0
        claude.options = [LaunchOption(["--continue"])]
        #expect(claude.resumeCommand?.contains("--continue") == false)
    }

    @Test func aModelIsCarriedOnlyWithinItsPattern() {
        let models = ["claude": "--model", "codex": "-m", "qwen": "--model"]
        for agent in Self.automatic {
            let flag = models[agent.rawValue]!
            let (base, facts) = passing(agent)
            var evidence = base
            evidence.options = [LaunchOption([flag, "x"])]
            guard case .resume(let command) = evidence.gate(facts) else {
                Issue.record("\(agent) did not resume with \(flag) x")
                continue
            }
            #expect(command.hasSuffix(" \(flag) x"))
            // A context size in brackets is part of a model's name, quoted on the line.
            evidence.options = [LaunchOption([flag, "opus[1m]"])]
            guard case .resume(let sized) = evidence.gate(facts) else {
                Issue.record("\(agent) did not resume with \(flag) opus[1m]")
                continue
            }
            #expect(sized.hasSuffix(" \(flag) 'opus[1m]'"))
            for value in ["opus;rm", "a b", String(repeating: "a", count: 65), "op$(id)", "[1m]"] {
                evidence.options = [LaunchOption([flag, value])]
                #expect(evidence.gate(facts) == .onTheLine([.flags]), "\(agent) \(value)")
                #expect(evidence.putBack(id: Self.sampleID(agent))?.line.contains(ShellQuote.quote(value)) == true, "\(agent) \(value)")
            }
            evidence.options = [LaunchOption([flag])]
            #expect(evidence.gate(facts) == .onTheLine([.flags]))
        }
    }

    /// Other agents never resume by themselves, and their line carries their options all the same.
    @Test func otherAgentsKeepTheirOptionsOnTheLine() {
        let (base, facts) = passing(.gemini)
        var gemini = base
        gemini.options = [LaunchOption(["--yolo"]), LaunchOption(["-m", "gemini-3"])]
        gemini.confirmed = [LaunchOption(["--yolo"])]
        guard case .onTheLine(let failed) = gemini.gate(facts) else {
            Issue.record("Gemini CLI resumed")
            return
        }
        #expect(failed.contains(.automatic))
        #expect(gemini.putBack(id: uuid)?.line == "gemini --yolo -m gemini-3 --resume \(uuid)")
    }

    // MARK: the gate

    /// Evidence and facts on which every check passes: an exact id from the agent's own file, a binary in the user's
    /// own folder outside the project, a private local session folder.
    func passing(_ agent: RestoreAgent) -> (Evidence, ResumeFacts) {
        let user = geteuid()
        let source: SessionSnapshot.IDSource = agent == .claude ? .sessionFile : agent == .codex ? .openRollout : .runtimeFile
        let program = agent.program ?? "agent"
        let store = agent.resumesAutomatically ? "/Users/x/.\(program)" : nil
        var evidence = Evidence(agent: agent, sessionID: Self.sampleID(agent), source: source, sessionFolder: "/Users/x/app", store: store,
                                executable: "/Users/x/.local/bin/\(program)", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                routingMatchesShell: true, autoContinueOff: true, ranAsTyped: true)
        evidence.options = []
        let link = "/Users/x/.local/bin/\(program)"
        let binary = FileFacts(realPath: "/Users/x/.local/share/\(program)/2.1.280", owner: user, mode: 0o755, isRegular: true,
                               linksFollowed: [link])
        let folder = FileFacts(realPath: "/Users/x/app", owner: user, mode: 0o755, isDirectory: true)
        var files = [link: binary, "/Users/x/app": folder]
        if let store { files[store] = FileFacts(realPath: store, owner: user, mode: 0o700, isDirectory: true) }
        let facts = ResumeFacts(user: user, files: files, outside: ["/Users/x/app"], temporaryFolders: ["/private/tmp", "/private/var/folders/zz/abc"],
                                sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
        return (evidence, facts)
    }

    @Test func aPassingGateResumes() {
        for agent in Self.automatic {
            let (evidence, facts) = passing(agent)
            #expect(evidence.gate(facts) == .resume(evidence.resumeCommand ?? "none"), "\(agent)")
        }
        let (claude, facts) = passing(.claude)
        let unset: String = RestoreAgent.claude.autoContinueVariables.map { "-u " + $0 }.joined(separator: " ")
        let command = "/usr/bin/env \(unset) /Users/x/.local/bin/claude --resume \(uuid)"
        #expect(claude.gate(facts) == .resume(command))
    }

    @Test func theRestGetTheirLineOrANote() {
        for agent in RestoreAgent.allCases where !agent.resumesAutomatically {
            let (base, facts) = passing(agent)
            var evidence = base
            evidence.source = .typedAndArgv
            if agent.hasResumeForm {
                guard case .onTheLine(let failed) = evidence.gate(facts) else {
                    Issue.record("\(agent) resumed")
                    continue
                }
                #expect(failed.contains(.automatic), "\(agent)")
            } else {
                #expect(evidence.gate(facts) == .note, "\(agent)")
            }
        }
    }

    @Test func anIDExactOnlyThroughTheTypedLineGoesOnTheLine() {
        for agent in Self.automatic {
            for source in [SessionSnapshot.IDSource.typedAndArgv, .childEnvironment, .guess, .unknown] {
                let (base, facts) = passing(agent)
                var evidence = base
                evidence.source = source
                #expect(evidence.gate(facts) == .onTheLine([.sessionFile]), "\(agent) \(source)")
            }
        }
        // Another agent's file is not this one's.
        let (base, facts) = passing(.claude)
        var claude = base
        claude.source = .openRollout
        #expect(claude.gate(facts) == .onTheLine([.sessionFile]))
    }

    /// One change each, and the one check it fails.
    @Test func eachFailedCheckPutsTheLineBack() {
        typealias Change = (inout Evidence, inout ResumeFacts) -> Void
        let user = geteuid()
        let cases: [(String, ResumeCheck, Change)] = [
            ("a bad id", .idPattern, { e, _ in e.sessionID = "abc; id" }),
            ("no id", .idPattern, { e, _ in e.sessionID = nil }),
            ("options not known", .flags, { e, _ in e.options = nil }),
            ("a settings file", .flags, { e, _ in e.options = [SessionSnapshot.LaunchOption(["--settings", "x.json"])] }),
            ("a permission option argv alone shows", .flags, { e, _ in
                e.options = [SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
            }),
            ("a function, a wrapper or an env prefix", .typedLine, { e, _ in e.ranAsTyped = false }),
            ("another provider", .routing, { e, _ in e.routingMatchesShell = false }),
            ("auto-continue in the environment", .autoContinue, { e, _ in e.autoContinueOff = false }),
            ("auto-continue in settings", .autoContinue, { _, f in f.settingsAutoContinue = true }),
            ("the session is gone or open", .session, { _, f in f.sessionAvailable = false }),
            ("no folder", .folder, { _, f in f.files["/Users/x/app"] = nil }),
            ("a folder others can write", .folder, { _, f in f.files["/Users/x/app"]?.mode = 0o777 }),
            ("a folder of another user's", .folder, { _, f in f.files["/Users/x/app"]?.owner = user + 1 }),
            ("a folder on a network volume", .folder, { _, f in f.files["/Users/x/app"]?.isLocal = false }),
            ("a file where the folder was", .folder, { _, f in f.files["/Users/x/app"]?.isDirectory = false }),
            ("the executable is gone", .executable, { _, f in f.files["/Users/x/.local/bin/claude"] = nil }),
            ("project config changed", .projectConfig, { _, f in f.projectConfigChanged = true }),
            ("no start time", .projectConfig, { e, _ in e.startedAt = nil }),
            ("no store recorded", .store, { e, _ in e.store = nil }),
            ("the store is gone", .store, { _, f in f.files["/Users/x/.claude"] = nil }),
            ("a store in the workspace", .store, { _, f in f.files["/Users/x/.claude"]?.realPath = "/Users/x/app/.claude-store" }),
            ("a store in a temporary folder", .store, { _, f in f.files["/Users/x/.claude"]?.realPath = "/private/tmp/claude" }),
            ("a store others can write", .store, { _, f in f.files["/Users/x/.claude"]?.mode = 0o777 }),
            ("a store of another user's", .store, { _, f in f.files["/Users/x/.claude"]?.owner = user + 1 }),
            ("a file where the store was", .store, { _, f in f.files["/Users/x/.claude"]?.isDirectory = false }),
        ]
        for (name, check, change) in cases {
            var (evidence, facts) = passing(.claude)
            change(&evidence, &facts)
            #expect(evidence.gate(facts) == .onTheLine([check]), "\(name)")
        }
    }

    // MARK: where the agent's code lies

    /// The Claude evidence with its executable's real path, owner and mode as given.
    func gate(realPath: String, owner: uid_t? = nil, mode: UInt16 = 0o755) -> ResumeVerdict {
        let (evidence, base) = passing(.claude)
        var facts = base
        facts.files[evidence.executable ?? ""] = FileFacts(realPath: realPath, owner: owner ?? geteuid(), mode: mode, isRegular: true)
        return evidence.gate(facts)
    }

    @Test func codeInTheWorkspaceOrTempGoesOnTheLine() {
        #expect(gate(realPath: "/Users/x/app/node_modules/@anthropic-ai/claude-code/cli.js") == .onTheLine([.location]))
        #expect(gate(realPath: "/Users/x/app") == .onTheLine([.location]))
        #expect(gate(realPath: "/private/var/folders/zz/abc/T/claude") == .onTheLine([.location]))
        #expect(gate(realPath: "/private/tmp/claude") == .onTheLine([.location]))
        // A sibling whose name only starts like the project is not inside it.
        if case .onTheLine = gate(realPath: "/Users/x/app2/claude") { Issue.record("a sibling folder counted as the project") }
    }

    /// The resume runs the recorded path, so every link it passes must lie where nothing in a tab can change it: a
    /// link in the workspace (a PATH folder direnv adds) or a temporary folder could be pointed elsewhere between the
    /// check and the run, whatever it leads to now.
    @Test func aLinkInTheWorkspaceOrTempGoesOnTheLineThoughItLeadsOut() {
        for links in [["/Users/x/app/bin/claude"], ["/Users/x/.local/bin/claude", "/Users/x/app/tools/claude"],
                      ["/Users/x/.local/bin/claude", "/private/tmp/claude"]] {
            var (evidence, facts) = passing(.claude)
            evidence.executable = links[0]
            facts.files[links[0]] = FileFacts(realPath: "/Users/x/.local/share/claude/2.1.280", owner: geteuid(), mode: 0o755, isRegular: true,
                                              linksFollowed: links)
            #expect(evidence.gate(facts) == .onTheLine([.location]), "\(links)")
        }
        // Links outside them pass, and the resume runs the path that was recorded.
        let (evidence, facts) = passing(.claude)
        guard case .resume(let command) = evidence.gate(facts) else {
            Issue.record("a link in ~/.local/bin did not pass")
            return
        }
        #expect(command.contains(" /Users/x/.local/bin/claude --resume "))
    }

    /// FileFacts names every link it follows, by the link's own path: one in a folder on the way counts too.
    @Test func fileFactsNameTheLinksFollowed() throws {
        let root = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-links-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/share/claude/versions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/app", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/share/claude/versions/2.1.280", contents: Data(), attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: root + "/app/claude", withDestinationPath: "../share/claude/versions/2.1.280")
        try fm.createSymbolicLink(atPath: root + "/bin/claude", withDestinationPath: root + "/app/claude")
        try fm.createSymbolicLink(atPath: root + "/versions", withDestinationPath: "share/claude/versions")
        let chain = try #require(FileFacts.read(root + "/bin/claude"))
        #expect(chain.realPath == root + "/share/claude/versions/2.1.280" && chain.isRegular)
        let followed: [String] = [root + "/bin/claude", root + "/app/claude"]
        #expect(chain.linksFollowed == followed)
        let folder = try #require(FileFacts.read(root + "/versions/2.1.280"))
        #expect(folder.realPath == chain.realPath && folder.linksFollowed == [root + "/versions"])
        let plain = try #require(FileFacts.read(root + "/share/claude/versions/2.1.280"))
        #expect(plain.linksFollowed.isEmpty)
        try fm.createSymbolicLink(atPath: root + "/loop", withDestinationPath: root + "/loop")
        #expect(FileFacts.read(root + "/loop") == nil)
    }

    @Test func codeOthersCanWriteGoesOnTheLine() {
        #expect(gate(realPath: "/Users/x/.local/share/claude/2.1.280", mode: 0o775) == .onTheLine([.ownership]))
        #expect(gate(realPath: "/Users/x/.local/share/claude/2.1.280", mode: 0o757) == .onTheLine([.ownership]))
        #expect(gate(realPath: "/Users/x/.local/share/claude/2.1.280", owner: geteuid() + 1) == .onTheLine([.ownership]))
        // Root's own agent in /usr/local/bin passes.
        guard case .resume = gate(realPath: "/usr/local/bin/claude", owner: 0) else {
            Issue.record("a root-owned agent did not pass")
            return
        }
    }

    @Test func aScriptAgentChecksItsInterpreterAndItsScript() {
        var (evidence, facts) = passing(.claude)
        evidence.executable = "/opt/homebrew/bin/node"
        evidence.interpreter = "/opt/homebrew/bin/node"
        let inProject = "/Users/x/app/node_modules/@anthropic-ai/claude-code/cli.js"
        evidence.script = inProject
        let node = FileFacts(realPath: "/opt/homebrew/Cellar/node/24.1.0/bin/node", owner: geteuid(), mode: 0o755, isRegular: true)
        facts.files["/opt/homebrew/bin/node"] = node
        facts.files[inProject] = FileFacts(realPath: inProject, owner: geteuid(), mode: 0o644, isRegular: true)
        #expect(evidence.gate(facts) == .onTheLine([.location]))
        let script = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        evidence.script = script
        #expect(evidence.gate(facts) == .onTheLine([.executable]))
        facts.files[script] = FileFacts(realPath: script, owner: geteuid(), mode: 0o664, isRegular: true)
        #expect(evidence.gate(facts) == .onTheLine([.ownership]))
        facts.files[script]?.mode = 0o644
        #expect(evidence.gate(facts) == .resume(evidence.resumeCommand ?? "none"))
    }

    /// The snapshot is read as untrusted, so the code it records must be the agent's, as capture judged it
    /// (CommandClassifier.agentName): by the executable's own name or install, or an interpreter running the agent's
    /// script. A recorded `/bin/zsh` for Codex would run `./resume` from the session's folder.
    @Test func codeThatIsNotTheAgentGoesOnTheLine() {
        typealias Code = (executable: String, interpreter: String?, script: String?)
        let claudeScript = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let codexScript = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
        let qwenScript = "/opt/homebrew/lib/node_modules/@qwen-code/qwen-code/cli.js"
        let theirs: [(RestoreAgent, Code)] = [
            (.claude, ("/Users/x/.local/bin/claude", nil, nil)),
            (.claude, ("/Users/x/.local/share/claude/versions/2.1.280", nil, nil)),
            (.claude, ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node", claudeScript)),
            (.codex, ("/opt/homebrew/bin/codex", nil, nil)),
            (.codex, ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node", codexScript)),
            (.qwen, ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node", qwenScript)),
        ]
        let notTheirs: [(RestoreAgent, Code)] = [
            (.codex, ("/bin/zsh", nil, nil)),
            (.claude, ("/usr/bin/python3", nil, nil)),
            (.claude, ("/opt/homebrew/bin/codex", nil, nil)),
            (.claude, ("/opt/homebrew/bin/node", nil, nil)),
            (.claude, ("/bin/sh", "/bin/sh", claudeScript)),
            (.claude, ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node", "/Users/x/tools/run.js")),
            (.claude, ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node", codexScript)),
            (.qwen, ("/Users/x/.local/bin/claude", nil, nil)),
        ]
        for (agent, code) in theirs + notTheirs {
            var (evidence, facts) = passing(agent)
            evidence.executable = code.executable
            evidence.interpreter = code.interpreter
            evidence.script = code.script
            for path in [code.executable, code.interpreter, code.script].compactMap({ $0 }) {
                facts.files[path] = FileFacts(realPath: path, owner: 0, mode: 0o755, isRegular: true)
            }
            let isTheirs = theirs.contains { $0.0 == agent && $0.1 == code }
            if isTheirs {
                #expect(evidence.gate(facts) == .resume(evidence.resumeCommand ?? "none"), "\(agent) \(code)")
            } else {
                #expect(evidence.resumeCommand == nil, "\(agent) \(code)")
                #expect(evidence.gate(facts) == .onTheLine([.executable]), "\(agent) \(code)")
            }
        }
    }

    /// A link the user owns in ~/.local/bin, not writable by others, that leads into the workspace: its real path decides.
    @Test func aUserLinkIntoTheWorkspaceGoesOnTheLine() throws {
        let root = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-agents-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/app/tools", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/home/.local/bin", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/app/tools/claude", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: root + "/home/.local/bin/claude", withDestinationPath: root + "/app/tools/claude")
        let link = try #require(FileFacts.read(root + "/home/.local/bin/claude"))
        #expect(link.realPath == root + "/app/tools/claude" && link.isRegular && link.owner == geteuid() && link.mode == 0o755)
        var (evidence, facts) = passing(.claude)
        evidence.executable = root + "/home/.local/bin/claude"
        facts.files[root + "/home/.local/bin/claude"] = link
        facts.temporaryFolders = []
        facts.outside = ["/Users/x/app", root + "/app"]
        #expect(evidence.gate(facts) == .onTheLine([.location]))
        facts.outside = ["/Users/x/app"]
        #expect(evidence.gate(facts) == .resume(evidence.resumeCommand ?? "none"))
    }

    @Test func fileFactsReadModesAndRefuseWhatIsNotThere() throws {
        let root = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-facts-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: false)
        fm.createFile(atPath: root + "/shared", contents: Data(), attributes: [.posixPermissions: 0o775])
        let shared = try #require(FileFacts.read(root + "/shared"))
        #expect(shared.mode == 0o775 && shared.isRegular && !shared.isDirectory && shared.links == 1 && shared.isLocal)
        let folder = try #require(FileFacts.read(root))
        #expect(folder.isDirectory && !folder.isRegular && folder.realPath == root)
        #expect(FileFacts.read(root + "/missing") == nil)
        #expect(FileFacts.read("relative/path") == nil)
        try fm.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: root + "/missing")
        #expect(FileFacts.read(root + "/dangling") == nil)
    }

    // MARK: rebuilt commands

    /// Random ids, folders, paths and model names from a pool of plain, shell, control, bidi, format and zero-width
    /// characters, each odd piece mixed into a resume that would otherwise be built: no line or command built from
    /// them holds a control or format character, and enough of them are built to say so.
    @Test func fuzzedRebuiltCommandsHoldNoControlOrFormatCharacter() {
        var random = SeededRandom(seed: 0x5EED)
        let odd: [UInt32] = [0x00, 0x07, 0x09, 0x0A, 0x0D, 0x1B, 0x7F, 0x85, 0x9B, 0xAD, 0x061C, 0x200B, 0x200E, 0x202A, 0x202E,
                             0x2028, 0x2029, 0x2066, 0xFEFF, 0xFFFE, 0xE0041, 0x1F600]
        let pool: [Unicode.Scalar] = Array("abcXYZ019-_.:/ ;'\"$`\\".unicodeScalars) + odd.compactMap { Unicode.Scalar($0) }
        func text(_ count: Int) -> String {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<count { scalars.append(pool[Int(random.next() % UInt64(pool.count))]) }
            return String(scalars)
        }
        /// `plain`, or with odd text set into it one time in `odds`.
        func mixed(_ plain: String, _ odds: UInt64) -> String {
            random.next() % odds == 0 ? plain + text(1 + Int(random.next() % 4)) : plain
        }
        var built = (lines: 0, commands: 0)
        for round in 0..<2000 {
            let agent = RestoreAgent.allCases[round % RestoreAgent.allCases.count]
            let id = mixed(Self.sampleID(agent), 3)
            let folder = mixed("/Users/x/app", 3)
            var lines = [agent.putBackLine(id: id, folder: folder)]
            let automatic = Self.automatic[round % Self.automatic.count]
            let script = round % 2 == 0
            let package = ["claude": "@anthropic-ai/claude-code/cli.js", "codex": "@openai/codex/bin/codex.js",
                           "qwen": "@qwen-code/qwen-code/cli.js"][automatic.program ?? ""] ?? "agent/cli.js"
            let binary = "/opt/homebrew/bin/" + (automatic.program ?? "agent")
            var evidence = Evidence(agent: automatic, sessionID: mixed(Self.sampleID(automatic), 4), source: .sessionFile,
                                    sessionFolder: mixed("/Users/x/app", 4),
                                    executable: mixed(script ? "/opt/homebrew/bin/node" : binary, 5),
                                    interpreter: script ? mixed("/opt/homebrew/bin/node", 5) : nil,
                                    script: script ? mixed("/opt/homebrew/lib/node_modules/" + package, 5) : nil)
            let model = automatic == .codex ? ["-m", mixed("gpt-5", 3)] : ["--model", mixed("opus", 3)]
            evidence.options = [SessionSnapshot.LaunchOption(model)]
            let command = evidence.resumeCommand
            lines.append(command)
            if command != nil { built.commands += 1 }
            if let line = lines[0], line.contains(" ") { built.lines += 1 }
            for line in lines.compactMap({ $0 }) {
                #expect(SessionSnapshot.Command.problem(with: line) == nil, "\(line.unicodeScalars.map(\.value))")
            }
        }
        #expect(built.commands >= 400, "\(built.commands) resume commands built")
        #expect(built.lines >= 600, "\(built.lines) put-back lines with an id built")
    }
}

/// SplitMix64: the same numbers on every run.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
