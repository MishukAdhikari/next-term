import Foundation
import Testing
@testable import NextTermCore

@Suite struct RemoteHostTests {
    @Test func destinationsThatSshCouldReadAsOptionsOrCommandsAreRefused() {
        #expect(RemoteHost.destinationProblem("deploy@203.0.113.5") == nil)
        #expect(RemoteHost.destinationProblem("web-1") == nil)
        #expect(RemoteHost.destinationProblem("root@2001:db8::1") == nil)
        // OpenSSH takes no brackets in a destination, and a port belongs in its own field.
        #expect(RemoteHost.destinationProblem("root@[2001:db8::1]") != nil)
        #expect(RemoteHost.destinationProblem("-oProxyCommand=touch%20x") != nil)
        #expect(RemoteHost.destinationProblem("host;rm -rf ~") != nil)
        #expect(RemoteHost.destinationProblem("host other") != nil)
        #expect(RemoteHost.destinationProblem("$(id)") != nil)
        #expect(RemoteHost.destinationProblem("") != nil)
        // A port after a colon is not a destination ssh understands.
        #expect(RemoteHost.destinationProblem("me@web:2222") != nil)
        #expect(RemoteHost.destinationProblem("web:2222") != nil)
    }

    @Test func foldersMustBeAbsoluteOrHomeRelativeWithoutControlCharacters() {
        #expect(RemoteHost.directoryProblem("~") == nil)
        #expect(RemoteHost.directoryProblem("~/app") == nil)
        #expect(RemoteHost.directoryProblem("/srv/my app") == nil)
        #expect(RemoteHost.directoryProblem("app") != nil)
        #expect(RemoteHost.directoryProblem("/srv/a\nb") != nil)
        #expect(RemoteHost.directoryProblem("") != nil)
    }

    @Test func savedHostsRoundTripAndBadOnesAreDropped() {
        let good = RemoteHost(id: "abc", name: "web", destination: "me@web", port: 2222, directory: "~/app", keep: .herdr)
        var bad = good
        bad.id = "bad"
        bad.destination = "-oX"
        let decoded = RemoteHost.decodeList(RemoteHost.encodeList([good, bad]))
        #expect(decoded == [good])
        #expect(RemoteHost.decodeList(Data("garbage".utf8)).isEmpty)
        #expect(RemoteHost.decodeList(nil).isEmpty)
    }
}

@Suite struct SSHArgumentsTests {
    let host = RemoteHost(id: "h", name: "web", destination: "me@web", port: 2222, directory: "~", keep: .tmux)

    @Test func theDestinationComesAfterDoubleDashAndTheCommandIsOneArgument() throws {
        let args = SSHArguments.tab(host, controlPath: "/x/ssh/abc", command: "echo hi")
        let dash = try #require(args.firstIndex(of: "--"))
        #expect(args[dash + 1] == "me@web")
        #expect(args[dash + 2] == "echo hi")
        #expect(args.count == dash + 3)
        #expect(args.contains("-t"))
        #expect(args.contains("EscapeChar=none"))
        #expect(args.contains("ControlPath=\"/x/ssh/abc\""))
        #expect(args.contains("ClearAllForwardings=yes"))
        #expect(args.firstIndex(of: "-p").map { args[$0 + 1] } == "2222")
        // Nothing is forwarded, by flag or by option.
        #expect(!args.contains("-R") && !args.contains("-L") && !args.contains("-A"))
    }

