import Foundation
import Testing
@testable import NextTermCore

/// The agent CLI table (KTD20): each agent's entry, read byte for byte; the fixes made as the words moved into it; and
/// the drift tests that pin the words the session list and the classifier still keep to it until 0.12.
@Suite struct AgentCLITests {
    static let uuid = RestoreAgentsTests.uuid
    var uuid: String { Self.uuid }

    /// A reading as one line: each piece as `class:name=value,value`, `?name` for an option the table does not know, and
    /// a word in quotes; then the session a form names.
    static func describe(_ reading: AgentCLI.Reading) -> String {
        var parts: [String] = reading.pieces.map { piece in
            switch piece {
            case .known(let name, let values, let option):
                let given = values.isEmpty ? "" : "=" + values.joined(separator: ",")
                return option.kind.rawValue + ":" + name + given
            case .unknown(let name, let value):
                return "?" + name + (value.map { "=" + $0 } ?? "")
            case .word(let word):
                return "\"" + word + "\""
            }
        }
        if let session = reading.session { parts.append("| " + session) }
        return parts.joined(separator: " ")
    }

    // MARK: goldens

    struct Golden {
        var agent: RestoreAgent
        var programs: [String]
        var launch: [String]
        var reading: String
    }

    /// One launch per agent with its options, prompt words and a form, and how the table reads it.
    var goldens: [Golden] {
        let s = uuid
        return [
            Golden(agent: .claude, programs: ["claude", "claude-code", "claude.exe"],
                   launch: ["--model", "opus[1m]", "--dangerously-skip-permissions", "--permission-mode", "plan", "--mcp-config", "a.json",
                            "b.json", "-r", s, "--newflag", "fix the tests"],
                   reading: "plain:--model=opus[1m] permission:--dangerously-skip-permissions permission:--permission-mode=plan "
                       + "codeLoading:--mcp-config=a.json,b.json form:-r=\(s) ?--newflag \"fix the tests\" | \(s)"),
            Golden(agent: .codex, programs: ["codex"],
                   launch: ["--yolo", "-m", "gpt-5", "-c", "model_reasoning_effort=high", "resume", "-C", "/Users/x/app", s, "exec"],
                   reading: "permission:--yolo plain:-m=gpt-5 codeLoading:-c=model_reasoning_effort=high form:resume=\(s) "
                       + "form:-C=/Users/x/app \"exec\" | \(s)"),
            Golden(agent: .qwen, programs: ["qwen", "qwen-code"],
                   launch: ["-y", "--approval-mode=yolo", "--model", "qwen3-coder", "-p", "explain", "--continue"],
                   reading: "permission:-y permission:--approval-mode=yolo plain:--model=qwen3-coder oneShot:-p=explain form:--continue"),
            Golden(agent: .copilot, programs: ["copilot"],
                   launch: ["-r", s, "--allow-all", "--model", "gpt-5", "--allow-tool", "shell(git)", "write"],
                   reading: "form:-r=\(s) permission:--allow-all plain:--model=gpt-5 permission:--allow-tool=shell(git),write | \(s)"),
            Golden(agent: .gemini, programs: ["gemini", "gemini-cli"],
                   launch: ["--approval-mode=yolo", "--session-id", s, "-m", "gemini-3-pro", "-i", "go on"],
                   reading: "permission:--approval-mode=yolo form:--session-id=\(s) plain:-m=gemini-3-pro oneShot:-i=go on | \(s)"),
            Golden(agent: .cursor, programs: ["cursor-agent"],
                   launch: ["resume", "-f", "--model", "sonnet-4"],
                   reading: "form:resume permission:-f plain:--model=sonnet-4"),
            Golden(agent: .opencode, programs: ["opencode"],
                   launch: ["--session", "ses_6a3f2b9c1d", "--auto", "-m", "anthropic/claude-sonnet-4", "--fork"],
                   reading: "form:--session=ses_6a3f2b9c1d permission:--auto plain:-m=anthropic/claude-sonnet-4 form:--fork | ses_6a3f2b9c1d"),
            Golden(agent: .amp, programs: ["amp"],
                   launch: ["threads", "continue", "T-" + s],
                   reading: "form:threads form:continue=T-\(s) | T-\(s)"),
            Golden(agent: .junie, programs: ["junie"],
                   launch: ["--brave", "--session-id", "s-42_a.b", "--resume"],
                   reading: "permission:--brave form:--session-id=s-42_a.b form:--resume | s-42_a.b"),
            Golden(agent: .commandCode, programs: ["command-code", "commandcode"],
                   launch: ["--yolo", "--permission-mode", "accept-edits", "--session", "s-42_a.b", "-p", "fix it"],
                   reading: "permission:--yolo permission:--permission-mode=accept-edits form:--session=s-42_a.b oneShot:-p=fix it | s-42_a.b"),
            Golden(agent: .kiro, programs: ["kiro-cli", "kiro"],
                   launch: ["chat", "--trust-all-tools", "--resume-id", "s-42_a.b"],
                   reading: "form:chat permission:--trust-all-tools form:--resume-id=s-42_a.b | s-42_a.b"),
            Golden(agent: .goose, programs: ["goose"],
                   launch: ["session", "--with-extension", "npx -y server", "-n", "work", "--debug"],
                   reading: "form:session codeLoading:--with-extension=npx -y server form:-n=work plain:--debug"),
            Golden(agent: .agy, programs: ["agy"], launch: ["fix it"], reading: "\"fix it\""),
            Golden(agent: .aider, programs: ["aider"], launch: ["--yes-always", "--model", "sonnet"],
                   reading: "permission:--yes-always plain:--model=sonnet"),
            Golden(agent: .unknown, programs: [], launch: ["--x", "y"], reading: "?--x \"y\""),
        ]
    }

