import Foundation

/// The tunnel checks for Remote access, all pure: the four tunnel choices, the public hostname a user types, where
/// `cloudflared` and `tailscale` are and how old they are, the Cloudflare tunnel token, the arguments and the
/// environment each child runs with, what `cloudflared`'s `/ready` and `/config` say, what Tailscale's status and
/// Funnel share say, and the waits between restarts. The app (RemoteAccessTunnel) runs the processes and the timers.
///
/// Rules this file keeps:
/// - Arguments are arrays, never shell text (as in Remote.swift).
/// - The tunnel token never goes in an argument, a description or an error. It reaches `cloudflared` only through
///   the environment, built in one place (R30).
/// - A routing check answers ok, warn, stop (or, for Funnel, waiting), and its messages name only the saved hostname
///   and the door's port: never a value read from the tunnel, which whoever holds the tunnel's account can set.
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
                return "TLS ends on your server, so only you can read the traffic. It reaches this Mac over ssh."
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
    public struct CloudflaredVersion: Equatable, Sendable {
        public var year: Int
        public var month: Int
        public var patch: Int

        public init(year: Int, month: Int, patch: Int) {
            self.year = year
            self.month = month
            self.patch = patch
        }

        public var text: String { "\(year).\(month).\(patch)" }

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

    /// `cloudflared`'s arguments. The token is not among them. The short grace period lets the first SIGTERM end
    /// it in most cases.
    public static func cloudflaredArguments(metricsPort: Int) -> [String] {
        let metrics = "127.0.0.1:\(metricsPort)"
        return ["tunnel", "--no-autoupdate", "--metrics", metrics, "--grace-period", "1s", "run"]
    }

    /// `cloudflared`'s environment: the clean environment (as LoginShell runs tools) without any inherited
    /// cloudflared setting or copy of the token, the login PATH, management diagnostics off, and the token. The
    /// only place the token's variable is named (the Verification Contract's argv gate).
    public static func cloudflaredEnvironment(token: Token, loginPath: [String],
                                              base: [String: String]) -> [String: String] {
        let clean = TerminalEnvironment.clean(base)
        var environment = clean.filter { key, value in
            !key.hasPrefix("TUNNEL_") && !value.contains(token.value)
        }
        environment["PATH"] = loginPath.joined(separator: ":")
        environment["TUNNEL_MANAGEMENT_DIAGNOSTICS"] = "false"
        environment["TUNNEL_TOKEN"] = token.value
        return environment
    }

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
        /// Funnel only: no share for the hostname yet, so not ready, and not a stop.
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
        let (rules, defaults) = parsed
        let settings = [defaults] + rules.map(\.settings)
        guard !settings.contains(where: { isSet($0["httpHostHeader"]) }) else { return .stop(.hostHeader) }
        guard let last = rules.last else { return .stop(.noRule) }
        guard last.isCatchAll else { return .stop(.noCatchAll) }
        let others = rules.dropLast()
        let wanted = host.lowercased()
        guard let door = others.first(where: { normalized($0.hostname) == wanted }) else { return .stop(.noRule) }
        guard others.count == 1 else { return .stop(.otherRule) }
        guard !isSet(door.settings["bastionMode"]) else { return .stop(.otherService) }
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

    /// The rules and the default `originRequest` of `/config`, or nil when it is not that shape.
    private static func ingress(_ data: Data) -> (rules: [Rule], defaults: [String: Any])? {
        guard let root = object(data), let config = root["config"] as? [String: Any] else { return nil }
        guard let list = config["ingress"] as? [Any] else { return nil }
        var rules: [Rule] = []
        for item in list {
            guard let rule = parsedRule(item) else { return nil }
            rules.append(rule)
        }
        let defaults = config["originRequest"] as? [String: Any] ?? [:]
        return (rules, defaults)
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

    public static let tailscaleStatusArguments = ["status", "--json"]
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
    /// Funnel and has one handler, at "/", that proxies to `http://127.0.0.1:<port>` (R33). No share yet is
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

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}
