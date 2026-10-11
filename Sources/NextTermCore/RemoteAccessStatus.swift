import Foundation

/// Where Remote access stands (U9), as one pure reducer: each event (the switch, the Keychain's answer, the door's
/// bind, the tunnel's reports, Confirm Host, quit) gives the next phase and the effects the app runs, in order. The
/// app (`RemoteAccess`) runs them and sends what they report back as events.
///
/// ```
/// Off → Starting (switch on) → [WaitingForKeychain →] Starting → Connecting (door bound, tunnel started)
///     → [ConfirmHost (Cloudflare, no saved host) →] On ⇄ Reconnecting
/// Starting → PortBusy (bind failed); On, Reconnecting → Stopped (route changed); each dismissed to Off
/// ```
///
/// Rules it keeps:
/// - The tunnel never starts before the door holds its port (R31). A busy port starts no tunnel (AE9).
/// - Every way to Off saves it off, so the switch and the saved setting agree and Remote access never comes back
///   by itself on the next launch. Quit is the one exception: a relaunch starts it again (R43).
/// - Off from an open door closes the door, drops the access tokens and stops the tunnel, in that order (R37).
/// - Quit waits for the tunnel in place, since timers never fire after it (R42); it does so even while off, in case
///   a stop on timers is still under way.
public struct RemoteAccessStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        /// Checks passed; the token is being read, or the door is binding.
        case starting
        /// The silent Keychain read would have asked (R44). "Allow Keychain access" reads again with the prompt.
        case waitingForKeychain
        /// The saved port is taken (R2). Nothing started; dismissed to Off.
        case portBusy(UInt16)
        /// The door is bound and the tunnel started, not ready yet.
        case connecting
        /// Cloudflare's first ready: the hostname from `/config` waits for the user. The door answers 421 until then.
        case confirmHost(String)
        case on
        /// Was on; the tunnel is not ready or exited, and restarts (U10).
        case reconnecting
        /// The route changed or the door failed (R33). Everything is stopped; dismissed to Off.
        case stopped(String)
    }

    /// What the Keychain gave for the tunnel token. The token itself never comes through here.
    public enum TokenRead: Equatable, Sendable {
        case found
        /// No token is saved.
        case missing
        /// The read would have shown a prompt, and the UI was suppressed (`errSecInteractionNotAllowed`).
        case needsPermission
        /// The user canceled the prompt the interactive read showed.
        case canceled
        case failed(String)
    }

    /// The facts a start is decided on, gathered by the app when the switch turns on or a launch finds it saved on.
    public struct Start: Equatable, Sendable {
        public var tunnel: RemoteAccessTunnelConfig.Kind?
        /// The saved public hostname, if any.
        public var host: String?
        /// The saved port, or one just picked; nil when none is free.
        public var port: RemoteAccessPort.Choice?
        /// "Let agents control Next Term" (R1).
        public var agentControl: Bool
        /// Why U1's scope tag check refuses the start, or nil when it passes.
        public var scopeCheck: String?
        /// A launch with Remote access saved on: the Mac is told once it is on, or that it didn't start (R43).
        public var launch: Bool

        public init(tunnel: RemoteAccessTunnelConfig.Kind?, host: String?, port: RemoteAccessPort.Choice?,
                    agentControl: Bool, scopeCheck: String?, launch: Bool) {
            self.tunnel = tunnel
            self.host = host
            self.port = port
            self.agentControl = agentControl
            self.scopeCheck = scopeCheck
            self.launch = launch
        }
    }

    public enum Event: Equatable, Sendable {
        /// The switch, or a launch with Remote access saved on.
        case turnOn(Start)
        case token(TokenRead)
        /// "Allow Keychain access" (U11).
        case allowKeychainAccess
        /// The door holds `127.0.0.1:<port>`.
        case bound
        case bindFailed(portInUse: Bool, reason: String)
        /// The tunnel can't run: a missing or old tool, Funnel off for the tailnet, no routes after 2 minutes (U10).
        case tunnelFailed(String)
        /// The tunnel is ready, with the hostname it serves when it can tell (`/config`, Funnel's status).
        case ready(host: String?)
        /// Not ready at a check, or the child exited (U10 restarts it).
        case notReady
        /// The tunnel's routing no longer sends the saved host to the door alone (R33).
        case routeChanged(String)
        /// The door's listener failed after it started.
        case doorFailed(String)
        case confirmHost
        case declineHost
        /// Turn Off, or Turn Off and Revoke All (R37).
        case turnOff(revokeAll: Bool)
        /// "Let agents control Next Term" turned off (R1).
        case agentControlOff
        case quit
        /// The user read PortBusy's or Stopped's message.
        case dismiss
    }

    public enum Effect: Equatable, Sendable {
        /// The port just picked, saved with the setting (R2).
        case savePort(UInt16)
        case saveOn
        case saveOff
        case saveHost(String)
        /// The tunnel token, once per start (R44): silently, or with the system's prompt allowed.
        case readToken(interactive: Bool)
        case bindDoor(UInt16)
        case startTunnel
        /// No new connection; every open call answered.
        case closeDoor
        /// Access tokens dropped; every grant ended too with `revokeAll`.
        case dropTokens(revokeAll: Bool)
        /// SIGTERM now, the rest on timers: gone within 3 seconds (R37).
        case stopTunnel
        /// For quit: SIGTERM, again after 1 second, SIGKILL after 3, waited for in place (R42).
        case stopTunnelNow
        /// A tunnel line in the audit log (R39).
        case audit(tunnel: String, detail: String?)
        case notify(Notice)
    }

    /// What the Mac is told in a notification.
    public enum Notice: Equatable, Sendable {
        /// After a launch with Remote access saved on (R43).
        case on(host: String?)
        /// It stopped by itself (R33).
        case stopped(String)
        /// A launch with it saved on could not start it.
        case didNotStart(String)

        public var title: String {
            switch self {
            case .on: return "Remote access is on"
            case .stopped: return "Remote access stopped"
            case .didNotStart: return "Remote access didn't start"
            }
        }

        public var body: String {
            switch self {
            case .on(let host):
                let place = host.map { " through \($0)" } ?? ""
                return "Connections you allowed can reach Next Term\(place). Turn it off in Settings › Remote Access."
            case .stopped(let reason), .didNotStart(let reason):
                return reason
            }
        }
    }

    // MARK: texts

    /// R44's waiting text.
    public static let keychainNeeded = "Allow Keychain access to turn Remote access on"
    /// The line plan 003's keep-sessions sheet shows while Remote access is on (R43).
    public static let updateNote = "Remote access stops until Next Term reopens."
    public static let agentControlNeeded = "Turn on “Let agents control Next Term” first."
    public static let tunnelNeeded = "Choose a tunnel in Settings › Remote Access first."
    public static let hostNeeded = "Type your tunnel's public hostname in Settings › Remote Access first."
    public static let tokenNeeded = "Paste your Cloudflare tunnel token in Settings › Remote Access first."
    public static let noFreePort = "No port from 40000 to 48999 is free."

    // MARK: state

    public private(set) var phase: Phase = .off
    /// Why it is off when that was not the user's doing: shown in Settings. Cleared by the next start.
    public private(set) var problem: String?
    public private(set) var tunnel: RemoteAccessTunnelConfig.Kind?
    public private(set) var host: String?
    public private(set) var port: UInt16?
    /// This run began at launch, and the Mac has not been told how it went yet.
    private var launch = false

    public init() {}

    /// The switch is on: from the start until it is off, PortBusy or Stopped.
    public var isOn: Bool {
        switch phase {
        case .off, .portBusy, .stopped: return false
        default: return true
        }
    }

    /// The door holds its port (and the tunnel may run).
    public var doorOpen: Bool {
        switch phase {
        case .connecting, .confirmHost, .on, .reconnecting: return true
        default: return false
        }
    }

    /// The status line.
    public var text: String {
        switch phase {
        case .off: return problem ?? "Off"
        case .starting: return "Starting…"
        case .waitingForKeychain: return Self.keychainNeeded
        case .portBusy(let port): return "Port \(port) is in use"
        case .connecting: return "Connecting…"
        case .confirmHost(let host): return "Confirm \(host) as the public hostname."
        case .on: return onText
        case .reconnecting: return "Reconnecting…"
        case .stopped(let reason): return reason
        }
    }

    private var onText: String {
        if tunnel == .advanced, let port { return RemoteAccessTunnelConfig.advancedStatus(port: Int(port)) }
        return host.map { "On at \($0)" } ?? "On"
    }

    // MARK: the reducer

    /// Moves to the phase `event` leads to and returns the effects to run, in order. An event that doesn't apply
    /// where it stands changes nothing and returns none.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .turnOn(let start): return turnOn(start)
        case .token(let read): return token(read)
        case .allowKeychainAccess:
            return phase == .waitingForKeychain ? [.readToken(interactive: true)] : []
        case .bound: return bound()
        case .bindFailed(let portInUse, let reason): return bindFailed(portInUse: portInUse, reason: reason)
        case .tunnelFailed(let reason): return tunnelFailed(reason)
        case .ready(let host): return ready(host)
        case .notReady:
            guard phase == .on else { return [] }
            phase = .reconnecting
            return [.audit(tunnel: "reconnecting", detail: nil)]
        case .routeChanged(let reason), .doorFailed(let reason): return stop(reason)
        case .confirmHost: return confirmHost()
        case .declineHost:
            guard case .confirmHost = phase else { return [] }
            return off(revokeAll: false)
        case .turnOff(let revokeAll):
            guard phase != .off else { return revokeAll ? [.dropTokens(revokeAll: true)] : [] }
            return off(revokeAll: revokeAll)
        case .agentControlOff:
            return phase == .off ? [.saveOff] : off(revokeAll: false)
        case .quit: return quit()
        case .dismiss:
            switch phase {
            case .portBusy, .stopped: return off(revokeAll: false)
            default: return []
            }
        }
    }

    private mutating func turnOn(_ start: Start) -> [Effect] {
        guard !isOn else { return [] }
        problem = nil
        launch = start.launch
        if let refusal = Self.refusal(start) { return refuse(refusal) }
        guard let tunnel = start.tunnel, let choice = start.port else { return refuse(Self.tunnelNeeded) }
        self.tunnel = tunnel
        host = start.host
        port = choice.port
        phase = .starting
        var effects: [Effect] = []
        if case .picked(let picked) = choice { effects.append(.savePort(picked)) }
        effects.append(.saveOn)
        effects.append(tunnel == .cloudflare ? .readToken(interactive: false) : .bindDoor(choice.port))
        return effects
    }

    /// Why a start can't go ahead, in the start order: agent control, the scope tag check, the settings.
    private static func refusal(_ start: Start) -> String? {
        guard start.agentControl else { return agentControlNeeded }
        if let reason = start.scopeCheck { return reason }
        guard let tunnel = start.tunnel else { return tunnelNeeded }
        if start.host == nil, tunnel == .advanced || tunnel == .ownServer { return hostNeeded }
        guard start.port != nil else { return noFreePort }
        return nil
    }

    private mutating func token(_ read: TokenRead) -> [Effect] {
        guard phase == .starting || phase == .waitingForKeychain, let port else { return [] }
        switch read {
        case .found:
            phase = .starting
            return [.bindDoor(port)]
        case .needsPermission, .canceled:
            phase = .waitingForKeychain
            return []
        case .missing:
            return refuse(Self.tokenNeeded)
        case .failed(let reason):
            return refuse(reason)
        }
    }

    private mutating func bound() -> [Effect] {
        guard phase == .starting, let tunnel else { return [] }
        guard tunnel.runsTunnel else {
            // Advanced: the user's own tunnel, so the door alone is on.
            phase = .on
            return [.audit(tunnel: "ready", detail: "not managed by Next Term")] + told()
        }
        phase = .connecting
        return [.audit(tunnel: "started", detail: nil), .startTunnel]
    }

    private mutating func bindFailed(portInUse: Bool, reason: String) -> [Effect] {
        guard phase == .starting, let port else { return [] }
        guard portInUse else { return refuse(reason) }
        phase = .portBusy(port)
        return didNotStart("Port \(port) is in use")
    }

    private mutating func tunnelFailed(_ reason: String) -> [Effect] {
        if phase == .starting || phase == .waitingForKeychain { return refuse(reason) }
        guard doorOpen else { return [] }
        let telling = launch
        var effects: [Effect] = [.audit(tunnel: "stopped", detail: reason)] + off(revokeAll: false)
        problem = reason
        if telling { effects.append(.notify(.didNotStart(reason))) }
        return effects
    }

    private mutating func ready(_ reported: String?) -> [Effect] {
        switch phase {
        case .connecting:
            var effects: [Effect] = []
            if host == nil {
                // Nothing to serve until there is a host: the door answers 421 meanwhile.
                guard let reported else { return [] }
                if tunnel == .cloudflare {
                    phase = .confirmHost(reported)
                    return []
                }
                host = reported
                effects.append(.saveHost(reported))
            }
            phase = .on
            return effects + [.audit(tunnel: "ready", detail: nil)] + told()
        case .reconnecting:
            phase = .on
            return [.audit(tunnel: "ready", detail: nil)]
        default:
            return []
        }
    }

    private mutating func confirmHost() -> [Effect] {
        guard case .confirmHost(let confirmed) = phase else { return [] }
        host = confirmed
        phase = .on
        return [.saveHost(confirmed), .audit(tunnel: "ready", detail: nil)] + told()
    }

    /// Route changed, or the door failed: all stopped and saved off, and the Mac told (R33).
    private mutating func stop(_ reason: String) -> [Effect] {
        guard doorOpen else { return [] }
        var effects: [Effect] = [.audit(tunnel: "stopped", detail: reason)] + off(revokeAll: false)
        phase = .stopped(reason)
        effects.append(.notify(.stopped(reason)))
        return effects
    }

    private mutating func quit() -> [Effect] {
        let open = doorOpen
        phase = .off
        launch = false
        guard open else { return [.stopTunnelNow] }
        return [.closeDoor, .dropTokens(revokeAll: false), .stopTunnelNow]
    }

    /// To Off, saved off, closing what is open.
    private mutating func off(revokeAll: Bool) -> [Effect] {
        let open = doorOpen
        phase = .off
        problem = nil
        launch = false
        if open { return [.closeDoor, .dropTokens(revokeAll: revokeAll), .stopTunnel, .saveOff] }
        return revokeAll ? [.saveOff, .dropTokens(revokeAll: true)] : [.saveOff]
    }

    /// A start that can't go on: Off with the reason, saved off, and the Mac told when it was a launch's.
    private mutating func refuse(_ reason: String) -> [Effect] {
        let telling = launch
        var effects = off(revokeAll: false)
        problem = reason
        if telling { effects.append(.notify(.didNotStart(reason))) }
        return effects
    }

    /// The launch's notice that it is on, once.
    private mutating func told() -> [Effect] {
        guard launch else { return [] }
        launch = false
        return [.notify(.on(host: host))]
    }

    /// The launch's notice that it didn't start, once.
    private mutating func didNotStart(_ reason: String) -> [Effect] {
        guard launch else { return [] }
        launch = false
        return [.notify(.didNotStart(reason))]
    }
}