    @Test func eachAgentsEntryReadsItsLaunchByteForByte() {
        let goldens = goldens
        #expect(goldens.map(\.agent) == RestoreAgent.allCases)
        for golden in goldens {
            #expect(golden.agent.cli.programs == golden.programs, "\(golden.agent)")
            #expect(Self.describe(golden.agent.cli.read(golden.launch)) == golden.reading, "\(golden.agent)")
        }
    }

    /// The resume template each agent's line and resume carry, with the subcommand its options belong to.
    @Test func eachAgentsResumeFormByteForByte() {
        let forms: [(RestoreAgent, [String], String)] = [
            (.claude, [], "--resume \(uuid)"),
            (.codex, [], "resume \(uuid) -C /Users/x/app"),
            (.qwen, [], "--resume \(uuid)"),
            (.copilot, [], "--resume=\(uuid)"),
            (.gemini, [], "--resume \(uuid)"),
            (.cursor, [], "--resume s-42_a.b"),
            (.opencode, [], "-s ses_6a3f2b9c1d"),
            (.amp, [], "threads continue T-\(uuid)"),
            (.junie, [], "--session-id s-42_a.b --resume"),
            (.commandCode, [], "--resume s-42_a.b"),
            (.kiro, ["chat"], "--resume-id s-42_a.b"),
            (.goose, ["session"], "--resume --session-id s-42_a.b"),
        ]
        let withForm: [RestoreAgent] = RestoreAgent.allCases.filter { $0.cli.resume != nil }
        #expect(forms.map(\.0) == withForm)
        for (agent, subcommand, form) in forms {
            let id = RestoreAgentsTests.sampleID(agent)
            #expect(agent.cli.subcommand == subcommand, "\(agent)")
            #expect(agent.cli.resumeWords(id: id, folder: "/Users/x/app")?.joined(separator: " ") == form, "\(agent)")
        }
        // Codex names the folder only when it is a plain absolute path, and leaves `-C` out with it.
        #expect(RestoreAgent.codex.cli.resumeWords(id: uuid, folder: "relative") == ["resume", uuid])
        #expect(RestoreAgent.codex.cli.resumeWords(id: uuid, folder: nil) == ["resume", uuid])
        for agent in [RestoreAgent.agy, .aider, .unknown] {
            #expect(agent.cli.resumeWords(id: uuid, folder: nil) == nil && agent.cli.idPattern == nil)
        }
    }

