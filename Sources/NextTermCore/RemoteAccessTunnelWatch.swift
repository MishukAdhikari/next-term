import Foundation

/// The tunnel's supervision (U10), as a pure watch over one tunnel run: each start and exit of the child, each health
/// and routing check, and each tick of the clock gives what to report to the status reducer (`RemoteAccessStatus`)
/// and when to restart. The app (RemoteAccessTunnel) runs the child, the timers and the checks, and stops the child
/// when the reducer says so.
///
/// Rules it keeps:
/// - Every check reports where the tunnel stands, ready or not, so the reducer can't miss a change (it ignores what
///   doesn't apply where it stands).
/// - A routing stop is reported at the check that sees it, ready or not, and ends the watch: nothing more is
///   reported for this run (R33, AE8).
/// - Cloudflare connected but with no routing after 2 minutes stops: the tunnel is managed from a local config file
///   (2026-10-11). Funnel has no such limit; its CLI waits there for Funnel to be enabled.
/// - An exit restarts after 1 second, doubling to 60, counted from the last time it was ready (R32).
/// - Down for 10 minutes tells the Mac once per outage (R32).
/// - Messages name only the saved hostname and the door, as U6's do; a hostname read from the tunnel is shown only
///   once it passed the public hostname check.
public struct RemoteAccessTunnelWatch: Sendable {
    public typealias Config = RemoteAccessTunnelConfig

    /// The plan's waits. A debug self-test shortens them (U12).
    public struct Limits: Equatable, Sendable {
        /// Connected with no routing for this long stops a Cloudflare tunnel.
        public var routingWait: TimeInterval
        /// Down this long tells the Mac.
        public var notifyAfter: TimeInterval
        /// Each restart wait is multiplied by this.
        public var restartScale: Double

        public init(routingWait: TimeInterval = Config.routingWaitLimit, notifyAfter: TimeInterval = Config.notifyAfter,
                    restartScale: Double = 1) {
            self.routingWait = routingWait
            self.notifyAfter = notifyAfter
            self.restartScale = restartScale
        }

        public static let standard = Limits()
    }

    /// What one check read. Nil where nothing answered.
    public enum Check: Sendable {
        /// `cloudflared`'s metrics: `/ready`'s status and body, and `/config`'s body when it answered 200.
        case cloudflare(ready: (status: Int, body: Data)?, config: Data?)
        /// Tailscale: this Mac's name or why there is none (`tailscale status --json`), and the Funnel share
        /// (`tailscale funnel status --json`).
        case funnel(name: Result<String, Config.TailscaleProblem>?, share: Data?)
    }

    public enum Output: Equatable, Sendable {
        /// Sent to the status reducer.
        case report(RemoteAccessStatus.Event)
        /// Start the child again after this many seconds.
        case restart(after: TimeInterval)
    }

    public let kind: Config.Kind
    /// The saved public hostname: nil before the first run, until the user confirms one or Funnel's is saved.
    public private(set) var host: String?
    public let port: Int
    public let limits: Limits

    /// The child runs.
    public private(set) var running = false
    /// A check stopped this run: nothing more is reported.
    public private(set) var finished = false
    /// Exits since the tunnel was last ready.
    public private(set) var attempt = 0
    /// Not ready since then; nil while ready.
    public private(set) var downSince: Date?
    /// Connected to Cloudflare with no routing yet, since then.
    public private(set) var waitingSince: Date?
    /// The last ready route's warnings, for Settings.
    public private(set) var warnings: [Config.RouteWarning] = []
    /// The Mac was told of this outage.
    private var told = false

    public init(kind: Config.Kind, host: String?, port: Int, limits: Limits = .standard) {
        self.kind = kind
        self.host = host
        self.port = port
        self.limits = limits
    }

    /// The hostname the reducer saved during this run: the one the user confirmed, or Funnel's first. Later checks
    /// and stop messages name it.
    public mutating func use(host saved: String) {
        host = saved
    }