// MARK: - the port (R2)

/// The door's port: the saved one, or at first turn-on a free one from 40000 to 48999.
public enum RemoteAccessPort {
    public static let range: ClosedRange<UInt16> = 40000...48999

    public enum Choice: Equatable, Sendable {
        /// The saved port, used busy or not: it never changes by itself.
        case saved(UInt16)
        /// Picked now, to be saved with the setting.
        case picked(UInt16)

        public var port: UInt16 {
            switch self {
            case .saved(let port), .picked(let port): return port
            }
        }
    }

    /// The saved port when there is one, without asking whether it is free. Otherwise the first free port from a
    /// random place in the range, going round it once; nil when none is free. `random(n)` gives a number from 0
    /// to n - 1 (others are wrapped into that).
    public static func choose(saved: UInt16?, isFree: (UInt16) -> Bool,
                              random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Choice? {
        if let saved, saved > 0 { return .saved(saved) }
        let count = Int(range.upperBound - range.lowerBound) + 1
        let first = ((random(count) % count) + count) % count
        for step in 0..<count {
            let port = range.lowerBound + UInt16((first + step) % count)
            if isFree(port) { return .picked(port) }
        }
        return nil
    }
}

// MARK: - the tunnel's pid record (R42)

/// What the next launch knows of a tunnel child, in case the watchdog was killed with Next Term: its pid, start
/// time and executable, and the Next Term that started it. U10 writes it `0600` in the Remote access folder when
/// the child starts and deletes it once the child is gone. At launch the record's process is ended only when all
/// three still match and that Next Term no longer runs; a pid now used by another process is left alone.
public struct RemoteAccessPidRecord: Codable, Equatable, Sendable {
    public static let fileName = "tunnel-pid.json"