    /// Every word the resume form adds is the agent's own form: a line with it reads back as forms naming the id, and
    /// nothing in it is ever left off or carried.
    @Test func theResumeFormReadsBackAsFormsNamingItsID() throws {
        for agent in RestoreAgent.allCases where agent.cli.resume != nil {
            let id = RestoreAgentsTests.sampleID(agent)
            let words = try #require(agent.resumeWords(id: id, folder: "/Users/x/app"))
            let reading = agent.cli.read(words)
            #expect(reading.session == id, "\(agent)")
            #expect(Self.leftOver(reading).isEmpty, "\(agent) \(Self.describe(reading))")
            #expect(agent.launchOptions(in: words) == [], "\(agent)")
        }
    }

    /// The pieces of a reading that are not forms.
    static func leftOver(_ reading: AgentCLI.Reading) -> [AgentCLI.Piece] {
        reading.pieces.filter { piece in
            guard case .known(_, _, let option) = piece else { return true }
            return option.kind != .form
        }
    }

    @Test func everyEntryIsCheckedAndOnlyItsOwnOptionsAreHidden() {
        // A date as the release check prints it (`date +%Y-%m-%d`), so a release that sets it from that output passes.
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        for agent in RestoreAgent.allCases where agent != .unknown {
            let cli = agent.cli
            let date = format.date(from: cli.checked.date)
            #expect(date.map(format.string(from:)) == cli.checked.date, "\(agent): \(cli.checked.date)")
            #expect(cli.checked.version.map { !$0.isEmpty } ?? true, "\(agent)")
            #expect(cli.hidden.isSubset(of: Set(cli.options.keys)), "\(agent)")
        }
        #expect(RestoreAgent.codex.cli.hidden.isSuperset(of: ["--yolo", "-P", "--permission-profile"]))
        #expect(RestoreAgent.opencode.cli.hidden == ["--yolo", "--dangerously-skip-permissions"])
        #expect(RestoreAgent.cursor.cli.hidden == ["--yolo"])
    }

    // MARK: reading values

