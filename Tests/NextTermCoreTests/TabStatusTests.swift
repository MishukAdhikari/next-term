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

    @Test func programLine() {
        #expect(CommandClassifier.programLine("sleep 30") == "sleep 30")
        #expect(CommandClassifier.programLine("PATH=/tmp/bin:$PATH claude --resume abc") == "claude --resume abc")
        #expect(CommandClassifier.programLine("cd web && npm run dev") == "npm run dev")
        #expect(CommandClassifier.programLine("FOO=1 sudo npx @anthropic-ai/claude-code --resume") == "claude-code --resume")
        #expect(CommandClassifier.programLine("A=1 B=2") == "")
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

/// OpenCode however it starts: its npm package with or without a version, run by any package runner, OpenCode 2's
/// `opencode2` and `@opencode/cli`, and npm's native `opencode.exe`, each named "opencode". Its servers are commands.
@Suite struct OpencodeRecognitionTests {
    static let starts = [
        "opencode", "opencode2", "npx opencode-ai", "npx opencode-ai@latest", "bunx opencode-ai@1.19.0", "npx @opencode/cli",
        "npx -y @opencode/cli@2.0.26", "pnpm dlx opencode-ai", "yarn dlx opencode-ai@latest", "pnpx opencode-ai",
        "/usr/local/lib/node_modules/opencode-ai/bin/opencode.exe", "cd ~/app && npx opencode-ai -c", "opencode ./web",
        "opencode attach http://localhost:4096", "opencode -c", "opencode serve & opencode attach http://localhost:4096",
    ]

    @Test func everyStartIsOpencode() {
        for line in Self.starts {
            #expect(CommandClassifier.agentName(line) == "opencode", "\(line)")
            #expect(CommandClassifier.kind(of: line) == .agent, "\(line)")
            #expect(CommandClassifier.programName(line) == "opencode", "\(line)")
        }
        #expect(CommandClassifier.programLine("npx opencode-ai@latest -c") == "opencode -c")
        #expect(CommandClassifier.parse("pnpm dlx opencode-ai -s ses_1").args == ["-s", "ses_1"])
    }

    /// A package runner's version is dropped for every agent, and only a runner's word is read as a package.
    @Test func aRunnersVersionIsDroppedForEveryAgent() {
        #expect(CommandClassifier.agentName("npx @anthropic-ai/claude-code@latest") == "claude-code")
        #expect(CommandClassifier.programLine("npx @anthropic-ai/claude-code@2.1.280 --resume") == "claude-code --resume")
        #expect(CommandClassifier.kind(of: "bunx @google/gemini-cli@latest") == .agent)
        #expect(CommandClassifier.programName("/opt/tools@2/bin/make test") == "make")
        #expect(CommandClassifier.programName("pnpm dlx create-vite@latest app") == "create-vite")
        #expect(CommandClassifier.programName("pnpm install") == "pnpm" && CommandClassifier.kind(of: "yarn dlx cowsay@1 hi") == .command)
        #expect(CommandClassifier.programName("npm exec opencode-ai") == "npm") // npm's exec is not read as a runner
        // bun's `x` is bunx, and npx's `-p` names the package, not the program.
        #expect(CommandClassifier.agentName("bun x opencode-ai@latest") == "opencode")
        #expect(CommandClassifier.programName("bun x.ts") == "bun" && CommandClassifier.kind(of: "bun run dev") == .command)
        #expect(CommandClassifier.programLine("npx -p opencode-ai opencode -c") == "opencode -c")
        #expect(CommandClassifier.programLine("npx --package opencode-ai opencode serve") == "opencode serve")
    }

    /// Only an `@` after the package's last `/` starts a version: one before it is a URL's, whose credential never
    /// becomes the program's name.
    @Test func aPackageURLsCredentialIsNeverTheProgram() {
        #expect(CommandClassifier.programName("npx https://user:TOKEN@example.com/org/tool") == "tool")
        #expect(CommandClassifier.programLine("npx git+https://user:TOKEN@example.com/org/tool.git --help") == "tool.git --help")
        #expect(CommandClassifier.programName("bunx https://user:TOKEN@example.com/org/tool@1.0") == "tool")
        #expect(CommandClassifier.programName("npx @opencode/cli@2.0.26") == "opencode")
        #expect(CommandClassifier.programName("npx @scope") == "@scope")
    }

    @Test func itsServersAreCommands() {
        let servers = ["opencode serve", "opencode web --port 4096", "opencode acp", "npx opencode-ai@latest serve --port 4096",
                       "opencode --log-level DEBUG serve", "opencode2 web", "cd ~/app && opencode acp"]
        for line in servers {
            #expect(CommandClassifier.kind(of: line) == .command, "\(line)")
            #expect(CommandClassifier.agentName(line) == nil, "\(line)")
            #expect(CommandClassifier.programName(line) == "opencode", "\(line)")
        }
        #expect(CommandClassifier.kind(of: "node /usr/local/lib/node_modules/opencode-ai/bin/opencode serve") == .command)
        // Another agent's word for a subcommand is that agent's own.
        #expect(CommandClassifier.kind(of: "claude web") == .agent)
    }

    /// Any option the table says takes a value takes the next word, as OpenCode's parser does, so a server started
    /// with an option before its subcommand is still a command, and a value named like a subcommand starts none.
    @Test func aServerAfterAnOptionsValueIsACommand() {
        let servers = [
            "opencode --port 4096 serve", "opencode --hostname 0.0.0.0 web", "opencode -m x/y serve", "opencode --model x/y acp",
            "opencode --agent build web", "opencode -s ses_1 serve", "opencode --session ses_1 web", "opencode --prompt hi serve",
            "opencode --cors http://localhost:5173 web", "opencode --mdns-domain opencode.local serve", "opencode --replay-limit 200 web",
            "opencode --mini --port=4096 serve", "npx opencode-ai@latest --port 4096 serve", "npx -p opencode-ai opencode serve",
        ]
        for line in servers {
            #expect(CommandClassifier.kind(of: line) == .command, "\(line)")
            #expect(CommandClassifier.agentName(line) == nil, "\(line)")
        }
        let tuis = ["opencode -m serve", "opencode --agent web", "opencode --port 4096", "opencode run serve", "opencode -m --port 4096"]
        for line in tuis {
            #expect(CommandClassifier.kind(of: line) == .agent, "\(line)")
        }
        let argv = ["opencode", "--port", "4096", "serve"]
        #expect(CommandClassifier.kind(of: ForegroundProcess(isShell: false, name: "opencode", arguments: argv)) == .command)
        #expect(CommandClassifier.runsServer(executable: "/opt/homebrew/bin/opencode", arguments: argv))
        let node = ["node", "/usr/local/lib/node_modules/opencode-ai/bin/opencode", "--hostname", "0.0.0.0", "web"]
        #expect(CommandClassifier.runsServer(executable: "/usr/local/bin/node", arguments: node))
        #expect(!CommandClassifier.runsServer(executable: "/opt/homebrew/bin/opencode", arguments: ["opencode", "-m", "serve"]))
    }

    @Test func itsProcessesAreNamedOpencode() {
        let npm = "/usr/local/lib/node_modules/opencode-ai/bin/opencode.exe"
        let native = ForegroundProcess(isShell: false, name: "opencode.exe", arguments: [npm, "-c"], executablePath: npm)
        #expect(CommandClassifier.kind(of: native) == .agent)
        #expect(CommandClassifier.programName(of: native) == "opencode")
        #expect(CommandClassifier.agentName(executable: npm, arguments: [npm, "-c"]) == "opencode")
        let two = ForegroundProcess(isShell: false, name: "opencode2", arguments: ["opencode2"], executablePath: "/opt/homebrew/bin/opencode2")
        #expect(CommandClassifier.kind(of: two) == .agent && CommandClassifier.programName(of: two) == "opencode")
        let script = "/opt/homebrew/lib/node_modules/@opencode/cli/dist/index.js"
        #expect(CommandClassifier.agentName(executable: "/opt/homebrew/bin/node", arguments: ["node", script]) == "opencode")
        let node = ForegroundProcess(isShell: false, name: "node", arguments: ["node", script], executablePath: "/opt/homebrew/bin/node")
        #expect(CommandClassifier.kind(of: node) == .agent && CommandClassifier.programName(of: node) == "opencode")
    }

    @Test func itsServerProcessesAreCommands() {
        let serve = ForegroundProcess(isShell: false, name: "opencode", arguments: ["opencode", "serve"])
        #expect(CommandClassifier.kind(of: serve) == .command)
        #expect(CommandClassifier.programName(of: serve) == "opencode")
        let wrapper = ForegroundProcess(isShell: false, name: "node", arguments: ["node", "/usr/local/bin/opencode", "web", "--port", "4096"],
                                        executablePath: "/usr/local/bin/node")
        #expect(CommandClassifier.kind(of: wrapper) == .command)
        #expect(CommandClassifier.runsServer(executable: "/usr/local/bin/node", arguments: wrapper.arguments))
        let acp = ForegroundProcess(isShell: false, name: "opencode", arguments: ["opencode", "--print-logs", "acp"])
        #expect(CommandClassifier.kind(of: acp) == .command)
        for tui in [["opencode"], ["opencode", "-c"], ["opencode", "attach", "http://localhost:4096"]] {
            let process = ForegroundProcess(isShell: false, name: "opencode", arguments: tui)
            #expect(CommandClassifier.kind(of: process) == .agent, "\(tui)")
            #expect(!CommandClassifier.runsServer(executable: "", arguments: tui), "\(tui)")
        }
        // A server's tools still call as OpenCode, so the process is named for whoever asks which agent calls.
        #expect(CommandClassifier.agentName(executable: "/usr/local/bin/opencode", arguments: ["opencode", "acp"]) == "opencode")
    }

    /// With the shell integration, polling upgrades a command to an agent only for an agent's TUI, never for a server.
    @Test func anIntegratedServerTabStaysACommand() {
        var server = TabStatus()
        server.commandStarted("opencode serve", at: 0)
        #expect(server.kind == .command && server.program == "opencode")
        server.observe(ForegroundProcess(isShell: false, name: "opencode", arguments: ["opencode", "serve"]), at: 1)
        #expect(server.kind == .command)
        var function = TabStatus()
        function.commandStarted("ocs", at: 0)
        function.observe(ForegroundProcess(isShell: false, name: "opencode", arguments: ["opencode", "web"]), at: 1)
        #expect(function.kind == .command)
        var tui = TabStatus()
        tui.commandStarted("oc", at: 0)
        tui.observe(ForegroundProcess(isShell: false, name: "opencode", arguments: ["opencode"]), at: 1)
        #expect(tui.kind == .agent && tui.program == "opencode")
        var npx = TabStatus()
        npx.commandStarted("npx opencode-ai@latest", at: 0)
        #expect(npx.kind == .agent && npx.program == "opencode")
    }
}

@Suite struct TabStatusTests {
    @Test func startupCommandsAreNotCommandsRun() {
        var s = TabStatus()
        s.observe(ForegroundProcess(isShell: false, name: "mkdir"), at: 0) // a theme's mkdir as the shell starts
        s.observe(ForegroundProcess(isShell: true, name: "zsh"), at: 0.5)
        #expect(s.commandsStarted == 1)
        s.commandFinished(exitCode: 0, at: 1) // the first prompt
        #expect(s.commandsRun == 0)
        s.commandStarted("ls", at: 2)
        s.commandFinished(exitCode: 0, at: 3)
        #expect(s.commandsRun == 1)
        var plain = TabStatus() // no integration: every command polling sees counts
        plain.observe(ForegroundProcess(isShell: false, name: "vim"), at: 0)
        #expect(plain.commandsRun == 1)
    }

    @Test func commandInBackgroundTabFinishesDone() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        #expect(s.running && s.state == .idle) // plain commands show no spinner
        s.commandFinished(exitCode: 0, at: 10)
        #expect(s.state == .done)
        #expect(s.takeNotice() == TabNotice(state: .done, command: "make", program: "make", kind: .command, stillRunning: false, duration: 10))
        #expect(s.takeNotice() == nil)
        s.setVisible(true)
        #expect(s.state == .idle)
    }

    @Test func runningSinceItsStart() {
        var s = TabStatus()
        #expect(s.runningSince == nil)
        s.commandStarted("claude", at: 12)
        #expect(s.runningSince == 12)
        s.commandFinished(exitCode: 0, at: 40)
        #expect(s.runningSince == nil)
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
        s.bell(at: 60)
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
        #expect(s.running && s.state == .idle)
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
        #expect(s.takeNotice() == TabNotice(state: .done, command: "claude", program: "claude", kind: .agent, stillRunning: true, duration: 7))
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
        #expect(s.state == .idle) // only agents show working
        s.tick(at: 10)
        #expect(s.state == .idle)
        s.commandFinished(exitCode: 0, at: 60)
        #expect(s.state == .idle)
        #expect(s.takeNotice() == nil)
    }

    @Test func attentionOutranksAndSurvivesDone() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        s.bell(at: 0.5)
        #expect(s.state == .attention)
        s.commandFinished(exitCode: 0, at: 1)
        #expect(s.state == .attention)
        s.setVisible(true)
        #expect(s.state == .idle)
    }

    /// Next Term's own call to a hidden tab outlasts the next command: starting one clears only done and failed, so the
    /// tab reads attention (as list_tabs and the update's save report it) until someone looks at it.
    @Test func attentionSurvivesANewCommand() {
        var s = TabStatus()
        s.needsAttention()
        s.commandStarted("sleep 600", at: 0)
        #expect(s.running && s.state == .attention)
        s.setVisible(true)
        s.setVisible(false)
        #expect(s.state == .idle && s.running && s.command == "sleep 600")
    }

    @Test func fallbackPollingWithoutIntegration() {
        var s = TabStatus()
        s.observe(ForegroundProcess(isShell: true, name: "bash"), at: 0)
        #expect(s.state == .idle)
        s.observe(ForegroundProcess(isShell: false, name: "sleep", arguments: ["sleep", "8"]), at: 1)
        #expect(s.running)
        #expect(s.program == "sleep")
        s.observe(nil, at: 5) // unreadable foreground (a pipeline's leader exited): keep the state
        #expect(s.running)
        s.observe(ForegroundProcess(isShell: true, name: "bash"), at: 9)
        #expect(s.state == .done)
        #expect(s.takeNotice()?.state == .done)
    }

    @Test func fallbackSeesWrapperProcesses() {
        var s = TabStatus()
        s.observe(ForegroundProcess(isShell: false, name: "sudo", arguments: ["sudo", "make", "install"]), at: 0)
        #expect(s.running)
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
        #expect(s.kind == .command && s.running)
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
        s.bell(at: 0)
        let notice = s.takeNotice()
        #expect(notice?.state == .attention && notice?.fromProgram == true && notice?.topic == .programAlert)
        for _ in 0..<500 { s.bell(at: 0) }
        #expect(s.takeNotice() == nil)
        s.setVisible(true)
        s.setVisible(false)
        s.bell(at: 0)
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
        #expect(s.running)
    }

    /// An agent whose own footer says it waits (OpenCode): its startup drawing is not a turn.
    @Test func theFirstReadyEndsStartupWithoutANotice() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        for t in stride(from: 0.0, through: 6, by: 0.25) {
            s.output(at: t)
            s.tick(at: t)
        }
        #expect(s.state == .working && !s.screenSynced) // output timing, until the screen speaks
        s.observe(agentScreen: .ready, at: 6.25)
        #expect(s.state == .idle)
        for t in stride(from: 6.5, through: 14, by: 0.25) {
            s.output(at: t) // it goes on drawing: output timing may call it working, but no turn of its own ends
            s.observe(agentScreen: .ready, at: t)
            s.tick(at: t)
        }
        s.tick(at: 17)
        #expect(s.state == .idle && s.unseen == nil && s.takeNotice() == nil)
    }

    /// A release whose working hint the table lacks draws its footer while it works too (OpenCode 2.x's prompt footer
    /// is the same busy or not): until its working hint has shown, output timing says when it works, and no done.
    @Test func beforeItsWorkingHintTheFooterLeavesOutputTimingOn() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .ready, at: 1)
        for t in stride(from: 5.0, through: 30, by: 0.25) {
            s.output(at: t)
            s.observe(agentScreen: .ready, at: t)
            s.tick(at: t)
        }
        #expect(s.state == .working && !s.screenSynced)
        for t in stride(from: 30.25, through: 34, by: 0.25) {
            s.observe(agentScreen: .ready, at: t)
            s.tick(at: t)
        }
        #expect(s.state == .idle && s.unseen == nil && s.takeNotice() == nil)
        // A question syncs the tab with its screen, and the footer while it works after the answer unsyncs it.
        s.observe(agentScreen: .asking("Permission required: $ npm test"), at: 40)
        #expect(s.state == .attention && s.screenSynced)
        s.observe(agentScreen: .ready, at: 42)
        s.output(at: 42.5)
        #expect(s.question == nil && s.state == .working && !s.screenSynced)
        // Its working hint, once: from then on the footer alone is a finish.
        s.observe(agentScreen: .working, at: 50)
        s.observe(agentScreen: .ready, at: 70)
        s.tick(at: 71)
        #expect(s.state == .done && s.takeNotice()?.topic == .agentFinished)
    }

    /// OpenCode showing none of its shapes once its footer has been seen (a sub-agent's session, which has a footer of
    /// its own): nothing to go by, so the tab stays as it was, never "done" while OpenCode may still work.
    @Test func noneOfItsShapesKeepsTheState() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .ready, at: 1)
        s.observe(agentScreen: .working, at: 2)
        s.observe(agentScreen: .idle, at: 10)
        s.tick(at: 20)
        #expect(s.state == .working && s.takeNotice() == nil)
        s.observe(agentScreen: .ready, at: 30)
        s.tick(at: 31)
        #expect(s.state == .done && s.takeNotice()?.duration == 28)
        // Every other agent: no hint is a stop, as before.
        var claude = TabStatus()
        claude.commandStarted("claude", at: 0)
        claude.observe(agentScreen: .working, at: 1)
        claude.observe(agentScreen: .idle, at: 10)
        claude.tick(at: 11)
        #expect(claude.state == .done)
    }

    /// Every new reading of OpenCode's question is a new question with a new number, so an id held for one request never
    /// answers another, even when OpenCode swaps requests under the same prompt. OpenCode 2.x replaces a shell request's
    /// command with what "Always allow" saves while that button is selected: a new question too, with no second notice.
    @Test func everyRequestReadIsItsOwnQuestion() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .working, at: 1)
        s.observe(agentScreen: .asking("Permission required: $ npm test"), at: 10)
        let serial = s.questionSerial
        #expect(s.takeNotice()?.question == "Permission required: $ npm test")
        // The selection moved onto "Always allow": its words and number change, and no new notice.
        s.observe(agentScreen: .asking("Permission required: This will always allow shell for this project."), at: 11)
        #expect(s.question == "Permission required: This will always allow shell for this project.")
        #expect(s.questionSerial == serial + 1 && s.takeNotice() == nil)
        // Back off it, the command shown may be another request's: a new question, with its notice.
        s.observe(agentScreen: .asking("Permission required: $ rm -rf build"), at: 12)
        #expect(s.question == "Permission required: $ rm -rf build" && s.questionSerial == serial + 2)
        #expect(s.takeNotice()?.question == "Permission required: $ rm -rf build")
        // The header alone is another question, never the one read before.
        s.observe(agentScreen: .asking("Permission required: Edit src/a.ts"), at: 13)
        s.observe(agentScreen: .asking("Permission required"), at: 14)
        #expect(s.question == "Permission required" && s.questionSerial == serial + 4)
        #expect(s.takeNotice()?.question == "Permission required")
    }

    @Test func workThenReadyIsAFinish() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .ready, at: 1)
        s.observe(agentScreen: .working, at: 2)
        #expect(s.state == .working)
        s.observe(agentScreen: .ready, at: 42)
        s.tick(at: 42)
        #expect(s.state == .done && s.takeNotice() == nil) // held for a second
        s.observe(agentScreen: .ready, at: 43)
        s.tick(at: 43)
        let notice = s.takeNotice()
        #expect(notice?.duration == 40 && notice?.stillRunning == true && notice?.topic == .agentFinished)
        // Back to work before the second is up: the same turn.
        s.observe(agentScreen: .working, at: 50)
        s.observe(agentScreen: .ready, at: 60)
        s.observe(agentScreen: .working, at: 60.5)
        s.tick(at: 62)
        #expect(s.takeNotice() == nil && s.state == .working)
    }

    @Test func aQuestionAfterWorkAndItsAnswer() {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .working, at: 1)
        s.observe(agentScreen: .asking("Permission required: Shell command ($ npm test)"), at: 10)
        #expect(s.state == .attention)
        let notice = s.takeNotice()
        #expect(notice?.question == "Permission required: Shell command ($ npm test)" && notice?.topic == .decision)
        s.observe(agentScreen: .working, at: 12) // answered
        #expect(s.question == nil && s.state == .working)
        // Answered and done at once: the question goes, and the stop notifies as any.
        s.observe(agentScreen: .asking("Always allow: This will allow bash until OpenCode is restarted."), at: 20)
        _ = s.takeNotice()
        s.observe(agentScreen: .ready, at: 21)
        #expect(s.question == nil && s.state == .idle)
    }

    @Test func aProgramsNoticeCarriesItsWords() {
        var s = TabStatus()
        s.bell(notice: ProgramNotice(title: "Fix the login test", body: "Session error"), at: 0)
        let notice = s.takeNotice()
        #expect(notice?.message == "Session error" && notice?.fromProgram == true && notice?.topic == .programAlert)
        s.setVisible(true)
        s.setVisible(false)
        s.bell(at: 1)
        let bare = s.takeNotice()
        #expect(bare?.state == .attention && bare?.message == nil)
    }

    @Test func aProgramsNoticeAfterADecisionAddsNothing() {
        // The decision's amber mark is attention already: the program's vaguer notice never replaces it.
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .working, at: 1)
        s.observe(agentScreen: .asking("Permission required: Shell command ($ npm test)"), at: 10)
        #expect(s.takeNotice()?.topic == .decision)
        s.bell(notice: ProgramNotice(title: nil, body: "Permission needs input"), at: 11)
        #expect(s.takeNotice() == nil && s.question == "Permission required: Shell command ($ npm test)")
        s.tick(at: 14)
        #expect(s.takeNotice() == nil)
    }

    /// An OpenCode tab whose screen Next Term reads: started at 0, working from 1.
    private func readOpencode() -> TabStatus {
        var s = TabStatus()
        s.commandStarted("opencode", at: 0)
        s.observe(agentScreen: .working, at: 1)
        return s
    }

    @Test func anAgentsWordsBeforeItsQuestionGiveWayToTheDecision() {
        // OpenCode sends "Permission needs input" as it asks, before Next Term's next look at its screen: one notice.
        var s = readOpencode()
        s.bell(notice: ProgramNotice(title: nil, body: "Permission needs input"), at: 10)
        #expect(s.takeNotice() == nil && s.state == .working) // the screen gives the mark
        s.observe(agentScreen: .asking("Permission required: Shell command ($ npm test)"), at: 10.4)
        #expect(s.takeNotice()?.topic == .decision)
        for now: TimeInterval in [11, 12.5, 15, 25] { s.tick(at: now) }
        #expect(s.takeNotice() == nil && s.state == .attention)
    }

    @Test func anAgentsWordsBeforeItsFinishAreTheFinishs() {
        // "Session error" as the turn ends: one notice, the finish's, in the agent's words. The mark is done, not amber.
        var s = readOpencode()
        s.bell(notice: ProgramNotice(title: "Fix the login test", body: "Session error"), at: 20)
        s.tick(at: 20.25)
        #expect(s.takeNotice() == nil && s.state == .working)
        s.observe(agentScreen: .ready, at: 20.5)
        s.tick(at: 21)
        #expect(s.takeNotice() == nil)
        s.tick(at: 21.5)
        let finish = s.takeNotice()
        #expect(finish?.topic == .agentFinished && finish?.message == "Session error" && finish?.duration == 19.5)
        s.tick(at: 23)
        #expect(s.takeNotice() == nil && s.state == .done && s.question == nil)
        // A late look at the screen: the words wait for the stop that is settling.
        var late = readOpencode()
        late.bell(notice: ProgramNotice(title: nil, body: "Session error"), at: 20)
        late.observe(agentScreen: .ready, at: 21.9)
        late.tick(at: 22.25)
        #expect(late.takeNotice() == nil)
        late.tick(at: 23)
        #expect(late.takeNotice()?.message == "Session error" && late.state == .done)
    }

    @Test func aShortTurnsWordsGoOutOnTheirOwn() {
        // A turn too short for a finish notice: the agent's own notice goes out once the stop has settled. Still no amber.
        var s = readOpencode()
        s.bell(notice: ProgramNotice(title: nil, body: "Session error"), at: 3)
        s.observe(agentScreen: .ready, at: 3.3)
        s.tick(at: 4.5)
        let words = s.takeNotice()
        #expect(words?.topic == .programAlert && words?.message == "Session error" && s.state == .done)
    }

    @Test func wordsTheScreenIsLateForStayWithTheTurn() {
        // The screen still shows work when the wait is over: the words go out alone, and the finish that follows takes them
        // too (the app drops it, the same words again). The next turn's finish has none.
        var s = readOpencode()
        s.bell(notice: ProgramNotice(title: nil, body: "Session error"), at: 20)
        s.tick(at: 21.75)
        #expect(s.takeNotice() == nil)
        s.tick(at: 22)
        #expect(s.takeNotice()?.message == "Session error")
        s.observe(agentScreen: .ready, at: 23)
        s.tick(at: 24)
        #expect(s.takeNotice()?.message == "Session error")
        s.observe(agentScreen: .working, at: 30)
        s.observe(agentScreen: .ready, at: 50)
        s.tick(at: 51)
        let next = s.takeNotice()
        #expect(next?.topic == .agentFinished && next?.message == nil)
    }

    @Test func wordsAsTheStopSettlesOrAfterItAreNoAmber() {
        // The screen showed the stop first: the words still go with its notice while it settles.
        var s = readOpencode()
        s.observe(agentScreen: .ready, at: 20)
        s.bell(notice: ProgramNotice(title: nil, body: "Session done"), at: 20.3)
        s.tick(at: 21)
        let finish = s.takeNotice()
        #expect(finish?.topic == .agentFinished && finish?.message == "Session done" && s.state == .done)
        // After a finish that went out, the words go out alone (the app drops them, so soon after its own), and the mark
        // stays done.
        s.observe(agentScreen: .working, at: 30)
        s.observe(agentScreen: .ready, at: 40)
        s.tick(at: 41)
        #expect(s.takeNotice()?.topic == .agentFinished)
        s.bell(notice: ProgramNotice(title: nil, body: "Session done"), at: 41.2)
        s.tick(at: 43.25)
        #expect(s.takeNotice()?.topic == .programAlert && s.state == .done)
    }

    @Test func anAgentsWordsNotifyOnceUntilSeenOrItWorksAgain() {
        var s = readOpencode()
        s.bell(notice: ProgramNotice(title: nil, body: "Session error"), at: 10)
        s.bell(notice: ProgramNotice(title: nil, body: "Model stopped responding"), at: 10.1)
        s.tick(at: 12)
        #expect(s.takeNotice()?.message == "Session error")
        for now in stride(from: 12.25, to: 20, by: 0.25) {
            s.bell(notice: ProgramNotice(title: nil, body: "again"), at: now)
            s.tick(at: now)
        }
        #expect(s.takeNotice() == nil)
        s.setVisible(true)
        s.setVisible(false)
        s.bell(notice: ProgramNotice(title: nil, body: "again"), at: 30)
        s.tick(at: 32)
        #expect(s.takeNotice()?.message == "again")
    }

    @Test func anAgentsWordsWhileSeenOrBeforeItsScreenIsRead() {
        // Seen: nothing, and words held when the tab is looked at go too.
        var s = readOpencode()
        s.setVisible(true)
        s.bell(notice: ProgramNotice(title: nil, body: "Session done"), at: 5)
        s.tick(at: 8)
        #expect(s.takeNotice() == nil)
        s.setVisible(false)
        s.bell(notice: ProgramNotice(title: nil, body: "Session done"), at: 10)
        s.setVisible(true)
        s.setVisible(false)
        s.tick(at: 13)
        #expect(s.takeNotice() == nil)
        // Before its screen has shown a hint, the agent's words are a program's notice as before: at once, and amber.
        var early = TabStatus()
        early.commandStarted("opencode", at: 0)
        early.bell(notice: ProgramNotice(title: nil, body: "Session error"), at: 1)
        #expect(early.takeNotice()?.message == "Session error" && early.state == .attention)
        // A bell with no words keeps its way in a tab whose screen is read (AgentScreenTests): at once, and amber.
        var rang = readOpencode()
        rang.bell(at: 10)
        #expect(rang.takeNotice()?.topic == .programAlert && rang.state == .attention)
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
