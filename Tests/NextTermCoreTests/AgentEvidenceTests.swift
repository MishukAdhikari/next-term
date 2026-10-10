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

    /// This process, described as an agent run with `arguments` in `directory`. `routing` holds values, digested here
    /// as capture reads them.
    func process(_ arguments: [String], executable: String = "/Users/x/.local/share/claude/versions/2.1.280",
                 directory: String? = nil, environment: [String: String] = [:], openFiles: [String] = [],
                 routing: [String: String] = [:]) throws -> AgentProcess {
        AgentProcess(pid: getpid(), startedAt: try ownStart(), executable: executable, arguments: arguments, environment: environment,
                     directory: directory, openFiles: openFiles, routing: routing.mapValues(AgentEvidence.routingDigest))
    }

    /// `shell`: the login shell's routing variables, as values (digested here); nil when the login shell is not known.
    func capture(_ leader: AgentProcess?, typed: String? = nil, home: String, children: [String] = [],
                 shell: [String: String]? = nil) -> Evidence? {
        let routing = shell?.mapValues(AgentEvidence.routingDigest)
        let input = AgentEvidence.Capture(leader: leader, verified: true, childSessionIDs: children, typedLine: typed,
                                          shellRouting: routing, home: home)
        return AgentEvidence.capture(input)
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
        let argv: [String] = ["node", "/opt/lib/cli.js", "--resume"]
        #expect(parsed.arguments == argv)
        #expect(parsed.environment == ["PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": "https://example.com"])
        let many = procArgs(argc: 20, ["/bin/x"] + (0..<20).map { "a\($0)" })
        #expect(try #require(ProcessArguments.parse(many, keeping: [])).arguments.count == 20)
    }

    /// KTD5: routing values are compared as digests made in memory. The record keeps a digest of each, never the value.
    @Test func procArgsDigestRoutingVariablesAndKeepNoValue() throws {
        let bytes = procArgs(argc: 1, ["/opt/homebrew/bin/codex", "codex", "PATH=/usr/bin", "OPENAI_API_KEY=sk-proj-abcdef123456", "",
                                       "executable_path=/opt/homebrew/bin/codex"])
        let parsed = try #require(ProcessArguments.parse(bytes, keeping: ["PATH"], digesting: ["OPENAI_API_KEY", "PATH"]))
        #expect(parsed.environment == ["PATH": "/usr/bin"])
        let digests = ["OPENAI_API_KEY": AgentEvidence.routingDigest("sk-proj-abcdef123456"), "PATH": AgentEvidence.routingDigest("/usr/bin")]
        #expect(parsed.routing == digests)
        #expect(!String(describing: parsed).contains("sk-proj"))
        #expect(AgentEvidence.routingDigest("a") == AgentEvidence.routingDigest("a"))
        #expect(AgentEvidence.routingDigest("a") != AgentEvidence.routingDigest("b") && AgentEvidence.routingDigest("a") != "a")
    }

    /// The login shell's environment as `/usr/bin/env` lists it: only the routing variables, each as a digest.
    @Test func theLoginShellsRoutingIsReadAsDigests() {
        let listing = "PATH=/usr/bin:/bin\nOPENAI_API_KEY=sk-proj-abc\nHOME=/Users/x\nANTHROPIC_BASE_URL=https://a.example.com\n"
            + "GITHUB_TOKEN=ghp_abc\nnot a variable\n=x\n"
        let digests = AgentEvidence.routingDigests(environmentListing: listing)
        let expected = ["OPENAI_API_KEY": AgentEvidence.routingDigest("sk-proj-abc"),
                        "ANTHROPIC_BASE_URL": AgentEvidence.routingDigest("https://a.example.com")]
        #expect(digests == expected)
        #expect(AgentEvidence.routingDigests(environmentListing: "").isEmpty)
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
        let date = try #require(AgentEvidence.procStart("Thu Oct  1 09:30:15 2026"))
        #expect(date == Date(timeIntervalSince1970: 1_790_847_015))
        #expect(AgentEvidence.procStartText(date) == "Thu Oct  1 09:30:15 2026")
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

    /// KTD4: the file's real path lies in the agent's own store. A sessions folder linked out of the store, into the
    /// workspace, is not the store's, and neither is a store a link leads into the workspace (the gate checks that one).
    @Test func aClaudeFileReachedThroughALinkedFolderIsAGuess() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/planted", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.claude/sessions", withDestinationPath: project + "/planted")
        try write(json(claudeFields(start: try ownStart(), cwd: project)), to: project + "/planted/\(getpid()).json")
        let linked = capture(try process(["claude"], directory: project), typed: "claude", home: home)
        #expect(linked?.source == .guess && linked?.sessionID == nil)
        #expect(throws: AgentEvidence.Problem.unreadable) { try AgentSessions.claudeProcess(pid: getpid(), home: home).get() }
        // The store itself as a link: the file is read in the store's real place, which capture records.
        try fm.removeItem(atPath: home + "/.claude")
        try fm.createDirectory(atPath: home + "/dotfiles/claude/sessions", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.claude", withDestinationPath: home + "/dotfiles/claude")
        try write(json(claudeFields(start: try ownStart(), cwd: project)), to: home + "/dotfiles/claude/sessions/\(getpid()).json")
        let moved = capture(try process(["claude"], directory: project), typed: "claude", home: home)
        #expect(moved?.source == .sessionFile && moved?.store == home + "/dotfiles/claude")
    }

    /// CLAUDE_CONFIG_DIR moves the store: the file is read there, and capture records where it is.
    @Test func aMovedClaudeStoreIsRecorded() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(json(claudeFields(start: try ownStart(), cwd: project)), to: home + "/work/sessions/\(getpid()).json")
        let moved = try process(["claude"], directory: project, environment: ["CLAUDE_CONFIG_DIR": home + "/work"])
        let evidence = try #require(capture(moved, typed: "claude", home: home))
        #expect(evidence.source == .sessionFile && evidence.store == home + "/work")
        let plain = try #require(capture(try process(["claude"], directory: project), typed: "claude", home: home))
        #expect(plain.store == home + "/.claude" && plain.source == .guess)
        // Only an automatic agent's store is recorded.
        let gemini = capture(try process(["gemini"], executable: "/opt/homebrew/bin/gemini"), typed: "gemini", home: home)
        #expect(gemini?.agent == .gemini && gemini?.store == nil)
    }

    /// Claude Code does not run itself again in a child: a `claude` below the tab's (one its Bash tool started) never
    /// names the tab's session, nor makes the tab's own a guess.
    @Test func aClaudeBelowTheLeaderIsNotTheTabs() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let start = try ownStart()
        var fields = claudeFields(start: start, cwd: project + "/elsewhere")
        fields["pid"] = Int(getppid())
        fields["sessionId"] = other
        try claudeFile(home: home, pid: getppid(), fields: fields)
        let leader = try process(["claude"], directory: project)
        let child = AgentProcess(pid: getppid(), startedAt: start, executable: "/Users/x/.local/share/claude/versions/2.1.280",
                                 arguments: ["claude", "-p", "hi"], directory: project + "/elsewhere")
        func evidence() -> Evidence? {
            AgentEvidence.capture(AgentEvidence.Capture(leader: leader, relaunched: [child], verified: true, typedLine: "claude", home: home))
        }
        #expect(evidence()?.sessionID == nil && evidence()?.source == .guess)
        try claudeFile(home: home, fields: claudeFields(start: start, cwd: project))
        let own = try #require(evidence())
        #expect(own.sessionID == uuid && own.source == .sessionFile && own.sessionFolder == project)
        // Only Codex's npm build and Qwen Code run themselves again in a child.
        let relaunching: [RestoreAgent] = RestoreAgent.allCases.filter(\.relaunchesItself)
        #expect(relaunching == [.codex, .qwen])
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

    /// KTD4: a rollout counts only by its real path in Codex's store. A sessions folder linked into the workspace
    /// leads out of it, so what is open there names nothing; the store is recorded by its real path.
    @Test func aRolloutReachedThroughALinkedFolderIsAGuess() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        let planted = project + "/planted/2026/10/07/rollout-2026-10-07T10-00-00-\(uuid).jsonl"
        try write(json(["type": "session_meta", "payload": ["id": uuid, "cwd": project]]), to: planted)
        try fm.createSymbolicLink(atPath: home + "/.codex/sessions", withDestinationPath: project + "/planted")
        // The kernel names an open file by its real path.
        let leader = try process(["codex"], executable: "/opt/homebrew/bin/codex", directory: project, openFiles: [planted])
        let linked = try #require(capture(leader, typed: "codex", home: home))
        #expect(linked.source == .guess && linked.sessionID == nil && linked.store == home + "/.codex")
        // CODEX_HOME moves the store, and the rollout open in it is exact.
        try write(json(["type": "session_meta", "payload": ["id": uuid, "cwd": project]]), to: rollout(home + "/moved", id: uuid))
        let moved = try process(["codex"], executable: "/opt/homebrew/bin/codex", directory: project,
                                environment: ["CODEX_HOME": home + "/moved/.codex"], openFiles: [rollout(home + "/moved", id: uuid)])
        let exact = try #require(capture(moved, typed: "codex", home: home))
        #expect(exact.source == .openRollout && exact.sessionID == uuid && exact.store == home + "/moved/.codex")
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
        #expect(evidence.store == home + "/.qwen")
        // The chats folder linked out of the store, into the workspace: the file there is not the store's.
        let fm = FileManager.default
        try fm.moveItem(atPath: chats, toPath: project + "/chats")
        try fm.createSymbolicLink(atPath: String(chats.dropLast()), withDestinationPath: project + "/chats")
        #expect(capture(leader, typed: "qwen", home: home)?.source == .guess)
        try fm.removeItem(atPath: String(chats.dropLast()))
        try fm.moveItem(atPath: project + "/chats", toPath: chats)
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

    // MARK: which agent

    /// An agent the classifier knows that the matrix does not is still an agent: its tab gets a note, never its
    /// line with the prompt put back as a command's (R6, R8).
    @Test func agentsOutsideTheMatrixAreUnknownAgents() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        for program in ["droid", "kimi", "crush", "cline", "auggie", "plandex", "q"] {
            let typed = program + " 'delete the tests'"
            let leader = try process([program, "delete the tests"], executable: "/opt/homebrew/bin/" + program)
            for evidence in [capture(leader, typed: typed, home: home), capture(nil, typed: typed, home: home)] {
                let found = try #require(evidence, "\(program)")
                #expect(found.agent == .unknown && found.sessionID == nil, "\(program)")
                #expect(found.gate(ResumeFacts()) == .note, "\(program)")
            }
            #expect(capture(leader, home: home)?.agent == .unknown, "\(program)")
        }
    }

    /// A folder named like an agent does not make what runs in it that agent: the command stays a command (R9).
    /// An agent's own script, by its name or its package, still names it.
    @Test func aFolderNamedLikeAnAgentNamesNoAgent() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        let commands: [[String]] = [
            ["node", "/Users/x/Code/codex/server.js"],
            ["node", "/Users/x/Code/opencode-site/dev.js"],
            ["python3", "/Users/x/Code/aider-notes/run.py"],
            ["node", "/Users/x/Code/claude-code/scripts/build.js"],
            ["node", "/Users/x/Code/codex/node_modules/.bin/vite"],
        ]
        for argv in commands {
            let line = argv.joined(separator: " ")
            #expect(CommandClassifier.programName(line) == argv[0], "\(line)")
            let leader = try process(argv, executable: "/opt/homebrew/bin/" + argv[0])
            #expect(RestoreAgent(process: leader) == nil, "\(line)")
            #expect(capture(leader, typed: line, home: home) == nil, "\(line)")
        }
        let agents: [([String], RestoreAgent)] = [
            (["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], .claude),
            (["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"], .codex),
            (["node", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"], .opencode),
            (["node", "/Users/x/.npm-global/lib/node_modules/@qwen-code/qwen-code/cli.js"], .qwen),
            (["python3", "/Users/x/.local/bin/aider"], .aider),
            (["python3", "-m", "aider"], .aider),
        ]
        for (argv, agent) in agents {
            let line = argv.joined(separator: " ")
            #expect(RestoreAgent(line: line) == agent, "\(line)")
            #expect(RestoreAgent(process: try process(argv, executable: "/opt/homebrew/bin/" + argv[0])) == agent, "\(line)")
            #expect(capture(nil, typed: line, home: home)?.agent == agent, "\(line)")
        }
        // A tab's program is named the same way: the agent's own package names it, a project folder does not.
        #expect(CommandClassifier.programName("node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js") == "codex")
        #expect(CommandClassifier.programName("node /Users/x/Code/opencode/node_modules/vite/bin/vite.js") == "node")
    }

    /// The tab's own agent, found the strict way, in a line that also runs other commands; a line running none is nil.
    @Test func aTypedLineNamesItsAgentStrictly() {
        #expect(RestoreAgent(line: "cd ~/Code/codex && claude --model opus") == .claude)
        #expect(RestoreAgent(line: "npx @anthropic-ai/claude-code") == .claude)
        #expect(RestoreAgent(line: "env -u CLAUDE_CODE_RESUME_PROMPT codex resume x") == .codex)
        #expect(RestoreAgent(line: "droid exec 'fix it'") == .unknown)
        for line in ["cd ~/Code/codex && npm run dev", "node ~/Code/aider/run.js", "make", ""] {
            #expect(RestoreAgent(line: line) == nil, "\(line)")
        }
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

    /// KTD5: the agent's routing variables are compared with the login shell's, the environment a restored tab starts
    /// with. A key .zshrc exports reaches both, so it matches; one set only in the tab, or only in the login shell,
    /// does not; a login shell not read yet matches nothing.
    @Test func routingIsComparedWithTheLoginShellAndAutoContinueIsSeen() throws {
        let home = try makeHome().home
        defer { try? FileManager.default.removeItem(atPath: home) }
        func evidence(_ routing: [String: String], environment: [String: String] = [:], shell: [String: String]?,
                      argv: [String] = ["claude"]) throws -> Evidence {
            let agent = try process(argv, environment: environment, routing: routing)
            return try #require(capture(agent, typed: argv.joined(separator: " "), home: home, shell: shell))
        }
        let exported = ["ANTHROPIC_API_KEY": "sk-ant-api03-abc", "AWS_PROFILE": "work"]
        let same = try evidence(exported, shell: exported.merging(["OPENAI_API_KEY": "sk-proj-x"]) { $1 })
        #expect(same.routingMatchesShell && same.autoContinueOff)
        let codexKey = ["OPENAI_API_KEY": "sk-proj-x"]
        #expect(try evidence(codexKey, shell: codexKey, argv: ["codex"]).routingMatchesShell)
        #expect(!(try evidence(codexKey, shell: ["OPENAI_API_KEY": "sk-proj-y"], argv: ["codex"])).routingMatchesShell)
        let other = ["ANTHROPIC_BASE_URL": "https://b.example.com"]
        #expect(!(try evidence(other, shell: ["ANTHROPIC_BASE_URL": "https://a.example.com"])).routingMatchesShell)
        #expect(!(try evidence(["CLAUDE_CONFIG_DIR": "/Users/x/other"], shell: [:])).routingMatchesShell)
        #expect(!(try evidence([:], shell: ["AWS_PROFILE": "prod"])).routingMatchesShell)
        #expect(!(try evidence([:], shell: nil)).routingMatchesShell)
        #expect(try evidence([:], shell: [:]).routingMatchesShell)
        let continues = try evidence([:], environment: ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"], shell: [:])
        #expect(!continues.autoContinueOff && continues.routingMatchesShell)
        var gated = continues
        gated.flagsAllowed = true
        let facts = ResumeFacts(sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
        guard case .onTheLine(let failed) = gated.gate(facts) else {
            Issue.record("resumed with auto-continue set")
            return
        }
        #expect(failed.contains(.autoContinue))
        // Values are kept only for the search path, the stores and the auto-continue variables; routing ones only as digests.
        #expect(AgentEvidence.environmentKeys.isSuperset(of: RestoreAgent.claude.autoContinueVariables + ["PATH", "CLAUDE_CONFIG_DIR"]))
        #expect(AgentEvidence.routingKeys.isSuperset(of: RestoreAgent.allCases.flatMap(\.routingVariables)))
        for key in ["GITHUB_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
            #expect(!AgentEvidence.environmentKeys.contains(key), "\(key)")
        }
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

    /// R8: CLAUDE_CONFIG_DIR moves the user's settings with the store, and `env -u` cannot unset what they put back.
    @Test func autoContinueInAMovedStoresSettingsIsSeen() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let managed = home + "/managed-settings.json"
        let store = home + "/work/claude"
        func sets() -> Bool { AgentEvidence.claudeSettingsAutoContinue(home: home, store: store, folder: project, managed: managed) }
        #expect(!sets())
        try write(json(["env": ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"]]), to: store + "/settings.json")
        #expect(sets())
        try FileManager.default.removeItem(atPath: store + "/settings.json")
        try write(json(["env": ["CLAUDE_CODE_RESUME_PROMPT": "go on"]]), to: store + "/settings.local.json")
        #expect(sets())
        // The gate reads the store the evidence names: its settings, and where it is now.
        let evidence = Evidence(agent: .claude, sessionFolder: project, store: store, startedAt: Date())
        let facts = ResumeFacts.read(for: evidence, projects: [project], tabFolder: project, sessionAvailable: true, home: home)
        #expect(facts.settingsAutoContinue)
        #expect(facts.files[store]?.isDirectory == true && facts.files[store]?.realPath == store)
    }

    /// A settings file, or a folder on the way to one, that cannot be read counts as one that sets auto-continue
    /// and as a changed config: a mode set back after the check would otherwise hide what it holds.
    @Test func configThatCannotBeReadCountsAgainstAResume() throws {
        let (home, project) = try makeHome()
        defer {
            chmod(project + "/.claude", 0o755)
            try? FileManager.default.removeItem(atPath: home)
        }
        let start = Date().addingTimeInterval(-60)
        try write(json(["env": ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1"]]), to: project + "/.claude/settings.json")
        func sets() -> Bool { AgentEvidence.claudeSettingsAutoContinue(home: home, folder: project, managed: home + "/managed.json") }
        func changed() -> Bool { AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: start, home: home) }
        #expect(sets() && changed())
        #expect(chmod(project + "/.claude", 0) == 0)
        #expect(sets())
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: Date().addingTimeInterval(60), home: home))
    }

    /// A config folder renamed or linked into place keeps its files' old times; the folder's own change shows it.
    @Test func aConfigFolderMovedOrLinkedIntoPlaceIsSeen() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try write(json(["hooks": [:]]), to: project + "/docs/old/.claude/settings.json")
        try write("{}", to: project + "/docs/old/.mcp.json")
        usleep(20_000)
        let start = Date()
        usleep(20_000)
        func changed() -> Bool { AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: start, home: home) }
        #expect(!changed())
        try fm.moveItem(atPath: project + "/docs/old/.claude", toPath: project + "/.claude")
        #expect(changed())
        try fm.moveItem(atPath: project + "/.claude", toPath: project + "/docs/old/.claude")
        try fm.createSymbolicLink(atPath: project + "/.claude", withDestinationPath: project + "/docs/old/.claude")
        #expect(changed())
        try fm.removeItem(atPath: project + "/.claude")
        try fm.moveItem(atPath: project + "/docs/old/.mcp.json", toPath: project + "/.mcp.json")
        #expect(changed())
    }

    /// A session run in the home folder reads the home folder's project config like any other's. Above a project,
    /// the home folder's is the user's own and is not counted.
    @Test func aSessionInTheHomeFolderChecksItsConfig() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let start = Date().addingTimeInterval(-60)
        try write("{}", to: home + "/.mcp.json")
        #expect(AgentEvidence.projectConfigChanged(agent: .claude, folder: home, since: start, home: home))
        #expect(!AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: start, home: home))
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

    // MARK: the code a project config starts

    /// A resume starts the config's hooks and MCP servers again. A script they name in the project, rewritten after
    /// the start, sends the agent to the line though the config's own dates are older.
    @Test func aScriptAHookOrServerStartsRewrittenAfterTheStartIsSeen() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server: [String: Any] = ["command": "node", "args": ["mcp/server.js"]]
        try write(json(["mcpServers": ["docs": server]]), to: project + "/.mcp.json")
        let hook = ["type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/start.sh --quiet"]
        try write(json(["hooks": ["SessionStart": [["hooks": [hook]]]]]), to: project + "/.claude/settings.json")
        let status = ["type": "command", "command": "~/bin/status.sh"]
        try write(json(["statusLine": status]), to: project + "/web/.claude/settings.json")
        try write("// one", to: project + "/mcp/server.js")
        try write("#!/bin/sh", to: project + "/.claude/hooks/start.sh", mode: 0o700)
        try write("#!/bin/sh", to: home + "/bin/status.sh", mode: 0o700)
        func changed(since start: Date, in folder: String? = nil, agent: RestoreAgent = .claude) -> Bool {
            AgentEvidence.projectCodeChanged(agent: agent, folder: folder ?? project, since: start, within: [project], home: home)
        }
        func startNow() -> Date {
            usleep(20_000)
            defer { usleep(20_000) }
            return Date()
        }
        var start = startNow()
        #expect(!changed(since: start) && !changed(since: start, in: project + "/web"))
        try write("// two", to: project + "/mcp/server.js")
        #expect(changed(since: start))
        // From a folder below, a relative word is also taken from the config's own folder.
        #expect(changed(since: start, in: project + "/web"))
        #expect(!AgentEvidence.projectConfigChanged(agent: .claude, folder: project, since: start, home: home))
        start = startNow()
        #expect(!changed(since: start))
        try write("#!/bin/sh\necho two", to: project + "/.claude/hooks/start.sh", mode: 0o700)
        #expect(changed(since: start))
        #expect(!changed(since: start, agent: .codex))
        #expect(changed(since: start.addingTimeInterval(-60)))
        start = startNow()
        // A script outside the projects and the tab's folder is not a tab's to rewrite.
        try write("#!/bin/sh\necho two", to: home + "/bin/status.sh", mode: 0o700)
        #expect(!changed(since: start, in: project + "/web"))
        // The facts read at restore count it, with the projects, the tab's folder and the temporary folders.
        let evidence = Evidence(agent: .claude, sessionFolder: project, startedAt: startNow())
        func read() -> ResumeFacts {
            ResumeFacts.read(for: evidence, projects: [project], tabFolder: project, sessionAvailable: true, home: home)
        }
        #expect(!read().projectConfigChanged)
        try write("// three", to: project + "/mcp/server.js")
        #expect(read().projectConfigChanged)
        #expect(AgentEvidence.projectCodeChanged(agent: .claude, folder: project, since: nil, within: [project], home: home))
    }

    /// What the check cannot follow counts as changed: a variable, a glob, a command substitution, a quote that does
    /// not end, a config that does not read, and a folder named in the project. An option, a package name, a web
    /// address and the project folder itself name no script.
    @Test func codeTheCheckCannotFollowCountsAsChanged() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write("// one", to: project + "/mcp/server.js")
        let later = Date().addingTimeInterval(60)
        func changed() -> Bool {
            AgentEvidence.projectCodeChanged(agent: .claude, folder: project, since: later, within: [project], home: home)
        }
        func server(_ server: [String: Any]) throws -> Bool {
            try write(json(["mcpServers": ["docs": server]]), to: project + "/.mcp.json")
            return changed()
        }
        #expect(try !server(["command": "npx", "args": ["-y", "@scope/server", "--root=.", "https://example.com/sse?key=1"]]))
        #expect(try !server(["command": "node", "args": ["mcp/server.js"], "env": ["TOKEN": "${TOKEN}"]]))
        #expect(try !server(["command": "$HOME/bin/server", "args": ["${CLAUDE_PROJECT_DIR}/mcp/server.js"]]))
        #expect(try server(["command": "node", "args": ["${SERVER}"]]))
        #expect(try server(["command": "node", "args": ["mcp/*.js"]]))
        #expect(try server(["command": "sh", "args": ["-c", "node `cat mcp/which`"]]))
        #expect(try server(["command": "node", "args": ["server.js"], "cwd": "mcp"]))
        #expect(try server(["command": "node", "args": ["--require=./mcp"]]))
        try write("{\"mcpServers\": ", to: project + "/.mcp.json")
        #expect(changed())
        try FileManager.default.removeItem(atPath: project + "/.mcp.json")
        #expect(!changed())
        func hook(_ command: String) throws -> Bool {
            let hook = ["type": "command", "command": command]
            try write(json(["hooks": ["Stop": [["hooks": [hook]]]]]), to: project + "/.claude/settings.local.json")
            return changed()
        }
        #expect(try !hook("[ -f mcp/server.js ] && node mcp/server.js >/dev/null 2>&1; echo done # all"))
        #expect(try hook("sh -c 'node mcp/server.js"))
        #expect(try hook("cd web && node server.js"))
        #expect(try hook("node mcp/{server,other}.js"))
        #expect(try hook("node ~other/server.js"))
    }

    /// Codex's and Qwen Code's configs name code too: Codex's MCP servers and notify program, Qwen Code's MCP servers,
    /// in a settings file that may hold comments.
    @Test func codexAndQwenConfigsAreReadForTheCodeTheyStart() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write("// one", to: project + "/mcp/server.js")
        try write("print(1)", to: project + "/notify.py")
        let toml = """
            model = "o3" # $ and * in a comment
            notify = ["python3", "notify.py"]

            [mcp_servers.docs]
            command = "node"
            args = [
              "mcp/server.js",
              "--port", "3000",
            ]

            [mcp_servers.docs.env]
            TOKEN = "${TOKEN}"

            [shell_environment_policy]
            exclude = ["AWS_*"]
            """
        try write(toml, to: project + "/.codex/config.toml")
        let qwen = """
            {
              // Qwen Code reads comments.
              "mcpServers": {"docs": {"command": "node", "args": ["mcp/server.js"], "env": {"TOKEN": "$TOKEN"}}}
            }
            """
        try write(qwen, to: project + "/.qwen/settings.json")
        func changed(_ agent: RestoreAgent, since start: Date) -> Bool {
            AgentEvidence.projectCodeChanged(agent: agent, folder: project, since: start, within: [project], home: home)
        }
        func startNow() -> Date {
            usleep(20_000)
            defer { usleep(20_000) }
            return Date()
        }
        var start = startNow()
        #expect(!changed(.codex, since: start) && !changed(.qwen, since: start))
        try write("// two", to: project + "/mcp/server.js")
        #expect(changed(.codex, since: start) && changed(.qwen, since: start))
        start = startNow()
        try write("print(2)", to: project + "/notify.py")
        #expect(changed(.codex, since: start) && !changed(.qwen, since: start))
        // A multi-line string that holds lines like a server's is only a string; a command in one is not read.
        let later = Date().addingTimeInterval(60)
        #expect(!changed(.codex, since: later))
        func codex(_ text: String) throws -> Bool {
            try write(text, to: project + "/.codex/config.toml")
            return changed(.codex, since: later)
        }
        #expect(try !codex(toml + "\ninstructions = \"\"\"\n[mcp_servers.other]\ncommand = \"mcp\"\n\"\"\"\n"))
        #expect(try codex("[mcp_servers.docs]\ncommand = \"\"\"node\"\"\"\n"))
        #expect(try codex("[mcp_servers.docs]\ncommand = = \"node\"\n"))
        #expect(try codex("[mcp_servers.docs]\ncommand = \"node\"\ncwd = \"mcp\"\n"))
        #expect(try codex("[mcp_servers]\ndocs = { command = \"node\" }\n"))
        #expect(try !codex("[mcp_servers.\"docs\"]\ncommand = \"node\"\nargs = ['mcp/server.js']\n"))
        #expect(try codex("notify = \"notify.py\"\n[mcp_servers.docs]\ncommand = \"node\"\nargs = [\"mcp/server.js\", 1]\n"))
        #expect(try codex("[hooks]\nstart = \"notify.py\"\n"))
        #expect(try codex("[mcp_servers.docs\n"))
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

    /// A link a folder on the PATH gained in the workspace (direnv's bin) is what capture finds first, and it leads to
    /// the very file that ran. The resume would run that link, which anything in the tab can point elsewhere: on the
    /// line. The same link in the user's own bin folder passes.
    @Test func aWorkspaceLinkOnThePathGoesOnTheLine() throws {
        let (home, project) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        let binary = home + "/.local/share/claude/versions/2.1.280"
        try fm.createDirectory(atPath: (binary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: binary, contents: Data(), attributes: [.posixPermissions: 0o755])
        try write(json(claudeFields(start: try ownStart(), cwd: project)), to: home + "/.claude/sessions/\(getpid()).json")
        for folder in [project + "/bin", home + "/.local/bin"] {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: folder + "/claude", withDestinationPath: binary)
            let leader = try process(["claude"], executable: binary, directory: project, environment: ["PATH": folder + ":/usr/bin"])
            var evidence = try #require(capture(leader, typed: "claude", home: home, shell: [:]))
            #expect(evidence.executable == folder + "/claude" && evidence.source == .sessionFile)
            evidence.flagsAllowed = true
            var facts = ResumeFacts.read(for: evidence, projects: [project], tabFolder: project, sessionAvailable: true, home: home)
            facts.temporaryFolders = [] // the test's home is in one
            facts.projectConfigChanged = false
            let verdict = evidence.gate(facts)
            if folder.hasPrefix(project) {
                #expect(verdict == .onTheLine([.location]), "\(verdict)")
            } else if case .onTheLine(let failed) = verdict {
                Issue.record("a link in the user's bin folder failed \(failed)")
            }
            try fm.removeItem(atPath: folder + "/claude")
        }
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
        // The store an automatic agent used is kept, so the restore checks and reads that one; one that is not a plain
        // absolute path is dropped.
        let stores: [(String, String?)] = [("/Users/x/work/claude", "/Users/x/work/claude"), ("work/claude", nil), ("/Users/x/a\u{202E}b", nil)]
        for (store, kept) in stores {
            pane.agent = Evidence(agent: .claude, sessionID: uuid, source: .sessionFile, store: store)
            let saved = SessionSnapshot(header: snapshot.header, windows: [.init(groups: [.init(root: .pane(pane), focused: pane.id)])])
            #expect(try SessionSnapshot.decode(try saved.encoded()).panes.first?.agent?.store == kept, "\(store)")
        }
    }
}
