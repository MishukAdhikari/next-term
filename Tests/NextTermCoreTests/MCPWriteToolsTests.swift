import Foundation
import Testing
@testable import NextTermCore

@Suite struct MCPToolCatalogueTests {
    /// The tools that only look, as the remote door's See options name them: tagged read, whatever their
    /// readOnly hint (check_host, host_sessions and host_changes run a script over ssh).
    let seeTools = ["list_tabs", "read_tab", "wait_for_tab", "list_projects", "read_file", "find_in_files", "git_status", "get_diff",
                    "get_editor_selection", "get_open_files", "list_hosts", "check_host", "host_sessions", "host_changes"]

    @Test func everyToolCarriesAScopeTag() {
        let untagged = MCPServer.tools.filter { $0.scope == nil }.map(\.name)
        #expect(untagged.isEmpty, "tag these read or write in MCPServer.scopeTags: \(untagged)")
        // No tag for a tool that is gone, and no tool listed twice.
        let names = Set(MCPServer.tools.map(\.name))
        #expect(Set(MCPServer.scopeTags.keys) == names)
        #expect(names.count == MCPServer.tools.count)
        for name in seeTools { #expect(MCPServer.tool(named: name)?.scope == .read, "\(name)") }
        // A tool that says it only reads is tagged read.
        for tool in MCPServer.tools where tool.readOnly { #expect(tool.scope == .read, "\(tool.name)") }
        for name in ["send_to_tab", "press_keys", "answer_agent", "new_tab", "close_tab", "install_skill", "remove_skill", "open_project"] {
            #expect(MCPServer.tool(named: name)?.scope == .write, "\(name)")
        }
        for tool in MCPServer.controlTools where tool.name != "settings_get" { #expect(tool.scope == .write, "\(tool.name)") }
        #expect(MCPServer.tool(named: "settings_get")?.scope == .read)
    }

    @Test func theTagIsListed() throws {
        let tools = MCPServer.listing()
        for tool in tools {
            let meta = try #require(tool["_meta"] as? [String: Any])
            let name = tool["name"] as? String ?? ""
            #expect(meta["next-term/scope"] as? String == MCPServer.tool(named: name)?.scope?.rawValue, "\(name)")
            #expect(meta["anthropic/alwaysLoad"] as? Bool == true)
        }
    }

    @Test func controlToolsAreAnnotatedHonestly() throws {
        func hints(_ name: String) throws -> [String: Bool] {
            let tool = try #require(MCPServer.listing().first { $0["name"] as? String == name })
            return try #require(tool["annotations"] as? [String: Any]).compactMapValues { $0 as? Bool }
        }
        // name: (destructive, idempotent)
        let expected: [String: (Bool, Bool)] = [
            "propose_edit": (false, false), "write_file": (true, true), "create_file": (false, true), "stage": (true, true),
            "commit": (true, false), "focus_tab": (false, true), "split_pane": (false, false), "close_pane": (true, true),
            "zoom_pane": (false, true), "set_layout": (false, true), "settings_set": (false, true),
        ]
        #expect(Set(expected.keys).union(["settings_get"]) == Set(MCPServer.controlTools.map(\.name)))
        for (name, (destructive, idempotent)) in expected {
            let h = try hints(name)
            #expect(h["readOnlyHint"] == false && h["destructiveHint"] == destructive && h["idempotentHint"] == idempotent, "\(name): \(h)")
            #expect(h["openWorldHint"] == false, "\(name)")
        }
        let get = try hints("settings_get")
        #expect(get["readOnlyHint"] == true && get["destructiveHint"] == false)
        // Every schema parses as an object schema, and each write tool says that the user is asked.
        for tool in MCPServer.controlTools {
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any]
            #expect(schema?["type"] as? String == "object", "\(tool.name)")
            if tool.scope == .write, tool.name != "propose_edit" { #expect(tool.description.contains("asked on the Mac first"), "\(tool.name)") }
        }
        let propose = try #require(MCPServer.tool(named: "propose_edit"))
        #expect(propose.description.contains("never writes the file") && propose.description.contains("Accept or Reject"))
        #expect(MCPServer.tool(named: "commit")?.description.contains("Never pushes") == true)
        #expect(MCPServer.instructions.contains("write_file") && MCPServer.instructions.contains("ask the user"))
        // Long enough for the user to answer, and for hooks.
        for tool in MCPServer.controlTools where tool.scope == .write { #expect(tool.timeout >= 60, "\(tool.name)") }
    }
}

@Suite struct MCPSettingsTests {
    @Test func theAllowlistIsShortAndHarmless() {
        #expect(MCPSettings.allowlist.map(\.name) == ["font_size", "line_height", "soft_wrap", "terminal_position", "notify_decisions",
                                                      "notify_agent_finished", "notify_program_alerts", "notification_sound"])
        // The guards and the switches that reach other programs are never on it, by any spelling.
        for name in ["agent_control", "agentControl", "share_with_claude", "shareWithClaude", "shareWithCopilot", "remote_access",
                     "check_for_updates", "checkForUpdates", "updateInstallWithoutAsking", "keyBindings", "key_bindings", "hideEnvValues",
                     "backgroundFetch", "optionAsMeta"] {
            #expect(MCPSettings.setting(name) == nil, "\(name)")
            let refused = MCPSettings.changes([name: true])
            #expect(refused.failureText?.contains("not a setting agents may change") == true, "\(name)")
        }
    }

    @Test func valuesAreChecked() throws {
        let ok = try MCPSettings.changes(["soft_wrap": false, "font_size": 15, "line_height": 1.5, "terminal_position": "right"]).get()
        // In the allowlist's order.
        #expect(ok.map(\.0.name) == ["font_size", "line_height", "soft_wrap", "terminal_position"])
        #expect(ok.map(\.1) == [.number(15), .number(1.5), .flag(false), .choice("right")])
        let bads: [[String: Any]] = [["font_size": "14"], ["font_size": 14.5], ["font_size": 33], ["font_size": true], ["line_height": 2.5],
                                     ["soft_wrap": 1], ["soft_wrap": "yes"], ["terminal_position": "middle"], ["notification_sound": NSNull()]]
        for bad in bads {
            #expect(MCPSettings.changes(bad).failureText?.contains("nothing was changed") == true, "\(bad)")
        }
        // One bad value refuses them all.
        #expect(MCPSettings.changes(["soft_wrap": false, "agent_control": false]).isFailure)
        #expect(MCPSettings.changes([String: Any]()).isFailure)
        #expect(MCPSettings.changes("font_size").isFailure)
        #expect(MCPSettings.Value.number(13).json as? Int == 13 && MCPSettings.Value.number(1.35).text == "1.35")
    }

    @Test func layoutChanges() throws {
        #expect(MCPLayoutChange.parse([:]).failureText?.contains("at least one") == true)
        #expect(MCPLayoutChange.parse(["terminal_position": "middle"]).isFailure)
        #expect(MCPLayoutChange.parse(["sidebar": true]).isFailure)
        #expect(MCPLayoutChange.parse(["terminal_folded": "yes"]).isFailure)
        let change = try MCPLayoutChange.parse(["terminal_position": "right", "sidebar": "hidden", "terminal_folded": true]).get()
        #expect(change == MCPLayoutChange(terminalPosition: "right", sidebarShown: false, terminalFolded: true))
        #expect(try MCPLayoutChange.parse(["sidebar_side": "right"]).get().sidebarSide == "right")
    }
}

@Suite struct MCPFileToolsTests {
    @Test func writesStayInsideOpenProjectsAndAwayFromSecrets() throws {
        let f = try ProjectFixture()
        let p = f.both
        func write(_ path: String, project: String? = "api") -> Result<MCPFileChange, MCPToolError> {
            var arguments: [String: Any] = ["path": path, "content": "x\n"]
            if let project { arguments["project"] = project }
            return MCPFileTools.prepareWrite(arguments, in: p, git: nil)
        }
        #expect(try write("src/app.txt").get().original?.hasPrefix("line 1\n") == true)
        // Secrets, by name and behind an innocent-looking link, with the reason and a write's wording.
        for path in [".env", "keys/server.pem", "id_ed25519", "notes.txt"] {
            let text = write(path).failureText ?? ""
            #expect(text.hasPrefix("Not written:") && text.contains("never lets agents change"), "\(path): \(text)")
        }
        #expect(write(".git/config").failureText?.contains(".git") == true)
        // Outside the open projects, through a link or "..", and absolute.
        #expect(write("link-out.txt").failureText?.contains("only files inside them are written") == true)
        #expect(write("../outside/secret.txt").failureText?.contains("outside") == true)
        #expect(write(f.outside + "/secret.txt", project: nil).failureText?.contains("outside") == true)
        #expect(write("src").failureText?.contains("is a folder; name a file") == true)
        #expect(write("blob.bin").failureText?.contains("binary") == true)
        #expect(write("missing.txt").failureText?.contains("No such file") == true)
        // content is required, and text.
        #expect(MCPFileTools.prepareWrite(["path": "src/app.txt", "project": "api"], in: p, git: nil).failureText?.contains("content") == true)
        #expect(MCPFileTools.prepareWrite(["path": "src/app.txt", "project": "api", "content": 5], in: p, git: nil).isFailure)
        #expect(MCPFileTools.prepareWrite(["path": "src/app.txt", "project": "api", "content": "a\0b"], in: p, git: nil).isFailure)
    }

    @Test func createMakesOnlyNewFiles() throws {
        let f = try ProjectFixture()
        let p = f.both
        func create(_ path: String) -> Result<MCPFileChange, MCPToolError> {
            MCPFileTools.prepareCreate(["path": path, "project": "api", "content": "new\n"], in: p, git: nil)
        }
        #expect(create("src/app.txt").failureText?.contains("exists already") == true)
        #expect(create("notes.txt").failureText?.contains("Not written") == true) // a link to .env
        #expect(create("link-in.txt").failureText?.contains("exists already") == true)
        for path in [".env.production", "config/credentials.json", "deploy/tls.key", ".git/hooks/pre-commit", ".ssh/config"] {
            #expect(create(path).failureText?.hasPrefix("Not written") == true, "\(path)")
        }
        #expect(create("../outside/new.txt").isFailure)
        #expect(create("src/new/").failureText?.contains("not a folder's") == true)
        let change = try create("docs/guide/intro.md").get()
        #expect(change.isNew && change.file.relative == "docs/guide/intro.md")
        try MCPFileTools.create(change)
        #expect(try String(contentsOfFile: f.a + "/docs/guide/intro.md", encoding: .utf8) == "new\n")
        // Something appeared there between the check and the write: it is never overwritten.
        let late = try create("late.txt").get()
        try f.write("api/late.txt", "theirs\n")
        #expect(throws: MCPToolError.self) { try MCPFileTools.create(late) }
        #expect(try String(contentsOfFile: f.a + "/late.txt", encoding: .utf8) == "theirs\n")
    }

    @Test func writeKeepsTheFileAsItIsStored() throws {
        let f = try ProjectFixture()
        let path = f.a + "/win.txt"
        try Data("one\r\ntwo\r\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let change = try MCPFileTools.prepareWrite(["path": "win.txt", "project": "api", "content": "one\nTWO\nthree\n"], in: f.both, git: nil).get()
        #expect(change.original == "one\ntwo\n" && change.changesText)
        try MCPFileTools.write(change)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("one\r\nTWO\r\nthree\r\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        // The same text again changes nothing.
        let again = try MCPFileTools.prepareWrite(["path": "win.txt", "project": "api", "content": "one\r\nTWO\r\nthree\r\n"], in: f.both, git: nil).get()
        #expect(!again.changesText)
    }

    @Test func aFileChangedSinceItWasReadIsNotWritten() throws {
        let f = try ProjectFixture()
        let change = try MCPFileTools.prepareWrite(["path": "src/app.txt", "project": "api", "content": "mine\n"], in: f.both, git: nil).get()
        try f.write("api/src/app.txt", "the user's edit\n")
        #expect(throws: MCPToolError.self) { try MCPFileTools.write(change) }
        #expect(try String(contentsOfFile: f.a + "/src/app.txt", encoding: .utf8) == "the user's edit\n")
    }

    @Test func proposals() throws {
        let f = try ProjectFixture()
        let p = f.both
        func propose(_ arguments: [String: Any]) -> Result<MCPFileChange, MCPToolError> {
            MCPFileTools.prepareProposal(arguments.merging(["project": "api"]) { $1 }, in: p, git: nil)
        }
        let replaced = try propose(["path": "src/app.txt", "old_text": "line 3\n", "new_text": "line three\n"]).get()
        #expect(replaced.content.contains("line 2\nline three\nline 4") && replaced.original?.contains("line 3\n") == true)
        #expect(propose(["path": "src/app.txt", "old_text": "line", "new_text": "x"]).failureText?.contains("appears 10 times") == true)
        #expect(propose(["path": "src/app.txt", "old_text": "nope", "new_text": "x"]).failureText?.contains("not in") == true)
        #expect(propose(["path": "src/app.txt", "old_text": "", "new_text": "x"]).failureText?.contains("empty") == true)
        #expect(propose(["path": "src/app.txt", "content": "a", "old_text": "line 1", "new_text": "b"]).failureText?.contains("not both") == true)
        #expect(propose(["path": "src/app.txt"]).isFailure)
        #expect(propose(["path": "src/app.txt", "old_text": "line 1"]).isFailure)
        // A new file takes content, and its left side is empty.
        let new = try propose(["path": "src/fresh.txt", "content": "hi\n"]).get()
        #expect(new.isNew && new.content == "hi\n")
        #expect(propose(["path": "src/fresh.txt", "old_text": "a", "new_text": "b"]).failureText?.contains("No such file") == true)
        #expect(propose(["path": ".env", "content": "A=1\n"]).failureText?.hasPrefix("Not written") == true)
        #expect(propose(["path": "link-out.txt", "content": "x"]).isFailure)
    }

    /// commit runs the repository's hooks, so a write there would let write and commit run anything.
    @Test func gitHooksAreNeverWritten() throws {
        guard let git = GitRunner.locateGit() else { return }
        let f = try ProjectFixture()
        let repo = f.base + "/hooked"
        try f.write("hooked/src/app.txt", "a\n")
        try f.write("hooked/.husky/pre-commit", "npm test\n")
        try f.write("hooked/.husky/_/h", "sh\n")
        try f.write("hooked/.pre-commit-config.yaml", "repos: []\n")
        try f.write("hooked/docs/lefthook.yml", "about lefthook\n")
        func sh(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try sh("init", "-q")
        try sh("config", "core.hooksPath", ".husky/_") // as husky sets it
        let p = MCPProjects(open: [repo], preferred: nil)
        func write(_ path: String) -> String? { MCPFileTools.prepareWrite(["path": path, "content": "x\n"], in: p, git: git).failureText }
        func create(_ path: String) -> String? { MCPFileTools.prepareCreate(["path": path, "content": "x\n"], in: p, git: git).failureText }
        func propose(_ path: String) -> String? { MCPFileTools.prepareProposal(["path": path, "content": "x\n"], in: p, git: git).failureText }
        for text in [write(".husky/pre-commit"), write(".husky/_/h"), create(".husky/commit-msg"), propose(".husky/pre-push"), create(".HUSKY/post-commit")] {
            #expect(text?.hasPrefix("Not written:") == true && text?.contains("is a git hook, which commit would run") == true, "\(String(describing: text))")
        }
        for text in [propose(".pre-commit-config.yaml"), create("lefthook.yml"), create(".lefthook-local.toml")] {
            #expect(text?.contains("lists what the repository's git hooks run") == true, "\(String(describing: text))")
        }
        // Elsewhere in the repository, and a lefthook.yml that is not the repository's own settings.
        #expect(write("src/app.txt") == nil && create("src/new.txt") == nil && write("docs/lefthook.yml") == nil && create("lefthook-notes.md") == nil)
        // A hooks folder of the repository's own choosing.
        try sh("config", "core.hooksPath", "tools/hooks")
        #expect(create("tools/hooks/pre-push")?.contains("git hook") == true)
        // A clone inside the repository whose folder the outer repository's hooks are in: commit in the
        // outer one runs them, whichever repository the file is in.
        try f.write("hooked/vendor/hooks/README", "x\n")
        let inner = Process()
        inner.executableURL = URL(fileURLWithPath: git)
        inner.arguments = ["-C", repo + "/vendor", "init", "-q"]
        inner.standardOutput = FileHandle.nullDevice
        try inner.run()
        inner.waitUntilExit()
        try sh("config", "core.hooksPath", "vendor/hooks")
        #expect(create("vendor/hooks/pre-commit")?.contains("git hook") == true)
        #expect(create("vendor/notes.md") == nil)
        // Outside a repository no commit runs hooks; with no git there is no commit at all.
        let plain = MCPProjects(open: [f.a], preferred: nil)
        #expect(MCPFileTools.prepareCreate(["path": ".husky/pre-commit", "content": "x\n"], in: plain, git: git).isSuccess)
        #expect(MCPFileTools.prepareCreate(["path": ".husky/pre-merge-commit", "content": "x\n"], in: p, git: nil).isSuccess)
        #expect(MCPFileTools.isHookSettings(".pre-commit-config.yml") && MCPFileTools.isHookSettings("Lefthook.yaml") && !MCPFileTools.isHookSettings("lefthook.md"))
    }

    @Test func theSummarySaysWhatChanges() throws {
        let f = try ProjectFixture()
        let change = try MCPFileTools.prepareWrite(["path": "src/app.txt", "project": "api",
                                                    "content": "line 1\nline 2\nCHANGED\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n"],
                                                   in: f.both, git: nil).get()
        if let git = GitRunner.locateGit() {
            let summary = MCPFileTools.summary(change, git: git)
            #expect(summary.hasPrefix("+1 −1 lines.") && summary.contains("− line 3") && summary.contains("+ CHANGED"), "\(summary)")
        }
        #expect(MCPFileTools.summary(change, git: nil).contains("10 lines"))
        let new = try MCPFileTools.prepareCreate(["path": "n.txt", "project": "api", "content": "a\nb\n"], in: f.both, git: nil).get()
        #expect(MCPFileTools.summary(new, git: nil).hasPrefix("2 lines, "))
    }
}

@Suite struct MCPCommitGuardTests {
    @Test func otherStagedChangesNeedSayingSo() throws {
        #expect(MCPGitTools.commitFiles(named: [], staged: [], includeStaged: true).failureText?.contains("Nothing to commit") == true)
        let unnamed = MCPGitTools.commitFiles(named: [], staged: ["b.txt", "a.txt"], includeStaged: false)
        #expect(unnamed.failureText?.contains("include_staged: true") == true && unnamed.failureText?.contains("a.txt, b.txt") == true)
        #expect(try MCPGitTools.commitFiles(named: [], staged: ["b.txt", "a.txt"], includeStaged: true).get() == ["a.txt", "b.txt"])
        let others = MCPGitTools.commitFiles(named: ["a.txt"], staged: ["a.txt", "z.txt"], includeStaged: false)
        #expect(others.failureText?.contains("z.txt") == true && others.failureText?.contains("Nothing was committed") == true)
        #expect(try MCPGitTools.commitFiles(named: ["a.txt"], staged: ["a.txt", "z.txt"], includeStaged: true).get() == ["a.txt", "z.txt"])
        #expect(try MCPGitTools.commitFiles(named: ["c.txt", "a.txt"], staged: ["a.txt"], includeStaged: false).get() == ["a.txt", "c.txt"])
        // A long list is cut, and says how many more.
        let many = (1...14).map { "f\($0).txt" }
        #expect(MCPGitTools.commitFiles(named: [], staged: many, includeStaged: false).failureText?.contains("and 4 more") == true)
    }

    @Test func messagesAndRefusals() {
        #expect(MCPGitTools.message(nil).isFailure && MCPGitTools.message("  \n").isFailure && MCPGitTools.message(3).isFailure)
        #expect(MCPGitTools.message("a\0b").isFailure && MCPGitTools.message(String(repeating: "x", count: 10_001)).isFailure)
        #expect(MCPGitTools.message("Fix the parser\n\nDetails.") == .success("Fix the parser\n\nDetails."))
        let clean = MCPRepository(root: "/r", gitDir: "/r/.git", commonDir: "/r/.git", branch: "main", inProgress: nil)
        #expect(MCPGitTools.commitRefusal(clean) == nil)
        let merging = MCPRepository(root: "/r", gitDir: "/r/.git", commonDir: "/r/.git", branch: "main", inProgress: .merge)
        #expect(MCPGitTools.commitRefusal(merging)?.text.contains("Merging is in progress") == true)
        let detached = MCPRepository(root: "/r", gitDir: "/r/.git", commonDir: "/r/.git", branch: nil, inProgress: nil)
        #expect(MCPGitTools.commitRefusal(detached)?.text.contains("detached") == true)
    }

    @Test func theCommandsNeverPushOrTakePatterns() {
        let add = MCPGitTools.stageArguments(pathspecFile: "/tmp/p")
        #expect(add.first == "--literal-pathspecs" && add.contains("--pathspec-file-nul") && add.contains("--pathspec-from-file=/tmp/p"))
        let commit = MCPGitTools.commitArguments(messageFile: "/tmp/m")
        #expect(commit == ["commit", "--file=/tmp/m"])
        #expect(!commit.contains("--amend") && !commit.contains("--no-verify") && !add.contains("push"))
        #expect(MCPGitTools.committedID(from: "[main abc1234] Fix the parser\n 1 file changed") == "abc1234")
        #expect(MCPGitTools.committedID(from: "[feat/x (root-commit) 0123456789] First") == "0123456789")
        #expect(MCPGitTools.committedID(from: "nothing to commit") == nil)
    }

    /// A repository with a commit, a staged change and an unstaged one (MCPGitToolsTests' fixture).
    @Test func plansInARealRepository() throws {
        guard let (fixture, projects, git) = try MCPGitToolsTests().repository() else { return }
        defer { withExtendedLifetime(fixture) {} }
        // staged.txt is staged already: naming another file alone is refused, naming it too is not.
        let refused = MCPGitTools.prepareCommit(["message": "m", "paths": ["edited.txt"]], in: projects, git: git)
        #expect(refused.failureText?.contains("staged.txt") == true, "\(String(describing: refused.failureText))")
        let plan = try MCPGitTools.prepareCommit(["message": "m", "paths": ["edited.txt"], "include_staged": true], in: projects, git: git).get()
        #expect(plan.files == ["edited.txt", "staged.txt"] && plan.paths == ["edited.txt"] && plan.repository.branch == "main")
        #expect(MCPGitTools.summary(plan).contains("staged.txt (staged already)") && MCPGitTools.summary(plan).contains("Nothing is pushed."))
        #expect(MCPGitTools.changedSince(plan, git: git) == nil)
        // The paths: never a secrets file, a folder, or anything outside the repository.
        let paths = { (names: [String]) in MCPGitTools.prepareStage(["paths": names], in: projects, git: git) }
        #expect(paths([".env"]).failureText?.hasPrefix("Not written") == true)
        #expect(paths(["."]).failureText?.contains("folder") == true)
        #expect(paths(["../api/src/app.txt"]).isFailure)
        #expect(paths([]).isFailure)
        #expect(try paths(["new.txt", "./new.txt", "gone.txt"]).get().paths == ["gone.txt", "new.txt"]) // a deleted file too
        // Something staged meanwhile: what the user approved no longer holds.
        let staged = try MCPGitTools.prepareCommit(["message": "m", "include_staged": true], in: projects, git: git).get()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", fixture.base + "/repo", "add", "new.txt"]
        try p.run()
        p.waitUntilExit()
        #expect(MCPGitTools.changedSince(staged, git: git)?.text.contains("staged changes changed") == true)
    }
}
