import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommandClassifierTests {
    @Test func programName() {
        #expect(CommandClassifier.programName("FOO=1 sudo npx @anthropic-ai/claude-code --resume") == "claude-code")
        #expect(CommandClassifier.programName("/usr/local/bin/claude") == "claude")
        #expect(CommandClassifier.programName("  make   test ") == "make")
        #expect(CommandClassifier.programName("") == "")
        #expect(CommandClassifier.programName("A=1 B=2") == "")
    }

    @Test func kinds() {
        #expect(CommandClassifier.kind(of: "claude") == .agent)
        #expect(CommandClassifier.kind(of: "codex --full-auto") == .agent)
        #expect(CommandClassifier.kind(of: "npx @anthropic-ai/claude-code") == .agent)
        #expect(CommandClassifier.kind(of: "vim notes.md") == .interactive)
        #expect(CommandClassifier.kind(of: "ssh prod") == .interactive)
        #expect(CommandClassifier.kind(of: "php artisan tinker") == .interactive)
        #expect(CommandClassifier.kind(of: "node") == .interactive)
        #expect(CommandClassifier.kind(of: "python3.12 -i") == .interactive)
        #expect(CommandClassifier.kind(of: "node build.js") == .command)
        #expect(CommandClassifier.kind(of: "python3 -c 'print(1)'") == .command)
        #expect(CommandClassifier.kind(of: "php artisan migrate") == .command)
        #expect(CommandClassifier.kind(of: "npm install") == .command)
        #expect(CommandClassifier.kind(of: "sleep 10") == .command)
    }
}

@Suite struct AgentDetectionTests {
    @Test func compoundLines() {
        #expect(CommandClassifier.segments("cd x && \"a b\" | less; make & y") == ["cd x", "\"a b\"", "less", "make", "y"])
        #expect(CommandClassifier.segments("git commit -m 'a && b'") == ["git commit -m 'a && b'"])
        #expect(CommandClassifier.kind(of: "cd ~/proj && claude") == .agent)
        #expect(CommandClassifier.kind(of: "nvm use 22 && codex --yolo") == .agent)
        #expect(CommandClassifier.programName("cd ~/proj && claude") == "claude")
        #expect(CommandClassifier.programName("cd ~/proj && make test") == "make")
        #expect(CommandClassifier.kind(of: "caffeinate -i claude") == .agent)
        #expect(CommandClassifier.kind(of: "npx @google/gemini-cli") == .agent)
        #expect(CommandClassifier.kind(of: "git commit -m 'claude && codex'") == .command)
        #expect(CommandClassifier.kind(of: "cat log | less") == .interactive)
    }

    @Test func processesSeeThroughFunctionsAndInstallers() {
        // Claude Code's native installer: ~/.local/bin/claude -> ~/.local/share/claude/versions/2.1.280
        let native = ForegroundProcess(isShell: false, name: "2.1.280", arguments: ["claude", "--resume"],
                                       executablePath: "/Users/me/.local/share/claude/versions/2.1.280")
        #expect(CommandClassifier.kind(of: native) == .agent)
        #expect(CommandClassifier.programName(of: native) == "claude")
        let npmNative = ForegroundProcess(isShell: false, name: "claude.exe", arguments: ["claude"])
        #expect(CommandClassifier.kind(of: npmNative) == .agent)
        let npmNode = ForegroundProcess(isShell: false, name: "node",
                                        arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])
        #expect(CommandClassifier.kind(of: npmNode) == .agent)
        #expect(CommandClassifier.programName(of: npmNode) == "claude")
        let codex = ForegroundProcess(isShell: false, name: "codex", arguments: ["codex", "--yolo"])
        #expect(CommandClassifier.kind(of: codex) == .agent)
        let build = ForegroundProcess(isShell: false, name: "node", arguments: ["node", "build.js"])
        #expect(CommandClassifier.kind(of: build) == .command)
        let repl = ForegroundProcess(isShell: false, name: "node", arguments: ["node"])
        #expect(CommandClassifier.kind(of: repl) == .interactive)
    }
}

