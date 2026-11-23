import Foundation
import Testing
@testable import NextTermCore

/// Next Term's tmux on a host (plan 010a U7): true colour and synchronized output, the host's prefix and history, the
/// live apply on a running server with no other client, and the note when a tab's session was gone and made anew. tmux
/// itself is a stand-in here: a script that answers as tmux would and notes each call.
@Suite struct TmuxOptionsTests {
    /// The config as it was before these options, for the default host: the same lines, and the feature line after.
    static let configBefore = [
        "set -g status off", "set -g mouse on", "set -g history-limit 50000", "set -sg escape-time 10", "set -g focus-events on",
        "set -g set-titles on", "set -g set-titles-string \"#{pane_title}\"", "set -gq allow-passthrough on",
        "set -sq extended-keys on", "set -gq window-size latest",
    ].joined(separator: "\n")

    @Test func theDefaultConfigIsAsBeforeWithTheFeatureLineAdded() {
        let config = RemoteShell.tmuxConfig()
        #expect(config == Self.configBefore + "\n" + TmuxOptions.featuresLine)
        // One indexed element, never appended: reading the config again sets the same one.
        #expect(config.contains("set -sq 'terminal-features[99]' 'xterm*:RGB:sync'"))
        #expect(!config.contains("-as") && !config.contains("prefix"))
    }

    @Test func anotherPrefixAndHistoryGoInTheConfig() {
        let config = RemoteShell.tmuxConfig(TmuxOptions(prefix: .ctrlA, history: 200_000))
        let lines: [String] = config.components(separatedBy: "\n")
        #expect(lines.contains("set -g prefix C-a"))
        #expect(lines.contains("unbind C-b"))
        #expect(lines.contains("bind C-a send-prefix"))
        #expect(lines.contains("set -g history-limit 200000"))
        #expect(!lines.contains("set -g history-limit 50000"))
        // The hooked host's config carries them too, with its key after.
        let hooked = RemoteCompletionHook.tmuxConfig(TmuxOptions(prefix: .ctrlSpace, history: 1_000))
        #expect(hooked.contains("set -g prefix C-Space") && hooked.contains("history-limit 1000") && hooked.contains("6973"))
    }

    @Test func historyOutsideItsRangeIsRefusedWithTheRange() {
        #expect(TmuxOptions.historyProblem(999) != nil)
        #expect(TmuxOptions.historyProblem(200_001) != nil)
        #expect(TmuxOptions.historyProblem(1_000) == nil)
        #expect(TmuxOptions.historyProblem(200_000) == nil)
        let host = RemoteHost(name: "web-1", destination: "dev@example.com", tmuxHistory: 999)
        #expect(host.problem == "tmux history must be between 1,000 and 200,000 lines.")
        #expect(RemoteHost(name: "web-1", destination: "dev@example.com", tmuxHistory: 5_000).problem == nil)
    }

    @Test func hostsSavedBeforeReadWithTmuxsOwnSettings() throws {
        let old = #"[{"id":"abc123","name":"web-1","destination":"dev@example.com","directory":"~","keep":"tmux"}]"#
        let hosts = RemoteHost.decodeList(Data(old.utf8))
        #expect(hosts.count == 1)
        #expect(hosts.first?.tmuxPrefix == nil && hosts.first?.tmuxHistory == nil)
        #expect(hosts.first?.tmuxOptions == TmuxOptions())
        // A prefix from a later version reads as none: the host is kept.
        let later = #"[{"id":"abc123","name":"web-1","destination":"dev@example.com","directory":"~","keep":"tmux","tmuxPrefix":"C-q"}]"#
        #expect(RemoteHost.decodeList(Data(later.utf8)).first?.tmuxPrefix == nil)
        // A default host saves as before: no tmux keys.
        let saved = String(decoding: RemoteHost.encodeList([RemoteHost(id: "abc123", name: "web-1", destination: "dev@example.com")]),
                           as: UTF8.self)
        #expect(!saved.contains("tmuxPrefix") && !saved.contains("tmuxHistory"))
        let chosen = RemoteHost(id: "abc123", name: "web-1", destination: "dev@example.com", tmuxPrefix: .ctrlA, tmuxHistory: 100_000)
        let back = RemoteHost.decodeList(RemoteHost.encodeList([chosen]))
        #expect(back == [chosen])
    }

