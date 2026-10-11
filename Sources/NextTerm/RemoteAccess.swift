import AppKit
import IOKit.ps
import NextTermCore
import UserNotifications

/// Remote access's controller (U9): the saved setting, off by default (R1), and its life from the switch to quit.
///
/// `RemoteAccessStatus` (Core) decides; this runs its effects and sends back what they report. A start goes in the
/// plan's order: agent control on, U1's scope tag check, the saved settings, the tunnel token read once from the
/// Keychain (Cloudflare only, silently, R44), the door bound on the saved port (or one picked at first turn-on, R2),
/// then the tunnel, which never starts before the bind. Turning off closes the door within a second, answering
/// open calls and dropping access tokens, then stops the tunnel (R37). Quit does the same and waits for the tunnel
/// in place (R42). While the door is open the Mac stays awake on power (R41).
///
/// The tunnel is U10's supervisor (`RemoteAccessTunnel`, through `RemoteAccessTunnelRunner`): the child, its checks,
/// restarts and watchdog. "Advanced: I expose the port myself" runs none.
///
/// Under `--self-test` (KTD18) it keeps its settings in memory, its files in a temp folder of its own and the token
/// in memory, so a test run never touches the user's setup; it starts off. The relaunch harness keeps the settings
/// and files in its own suite and folder instead, so a relaunch with Remote access saved on can be checked (R43).
@MainActor
final class RemoteAccess {
    static let shared = RemoteAccess()

    /// Posted on the main thread when the status, the settings or the grants change (U11's views and status item).
    static let didChange = Notification.Name("NextTermRemoteAccessDidChange")

    /// What is saved: the switch, the port, the public hostname, the tunnel and Keep Awake on Battery. The token is
    /// in the Keychain, never here.
    struct Settings: Equatable {
        var on = false
        var port: UInt16?
        var host: String?
        var tunnel: RemoteAccessTunnelConfig.Kind?
        var keepAwakeOnBattery = false

        private enum Key {
            static let on = "remoteAccess"
            static let port = "remoteAccessPort"
            static let host = "remoteAccessHost"
            static let tunnel = "remoteAccessTunnel"
            static let keepAwake = "remoteAccessKeepAwakeOnBattery"
        }

        init() {}

        init(defaults: UserDefaults) {
            on = defaults.bool(forKey: Key.on)
            let port = defaults.integer(forKey: Key.port)
            self.port = port > 0 && port <= Int(UInt16.max) ? UInt16(port) : nil
            let host = defaults.string(forKey: Key.host).map(RemoteAccessTunnelConfig.publicHostname)
            if case .success(let name)? = host { self.host = name }
            tunnel = defaults.string(forKey: Key.tunnel).flatMap(RemoteAccessTunnelConfig.Kind.init(rawValue:))
            keepAwakeOnBattery = defaults.bool(forKey: Key.keepAwake)
        }

        func save(to defaults: UserDefaults) {
            defaults.set(on, forKey: Key.on)
            defaults.set(port.map { Int($0) }, forKey: Key.port)
            defaults.set(host, forKey: Key.host)
            defaults.set(tunnel?.rawValue, forKey: Key.tunnel)
            defaults.set(keepAwakeOnBattery, forKey: Key.keepAwake)
        }
    }

    private(set) var status = RemoteAccessStatus()
    private(set) var settings: Settings
    /// The open door's state: Connect a Client, the grants, Revoke (U11). A new one each start.
    private(set) var doorState: RemoteAccessDoorState?
    private(set) var door: RemoteAccessServer?
    /// The Remote access folder: the grants, the audit log and the tunnel's pid record.
    let folder: URL
    let tokens: RemoteAccessTokenStore
    /// What runs the tunnel: U10's supervisor.
    var tunnel: RemoteAccessTunnelRunner {
        didSet { connect(tunnel) }
    }

    private let defaults: UserDefaults?
    /// The tunnel token, read once per start and held in memory only while the switch is on (R44).
    private var token: RemoteAccessTunnelConfig.Token?
    private var pending: [RemoteAccessStatus.Event] = []
    private var handling = false
    /// Each start's number, so a Keychain answer that comes after another start is dropped.
    private var run = 0
    /// When quit began, while it runs: the tunnel's end is counted from it, so quit waits at most 3 seconds (R42).
    private var quitBegan: DispatchTime?
    private var activity: NSObjectProtocol?
    private var awake: RemoteAccessAwake?
    private var powerSource: CFRunLoopSource?
    private var wake: NSObjectProtocol?