@Suite struct TabStatusTests {
    @Test func commandInBackgroundTabFinishesDone() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        #expect(s.state == .working)
        s.commandFinished(exitCode: 0, at: 10)
        #expect(s.state == .done)
        #expect(s.takeNotice() == TabNotice(state: .done, command: "make", program: "make", kind: .command, stillRunning: false))
        #expect(s.takeNotice() == nil)
        s.setVisible(true)
        #expect(s.state == .idle)
    }

    @Test func failureIsRed() {
        var s = TabStatus()
        s.commandStarted("false", at: 0)
        s.commandFinished(exitCode: 1, at: 0.1)
        #expect(s.state == .failed)
        #expect(s.exitCode == 1)
        #expect(s.takeNotice() == nil) // too quick to notify
    }

    @Test func visibleTabNeverMarks() {
        var s = TabStatus()
        s.setVisible(true)
        s.commandStarted("make", at: 0)
        s.commandFinished(exitCode: 2, at: 60)
        s.bell()
        #expect(s.state == .idle)
        #expect(s.takeNotice() == nil)
    }

    @Test func bareEnterAtPromptIsIgnored() {
        var s = TabStatus()
        s.commandFinished(exitCode: 0, at: 1)
        #expect(s.state == .idle)
        #expect(s.integrated)
    }

    @Test func newCommandClearsOldResult() {
        var s = TabStatus()
        s.commandStarted("false", at: 0)
        s.commandFinished(exitCode: 1, at: 1)
        s.commandStarted("sleep 5", at: 2)
        #expect(s.state == .working)
    }

    @Test func agentWorksThenWaits() {
        var s = TabStatus()
        s.commandStarted("claude", at: 0)
        #expect(s.state == .idle) // started, nothing printed yet
        s.output(at: 1)
        #expect(s.state == .working)
        s.output(at: 8)
        s.tick(at: 9)
        #expect(s.state == .working)
        s.tick(at: 8 + TabStatus.quietAfter)
        #expect(s.state == .done)
        #expect(s.takeNotice() == TabNotice(state: .done, command: "claude", program: "claude", kind: .agent, stillRunning: true))
        // Agent resumes: the stale done clears.
        s.output(at: 20)
        #expect(s.state == .working)
    }

    @Test func typingIntoAgentIsNotWork() {
        var s = TabStatus()
        s.commandStarted("claude", at: 0)
        s.input(at: 5)
        s.output(at: 5.05)
        #expect(s.state == .idle)
        s.resized(at: 6)
        s.output(at: 6.1)
        #expect(s.state == .idle)
    }

    @Test func interactiveProgramsAreNeverDone() {
        var s = TabStatus()
        s.commandStarted("vim a.txt", at: 0)
        s.output(at: 1)
        #expect(s.state == .working)
        s.tick(at: 10)
        #expect(s.state == .idle)
        s.commandFinished(exitCode: 0, at: 60)
        #expect(s.state == .idle)
        #expect(s.takeNotice() == nil)
    }

    @Test func attentionOutranksAndSurvivesDone() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        s.bell()
        #expect(s.state == .attention)
        s.commandFinished(exitCode: 0, at: 1)
        #expect(s.state == .attention)
        s.setVisible(true)
        #expect(s.state == .idle)
    }

    @Test func fallbackPollingWithoutIntegration() {
        var s = TabStatus()
        s.observe(ForegroundProcess(isShell: true, name: "bash"), at: 0)
        #expect(s.state == .idle)
        s.observe(ForegroundProcess(isShell: false, name: "sleep", arguments: ["sleep", "8"]), at: 1)
        #expect(s.state == .working)
        #expect(s.program == "sleep")
        s.observe(nil, at: 5) // unreadable foreground (a pipeline's leader exited): keep the state
        #expect(s.state == .working)
        s.observe(ForegroundProcess(isShell: true, name: "bash"), at: 9)
        #expect(s.state == .done)
        #expect(s.takeNotice()?.state == .done)
    }

    @Test func fallbackSeesWrapperProcesses() {
        var s = TabStatus()
        s.observe(ForegroundProcess(isShell: false, name: "sudo", arguments: ["sudo", "make", "install"]), at: 0)
        #expect(s.state == .working)
        // A bash script run from bash is a running program, not the idle shell (decided by pid upstream).
        s.observe(ForegroundProcess(isShell: false, name: "bash", arguments: ["/bin/bash", "./deploy.sh"]), at: 1)
        #expect(s.running)
        s.observe(ForegroundProcess(isShell: true, name: "bash"), at: 2)
        #expect(!s.running)
    }

    @Test func aliasExpandingToAnAgentIsAnAgent() {
        var s = TabStatus()
        s.commandStarted("claude-auto", expanded: "claude --permission-mode auto --enable-auto-mode", at: 0)
        #expect(s.kind == .agent)
        #expect(s.program == "claude-auto") // the tab shows what you typed
        s.output(at: 1)
        s.tick(at: 1 + TabStatus.quietAfter)
        #expect(s.state == .done)
        #expect(s.takeNotice() == nil) // quick, so no notification, but the dot says "waiting for you"
    }

    @Test func functionRunningAnAgentIsFoundByPolling() {
        var s = TabStatus()
        s.commandStarted("claude-auto-danger", at: 0) // a shell function: zsh cannot expand it
        #expect(s.kind == .command && s.state == .working)
        s.output(at: 0.5)
        s.observe(ForegroundProcess(isShell: false, name: "claude", arguments: ["claude", "--dangerously-skip-permissions"]), at: 1)
        #expect(s.kind == .agent)
        #expect(s.state == .working)
        s.output(at: 4)
        s.output(at: 7) // six seconds of work since it was recognised
        s.tick(at: 7 + TabStatus.quietAfter)
        #expect(s.state == .done)
        let notice = s.takeNotice()
        #expect(notice?.stillRunning == true && notice?.kind == .agent)
    }

    @Test func kernelSeenExecEndsIntegration() {
        var s = TabStatus()
        s.commandStarted("omz reload", at: 0)
        #expect(s.running)
        s.shellReplaced()
        #expect(!s.running && !s.integrated)
        s.observe(ForegroundProcess(isShell: true, name: "zsh"), at: 2)
        #expect(s.state == .idle)
    }

    @Test func oneShotAgentNoticeSaysFinished() {
        var s = TabStatus()
        s.commandStarted("claude -p 'summarize'", at: 0)
        s.commandFinished(exitCode: 0, at: 30)
        let notice = s.takeNotice()
        #expect(notice?.state == .done && notice?.stillRunning == false)
    }

    @Test func jobsAndShellExit() {
        var s = TabStatus()
        s.jobsChanged(count: 1, summary: "vim notes.md (suspended)")
        #expect(s.jobs == 1 && s.jobSummary.contains("vim"))
        s.shellExited(code: 1)
        #expect(s.state == .failed && s.exitCode == 1)
    }

    @Test func execHandsOverToPolling() {
        var s = TabStatus()
        s.commandStarted("ls", at: 0)
        s.commandFinished(exitCode: 0, at: 1)
        s.commandStarted("exec zsh", at: 2)
        #expect(!s.integrated && !s.running)
        s.observe(ForegroundProcess(isShell: false, name: "ssh", arguments: ["ssh", "prod"]), at: 3)
        #expect(s.running)
    }

    @Test func bellLoopNotifiesOnce() {
        var s = TabStatus()
        s.bell()
        #expect(s.takeNotice()?.state == .attention)
        for _ in 0..<500 { s.bell() }
        #expect(s.takeNotice() == nil)
        s.setVisible(true)
        s.setVisible(false)
        s.bell()
        #expect(s.takeNotice()?.state == .attention)
    }

    @Test func programNameIsCached() {
        var s = TabStatus()
        s.commandStarted("FOO=1 claude --resume", at: 0)
        #expect(s.program == "claude")
    }

    @Test func pollingIgnoredOnceIntegrated() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        s.observe(ForegroundProcess(isShell: true, name: "zsh"), at: 1)
        #expect(s.state == .working)
    }
}