    @Test func theHistoryFieldReadsAsTyped() {
        #expect(TmuxSettingsText.history("") == nil)
        #expect(TmuxSettingsText.history("  ") == nil)
        #expect(TmuxSettingsText.history("50000") == nil)
        #expect(TmuxSettingsText.history("200,000") == 200_000)
        #expect(TmuxSettingsText.history("10 000") == 10_000)
        #expect(TmuxSettingsText.history("lots") == -1)
        #expect(TmuxSettingsText.history("-5") == -1)
    }

    @Test func onlyATabThatExpectsItsSessionChecksForIt() {
        let fresh = RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1")
        let back = RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", expectsSession: true)
        // The marker is cleared on every path, before anything else runs.
        for script in [fresh, back] { #expect(script.contains("rm -f \"$K.plain\" \"$K.nodir\" \"$K.created\"")) }
        #expect(!fresh.contains("has-session -t"))
        #expect(back.contains("has-session -t '=s' 2>/dev/null || : > \"$K.created\""))
        let hooked = RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", completionHook: true, expectsSession: true)
        #expect(hooked.contains("has-session -t '=s'"))
        // Not for an ssh shell or herdr.
        #expect(!RemoteShell.tabScript(keep: .off, directory: "~", session: "s", tabID: "t1", expectsSession: true).contains("has-session"))
        #expect(!RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "t1", expectsSession: true).contains("has-session"))
    }

    @Test func thePollSaysWhenASessionWasMadeAnew() throws {
        let script = RemoteShell.pollScript(tabs: [(id: "t1", keep: .tmux, session: "s")])
        #expect(script.contains("[ -e \"$C/tabs/t1.created\" ] && printf '%s\\tcreated\\n' 't1'"))
        let output = "\n\(RemoteShell.marker)\nt1\tup\ttok\nt1\tshell\nt1\tcreated\nt2\tshell\n"
        let poll = try #require(RemotePoll.parse(output))
        #expect(poll.tabs["t1"]?.sessionCreated == true)
        #expect(poll.tabs["t2"]?.sessionCreated == false)
    }

    // MARK: with a stand-in tmux

    /// A folder with a stand-in `tmux` that notes each call in `calls` and answers: `-V`; `has-session` (with `-t`: the
    /// session, without: the server) as `running` says; `list-clients` with `clients`; `show -gv prefix` with `prefix`;
    /// everything else, `new-session` included, does nothing.
    struct StandIn {
        let home: String
        let calls: String

        init(running: Bool, session: Bool, clients: String = "", prefix: String = "C-b") throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-tmux-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
            calls = home + "/calls"
            let script = """
                #!/bin/sh
                printf '%s\\n' "$*" >> '\(calls)'
                case "$*" in
                  -V) echo 'tmux 3.4' ;;
                  *has-session\\ -t*) [ \(session ? "1" : "0") = 1 ] ;;
                  *has-session*) [ \(running ? "1" : "0") = 1 ] ;;
                  *list-clients*) printf '%s' '\(clients)' ;;
                  *show\\ -gv\\ prefix*) echo '\(prefix)' ;;
                esac
                """
            try script.write(toFile: home + "/bin/tmux", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/tmux")
        }

        func run(_ script: String) throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", RemoteShell.command(script)]
            process.environment = ["HOME": home, "PATH": home + "/bin:/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let text = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init).filter { $0 != "-V" }
        }

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: home + "/.cache/next-term/tabs/" + name) }
        func remove() { try? FileManager.default.removeItem(atPath: home) }
    }

    @Test func aSessionThatWasGoneIsMarkedOnlyForATabThatExpectedIt() throws {
        let gone = try StandIn(running: false, session: false)
        defer { gone.remove() }
        let calls = try gone.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", expectsSession: true))
        #expect(gone.exists("t1.created"))
        #expect(calls.last?.hasPrefix("-L nextterm -f ") == true && calls.last?.hasSuffix("new-session -A -s s -c \(gone.home)") == true)
        // A brand-new tab never checks, so never says it.
        let fresh = try StandIn(running: false, session: false)
        defer { fresh.remove() }
        _ = try fresh.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t2"))
        #expect(!fresh.exists("t2.created"))
        // There: attached, no mark; and a mark from an earlier connection goes.
        let there = try StandIn(running: true, session: true, clients: "/dev/ttys001: s")
        defer { there.remove() }
        try FileManager.default.createDirectory(atPath: there.home + "/.cache/next-term/tabs", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: there.home + "/.cache/next-term/tabs/t3.created", contents: nil)
        _ = try there.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t3", expectsSession: true))
        #expect(!there.exists("t3.created"))
        // The config the tab wrote has the feature line.
        let config = try String(contentsOfFile: there.home + "/.cache/next-term/tmux.conf", encoding: .utf8)
        #expect(config.contains(TmuxOptions.featuresLine))
    }

    @Test func aRunningServerWithNoClientTakesThePrefixItsOldOneUnboundFirst() throws {
        let alone = try StandIn(running: true, session: true, prefix: "C-a")
        defer { alone.remove() }
        let options = TmuxOptions(prefix: .ctrlB, history: 20_000)
        let calls = try alone.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", tmux: options))
        let unbind = try #require(calls.firstIndex(of: "-L nextterm unbind-key C-a"))
        let prefix = try #require(calls.firstIndex(of: "-L nextterm set -g prefix C-b"))
        let bind = try #require(calls.firstIndex(of: "-L nextterm bind-key C-b send-prefix"))
        #expect(unbind < prefix && prefix < bind)
        #expect(calls.contains("-L nextterm set -g history-limit 20000"))
        #expect(calls.contains("-L nextterm set -sq terminal-features[99] xterm*:RGB:sync"))
        // Another client attached (another Mac): the running server is left as it is.
        let shared = try StandIn(running: true, session: true, clients: "/dev/pts/3: s", prefix: "C-a")
        defer { shared.remove() }
        let left = try shared.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", tmux: options))
        #expect(!left.contains { $0.contains("prefix") || $0.contains("unbind") || $0.contains("history-limit") })
        // No server running: nothing to apply; the new one reads the config.
        let none = try StandIn(running: false, session: false)
        defer { none.remove() }
        let fresh = try none.run(RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t1", tmux: options))
        #expect(!fresh.contains { $0.contains("list-clients") || $0.contains("set -g") })
    }

    @Test func theTabScriptsAreValidShell() throws {
        for expects in [false, true] {
            for hook in [false, true] {
                let script = RemoteShell.tabScript(keep: .tmux, directory: "~/app", session: "nt-app-1", tabID: "t1",
                                                   completionHook: hook, tmux: TmuxOptions(prefix: .ctrlBracket, history: 9_000),
                                                   expectsSession: expects)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-n", "-c", script]
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "expects \(expects), hook \(hook)")
            }
        }
    }

    @Test func removingTheCompletionHookKeepsTheHostsTmuxOptions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-tmux-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.cache/next-term", withIntermediateDirectories: true)
        let hooked = RemoteCompletionHook.tmuxConfig(TmuxOptions(prefix: .ctrlA, history: 9_000))
        try (hooked + "\n").write(toFile: home + "/.cache/next-term/tmux.conf", atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(RemoteCompletionHook.removeScript)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let config = try String(contentsOfFile: home + "/.cache/next-term/tmux.conf", encoding: .utf8)
        #expect(!config.contains("6973"))
        #expect(config.contains("set -g prefix C-a") && config.contains("history-limit 9000") && config.contains("terminal-features"))
    }
}