    /// A process's start time as the kernel keeps it (`p_starttime`), compared exactly.
    public struct Start: Codable, Equatable, Sendable {
        public var seconds: Int64
        public var microseconds: Int32

        public init(seconds: Int64, microseconds: Int32) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    /// The process that has the record's pid now.
    public struct Seen: Equatable, Sendable {
        public var start: Start
        /// The file the kernel ran (`proc_pidpath`), or nil when it can't be read.
        public var path: String?

        public init(start: Start, path: String?) {
            self.start = start
            self.path = path
        }
    }

    public enum Cleanup: Equatable, Sendable {
        /// Signal it, and delete the record once it is gone.
        case end
        /// Another Next Term that still runs owns it: leave the process and the record.
        case keep
        /// It is gone, or the pid is another process now: delete the record only.
        case forget
    }

    public var pid: Int32
    public var start: Start
    /// The file the kernel ran for the child (`proc_pidpath`, read after it started), so a symlink matches.
    public var path: String
    /// The Next Term that started it.
    public var owner: Int32
    public var ownerStart: Start

    public init(pid: Int32, start: Start, path: String, owner: Int32, ownerStart: Start) {
        self.pid = pid
        self.start = start
        self.path = path
        self.owner = owner
        self.ownerStart = ownerStart
    }