@Suite struct ShellIntegrationTests {
    let n = "abc123"
    func parse(_ s: String) -> ShellIntegration.Event? { ShellIntegration.parse(Array(s.utf8), nonce: n) }

    @Test func parsesEvents() {
        let cmd = Data("git commit -m \"é; x\"".utf8).base64EncodedString()
        #expect(parse("\(n);cmd;\(cmd)") == .commandStarted("git commit -m \"é; x\"", expanded: nil))
        let alias = Data("claude-auto".utf8).base64EncodedString()
        let full = Data("claude --permission-mode auto".utf8).base64EncodedString()
        #expect(parse("\(n);cmd;\(alias);\(full)") == .commandStarted("claude-auto", expanded: "claude --permission-mode auto"))
        #expect(parse("\(n);cmd;\(alias);\(alias)") == .commandStarted("claude-auto", expanded: nil))
        let jobs = Data("vim notes.md (suspended)".utf8).base64EncodedString()
        #expect(parse("\(n);jobs;1;\(jobs)") == .jobs(1, summary: "vim notes.md (suspended)"))
        #expect(parse("\(n);jobs;0;") == .jobs(0, summary: ""))
        #expect(parse("\(n);jobs;-1;") == nil)
        #expect(parse("\(n);end;127") == .commandFinished(127))
        #expect(parse("\(n);cwd;\(Data("/tmp/a b".utf8).base64EncodedString())") == .directory("/tmp/a b"))
        #expect(parse("\(n);end;x") == nil)
        #expect(parse("\(n);nope;1") == nil)
        #expect(parse("\(n);cmd") == nil)
        #expect(parse("\(n);cmd;!!!") == nil)
        #expect(parse("\(n);cwd;\(Data("relative".utf8).base64EncodedString())") == nil)
    }

