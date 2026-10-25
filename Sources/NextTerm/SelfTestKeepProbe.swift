#if DEBUG
import AppKit
import NextTermCore

/// The keep probe (plan 010a U8), in debug builds only: does a herdr session, or a tmux server, started in a Next Term tab
/// outlive the app's update relaunch, and then its quit? `scripts/selftest.sh --keep-probe` runs it in the relaunch
/// harness's throwaway copy, launched as the Finder launches an app, against a herdr and a tmux of its own: a scratch
/// root with its own XDG folders and TMUX_TMPDIR. The driver names the tools, the session and the scratch root in
/// `probe-tools`, and writes the two launchers the tabs run (`probe-herdr`, `probe-tmux`), which start the tool with only
/// the variables it needs: no herdr or tmux variable of the driver's or the user's reaches it, and neither reads the
/// user's config. A step only looks; the driver's exit trap ends what the probe started and removes the scratch root.
///
/// `keep-probe-start` runs both in tabs, notes their servers' pids in `probe-pids`, and quits through the update sheet's
/// Update Now. `keep-probe-after-update` looks at them, attaches a tab to each again, and quits as the user does.
/// `keep-probe-after-quit` looks at them once more. Each look is a RESULT line in the report and a value in
/// `probe-result.json`: survived (the same server, still answering), died, or skipped (the tool is not on this Mac).
@MainActor
enum SelfTestKeepProbe {
    typealias Harness = SelfTestRestore.Harness

    /// One of the two tools the probe starts.
    enum Tool: String, CaseIterable, Sendable {
        case herdr
        case tmux
    }

    /// What the driver set up for the probe.
    struct Probe: Sendable {
        let harness: Harness
        /// The herdr session and the tmux socket name: nt-probe-<driver's pid>.
        let session: String
        /// The scratch root, private, outside the user's folders.
        let root: String
        let tools: [Tool: String]

        init?(_ harness: Harness) {
            let file = harness.folder.appendingPathComponent("probe-tools")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            var values: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            guard let session = values["session"], session.hasPrefix("nt-probe-"),
                  let root = values["root"], root.hasPrefix("/"), PrivateFolder.isPrivate(root) else { return nil }
            self.harness = harness
            self.session = session
            self.root = root
            var tools: [Tool: String] = [:]
            for tool in Tool.allCases {
                if let path = values[tool.rawValue], path.hasPrefix("/") { tools[tool] = path }
            }
            self.tools = tools
        }

        /// The variables every look runs the tools with: the scratch ones, and no others of the app's.
        var environment: [String: String] {
            [
                "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                "XDG_CONFIG_HOME": root + "/c", "XDG_DATA_HOME": root + "/d", "XDG_STATE_HOME": root + "/s",
                "XDG_CACHE_HOME": root + "/k", "XDG_RUNTIME_DIR": root + "/r", "TMUX_TMPDIR": root + "/t",
            ]
        }

        /// Where each tool's server listens.
        func socket(_ tool: Tool) -> String {
            switch tool {
            case .herdr: return root + "/c/herdr/sessions/" + session + "/herdr.sock"
            case .tmux: return root + "/t/tmux-\(getuid())/" + session
            }
        }

        func launcher(_ tool: Tool) -> URL { harness.folder.appendingPathComponent("probe-" + tool.rawValue) }
        var pids: URL { harness.folder.appendingPathComponent("probe-pids") }
        var result: URL { harness.folder.appendingPathComponent("probe-result.json") }
    }

    // MARK: the steps

