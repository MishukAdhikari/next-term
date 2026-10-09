import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// What capture makes of a live agent: its session id and how it is known (the agent's own file, the typed line and
/// argv agreeing, or a guess), its paths, options and environment facts. Each agent's store is made here by hand in
/// a temporary home, and the process is this test's own, or one described.
@Suite struct AgentEvidenceTests {
    typealias Evidence = SessionSnapshot.Evidence
    let uuid = "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c"
    let other = "0d9c8b7a-6f5e-4d3c-8b2a-1f0e9d8c7b6a"

    /// A temporary home and a project folder in it. Remove it after.
    func makeHome() throws -> (home: String, project: String) {
        let home = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-evidence-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/Code/app", withIntermediateDirectories: true)
        return (home, home + "/Code/app")
    }

    func write(_ text: String, to path: String, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// When this test process started, as the kernel has it.
    func ownStart() throws -> Date {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try #require(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size)
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// This process, described as an agent run with `arguments` in `directory`.
    func process(_ arguments: [String], executable: String = "/Users/x/.local/share/claude/versions/2.1.280",
                 directory: String? = nil, environment: [String: String] = [:], openFiles: [String] = []) throws -> AgentProcess {
        AgentProcess(pid: getpid(), startedAt: try ownStart(), executable: executable, arguments: arguments, environment: environment,
                     directory: directory, openFiles: openFiles)
    }

    func capture(_ leader: AgentProcess?, typed: String? = nil, home: String, children: [String] = [],
                 shell: [String: String] = [:]) -> Evidence? {
        AgentEvidence.capture(AgentEvidence.Capture(leader: leader, verified: true, childSessionIDs: children, typedLine: typed,
                                                    shellEnvironment: shell, home: home))
    }

    // MARK: KERN_PROCARGS2

    /// The kernel's layout: argc, the executable path and its padding, argv, the environment, then the loader's strings.
    func procArgs(argc: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        for (index, string) in strings.enumerated() {
            bytes += Array(string.utf8) + [0]
            if index == 0 { bytes += [UInt8](repeating: 0, count: padding) }
        }
        return bytes
    }

    @Test func procArgsKeepTheWholeArgvAndOnlyAllowlistedVariables() throws {
        let bytes = procArgs(argc: 3, ["/opt/homebrew/bin/node", "node", "/opt/lib/cli.js", "--resume",
                                       "PATH=/usr/bin:/bin", "GITHUB_TOKEN=ghp_abc", "ANTHROPIC_BASE_URL=https://example.com", "",
                                       "executable_path=/opt/homebrew/bin/node"])
        let parsed = try #require(ProcessArguments.parse(bytes, keeping: ["PATH", "ANTHROPIC_BASE_URL", "executable_path"]))
        #expect(parsed.executable == "/opt/homebrew/bin/node")
        #expect(parsed.arguments == ["node", "/opt/lib/cli.js", "--resume"])
        #expect(parsed.environment == ["PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": "https://example.com"])
        let many = procArgs(argc: 20, ["/bin/x"] + (0..<20).map { "a\($0)" })
        #expect(try #require(ProcessArguments.parse(many, keeping: [])).arguments.count == 20)
    }

    @Test func procArgsRefuseWhatIsCutShortOrNotThere() {
        let whole = procArgs(argc: 2, ["/bin/x", "x", "y", "HOME=/Users/x"])
        for cut in [0, 2, 4, 8, 12, 14] { #expect(ProcessArguments.parse(Array(whole.prefix(cut)), keeping: ["HOME"]) == nil, "\(cut)") }
        #expect(ProcessArguments.parse(procArgs(argc: -1, ["/bin/x"]), keeping: []) == nil)
        #expect(ProcessArguments.parse(procArgs(argc: 9, ["/bin/x", "x"]), keeping: []) == nil)
        // An environment cut off at the end keeps what read whole.
        let open = Array(whole.dropLast())
        #expect(ProcessArguments.parse(open, keeping: ["HOME"])?.environment.isEmpty == true)
    }

    // MARK: Claude Code

    func claudeFile(home: String, pid: Int32 = getpid(), fields: [String: Any]) throws {
        try write(json(fields), to: home + "/.claude/sessions/\(pid).json")
    }

    func claudeFields(start: Date, cwd: String) -> [String: Any] {
        ["pid": Int(getpid()), "sessionId": uuid, "cwd": cwd, "procStart": AgentEvidence.procStartText(start), "status": "busy",
         "startedAt": 1_790_000_000_000, "version": "2.1.280"]
    }

    @Test func procStartReadsAsPsWritesIt() throws {
        let date = try #require(AgentEvidence.procStart("Wed Oct  7 18:05:43 2026"))
        #expect(date == Date(timeIntervalSince1970: 1_791_396_343))
        #expect(AgentEvidence.procStartText(date) == "Wed Oct  7 18:05:43 2026")
        #expect(AgentEvidence.procStartText(Date(timeIntervalSince1970: 1_792_000_000.9)) == "Wed Oct 14 17:46:40 2026")
        #expect(AgentEvidence.procStart("yesterday") == nil && AgentEvidence.procStart("") == nil)
    }

    @Test func aClaudeSessionFileForThisVeryProcessIsExact() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try claudeFile(home: home, fields: claudeFields(start: try ownStart(), cwd: project))
        let record = try AgentSessions.claudeProcess(pid: getpid(), home: home).get()
        #expect(record.sessionID == uuid && record.cwd == project && record.status == "busy" && record.pid == getpid())
        let evidence = try #require(capture(try process(["claude"], directory: home), typed: "claude", home: home))
        #expect(evidence.agent == .claude && evidence.sessionID == uuid && evidence.source == .sessionFile && evidence.isExact)
        #expect(evidence.sessionFolder == project)
        #expect(evidence.startedAt == (try ownStart()))
    }

    @Test func aClaudeFileThatDoesNotMatchIsAGuess() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let start = try ownStart()
        func source() throws -> SessionSnapshot.IDSource? {
            capture(try process(["claude"]), typed: "claude", home: home)?.source
        }
        // Another start time: another process that had this pid.
        try claudeFile(home: home, fields: claudeFields(start: start.addingTimeInterval(-3600), cwd: project))
        #expect(try source() == .guess)
        // Another pid in the file.
        var fields = claudeFields(start: start, cwd: project)
        fields["pid"] = Int(getpid()) + 1
        try claudeFile(home: home, fields: fields)
        #expect(try source() == .guess)
        // A key missing.
        for key in ["sessionId", "cwd", "procStart"] {
            var fields = claudeFields(start: start, cwd: project)
            fields[key] = nil
            try claudeFile(home: home, fields: fields)
            #expect(try source() == .guess, "\(key)")
            #expect(throws: AgentEvidence.Problem.missing(key)) { try AgentSessions.claudeProcess(pid: getpid(), home: home).get() }
        }
        // A file outside the store, linked in.
        let path = home + "/.claude/sessions/\(getpid()).json"
        try FileManager.default.removeItem(atPath: path)
        try write(json(claudeFields(start: start, cwd: project)), to: project + "/planted.json")
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: project + "/planted.json")
        #expect(try source() == .guess)
        // A hard link to a file elsewhere is not the store's own.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.linkItem(atPath: project + "/planted.json", toPath: path)
        #expect(try source() == .guess)
        // Not JSON.
        try FileManager.default.removeItem(atPath: path)
        try write("not json", to: path)
        #expect(throws: AgentEvidence.Problem.notJSON) { try AgentSessions.claudeProcess(pid: getpid(), home: home).get() }
    }