    @Test func valuesAreReadAsTheirOptionTakesThem() {
        let claude = RestoreAgent.claude.cli
        // `=` joins a value; a word that starts with `-` is never one; `--` ends the options.
        #expect(Self.describe(claude.read(["--model=opus", "--model", "-x", "--", "--model", "y"]))
            == "plain:--model=opus plain:--model ?-x \"--model\" \"y\"")
        // Many values run to the next option, and a value-less option leaves the next word a word.
        #expect(Self.describe(claude.read(["--add-dir", "a", "b", "--verbose", "fix"])) == "codeLoading:--add-dir=a,b plain:--verbose \"fix\"")
        // A command counts only among the first words: after a prompt word, or a command's value, it is a word.
        #expect(Self.describe(RestoreAgent.codex.cli.read(["fix", "resume"])) == "\"fix\" \"resume\"")
        #expect(Self.describe(RestoreAgent.codex.cli.read(["exec", "fix", "resume"])) == "oneShot:exec \"fix\" \"resume\"")
        #expect(Self.describe(RestoreAgent.codex.cli.read(["resume", "a", "exec"])) == "form:resume=a \"exec\" | a")
        // A session form with no value names no session (`claude -r` opens the picker).
        #expect(claude.read(["-r"]).session == nil)
        #expect(claude.read(["--resume", "a", "--session-id", "b"]).session == "a")
    }

    @Test func valuePatternsTakeOnlyPlainWords() {
        for model in ["opus", "opus[1m]", "claude-opus-4-5", "gpt-5.1-codex", "anthropic/claude-sonnet-4", "qwen3:coder"] {
            #expect(AgentCLI.ValuePattern.model.matches(model), "\(model)")
        }
        for bad in ["[1m]", "opus;rm", "a b", "op$(id)", "", "-x", String(repeating: "a", count: 65), "opus\u{202E}"] {
            #expect(!AgentCLI.ValuePattern.model.matches(bad), "\(bad)")
        }
        #expect(AgentCLI.ValuePattern.mode.matches("bypassPermissions") && AgentCLI.ValuePattern.mode.matches("on-request"))
        #expect(!AgentCLI.ValuePattern.mode.matches("plan;id"))
        #expect(AgentCLI.ValuePattern.tools.matches("Bash(git *)") && !AgentCLI.ValuePattern.tools.matches("Bash($(id))"))
    }

    // MARK: the fixes made as the words moved in

    /// Copilot's `-r` and `--session-id`, Gemini's `--session-id` and opencode's `--session` are forms: dropped, never
    /// left off, and they name the session.
    @Test func sessionOptionsTheMatrixMissedAreForms() {
        let cases: [(RestoreAgent, String, String)] = [
            (.copilot, "-r", uuid), (.copilot, "--session-id", uuid), (.gemini, "--session-id", uuid),
            (.opencode, "--session", "ses_6a3f2b9c1d"),
        ]
        for (agent, option, id) in cases {
            for words in [[option, id], [option + "=" + id]] {
                let reading = agent.cli.read(words + ["fix it"])
                #expect(reading.session == id, "\(agent) \(words)")
                #expect(agent.resumedID(in: words) == id, "\(agent) \(words)")
                #expect(agent.launchOptions(in: words + ["fix it"]) == [], "\(agent) \(words)")
            }
        }
        // AE29: Copilot's `-r` is dropped, never left off, and `--allow-all` comes back on the line.
        var copilot = SessionSnapshot.Evidence(agent: .copilot)
        copilot.options = RestoreAgent.copilot.launchOptions(in: ["-r", uuid, "--allow-all"])
        #expect(copilot.options == [SessionSnapshot.LaunchOption(["--allow-all"])])
        #expect(copilot.putBack(id: uuid) == PutBack(line: "copilot --allow-all --resume=\(uuid)", namesSession: true, leftOff: []))
    }

    /// `opus[1m]` is a model: carried by an automatic resume, quoted, and kept through the snapshot's repair.
    @Test func aModelWithAContextSizeIsCarried() {
        let options = RestoreAgent.claude.launchOptions(in: ["--model", "opus[1m]"])
        var evidence = SessionSnapshot.Evidence(agent: .claude, sessionID: uuid, source: .sessionFile, sessionFolder: "/Users/x/app",
                                                executable: "/Users/x/.local/bin/claude", options: options)
        #expect(evidence.launch.plain == ["--model", "opus[1m]"] && evidence.launch.allowed)
        #expect(evidence.resumeCommand?.hasSuffix("--resume \(uuid) --model 'opus[1m]'") == true)
        let repaired = evidence.repaired(limits: .standard)
        #expect(repaired.options == options && repaired.launch.allowed)
        evidence.agent = .codex
        evidence.options = RestoreAgent.codex.launchOptions(in: ["-m=gpt-5[1m]"])
        #expect(evidence.launch.plain == ["-m=gpt-5[1m]"] && evidence.launch.allowed)
    }

    /// Cursor runs as `cursor-agent`, or as `agent` only from its own install; Command Code as `command-code`, or as
    /// `cmd` only from its own: other programs share those names.
    @Test func aSharedNameCountsOnlyAtTheAgentsOwnInstall() {
        let cursorFile = "/Users/x/.local/share/cursor-agent/versions/2026.10.01-7ce4/cursor-agent"
        #expect(RestoreAgent(program: "cursor-agent") == .cursor)
        #expect(RestoreAgent(program: "agent") == nil)
        #expect(RestoreAgent(program: "agent", at: [cursorFile]) == .cursor)
        #expect(RestoreAgent(program: "agent", at: ["/Users/x/bin/agent"]) == nil)
        let commandFile = "/opt/homebrew/lib/node_modules/command-code/dist/index.mjs"
        #expect(RestoreAgent(program: "command-code") == .commandCode && RestoreAgent(program: "commandcode") == .commandCode)
        #expect(RestoreAgent(program: "cmd") == nil)
        #expect(RestoreAgent(program: "cmd", at: [commandFile]) == .commandCode)
        #expect(RestoreAgent(program: "cmd", at: [cursorFile]) == nil)
        #expect(RestoreAgent.cursor.cli.installedNames == ["agent"] && RestoreAgent.commandCode.cli.installedNames == ["cmd"])
    }

    /// Cursor's install runs its own node on `index.js`: its versions folder names it, and its arguments are read.
    @Test func cursorsOwnNodeIsCursor() throws {
        let folder = "/Users/x/.local/share/cursor-agent/versions/2026.10.01-7ce4"
        let process = AgentProcess(pid: 42, startedAt: nil, executable: folder + "/node",
                                   arguments: [folder + "/node", folder + "/index.js", "--resume", "s-42_a.b", "-f"])
        #expect(RestoreAgent(process: process) == .cursor)
        let arguments = RestoreAgent.arguments(argv: process.arguments, executable: process.executable)
        #expect(arguments == ["--resume", "s-42_a.b", "-f"])
        #expect(RestoreAgent.cursor.resumedID(in: arguments) == "s-42_a.b")
        // Another program's node, in a project named like it, is none.
        let project = AgentProcess(pid: 43, startedAt: nil, executable: "/opt/homebrew/bin/node",
                                   arguments: ["node", "/Users/x/Code/cursor-agent/index.js"])
        #expect(RestoreAgent(process: project) == nil)
    }

    /// `cmd` is Command Code when the script it runs is Command Code's own, through the link npm makes; another `cmd`
    /// is an agent the table does not know.
    @Test func cmdIsCommandCodeOnlyThroughItsOwnScript() throws {
        let root = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-cmd-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/lib/node_modules/command-code/dist", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/lib/node_modules/command-code/dist/index.mjs", contents: Data())
        try fm.createSymbolicLink(atPath: root + "/bin/cmd", withDestinationPath: "../lib/node_modules/command-code/dist/index.mjs")
        let ours = AgentProcess(pid: 42, startedAt: nil, executable: "/opt/homebrew/bin/node", arguments: ["node", root + "/bin/cmd", "--yolo"])
        #expect(RestoreAgent(process: ours) == .commandCode)
        let theirs = AgentProcess(pid: 43, startedAt: nil, executable: "/usr/local/bin/cmd", arguments: ["cmd", "--help"])
        #expect(RestoreAgent(process: theirs) == .unknown)
        #expect(RestoreAgent(line: "cmd --resume s1") == .unknown)
    }

    // MARK: no prompt word ever reaches a line

    /// R8, KTD7: random prompt words, quoted any way and mixed with each agent's options (known, unknown, forms and
    /// one-shot options, whose value is a prompt), typed as the agent or through an alias, never reach a put-back line
    /// or a resume command. Capture keeps argv's options alone, and the restore reads them again with the table. A
    /// prompt word goes only where the agent too reads one: never where an option still takes values.
    @Test func noPromptWordEverReachesALineOrAResume() throws {
        var random = SeededRandom(seed: 0x9F0_3C7)
        func pick(_ count: Int) -> Int { Int(random.next() % UInt64(count)) }
        let pool: [Character] = Array("abc XYZ 019 ;'\"$`\\*?(){}[]<>|&!#~=-_.,:/\u{00E9}\u{202E}\u{200B}\u{1F600}")
        // Every prompt word starts with a mark no option, value, path or variable name holds.
        var marks = 0
        func prompt() -> String {
            marks += 1
            return "Xyzzy\(marks)" + String((0..<pick(12)).map { _ in pool[pick(pool.count)] })
        }
        /// A word as a person types it: bare when plain, else in single or double quotes, or with each odd character
        /// escaped. Only this test's reader (AgentKind.words) reads it back, so each form is one it reads.
        func typed(_ word: String) -> String {
            func alphanumeric(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
            let plain: Bool = !word.isEmpty && word.allSatisfy { (character: Character) -> Bool in
                alphanumeric(character) || "-_./=:@%+,".contains(character)
            }
            switch pick(3) {
            case 0:
                return plain ? word : ShellQuote.quote(word)
            case 1:
                let inside: [String] = word.map { (character: Character) -> String in
                    "\"\\$`".contains(character) ? "\\" + String(character) : String(character)
                }
                return "\"" + inside.joined() + "\""
            default:
                let escaped: [String] = word.map { (character: Character) -> String in
                    alphanumeric(character) ? String(character) : "\\" + String(character)
                }
                return escaped.joined()
            }
        }
        let agents: [RestoreAgent] = RestoreAgent.allCases.filter(\.hasResumeForm)
        var built = (lines: 0, replayed: 0, kept: 0, commands: 0, leftOff: 0)
        for round in 0..<1500 {
            let agent = agents[round % agents.count]
            let cli = agent.cli
            let program = try #require(agent.program)
            let id = RestoreAgentsTests.sampleID(agent)
            let names: [String] = cli.groups.flatMap(\.names).filter { $0.hasPrefix("-") }
            var arguments: [String] = []
            // A subcommand first, now and then: Codex's `exec`, Kiro's `chat`.
            let commands: [String] = cli.groups.flatMap(\.names).filter { !$0.hasPrefix("-") }
            if !commands.isEmpty, pick(4) == 0 {
                let command = commands[pick(commands.count)]
                arguments.append(command)
                if cli.options[command]?.values != AgentCLI.Values.none { arguments.append(cli.options[command]?.namesSession == true ? id : prompt()) }
            }
            var takesMore = false
            for _ in 0..<pick(7) {
                switch pick(takesMore ? 3 : 4) {
                case 0 where !names.isEmpty:
                    let name = names[pick(names.count)]
                    let option = try #require(cli.options[name])
                    // A session form's value is an id; a one-shot option's is the prompt; the rest take plain values.
                    let value = option.namesSession ? id : option.kind == .oneShot ? prompt() : "v\(pick(9))"
                    switch option.values {
                    case .none:
                        arguments.append(name)
                    case .one:
                        arguments += pick(2) == 0 ? [name + "=" + value] : [name, value]
                    case .many:
                        arguments += [name] + (0...pick(2)).map { "v\($0)" }
                    }
                    takesMore = option.values == .many
                case 1:
                    let name = "--zq\(pick(5))"
                    arguments.append(pick(2) == 0 ? name + "=v\(pick(9))" : name)
                    takesMore = false
                case 2:
                    arguments.append("-" + "abc".map(String.init)[pick(3)] + "q")
                    takesMore = false
                default:
                    arguments.append(prompt())
                    takesMore = false
                }
            }
            if !takesMore, pick(5) == 0 { arguments += ["--", prompt(), "--zq9"] }
            // Typed as the agent itself, or through an alias (`ag`, whose expansion the shell sends) or a function (`fn`,
            // whose own words nothing shows) that holds some of the agent's own options, and now and then a prompt word of
            // its own or an end of options (`--`). Either passes the words typed after it on.
            let own: [String] = names.filter { (name: String) -> Bool in
                guard let option = cli.options[name] else { return false }
                return option.values == .none && (option.kind == .plain || option.kind == .permission)
            }
            let launcher = ["", "ag", "fn"][pick(3)]
            var ownWords: [String] = launcher.isEmpty ? [] : Array(own.prefix(pick(3)))
            if !launcher.isEmpty, pick(3) == 0 { ownWords.append(prompt()) }
            if !launcher.isEmpty, pick(4) == 0 { ownWords.append("--") }
            let holdsPrompt = ownWords.contains("--") || ownWords.contains { $0.hasPrefix("Xyzzy") }
            let argv = [program] + ownWords + arguments
            let rest = arguments.map(typed).joined(separator: " ")
            let body = ([program] + ownWords.map(typed)).joined(separator: " ")
            let line = (launcher.isEmpty ? program : launcher) + " " + rest
            let expanded = launcher == "ag" ? body + " " + rest : nil
            let leader = AgentProcess(pid: 7, startedAt: Date(timeIntervalSince1970: 1_790_000_000), executable: "/opt/homebrew/bin/" + program,
                                      arguments: argv)
            let input = AgentEvidence.Capture(leader: leader, verified: true, typedLine: line, expandedLine: expanded, home: "/Users/x")
            var evidence = try #require(AgentEvidence.capture(input), "\(argv)")
            #expect(evidence.agent == agent, "\(argv)")
            // A launcher whose own words hold a prompt word or `--` is never replayed, and did not run as typed.
            if holdsPrompt { #expect(evidence.launcher == nil && !evidence.ranAsTyped, "\(line) for \(argv)") }
            evidence.sessionID = id
            evidence.source = agent.fileSource ?? .typedAndArgv
            evidence.sessionFolder = "/Users/x/app"
            let put = try #require(evidence.putBack(id: id, folder: "/Users/x/app"), "\(argv)")
            let command = evidence.resumeCommand
            // The line as the shell runs it: a launcher replayed runs its own words first.
            let replayed = !launcher.isEmpty && (put.line == launcher || put.line.hasPrefix(launcher + " "))
            let ran = replayed ? body + put.line.dropFirst(launcher.count) : put.line
            for text in [ran, command ?? ""] + put.leftOff {
                #expect(!text.contains("Xyzzy"), "\(argv) gave \(text)")
                #expect(SessionSnapshot.Command.problem(with: text) == nil, "\(text)")
            }
            // It resumes the session it names: its resume form reads back as forms, never as a prompt after `--`.
            if put.namesSession {
                let words = AgentKind.words(ran)
                #expect(cli.read(Array(words.dropFirst())).session == id, "\(argv) gave \(ran)")
            }
            built.lines += 1
            if evidence.launcher != nil { built.replayed += 1 }
            if evidence.options?.isEmpty == false { built.kept += 1 }
            if command != nil { built.commands += 1 }
            if !put.leftOff.isEmpty { built.leftOff += 1 }
        }
        // Enough of each kind ran: replayed launchers, kept options, resume commands, and options left off.
        let enough: Bool = built.replayed >= 300 && built.kept >= 600 && built.commands >= 30 && built.leftOff >= 100
        #expect(enough, "\(built)")
    }

    // MARK: drift: what keeps its own words until 0.12 agrees with the table

    /// Every command the session list builds (resume, fork and continue) is the agent's program and its forms: it reads
    /// back through the table with the same id, and nothing left over.
    @Test func theSessionListsCommandsReadBackAsForms() throws {
        for kind in AgentKind.allCases {
            let agent = RestoreAgent(kind: kind)
            let id = RestoreAgentsTests.sampleID(agent)
            let commands = [(kind.resumeCommand(id: id, cwd: "/Users/x/app", fork: false), id),
                            (kind.resumeCommand(id: id, cwd: "/Users/x/app", fork: true), id),
                            (kind.continueCommand, nil)]
            for (command, named) in commands {
                let words = AgentKind.words(command)
                let program = try #require(words.first)
                #expect(RestoreAgent(program: program) == agent, "\(command)")
                let reading = agent.cli.read(Array(words.dropFirst()))
                #expect(Self.leftOver(reading).isEmpty, "\(command): \(Self.describe(reading))")
                let session = reading.session.flatMap { agent.isSessionID($0) ? $0 : nil }
                #expect(session == named, "\(command)")
            }
        }
    }

    @Test func theSessionListsIDOptionsAreFormsNamingTheSession() {
        for kind in AgentKind.allCases {
            let cli = RestoreAgent(kind: kind).cli
            for option in kind.idOptions {
                let entry = cli.options[option]
                #expect(entry?.kind == .form && entry?.namesSession == true, "\(kind) \(option)")
            }
        }
    }

    @Test func theClassifierKnowsEveryProgramTheTableNamesAlone() {
        for agent in RestoreAgent.allCases {
            for program in agent.cli.programs {
                #expect(CommandClassifier.agents.contains(program), "\(agent) \(program)")
                #expect(RestoreAgent(program: program) == agent, "\(agent) \(program)")
                if let kind = agent.kind { #expect(AgentKind(program: program) == kind, "\(agent) \(program)") }
            }
        }
    }

    /// The paste dialect each program gets (AgentPrompt) is the same for every name the table runs its agent by, so a name
    /// the table adds is not pasted to as another program.
    @Test func thePasteDialectIsTheSameForEveryNameOfAnAgent() {
        let expected: [RestoreAgent: AgentDialect] = [.claude: .atHash, .opencode: .atHash, .copilot: .atColon, .gemini: .atProse,
                                                      .qwen: .atProse]
        for agent in RestoreAgent.allCases {
            let dialects: [AgentDialect] = agent.cli.programs.map(AgentDialect.forProgram)
            #expect(Set(dialects).count <= 1, "\(agent): \(dialects)")
            #expect(dialects.allSatisfy { $0 == expected[agent] ?? .plain }, "\(agent): \(dialects)")
        }
    }

    /// The commit message agents run as their agent's program, by its name, and only ever once: their arguments read with
    /// the table as a one-shot run, never as a launch a restore would keep or resume.
    @Test func theCommitMessageAgentsRunTheirAgentOnce() throws {
        for known in CommitMessageAgent.known {
            let agent = try #require(RestoreAgent(program: known.program), "\(known.program)")
            #expect(agent.program == known.program && agent.name == known.name, "\(known.program)")
            let arguments = known.arguments(prompt: "Xyzzy write it", answerFile: "/Users/x/answer")
            let pieces = agent.cli.read(arguments).pieces
            let once = pieces.contains { (piece: AgentCLI.Piece) -> Bool in
                guard case .known(_, _, let option) = piece else { return false }
                return option.kind == .oneShot
            }
            #expect(once, "\(known.program): \(Self.describe(agent.cli.read(arguments)))")
        }
    }

    /// Suggest a Command's agents run as their agent's program, by its name, and only ever once; the agents it leaves
    /// out are named as the table names them.
    @Test func theCommandSuggestionAgentsRunTheirAgentOnce() throws {
        for adapter in CommandSuggestion.adapters {
            let agent = try #require(RestoreAgent(program: adapter.program), "\(adapter.program)")
            #expect(agent.program == adapter.program && agent.name == adapter.name, "\(adapter.program)")
            let reading = agent.cli.read(adapter.arguments)
            let once = reading.pieces.contains { (piece: AgentCLI.Piece) -> Bool in
                guard case .known(_, _, let option) = piece else { return false }
                return option.kind == .oneShot
            }
            #expect(once && reading.session == nil, "\(adapter.program): \(Self.describe(reading))")
        }
        let names = Set(RestoreAgent.allCases.map(\.name))
        for (name, _) in CommandSuggestion.leftOut {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func noOptionIsInTwoClasses() {
        for agent in RestoreAgent.allCases {
            let names = agent.cli.groups.flatMap(\.names)
            #expect(names.count == Set(names).count, "\(agent): \(names.filter { name in names.filter { $0 == name }.count > 1 })")
            let byClass: [Int] = AgentCLI.Class.allCases.map { agent.cli.names($0).count }
            #expect(byClass.reduce(0, +) == names.count, "\(agent)")
        }
    }
}