    @Test func backgroundCommandsOnlyRideAnOpenMasterAndNeverLogIn() {
        let args = SSHArguments.exec(host, controlPath: "/x/abc", configFile: "/x/ssh_config", command: "true")
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("-T"))
        // No master of their own, and no fallback login if the master refuses the session.
        #expect(args.contains("ControlMaster=no") && !args.contains("ControlMaster=auto"))
        #expect(args.contains("ProxyCommand=/usr/bin/false"))
        #expect(args.prefix(2) == ["-F", "/x/ssh_config"])
    }

    @Test func tabsAskAboutHostKeysWhateverTheUsersConfigSays() {
        let args = SSHArguments.tab(host, controlPath: "/x/abc", configFile: "/x/ssh_config", command: "true")
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("ControlMaster=auto"))
        // ProxyJump hops get the same rule through the -F config, which then reads the user's own.
        #expect(SSHArguments.configText.contains("StrictHostKeyChecking ask"))
        let lines = SSHArguments.configText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.firstIndex(of: "StrictHostKeyChecking ask")! < lines.firstIndex(of: "Include ~/.ssh/config")!)
        // The user's config before the system's, as ssh itself reads them (the first value wins).
        #expect(lines.firstIndex(of: "Include ~/.ssh/config")! < lines.firstIndex(of: "Include /etc/ssh/ssh_config")!)
        #expect(lines.contains("Include /etc/ssh/ssh_config"))
    }

    @Test func controlNamesAreShortStableAndPerDestination() {
        var other = host
        other.port = 22
        #expect(SSHArguments.controlName(host) == SSHArguments.controlName(host))
        #expect(SSHArguments.controlName(host) != SSHArguments.controlName(other))
        #expect(SSHArguments.controlName(host).count <= 16)
    }
}

@Suite struct RemoteShellTests {
    /// Runs a remote command line the way sshd does: through a login shell's `-c`.
    func run(_ command: String, home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func temporaryHome() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func theCommandLineHoldsOnlyFixedTextAndBase64() {
        let script = "echo '$(touch /tmp/pwned)'; `id`; \"; rm -rf ~"
        let line = RemoteShell.command(script)
        #expect(!line.contains("pwned"))
        #expect(!line.contains("`"))
        let encoded = Data(script.utf8).base64EncodedString()
        #expect(line.contains(encoded))
        #expect(line.hasPrefix("exec /bin/sh -c '"))
    }

    @Test func scriptsRunUnchangedThroughALoginShell() throws {
        let home = try temporaryHome()
        let tricky = "it's a \"test\" with $(dollars) and `ticks`; and \\ backslashes"
        let output = try run(RemoteShell.command("printf '%s\\n' \(RemoteShell.quote(tricky))"), home: home)
        #expect(output == tricky + "\n")
    }

    @Test func foldersExpandHomeAndKeepOddNames() throws {
        let home = try temporaryHome()
        try FileManager.default.createDirectory(atPath: home + "/my app's dir", withIntermediateDirectories: true)
        #expect(try run(RemoteShell.command("cd \(RemoteShell.folder("~/my app's dir")) && pwd"), home: home)
                    .hasSuffix("/my app's dir\n"))
        #expect(try run(RemoteShell.command("cd \(RemoteShell.folder("~")) && pwd"), home: home).hasSuffix(home + "\n"))
    }

    @Test func safeNamesKeepOnlyLettersDigitsDashAndUnderscore() {
        #expect(RemoteShell.safeName("nt-app-1a2b3c") == "nt-app-1a2b3c")
        #expect(RemoteShell.safeName("a;b$(c) d'e") == "abcde")
        let name = RemoteShell.newSessionName(directory: "/srv/My App!")
        #expect(name.hasPrefix("nt-my-app-"))
        #expect(RemoteShell.safeName(name) == name)
    }