    @Test func rejectsMarksWithoutTheTabsNonce() {
        #expect(parse("end;0") == nil)                 // old format / no nonce
        #expect(parse("wrong;end;0") == nil)           // another tab's, or a guess
        #expect(ShellIntegration.parse(Array("\(n);end;0".utf8), nonce: "") == nil)
    }

    @Test func capsSizes() {
        let long = String(repeating: "x", count: 10_000)
        let event = parse("\(n);cmd;\(Data(long.utf8).base64EncodedString())")
        #expect(event == .commandStarted(String(repeating: "x", count: ShellIntegration.maxCommandLength), expanded: nil))
        let huge = String(repeating: "A", count: 100_000)
        #expect(parse("\(n);cmd;\(huge)") == nil)
    }

    @Test func noncesAreUnique() {
        #expect(ShellIntegration.makeNonce() != ShellIntegration.makeNonce())
        #expect(ShellIntegration.makeNonce().count == 32)
    }

    @Test func installWritesScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zdotdir = try ShellIntegration.install(in: dir)
        let text = try String(contentsOf: zdotdir.appendingPathComponent(".zshenv"), encoding: .utf8)
        #expect(text == ShellIntegration.zshenvScript)
        #expect(text.contains("6973;%s;cmd;") && text.contains("unset NEXTTERM_NONCE"))
    }
}

@Suite struct ShellQuoteTests {
    @Test func quoting() {
        #expect(ShellQuote.quote("/usr/local/bin") == "/usr/local/bin")
        #expect(ShellQuote.quote("/tmp/a b") == "'/tmp/a b'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("notes\u{15} touch PWNED\r.txt") == "$'notes\\x15 touch PWNED\\x0D.txt'")
    }

    static let nasty = [
        "plain", "a b", "it's", "back\\slash", "$(touch PWNED)", "`id`", "a;b|c&d", "-rf", "~user", "*.txt",
        "notes\u{15} touch PWNED\r.txt", "line\nbreak", "esc\u{1b}[201~x", "del\u{7f}", "c1\u{85}x", "tab\tq'uote\\",
        "বাংলা ফাইল.md", "emoji 🙂", "!event", "{a,b}", "#hash",
    ]

    /// The real test: the quoted text, run through zsh and bash, comes back byte for byte,
    /// and never contains a control character that the line editor would act on.
    @Test(arguments: nasty) func quotedTextRoundTripsThroughRealShells(_ name: String) throws {
        let quoted = ShellQuote.quote(name)
        #expect(!quoted.unicodeScalars.contains(where: ShellQuote.isControl), "control character in \(quoted)")
        for shell in ["/bin/zsh", "/bin/bash"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", "printf %s \(quoted)"] : ["--norc", "-c", "printf %s \(quoted)"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let got = out.fileHandleForReading.readDataToEndOfFile()
            #expect(got == Data(name.utf8), "\(shell): \(quoted)")
        }
    }
}

@Suite struct FileTreeTests {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-tree-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["proj/.git", "proj/src/deep", "proj/Zeta", "proj/alpha"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["proj/file10.txt", "proj/file2.txt", "proj/.env", "proj/.DS_Store", "proj/README.md"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        return root
    }

    @Test func canonicalPathMatchesTheKernel() {
        #expect(canonicalPath("/tmp") == "/private/tmp")
        #expect(canonicalPath("/tmp/../tmp/./") == "/private/tmp")
        #expect(canonicalPath("/no/such/dir/x") == "/no/such/dir/x")
    }

    @Test func projectRootIsTheGitWorkTree() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("proj").standardizedFileURL.path
        #expect(ProjectRoot.find(from: proj + "/src/deep") == proj)
        #expect(ProjectRoot.find(from: proj) == proj)
        let outside = root.appendingPathComponent("proj/../").standardizedFileURL.path
        #expect(ProjectRoot.find(from: outside) == outside) // no .git above: the folder itself
    }