    /// The child started (first, or again after an exit).
    public mutating func started(at now: Date) -> [Output] {
        guard !finished else { return [] }
        running = true
        if downSince == nil { downSince = now }
        return []
    }

    /// The child exited by itself: not ready, and a restart after the next wait.
    public mutating func exited(at now: Date) -> [Output] {
        guard running, !finished else { return [] }
        running = false
        waitingSince = nil
        attempt += 1
        if downSince == nil { downSince = now }
        let wait = Config.restartWait(attempt: attempt) * limits.restartScale
        return [.report(.notReady), .restart(after: wait)] + downNotice(at: now)
    }

    /// Time passed with no check, between restarts: only the 10 minutes down are counted.
    public mutating func tick(at now: Date) -> [Output] {
        guard !finished else { return [] }
        return downNotice(at: now)
    }

    /// A health and routing check of the running child.
    public mutating func checked(_ check: Check, at now: Date) -> [Output] {
        guard running, !finished else { return [] }
        switch check {
        case .cloudflare(let ready, let config):
            let connected = ready.map { Config.isReady(status: $0.status, body: $0.body) } ?? false
            return cloudflare(connected: connected, config: config, at: now)
        case .funnel(let name, let share):
            return funnel(name: name, share: share, at: now)
        }
    }

    // MARK: the checks

    /// Shown in a stop's message when nothing names the hostname yet.
    static let unnamedHost = "the public hostname"

    private mutating func cloudflare(connected: Bool, config: Data?, at now: Date) -> [Output] {
        guard let config else { return notReady(at: now) }
        // The tunnel's own hostname is checked when it has one, so another one than the saved one is reported as
        // ready there, for the reducer to stop and offer it (U10); else the saved one, so its stop names it.
        let named = Config.cloudflareHostname(config)
        let routeHost = named ?? host ?? Self.unnamedHost
        switch Config.cloudflareRoute(config, host: routeHost, port: port) {
        case .stop(let stop):
            return finish(.routeChanged(stop.message(host: host ?? routeHost, port: port)))
        case .waiting:
            guard connected else {
                waitingSince = nil
                return notReady(at: now)
            }
            let since = waitingSince ?? now
            waitingSince = since
            guard now.timeIntervalSince(since) < limits.routingWait else {
                return finish(.tunnelFailed(Config.noRoutes))
            }
            return notReady(at: now)
        case .ok:
            waitingSince = nil
            warnings = []
            return connected ? ready(host: routeHost) : notReady(at: now)
        case .warn(let found):
            waitingSince = nil
            warnings = found
            return connected ? ready(host: routeHost) : notReady(at: now)
        }
    }

    private mutating func funnel(name: Result<String, Config.TailscaleProblem>?, share: Data?,
                                 at now: Date) -> [Output] {
        // Tailscale's own trouble (logged out, turned off) and output that isn't a status are not ready: the share
        // went with it, and the CLI can print a passing error. Only a share it shows is judged.
        guard case .success(let mine)? = name, let share, Self.isObject(share) else { return notReady(at: now) }
        switch Config.funnelRoute(share, host: mine, port: port) {
        case .stop(let stop):
            return finish(.routeChanged(stop.message(host: host ?? mine, port: port)))
        case .waiting:
            return notReady(at: now)
        case .ok:
            warnings = []
            return ready(host: mine)
        case .warn(let found):
            warnings = found
            return ready(host: mine)
        }
    }

    private static func isObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    // MARK: reports

    private mutating func ready(host reported: String) -> [Output] {
        attempt = 0
        downSince = nil
        told = false
        return [.report(.ready(host: reported))]
    }

    private mutating func notReady(at now: Date) -> [Output] {
        if downSince == nil { downSince = now }
        return [.report(.notReady)] + downNotice(at: now)
    }