    @Test func aMissingFolderIsSaidAndMarkedAndTheTabOpensInHome() throws {
        let home = try temporaryHome()
        let script = RemoteShell.tabScript(keep: .off, directory: "~/nope", session: "s", tabID: "tab2")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "pwd")
        let output = try run(RemoteShell.command(script), home: home)
        #expect(output.contains("is not a folder on this host"))
        #expect(output.hasSuffix(home + "\n"))
        #expect(FileManager.default.fileExists(atPath: home + "/.cache/next-term/tabs/tab2.nodir"))
    }

    @Test func theTokenFallsBackToAPrivateTmpFolderWhenTheCacheCannotBeWritten() throws {
        let home = try temporaryHome()
        // ~/.cache is a file: nothing can be written under it.
        FileManager.default.createFile(atPath: home + "/.cache", contents: Data())
        let key = "tab-\(UUID().uuidString.prefix(8))"
        let script = RemoteShell.tabScript(keep: .off, directory: "~", session: "s", tabID: key, token: "tok3n")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "exit 0")
        _ = try run(RemoteShell.command(script), home: home)
        let poll = try #require(RemotePoll.parse(try run(RemoteShell.command(RemoteShell.pollScript(tabs: [(id: key, keep: .off, session: "")])), home: home)))
        #expect(poll.tabs[key]?.token == "tok3n")
        try? FileManager.default.removeItem(atPath: "/tmp/nt-\(getuid())-tabs/\(key)")
    }

    @Test func aTmuxTabWithoutTmuxMarksItselfPlain() throws {
        let home = try temporaryHome()
        let script = RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "tab3")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "exit 0")
        let output = try run(RemoteShell.command(script), home: home)
        #expect(output.contains("tmux is not installed"))
        #expect(FileManager.default.fileExists(atPath: home + "/.cache/next-term/tabs/tab3.plain"))
    }

    @Test func anOffTabRecordsItsShellPidAndStartsALoginShell() throws {
        let home = try temporaryHome()
        let script = RemoteShell.tabScript(keep: .off, directory: "~", session: "s", tabID: "tab1", token: "t0k3n")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "echo started")
        let output = try run(RemoteShell.command(script), home: home)
        #expect(output.contains("started"))
        let fields = try String(contentsOfFile: home + "/.cache/next-term/tabs/tab1", encoding: .utf8).split(separator: " ")
        #expect(Int(fields.first ?? "") != nil)
        #expect(fields.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "t0k3n")
    }

    @Test func tmuxAndHerdrTabsFallBackToAPlainShellWhenNotInstalled() {
        let tmux = RemoteShell.tabScript(keep: .tmux, directory: "/srv/app", session: "nt-app-123456", tabID: "t")
        #expect(tmux.contains("-L nextterm"))
        #expect(tmux.contains("new-session -A -s 'nt-app-123456'"))
        #expect(tmux.contains("tmux is not installed"))
        let herdr = RemoteShell.tabScript(keep: .herdr, directory: "~", session: "x", tabID: "t")
        #expect(herdr.contains("never installs it"))
        #expect(!herdr.contains("curl") && !herdr.contains("install.sh"))
    }

    @Test func thePollFindsTheForegroundOfARealShell() throws {
        // A real "tab": sh records its pid the way tabScript does, then runs sleep in front (job control on).
        let home = try temporaryHome()
        try FileManager.default.createDirectory(atPath: home + "/.cache/next-term/tabs", withIntermediateDirectories: true)
        let script = RemoteShell.pollScript(tabs: [(id: "tab1", keep: .off, session: "")])
        // Without a pid file the tab is unknown.
        let unknown = try #require(RemotePoll.parse(try run(RemoteShell.command(script), home: home)))
        #expect(unknown.tabs["tab1"]?.foreground == nil)
        // The poll's own process: its pid file names a live process with no terminal (tpgid -1 or 0).
        try "\(getpid()) abc123\n".write(toFile: home + "/.cache/next-term/tabs/tab1", atomically: true, encoding: .utf8)
        let poll = try #require(RemotePoll.parse(try run(RemoteShell.command(script), home: home)))
        #expect(poll.tabs["tab1"]?.token == "abc123")
    }
}