    @Test func listingOrderAndHiding() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = FileNode(url: root.appendingPathComponent("proj"))
        node.loadChildren()
        #expect(node.children?.map(\.name) == ["alpha", "src", "Zeta", ".env", "file2.txt", "file10.txt", "README.md"])
        #expect(node.children?.first?.isDirectory == true)
    }

    @Test func reloadKeepsNodesAndSeesChanges() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = FileNode(url: root.appendingPathComponent("proj"))
        node.loadChildren()
        let src = node.children!.first { $0.name == "src" }!
        src.loadChildren()
        #expect(node.reload() == false)
        try Data().write(to: root.appendingPathComponent("proj/new.swift"))
        #expect(node.reload() == true)
        #expect(node.children!.contains { $0.name == "new.swift" })
        #expect(node.children!.first { $0.name == "src" } === src) // same object: stays expanded
        #expect(src.isLoaded)
        #expect(node.node(at: src.path + "/deep") != nil)
        #expect(node.node(at: "/elsewhere") == nil)
    }
}

@Suite struct FileOpsTests {
    func tempFolder() throws -> URL {
        let url = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func names() {
        #expect(FileOps.problem(withName: "ok.txt") == nil)
        #expect(FileOps.problem(withName: "") != nil)
        #expect(FileOps.problem(withName: "  ") != nil)
        #expect(FileOps.problem(withName: "a/b") != nil)
        #expect(FileOps.problem(withName: "..") != nil)
        #expect(FileOps.problem(withName: "bad\rname") != nil)
        #expect(FileOps.problem(withName: String(repeating: "x", count: 300)) != nil)
    }

    @Test func keepBothNaming() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "a 2.txt", "Makefile", ".env"] { try Data().write(to: dir.appendingPathComponent(name)) }
        #expect(FileOps.availableName("b.txt", in: dir) == "b.txt")
        #expect(FileOps.availableName("a.txt", in: dir) == "a 3.txt")
        #expect(FileOps.availableName("Makefile", in: dir) == "Makefile 2")
        #expect(FileOps.availableName(".env", in: dir) == ".env 2")
    }

    @Test func moveRules() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src"), deep = src.appendingPathComponent("deep"), other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(!FileOps.canMove(src, into: src))
        #expect(!FileOps.canMove(src, into: deep))  // into its own descendant
        #expect(!FileOps.canMove(deep, into: src))  // already there
        #expect(FileOps.canMove(deep, into: other))
        let file = src.appendingPathComponent("x.swift")
        try Data("1".utf8).write(to: file)
        try Data("2".utf8).write(to: other.appendingPathComponent("x.swift"))
        let moved = try FileOps.transfer([file], into: other, copy: false)
        #expect(moved.first?.to.lastPathComponent == "x 2.swift")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let copied = try FileOps.transfer([other.appendingPathComponent("x.swift")], into: src, copy: true)
        #expect(copied.first?.to.lastPathComponent == "x.swift")
    }

    @Test func renaming() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("readme.md"), b = dir.appendingPathComponent("b.md")
        try Data().write(to: a)
        try Data().write(to: b)
        let upper = try FileOps.rename(a, to: "README.md") // case only
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains("README.md"))
        #expect(throws: (any Error).self) { try FileOps.rename(upper, to: "b.md") } // taken
        #expect(throws: (any Error).self) { try FileOps.rename(upper, to: "x/y") }
    }

    @Test func listingCapAndMerge() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("keep"), withIntermediateDirectories: true)
        let node = FileNode(url: dir)
        node.loadChildren()
        let keep = node.children!.first!
        try Data().write(to: dir.appendingPathComponent("new.txt"))
        let listing = FileNode.readChildren(of: dir) // e.g. on a background queue
        #expect(node.install(listing) == true)
        #expect(node.children!.first === keep)
        #expect(node.children!.last?.parent === node)
        #expect(node.install(FileNode.readChildren(of: dir)) == false)
        #expect(node.children!.last?.relativePath(to: dir.path) == "new.txt")
    }
}

@Suite struct RecentProjectsTests {
    @Test func ordering() {
        var r = RecentProjects(["/a", "/b", "/a"])
        #expect(r.paths == ["/a", "/b"])
        r.add("/b")
        #expect(r.paths == ["/b", "/a"])
        for i in 0..<20 { r.add("/p\(i)") }
        #expect(r.paths.count == RecentProjects.limit && r.paths.first == "/p19")
        r.remove("/p19")
        #expect(r.paths.first == "/p18")
        r.clear()
        #expect(r.paths.isEmpty)
    }

    @Test func existingAndAbbreviation() {
        let r = RecentProjects(["/tmp", "/no/such/folder"])
        #expect(r.existing() == ["/tmp"])
        #expect(RecentProjects.abbreviate("/Users/me/Code/x", home: "/Users/me") == "~/Code/x")
        #expect(RecentProjects.abbreviate("/Users/meow", home: "/Users/me") == "/Users/meow")
    }
}