    /// What to do with the record at launch, given the process that has its pid now and whether its Next Term
    /// still runs.
    public func cleanup(seen: Seen?, ownerRunning: Bool) -> Cleanup {
        guard let seen, seen.start == start, seen.path == path else { return .forget }
        return ownerRunning ? .keep : .end
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// The record in `folder`, or nil when there is none or it can't be read.
    public static func read(in folder: URL) -> RemoteAccessPidRecord? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? JSONDecoder().decode(RemoteAccessPidRecord.self, from: data)
    }

    /// Writes the record `0600` in `folder` (made `0700`), replacing any other.
    public func write(in folder: URL) throws {
        try RemoteAccessStore.prepare(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try RemoteAccessStore.replace(Self.url(in: folder), with: try encoder.encode(self))
    }

    public static func delete(in folder: URL) {
        unlink(url(in: folder).path)
    }
}

// MARK: - sleep (R41)

/// What Next Term asks of macOS while Remote access is on.
public enum RemoteAccessAwake: Equatable, Sendable {
    /// No idle sleep for the Mac and no App Nap for Next Term; the display may still sleep.
    case noIdleSleep
    /// No App Nap only.
    case noAppNap

    /// On power, the Mac stays awake. On battery, only App Nap is avoided, unless "Keep awake on battery" is on.
    public static func activity(onPower: Bool, keepAwakeOnBattery: Bool) -> RemoteAccessAwake {
        onPower || keepAwakeOnBattery ? .noIdleSleep : .noAppNap
    }
}