    private mutating func finish(_ event: RemoteAccessStatus.Event) -> [Output] {
        finished = true
        running = false
        return [.report(event)]
    }

    private mutating func downNotice(at now: Date) -> [Output] {
        guard !told, let since = downSince, now.timeIntervalSince(since) >= limits.notifyAfter else { return [] }
        told = true
        return [.report(.tunnelDown)]
    }
}

// MARK: - the child's output

/// The tunnel child's last 20 lines, kept in memory only, for Settings: each masked for the tunnel token in its four
/// forms and for what `MCPRedaction` finds, and cut to 500 characters. A line shows once it ends; a line that never
/// ends is kept cut once it passes 4 KB, and the rest of it dropped.
public struct RemoteAccessTunnelOutput: Sendable {
    public static let keptLines = 20
    public static let longestLine = 500
    static let longestPart = 4096

    public private(set) var lines: [String] = []
    /// The token's forms, longest first.
    private var forms: [String]
    private var part = Data()
    private var skipping = false

    /// It still holds what the token may be in: its forms, or a line not ended yet, which is not masked.
    public var mayHoldToken: Bool { !forms.isEmpty || !part.isEmpty }

    public init(token: RemoteAccessTunnelConfig.Token? = nil) {
        let forms = token.map(RemoteAccessTunnelConfig.tokenForms) ?? []
        self.forms = forms.sorted { $0.count > $1.count }
    }

    /// Turn Off: the masked lines stay for Settings; the token's forms and a line not ended yet go.
    public mutating func forgetToken() {
        forms = []
        part = Data()
        skipping = false
    }

    public mutating func append(_ data: Data) {
        var rest = data[...]
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            if skipping {
                skipping = false
            } else {
                part.append(rest[rest.startIndex..<newline])
                keep(part)
            }
            part.removeAll()
            rest = rest[rest.index(after: newline)...]
        }
        guard !skipping else { return }
        part.append(rest)
        guard part.count > Self.longestPart else { return }
        keep(part)
        part.removeAll()
        skipping = true
    }

    private mutating func keep(_ bytes: Data) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        for form in forms { line = line.replacingOccurrences(of: form, with: MCPRedaction.mask) }
        line = MCPRedaction.redact(line).text
        if line.count > Self.longestLine { line = String(line.prefix(Self.longestLine)) + "…" }
        lines.append(line)
        if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
    }
}

// MARK: - the watchdog's arguments (KTD12)

/// What `nxtrm tunnel-guard` watches: the Next Term that started a tunnel child, and the child, each by pid and start
/// time. Anything that doesn't read back exactly is not the watchdog, so `nxtrm tunnel-guard` alone still opens a
/// file of that name.
public struct RemoteAccessGuardTargets: Equatable, Sendable {
    public typealias Start = RemoteAccessPidRecord.Start

    public static let mode = "tunnel-guard"

    public var owner: Int32
    public var ownerStart: Start
    public var child: Int32
    public var childStart: Start

    public init(owner: Int32, ownerStart: Start, child: Int32, childStart: Start) {
        self.owner = owner
        self.ownerStart = ownerStart
        self.child = child
        self.childStart = childStart
    }

    /// After `--cli`: the mode, then the owner's pid and start, then the child's.
    public var arguments: [String] {
        let owner = ["\(self.owner)", "\(ownerStart.seconds)", "\(ownerStart.microseconds)"]
        let child = ["\(self.child)", "\(childStart.seconds)", "\(childStart.microseconds)"]
        return [Self.mode] + owner + child
    }

    public static func parse(_ arguments: [String]) -> RemoteAccessGuardTargets? {
        guard arguments.count == 7, arguments[0] == mode else { return nil }
        let fields = arguments.dropFirst().map { Self.number($0) }
        guard let owner = fields[0].flatMap(Int32.init(exactly:)), owner > 0,
              let child = fields[3].flatMap(Int32.init(exactly:)), child > 0,
              let ownerStart = start(fields[1], fields[2]), let childStart = start(fields[4], fields[5]) else {
            return nil
        }
        return RemoteAccessGuardTargets(owner: owner, ownerStart: ownerStart, child: child, childStart: childStart)
    }