@Suite struct RemoteParsingTests {
    @Test func pollLinesBecomeForegroundsAndFolders() throws {
        let output = """
            Welcome to Ubuntu 24.04
            \(RemoteShell.marker)
            a1\tshell
            a1\tdir\t/srv/app
            b2\tfg\tclaude\tclaude --resume abc
            c3\tfg\tnode\tnode /home/me/.npm/@anthropic-ai/claude-code/cli.js
            d4\t?
            e5\tfg\t-bash\t-bash
            f6\tplain
            f6\tnodir
            f6\tshell
            f6\tup\t0123abcd
            f6\tjobs\t2\tsleep (running);vim (suspended);
            """
        let poll = try #require(RemotePoll.parse(output))
        #expect(poll.tabs["a1"]?.foreground?.isShell == true)
        #expect(poll.tabs["a1"]?.directory == "/srv/app")
        let claude = try #require(poll.tabs["b2"]?.foreground)
        #expect(CommandClassifier.kind(of: claude) == .agent)
        #expect(CommandClassifier.programName(of: claude) == "claude")
        let npm = try #require(poll.tabs["c3"]?.foreground)
        #expect(CommandClassifier.kind(of: npm) == .agent)
        #expect(poll.tabs["d4"]?.foreground == nil)
        #expect(poll.tabs["e5"]?.foreground?.name == "bash")
        #expect(poll.tabs["d4"]?.started == false && poll.tabs["b2"]?.started == true)
        #expect(poll.tabs["f6"]?.plain == true && poll.tabs["f6"]?.folderMissing == true && poll.tabs["f6"]?.started == true)
        #expect(poll.tabs["f6"]?.token == "0123abcd")
        #expect(poll.tabs["f6"]?.jobs == 2 && poll.tabs["f6"]?.jobSummary == "sleep (running)\nvim (suspended)")
        #expect(RemotePoll.parse("no marker at all") == nil)
    }

    @Test func theMarkerIsFoundAfterNoiseWithoutANewlineAndInCRLFOutput() throws {
        let noisy = "Last login: today" + RemoteShell.marker + "\r\na1\tshell\r\na1\tup\tabc\r\n"
        let poll = try #require(RemotePoll.parse(noisy))
        #expect(poll.tabs["a1"]?.foreground?.isShell == true)
        #expect(poll.tabs["a1"]?.token == "abc")
    }

    @Test func aHostCannotForgeLinesThroughAFolderNameWithANewline() throws {
        // The poll prints what a host reports through nt_clean: run it the way a host would.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-forge-\(UUID().uuidString)").path
        let evil = home + "/x\nb2\tfg\tclaude\tclaude"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        let script = RemoteShell.pollScript(tabs: []) + "\nd=$(nt_clean \(RemoteShell.quote(evil)) 1024); printf 'a1\\tdir\\t%s\\n' \"$d\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteShell.command(script)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let poll = try #require(RemotePoll.parse(String(decoding: data, as: UTF8.self)))
        #expect(poll.tabs["b2"] == nil)
        #expect(poll.tabs["a1"]?.directory?.contains("b2") == true)
    }

    @Test func herdrAgentsParseFromEitherShapeAndIgnoreUnknownFields() throws {
        let agents = """
            [{"pane_id":"w1:p1","agent":"claude","agent_status":"working","future_field":1},
             {"pane_id":"w1:p2","name":"reviewer","agent":"codex","agent_status":"blocked","cwd":"/srv/app"},
             {"pane_id":"w2:p1","agent":"gemini","agent_status":"something-new"}]
            """
        let wrapped = try #require(HerdrAgent.parseList("{\"id\":\"1\",\"result\":{\"type\":\"agent_list\",\"agents\":\(agents)}}"))
        let bare = try #require(HerdrAgent.parseList("{\"agents\":\(agents)}"))
        #expect(wrapped == bare)
        #expect(wrapped.map(\.status) == [.working, .blocked, .unknown])
        #expect(wrapped[1].name == "reviewer")
        #expect(wrapped[1].directory == "/srv/app")
        #expect(HerdrAgent.parseList("not json") == nil)
    }