    static func start(_ harness: Harness) async {
        SelfTestRestore.record("STEP keep-probe-start, version \(Updater.shared.current?.description ?? "none")")
        SelfTestRestore.isolationChecks(harness)
        // The user's own defaults and Application Support as they are now, for the last step to compare.
        SelfTestRestore.recordRealState(harness)
        guard let probe = Probe(harness) else {
            check(false, "the driver named the probe's session, scratch root and tools")
            return SelfTestRestore.finish()
        }
        let app = AppDelegate.shared!
        let controller = app.openFolder(harness.project.path, newWindow: false)
        let tabs: [Tool: TerminalTab] = await openTabs(probe, in: controller)
        var pids: [String] = []
        for tool in Tool.allCases {
            guard let tab = tabs[tool] else {
                record(probe, tool, step: "start", "skipped")
                continue
            }
            let holders: [pid_t] = await up(probe, tool)
            let answers: Bool = await answers(probe, tool)
            check(!holders.isEmpty && answers && tab.status.running,
                  "keep probe: \(tool.rawValue), started in a tab, runs its server on the scratch socket and answers there",
                  "holders \(holders), answers \(answers), the tab's command running \(tab.status.running)")
            pids += holders.map { "\(tool.rawValue) \($0)" }
        }
        try? (pids.joined(separator: "\n") + "\n").write(to: probe.pids, atomically: true, encoding: .utf8)
        guard !pids.isEmpty else {
            SelfTestRestore.record("RESULT nothing to probe: neither herdr nor tmux is on this Mac")
            return SelfTestRestore.finish()
        }

        // The update quit, through the update sheet's real button, as the user's.
        let version: AppVersion
        do {
            version = try await Updater.shared.stageStandIn(harness.update, in: harness.staging, replacing: harness.install,
                                                             opener: harness.opener)
        } catch {
            check(false, "keep probe: the stand-in update is staged", (error as? Updater.UpdateError)?.text ?? "\(error)")
            return SelfTestRestore.finish()
        }
        check(Updater.shared.badge == .relaunch(version), "keep probe: the stand-in update is staged")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        }
        Updater.shared.showAvailable()
        SelfTestRestore.press([UpdateButton.updateNow.title])
        SelfTestRestore.record("STEP keep-probe-start: quitting through the update")
        // The press quits the app; reached only when the quit did not go ahead.
        await SelfTest.pause(60)
        check(false, "keep probe: the update quit goes ahead")
        SelfTestRestore.finish()
    }

    static func afterUpdate(_ harness: Harness) async {
        SelfTestRestore.record("STEP keep-probe-after-update, version \(Updater.shared.current?.description ?? "none")")
        SelfTestRestore.isolationChecks(harness)
        SelfTestRestore.leakChecks(harness)
        let updateVersion = Bundle(url: harness.update)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        check(Updater.shared.current?.description == updateVersion, "keep probe: the install put the update in place",
              "\(Updater.shared.current?.description ?? "none"), update \(updateVersion ?? "none")")
        guard let probe = Probe(harness) else {
            check(false, "the driver named the probe's session, scratch root and tools")
            return SelfTestRestore.finish()
        }
        let survived: [Tool] = await look(probe, step: "after-update")
        // A tab on each server that is still there, as the user attaches again after an update: the quit that follows
        // then ends a tab attached to it, as the first one did.
        let app = AppDelegate.shared!
        let controller = app.openFolder(harness.project.path, newWindow: false)
        let tabs: [Tool: TerminalTab] = await openTabs(probe, in: controller, only: survived)
        for tool in survived {
            let attached: Bool = await SelfTest.wait(10) { tabs[tool]?.status.running == true }
            check(attached, "keep probe: a tab attaches to the \(tool.rawValue) server that outlived the update")
        }
        SelfTestRestore.record("STEP keep-probe-after-update: quitting")
        SelfTestRestore.answerQuitQuestion(box: false, press: QuitPromptButton.quit.title)
        NSApp.terminate(nil)
        check(false, "keep probe: the quit goes ahead")
        SelfTestRestore.finish()
    }

    static func afterQuit(_ harness: Harness) async {
        SelfTestRestore.record("STEP keep-probe-after-quit")
        SelfTestRestore.isolationChecks(harness)
        // Nothing of the user's own changed across the three launches.
        SelfTestRestore.realStateChecks(harness, step: "keep-probe-after-quit")
        guard let probe = Probe(harness) else {
            check(false, "the driver named the probe's session, scratch root and tools")
            return SelfTestRestore.finish()
        }
        _ = await look(probe, step: "after-quit")
        SelfTestRestore.finish()
    }

    /// The quit's last save is written: the step's last line, as the app's own quit ends the process.
    static func quitSaved() {
        SelfTestRestore.recordStepEnd()
    }

    // MARK: looking

    /// Each tool's server after a relaunch: the same process the first step noted, still on its socket, still answering.
    /// Returns the tools whose server survived.
    private static func look(_ probe: Probe, step: String) async -> [Tool] {
        let noted: [Tool: [pid_t]] = notedPids(probe)
        var survived: [Tool] = []
        for tool in Tool.allCases {
            guard let before = noted[tool], !before.isEmpty else {
                record(probe, tool, step: step, "skipped")
                continue
            }
            let holders: Set<pid_t> = Set(await socketHolders(probe.socket(tool)))
            let same: [pid_t] = before.filter { (pid: pid_t) -> Bool in kill(pid, 0) == 0 && holders.contains(pid) }
            let answering: Bool = await answers(probe, tool)
            let kept: Bool = !same.isEmpty && answering
            record(probe, tool, step: step, kept ? "survived" : "died",
                   "noted \(before), on the socket now \(holders.sorted()), answers \(answering)")
            if kept { survived.append(tool) }
        }
        return survived
    }

    /// The pids the first step noted, by tool.
    private static func notedPids(_ probe: Probe) -> [Tool: [pid_t]] {
        let text = (try? String(contentsOf: probe.pids, encoding: .utf8)) ?? ""
        var noted: [Tool: [pid_t]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let tool = Tool(rawValue: String(parts[0])), let pid = pid_t(parts[1]) else { continue }
            noted[tool, default: []].append(pid)
        }
        return noted
    }

    /// One look's outcome: a RESULT line in the report, and its value in `probe-result.json`.
    private static func record(_ probe: Probe, _ tool: Tool, step: String, _ outcome: String, _ detail: String = "") {
        SelfTestRestore.record("RESULT \(tool.rawValue) \(step): \(outcome)" + (detail.isEmpty ? "" : " — " + detail))
        var results: [String: [String: String]] = [:]
        if let data = try? Data(contentsOf: probe.result),
           let read = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            results = read
        }
        results[tool.rawValue, default: [:]][step] = outcome
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: probe.result)
    }

    // MARK: the tabs

    /// A tab per tool on this Mac (or in `only`), each running the tool through its launcher once the shell is ready.
    private static func openTabs(_ probe: Probe, in controller: TerminalWindowController,
                                 only: [Tool]? = nil) async -> [Tool: TerminalTab] {
        var tabs: [Tool: TerminalTab] = [:]
        for tool in Tool.allCases where probe.tools[tool] != nil && (only?.contains(tool) ?? true) {
            tabs[tool] = controller.addTab(directory: probe.harness.project.path, select: false)
        }
        let ready: Bool = await SelfTest.wait(20) { tabs.values.allSatisfy(\.status.integrated) }
        check(ready, "keep probe: the probe's tabs start their shells")
        for (tool, tab) in tabs {
            tab.view.send(txt: "/bin/sh " + quoted(probe.launcher(tool).path) + "\r")
        }
        return tabs
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The processes holding `tool`'s socket once it is there, within 20 seconds; none when it never came up.
    private static func up(_ probe: Probe, _ tool: Tool) async -> [pid_t] {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let holders: [pid_t] = await socketHolders(probe.socket(tool))
            if !holders.isEmpty { return holders }
            await SelfTest.pause(0.3)
        }
        return []
    }

    /// Whether `tool`'s server answers on the scratch socket: herdr's status says running, tmux has the session.
    private static func answers(_ probe: Probe, _ tool: Tool) async -> Bool {
        guard let path = probe.tools[tool] else { return false }
        var environment = probe.environment
        let argv: [String]
        switch tool {
        case .herdr:
            environment["HERDR_SOCKET_PATH"] = probe.socket(.herdr)
            argv = [path, "status", "server"]
        case .tmux:
            argv = [path, "-L", probe.session, "has-session", "-t", "probe"]
        }
        let ran: LocalHerdr.Ran = await run(argv, environment: environment)
        guard ran.status == 0 else { return false }
        guard tool == .herdr else { return true }
        return String(decoding: ran.output, as: UTF8.self).contains("status: running")
    }

    /// The processes that have `socket` open, by lsof; none when nothing has.
    private static func socketHolders(_ socket: String) async -> [pid_t] {
        guard FileManager.default.fileExists(atPath: socket) else { return [] }
        let ran: LocalHerdr.Ran = await run(["/usr/sbin/lsof", "-t", "--", socket], environment: ["PATH": "/usr/bin:/bin"])
        return String(decoding: ran.output, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Runs one process, no shell, off the main thread, for at most 10 seconds.
    private static func run(_ argv: [String], environment: [String: String]) async -> LocalHerdr.Ran {
        await Task.detached {
            LocalHerdr.run(argv, environment: environment, timeout: 10)
        }.value
    }

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        SelfTestRestore.check(ok, name, detail())
    }
}
#endif