    /// Plain digits only: no sign, space or prefix.
    private static func number(_ text: String) -> Int64? {
        guard !text.isEmpty, text.count <= 18, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }

    private static func start(_ seconds: Int64?, _ microseconds: Int64?) -> Start? {
        guard let seconds, let microseconds, microseconds < 1_000_000 else { return nil }
        return Start(seconds: seconds, microseconds: Int32(microseconds))
    }
}

// MARK: - Test Connection (R36)

/// Test Connection, only on a click: the resource metadata fetched through the public URL, and what came back said in
/// a sentence. Nothing the network sent is repeated: a body is read only for its resource.
public enum RemoteAccessConnectionTest {
    public static let timeout: TimeInterval = 15

    public enum Failure: Equatable, Sendable {
        case noSuchHost
        case timedOut
        case cannotConnect
        case certificate
        case other
    }

    public enum Answer: Equatable, Sendable {
        /// The status, the body and the `Server` header.
        case response(status: Int, body: Data, server: String?)
        case failed(Failure)
    }

    /// `https://<host>/.well-known/oauth-protected-resource`.
    public static func url(host: String) -> URL? {
        URL(string: "https://\(host)/.well-known/oauth-protected-resource")
    }

    public static func failure(_ code: URLError.Code) -> Failure {
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return .noSuchHost
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return .cannotConnect
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
            return .certificate
        default:
            return .other
        }
    }

    public static func message(_ answer: Answer, kind: RemoteAccessTunnelConfig.Kind, host: String) -> String {
        switch answer {
        case .failed(let failure):
            return message(failure, host: host)
        case .response(let status, let body, let server):
            let cloudflare = kind == .cloudflare || server?.lowercased() == "cloudflare"
            return message(status: status, reached: isNextTerm(body, host: host), cloudflare: cloudflare,
                           kind: kind, host: host)
        }
    }

    private static func message(_ failure: Failure, host: String) -> String {
        switch failure {
        case .noSuchHost:
            return "\(host) can't be found yet. A new hostname can take a few minutes to reach DNS."
        case .timedOut:
            return "\(host) didn't answer within \(Int(timeout)) seconds."
        case .cannotConnect:
            return "Couldn't connect to \(host)."
        case .certificate:
            return "\(host)'s certificate isn't valid for it yet."
        case .other:
            return "Couldn't reach \(host)."
        }
    }

    private static func message(status: Int, reached: Bool, cloudflare: Bool, kind: RemoteAccessTunnelConfig.Kind,
                                host: String) -> String {
        switch status {
        case 200 where reached:
            // With Funnel, the Mac may reach its own ts.net name through the tailnet, not the public relay.
            guard kind != .funnel else {
                return "Reached Next Term from this Mac. Check from a phone off Wi-Fi to test the public path."
            }
            return "Reached Next Term through \(host)."
        case 200:
            return "\(host) answered, but not as Next Term. Check that the tunnel points at Next Term's door."
        case 421:
            return "Next Term refused the Host header (421). The tunnel must pass \(host) as the Host unchanged."
        case 403 where cloudflare:
            return "Cloudflare answered 403: check Bot Fight Mode."
        case 404:
            return "\(host) answered 404: the request didn't reach Next Term."
        case 502...504 where cloudflare, 520...530 where cloudflare:
            return "Cloudflare answered \(status): it can't reach Next Term through the tunnel."
        default:
            return "\(host) answered \(status)."
        }
    }

    /// Next Term's protected resource metadata for this host.
    private static func isNextTerm(_ body: Data, host: String) -> Bool {
        guard let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return (fields["resource"] as? String)?.lowercased() == "https://\(host.lowercased())/mcp"
    }
}