    @Test func herdrAgentsBecomeOneTabActivity() {
        func agent(_ status: HerdrAgent.Status, _ name: String = "claude") -> HerdrAgent {
            HerdrAgent(paneID: "p", name: name, status: status)
        }
        #expect(HerdrAgent.activity([agent(.idle), agent(.working)]) == .working)
        #expect(HerdrAgent.activity([agent(.done)]) == .idle)
        #expect(HerdrAgent.activity([]) == .idle)
        guard case .asking(let question) = HerdrAgent.activity([agent(.working), agent(.blocked, "codex"), agent(.blocked)]) else {
            Issue.record("blocked should ask")
            return
        }
        #expect(question.contains("codex"))
        #expect(question.contains("1 more"))
    }

    @Test func aHerdrTabFollowsWhatHerdrReports() {
        var status = TabStatus()
        status.observeAgentHost("herdr", at: 0)
        #expect(status.kind == .agent && status.running)
        // herdr's own UI redrawing is not work.
        status.output(at: 1)
        #expect(status.state == .idle)
        status.observe(agentScreen: .working, at: 2)
        #expect(status.state == .working)
        status.observe(agentScreen: .asking("codex (w1:p2) needs a decision"), at: 3)
        #expect(status.state == .attention)
        #expect(status.question == "codex (w1:p2) needs a decision")
        // Seen again: no new start, no lost state.
        status.observeAgentHost("herdr", at: 4)
        #expect(status.question != nil)
    }

    @Test func probeAndSessionsParse() throws {
        let output = """
            motd
            \(RemoteShell.marker)
            os\tLinux x86_64
            shell\t/bin/bash
            home\t/home/me
            tmux\ttmux 3.4
            herdr\therdr 0.9.3
            git\tgit version 2.43.0
            agent\tclaude
            agent\tcodex
            linger\tno
            session\tnt-app-1a2b3c\t1\t/srv/app\tclaude
            """
        let probe = try #require(RemoteProbe.parse(output))
        #expect(probe.os == "Linux x86_64")
        #expect(probe.tmuxUsable)
        #expect(probe.herdr == "herdr 0.9.3")
        #expect(probe.agents == ["claude", "codex"])
        #expect(probe.linger == "no")
        #expect(probe.sessions.first?.name == "nt-app-1a2b3c")
        #expect(probe.sessions.first?.attached == 1)

        var old = RemoteProbe()
        old.tmux = "tmux 3.0a"
        #expect(!old.tmuxUsable)
        old.tmux = "tmux next-3.5"
        #expect(old.tmuxUsable)

        let listed = try #require(RemoteSession.parseList("\(RemoteShell.marker)\nsession\tnt-x-1\t0\t/srv\tzsh\n\(RemoteShell.herdrMarker)\n{\"agents\":[]}\n"))
        #expect(listed.sessions.map(\.name) == ["nt-x-1"])
        #expect(listed.herdr == [])
    }

    @Test func changesSplitIntoStatusStatAndDiff() throws {
        let output = """
            \(RemoteShell.marker)
            ## main...origin/main [ahead 1]
             M app/User.php
            ?? notes.md
            \(RemoteShell.statMarker)
             app/User.php | 2 +-
             1 file changed, 1 insertion(+), 1 deletion(-)
            \(RemoteShell.diffMarker)
            diff --git a/app/User.php b/app/User.php
            -old
            +new
            """
        let changes = try #require(RemoteChanges.parse(output))
        #expect(changes.branch == "main...origin/main [ahead 1]")
        #expect(changes.files == [" M app/User.php", "?? notes.md"])
        #expect(changes.stat.contains("1 file changed"))
        #expect(changes.diff.hasPrefix("diff --git"))
    }

    @Test func changesScriptRunsAgainstARealRepository() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/repo", withIntermediateDirectories: true)
        func sh(_ line: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", line]
            p.currentDirectoryURL = URL(fileURLWithPath: home + "/repo")
            p.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try sh("git init -q && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init && printf 'one\\n' > a.txt && git add a.txt && git -c user.email=a@b -c user.name=a commit -q -m a && printf 'two\\n' > a.txt && printf 'n\\n' > new.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(RemoteShell.changesScript(directory: "~/repo", maxBytes: 100_000))]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let changes = try #require(RemoteChanges.parse(String(decoding: data, as: UTF8.self)))
        #expect(changes.files.contains(" M a.txt"))
        #expect(changes.files.contains("?? new.txt"))
        #expect(changes.diff.contains("+two"))
        #expect(changes.stat.contains("a.txt"))
    }
}

@Suite struct RemoteLinkTests {
    @Test func aLostConnectionWinsOverEverythingElse() {
        #expect(RemoteLink(exited: false, disconnected: true, waiting: false, loginPrompt: true, connected: false) == .disconnected)
    }

