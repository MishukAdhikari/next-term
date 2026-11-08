import AppKit
import NextTermCore
import UserNotifications

/// Settings › Agents' side in the app (plan 038): it reads the agents' copies along the login shell's PATH
/// (AgentCLIs), asks each one's latest version (cached a day, off the main thread, never before the section is opened or
/// an update is due), keeps each agent's schedule (Off until the user picks Daily or Weekly), and runs a due update in
/// the background: the login shell's PATH, a clean environment, never sudo, ten minutes at most, its output in a log
/// in Application Support, and one notification when it is done.
///
/// A scheduled update waits while a tab runs that agent or any process of it is running, so it never pulls the files
/// from under a session, nor comes while the user types to it. It is looked at a minute after launch, on waking and
/// every hour: no daemon, nothing between launches. The self-test gives it a PATH, a latest lookup, defaults and a log
/// folder of its own, so it never reads the user's agents, their schedules or the network.
@MainActor
final class AgentCLIManager {
    static let shared = AgentCLIManager()
    /// Posted on the main thread when `statuses`, `updating` or `checking` change.
    static let changed = Notification.Name("AgentCLIManager.changed")

    // The self-test's stand-ins.
    static var pathForTest: [String]?
    nonisolated(unsafe) static var latestForTest: ((AgentCLIs.Latest) -> String?)?
    static var defaultsForTest: UserDefaults?
    static var logFolderForTest: String?

    static let schedulesKey = "AgentCLISchedules"
    static let lastTriesKey = "AgentCLILastTries"
    static let cacheKey = "AgentCLILatest"

    /// Every agent of the catalog, installed or not, as the last look found it.
    private(set) var statuses: [AgentCLIs.Status] = AgentCLIs.catalog.map { AgentCLIs.Status(agent: $0, copies: []) }
    /// The agents a background update runs for now.
    private(set) var updating: Set<String> = []
    /// A look along PATH, or a check of the latest versions, is under way.
    private(set) var checking = false
    /// When the latest versions were last asked.
    private(set) var checkedAt: Date?
    /// Has looked along PATH at least once.
    private(set) var looked = false

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var scheduledLook = false

    /// The schedules, the tries and the cache: the user's, or (in any self-test, whether or not its part set its own)
    /// a volatile domain of the run's own, never Next Term's prefs.
    private var defaults: UserDefaults { Self.defaultsForTest ?? (SelfTest.isRequested ? Self.selfTestDefaults : .standard) }
    private static let selfTestDefaults: UserDefaults = {
        let name = "nt-selftest-agentclis-\(getpid())"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    /// The PATH looked along: the self-test's own (none, unless its part gives one), else the login shell's.
    private static var testPath: [String]? { pathForTest ?? (SelfTest.isRequested ? [] : nil) }

    // MARK: What is kept

    func schedule(_ id: String) -> AgentCLIs.Schedule {
        let saved = defaults.dictionary(forKey: Self.schedulesKey) as? [String: String]
        return saved?[id].flatMap(AgentCLIs.Schedule.init(rawValue:)) ?? .off
    }

    func setSchedule(_ schedule: AgentCLIs.Schedule, for id: String) {
        var saved = defaults.dictionary(forKey: Self.schedulesKey) as? [String: String] ?? [:]
        saved[id] = schedule == .off ? nil : schedule.rawValue
        defaults.set(saved.isEmpty ? nil : saved, forKey: Self.schedulesKey)
        refreshKept()
    }

    func lastTry(_ id: String) -> Date? {
        (defaults.dictionary(forKey: Self.lastTriesKey) as? [String: Date])?[id]
    }

    private func setLastTry(_ date: Date, for id: String) {
        var saved = defaults.dictionary(forKey: Self.lastTriesKey) as? [String: Date] ?? [:]
        saved[id] = date
        defaults.set(saved, forKey: Self.lastTriesKey)
    }

    private var cache: AgentCLIs.LatestCache {
        get {
            guard let data = defaults.data(forKey: Self.cacheKey),
                  let cache = try? JSONDecoder().decode(AgentCLIs.LatestCache.self, from: data) else { return AgentCLIs.LatestCache() }
            return cache
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.cacheKey) }
    }

