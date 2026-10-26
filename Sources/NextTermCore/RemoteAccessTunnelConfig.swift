import Foundation

/// The tunnel checks for Remote access, all pure: the four tunnel choices, the public hostname a user types, where
/// `cloudflared` and `tailscale` are and how old they are, the Cloudflare tunnel token, the arguments and the
/// environment each child runs with, what `cloudflared`'s `/ready` and `/config` say, what Tailscale's status and
/// Funnel share say, your own server's ssh forward, server port and Caddy setup (U15), and the waits between
/// restarts. The app (RemoteAccessTunnel) runs the processes and the timers.
///
/// Rules this file keeps:
/// - Arguments are arrays, never shell text (as in Remote.swift).
/// - The tunnel token never goes in an argument, the environment, a description or an error. It reaches
///   `cloudflared` only through a pipe on its standard input, which it reads once with its token-file flag set to
///   `/dev/stdin` (R30, decided 2026-10-11).
/// - A routing check answers ok, warn, stop or waiting, and its messages name only the saved hostname and the
///   door's port: never a value read from the tunnel, which whoever holds the tunnel's account can set.
public enum RemoteAccessTunnelConfig {
    // MARK: the four choices (R28)

    /// The tunnel the user picks. Saved by its raw value.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case funnel
        case cloudflare
        case ownServer
        case advanced

        public var label: String {
            switch self {
            case .funnel: return "Tailscale Funnel"
            case .cloudflare: return "Cloudflare Tunnel"
            case .ownServer: return "Your own server (over ssh)"
            case .advanced: return "Advanced: I expose the port myself"
            }
        }

        /// Who can read the traffic, shown with the choice (R28).
        public var traffic: String {
            switch self {
            case .funnel:
                return "Tailscale relays the traffic still encrypted. TLS ends on this Mac, so only this Mac reads it."
            case .cloudflare:
                return "TLS ends at Cloudflare, so Cloudflare can read the traffic. Whoever holds the Cloudflare "
                    + "account can also re-route it."
            case .ownServer:
                return "TLS ends on your server, so your server can read the traffic, and so can the chat app's vendor, "
                    + "which sends every call. It reaches this Mac over ssh."
            case .advanced:
                return "Whoever ends TLS for your tunnel can read the traffic."
            }
        }