    @Test func aShellThatEndedIsNotADroppedConnection() {
        // `exit 1` on the host: the tab stays to show why, but Return has nothing to reconnect.
        #expect(RemoteLink(exited: true, disconnected: false, waiting: false, loginPrompt: false, connected: true) == .ended)
        #expect(RemoteLink(exited: true, disconnected: true, waiting: false, loginPrompt: false, connected: false) == .ended)
        #expect(RemoteLink.ended.titleNote == nil && RemoteLink.ended.phrase == "ended" && !RemoteLink.ended.isOnItsWay)
    }

    @Test func onItsWayUntilTheHostProvesTheLogin() {
        #expect(RemoteLink(exited: false, disconnected: false, waiting: true, loginPrompt: false, connected: false) == .waiting)
        #expect(RemoteLink(exited: false, disconnected: false, waiting: false, loginPrompt: true, connected: false) == .logIn)
        #expect(RemoteLink(exited: false, disconnected: false, waiting: false, loginPrompt: false, connected: false) == .connecting)
        #expect(RemoteLink(exited: false, disconnected: false, waiting: false, loginPrompt: false, connected: true) == .connected)
        #expect(RemoteLink.allCases.filter(\.isOnItsWay) == [.connecting, .waiting, .logIn])
    }

    @Test func titleNotesAndPhrases() {
        // The title keeps the notes the docs name; a connection that is simply up adds none.
        #expect(RemoteLink.allCases.map(\.titleNote) == [nil, "connecting", "waiting", "log in", "disconnected", nil])
        #expect(RemoteLink.logIn.phrase == "waiting for you to log in")
        #expect(RemoteLink.connected.phrase == "connected")
    }

    @Test func aSplitTabShowsItsWeakestPane() {
        #expect(RemoteLink.weakest([.connected, .disconnected, .connecting]) == .disconnected)
        #expect(RemoteLink.weakest([.ended, .disconnected]) == .disconnected) // the one Return brings back
        #expect(RemoteLink.weakest([.connected, .ended, .logIn]) == .ended)
        #expect(RemoteLink.weakest([.connected, .logIn]) == .logIn)
        // A login waiting for you outranks a pane that is only on its way, whatever the pane order.
        #expect(RemoteLink.weakest([.connecting, .logIn]) == .logIn)
        #expect(RemoteLink.weakest([.waiting, .connecting]) == .connecting)
        #expect(RemoteLink.weakest([.connected, .connected]) == .connected)
        #expect(RemoteLink.weakest([]) == nil)
    }

    @Test func aSplitTabNamesTheHostWhoseConnectionItShows() {
        let web1 = RemoteMark(host: "web-1", destination: "deploy@web-1", link: .connected)
        let web2 = RemoteMark(host: "web-2", destination: "deploy@web-2", link: .disconnected)
        #expect(RemoteMark.split(focused: web1, panes: [web1, web2]) == web2)
        #expect(RemoteMark.split(focused: web1, panes: [web1, web2])?.summary == "Remote: web-2 (deploy@web-2), disconnected")
        // As weak as the other panes: the focused pane's own host.
        let web2Up = RemoteMark(host: "web-2", destination: "deploy@web-2", link: .connected)
        #expect(RemoteMark.split(focused: web2Up, panes: [web1, web2Up]) == web2Up)
        // The focused pane is on this Mac.
        #expect(RemoteMark.split(focused: nil, panes: [web2]) == web2)
        #expect(RemoteMark.split(focused: nil, panes: []) == nil)
    }
}