    private func refreshKept() {
        statuses = statuses.map { status in
            var status = status
            status.schedule = schedule(status.agent.id)
            status.lastTry = lastTry(status.agent.id)
            return status
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Looking

    /// Looks along PATH again, and with `fetch` asks the latest versions (each source once a day at most; `force`, as
    /// Check for Updates does, asks again). `done` runs on the main thread after.
    func reload(fetch: Bool, force: Bool = false, only ids: Set<String>? = nil, done: (() -> Void)? = nil) {
        checking = true
        NotificationCenter.default.post(name: Self.changed, object: self)
        let path = Self.testPath
        let cache = self.cache
        let previous = statuses
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = path ?? LoginShell.path
            var found: [AgentCLIs.Status] = []
            var cache = cache
            let now = Date()
            for agent in AgentCLIs.catalog {
                guard ids?.contains(agent.id) ?? true else {
                    found.append(previous.first { $0.agent.id == agent.id } ?? AgentCLIs.Status(agent: agent, copies: []))
                    continue
                }
                var copies = AgentCLIs.copies(of: agent, path: folders)
                if var first = copies.first, first.version == nil, let arguments = agent.versionArguments {
                    first.version = Self.runVersion(first.path, arguments)
                    copies[0] = first
                }
                var status = AgentCLIs.Status(agent: agent, copies: copies)
                if let source = status.latestSource {
                    if !force, let fresh = cache.fresh(source, now: now) {
                        status.latest = fresh.version
                    } else if fetch {
                        let (version, answered) = Self.fetchLatest(source)
                        // No answer (offline) keeps what was known, and asks again next time; a server's answer that
                        // names none is kept the day, like a version.
                        cache.record(version, answered: answered, for: source, now: now)
                        status.latest = version ?? cache.entries[source.key]?.version
                    } else {
                        status.latest = cache.entries[source.key]?.version
                    }
                }
                found.append(status)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.statuses = found
                    self.cache = cache
                    self.checking = false
                    self.looked = true
                    if fetch { self.checkedAt = now }
                    self.refreshKept()
                    done?()
                }
            }
        }
    }

    /// What `runVersion` found, by program and its file's modification date: a look again (each time Settings comes
    /// forward) runs no program whose file hasn't changed.
    nonisolated(unsafe) private static var printedVersions: [String: String] = [:]
    nonisolated private static let printedLock = NSLock()