    @Test func aProcessThatIsNotTheTabsGivesNothingExact() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try claudeFile(home: home, fields: claudeFields(start: try ownStart(), cwd: project))
        let leader = try process(["claude", "--resume", uuid])
        let evidence = AgentEvidence.capture(AgentEvidence.Capture(leader: leader, verified: false, typedLine: "claude --resume \(uuid)",
                                                                   home: home))
        #expect(evidence?.agent == .claude && evidence?.source == .guess && evidence?.sessionID == uuid)
        #expect(evidence?.executable == nil && evidence?.startedAt == nil)
    }

    // MARK: Codex

    func rollout(_ home: String, id: String, day: String = "2026/10/07") -> String {
        home + "/.codex/sessions/\(day)/rollout-2026-10-07T10-00-00-\(id).jsonl"
    }

    @Test func rolloutNames() {
        #expect(AgentEvidence.rolloutID(fileName: "rollout-2026-10-07T10-00-00-\(uuid).jsonl") == uuid)
        for name in ["rollout-\(uuid).json", "session-\(uuid).jsonl", "rollout-2026-10-07T10-00-00-\(uuid)x.jsonl",
                     "rollout-2026-10-07T10-00-00-abc.jsonl", "rollout.jsonl"] {
            #expect(AgentEvidence.rolloutID(fileName: name) == nil, "\(name)")
        }
    }

    @Test func oneOpenRolloutIsExact() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let meta: [String: Any] = ["timestamp": "2026-10-07T10:00:00.000Z", "type": "session_meta",
                                   "payload": ["id": uuid, "cwd": project, "instructions": String(repeating: "x", count: 70_000)]]
        try write(json(meta) + "\n" + json(["type": "event_msg"]) + "\n", to: rollout(home, id: uuid))
        let leader = try process(["codex"], executable: "/opt/homebrew/bin/codex", directory: home,
                                 openFiles: [home + "/.codex/log/codex-tui.log", rollout(home, id: uuid)])
        let evidence = try #require(capture(leader, typed: "codex", home: home))
        #expect(evidence.agent == .codex && evidence.sessionID == uuid && evidence.source == .openRollout)
        #expect(evidence.sessionFolder == project)
        // A rollout whose first line names another session.
        try write(json(["type": "session_meta", "payload": ["id": other, "cwd": project]]) + "\n", to: rollout(home, id: uuid))
        #expect(capture(leader, typed: "codex", home: home)?.source == .guess)
        // A first line that does not read leaves the name, and the process's own folder.
        try write("{", to: rollout(home, id: uuid))
        let unread = capture(leader, typed: "codex", home: home)
        #expect(unread?.source == .openRollout && unread?.sessionFolder == home)
    }

    @Test func twoOpenRolloutsAreAGuessAndOtherNamesNothing() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for id in [uuid, other] { try write(json(["type": "session_meta", "payload": ["id": id, "cwd": project]]), to: rollout(home, id: id)) }
        let two = try process(["codex"], executable: "/opt/homebrew/bin/codex", openFiles: [rollout(home, id: uuid), rollout(home, id: other)])
        let guessed = capture(two, typed: "codex", home: home)
        #expect(guessed?.source == .guess && guessed?.sessionID == nil)
        // One held by a relaunched codex beside the leader counts as a second.
        let leader = try process(["node", "/opt/lib/node_modules/@openai/codex/bin/codex.js"], executable: "/opt/homebrew/bin/node",
                                 openFiles: [rollout(home, id: uuid)])
        let child = try process(["codex"], executable: "/opt/lib/node_modules/@openai/codex/vendor/codex", openFiles: [rollout(home, id: other)])
        let both = AgentEvidence.capture(AgentEvidence.Capture(leader: leader, relaunched: [child], verified: true, home: home))
        #expect(both?.agent == .codex && both?.source == .guess)
        let one = AgentEvidence.capture(AgentEvidence.Capture(leader: leader, relaunched: [try process(["codex"])], verified: true, home: home))
        #expect(one?.source == .openRollout && one?.sessionID == uuid)
        // Other names, and a rollout outside the store.
        try write("{}", to: project + "/rollout-2026-10-07T10-00-00-\(uuid).jsonl")
        let elsewhere = try process(["codex"], executable: "/opt/homebrew/bin/codex",
                                    openFiles: [home + "/.codex/history.jsonl", project + "/rollout-2026-10-07T10-00-00-\(uuid).jsonl"])
        let none = capture(elsewhere, typed: "codex", home: home)
        #expect(none?.source == .guess && none?.sessionID == nil)
    }

    // MARK: Qwen Code

    @Test func aQwenRuntimeFileWithThisPidIsExact() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let chats = home + "/.qwen/projects/" + QwenSessions.folderName(project) + "/chats/"
        try write(json(["pid": Int(getpid()), "session_id": uuid, "work_dir": project]), to: chats + uuid + ".runtime.json")
        let leader = try process(["node", "/opt/lib/node_modules/@qwen-code/qwen-code/cli.js"], executable: "/opt/homebrew/bin/node",
                                 directory: project)
        let evidence = try #require(capture(leader, typed: "qwen", home: home))
        #expect(evidence.agent == .qwen && evidence.sessionID == uuid && evidence.source == .runtimeFile && evidence.sessionFolder == project)
        // Another process's file, or one named for another session, is not.
        try write(json(["pid": Int(getpid()) + 1, "session_id": uuid, "work_dir": project]), to: chats + uuid + ".runtime.json")
        #expect(capture(leader, typed: "qwen", home: home)?.source == .guess)
        try write(json(["pid": Int(getpid()), "session_id": other, "work_dir": project]), to: chats + uuid + ".runtime.json")
        #expect(capture(leader, typed: "qwen", home: home)?.source == .guess)
        #expect(throws: AgentEvidence.Problem.missing("work_dir")) {
            try AgentEvidence.qwenRuntime(Data(json(["pid": 1, "session_id": uuid]).utf8)).get()
        }
    }

    // MARK: the typed line and argv

    @Test func anIDFromArgvAloneOrAMismatchIsAGuess() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gemini = try process(["gemini", "--resume", uuid], executable: "/opt/homebrew/bin/gemini")
        let agreed = capture(gemini, typed: "gemini --resume \(uuid)", home: home)
        #expect(agreed?.agent == .gemini && agreed?.sessionID == uuid && agreed?.source == .typedAndArgv)
        let argvOnly = capture(gemini, typed: "gemini", home: home)
        #expect(argvOnly?.sessionID == uuid && argvOnly?.source == .guess)
        let notTyped = capture(gemini, home: home)
        #expect(notTyped?.sessionID == uuid && notTyped?.source == .guess)
        let mismatch = capture(gemini, typed: "gemini --resume \(other)", home: home)
        #expect(mismatch?.sessionID == uuid && mismatch?.source == .guess)
        let typedOnly = capture(try process(["gemini"], executable: "/opt/homebrew/bin/gemini"), typed: "gemini --resume \(other)", home: home)
        #expect(typedOnly?.sessionID == other && typedOnly?.source == .guess)
        // An id the agent's pattern refuses is no id at all.
        let bad = capture(try process(["gemini", "--resume", "x;y"], executable: "/opt/homebrew/bin/gemini"), typed: "gemini --resume 'x;y'",
                          home: home)
        #expect(bad?.sessionID == nil && bad?.source == .guess)
    }

    @Test func forTheAutomaticAgentsTheTypedLineAloneDoesNotResume() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lines: [(RestoreAgent, [String], String)] = [
            (.claude, ["claude", "--resume", uuid], "claude --resume \(uuid)"),
            (.codex, ["codex", "resume", uuid], "codex resume \(uuid)"),
            (.qwen, ["qwen", "--resume", uuid], "qwen --resume \(uuid)"),
        ]
        for (agent, argv, typed) in lines {
            let evidence = try #require(capture(try process(argv, executable: "/opt/homebrew/bin/" + argv[0], directory: home),
                                                typed: typed, home: home, shell: [:]))
            #expect(evidence.agent == agent && evidence.source == .typedAndArgv && evidence.isExact)
            let facts = ResumeFacts(user: geteuid(), sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
            guard case .onTheLine(let failed) = evidence.gate(facts) else {
                Issue.record("\(agent) resumed on the typed line alone")
                continue
            }
            #expect(failed.contains(.sessionFile))
            #expect(agent.putBackLine(id: evidence.sessionID, folder: evidence.sessionFolder)?.contains(uuid) == true)
        }
    }

    @Test func copilotsChildEnvironmentIsAGuess() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let copilot = try process(["copilot", "--resume=\(uuid)"], executable: "/opt/homebrew/bin/copilot")
        let typed = "copilot --resume=\(uuid)"
        let agreed = try #require(capture(copilot, typed: typed, home: home, children: [uuid]))
        #expect(agreed.source == .typedAndArgv)
        let differs = try #require(capture(copilot, typed: typed, home: home, children: [other]))
        #expect(differs.source == .guess && differs.sessionID == uuid && !differs.isExact)
        guard case .onTheLine = differs.gate(ResumeFacts(sessionAvailable: true, projectConfigChanged: false,
                                                         settingsAutoContinue: false)) else {
            Issue.record("Copilot resumed")
            return
        }
        let plain = try #require(capture(try process(["copilot"], executable: "/opt/homebrew/bin/copilot"), typed: "copilot", home: home,
                                         children: [other, other]))
        #expect(plain.source == .childEnvironment && plain.sessionID == other && !plain.isExact)
        let two = capture(try process(["copilot"], executable: "/opt/homebrew/bin/copilot"), typed: "copilot", home: home, children: [uuid, other])
        #expect(two?.sessionID == nil && two?.source == .guess)
    }

    // MARK: the facts beside the id

    @Test func optionsAreRecordedFromArgv() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let argv = ["claude", "--dangerously-skip-permissions", "--model", "opus", "fix the login bug"]
        let evidence = try #require(capture(try process(argv), typed: argv.map(ShellQuote.quote).joined(separator: " "), home: home))
        #expect(evidence.flags == ["--model", "opus"] && evidence.leftOff == ["--dangerously-skip-permissions"] && !evidence.flagsAllowed)
        let plain = try #require(capture(try process(["claude", "--model", "opus"]), typed: "claude --model opus", home: home))
        #expect(plain.flags == ["--model", "opus"] && plain.leftOff.isEmpty && plain.flagsAllowed)
    }

    @Test func anEnvPrefixOrAnAliasDidNotRunAsTyped() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let claude = try process(["claude"])
        func ran(_ typed: String?, expanded: String? = nil) -> Bool {
            AgentEvidence.capture(AgentEvidence.Capture(leader: claude, verified: true, typedLine: typed, expandedLine: expanded,
                                                        home: home))?.ranAsTyped ?? false
        }
        #expect(ran("claude"))
        #expect(ran("cd ~/app && claude"))
        #expect(!ran("CLAUDE_CONFIG_DIR=/Users/x/other claude"))
        #expect(!ran("env ANTHROPIC_BASE_URL=https://example.com claude"))
        #expect(!ran("sudo claude"))
        #expect(!ran("cl", expanded: "claude --dangerously-skip-permissions"))
        #expect(ran("claude", expanded: "claude"))
        #expect(!ran("make"))
        #expect(!ran(nil))
        // Another config folder given on the line: on the line, whatever its session file says.
        let (project, start) = (home + "/Code/app", try ownStart())
        try write(json(["pid": Int(getpid()), "sessionId": uuid, "cwd": project, "procStart": AgentEvidence.procStartText(start)]),
                  to: home + "/other/sessions/\(getpid()).json")
        let moved = try process(["claude"], environment: ["CLAUDE_CONFIG_DIR": home + "/other"])
        let evidence = try #require(capture(moved, typed: "CLAUDE_CONFIG_DIR=\(home)/other claude", home: home))
        #expect(evidence.source == .sessionFile && !evidence.ranAsTyped && !evidence.routingMatchesShell)
        let facts = ResumeFacts(sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
        guard case .onTheLine(let failed) = evidence.gate(facts) else {
            Issue.record("resumed with another config folder")
            return
        }
        #expect(failed.contains(.typedLine) && failed.contains(.routing))
    }

    @Test func routingIsComparedWithTheShellAndAutoContinueIsSeen() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        func evidence(_ environment: [String: String], shell: [String: String]) throws -> Evidence {
            try #require(capture(try process(["claude"], environment: environment), typed: "claude", home: home, shell: shell))
        }
        let same = try evidence(["ANTHROPIC_BASE_URL": "https://a.example.com", "PATH": "/usr/bin"],
                                shell: ["ANTHROPIC_BASE_URL": "https://a.example.com", "PATH": "/bin"])
        #expect(same.routingMatchesShell && same.autoContinueOff)
        #expect(!(try evidence(["ANTHROPIC_BASE_URL": "https://b.example.com"], shell: ["ANTHROPIC_BASE_URL": "https://a.example.com"]))
            .routingMatchesShell)
        #expect(!(try evidence(["CLAUDE_CONFIG_DIR": "/Users/x/other"], shell: [:])).routingMatchesShell)
        #expect(!(try evidence([:], shell: ["AWS_PROFILE": "prod"])).routingMatchesShell)
        let continues = try evidence(["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"], shell: [:])
        #expect(!continues.autoContinueOff && continues.routingMatchesShell)
        var gated = continues
        gated.flagsAllowed = true
        let facts = ResumeFacts(sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
        guard case .onTheLine(let failed) = gated.gate(facts) else {
            Issue.record("resumed with auto-continue set")
            return
        }
        #expect(failed.contains(.autoContinue))
        #expect(AgentEvidence.environmentKeys.isSuperset(of: RestoreAgent.claude.routingVariables + RestoreAgent.claude.autoContinueVariables))
        #expect(!AgentEvidence.environmentKeys.contains("GITHUB_TOKEN"))
    }

    @Test func autoContinueInClaudeSettingsIsSeen() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let managed = home + "/managed-settings.json"
        func sets() -> Bool { AgentEvidence.claudeSettingsAutoContinue(home: home, folder: project, managed: managed) }
        #expect(!sets())
        try write(json(["env": ["ANTHROPIC_MODEL": "opus"], "model": "opus"]), to: home + "/.claude/settings.json")
        #expect(!sets())
        try write(json(["env": ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"]]), to: home + "/.claude/settings.json")
        #expect(sets())
        try FileManager.default.removeItem(atPath: home + "/.claude/settings.json")
        try write(json(["env": ["CLAUDE_CODE_RESUME_PROMPT": "go on"]]), to: home + "/Code/.claude/settings.local.json")
        #expect(sets())
        try FileManager.default.removeItem(atPath: home + "/Code/.claude/settings.local.json")
        try write(json(["env": ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"]]), to: managed)
        #expect(sets())
        try write("{ not json", to: managed)
        #expect(sets())
    }

    @Test func projectConfigTouchedAfterTheStartIsSeen() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: project + "/web", withIntermediateDirectories: true)
        let now = Date()
        #expect(!AgentEvidence.projectConfigChanged(agent: .claude, folder: project + "/web", since: now.addingTimeInterval(-60)))
        try write("{}", to: project + "/.claude/settings.json")
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: project + "/web", since: now.addingTimeInterval(-60)))
        #expect(!AgentEvidence.projectConfigChanged(agent: .claude, folder: project + "/web", since: now.addingTimeInterval(60)))
        // Its modification time set back does not hide the change.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: project + "/.claude/settings.json")
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: project + "/web", since: now.addingTimeInterval(-60)))
        try write("{}", to: project + "/web/.mcp.json")
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: project + "/web", since: now.addingTimeInterval(-60)))
        #expect(!AgentEvidence.projectConfigChanged(agent: .codex, folder: project + "/web", since: now.addingTimeInterval(-60)))
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: nil))
        let facts = ResumeFacts.read(for: Evidence(agent: .claude, sessionFolder: project + "/web", startedAt: now.addingTimeInterval(-60)),
                                     projects: [project], tabFolder: project, sessionAvailable: true, home: home)
        #expect(facts.projectConfigChanged && !facts.settingsAutoContinue && facts.outside.contains(project))
    }

    // MARK: paths

    @Test func theInvokedPathIsRecordedWhenItLeadsToWhatRan() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.local/share/claude/versions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        let binary = home + "/.local/share/claude/versions/2.1.280"
        fm.createFile(atPath: binary, contents: Data(), attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: binary)
        let path = "/usr/bin:" + home + "/.local/bin"
        let invoked = try process(["claude"], executable: binary, directory: project, environment: ["PATH": path])
        #expect(capture(invoked, typed: "claude", home: home)?.executable == home + "/.local/bin/claude")
        // A name on the PATH that is some other file: what ran is recorded.
        fm.createFile(atPath: home + "/.local/bin/other", contents: Data(), attributes: [.posixPermissions: 0o755])
        let renamed = try process(["other"], executable: binary, directory: project, environment: ["PATH": path])
        #expect(capture(renamed, typed: "other", home: home)?.executable == binary)
        // A path given in argv[0].
        let direct = try process([home + "/.local/bin/claude"], executable: binary, directory: project)
        #expect(capture(direct, home: home)?.executable == home + "/.local/bin/claude")
        #expect(AgentEvidence.invokedPath("claude", searchPath: "relative:" + home + "/.local/bin", directory: project)
                == home + "/.local/bin/claude")
        #expect(AgentEvidence.invokedPath("./bin/x", searchPath: nil, directory: "/Users/x/app") == "/Users/x/app/bin/x")
    }

    @Test func aScriptAgentRecordsItsInterpreterAndTheScriptsRealPath() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        let package = home + "/.npm-global/lib/node_modules/@anthropic-ai/claude-code"
        try fm.createDirectory(atPath: package, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.npm-global/bin", withIntermediateDirectories: true)
        fm.createFile(atPath: package + "/cli.js", contents: Data("#!/usr/bin/env node\n".utf8), attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: home + "/.npm-global/bin/claude", withDestinationPath: package + "/cli.js")
        let leader = try process(["node", home + "/.npm-global/bin/claude", "--model", "opus"], executable: "/opt/homebrew/Cellar/node/24/bin/node",
                                 directory: project)
        let evidence = try #require(capture(leader, typed: "claude --model opus", home: home))
        #expect(evidence.agent == .claude)
        #expect(evidence.interpreter == "/opt/homebrew/Cellar/node/24/bin/node" && evidence.executable == evidence.interpreter)
        #expect(evidence.script == package + "/cli.js")
        #expect(evidence.flags == ["--model", "opus"] && evidence.flagsAllowed && evidence.ranAsTyped)
    }

    // MARK: the record

    @Test func theNewFactsSaveAndReadBack() throws {
        var evidence = Evidence(agent: .opencode, sessionID: "ses_6a3f2b9c1d", source: .typedAndArgv, sessionFolder: "/Users/x/app")
        evidence.flags = ["--model", "opus"]
        evidence.leftOff = ["--yolo", "--settings"]
        evidence.flagsAllowed = true
        var pane = SessionSnapshot.Pane(id: UUID())
        pane.agent = evidence
        let group = SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        let snapshot = SessionSnapshot(header: .init(launchID: UUID(), generation: 1, clean: false, savedAt: Date(timeIntervalSince1970: 1)),
                                       windows: [.init(groups: [group])])
        let read = try SessionSnapshot.decode(try snapshot.encoded())
        #expect(read.panes.first?.agent == evidence)
        // What a file cannot hold: a flag word or a name outside its pattern drops the list and the fact with it.
        var odd = evidence
        odd.flags = ["--model", "a b"]
        odd.leftOff = ["--yolo", "-\u{202E}x"]
        pane.agent = odd
        let mended = SessionSnapshot(header: snapshot.header, windows: [.init(groups: [.init(root: .pane(pane), focused: pane.id)])])
        let back = try SessionSnapshot.decode(try mended.encoded()).panes.first?.agent
        #expect(back?.flags == [] && back?.leftOff == [] && back?.flagsAllowed == false)
        #expect(back?.sessionID == "ses_6a3f2b9c1d")
    }
}