        /// Whether Next Term runs the tunnel as its own child. With Advanced, the user runs it (R35).
        public var runsTunnel: Bool { self != .advanced }
    }

    // MARK: the door's address

    /// Where every tunnel points: the door on IPv4 loopback. Never `localhost`, which can resolve to `::1`.
    public static func doorAddress(port: Int) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// Advanced's status line (R35, U10).
    public static func advancedStatus(port: Int) -> String {
        "Door open on 127.0.0.1:\(port). Your tunnel is not managed by Next Term."
    }

    /// Advanced's warning (R35).
    public static let advancedWarning = "Next Term doesn't stop your tunnel. It keeps forwarding to the door's port "
        + "while Remote access is off, when another program could listen there."

    // MARK: the public hostname a user types (own server, Advanced)

    public enum HostnameError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case notHTTPS
        case port
        case path
        case ipAddress
        case localName
        case invalid

        public var message: String {
            switch self {
            case .empty:
                return "Type the public hostname, such as mcp.example.com."
            case .notHTTPS:
                return "The public address must use https. Type only the hostname, such as mcp.example.com."
            case .port:
                return "The public address must be on port 443, the https port. Type only the hostname."
            case .path:
                return "Type only the hostname, such as mcp.example.com, without a path."
            case .ipAddress:
                return "Use a hostname, not an IP address. claude.ai and chatgpt.com need a name with a certificate."
            case .localName:
                return "That name works only on your own network. claude.ai and chatgpt.com need a public hostname."
            case .invalid:
                return "That is not a hostname. Use letters, digits, dashes and dots, such as mcp.example.com."
            }
        }

        public var description: String { message }
    }

    /// Top-level names that resolve only on a local network or never.
    static let localSuffixes = ["localhost", "local", "internal", "lan", "test", "invalid", "home.arpa"]

    /// The hostname a user typed or pasted, as the door saves it: lowercased, without a final dot, an `https://`,
    /// `:443` or a `/mcp` path. A pasted connector URL gives its hostname.
    public static func publicHostname(_ typed: String) -> Result<String, HostnameError> {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.unicodeScalars.allSatisfy(\.isASCII) else { return .failure(.invalid) }
        let refused: Set<Character> = ["?", "#", "@", " ", "\t", "\\"]
        guard !trimmed.contains(where: { refused.contains($0) }) else { return .failure(.invalid) }
        var rest = Substring(trimmed.lowercased())
        if let scheme = rest.range(of: "://") {
            guard rest[..<scheme.lowerBound] == "https" else { return .failure(.notHTTPS) }
            rest = rest[scheme.upperBound...]
        }
        if let slash = rest.firstIndex(of: "/") {
            let path = rest[slash...]
            guard ["/", "/mcp", "/mcp/"].contains(path) else { return .failure(.path) }
            rest = rest[..<slash]
        }
        guard !rest.hasPrefix("[") else { return .failure(.ipAddress) }
        let colons = rest.filter { $0 == ":" }.count
        guard colons <= 1 else { return .failure(.ipAddress) }
        if let colon = rest.firstIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else { return .failure(.invalid) }
            guard port == "443" else { return .failure(.port) }
            rest = rest[..<colon]
        }
        if rest.hasSuffix(".") { rest = rest.dropLast() }
        return checkedName(String(rest))
    }

    private static func checkedName(_ name: String) -> Result<String, HostnameError> {
        guard !name.isEmpty, name.utf8.count <= 253 else { return .failure(.invalid) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return .failure(.invalid) }
        guard !labels.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) else { return .failure(.ipAddress) }
        let local = localSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
        guard !local else { return .failure(.localName) }
        guard labels.count >= 2 else { return .failure(.invalid) }
        guard labels.allSatisfy(isLabel) else { return .failure(.invalid) }
        guard let last = labels.last, !last.allSatisfy(\.isASCIIDigit) else { return .failure(.invalid) }
        return .success(name)
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCIIDigit || ("a"..."z").contains($0) || $0 == "-" }
    }

    // MARK: where the tools are (R29, R34)

    public enum Tool: String, Sendable, CaseIterable {
        case cloudflared
        case tailscale

        /// Shown when the tool is missing. Next Term runs nothing to install it (R29).
        public var installHint: String {
            switch self {
            case .cloudflared: return "brew install cloudflared"
            case .tailscale: return "Install Tailscale from tailscale.com/download or the Mac App Store."
            }
        }

        /// Why a start that needs the tool can't go on, with how to get it.
        public var missing: String {
            switch self {
            case .cloudflared: return "cloudflared is not installed. Install it in Terminal with \(installHint)."
            case .tailscale: return "Tailscale is not installed. \(installHint)"
            }
        }
    }

    /// Where a tool may be, in order: the login PATH's folders (absolute ones only, since a relative folder would
    /// follow the working directory), then Homebrew's folders, then, for Tailscale, the app's own CLI.
    public static func candidates(_ tool: Tool, loginPath: [String], home: String) -> [String] {
        var folders: [String] = []
        let usual = ["/opt/homebrew/bin", "/usr/local/bin"]
        for folder in loginPath + usual where folder.hasPrefix("/") {
            let trimmed = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            if !folders.contains(trimmed) { folders.append(trimmed) }
        }
        var paths = folders.map { "\($0)/\(tool.rawValue)" }
        if tool == .tailscale {
            let bundled = "Tailscale.app/Contents/MacOS/Tailscale"
            paths.append("/Applications/\(bundled)")
            paths.append("\(home)/Applications/\(bundled)")
        }
        return paths
    }

    /// The first candidate that is an executable file, or nil.
    public static func locate(_ tool: Tool, loginPath: [String], home: String,
                              isExecutable: (String) -> Bool) -> String? {
        candidates(tool, loginPath: loginPath, home: home).first(where: isExecutable)
    }

    /// Where `cloudflared service install` puts its service, with sudo and without (R34).
    public static func cloudflaredServices(home: String) -> [String] {
        let name = "com.cloudflare.cloudflared.plist"
        return ["/Library/LaunchDaemons/\(name)", "\(home)/Library/LaunchAgents/\(name)"]
    }

    public static let cloudflaredServiceWarning = "A cloudflared system service is installed. It keeps a tunnel up "
        + "while Remote access is off, and after Next Term quits."

    public static let funnelShareWarning = "A Funnel share already exists on this Mac. It stays public while Remote "
        + "access is off. See it with tailscale funnel status."

    // MARK: versions (R29)

    /// A `cloudflared` release: Cloudflare numbers them by year and month.
    public struct CloudflaredVersion: Equatable, Comparable, Sendable {
        public var year: Int
        public var month: Int
        public var patch: Int

        public init(year: Int, month: Int, patch: Int) {
            self.year = year
            self.month = month
            self.patch = patch
        }

        public var text: String { "\(year).\(month).\(patch)" }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.year, lhs.month, lhs.patch) < (rhs.year, rhs.month, rhs.patch)
        }

        /// Whether it reads the token from a file, here its standard input (R30): 2025.4.0 and later.
        public var readsTokenFile: Bool { self >= RemoteAccessTunnelConfig.tokenFileVersion }

        /// More than 12 months older than today's month, when Cloudflare no longer supports it.
        public func isOutdated(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
            let today = calendar.dateComponents([.year, .month], from: now)
            guard let year = today.year, let month = today.month else { return false }
            let age = (year * 12 + month) - (self.year * 12 + self.month)
            return age > 12
        }
    }

    /// From `cloudflared version`: "cloudflared version 2026.10.0 (built ...)". Nil for a dev build or other text.
    public static func cloudflaredVersion(_ output: String) -> CloudflaredVersion? {
        let prefix = "cloudflared version "
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let word = trimmed.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCIIDigit) })
        else { return nil }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        guard (2000...9999).contains(year), (1...12).contains(month) else { return nil }
        return CloudflaredVersion(year: year, month: month, patch: patch)
    }

    /// The first `cloudflared` with its token-file flag.
    public static let tokenFileVersion = CloudflaredVersion(year: 2025, month: 4, patch: 0)

    public static let updateCloudflared = "Update cloudflared to 2025.4.0 or later."

    /// Settings' warning for a `cloudflared` more than 12 months old (R29).
    public static func outdatedWarning(_ version: CloudflaredVersion) -> String {
        "cloudflared \(version.text) is more than a year old. Update it with brew upgrade cloudflared."
    }

    /// Why `cloudflared` can't start, from what its version flag printed (nil when it didn't answer): one older
    /// than 2025.4.0, or whose version can't be read, would not take the token from its standard input.
    public static func cloudflaredStartProblem(versionOutput: String?) -> String? {
        guard let output = versionOutput, let version = cloudflaredVersion(output), version.readsTokenFile else {
            return updateCloudflared
        }
        return nil
    }

    /// From `tailscale version`: its first line, such as "1.104.1", for display only.
    public static func tailscaleVersion(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isASCIIDigit, trimmed.count <= 40 else { return nil }
        let allowed = trimmed.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || ".-+".contains($0) }
        return allowed ? trimmed : nil
    }

    // MARK: the Cloudflare tunnel token (R30)

    /// A pasted tunnel token, checked for shape. `value` is what `cloudflared` reads: standard base64 with padding,
    /// whatever form was pasted. Descriptions and mirrors show only the tunnel id.
    public struct Token: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        public let value: String
        /// The tunnel's UUID, lowercased: all the Mac ever shows of the token.
        public let tunnelID: String

        public var description: String { "Cloudflare tunnel \(tunnelID)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["tunnelID": tunnelID]) }
    }

    /// No case carries text, so no error can hold the token or a piece of it.
    public enum TokenError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        case empty
        case tooLong
        case notBase64
        case notToken

        public var message: String {
            switch self {
            case .empty:
                return "Paste the tunnel token from the Cloudflare dashboard."
            case .tooLong:
                return "That is too long for a tunnel token. Paste only the token from the Cloudflare dashboard."
            case .notBase64, .notToken:
                return "That is not a Cloudflare tunnel token. Copy it from the tunnel's install command in the "
                    + "Cloudflare dashboard."
            }
        }

        public var description: String { message }
        public var errorDescription: String? { message }
    }

    /// Longer than any real token (about 200 characters).
    public static let maximumTokenLength = 4096

    /// Checks a pasted token: base64, standard or URL-safe, padding optional, of JSON with a string `a`, a UUID
    /// `t`, a base64 string `s`, and an optional string `e`. A pasted install command gives its last word, and one
    /// pair of quotes around it is dropped.
    public static func token(_ pasted: String) -> Result<Token, TokenError> {
        let words = pasted.split(whereSeparator: { $0.isWhitespace })
        guard var candidate = words.last.map(String.init) else { return .failure(.empty) }
        for quote in ["'", "\""] where candidate.count >= 2 && candidate.hasPrefix(quote) && candidate.hasSuffix(quote) {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard !candidate.isEmpty else { return .failure(.empty) }
        guard candidate.count <= maximumTokenLength else { return .failure(.tooLong) }
        guard let data = base64Data(candidate) else { return .failure(.notBase64) }
        guard let tunnelID = tunnelID(in: data) else { return .failure(.notToken) }
        return .success(Token(value: data.base64EncodedString(), tunnelID: tunnelID))
    }

    /// Standard or URL-safe base64, with or without padding.
    static func base64Data(_ text: String) -> Data? {
        var body = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        var padding = 0
        while body.hasSuffix("=") {
            body.removeLast()
            padding += 1
        }
        let alphabet = body.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "+" || scalar == "/")
        }
        guard padding <= 2, !body.isEmpty, alphabet, body.count % 4 != 1 else { return nil }
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        return Data(base64Encoded: body)
    }

    /// The tunnel id of a decoded token, or nil when the JSON is not a token's.
    private static func tunnelID(in data: Data) -> String? {
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let account = fields["a"] as? String, !account.isEmpty else { return nil }
        guard let secret = fields["s"] as? String, !secret.isEmpty, Data(base64Encoded: secret) != nil else {
            return nil
        }
        guard let tunnel = fields["t"] as? String, let uuid = UUID(uuidString: tunnel) else { return nil }
        if let endpoint = fields["e"], !(endpoint is NSNull), !(endpoint is String) { return nil }
        return uuid.uuidString.lowercased()
    }

    // MARK: the cloudflared child (R31)

    /// `cloudflared`'s arguments: its own settings file (`cloudflaredSettings`), no updates, metrics on loopback and
    /// a short grace period, so the first SIGTERM ends it in most cases. Then `run`, whose token-file flag reads the
    /// token from standard input (R30). The token is not among them.
    public static func cloudflaredArguments(metricsPort: Int, configFile: String) -> [String] {
        let metrics = "127.0.0.1:\(metricsPort)"
        let tunnel = ["tunnel", "--config", configFile, "--no-autoupdate", "--metrics", metrics, "--grace-period", "1s"]
        return tunnel + ["run", tokenFileFlag, "/dev/stdin"]
    }

    /// `run`'s flag for a file that holds the token, here its standard input (cloudflared 2025.4.0 and later).
    static let tokenFileFlag = "--token-file"

    /// `cloudflared`'s environment: the clean environment (as LoginShell runs tools) without any inherited
    /// cloudflared setting, the token's variables included, or any copy of the token, then the login PATH and
    /// management diagnostics off. The token is not in it (R30): it goes on standard input (`cloudflaredInput`).
    public static func cloudflaredEnvironment(token: Token, loginPath: [String],
                                              base: [String: String]) -> [String: String] {
        let clean = TerminalEnvironment.clean(base)
        let copies = pastedForms(token)
        var environment = clean.filter { key, value in
            !key.hasPrefix("TUNNEL_") && !copies.contains(where: { value.contains($0) })
        }
        environment["PATH"] = loginPath.joined(separator: ":")
        environment["TUNNEL_MANAGEMENT_DIAGNOSTICS"] = "false"
        return environment
    }

    /// What Next Term writes on `cloudflared`'s standard input, once, before it closes it: the token as
    /// `cloudflared` reads it (standard base64, padded). `cloudflared` trims it and reads nothing else there.
    public static func cloudflaredInput(_ token: Token) -> Data {
        Data(token.value.utf8)
    }

    /// The four forms the token can be found in, standard first: standard or URL-safe base64, each with and
    /// without padding. Output is masked with them, and the self-test looks for them in a child's arguments and
    /// environment.
    public static func tokenForms(_ token: Token) -> [String] {
        let padded = token.value
        let unpadded = padded.replacingOccurrences(of: "=", with: "")
        let safePadded = padded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let safe = safePadded.replacingOccurrences(of: "=", with: "")
        var forms: [String] = []
        for form in [padded, unpadded, safePadded, safe] where !forms.contains(form) { forms.append(form) }
        return forms
    }

    /// The token as it may have been pasted or copied: standard or URL-safe base64, without padding. Each is a
    /// prefix of its padded form, so the two find all four forms.
    private static func pastedForms(_ token: Token) -> [String] {
        let unpadded = token.value.replacingOccurrences(of: "=", with: "")
        let urlSafe = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return [unpadded, urlSafe]
    }

    // MARK: cloudflared's own settings file (2026-10-11)

    /// The settings `cloudflared` gets in place of `~/.cloudflared/config.yml` (or the copies in `/etc/cloudflared`
    /// and `/usr/local/etc/cloudflared`), where a leftover `loglevel: debug` with a `logfile:` would write every
    /// request's headers, bearer tokens included, to disk.
    public static let cloudflaredSettings = "no-autoupdate: true\nloglevel: info\n"

    public static let cloudflaredSettingsName = "cloudflared.yml"

    /// Writes `cloudflaredSettings` `0600` in the Remote access folder (made `0700`), fresh at each start, and
    /// returns where.
    public static func writeCloudflaredSettings(in folder: URL) throws -> URL {
        try RemoteAccessStore.prepare(folder)
        let url = folder.appendingPathComponent(cloudflaredSettingsName)
        try RemoteAccessStore.replace(url, with: Data(cloudflaredSettings.utf8))
        return url
    }

    /// A tunnel connected to Cloudflare whose routing has not come after this long gets no routes from Cloudflare:
    /// it is managed from a local config file (2026-10-11).
    public static let routingWaitLimit: TimeInterval = 120

    public static let noRoutes = "This tunnel gets no routes from Cloudflare. Use a tunnel created in the Cloudflare "
        + "dashboard (Networking › Tunnels) and paste its token."

    public enum MetricsPath: String, Sendable {
        case ready
        case config
    }

    /// A page of `cloudflared`'s metrics server, on loopback.
    public static func metricsURL(port: Int, path: MetricsPath) -> URL {
        let text = "http://127.0.0.1:\(port)/\(path.rawValue)"
        return URL(string: text) ?? URL(fileURLWithPath: "/")
    }

    /// `/ready`: 200 with at least one ready connection to Cloudflare's edge (R32).
    public static func isReady(status: Int, body: Data) -> Bool {
        guard status == 200, let fields = object(body) else { return false }
        guard let count = fields["readyConnections"] as? NSNumber else { return false }
        return count.intValue >= 1
    }

    // MARK: routing checks (R33)

    /// What a routing check found.
    public enum Route: Equatable, Sendable {
        case ok
        /// Keeps running; Settings shows these.
        case warn([RouteWarning])
        /// Stops the tunnel, turns Remote access off and tells the Mac.
        case stop(RouteStop)
        /// Not ready, and not a stop: Funnel has no share for the hostname yet, or `cloudflared` has not had the
        /// tunnel's routing from Cloudflare yet.
        case waiting
    }

    public enum RouteStop: Equatable, Sendable {
        case unreadable
        case noRule
        case localhost
        case wrongService
        case otherRule
        case otherService
        case noCatchAll
        case hostHeader
        /// Funnel: the share reaches only the tailnet.
        case funnelOff

        /// Names only the saved hostname and the door, never a value read from the tunnel.
        public func message(host: String, port: Int) -> String {
            let door = RemoteAccessTunnelConfig.doorAddress(port: port)
            let again = "then turn Remote access on again."
            switch self {
            case .unreadable:
                return "Next Term can't read the tunnel's routing, so it stopped the tunnel."
            case .noRule:
                return "The tunnel has no route for \(host). Add one to \(door), \(again)"
            case .localhost:
                return "The tunnel points at localhost, which can resolve to ::1, where Next Term does not listen. "
                    + "Point it at \(door), \(again)"
            case .wrongService:
                return "The tunnel's route for \(host) no longer goes to Next Term. Point it at \(door), \(again)"
            case .otherRule:
                return "The tunnel carries more than Next Term. Keep only \(host) to \(door), \(again)"
            case .otherService:
                return "The tunnel's route for \(host) is not a plain web route. Point it at \(door), \(again)"
            case .noCatchAll:
                return "The tunnel's last rule must answer everything else with 404 (http_status:404). Add it, "
                    + again
            case .hostHeader:
                return "The tunnel rewrites the Host header (httpHostHeader). Remove that setting, \(again)"
            case .funnelOff:
                return "Funnel is off for \(host), so only your tailnet reaches it. Turn Remote access on again."
            }
        }
    }

    public enum RouteWarning: Equatable, Sendable {
        /// `originRequest` settings that are set and not known to leave the door's route as it is.
        case unknownSettings([String])
        /// The door's rule matches only some paths, so OAuth's paths may not reach it.
        case path
        /// Funnel: the share runs in the background, so it outlives Remote access.
        case backgroundShare
        /// Funnel: something else on this Mac is shared too.
        case otherShare
        /// Your own server: the server didn't let ssh listen on the server port. ssh can't tell why: an earlier
        /// connection the server hasn't dropped yet, another program, or sshd's rules. ssh starts again meanwhile.
        case serverPortBusy(server: String, port: Int)

        public var message: String {
            switch self {
            case .unknownSettings(let names):
                let known = names.isEmpty ? "" : ": " + names.joined(separator: ", ")
                return "The tunnel's route has settings Next Term doesn't know\(known)."
            case .path:
                return "The tunnel's route has a path, so part of Next Term can't be reached. Remove the path."
            case .backgroundShare:
                return "This Funnel share runs in the background, so it stays public while Remote access is off."
            case .otherShare:
                return "Funnel also shares something else from this Mac. It stays public while Remote access is off."
            case .serverPortBusy(let server, let port):
                let causes = "\(server) didn't let ssh listen on port \(port) for Next Term. An earlier connection may "
                    + "still hold it until \(server) drops it (ClientAliveInterval 15 in its sshd_config makes that "
                    + "take a minute), another program may use it, or its sshd may not allow it (AllowTcpForwarding, "
                    + "PermitListen)."
                let risk = "Meanwhile, whatever holds that port gets the requests meant for Next Term."
                let button = RemoteAccessTunnelConfig.newServerPortTitle
                let next = "Next Term keeps trying. To use another port, choose \(button) in Settings, then set up "
                    + "Caddy again."
                return [causes, risk, next].joined(separator: " ")
            }
        }
    }

    /// `originRequest` fields that leave a plain http route to the door as it is: the timeouts and keep-alives,
    /// and fields that act only on https, socks or bastion origins, which the checks stop anyway.
    static let knownSettings: Set<String> = [
        "connectTimeout", "tlsTimeout", "tcpKeepAlive", "noHappyEyeballs", "keepAliveTimeout",
        "keepAliveConnections", "disableChunkedEncoding", "originServerName", "matchSNItoHost", "caPool",
        "noTLSVerify", "proxyAddress", "proxyPort", "proxyType", "ipRules",
    ]

    /// Fields the checks read themselves: a Host override and bastion mode stop.
    static let checkedSettings: Set<String> = ["httpHostHeader", "bastionMode"]

    /// One rule of `/config`'s ingress list.
    private struct Rule {
        var hostname: String
        var path: String
        var service: String
        var settings: [String: Any]

        var isCatchAll: Bool {
            (hostname.isEmpty || hostname == "*") && path.isEmpty && service == "http_status:404"
        }
    }

    /// `cloudflared`'s `/config` against the saved hostname and the door's port: one rule for the hostname to
    /// `http://127.0.0.1:<port>`, then the 404 catch-all, and no Host override (R33).
    public static func cloudflareRoute(_ data: Data, host: String, port: Int) -> Route {
        guard let parsed = ingress(data) else { return .stop(.unreadable) }
        let (rules, defaults) = (parsed.rules, parsed.defaults)
        guard !awaitsRouting(version: parsed.version, rules: rules) else { return .waiting }
        let settings = [defaults] + rules.map(\.settings)
        guard !settings.contains(where: { isSet($0["httpHostHeader"]) }) else { return .stop(.hostHeader) }
        guard let last = rules.last else { return .stop(.noRule) }
        guard last.isCatchAll else { return .stop(.noCatchAll) }
        let others = rules.dropLast()
        let wanted = host.lowercased()
        guard let door = others.first(where: { normalized($0.hostname) == wanted }) else { return .stop(.noRule) }
        guard others.count == 1 else { return .stop(.otherRule) }
        let bastion = [defaults, door.settings].contains { isSet($0["bastionMode"]) }
        guard !bastion else { return .stop(.otherService) }
        if let stop = serviceStop(door.service, port: port) { return .stop(stop) }
        var warnings: [RouteWarning] = []
        if !door.path.isEmpty { warnings.append(.path) }
        let unknown = unknownSettings([defaults, door.settings])
        if let unknown { warnings.append(unknown) }
        return warnings.isEmpty ? .ok : .warn(warnings)
    }

    /// The hostname to confirm the first time the tunnel is ready (U10): the only rule's that names one, when it
    /// is a public hostname.
    public static func cloudflareHostname(_ data: Data) -> String? {
        guard let rules = ingress(data)?.rules else { return nil }
        let named = rules.filter { !$0.hostname.isEmpty && $0.hostname != "*" }
        guard named.count == 1, case .success(let name) = publicHostname(named[0].hostname) else { return nil }
        return name
    }

    /// Whether `/config` is still `cloudflared`'s own rule from before the tunnel's routing arrives: version -1 and
    /// one 503 for everything. Rules from a local config file at version -1 carry requests, so they are checked.
    private static func awaitsRouting(version: Int?, rules: [Rule]) -> Bool {
        guard let version, version < 0, rules.count == 1, let only = rules.first else { return false }
        return only.hostname.isEmpty && only.path.isEmpty && only.service == "http_status:503"
    }

    /// The version, the rules and the default `originRequest` of `/config`, or nil when it is not that shape.
    private static func ingress(_ data: Data) -> (version: Int?, rules: [Rule], defaults: [String: Any])? {
        guard let root = object(data), let config = root["config"] as? [String: Any] else { return nil }
        guard let list = config["ingress"] as? [Any] else { return nil }
        var rules: [Rule] = []
        for item in list {
            guard let rule = parsedRule(item) else { return nil }
            rules.append(rule)
        }
        let defaults = config["originRequest"] as? [String: Any] ?? [:]
        let version = (root["version"] as? NSNumber)?.intValue
        return (version, rules, defaults)
    }

    private static func parsedRule(_ item: Any) -> Rule? {
        guard let fields = item as? [String: Any], let service = fields["service"] as? String else { return nil }
        guard let hostname = optionalText(fields["hostname"]), let path = optionalText(fields["path"]) else {
            return nil
        }
        let settings = fields["originRequest"] as? [String: Any] ?? [:]
        return Rule(hostname: hostname, path: path, service: service, settings: settings)
    }

    /// A string, or "" for a missing or null value; nil for any other type.
    private static func optionalText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "" }
        return value as? String
    }

    private static func normalized(_ hostname: String) -> String {
        let lower = hostname.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// The stop a route's service gets, or nil when it is the door.
    private static func serviceStop(_ service: String, port: Int) -> RouteStop? {
        let lower = service.lowercased()
        let door = doorAddress(port: port)
        guard lower != door, lower != door + "/" else { return nil }
        for scheme in ["http://", "https://"] where lower.hasPrefix(scheme) {
            let authority = lower.dropFirst(scheme.count).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            let name = authority.hasPrefix("[") ? authority : authority.prefix { $0 != ":" }
            return name == "localhost" ? .localhost : .wrongService
        }
        return .otherService
    }

    /// Settings outside the known and checked ones that hold more than their empty default, by name. Names other
    /// than plain letters and digits are counted but not shown.
    private static func unknownSettings(_ groups: [[String: Any]]) -> RouteWarning? {
        var names = Set<String>()
        var unnamed = false
        for group in groups {
            for (key, value) in group where !knownSettings.contains(key) && !checkedSettings.contains(key) {
                guard isSet(value) else { continue }
                if isPlainName(key) { names.insert(key) } else { unnamed = true }
            }
        }
        guard !names.isEmpty || unnamed else { return nil }
        return .unknownSettings(names.sorted())
    }

    private static func isPlainName(_ key: String) -> Bool {
        guard (1...40).contains(key.count), let first = key.first, first.isASCIILetter else { return false }
        return key.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit }
    }

    /// Whether a JSON value holds more than an empty default: null, false, 0, "", an empty list, or an object of
    /// those are unset. cloudflared reports every field, most of them at such a default.
    static func isSet(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return !text.isEmpty }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let list = value as? [Any] { return !list.isEmpty }
        if let object = value as? [String: Any] { return object.values.contains(where: isSet) }
        return true
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Tailscale and Funnel (R31 to R34)

    /// Funnel in the foreground, so the share ends with the child. Never the background flag (R31).
    public static func funnelArguments(port: Int) -> [String] {
        ["funnel", doorAddress(port: port)]
    }

    /// This Mac's status only: with every peer, a large tailnet's would pass the 4 MB a read keeps, every 10 seconds.
    public static let tailscaleStatusArguments = ["status", "--json", "--peers=false"]
    public static let funnelStatusArguments = ["funnel", "status", "--json"]

    /// Why Tailscale can't carry the door.
    public enum TailscaleProblem: Error, Equatable, Sendable, CustomStringConvertible {
        case unreadable
        case notLoggedIn
        case needsApproval
        case stopped
        case notRunning
        case noName
        case noHTTPS
        case funnelOff
        case port443Off

        public var message: String {
            switch self {
            case .unreadable: return "Next Term can't read Tailscale's status."
            case .notLoggedIn: return "Tailscale is not logged in."
            case .needsApproval: return "This Mac waits for approval in your tailnet's admin console."
            case .stopped: return "Tailscale is turned off. Turn it on from the Tailscale menu."
            case .notRunning: return "Tailscale is not running yet."
            case .noName: return "Tailscale has no name for this Mac. Turn on MagicDNS for your tailnet."
            case .noHTTPS:
                return "Funnel needs HTTPS certificates. Turn on HTTPS for your tailnet in Tailscale's admin console."
            case .funnelOff: return "Funnel is not enabled for your tailnet."
            case .port443Off: return "Funnel is not allowed on port 443 for this Mac."
            }
        }

        public var description: String { message }
    }

    /// What a Funnel start does with Tailscale's status.
    public enum FunnelStart: Equatable, Sendable {
        case go
        /// Funnel or HTTPS is not enabled for the tailnet: `tailscale funnel` prints its own message, with the link
        /// that enables it, and waits there. The start goes on, Settings warns with this, and the child's lines show
        /// that message (U10).
        case waitForEnabling(warning: String)
        /// It can't start: the reason.
        case refuse(String)
    }

    public static func funnelStart(_ status: Result<String, TailscaleProblem>) -> FunnelStart {
        switch status {
        case .success:
            return .go
        case .failure(let problem) where problem == .funnelOff || problem == .noHTTPS:
            let next = "Tailscale's own message in the tunnel's output has the link that turns it on. Remote access "
                + "connects once it is on."
            return .waitForEnabling(warning: "\(problem.message) \(next)")
        case .failure(let problem):
            return .refuse(problem.message)
        }
    }

    /// From `tailscale status --json`: the Mac's name (its DNS name, lowercased, without the final dot) when
    /// Tailscale runs and this Mac may use Funnel on port 443.
    public static func tailscaleStatus(_ data: Data) -> Result<String, TailscaleProblem> {
        guard let root = object(data) else { return .failure(.unreadable) }
        switch root["BackendState"] as? String {
        case "Running": break
        case "NeedsLogin": return .failure(.notLoggedIn)
        case "NeedsMachineAuth": return .failure(.needsApproval)
        case "Stopped": return .failure(.stopped)
        default: return .failure(.notRunning)
        }
        let me = root["Self"] as? [String: Any] ?? [:]
        let name = me["DNSName"] as? String ?? ""
        guard case .success(let hostname) = publicHostname(name) else { return .failure(.noName) }
        let capabilities = nodeCapabilities(me)
        guard capabilities.contains("https") else { return .failure(.noHTTPS) }
        guard capabilities.contains("funnel") else { return .failure(.funnelOff) }
        guard funnelAllows443(capabilities) else { return .failure(.port443Off) }
        return .success(hostname)
    }

    /// The node's capabilities: `CapMap`'s keys and the older `Capabilities` list.
    private static func nodeCapabilities(_ me: [String: Any]) -> Set<String> {
        var capabilities = Set((me["CapMap"] as? [String: Any] ?? [:]).keys)
        for case let capability as String in me["Capabilities"] as? [Any] ?? [] {
            capabilities.insert(capability)
        }
        return capabilities
    }

    /// Whether the funnel-ports capability lists 443, alone or in a range. Without it, Tailscale allows no port.
    private static func funnelAllows443(_ capabilities: Set<String>) -> Bool {
        let base = "https://tailscale.com/cap/funnel-ports"
        for capability in capabilities where capability.hasPrefix(base + "?") {
            guard let parts = URLComponents(string: capability) else { continue }
            let ports = parts.queryItems?.first { $0.name == "ports" }?.value ?? ""
            if ports.split(separator: ",").contains(where: { allows443($0) }) { return true }
        }
        return false
    }

    private static func allows443(_ item: Substring) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed == "443" { return true }
        let ends = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let low = Int(ends[0]), let high = Int(ends[1]) else { return false }
        return low <= 443 && 443 <= high
    }

    /// The fields a handler that only proxies may set. Tailscale serves `Text`, `Redirect` and `Path` ahead of
    /// `Proxy`, so a handler with any other field set does not reach the door.
    static let proxyHandlerFields: Set<String> = ["Proxy", "AcceptAppCaps"]

    /// One handler of a serve config, on the hostname's port 443.
    private struct Handler {
        var mount: String
        var fields: [String: Any]
        var funnel: Bool
        var background: Bool
    }

    /// The serve configs in `tailscale funnel status --json`: the background one, then each foreground session's.
    private static func serveConfigs(_ root: [String: Any]) -> [(config: [String: Any], background: Bool)] {
        var configs: [(config: [String: Any], background: Bool)] = [(root, true)]
        let sessions = root["Foreground"] as? [String: Any] ?? [:]
        for key in sessions.keys.sorted() {
            if let session = sessions[key] as? [String: Any] { configs.append((session, false)) }
        }
        return configs
    }

    /// `tailscale funnel status --json` against the Mac's name and the door's port: port 443 on the name allows
    /// Funnel and has one handler, at "/", that only proxies to `http://127.0.0.1:<port>` (R33). No share yet is
    /// waiting, not a stop.
    public static func funnelRoute(_ data: Data, host: String, port: Int) -> Route {
        guard let root = object(data) else { return .stop(.unreadable) }
        let wanted = "\(host.lowercased()):443"
        var handlers: [Handler] = []
        var otherShare = false
        for (config, background) in serveConfigs(root) {
            let tcp = (config["TCP"] as? [String: Any])?["443"] as? [String: Any] ?? [:]
            guard !isSet(tcp["TCPForward"]) else { return .stop(.otherService) }
            let allowed = config["AllowFunnel"] as? [String: Any] ?? [:]
            otherShare = otherShare || allowed.contains { $0.key.lowercased() != wanted && isSet($0.value) }
            let web = config["Web"] as? [String: Any] ?? [:]
            for (key, value) in web where key.lowercased() == wanted {
                let funnel = allowed.contains { $0.key.lowercased() == wanted && isSet($0.value) }
                let mounts = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
                for (mount, raw) in mounts {
                    let fields = raw as? [String: Any] ?? [:]
                    handlers.append(Handler(mount: mount, fields: fields, funnel: funnel, background: background))
                }
            }
        }
        guard let handler = handlers.first else { return .waiting }
        guard handlers.count == 1 else { return .stop(.otherRule) }
        guard handler.mount == "/", let proxy = handler.fields["Proxy"] as? String else {
            return .stop(.wrongService)
        }
        let more = handler.fields.contains { !proxyHandlerFields.contains($0.key) && isSet($0.value) }
        guard !more else { return .stop(.wrongService) }
        if let stop = serviceStop(proxy, port: port) {
            return .stop(stop == .otherService ? .wrongService : stop)
        }
        guard handler.funnel else { return .stop(.funnelOff) }
        var warnings: [RouteWarning] = []
        if handler.background { warnings.append(.backgroundShare) }
        if otherShare { warnings.append(.otherShare) }
        return warnings.isEmpty ? .ok : .warn(warnings)
    }

    /// Whether any share on this Mac is open to the internet, before Next Term starts its own (R34).
    public static func funnelShareExists(_ data: Data) -> Bool {
        guard let root = object(data) else { return false }
        return serveConfigs(root).contains { entry in
            let allowed = entry.config["AllowFunnel"] as? [String: Any] ?? [:]
            return allowed.values.contains(where: isSet)
        }
    }

    // MARK: your own server over ssh (R46, R47, U15)

    /// "Your own server": a host the user saved in Next Term's remote hosts (R46), and the port on it, on its
    /// loopback only, that forwards to the door.
    public struct OwnServer: Equatable, Sendable {
        public var host: RemoteHost
        public var port: Int

        public init(host: RemoteHost, port: Int) {
            self.host = host
            self.port = port
        }

        public var name: String { host.name }
    }

    /// Where a server port is picked from, once per host: below Linux's ephemeral ports (32768 to 60999), so a
    /// reconnect's listen never meets the port of one of the server's outgoing connections.
    public static let serverPorts: ClosedRange<Int> = 20000...32767

    /// The saved server port while it is in the range, never another; otherwise one picked from the range, to be
    /// saved with the host's Remote access settings. `random(n)` gives a number from 0 to n - 1 (others are
    /// wrapped into that).
    public static func serverPort(saved: Int?, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        if let saved, serverPorts.contains(saved) { return saved }
        let count = serverPorts.count
        let offset = ((random(count) % count) + count) % count
        return serverPorts.lowerBound + offset
    }

    /// The button that picks another server port, when the server keeps the saved one busy.
    public static let newServerPortTitle = "New Server Port"

    /// Another server port from the range, never `old`: for New Server Port. The server's Caddyfile then needs the
    /// new one, through Set Up Caddy again.
    public static func newServerPort(replacing old: Int, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        guard serverPorts.contains(old) else { return serverPort(saved: nil, random: random) }
        let count = serverPorts.count - 1
        let port = serverPorts.lowerBound + ((random(count) % count) + count) % count
        return port >= old ? port + 1 : port
    }

    /// The one forward: the server's `127.0.0.1:<server port>` to the door at `127.0.0.1:<door port>`. The server
    /// side names loopback, so it listens there only while the server's sshd keeps GatewayPorts at no (its
    /// default) or clientspecified. With GatewayPorts yes, sshd listens on every address whatever this says, and
    /// nothing on the Mac can see it: the docs and hand check H15 cover it.
    public static func sshForward(serverPort: Int, doorPort: Int) -> String {
        "127.0.0.1:\(serverPort):127.0.0.1:\(doorPort)"
    }

    /// The system ssh's arguments for the reverse forward (R46, R47), an array and never shell text:
    /// - `-N`: no session, so no command, shell, agent or X11 forwarding: only the door's forward.
    /// - It never prompts (BatchMode): a login that needs the user happens in a visible remote tab first.
    /// - It never takes a host key (StrictHostKeyChecking=yes), nor writes one (UpdateHostKeys=no).
    /// - It ends when the forward fails, and within 45 seconds of a dead connection, so it starts again.
    /// - Its own connection: never a master for the user's sessions, never one of theirs (a forward made through a
    ///   master outlives the client that asked for it).
    /// - ssh's debug lines say when the server took the forward: the status is On only then.
    /// - `configFile`: Next Term's ssh config (RemoteConnection's), so ProxyJump hops ask about host keys too, and
    ///   a hop that would ask fails here, with no terminal.
    /// - What the user's ssh config may set for every ssh they run is set back here, since the first value ssh
    ///   reads wins and these come before the config: it never goes to the background
    ///   (ForkAfterAuthentication), where it would leave the process group Turn Off and quit end, the watchdog and
    ///   the pid record; it runs no command on the server or the Mac (RemoteCommand, PermitLocalCommand); and it
    ///   forwards no agent, X11 display or network device. ClearAllForwardings stays no, since yes would clear the
    ///   door's forward too.
    /// - A forward the user's config adds for the server can't be cleared without the door's, so each start checks
    ///   with `sshCheckArguments` first and refuses one (`sshSettingsProblem`).
    public static func sshArguments(_ server: OwnServer, doorPort: Int, configFile: String?) -> [String] {
        var arguments: [String] = configFile.map { ["-F", $0] } ?? []
        arguments.append("-N")
        let options = [
            "BatchMode=yes", "StrictHostKeyChecking=yes", "UpdateHostKeys=no", "ExitOnForwardFailure=yes",
            "ServerAliveInterval=15", "ServerAliveCountMax=3", "ConnectTimeout=15",
            "ControlMaster=no", "ControlPath=none",
            "ForkAfterAuthentication=no", "ClearAllForwardings=no", "RemoteCommand=none", "PermitLocalCommand=no",
            "Tunnel=no", "ForwardAgent=no", "ForwardX11=no",
            "LogLevel=DEBUG1",
        ]
        for option in options { arguments += ["-o", option] }
        arguments += ["-R", sshForward(serverPort: server.port, doorPort: doorPort)]
        if let port = server.host.port { arguments += ["-p", String(port)] }
        return arguments + ["--", server.host.destination]
    }

    /// `ssh -G` with the child's own arguments: ssh prints the settings it would connect with, the user's config
    /// read, and connects to nothing. Run before each start.
    public static func sshCheckArguments(_ server: OwnServer, doorPort: Int, configFile: String?) -> [String] {
        ["-G"] + sshArguments(server, doorPort: doorPort, configFile: configFile)
    }

    /// Why the child must not start, from what `ssh -G` printed (nil or empty: it couldn't read its config), or
    /// nil. Every forward has to be the door's: a LocalForward, DynamicForward or RemoteForward the user's config
    /// sets for the server would ride along on the child, and with ExitOnForwardFailure a busy one would make it
    /// restart forever. The door's forward must be there, and ssh must not go to the background.
    public static func sshSettingsProblem(_ printed: String?, server: OwnServer, doorPort: Int) -> String? {
        let name = server.name
        guard let printed, !printed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ssh can't read its settings for \(name). Run ssh -G \(server.host.destination) in a terminal to "
                + "see why."
        }
        let names = ["localforward": "LocalForward", "dynamicforward": "DynamicForward",
                     "remoteforward": "RemoteForward"]
        let door = "127.0.0.1:\(server.port) 127.0.0.1:\(doorPort)"
        var doorFound = false
        var others: [String] = []
        var forks = false
        for line in printed.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = words.first?.lowercased() else { continue }
            let value = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
            if key == "forkafterauthentication", value.lowercased() == "yes" { forks = true }
            guard let shown = names[key] else { continue }
            let plain = value.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            if key == "remoteforward", plain == door, !doorFound {
                doorFound = true
            } else {
                others.append("\(shown) \(plain)")
            }
        }
        if !others.isEmpty {
            let listed = others.prefix(3).joined(separator: ", ") + (others.count > 3 ? ", …" : "")
            return "Your ssh config adds forwards for \(name) (\(listed)), and Remote access forwards only its own "
                + "port. Remove them from that host's entry in ~/.ssh/config or /etc/ssh/ssh_config, then turn "
                + "Remote access on again."
        }
        if !doorFound {
            return "ssh's settings for \(name) leave out the door's forward, so Remote access can't start. Check "
                + "\(name)'s entry in ~/.ssh/config and /etc/ssh/ssh_config."
        }
        if forks {
            return "ssh would go to the background for \(name), out of reach of Turn Off, so Remote access can't "
                + "start. Check \(name)'s entry in ~/.ssh/config and /etc/ssh/ssh_config."
        }
        return nil
    }

    /// What a line of the ssh child's output says about the forward.
    public enum SSHLine: Equatable, Sendable {
        /// Logged in to the server.
        case loggedIn
        /// The server listens on the server port for the door.
        case forwardHolds
        /// The server could not listen on the server port.
        case serverPortBusy
        /// The host key is not known on this Mac, or it changed.
        case hostKey
        /// The login needs the user: a password, a passphrase that isn't in the agent, a security key, or no key
        /// the server takes.
        case loginNeeded
    }

    /// One line of ssh's output, as OpenSSH prints it. The forward's lines are ssh's debug lines and name the
    /// server port; the others are its own messages, never a debug line that happens to hold the same words.
    public static func sshLine(_ line: String, serverPort: Int) -> SSHLine? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("debug1: ") {
            if text.contains("remote forward success for: listen 127.0.0.1:\(serverPort),") { return .forwardHolds }
            if text.contains("remote forward failure for: listen 127.0.0.1:\(serverPort),") { return .serverPortBusy }
            return nil
        }
        guard !isDebugLine(text) else { return nil }
        if text.hasPrefix("Authenticated to ") { return .loggedIn }
        if text.hasSuffix("remote port forwarding failed for listen port \(serverPort)") { return .serverPortBusy }
        let hostKey = ["Host key verification failed.", "REMOTE HOST IDENTIFICATION HAS CHANGED"]
        if hostKey.contains(where: text.contains) { return .hostKey }
        if text.contains(" host key is known for ") && text.contains("strict checking") { return .hostKey }
        let login = ["Permission denied (", "Too many authentication failures"]
        if login.contains(where: text.contains) { return .loginNeeded }
        return nil
    }

    /// Whether Settings keeps the line: ssh's own messages and the forward's success, not its other debug lines,
    /// which every request through the forward adds.
    public static func keepsSSHLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        guard isDebugLine(text) else { return true }
        return text.hasPrefix("debug1: remote forward ")
    }

    private static func isDebugLine(_ text: String) -> Bool {
        ["debug1: ", "debug2: ", "debug3: "].contains(where: text.hasPrefix)
    }

    /// The ssh child's output, split into lines as it comes, `\r\n` or `\n`. A line longer than `longest` is cut
    /// there and the rest of it dropped.
    public struct SSHLines: Sendable {
        public static let longest = 4096

        private var part = Data()
        private var skipping = false

        public init() {}

        public mutating func read(_ data: Data) -> [String] {
            var lines: [String] = []
            var rest = data[...]
            while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                if skipping {
                    skipping = false
                } else {
                    part.append(rest[rest.startIndex..<newline])
                    lines.append(Self.text(part))
                }
                part.removeAll()
                rest = rest[rest.index(after: newline)...]
            }
            guard !skipping else { return lines }
            part.append(rest)
            guard part.count > Self.longest else { return lines }
            lines.append(Self.text(part.prefix(Self.longest)))
            part.removeAll()
            skipping = true
            return lines
        }

        /// What is left once the output ends.
        public mutating func finish() -> [String] {
            defer {
                part.removeAll()
                skipping = false
            }
            return part.isEmpty || skipping ? [] : [Self.text(part)]
        }

        private static func text(_ bytes: Data) -> String {
            var line = String(decoding: bytes, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }

    public static let serverNeeded = "Choose your server from your remote hosts in Settings › Remote Access first."

    /// An unknown or changed host key: nothing starts (R47).
    public static func sshHostKeyProblem(_ server: String) -> String {
        "Next Term doesn't know \(server)'s host key yet, or the key changed. Connect to \(server) once in a "
            + "remote tab and check its key there, then turn Remote access on again."
    }

    /// The login still needs the user after they logged in in the tab: a password, or a key that isn't in the agent.
    public static func sshLoginProblem(_ server: String) -> String {
        "\(server) needs you at each login (a password, a passphrase or a security key), and Remote access logs in "
            + "on its own. Add your key to the ssh agent, or set up key login for \(server), then turn Remote access "
            + "on again."
    }

    /// The login tab ended before its login got through.
    public static func sshLoginNeeded(_ server: String) -> String {
        "Log in to \(server) in a remote tab to turn Remote access on."
    }

    /// How long after the user's own Turn On a login tab is put in front of them. Any later one, at a launch, after
    /// a drop, or long after the click, opens in the background, where nothing typed in Next Term reaches it, and
    /// the Mac is told (`sshLoginTabNotice`).
    public static let loginTabInFrontFor: TimeInterval = 120

    /// The Mac's notification for a login tab opened in the background.
    public static func sshLoginTabNotice(_ server: String) -> (title: String, body: String) {
        let body = "Remote access needs you to log in to \(server) again. Next Term opened a tab on \(server) in the "
            + "background: log in there, and Remote access starts again."
        return ("Remote access: log in to \(server)", body)
    }

    // MARK: Caddy on your own server (R48)

    /// The server's system, for Caddy's install command. Picked in the confirmation, never read from the server.
    /// Each label names only systems whose own packages have Caddy; any other installs it first (Caddy's install
    /// docs) and picks "installed already".
    public enum CaddySystem: String, Sendable, CaseIterable {
        case apt
        case dnf
        case installed

        public var label: String {
            switch self {
            case .apt: return "Debian 12 or later, Ubuntu 24.04 or later"
            case .dnf: return "Fedora"
            case .installed: return "Caddy is installed already"
            }
        }
    }

    /// The door's site, a file of its own beside the user's Caddyfile, which keeps its sites.
    public static let caddySiteFile = "/etc/caddy/Caddyfile.d/next-term.caddyfile"
    static let caddyMainFile = "/etc/caddy/Caddyfile"
    /// Copies of the Caddyfile and of the door's earlier site, kept while Caddy's check runs, outside the folder
    /// the Caddyfile imports.
    static let caddyMainCopy = "/etc/caddy/Caddyfile.before-next-term"
    static let caddySiteCopy = "/etc/caddy/next-term.caddyfile.before"

    /// The door's site: TLS for the hostname, and every request to the forward on the server's loopback. Caddy
    /// passes the Host header as it came.
    public static func caddyfile(hostname: String, serverPort: Int) -> String {
        "\(hostname) {\n\treverse_proxy 127.0.0.1:\(serverPort)\n}\n"
    }

    /// The commands "Set up Caddy" types, in order: install Caddy, keep copies of the Caddyfile and of the door's
    /// earlier site, write the door's site, import it from the Caddyfile unless it is imported already, check the
    /// whole config, remove the copies, start Caddy, reload it. A failed check puts both copies back and stops
    /// there (R48): a Caddyfile that already has a block for the hostname fails it, and left in place it would stop
    /// every site at Caddy's next restart. Nil unless the hostname is a public hostname and the port a server port.
    ///
    /// They are typed as one line into the user's own login shell on the server, so sudo asks once, and every shell
    /// reads them alike (sh, bash, zsh, fish, tcsh): no `!`, `$`, backquote, tab or line break, and no `~`; anything
    /// more than `&&` and a pipe goes to `sh -c`, quoted.
    public static func caddySetup(_ system: CaddySystem, hostname: String, serverPort: Int) -> [String]? {
        guard case .success(let name) = publicHostname(hostname), name == hostname.lowercased() else { return nil }
        guard serverPorts.contains(serverPort) else { return nil }
        var commands: [String] = []
        switch system {
        case .apt: commands += ["sudo apt-get update", "sudo apt-get install -y caddy"]
        case .dnf: commands.append("sudo dnf install -y caddy")
        case .installed: break
        }
        let folder = (caddySiteFile as NSString).deletingLastPathComponent
        commands.append("sudo mkdir -p \(folder)")
        commands.append("sudo cp -p \(caddyMainFile) \(caddyMainCopy)")
        commands.append("sudo sh -c \"rm -f \(caddySiteCopy) && if test -e \(caddySiteFile); then "
            + "cp -p \(caddySiteFile) \(caddySiteCopy); fi\"")
        // Written as the Caddyfile reads, its line breaks and tab given to printf.
        let site = caddyfile(hostname: name, serverPort: serverPort)
        let format = site.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        commands.append("printf '\(format)' | sudo tee \(caddySiteFile)")
        commands.append(caddyImport)
        commands.append(caddyCheck)
        commands.append("sudo rm -f \(caddyMainCopy) \(caddySiteCopy)")
        commands.append("sudo systemctl enable --now caddy")
        commands.append("sudo systemctl reload caddy")
        return commands
    }

    /// Adds the import of the door's site to the Caddyfile, at its end on a line of its own, unless the Caddyfile
    /// imports that folder already (Fedora's does).
    static let caddyImport: String = {
        let pattern = "^[[:space:]]*import[[:space:]]+(/etc/caddy/)?Caddyfile[.]d/[*][.]caddyfile"
        let line = "import /etc/caddy/Caddyfile.d/*.caddyfile"
        let check = "grep -qsE '\(pattern)' \(caddyMainFile)"
        return "sudo sh -c \"\(check) || printf '\\n\(line)\\n' >> \(caddyMainFile)\""
    }()

    /// Caddy's check of the whole config; when it fails, the Caddyfile and the door's earlier site (or none) are
    /// put back from their copies, and the line stops.
    static let caddyCheck: String = {
        let validate = "caddy validate --config \(caddyMainFile) --adapter caddyfile"
        let site = "if test -e \(caddySiteCopy); then mv \(caddySiteCopy) \(caddySiteFile); "
            + "else rm -f \(caddySiteFile); fi"
        let back = "mv \(caddyMainCopy) \(caddyMainFile); \(site); exit 1"
        return "sudo sh -c \"\(validate) || { \(back); }\""
    }()

    /// The one line typed: each command after the one before succeeded.
    public static func caddySetupLine(_ commands: [String]) -> String {
        commands.joined(separator: " && ")
    }

    // MARK: checks and restarts (R32)

    /// Seconds between health and routing checks.
    public static let checkInterval: TimeInterval = 10
    /// The longest wait before a restart.
    public static let longestRestartWait: TimeInterval = 60
    /// Seconds down before the Mac is told.
    public static let notifyAfter: TimeInterval = 600

    /// The wait before restart number `attempt` (1 for the first): 1 second, doubling, at most 60.
    public static func restartWait(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 1 }
        guard attempt <= 7 else { return longestRestartWait }
        return min(longestRestartWait, TimeInterval(1 << (attempt - 1)))
    }

    /// Whether a tunnel down since `downSince` has been down long enough to tell the Mac.
    public static func notifies(downSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(downSince) >= notifyAfter
    }
}

// isASCIIDigit is the module's (SQLiteEditing.swift).
private extension Character {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}