    /// The version a copy prints (its first line's), in 3 seconds at most: only for a copy whose files say none. Its
    /// output goes to a file, never a pipe, so a process it leaves behind holding its output can't keep the read waiting.
    nonisolated static func runVersion(_ program: String, _ arguments: [String]) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: canonicalPath(program)))?[.modificationDate] as? Date
        let key = "\(program)\u{0}\(arguments.joined(separator: " "))\u{0}\(modified?.timeIntervalSince1970 ?? 0)"
        printedLock.lock()
        let known = printedVersions[key]
        printedLock.unlock()
        if let known { return known }
        let found = printVersion(program, arguments)
        if let found {
            printedLock.lock()
            printedVersions[key] = found
            printedLock.unlock()
        }
        return found
    }

    nonisolated private static func printVersion(_ program: String, _ arguments: [String]) -> String? {
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-agent-version-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        var environment = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        let data = (try? FileHandle(forReadingFrom: output)).flatMap { reader in
            defer { try? reader.close() }
            return try? reader.read(upToCount: 4096)
        }
        return data.flatMap { AgentSessionVersion.parse(String(decoding: $0, as: UTF8.self)) }
    }

    /// The latest version `source` names, asked now (10 seconds at most), and whether its server answered at all.
    nonisolated static func fetchLatest(_ source: AgentCLIs.Latest) -> (version: String?, answered: Bool) {
        if let stub = latestForTest { return (stub(source), true) }
        if SelfTest.isRequested { return (nil, false) } // a self-test never asks the network
        guard let url = source.url else { return (nil, false) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("NextTerm", forHTTPHeaderField: "User-Agent")
        if case .github = source { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: Data?
        nonisolated(unsafe) var status: Int?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if status == 200 { answer = data }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            return (nil, false)
        }
        // A 404 (a package gone or renamed) is an answer; a rate limit or a server's error is not.
        let answered = status.map { $0 == 200 || $0 == 404 || $0 == 410 } ?? false
        return (answer.flatMap(source.parse), answered)
    }

    // MARK: Updating where the user sees it

    /// Update Now: a new tab in the home folder running the exact command, so the user sees every line of it.
    func updateInTab(_ status: AgentCLIs.Status) {
        guard let copy = status.copy, let command = AgentCLIs.updateCommand(status.agent, copy) else { return }
        // It counts as the schedule's try: no background update of the same copy comes while this one runs in its tab.
        if schedule(status.agent.id) != .off { setLastTry(Date(), for: status.agent.id) }
        openTab(command: command, title: "Update \(status.agent.name)", submit: true)
    }

    /// Install…: the tool's own one-line installer typed in a new tab, for the user to read and run.
    func installInTab(_ agent: AgentCLIs.Agent) {
        guard let installer = agent.installer else { return }
        openTab(command: installer, title: "Install \(agent.name)", submit: false)
    }

    private func openTab(command: String, title: String, submit: Bool) {
        let home = NSHomeDirectory()
        let front = TerminalWindow.front?.windowController as? TerminalWindowController
        let controller = front ?? AppDelegate.shared.openWindow(directory: home)
        controller.runInNewTab(directory: home, command: command, title: title, submit: submit)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Scheduled updates

    /// Starts the looks: a minute after launch, on waking, and every hour. Never in the self-test, which drives `look`.
    func start() {
        guard observers.isEmpty, !SelfTest.isRequested else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                           queue: .main) { _ in
            MainActor.assumeIsolated { AgentCLIManager.shared.soon() }
        })
        let hourly = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { AgentCLIManager.shared.look() }
        }
        hourly.tolerance = 10 * 60
        RunLoop.main.add(hourly, forMode: .common)
        timer = hourly
        soon()
    }

    private func soon() {
        guard !scheduledLook else { return }
        scheduledLook = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated {
                self.scheduledLook = false
                self.look()
            }
        }
    }

    /// One look: each agent whose schedule is due is looked along PATH again, its latest version asked, and updated in
    /// the background unless it is running, up to date, or not Next Term's to update. With every schedule Off (the
    /// default), nothing is read at all.
    func look(now: Date = Date(), done: (() -> Void)? = nil) {
        let due = AgentCLIs.catalog.filter { AgentCLIs.isDue(schedule($0.id), lastTry: lastTry($0.id), now: now) && !updating.contains($0.id) }
        guard !due.isEmpty, !checking else {
            done?()
            return
        }
        reload(fetch: true, only: Set(due.map(\.id))) { [self] in
            let looked = due.compactMap { agent in statuses.first(where: { $0.agent.id == agent.id }) }
            // Every process's arguments, and their paths resolved, are read off the main thread.
            DispatchQueue.global(qos: .utility).async {
                let processes = Self.processes()
                let busy = Set(looked.filter { AgentCLIs.isRunning($0.agent, copies: $0.copies, processes: processes) }.map(\.agent.id))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.decide(looked, busy: busy, now: now, done: done) }
                }
            }
        }
    }

    /// The decisions of one look, on the main thread: `busy`, the agents a process runs (read off it).
    private func decide(_ looked: [AgentCLIs.Status], busy: Set<String>, now: Date, done: (() -> Void)?) {
        for status in looked {
            let agent = status.agent
            guard !updating.contains(agent.id) else { continue }
            let running = busy.contains(agent.id) || tabRuns(agent)
            let decision = AgentCLIs.decide(agent, copy: status.copy, schedule: schedule(agent.id), lastTry: lastTry(agent.id),
                                            now: now, running: running, latest: status.latest)
            switch decision {
            case .update(let command):
                setLastTry(now, for: agent.id)
                runInBackground(status, command: command)
            case .skip(let skip):
                if skip.counts { setLastTry(now, for: agent.id) }
            }
        }
        refreshKept()
        done?()
    }

    /// A local tab runs `agent` now.
    private func tabRuns(_ agent: AgentCLIs.Agent) -> Bool {
        AppDelegate.shared.controllers.flatMap(\.tabs).contains { tab in
            tab.remote == nil && tab.status.running && tab.status.kind == .agent
                && (agent.programs.contains(tab.status.program) || CommandClassifier.agentName(tab.status.command).map(agent.programs.contains) == true)
        }
    }

    /// Every process of the user's now: its executable and argv.
    nonisolated private static func processes() -> [(executable: String, arguments: [String])] {
        (ProcessSnapshot.take() ?? []).compactMap { record in
            // Another user's arguments can't be read: only the user's own processes come back.
            guard record.pid > 1, let line = ProcessInspector.commandLine(of: record.pid) else { return nil }
            return (line.path, line.arguments)
        }
    }

    /// The log a background update writes to.
    func logURL(_ id: String) -> URL {
        let folder = Self.logFolderForTest
            ?? (SelfTest.isRequested ? NSTemporaryDirectory() + "nt-agent-updates-\(getpid())" : nil)
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Next Term/Agent Updates")
        return URL(fileURLWithPath: folder).appendingPathComponent("\(id).log")
    }

    /// Runs `command` for `status`'s agent, off the main thread: the login shell's PATH (the copy's own npm or brew
    /// first), a clean environment, no input, ten minutes at most. Its output goes to the agent's log; then one
    /// notification.
    func runInBackground(_ status: AgentCLIs.Status, command: String, timeout: TimeInterval = 600) {
        let agent = status.agent
        guard let copy = status.copy, !updating.contains(agent.id) else { return }
        updating.insert(agent.id)
        NotificationCenter.default.post(name: Self.changed, object: self)
        let log = logURL(agent.id)
        let testPath = Self.testPath
        let before = copy.version
        DispatchQueue.global(qos: .utility).async {
            let environment = AgentCLIs.backgroundEnvironment(TerminalEnvironment.clean(ProcessInfo.processInfo.environment),
                                                              path: testPath ?? LoginShell.path, copy: copy)
            let result = Self.run(command, environment: environment, log: log, timeout: timeout)
            let after = AgentCLIs.copies(of: agent, path: testPath ?? LoginShell.path).first
            var version = after?.version
            if version == nil, let after, let arguments = agent.versionArguments { version = Self.runVersion(after.path, arguments) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.updating.remove(agent.id)
                    self.finished(agent, status: result, before: before, after: version, log: log)
                    self.reload(fetch: false, only: [agent.id])
                }
            }
        }
    }

    /// The command's exit status, or nil when it ran out of time or could not start. Its output is appended to `log`.
    nonisolated static func run(_ command: String, environment: [String: String], log: URL, timeout: TimeInterval) -> (code: Int32?, last: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        AgentCLIs.trimLog(at: log) // a log of every update ever would only grow
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n\u{2014} \(stamp)  \(command)\n"
        if !manager.fileExists(atPath: log.path) { manager.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return (nil, "Its log couldn\u{2019}t be written.") }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(header.utf8))
        let start = (try? handle.offset()) ?? 0
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return (nil, "It couldn\u{2019}t start.") }
        var code: Int32?
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // The shell's children (npm, brew, curl) first: ending only the shell would leave them running on.
            let children = AgentCLIs.descendants(of: process.processIdentifier, in: ProcessSnapshot.take() ?? [])
            for child in children { kill(child, SIGTERM) }
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                for child in children { kill(child, SIGKILL) }
                kill(process.processIdentifier, SIGKILL)
            }
        } else {
            code = process.terminationStatus
        }
        let end = (try? handle.seekToEnd()) ?? start
        var last = ""
        // The output's last line, read before the exit line goes in after it.
        if end > start, let reader = try? FileHandle(forReadingFrom: log) {
            let from = end > start + 4096 ? end - 4096 : start
            try? reader.seek(toOffset: from)
            let tail = String(decoding: (try? reader.read(upToCount: Int(end - from))) ?? Data(), as: UTF8.self)
            last = tail.split(whereSeparator: \.isNewline).last.map { String($0.prefix(160)) } ?? ""
            try? reader.close()
        }
        try? handle.write(contentsOf: Data("\u{2014} exit \(code.map(String.init) ?? "none: ran out of time")\n".utf8))
        if code == nil { last = "It took longer than \(Int(timeout / 60)) minutes and was stopped." }
        return (code, last)
    }

    nonisolated static let logKey = "agent_cli_log"

    /// One notification for a finished update: updated to its new version, or why not, with Show Log. An update that
    /// changed nothing says nothing.
    private func finished(_ agent: AgentCLIs.Agent, status: (code: Int32?, last: String), before: String?, after: String?, log: URL) {
        let content = UNMutableNotificationContent()
        if status.code == 0 {
            guard let after, after != before else { return }
            content.title = "\(agent.name) updated to \(after)"
            content.body = before.map { "It was \($0). The new version runs from its next start." } ?? "The new version runs from its next start."
        } else {
            content.title = "Couldn\u{2019}t update \(agent.name)"
            content.body = status.last.isEmpty ? "It stopped with exit code \(status.code.map(String.init) ?? "none")." : status.last
        }
        guard let delegate = AppDelegate.shared else { return }
        let sound = NotificationSettings(defaults: .standard).sound && Date().timeIntervalSince(delegate.lastSoundAt) >= 3
        content.sound = sound ? .default : nil
        if sound { delegate.lastSoundAt = Date() }
        content.threadIdentifier = "agent-updates"
        content.userInfo = [Self.logKey: log.path]
        content.categoryIdentifier = delegate.showLogCategory()
        delegate.deliver(UNNotificationRequest(identifier: "agent-update-\(agent.id)", content: content, trigger: nil))
    }

    /// list_agent_clis: a look along PATH now, with the latest versions as last asked (no network).
    static func listForMCP(all: Bool, reply: @escaping MCPControl.Reply) {
        shared.reload(fetch: false) {
            reply(MCPControl.ok(AgentCLIs.answer(shared.statuses, all: all)))
        }
    }

    /// Show Log, or a click on an update's notification: the log, in the app that opens text.
    static func showLog(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