    private init() {
        if SelfTest.isRequested {
            // The plain self-test keeps none (nil); the relaunch harness its own suite.
            defaults = SelfTest.keptDefaults
            folder = Self.selfTestFolder()
            tokens = RemoteAccessMemoryTokens()
            settings = SelfTest.keptDefaults.map(Settings.init(defaults:)) ?? Settings()
        } else {
            folder = RemoteAccessStore.defaultFolder()
            defaults = .standard
            tokens = RemoteAccessKeychain()
            settings = Settings(defaults: .standard)
        }
        tunnel = RemoteAccessTunnel(folder: folder)
        connect(tunnel)
        let center = NSWorkspace.shared.notificationCenter
        let woke = NSWorkspace.didWakeNotification
        wake = center.addObserver(forName: woke, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
    }

    /// The self-test's Remote access folder: the relaunch harness's, kept across its relaunch, else a temp one for
    /// this process.
    private static func selfTestFolder() -> URL {
        if SelfTest.mode == .relaunchHarness, let support = SelfTest.supportFolder {
            return support.appendingPathComponent("remote-access", isDirectory: true)
        }
        let name = "nextterm-remote-access-\(getpid())"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// The switch is on: from the start until Off, PortBusy or Stopped. The update sheet's note follows it.
    var isOn: Bool { status.isOn }

    // MARK: the app's hooks (AppDelegate)

    /// After launch: a tunnel a crash left behind is ended (R42), then Remote access starts again if it was saved
    /// on, and the Mac is told once it is on, or that it waits for the Keychain or didn't start (R43, R44).
    func launched() {
        endLeftoverTunnel()
        guard settings.on else { return }
        start(launch: true)
    }

    /// "Let agents control Next Term" changed: off turns Remote access off and saves it off (R1).
    func agentControlChanged(_ on: Bool) {
        guard !on else { return }
        send(.agentControlOff)
    }

    /// Quit, as `applicationWillTerminate`'s first call, so the public door closes before anything else. Timers
    /// never fire after it, so everything happens in place: the door closes, open calls are answered, access tokens
    /// are dropped, the grants file and the audit log are written, and the tunnel is ended (SIGTERM, again after 1
    /// second, SIGKILL after 3), its pid record deleted once it is gone (R42). All of it is counted from here, so
    /// quit waits at most 3 seconds. The setting stays as saved, so a relaunch starts it again. The self-test calls
    /// this directly.
    func stopForQuit() {
        quitBegan = .now()
        defer { quitBegan = nil }
        send(.quit)
    }

    // MARK: Settings and the status item (U11)

    func turnOn() {
        start(launch: false)
    }

    /// Turn Off, or Turn Off and Revoke All (R37). Again does nothing.
    func turnOff(revokeAll: Bool = false) {
        send(.turnOff(revokeAll: revokeAll))
    }

    /// "Allow Keychain access": the token is read again with the system's prompt allowed (R44).
    func allowKeychainAccess() {
        send(.allowKeychainAccess)
    }

    func confirmHost() {
        send(.confirmHost)
    }

    func declineHost() {
        send(.declineHost)
    }

    /// PortBusy's or Stopped's message was read.
    func dismiss() {
        send(.dismiss)
    }

    /// A change to the saved settings. The tunnel, the host and the port apply at the next start; Keep Awake on
    /// Battery at once. The switch itself changes only through `turnOn` and `turnOff`.
    func change(_ body: (inout Settings) -> Void) {
        var changed = settings
        body(&changed)
        changed.on = settings.on
        guard changed != settings else { return }
        settings = changed
        save()
        keepAwake()
        changedNotice()
    }

    // MARK: the reducer's loop

    /// Hands `event` to the reducer and runs its effects in order. An effect's own report (the bind, the token,
    /// the tunnel) waits for the effects before it, so each event sees the state the last one left.
    private func send(_ event: RemoteAccessStatus.Event) {
        pending.append(event)
        guard !handling else { return }
        handling = true
        defer { handling = false }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let before = status
            let effects = status.handle(next)
            for effect in effects { perform(effect, in: effects) }
            if !status.isOn { token = nil }
            keepAwake()
            if status != before { changedNotice() }
        }
    }

    private func start(launch: Bool) {
        guard !status.isOn else { return }
        run += 1
        token = nil
        let agentControl = AppDelegate.shared?.agentControl ?? false
        let choice = RemoteAccessPort.choose(saved: settings.port, isFree: Self.isFree)
        let start = RemoteAccessStatus.Start(tunnel: settings.tunnel, host: settings.host, port: choice,
                                             agentControl: agentControl,
                                             scopeCheck: RemoteAccessTools.startCheck()?.description,
                                             launch: launch)
        send(.turnOn(start))
    }

    private func perform(_ effect: RemoteAccessStatus.Effect, in batch: [RemoteAccessStatus.Effect]) {
        switch effect {
        case .savePort(let port):
            settings.port = port
            save()
        case .saveOn:
            settings.on = true
            save()
        case .saveOff:
            settings.on = false
            save()
        case .saveHost(let host):
            settings.host = host
            save()
            doorState?.setHost(host)
        case .readToken(let interactive):
            readToken(interactive: interactive)
        case .bindDoor(let port):
            openDoor(port)
        case .startTunnel:
            guard let kind = status.tunnel, let port = status.port else { return }
            tunnel.start(kind, port: port, host: status.host, token: token)
        case .closeDoor:
            door?.stop(revokeAll: batch.contains(.dropTokens(revokeAll: true)))
            // At quit, the answers the stop queued reach their connections before the process ends.
            if quitBegan != nil { door?.drain() }
        case .dropTokens(let revokeAll):
            doorClosed(revokeAll: revokeAll)
        case .stopTunnel:
            tunnel.stop()
        case .stopTunnelNow:
            tunnel.stopNow(from: quitBegan ?? .now())
        case .audit(let state, let detail):
            guard let doorState else { return }
            doorState.audit([RemoteAccessAuditEntry.tunnel(state, detail: detail, time: doorState.now)])
        case .notify(let notice):
            notify(title: notice.title, body: notice.body)
        }
    }

    // MARK: the token (R30, R44)

    /// Off the main thread, silent or not: a read can wait for a prompt (the interactive one, or a silent one whose
    /// options don't reach a legacy item's prompt, H6), and a launch must never hang on it (R44). An answer that
    /// comes after another start is dropped.
    private func readToken(interactive: Bool) {
        let run = self.run
        let tokens = self.tokens
        DispatchQueue.global(qos: .userInitiated).async {
            let result = tokens.read(interactive: interactive)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.run == run else { return }
                    self.tokenRead(result)
                }
            }
        }
    }

    private func tokenRead(_ result: Result<RemoteAccessTunnelConfig.Token, RemoteAccessTokenFailure>) {
        switch result {
        case .success(let read):
            token = read
            send(.token(.found))
        case .failure(let failure):
            send(.token(failure.read))
        }
    }

    // MARK: the door

    /// A new door state from the grants file and the saved host (none until Confirm Host, so the door answers 421),
    /// and the door bound on `127.0.0.1:<port>` alone. A busy port is reported as such; no other port is tried.
    private func openDoor(_ port: UInt16) {
        let state = RemoteAccessDoorState.forDoor(folder: folder, host: status.host)
        state.onEvents = { [weak self] events in self?.authorityEvents(events) }
        let server = RemoteAccessServer(port: port, state: state)
        server.onFailure = { [weak self, weak server] in
            guard let self, let server, self.door === server else { return }
            self.send(.doorFailed("The door on port \(port) stopped. Turn Remote access on again."))
        }
        do {
            try server.start()
        } catch let error as RemoteAccessServer.StartError {
            if case .portInUse = error { return send(.bindFailed(portInUse: true, reason: error.description)) }
            return send(.bindFailed(portInUse: false, reason: error.description))
        } catch {
            return send(.bindFailed(portInUse: false, reason: "The door could not start: \(error)"))
        }
        doorState = state
        door = server
        send(.bound)
    }

    /// After the door closed: a grant change whose save failed and the last uses are written, since this state
    /// ends here; at quit the audit lines are waited for too. With no door, Revoke All ends the saved grants.
    private func doorClosed(revokeAll: Bool) {
        if let doorState {
            do {
                try doorState.saveOnQuit()
            } catch {
                NSLog("Next Term: Remote access could not save its grants: %@", "\(error)")
            }
            if quitBegan != nil { doorState.flushAudit(within: 0.5) }
        } else if revokeAll {
            revokeSavedGrants()
        }
        doorState = nil
        door = nil
        token = nil
    }

    /// Turn Off and Revoke All with the door closed: every grant the file holds ends, with no host saved too (the
    /// last host's grants would work again if it were typed back in), and the log gets the kill switch's line (R39).
    private func revokeSavedGrants() {
        let state = RemoteAccessDoorState(folder: folder, host: settings.host)
        state.turnOff(revokeAll: true)
        do {
            try state.saveOnQuit()
        } catch {
            NSLog("Next Term: Remote access could not save its grants: %@", "\(error)")
        }
        state.flushAudit(within: 1)
    }

    /// The authority's events: a reused key cuts its grant and the Mac is told (R16). Pairing never alerts (R14).
    private func authorityEvents(_ events: [RemoteAccessOAuth.Event]) {
        for event in events {
            switch event {
            case .refreshReused(_, let name), .codeReused(_, let name):
                notify(title: "Remote access", body: RemoteAccessOAuth.reuseNotice(grantName: name))
            default:
                break
            }
        }
        changedNotice()
    }

    /// Whether nothing holds `127.0.0.1:<port>`: a socket binds it and closes at once.
    nonisolated static func isFree(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        return bound == 0
    }

    // MARK: the tunnel

    private func connect(_ runner: RemoteAccessTunnelRunner) {
        runner.report = { [weak self] event in self?.send(event) }
    }

    /// A tunnel child a crash left running, its watchdog gone too (R42, AE10): ended only when its pid, start time
    /// and path match the record and the Next Term that started it no longer runs. The record goes once that
    /// process is gone, or at once when it is another process or gone already. At launch, and from the self-test
    /// after it wrote a record of its own (U12).
    func endLeftoverTunnel() {
        guard let record = RemoteAccessPidRecord.read(in: folder) else { return }
        let ownerRunning = RemoteAccessProcesses.start(of: record.owner) == record.ownerStart
        let seen = RemoteAccessProcesses.seen(record.pid)
        switch record.cleanup(seen: seen, ownerRunning: ownerRunning) {
        case .keep:
            return
        case .forget:
            RemoteAccessPidRecord.delete(in: folder)
        case .end:
            // A start meanwhile may have written its own child's record: only this one goes.
            let folder = self.folder
            RemoteAccessProcesses.end(record.pid, start: record.start) { gone in
                guard gone, RemoteAccessPidRecord.read(in: folder) == record else { return }
                RemoteAccessPidRecord.delete(in: folder)
            }
        }
    }

    /// After a wake, the tunnel is checked at once (R41).
    private func woke() {
        guard status.doorOpen else { return }
        tunnel.checkNow()
    }

    // MARK: sleep (R41)

    /// While the door is open: no idle sleep on power, only no App Nap on battery unless Keep Awake on Battery is
    /// on. The display may sleep. Follows the power source as it changes.
    private func keepAwake() {
        var wanted: RemoteAccessAwake?
        if status.doorOpen {
            wanted = RemoteAccessAwake.activity(onPower: Self.onPower(),
                                                keepAwakeOnBattery: settings.keepAwakeOnBattery)
        }
        guard wanted != awake else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        awake = wanted
        guard let wanted else { return watchPower(false) }
        let options: ProcessInfo.ActivityOptions
        switch wanted {
        case .noIdleSleep: options = .userInitiated
        case .noAppNap: options = .userInitiatedAllowingIdleSystemSleep
        }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Remote access is on")
        watchPower(true)
    }

    /// On AC power. A Mac that reports no power source (a desktop) counts as on power.
    private static func onPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private func watchPower(_ on: Bool) {
        if on, powerSource == nil {
            let made = IOPSNotificationCreateRunLoopSource({ _ in
                MainActor.assumeIsolated { RemoteAccess.shared.keepAwake() }
            }, nil)
            guard let source = made?.takeRetainedValue() else { return }
            // Every common mode, so a change during menu tracking or a modal panel is seen at once.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        } else if !on, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
    }

    // MARK: saving and telling

    private func save() {
        guard let defaults else { return }
        settings.save(to: defaults)
    }

    private func changedNotice() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A Mac notification, guarded as `AppDelegate.notificationCenter` is; in the self-test it goes to the list the
    /// self-test reads, never to Notification Center.
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "remote-access"
        let identifier = "remote-access-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        if SelfTest.isRequested {
            AppDelegate.shared?.testNotifications.append(request)
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - the update sheet (R43)

extension RemoteAccess {
    static let updateNoteID = NSUserInterfaceItemIdentifier("remoteAccessUpdateNote")

    /// Plan 003's keep-sessions sheet: its notes hold "Remote access stops until Next Term reopens." while Remote
    /// access is on, and not otherwise. True when the notes changed, so the sheet fits itself again.
    func showUpdateNote(in notes: NSStackView) -> Bool {
        let shown = notes.arrangedSubviews.first { $0.identifier == Self.updateNoteID }
        guard isOn != (shown != nil) else { return false }
        if let shown {
            notes.removeArrangedSubview(shown)
            shown.removeFromSuperview()
        } else {
            let label = NSTextField(labelWithString: RemoteAccessStatus.updateNote)
            label.font = .systemFont(ofSize: 12)
            label.identifier = Self.updateNoteID
            notes.addArrangedSubview(label)
        }
        notes.isHidden = notes.arrangedSubviews.isEmpty
        return true
    }
}

// MARK: - the tunnel's seam (U10)

/// What runs the tunnel for the controller: U10's supervisor (RemoteAccessTunnel.swift). It reports on the main thread
/// through `report`: `.ready(host:)`, `.notReady`, `.tunnelDown`, `.routeChanged(_:)` and `.tunnelFailed(_:)`.
@MainActor
protocol RemoteAccessTunnelRunner: AnyObject {
    var report: ((RemoteAccessStatus.Event) -> Void)? { get set }
    /// Starts the chosen tunnel's child once the door holds `port`, with Cloudflare's token read at this start.
    func start(_ kind: RemoteAccessTunnelConfig.Kind, port: UInt16, host: String?,
               token: RemoteAccessTunnelConfig.Token?)
    /// SIGTERM now, the rest on timers: gone within 3 seconds (R37). Nothing when no child runs.
    func stop()
    /// For quit: ended in place with `RemoteAccessProcesses.endNow`, its signals counted from `began` (when quit
    /// began), so quit waits at most 3 seconds in all; the pid record deleted once it is gone (R42).
    func stopNow(from began: DispatchTime)
    /// A health and routing check at once, after a wake.
    func checkNow()
}

// MARK: - tunnel processes (R42)

/// Tunnel children by pid: what a pid record holds, and ending one. U10's supervisor and its watchdog end children
/// with these, and a launch a leftover one. A signal goes only to the process the record names: its pid, with the same
/// start time.
enum RemoteAccessProcesses {
    typealias Start = RemoteAccessPidRecord.Start

    /// SIGTERM, again after 1 second, SIGKILL after 3 (R37, R42).
    static let secondTerm: TimeInterval = 1
    static let killAfter: TimeInterval = 3
    /// How long the end is waited for after SIGKILL while the app runs.
    static let afterKill: TimeInterval = 0.5
    /// At quit, SIGKILL goes this much before `killAfter`, so its end is seen within quit's 3 seconds (R42).
    static let quitKillWait: TimeInterval = 0.1

    /// When `pid` started (`KERN_PROC_PID`, `p_starttime`), or nil when no process has it or it has exited and
    /// waits to be reaped.
    static func start(of pid: pid_t) -> Start? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Start(seconds: Int64(time.tv_sec), microseconds: Int32(time.tv_usec))
    }

    /// The process that has `pid` now: its start time and the file the kernel ran.
    static func seen(_ pid: pid_t) -> RemoteAccessPidRecord.Seen? {
        guard let start = start(of: pid) else { return nil }
        return RemoteAccessPidRecord.Seen(start: start, path: ProcessInspector.executablePath(of: pid))
    }

    /// The record for a child that just started, owned by this Next Term, for U10 to write.
    static func record(for pid: pid_t) -> RemoteAccessPidRecord? {
        guard let seen = seen(pid), let path = seen.path, let ownerStart = start(of: getpid()) else { return nil }
        return RemoteAccessPidRecord(pid: pid, start: seen.start, path: path, owner: getpid(), ownerStart: ownerStart)
    }

    /// No process has the pid, it exited, or the pid is another process's now.
    static func isGone(_ pid: pid_t, start: Start) -> Bool {
        self.start(of: pid) != start
    }

    /// Sends `signal` while the pid is still that process.
    static func post(_ signal: Int32, to pid: pid_t, start: Start) {
        guard !isGone(pid, start: start) else { return }
        kill(pid, signal)
    }

    /// Ends it in place, for quit, counted from `began`, when quit began: SIGTERM now, again 1 second after
    /// `began`, and SIGKILL in time for its end to be seen 3 seconds after it. So quit waits at most 3 seconds in
    /// all, the door's last answers and the audit lines before it included (R42). True once it is gone; otherwise
    /// its record stays for the next launch, which matches it by pid, start time and path.
    @discardableResult
    static func endNow(_ pid: pid_t, start: Start, from began: DispatchTime) -> Bool {
        post(SIGTERM, to: pid, start: start)
        if waitGone(pid, start: start, until: secondTerm, from: began) { return true }
        post(SIGTERM, to: pid, start: start)
        if waitGone(pid, start: start, until: killAfter - quitKillWait, from: began) { return true }
        post(SIGKILL, to: pid, start: start)
        return waitGone(pid, start: start, until: killAfter, from: began)
    }

    /// The same on main-thread timers while the app runs: `done` gets true once it is gone, false if it outlived
    /// SIGKILL's wait.
    @MainActor
    static func end(_ pid: pid_t, start: Start, done: @escaping @MainActor (Bool) -> Void) {
        post(SIGTERM, to: pid, start: start)
        Ending(pid: pid, start: start, done: done).begin()
    }

    private static func waitGone(_ pid: pid_t, start: Start, until seconds: TimeInterval,
                                 from began: DispatchTime) -> Bool {
        while !isGone(pid, start: start) {
            if elapsed(since: began) >= seconds { return false }
            usleep(10_000)
        }
        return true
    }

    static func elapsed(since began: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000_000
    }

    /// One end on timers: checked every 50 milliseconds. It holds itself through its timer until it is done.
    @MainActor
    private final class Ending {
        let pid: pid_t
        let start: Start
        let done: @MainActor (Bool) -> Void
        let began = DispatchTime.now()
        var signalled = 1
        var timer: DispatchSourceTimer?

        init(pid: pid_t, start: Start, done: @escaping @MainActor (Bool) -> Void) {
            self.pid = pid
            self.start = start
            self.done = done
        }

        func begin() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
            timer.setEventHandler { MainActor.assumeIsolated { self.tick() } }
            self.timer = timer
            timer.resume()
        }

        private func tick() {
            let elapsed = RemoteAccessProcesses.elapsed(since: began)
            if RemoteAccessProcesses.isGone(pid, start: start) { return finish(true) }
            if signalled == 1, elapsed >= RemoteAccessProcesses.secondTerm {
                signalled = 2
                RemoteAccessProcesses.post(SIGTERM, to: pid, start: start)
            } else if signalled == 2, elapsed >= RemoteAccessProcesses.killAfter {
                signalled = 3
                RemoteAccessProcesses.post(SIGKILL, to: pid, start: start)
            } else if signalled == 3, elapsed >= RemoteAccessProcesses.killAfter + RemoteAccessProcesses.afterKill {
                finish(false)
            }
        }

        private func finish(_ gone: Bool) {
            timer?.cancel()
            timer?.setEventHandler(handler: nil)
            timer = nil
            done(gone)
        }
    }
}
