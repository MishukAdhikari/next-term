import Foundation
import Testing
@testable import NextTermCore

/// Finding herdr (and tmux) on a host, run here as a host would: the scripts under a login shell's -c, in a temporary
/// HOME, with stand-in herdr copies, a stand-in login shell, and a stand-in pgrep first on PATH, so the user's own
/// herdr (a server running on this Mac, a copy in /opt/homebrew) is never found or started.
@Suite struct RemoteFinderTests {
    let base: String
    let home: String
    let bin: String

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-finder-\(UUID().uuidString)").path
        home = base + "/home"
        bin = base + "/bin"
        for folder in [home, bin] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        // No running herdr server, whatever runs on this Mac.
        try script(bin + "/pgrep", "exit 1", warm: [])
    }

    /// A herdr copy here on this Mac where a host's finder would look: then a test that expects none skips that part.
    static let herdrOnThisMac = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/home/linuxbrew/.linuxbrew/bin/herdr",
                                 "/nix/var/nix/profiles/default/bin/herdr", "/run/current-system/sw/bin/herdr"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }
    static let tmuxOnThisMac = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/bin/tmux"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }

    /// An executable shell script at `path`, run once with `warm` (macOS checks a new program the first time it runs,
    /// which under a parallel test run can take seconds: longer than the finder's 3-second cap on a login shell).
    func script(_ path: String, _ body: String, warm: [String]? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        guard let warm else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = warm
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// A stand-in herdr: `--version` says so, `agent list` prints `list` (stdout) or `error` (stderr, exit 1).
    func herdr(at path: String, version: String = "herdr 0.9.4", versionExit: Int = 0, list: String = #"{"result":{"agents":[]}}"#,
               error: String? = nil, paneList: String? = nil) throws {
        var body = "case \"$1 $2\" in\n"
        body += "  '--version '*) echo \(RemoteShell.quote(version)); exit \(versionExit) ;;\n"
        if let error {
            body += "  'agent list') echo \(RemoteShell.quote(error)) >&2; exit 1 ;;\n"
        } else {
            body += "  'agent list') echo \(RemoteShell.quote(list)) ;;\n"
        }
        if let paneList { body += "  'pane list') echo \(RemoteShell.quote(paneList)) ;;\n" }
        body += "esac"
        try script(path, body, warm: ["--version"])
    }

    /// A stand-in login shell named `name`: when the finder runs it, it notes its flags (or with `sleep`, hangs), prints
    /// rc-file noise (no newline after it, and on stderr), then runs the command it was given with PATH `path`, and
    /// `env` exported.
    func loginShell(_ name: String, path: String, env: String = "", sleep: Int = 0) throws -> String {
        let shell = base + "/shells/" + name
        let hang = sleep > 0 ? "exec sleep \(sleep)" : ":"
        try script(shell, """
            case "$*" in
              *@@NT-ENV-*) printf '%s\\n' "$*" >> \(RemoteShell.quote(base + "/shell-args")); \(hang) ;;
            esac
            printf 'Welcome to the host\\nlast login: never'
            echo 'rc noise on stderr' >&2
            while [ $# -gt 1 ]; do shift; done
            PATH=\(RemoteShell.quote(path)); export PATH
            \(env)
            exec /bin/sh -c "$1"
            """, warm: ["-c", "true"])
        return shell
    }

    /// Runs `script` the way sshd runs a remote command: through a shell's -c, here with HOME, PATH and SHELL set.
    func run(_ script: String, shell: String = "", path: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(script)]
        // TMUX_TMPDIR: a tmux the scripts find never reaches a server of this Mac's.
        process.environment = ["HOME": home, "PATH": path ?? (bin + ":/usr/bin:/bin:/usr/sbin:/sbin"), "SHELL": shell,
                               "TMUX_TMPDIR": base]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The tab's finder, then what it found: `H=…`, `HW=…`, `BAD=…`, `SAID=…`, `SESSION=…` lines.
    func tabFinder(shell: String = "", path: String? = nil) throws -> [String: String] {
        let found = "printf 'H=%s\\nHW=%s\\nBAD=%s\\nSAID=%s\\nSESSION=%s\\n' \"$H\" \"$HW\" \"$nt_bad\" \"$nt_said\" \"${HERDR_SESSION:-}\""
        let output = try run("C=\(RemoteShell.cacheDir)\n" + RemoteShell.herdrTabFinder() + "\n" + found, shell: shell, path: path)
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    // MARK: the install folders

    @Test func herdrIsFoundInEachOfItsInstallFolders() throws {
        guard !Self.herdrOnThisMac else { return } // a copy in /opt/homebrew or /usr/local comes before mise and Nix
        for place in [".local/bin/herdr", "bin/herdr", ".cargo/bin/herdr", ".linuxbrew/bin/herdr",
                      ".local/share/mise/installs/herdr/0.9.4/herdr", ".local/share/mise/installs/herdr/0.9.4/bin/herdr",
                      ".local/share/mise/installs/github-ogulcancelik-herdr/0.8.0/herdr", ".nix-profile/bin/herdr",
                      ".local/state/nix/profile/bin/herdr", ".asdf/shims/herdr"] {
            try? FileManager.default.removeItem(atPath: home)
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            try herdr(at: home + "/" + place)
            let found = try tabFinder()
            #expect(found["H"] == home + "/" + place && found["HW"] == "known", "\(place): \(found)")
        }
    }

    @Test func misesNewestVersionAndItsLatestLinkComeFirst() throws {
        guard !Self.herdrOnThisMac else { return }
        let mise = home + "/.local/share/mise/installs/herdr"
        try herdr(at: mise + "/0.9.4/herdr")
        try herdr(at: mise + "/0.10.1/bin/herdr")
        try herdr(at: mise + "/0.2.0/herdr")
        #expect(try tabFinder()["H"] == mise + "/0.10.1/bin/herdr")
        try herdr(at: mise + "/latest/herdr")
        #expect(try tabFinder()["H"] == mise + "/latest/herdr")
        // A direct install comes before mise.
        try herdr(at: home + "/.local/bin/herdr")
        #expect(try tabFinder()["H"] == home + "/.local/bin/herdr")
    }

    @Test func aShimIsTakenOnlyWhenNothingElseRuns() throws {
        let shims = home + "/.local/share/mise/shims"
        let tools = base + "/tools"
        try herdr(at: shims + "/herdr")
        try herdr(at: tools + "/herdr")
        let path = bin + ":" + shims + ":" + tools + ":/usr/bin:/bin"
        let concrete = try tabFinder(path: path)
        #expect(concrete["H"] == tools + "/herdr" && concrete["HW"] == "path")
        try FileManager.default.removeItem(atPath: tools)
        #expect(try tabFinder(path: path)["H"] == shims + "/herdr")
    }

    @Test func aShimFolderWithoutHerdrDoesNotHideALaterOne() throws {
        // mise's shims first on PATH but herdr managed by asdf, in a folder of its own (not ~/.asdf, which the install
        // folders would find anyway).
        let mise = home + "/.local/share/mise/shims"
        let asdf = base + "/opt/asdf/shims"
        try FileManager.default.createDirectory(atPath: mise, withIntermediateDirectories: true)
        try herdr(at: asdf + "/herdr")
        let found = try tabFinder(path: bin + ":" + mise + ":" + asdf + ":/usr/bin:/bin")
        #expect(found["H"] == asdf + "/herdr" && found["HW"] == "path", "\(found)")
    }

    @Test func copiesThatCannotRunArePassedOverAndTheBrokenOneIsNamed() throws {
        guard !Self.herdrOnThisMac else { return }
        // A folder named herdr, a file that cannot run, and one whose --version fails, before one that works.
        try FileManager.default.createDirectory(atPath: home + "/.local/bin/herdr", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try "not a program".write(toFile: home + "/bin/herdr", atomically: true, encoding: .utf8)
        try herdr(at: home + "/.cargo/bin/herdr", version: "error: no version is set for herdr", versionExit: 1)
        try herdr(at: home + "/.nix-profile/bin/herdr")
        let found = try tabFinder()
        #expect(found["H"] == home + "/.nix-profile/bin/herdr")
        #expect(found["BAD"] == home + "/.cargo/bin/herdr" && found["SAID"] == "error: no version is set for herdr")
        // With nothing that runs, the tab says which copy didn't, and why.
        try FileManager.default.removeItem(atPath: home + "/.nix-profile")
        let none = try tabFinder()
        #expect(none["H"] == "" && none["BAD"] == home + "/.cargo/bin/herdr")
    }

    // MARK: the login shell's PATH

    @Test func herdrOnTheLoginShellsPATHIsFound() throws {
        let loginBin = base + "/login-bin"
        try herdr(at: loginBin + "/herdr")
        let shell = try loginShell("zsh", path: loginBin + ":/usr/bin:/bin", env: "HERDR_SESSION=work; export HERDR_SESSION")
        let found = try tabFinder(shell: shell)
        #expect(found["H"] == loginBin + "/herdr" && found["HW"] == "login", "\(found)")
        // A login shell asked as one; the socket variable it sets is carried to herdr, and into the cache.
        let args = try String(contentsOfFile: base + "/shell-args", encoding: .utf8)
        #expect(args.hasPrefix("-l -c echo @@NT-ENV-") && args.contains("/usr/bin/env"))
        #expect(found["SESSION"] == "work")
        let cache = try String(contentsOfFile: home + "/.cache/next-term/herdr", encoding: .utf8)
        #expect(cache == "path\t\(loginBin)/herdr\nhow\tlogin\nenv\tHERDR_SESSION=work\n")
        // Nothing of the login shell's file is left.
        let left = try FileManager.default.contentsOfDirectory(atPath: home + "/.cache/next-term").filter { $0.hasPrefix("login-env") }
        #expect(left.isEmpty)
    }

    @Test func cshShellsAreAskedWithoutLogin() throws {
        let shell = try loginShell("tcsh", path: "/usr/bin:/bin")
        _ = try tabFinder(shell: shell)
        let args = try String(contentsOfFile: base + "/shell-args", encoding: .utf8)
        #expect(args.hasPrefix("-c echo @@NT-ENV-"), "\(args)")
    }

    @Test func bashIsAskedAgainAsAnInteractiveShellWhereSetsidIs() throws {
        // Ubuntu's ~/.bashrc sets PATH (mise, Linuxbrew) after its "not interactive" guard: only `-l -i` has herdr. A
        // stand-in setsid, as Linux has (macOS has none, so the second ask never happens here otherwise).
        let loginBin = base + "/login-bin"
        try herdr(at: loginBin + "/herdr")
        try script(bin + "/setsid", "exec \"$@\"", warm: ["/usr/bin/true"])
        let shell = base + "/shells/bash"
        try script(shell, """
            printf '%s\\n' "$1 $2" >> \(RemoteShell.quote(base + "/shell-args"))
            case "$1 $2" in
              '-l -i') PATH=\(RemoteShell.quote(loginBin + ":/usr/bin:/bin")) ;;
              *) PATH=/usr/bin:/bin ;;
            esac
            export PATH
            while [ $# -gt 1 ]; do shift; done
            exec /bin/sh -c "$1"
            """, warm: ["-c", "true"])
        try? FileManager.default.removeItem(atPath: base + "/shell-args")
        let found = try tabFinder(shell: shell)
        #expect(found["H"] == loginBin + "/herdr" && found["HW"] == "login", "\(found)")
        let args = try String(contentsOfFile: base + "/shell-args", encoding: .utf8)
        #expect(args == "-l -c\n-l -i\n")
    }

    @Test func aLoginShellThatHangsIsGivenUpOnWithinFourSeconds() throws {
        try herdr(at: home + "/.local/bin/herdr")
        // With setsid there, a bash that gave nothing in time is not asked again as an interactive shell.
        try script(bin + "/setsid", "exec \"$@\"", warm: ["/usr/bin/true"])
        let shell = try loginShell("bash", path: "/usr/bin:/bin", sleep: 10)
        let start = Date()
        let found = try tabFinder(shell: shell)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(found["H"] == home + "/.local/bin/herdr" && found["HW"] == "known")
        let asked = try String(contentsOfFile: base + "/shell-args", encoding: .utf8).split(separator: "\n")
        #expect(asked.count == 1 && asked.first?.hasPrefix("-l -c ") == true, "\(asked)")
    }

    @Test func nothingTheLoginShellPrintsReachesTheTab() throws {
        let shell = try loginShell("zsh", path: "/usr/bin:/bin")
        let output = try run("C=\(RemoteShell.cacheDir)\n" + RemoteShell.herdrTabFinder() + "\necho done", shell: shell)
        #expect(output == "done\n")
    }

    // MARK: the running server

    @Test func theRunningServersExecutableComesFirst() throws {
        // No /proc here: the finder asks ps. A stand-in pgrep finds pid 4242, a stand-in ps says what runs as it.
        let server = base + "/server/herdr"
        try herdr(at: server)
        try herdr(at: home + "/.local/bin/herdr")
        try script(bin + "/pgrep", "echo 4242")
        func ps(args: String) throws {
            try script(bin + "/ps", "case \"$*\" in *args=*) echo \(RemoteShell.quote(args)) ;; *comm=*) echo \(RemoteShell.quote(server)) ;; esac")
        }
        try ps(args: "herdr server")
        let found = try tabFinder()
        #expect(found["H"] == server && found["HW"] == "running", "\(found)")
        // A status check asks the running server's copy before the cache's (an older copy left installed would not
        // speak its protocol).
        try "path\t\(home)/.local/bin/herdr\nhow\tlogin\n".write(toFile: home + "/.cache/next-term/herdr", atomically: true, encoding: .utf8)
        let polled = try #require(RemotePoll.parse(try run(RemoteShell.pollScript(tabs: [], herdr: true)))?.herdr)
        #expect(polled.path == server && polled.how == "running")
        // A client (`herdr` with no `server`) is not the server.
        try ps(args: "herdr")
        #expect(try tabFinder()["H"] == home + "/.local/bin/herdr")
        // On Linux the server's own /proc entries say the same, and its socket variables are read.
        let text = RemoteShell.herdrTabFinder()
        #expect(text.contains("pgrep -u \"$(id -u)\" -x \"$1\"") && text.contains("/proc/$nt_q/cmdline") && text.contains("/proc/$nt_q/exe"))
        #expect(text.contains("/proc/$NTS/environ") && text.contains("HERDR_SESSION|HERDR_SOCKET_PATH|XDG_CONFIG_HOME"))
    }

    @Test func aSessionIsCarriedOverOnlyFromTheOnlyServer() throws {
        // Which of several servers started first says nothing of the session wanted: then none is read (NTS, whose
        // /proc environ nt_server_env reads), and herdr picks, as it does in the user's own terminal.
        let server = base + "/server/herdr"
        try herdr(at: server)
        try script(bin + "/ps", "case \"$*\" in *args=*) echo 'herdr server' ;; *comm=*) echo \(RemoteShell.quote(server)) ;; esac")
        let probe = [RemoteShell.finderFunctions, RemoteShell.herdrFunctions,
                     "nt_check=; nt_bad=; NTF=", "nt_running herdr; printf '%s|%s\\n' \"$NTF\" \"$NTS\""].joined(separator: "\n")
        try script(bin + "/pgrep", "echo 4242")
        #expect(try run(probe) == "\(server)|4242\n")
        try script(bin + "/pgrep", "printf '4242\\n4243\\n'")
        #expect(try run(probe) == "\(server)|\n")
    }

    // MARK: the status check

    @Test func theStatusCheckReadsTheCacheAndNeverRunsTheLoginShell() throws {
        let poll = RemoteShell.pollScript(tabs: [], herdr: true)
        #expect(!poll.contains("nt_login_env") && !poll.contains("nt_login_find"))
        #expect(!RemoteShell.sessionsScript.contains("nt_login_env"))
        #expect(!RemoteShell.pollScript(tabs: [(id: "t", keep: .off, session: "")]).contains(RemoteShell.herdrMarker))
        // The tab found herdr through the login shell; the check finds it where the tab said.
        let loginBin = base + "/login-bin"
        try herdr(at: loginBin + "/herdr", list: try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent("agent-list-0.9.4.json"), encoding: .utf8))
        _ = try tabFinder(shell: try loginShell("zsh", path: loginBin + ":/usr/bin:/bin"))
        let report = try #require(RemotePoll.parse(try run(poll))?.herdr)
        #expect(report.path == loginBin + "/herdr" && report.how == "login")
        guard case .agents(let agents) = report.listing else { Issue.record("\(report.listing)"); return }
        #expect(agents.map(\.status) == [.working, .blocked, .done])
        // A cached copy that is gone is looked for again.
        try FileManager.default.removeItem(atPath: loginBin)
        try herdr(at: home + "/bin/herdr")
        let again = try #require(RemotePoll.parse(try run(poll))?.herdr)
        #expect(again.path == home + "/bin/herdr" && again.how == "known")
    }

    @Test func theStatusCheckSaysWhatHerdrSaidWhenItFails() throws {
        let poll = RemoteShell.pollScript(tabs: [], herdr: true)
        // No server: herdr's JSON error on stderr, which the old check threw away.
        let notRunning = try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent("server-not-running.json"), encoding: .utf8)
        try herdr(at: home + "/.local/bin/herdr", error: notRunning.trimmingCharacters(in: .newlines))
        let report = try #require(RemotePoll.parse(try run(poll))?.herdr)
        guard case .notRunning(let said) = report.listing else { Issue.record("\(report.listing)"); return }
        #expect(said.contains("herdr.sock"))
        // herdr before 0.5.10: `agent list` is unknown, so `pane list` is asked.
        let panes = try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent("pane-list-0.4.5.json"), encoding: .utf8)
        try herdr(at: home + "/.local/bin/herdr", error: "unknown command: agent", paneList: panes.trimmingCharacters(in: .newlines))
        let old = try #require(RemotePoll.parse(try run(poll))?.herdr)
        #expect(old.listing == .agents([HerdrListingTests.agent045]))
        // Not there at all.
        try FileManager.default.removeItem(atPath: home + "/.local/bin/herdr")
        guard !Self.herdrOnThisMac else { return }
        let gone = try RemotePoll.parse(try run(poll))?.herdr?.listing
        #expect(gone == .missing)
    }

    @Test func theStatusCheckReadsAnAnswerThatWorkedAsHerdrGaveIt() throws {
        let poll = RemoteShell.pollScript(tabs: [], herdr: true)
        let list = #"{"result":{"agents":[{"pane_id":"p1","name":"claude","agent_status":"working","title":"Fix unknown command error"}]}}"#
        let agent = HerdrAgent(paneID: "p1", customName: "claude", status: .working, title: "Fix unknown command error")
        // An agent's title that says "unknown command", in an answer that worked: `pane list` is not asked.
        try herdr(at: home + "/.local/bin/herdr", list: list, paneList: #"{"result":{"panes":[]}}"#)
        let listed = try #require(RemotePoll.parse(try run(poll))?.herdr)
        #expect(listed.listing == .agents([agent]), "\(listed.listing)")
        // A wrapper that sets the title first: BEL, which ends its OSC, is kept, so the answer after it is read.
        try herdr(at: home + "/.local/bin/herdr", list: "\u{1b}]0;herdr\u{07}" + list)
        let titled = try #require(RemotePoll.parse(try run(poll))?.herdr)
        #expect(titled.listing == .agents([agent]), "\(titled.listing)")
    }

    // MARK: the tab

    @Test func aTabWithoutHerdrSaysWhereItLookedAndPointsToTheInstallPage() throws {
        let tab = RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "tab9")
        #expect(tab.contains("never installs it") && tab.contains(RemoteShell.herdrInstallPage))
        #expect(!tab.contains("curl") && !tab.contains("install.sh"))
        guard !Self.herdrOnThisMac else { return }
        let ran = tab.replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "exit 0")
        let output = try run(ran, shell: try loginShell("zsh", path: "/usr/bin:/bin"))
        #expect(output.contains("Next Term: herdr was not found on this host, so this tab is a plain shell"))
        #expect(output.contains("Looked on your login shell's PATH and /bin/sh's PATH"))
        // The install page as a link, and as text.
        let page = RemoteShell.herdrInstallPage
        #expect(output.contains("\u{1b}]8;;\(page)\u{1b}\\\(page)\u{1b}]8;;\u{1b}\\ (Next Term never installs it)"))
        let plain = home + "/.cache/next-term/tabs/tab9.plain"
        let reason = try? String(contentsOfFile: plain, encoding: .utf8)
        #expect(reason?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: home + "/.cache/next-term/herdr"))
    }

    @Test func aTabWhoseHerdrDoesNotRunSaysSoAndTheCheckCarriesWhy() throws {
        try herdr(at: home + "/.local/bin/herdr", version: "herdr: cannot execute binary file", versionExit: 126)
        let tab = RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "tab8")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "exit 0")
        guard !Self.herdrOnThisMac else { return }
        let output = try run(tab)
        #expect(output.contains("Next Term: herdr at \(home)/.local/bin/herdr did not run (herdr --version said: herdr: cannot execute binary file)"))
        let poll = try #require(RemotePoll.parse(try run(RemoteShell.pollScript(tabs: [(id: "tab8", keep: .off, session: "")], herdr: true))))
        #expect(poll.tabs["tab8"]?.plain == true)
        #expect(poll.tabs["tab8"]?.plainReason == "herdr at \(home)/.local/bin/herdr did not run (herdr --version said: herdr: cannot execute binary file)")
    }

    @Test func aTabThatFindsHerdrRunsIt() throws {
        try herdr(at: home + "/.local/bin/herdr")
        let tab = RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "tab7")
            .replacingOccurrences(of: "exec \"$H\"", with: "printf 'runs %s\\n' \"$H\"")
        let output = try run(tab)
        #expect(output.hasSuffix("runs \(home)/.local/bin/herdr\n"), "\(output)")
        #expect(!FileManager.default.fileExists(atPath: home + "/.cache/next-term/tabs/tab7.plain"))
    }

    @Test func aTabOpensANamedHerdrSessionOnlyWhileHerdrListsIt() throws {
        let list = #"{"sessions":[{"name":"default","default":true,"running":true},{"name":"review","default":false,"running":true}]}"#
        try script(home + "/.local/bin/herdr", """
            case "$1 $2" in
              '--version '*) echo 'herdr 0.9.4' ;;
              'session list') echo \(RemoteShell.quote(list)) ;;
            esac
            """, warm: ["--version"])
        func opened(_ session: String) throws -> String {
            let tab = RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "tab6", herdrSession: session)
                .replacingOccurrences(of: "exec \"$H\" --session", with: "printf 'runs %s with %s\\n' \"$H\"")
                .replacingOccurrences(of: "exec \"${SHELL:-/bin/sh}\" -l", with: "exit 0")
            return try run(tab)
        }
        #expect(try opened("review").hasSuffix("runs \(home)/.local/bin/herdr with review\n"))
        #expect(!FileManager.default.fileExists(atPath: home + "/.cache/next-term/tabs/tab6.plain"))
        // A session herdr no longer lists: a plain shell that says so, and the check carries why.
        let gone = try opened("old")
        #expect(gone.contains("Next Term: herdr on this host lists no session “old”") && !gone.contains("runs \(home)"))
        let poll = try #require(RemotePoll.parse(try run(RemoteShell.pollScript(tabs: [(id: "tab6", keep: .off, session: "")]))))
        #expect(poll.tabs["tab6"]?.plain == true && poll.tabs["tab6"]?.plainReason == "herdr on this host lists no session old")
    }

    @Test func aHostWithNoHerdrTabIsAskedOnlyForAHerdrATabFoundBefore() throws {
        let path = home + "/.local/bin/herdr"
        let list = #"{"result":{"agents":[{"pane_id":"w1:p1","agent":"codex","agent_status":"blocked","state_change_seq":2}]}}"#
        try herdr(at: path, list: list)
        let poll = RemoteShell.pollScript(tabs: [(id: "tab9", keep: .tmux, session: "nt-x")], herdrSessions: [HerdrPollSession(name: nil, overview: true)])
        // No herdr tab ever found it here, and no herdr server runs: nothing is asked, though a copy is installed.
        let before = try #require(RemotePoll.parse(try run(poll)))
        #expect(before.herdrSessions.isEmpty)
        // Once a tab has found it (the cache names it), the check reads its default session.
        let cache = home + "/.cache/next-term"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try "path\t\(path)\nhow\tlocal-bin\n".write(toFile: cache + "/herdr", atomically: true, encoding: .utf8)
        let after = try #require(RemotePoll.parse(try run(poll)))
        guard case .agents(let agents) = after.herdr?.listing else {
            Issue.record("\(after.herdrSessions)")
            return
        }
        #expect(agents.map(\.paneID) == ["w1:p1"] && agents.first?.status == .blocked)
    }

    // MARK: check_host

    @Test func checkHostSaysWhereHerdrIsAndHowItWasFound() throws {
        try herdr(at: home + "/.local/bin/herdr")
        let probe = try #require(RemoteProbe.parse(try run(RemoteShell.probeScript)))
        #expect(probe.herdr == "herdr 0.9.4" && probe.herdrPath == home + "/.local/bin/herdr" && probe.herdrHow == "known")
        #expect(probe.herdrSummary == "herdr 0.9.4 at \(home)/.local/bin/herdr (found in one of herdr’s usual install folders)")
        // It writes the cache the status checks read.
        let cache = try String(contentsOfFile: home + "/.cache/next-term/herdr", encoding: .utf8)
        #expect(cache == "path\t\(home)/.local/bin/herdr\nhow\tknown\n")
        guard !Self.herdrOnThisMac else { return }
        try FileManager.default.removeItem(atPath: home + "/.local/bin/herdr")
        let missing = try #require(RemoteProbe.parse(try run(RemoteShell.probeScript)))
        #expect(missing.herdr == nil && missing.herdrMissing && missing.herdrBroken == nil)
        #expect(!FileManager.default.fileExists(atPath: home + "/.cache/next-term/herdr"))
    }

    // MARK: tmux, from the same finder

    @Test func tmuxIsFoundInTheSameFoldersAndOneThatDoesNotRunIsPassedOver() throws {
        try script(home + "/.cargo/bin/tmux", "exit 1")
        try script(home + "/.nix-profile/bin/tmux", "echo 'tmux 3.4'")
        let found = try run(RemoteShell.tmuxFinder(checked: true) + "\nprintf '%s\\n' \"$T\"")
        // A tmux in /opt/homebrew or /usr/local (on this Mac) comes before Nix's.
        if !Self.tmuxOnThisMac { #expect(found == home + "/.nix-profile/bin/tmux\n") }
        // A status check runs nothing to look: the first file that can run.
        let quick = try run(RemoteShell.findTmux + "\nprintf '%s\\n' \"$T\"")
        if !Self.tmuxOnThisMac { #expect(quick == home + "/.cargo/bin/tmux\n") }
    }

    @Test func theFinderLeavesTheScriptsOwnVariablesAlone() throws {
        try herdr(at: home + "/.local/bin/herdr")
        let names = ["C", "K", "A", "L", "D", "W", "p", "s", "t", "d", "g", "q", "m"]
        let assigned = names.map { "\($0)=keep-\($0)" }.joined(separator: "; ")
        let shown = names.map { "\"$\($0)\"" }.joined(separator: " ")
        let format = String(repeating: "%s ", count: names.count)
        let output = try run("\(assigned)\n\(RemoteShell.findTmux)\n\(RemoteShell.findHerdr)\nprintf '\(format)\\n' \(shown)")
        #expect(output == names.map { "keep-\($0)" }.joined(separator: " ") + " \n")
    }
}
