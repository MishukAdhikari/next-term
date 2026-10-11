import Foundation
import Testing
@testable import NextTermCore

/// The tunnel checks: the four choices, the hostname a user types, where the tools are and how old they are, the
/// Cloudflare token and the child's arguments and environment, `/ready` and `/config`, Tailscale's status and the
/// Funnel share, and the waits between restarts.
@Suite struct RemoteAccessTunnelConfigTests {
    typealias Config = RemoteAccessTunnelConfig

    let host = "mcp.example.com"
    let port = 41234
    let tailnetHost = "mac.tailnet-0000.ts.net"
    static let account = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    static let tunnel = "C2A9E5D4-1B3F-4E6A-9C8D-7F0E1A2B3C4D"

    // MARK: helpers

    /// A token as the dashboard shows it: standard base64 of the JSON, padded.
    func token(account: String? = account, tunnel: String? = tunnel, secret: String? = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0IQ==",
               extra: String = "") -> String {
        var fields: [String] = []
        if let account { fields.append(#""a":"\#(account)""#) }
        if let secret { fields.append(#""s":"\#(secret)""#) }
        if let tunnel { fields.append(#""t":"\#(tunnel)""#) }
        if !extra.isEmpty { fields.append(extra) }
        let json = "{" + fields.joined(separator: ",") + "}"
        return Data(json.utf8).base64EncodedString()
    }

    func urlSafe(_ token: String) -> String {
        let dashed = token.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return dashed.replacingOccurrences(of: "=", with: "")
    }

    func parsed(_ pasted: String) -> Config.Token? {
        if case .success(let token) = Config.token(pasted) { return token }
        return nil
    }

    func tokenError(_ pasted: String) -> Config.TokenError? {
        if case .failure(let error) = Config.token(pasted) { return error }
        return nil
    }

    func hostname(_ typed: String) -> String? {
        if case .success(let name) = Config.publicHostname(typed) { return name }
        return nil
    }

    func hostnameError(_ typed: String) -> Config.HostnameError? {
        if case .failure(let error) = Config.publicHostname(typed) { return error }
        return nil
    }

    func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    /// `originRequest` as cloudflared 2026.10.0 resolves it: every field, at its default.
    var resolvedDefaults: [String: Any] {
        var fields: [String: Any] = ["connectTimeout": 30, "tlsTimeout": 10, "tcpKeepAlive": 30]
        fields["noHappyEyeballs"] = false
        fields["keepAliveTimeout"] = 90
        fields["keepAliveConnections"] = 100
        fields["httpHostHeader"] = ""
        fields["originServerName"] = ""
        fields["matchSNItoHost"] = false
        fields["caPool"] = ""
        fields["noTLSVerify"] = false
        fields["disableChunkedEncoding"] = false
        fields["bastionMode"] = false
        fields["proxyAddress"] = "127.0.0.1"
        fields["proxyPort"] = 0
        fields["proxyType"] = ""
        fields["ipRules"] = NSNull()
        fields["http2Origin"] = false
        fields["access"] = ["required": false, "teamName": "", "audTag": NSNull()] as [String: Any]
        return fields
    }

    func rule(_ hostname: String?, _ service: String, _ changes: [String: Any] = [:]) -> [String: Any] {
        var origin = resolvedDefaults
        for (key, value) in changes { origin[key] = value }
        var fields: [String: Any] = ["service": service, "path": NSNull(), "Handlers": NSNull()]
        fields["hostname"] = hostname ?? ""
        fields["originRequest"] = origin
        return fields
    }

    var catchAll: [String: Any] { rule(nil, "http_status:404") }

    var doorRule: [String: Any] { rule(host, "http://127.0.0.1:\(port)") }

    /// `/config` as cloudflared serves it: the version, then the rules and the defaults.
    func config(_ rules: [[String: Any]], defaults: [String: Any]? = nil, version: Int = 3) -> Data {
        var inner: [String: Any] = ["ingress": rules]
        inner["originRequest"] = defaults ?? resolvedDefaults
        return json(["version": version, "config": inner] as [String: Any])
    }

    func route(_ rules: [[String: Any]], defaults: [String: Any]? = nil, version: Int = 3) -> Config.Route {
        Config.cloudflareRoute(config(rules, defaults: defaults, version: version), host: host, port: port)
    }

    /// cloudflared's own rule while it has no routing: everything gets 503.
    var noRoutingYet: [String: Any] { ["service": "http_status:503", "hostname": "", "path": NSNull()] }

    /// One serve config: these handlers on the hostname's port 443, Funnel on or off.
    func share(_ handlers: [String: Any], host: String? = nil, funnel: Bool = true,
               tcp: [String: Any] = ["HTTPS": true]) -> [String: Any] {
        let key = "\(host ?? tailnetHost):443"
        var fields: [String: Any] = ["TCP": ["443": tcp]]
        fields["Web"] = [key: ["Handlers": handlers]]
        if funnel { fields["AllowFunnel"] = [key: true] }
        return fields
    }

    func foreground(_ config: [String: Any]) -> Data {
        json(["Foreground": ["a1b2c3": config]])
    }

    var doorHandler: [String: Any] { ["/": ["Proxy": "http://127.0.0.1:\(port)"]] }

    func funnel(_ data: Data) -> Config.Route {
        Config.funnelRoute(data, host: tailnetHost, port: port)
    }

    func status(state: String = "Running", name: String = "Mac.tailnet-0000.ts.net.",
                caps: [String] = ["https", "funnel", "https://tailscale.com/cap/funnel-ports?ports=443,8443,10000"],
                legacy: Bool = false) -> Data {
        var me: [String: Any] = ["DNSName": name]
        if legacy {
            me["Capabilities"] = caps
        } else {
            var map: [String: Any] = [:]
            for cap in caps { map[cap] = NSNull() }
            me["CapMap"] = map
        }
        return json(["BackendState": state, "Self": me] as [String: Any])
    }

    func tailscale(_ data: Data) -> Result<String, Config.TailscaleProblem> {
        Config.tailscaleStatus(data)
    }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return utc.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    // MARK: the four choices

    @Test func theFourChoicesAreThePlans() {
        let labels = Config.Kind.allCases.map(\.label)
        #expect(labels == ["Tailscale Funnel", "Cloudflare Tunnel", "Your own server (over ssh)",
                           "Advanced: I expose the port myself"])
        for kind in Config.Kind.allCases {
            #expect(!kind.traffic.isEmpty)
        }
        #expect(Config.Kind.cloudflare.traffic.contains("Cloudflare can read"))
        #expect(Config.Kind.funnel.traffic.contains("on this Mac"))
        #expect(Config.Kind.ownServer.traffic.contains("your server"))
    }

    @Test func onlyAdvancedRunsNoTunnel() {
        #expect(Config.Kind.funnel.runsTunnel)
        #expect(Config.Kind.cloudflare.runsTunnel)
        #expect(Config.Kind.ownServer.runsTunnel)
        #expect(!Config.Kind.advanced.runsTunnel)
    }

    @Test func aKindIsSavedByAStableName() throws {
        let saved = try JSONEncoder().encode([Config.Kind.ownServer, .advanced])
        #expect(String(decoding: saved, as: UTF8.self) == #"["ownServer","advanced"]"#)
    }

    @Test func advancedShowsTheDoorAndSaysItIsNotManaged() {
        #expect(Config.doorAddress(port: port) == "http://127.0.0.1:41234")
        #expect(Config.advancedStatus(port: port)
                == "Door open on 127.0.0.1:41234. Your tunnel is not managed by Next Term.")
        #expect(Config.advancedWarning.contains("keeps forwarding"))
        #expect(Config.advancedWarning.contains("while Remote access is off"))
    }

    // MARK: the hostname a user types (own server, Advanced)

    @Test func aPlainHostnameIsKept() {
        #expect(hostname("mcp.example.com") == "mcp.example.com")
        #expect(hostname("xn--mnchen-3ya.example") == "xn--mnchen-3ya.example")
        #expect(hostname("a-b.c-d.example.org") == "a-b.c-d.example.org")
    }

    @Test func aPastedConnectorURLGivesItsHostname() {
        #expect(hostname("  https://MCP.Example.com/mcp \n") == "mcp.example.com")
        #expect(hostname("https://mcp.example.com/") == "mcp.example.com")
        #expect(hostname("https://mcp.example.com:443/mcp") == "mcp.example.com")
        #expect(hostname("mcp.example.com.") == "mcp.example.com")
        #expect(hostname("mcp.example.com:443") == "mcp.example.com")
    }

    @Test func aHostnameThatCannotBeTheDoorsIsRefused() {
        #expect(hostnameError("") == .empty)
        #expect(hostnameError("   ") == .empty)
        #expect(hostnameError("http://mcp.example.com") == .notHTTPS)
        #expect(hostnameError("ftp://mcp.example.com") == .notHTTPS)
        #expect(hostnameError("mcp.example.com:8443") == .port)
        #expect(hostnameError("https://mcp.example.com:80/mcp") == .port)
        #expect(hostnameError("https://mcp.example.com/other") == .path)
        #expect(hostnameError("mcp.example.com/mcp?x=1") == .invalid)
        #expect(hostnameError("127.0.0.1") == .ipAddress)
        #expect(hostnameError("203.0.113.5") == .ipAddress)
        #expect(hostnameError("[::1]") == .ipAddress)
        #expect(hostnameError("localhost") == .localName)
        #expect(hostnameError("door.localhost") == .localName)
        #expect(hostnameError("mac.local") == .localName)
        #expect(hostnameError("mcp.home.arpa") == .localName)
        #expect(hostnameError("mcp.internal") == .localName)
        #expect(hostnameError("mcp") == .invalid)
        #expect(hostnameError("my_host.example.com") == .invalid)
        #expect(hostnameError("-mcp.example.com") == .invalid)
        #expect(hostnameError("mcp-.example.com") == .invalid)
        #expect(hostnameError("mcp..example.com") == .invalid)
        #expect(hostnameError("*.example.com") == .invalid)
        #expect(hostnameError("user@mcp.example.com") == .invalid)
        #expect(hostnameError("münchen.example") == .invalid)
        #expect(hostnameError("mcp.example.123") == .invalid)
        #expect(hostnameError(String(repeating: "a", count: 64) + ".example.com") == .invalid)
        let long = Array(repeating: String(repeating: "a", count: 60), count: 5).joined(separator: ".")
        #expect(hostnameError(long + ".com") == .invalid)
    }

    @Test func everyHostnameRefusalSaysWhatToType() {
        let errors: [Config.HostnameError] = [.empty, .notHTTPS, .port, .path, .ipAddress, .localName, .invalid]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(error.description == error.message)
        }
        #expect(Config.HostnameError.localName.message.contains("public hostname"))
    }

    // MARK: where the tools are

    @Test func toolsAreLookedForOnTheLoginPathThenTheUsualFolders() {
        let login = ["/Users/u/.local/bin", "relative/bin", "", "/opt/homebrew/bin", "/Users/u/.local/bin"]
        let cloudflared = Config.candidates(.cloudflared, loginPath: login, home: "/Users/u")
        #expect(cloudflared == ["/Users/u/.local/bin/cloudflared", "/opt/homebrew/bin/cloudflared",
                                "/usr/local/bin/cloudflared"])
        let tailscale = Config.candidates(.tailscale, loginPath: [], home: "/Users/u")
        #expect(tailscale == ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                              "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                              "/Users/u/Applications/Tailscale.app/Contents/MacOS/Tailscale"])
    }

    @Test func theFirstExecutableCandidateIsTheTool() {
        let found = Config.locate(.tailscale, loginPath: ["/Users/u/bin"], home: "/Users/u") { path in
            path.hasPrefix("/Applications/")
        }
        #expect(found == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        let missing = Config.locate(.cloudflared, loginPath: [], home: "/Users/u") { _ in false }
        #expect(missing == nil)
        #expect(Config.Tool.cloudflared.installHint == "brew install cloudflared")
        #expect(Config.Tool.tailscale.installHint.contains("tailscale.com"))
    }

    @Test func cloudflaredSystemServicesAreKnownPlaces() {
        #expect(Config.cloudflaredServices(home: "/Users/u") == [
            "/Library/LaunchDaemons/com.cloudflare.cloudflared.plist",
            "/Users/u/Library/LaunchAgents/com.cloudflare.cloudflared.plist",
        ])
        #expect(Config.cloudflaredServiceWarning.contains("while Remote access is off"))
        #expect(Config.funnelShareWarning.contains("while Remote access is off"))
    }

    // MARK: versions

    @Test func aCloudflaredVersionIsReadFromItsOutput() {
        let output = "cloudflared version 2026.10.0 (built 2026-10-02-1200 UTC)\n"
        #expect(Config.cloudflaredVersion(output) == Config.CloudflaredVersion(year: 2026, month: 10, patch: 0))
        #expect(Config.cloudflaredVersion(output)?.text == "2026.10.0")
        #expect(Config.cloudflaredVersion("cloudflared version DEV (built unknown)") == nil)
        #expect(Config.cloudflaredVersion("") == nil)
        #expect(Config.cloudflaredVersion("cloudflared version 2026.13.0") == nil)
    }

    @Test func aCloudflaredMoreThanAYearOldWarns() throws {
        let today = date(2026, 10, 7)
        let old = try #require(Config.cloudflaredVersion("cloudflared version 2025.9.0 (built 2025-09-18)"))
        let recent = try #require(Config.cloudflaredVersion("cloudflared version 2025.11.0"))
        let yearOld = try #require(Config.cloudflaredVersion("cloudflared version 2025.10.3"))
        #expect(old.isOutdated(now: today, calendar: utc))
        #expect(!recent.isOutdated(now: today, calendar: utc))
        #expect(!yearOld.isOutdated(now: today, calendar: utc))
        #expect(yearOld.isOutdated(now: date(2026, 11, 1), calendar: utc))
    }

    @Test func aTailscaleVersionIsItsFirstLine() {
        let output = "1.104.1\n  tailscale commit: 0123abcd\n  long version: 1.104.1-t0123abcd\n"
        #expect(Config.tailscaleVersion(output) == "1.104.1")
        #expect(Config.tailscaleVersion("  1.90.0-dev20260101  \n") == "1.90.0-dev20260101")
        #expect(Config.tailscaleVersion("The Tailscale CLI failed to start") == nil)
        #expect(Config.tailscaleVersion("") == nil)
        #expect(Config.tailscaleVersion("1." + String(repeating: "9", count: 60)) == nil)
    }

    // MARK: the Cloudflare token

    @Test func aValidTokenGivesItsTunnelID() throws {
        let pasted = token()
        let parsed = try #require(self.parsed(pasted))
        #expect(parsed.tunnelID == Self.tunnel.lowercased())
        #expect(parsed.value == pasted)
        #expect(self.parsed(token(extra: #""e":"https://edge.example""#))?.tunnelID == Self.tunnel.lowercased())
    }

    @Test func aURLSafeTokenWithoutPaddingIsTheSameToken() throws {
        var random = SplitMix(seed: 2026)
        var sawURLSafe = false
        var sawPadding = false
        for index in 0..<64 {
            let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &random) }
            // JSON is ASCII, so only "~", "?" or ">" put a "+" or "/" in the token; the endpoint carries them,
            // and its length varies so some tokens end in padding.
            let endpoint = "~~~???" + String(repeating: "x", count: index % 3)
            let standard = token(secret: Data(bytes).base64EncodedString(), extra: #""e":"\#(endpoint)""#)
            let safe = urlSafe(standard)
            sawURLSafe = sawURLSafe || safe.contains("-") || safe.contains("_")
            sawPadding = sawPadding || standard.hasSuffix("=")
            let parsed = try #require(self.parsed(safe))
            #expect(parsed.value == standard, "cloudflared reads standard base64 with padding")
            #expect(parsed.tunnelID == Self.tunnel.lowercased())
        }
        #expect(sawURLSafe)
        #expect(sawPadding)
    }

    @Test func aPastedInstallCommandGivesItsToken() {
        let pasted = token()
        #expect(parsed("sudo cloudflared service install \(pasted)\n")?.value == pasted)
        #expect(parsed("  '\(pasted)'  ")?.value == pasted)
        #expect(parsed("\"\(pasted)\"")?.value == pasted)
    }

    @Test func aTokenOfTheWrongShapeIsInvalid() {
        #expect(tokenError("") == .empty)
        #expect(tokenError("  \n") == .empty)
        #expect(tokenError("not-base64!") == .notBase64)
        #expect(tokenError("abcde") == .notBase64)
        #expect(tokenError(Data("plain words".utf8).base64EncodedString()) == .notToken)
        #expect(tokenError(Data("[1,2]".utf8).base64EncodedString()) == .notToken)
        #expect(tokenError(token(secret: nil)) == .notToken)
        #expect(tokenError(token(secret: "")) == .notToken)
        #expect(tokenError(token(secret: "not base64 at all")) == .notToken)
        #expect(tokenError(token(account: nil)) == .notToken)
        #expect(tokenError(token(account: "")) == .notToken)
        #expect(tokenError(token(tunnel: nil)) == .notToken)
        #expect(tokenError(token(tunnel: "not-a-uuid")) == .notToken)
        #expect(tokenError(token(extra: #""e":5"#)) == .notToken)
        #expect(tokenError(String(repeating: "A", count: Config.maximumTokenLength + 4)) == .tooLong)
    }

    @Test func noTokenErrorOrDescriptionHoldsTheToken() throws {
        let missingSecret = token(secret: nil)
        let error = try #require(tokenError(missingSecret))
        let shown = [error.message, "\(error)", String(reflecting: error), error.localizedDescription]
        for text in shown {
            #expect(!text.contains(missingSecret))
            #expect(!text.contains(Self.account))
            #expect(!text.lowercased().contains(Self.tunnel.lowercased()))
        }
        let pasted = token()
        let valid = try #require(parsed(pasted))
        var dumped = ""
        dump(valid, to: &dumped)
        let described = ["\(valid)", String(reflecting: valid), dumped]
        for text in described {
            #expect(!text.contains(pasted))
            #expect(!text.contains("c2VjcmV0"))
        }
        #expect("\(valid)".contains(Self.tunnel.lowercased()))
    }

    // MARK: the cloudflared child

    static let configFile = "/Users/u/Library/Application Support/Next Term/remote-access/cloudflared.yml"

    @Test func cloudflaredRunsWithThePlansArguments() {
        let arguments = Config.cloudflaredArguments(metricsPort: 45001, configFile: Self.configFile)
        let tunnel = ["tunnel", "--config", Self.configFile, "--no-autoupdate", "--metrics", "127.0.0.1:45001",
                      "--grace-period", "1s"]
        #expect(arguments == tunnel + ["run", "--token-file", "/dev/stdin"])
        #expect(Config.metricsURL(port: 45001, path: .ready).absoluteString == "http://127.0.0.1:45001/ready")
        #expect(Config.metricsURL(port: 45001, path: .config).absoluteString == "http://127.0.0.1:45001/config")
    }

    /// The token-file flag belongs to `run`, so it comes after it; the tunnel's own flags come before it.
    @Test func theTokenIsReadFromStandardInputByRun() throws {
        let arguments = Config.cloudflaredArguments(metricsPort: 45001, configFile: Self.configFile)
        let run = try #require(arguments.firstIndex(of: "run"))
        let file = try #require(arguments.firstIndex(of: "--token-file"))
        #expect(file > run)
        #expect(arguments[file + 1] == "/dev/stdin")
        let config = try #require(arguments.firstIndex(of: "--config"))
        #expect(config < run)
        #expect(arguments[config + 1] == Self.configFile)
    }

    /// R30 (2026-10-11): the token reaches cloudflared only through a pipe on its standard input. Neither its
    /// arguments nor its environment hold it, in any of its four base64 forms.
    @Test func theTokenGoesInNeitherTheArgumentsNorTheEnvironment() throws {
        var random = SplitMix(seed: 7)
        let base = ["HOME": "/Users/u", "PATH": "/usr/bin", "CLAUDECODE": "1", "TUNNEL_ORIGIN_CERT": "/tmp/cert.pem",
                    "TUNNEL_TOKEN": "inherited", "TUNNEL_TOKEN_FILE": "/tmp/token", "LANG": "en_US.UTF-8"]
        for _ in 0..<40 {
            let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &random) }
            let pasted = token(secret: Data(bytes).base64EncodedString())
            let parsed = try #require(self.parsed(pasted))
            let forms = Config.tokenForms(parsed)
            let arguments = Config.cloudflaredArguments(metricsPort: 45001, configFile: Self.configFile)
            let environment = Config.cloudflaredEnvironment(token: parsed, loginPath: ["/opt/homebrew/bin", "/usr/bin"],
                                                            base: base)
            for form in forms {
                #expect(!arguments.contains { $0.contains(form) })
                #expect(!environment.contains { $0.key.contains(form) || $0.value.contains(form) })
            }
            #expect(environment.keys.filter { $0.hasPrefix("TUNNEL_TOKEN") }.isEmpty)
            #expect(environment["TUNNEL_MANAGEMENT_DIAGNOSTICS"] == "false")
            #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
            #expect(environment["HOME"] == "/Users/u")
            #expect(environment["LANG"] == "en_US.UTF-8")
            #expect(environment["CLAUDECODE"] == nil, "the clean environment, as LoginShell runs tools")
            #expect(environment["TUNNEL_ORIGIN_CERT"] == nil, "no inherited cloudflared setting")
            #expect(Config.cloudflaredInput(parsed) == Data(parsed.value.utf8), "written once on standard input")
        }
    }

    @Test func noInheritedValueRepeatsTheToken() throws {
        let parsed = try #require(self.parsed(token()))
        let base = ["COPIED": "x" + parsed.value, "HOME": "/Users/u"]
        let environment = Config.cloudflaredEnvironment(token: parsed, loginPath: ["/usr/bin"], base: base)
        #expect(!environment.contains { $0.value.contains(parsed.value) })
        #expect(environment["COPIED"] == nil)
        #expect(environment["HOME"] == "/Users/u")
    }

    @Test func noInheritedValueRepeatsTheTokenInAnyForm() throws {
        for index in 0..<6 {
            // "~" and "?" put a "+" and a "/" in the token, so its URL-safe form differs from the standard one.
            let endpoint = "~~~???" + String(repeating: "x", count: index % 3)
            let standard = token(extra: #""e":"\#(endpoint)""#)
            let pasted = urlSafe(standard)
            #expect(pasted != standard)
            let parsed = try #require(self.parsed(pasted))
            let unpadded = standard.replacingOccurrences(of: "=", with: "")
            let base = ["CF_TUNNEL": pasted, "QUOTED": "'\(pasted)'", "PADLESS": "t=" + unpadded,
                        "URLSAFE_PADDED": urlSafe(standard) + "==", "HOME": "/Users/u"]
            let environment = Config.cloudflaredEnvironment(token: parsed, loginPath: ["/usr/bin"], base: base)
            let holding = environment.filter { $0.value.contains(unpadded) || $0.value.contains(pasted) }
            #expect(holding.isEmpty, "the pasted form is a copy too")
            #expect(environment["HOME"] == "/Users/u")
        }
    }

    /// The four forms a token can be found in: standard or URL-safe base64, with or without padding.
    @Test func aTokenHasFourForms() throws {
        let standard = token(extra: #""e":"~~~???xx""#)
        #expect(standard.hasSuffix("="))
        let parsed = try #require(self.parsed(standard))
        let unpadded = standard.replacingOccurrences(of: "=", with: "")
        let safe = urlSafe(standard)
        let safePadded = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(Set(Config.tokenForms(parsed)) == Set([standard, unpadded, safe, safePadded]))
        #expect(Config.tokenForms(parsed).first == standard)
    }

    // MARK: the cloudflared version and its settings file

    /// `--token-file` came in 2025.4.0: an older cloudflared, or one whose version can't be read, starts nothing.
    @Test func onlyACloudflaredFrom2025Point4ReadsTheTokenFromStandardInput() throws {
        func reads(_ text: String) -> Bool {
            Config.cloudflaredVersion("cloudflared version \(text)")?.readsTokenFile ?? false
        }
        #expect(reads("2025.4.0"))
        #expect(reads("2025.4.2"))
        #expect(reads("2025.10.0"))
        #expect(reads("2026.10.0"))
        #expect(!reads("2025.3.9"))
        #expect(!reads("2024.12.1"))
        #expect(Config.tokenFileVersion == Config.CloudflaredVersion(year: 2025, month: 4, patch: 0))
        #expect(Config.updateCloudflared == "Update cloudflared to 2025.4.0 or later.")
        let older = try #require(Config.cloudflaredVersion("cloudflared version 2025.3.9"))
        let newer = try #require(Config.cloudflaredVersion("cloudflared version 2025.4.0"))
        #expect(older < newer)
        #expect(Config.cloudflaredStartProblem(versionOutput: "cloudflared version 2025.3.9") == Config.updateCloudflared)
        #expect(Config.cloudflaredStartProblem(versionOutput: "cloudflared version DEV") == Config.updateCloudflared)
        #expect(Config.cloudflaredStartProblem(versionOutput: nil) == Config.updateCloudflared)
        #expect(Config.cloudflaredStartProblem(versionOutput: "cloudflared version 2026.10.0 (built x)") == nil)
    }

    /// cloudflared's own settings file: without it cloudflared reads ~/.cloudflared/config.yml, where a leftover
    /// debug level and log file would write every request's headers to disk.
    @Test func cloudflaredGetsItsOwnSettingsFileOwnerOnly() throws {
        #expect(Config.cloudflaredSettings == "no-autoupdate: true\nloglevel: info\n")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ra-cf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("remote-access")
        let url = try Config.writeCloudflaredSettings(in: folder)
        #expect(url == folder.appendingPathComponent("cloudflared.yml"))
        #expect(try String(contentsOf: url, encoding: .utf8) == Config.cloudflaredSettings)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let made = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((made[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try Data("loglevel: debug\nlogfile: /tmp/x.log\n".utf8).write(to: url)
        _ = try Config.writeCloudflaredSettings(in: folder)
        #expect(try String(contentsOf: url, encoding: .utf8) == Config.cloudflaredSettings, "written fresh each start")
    }

    @Test func aMissingToolSaysHowToGetItAndAnOldOneHowToUpdate() throws {
        #expect(Config.Tool.cloudflared.missing == "cloudflared is not installed. Install it in Terminal with brew "
            + "install cloudflared.")
        #expect(Config.Tool.tailscale.missing.hasPrefix("Tailscale is not installed."))
        #expect(Config.Tool.tailscale.missing.contains(Config.Tool.tailscale.installHint))
        let old = try #require(Config.cloudflaredVersion("cloudflared version 2025.4.1"))
        #expect(Config.outdatedWarning(old) == "cloudflared 2025.4.1 is more than a year old. Update it with brew "
            + "upgrade cloudflared.")
    }

    @Test func aTunnelWithNoRoutesAfterTwoMinutesSaysWhereToMakeOne() {
        #expect(Config.routingWaitLimit == 120)
        #expect(Config.noRoutes.hasPrefix("This tunnel gets no routes from Cloudflare."))
        #expect(Config.noRoutes.contains("Networking › Tunnels"))
    }

    // MARK: /ready

    @Test func readyNeedsA200AndAConnection() {
        let up = json(["status": 200, "readyConnections": 4, "connectorId": "1d2c3b4a"] as [String: Any])
        let none = json(["status": 503, "readyConnections": 0, "connectorId": "1d2c3b4a"] as [String: Any])
        #expect(Config.isReady(status: 200, body: up))
        #expect(!Config.isReady(status: 503, body: none))
        #expect(!Config.isReady(status: 200, body: none))
        #expect(!Config.isReady(status: 503, body: up))
        #expect(!Config.isReady(status: 200, body: Data("ok".utf8)))
        #expect(!Config.isReady(status: 200, body: json(["readyConnections": "4"])))
    }

    // MARK: /config

    @Test func oneRuleToTheDoorAndTheCatchAllIsOK() {
        #expect(route([doorRule, catchAll]) == .ok)
        #expect(route([rule("MCP.Example.com", "http://127.0.0.1:\(port)/"), catchAll]) == .ok)
        #expect(route([rule(host, "http://127.0.0.1:\(port)"), rule("*", "http_status:404")]) == .ok)
    }

    @Test func aBareConfigWithoutTheResolvedDefaultsIsOK() {
        let rules: [[String: Any]] = [["hostname": host, "service": "http://127.0.0.1:\(port)"],
                                      ["service": "http_status:404"]]
        let data = json(["config": ["ingress": rules]])
        #expect(Config.cloudflareRoute(data, host: host, port: port) == .ok)
    }

    @Test func knownTimeoutsPassAndUnknownSettingsWarn() {
        let slow = rule(host, "http://127.0.0.1:\(port)", ["connectTimeout": 60, "keepAliveTimeout": 120])
        #expect(route([slow, catchAll]) == .ok)
        let newKnob = rule(host, "http://127.0.0.1:\(port)", ["someNewKnob": 5])
        #expect(route([newKnob, catchAll]) == .warn([.unknownSettings(["someNewKnob"])]))
        let quietKnob = rule(host, "http://127.0.0.1:\(port)", ["someNewKnob": false])
        #expect(route([quietKnob, catchAll]) == .ok, "a field at its empty default is unset")
        let h2 = rule(host, "http://127.0.0.1:\(port)", ["http2Origin": true])
        #expect(route([h2, catchAll]) == .warn([.unknownSettings(["http2Origin"])]))
        var defaults = resolvedDefaults
        defaults["access"] = ["required": true, "teamName": "team", "audTag": ["aud"]] as [String: Any]
        #expect(route([doorRule, catchAll], defaults: defaults) == .warn([.unknownSettings(["access"])]))
    }

    @Test func aPathOnTheDoorsRuleWarns() {
        var narrowed = doorRule
        narrowed["path"] = "^/mcp"
        #expect(route([narrowed, catchAll]) == .warn([.path]))
    }

    @Test func aRouteToAnotherPortStops() {
        #expect(route([rule(host, "http://127.0.0.1:22"), catchAll]) == .stop(.wrongService))
        #expect(route([rule(host, "https://127.0.0.1:\(port)"), catchAll]) == .stop(.wrongService))
        #expect(route([rule(host, "http://192.168.1.5:\(port)"), catchAll]) == .stop(.wrongService))
        #expect(route([rule(host, "http://127.0.0.1:\(port)/mcp"), catchAll]) == .stop(.wrongService))
        #expect(route([rule(host, "http://[::1]:\(port)"), catchAll]) == .stop(.wrongService))
    }

    @Test func aLocalhostRouteStopsAndSaysToUse127() {
        #expect(route([rule(host, "http://localhost:\(port)"), catchAll]) == .stop(.localhost))
        #expect(route([rule(host, "http://LOCALHOST:\(port)/"), catchAll]) == .stop(.localhost))
        let message = Config.RouteStop.localhost.message(host: host, port: port)
        #expect(message.contains("http://127.0.0.1:41234"))
        #expect(message.contains("::1"))
    }

    @Test func otherServiceTypesStop() {
        let services = ["bastion", "unix:/tmp/door.sock", "unix+tls:/tmp/door.sock", "tcp://127.0.0.1:\(port)",
                        "ssh://127.0.0.1:22", "rdp://127.0.0.1:3389", "smb://127.0.0.1:445", "socks-proxy",
                        "hello_world", "http_status:404"]
        for service in services {
            #expect(route([rule(host, service), catchAll]) == .stop(.otherService), "\(service)")
        }
        let bastion = rule(host, "http://127.0.0.1:\(port)", ["bastionMode": true])
        #expect(route([bastion, catchAll]) == .stop(.otherService))
    }

    @Test func bastionModeInTheDefaultsStops() {
        let rules: [[String: Any]] = [["hostname": host, "service": "http://127.0.0.1:\(port)"],
                                      ["service": "http_status:404"]]
        let bare = json(["config": ["ingress": rules, "originRequest": ["bastionMode": true]]])
        #expect(Config.cloudflareRoute(bare, host: host, port: port) == .stop(.otherService))
        var defaults = resolvedDefaults
        defaults["bastionMode"] = true
        #expect(route([doorRule, catchAll], defaults: defaults) == .stop(.otherService))
    }

    @Test func aHostHeaderOverrideStops() {
        let override = rule(host, "http://127.0.0.1:\(port)", ["httpHostHeader": "mcp.example.com"])
        #expect(route([override, catchAll]) == .stop(.hostHeader))
        var defaults = resolvedDefaults
        defaults["httpHostHeader"] = "evil.example.net"
        #expect(route([doorRule, catchAll], defaults: defaults) == .stop(.hostHeader))
        let onCatchAll = rule(nil, "http_status:404", ["httpHostHeader": "x"])
        #expect(route([doorRule, onCatchAll]) == .stop(.hostHeader))
    }

    @Test func anotherRuleStops() {
        let other = rule("evil.example.net", "http://127.0.0.1:22")
        #expect(route([doorRule, other, catchAll]) == .stop(.otherRule))
        #expect(route([doorRule, rule(host, "http://127.0.0.1:\(port)"), catchAll]) == .stop(.otherRule))
        #expect(route([doorRule, rule("*.example.com", "http://127.0.0.1:\(port)"), catchAll]) == .stop(.otherRule))
        let message = Config.RouteStop.otherRule.message(host: host, port: port)
        #expect(!message.contains("evil.example.net"), "no value from the network in a message")
    }

    @Test func noRuleForTheHostStops() {
        #expect(route([catchAll]) == .stop(.noRule))
        #expect(route([rule("other.example.com", "http://127.0.0.1:\(port)"), catchAll]) == .stop(.noRule))
        #expect(route([]) == .stop(.noRule))
    }

    @Test func aMissingCatchAllStops() {
        #expect(route([doorRule]) == .stop(.noCatchAll))
        #expect(route([doorRule, rule(nil, "http_status:503")]) == .stop(.noCatchAll))
        #expect(route([doorRule, rule(nil, "http://127.0.0.1:\(port)")]) == .stop(.noCatchAll))
        var pathed = catchAll
        pathed["path"] = "^/x"
        #expect(route([doorRule, pathed]) == .stop(.noCatchAll))
    }

    @Test func cloudflaredsOwnRuleBeforeTheTunnelsRoutingArrivesIsWaiting() {
        let inner: [String: Any] = ["ingress": [noRoutingYet], "originRequest": [String: Any]()]
        let cloudflaredDefault = json(["version": -1, "config": inner] as [String: Any])
        #expect(Config.cloudflareRoute(cloudflaredDefault, host: host, port: port) == .waiting)
        #expect(route([noRoutingYet], version: -1) == .waiting)
    }

    @Test func rulesFromALocalConfigFileBeforeTheTunnelsRoutingArrivesAreChecked() {
        #expect(route([rule(host, "ssh://127.0.0.1:22"), catchAll], version: -1) == .stop(.otherService))
        #expect(route([rule("evil.example.net", "http://127.0.0.1:22"), noRoutingYet], version: -1)
                == .stop(.noCatchAll))
        #expect(route([doorRule, catchAll], version: -1) == .ok)
    }

    @Test func onlyA503FromTheTunnelsOwnRoutingStops() {
        #expect(route([noRoutingYet], version: 0) == .stop(.noCatchAll), "Cloudflare sent it, so it is the routing")
        let bare = json(["config": ["ingress": [noRoutingYet]]])
        #expect(Config.cloudflareRoute(bare, host: host, port: port) == .stop(.noCatchAll))
    }

    @Test func anUnreadableConfigStops() {
        let host = self.host
        #expect(Config.cloudflareRoute(Data("not json".utf8), host: host, port: port) == .stop(.unreadable))
        #expect(Config.cloudflareRoute(json([:] as [String: Any]), host: host, port: port) == .stop(.unreadable))
        let notRules = json(["config": ["ingress": "none"]])
        #expect(Config.cloudflareRoute(notRules, host: host, port: port) == .stop(.unreadable))
        let notObjects = json(["config": ["ingress": [1, 2]]])
        #expect(Config.cloudflareRoute(notObjects, host: host, port: port) == .stop(.unreadable))
        let noService = json(["config": ["ingress": [["hostname": host]]]])
        #expect(Config.cloudflareRoute(noService, host: host, port: port) == .stop(.unreadable))
    }

    @Test func everyStopNamesTheDoorAndNoNetworkValue() {
        let stops: [Config.RouteStop] = [.unreadable, .noRule, .localhost, .wrongService, .otherRule, .otherService,
                                         .noCatchAll, .hostHeader, .funnelOff]
        for stop in stops {
            let message = stop.message(host: host, port: port)
            #expect(!message.isEmpty)
            #expect(!message.contains(":22"))
        }
        #expect(Config.RouteStop.wrongService.message(host: host, port: port).contains("http://127.0.0.1:41234"))
        #expect(Config.RouteWarning.unknownSettings(["a", "b"]).message.contains("a, b"))
    }

    @Test func aWarningNamesOnlyPlainSettingNames() {
        let odd = rule(host, "http://127.0.0.1:\(port)", ["<script>": 1, "fine2": 1])
        #expect(route([odd, catchAll]) == .warn([.unknownSettings(["fine2"])]))
    }

    @Test func theHostnameToConfirmIsTheOnlyRules() {
        #expect(Config.cloudflareHostname(config([rule("MCP.Example.com.", "http://127.0.0.1:1"), catchAll]))
                == "mcp.example.com")
        #expect(Config.cloudflareHostname(config([doorRule, rule("b.example.com", "http://127.0.0.1:1"), catchAll]))
                == nil)
        #expect(Config.cloudflareHostname(config([rule("localhost", "http://127.0.0.1:1"), catchAll])) == nil)
        #expect(Config.cloudflareHostname(config([rule("*.example.com", "http://127.0.0.1:1"), catchAll])) == nil)
        #expect(Config.cloudflareHostname(config([catchAll])) == nil)
        #expect(Config.cloudflareHostname(Data("x".utf8)) == nil)
    }

    // MARK: Tailscale and Funnel

    @Test func funnelRunsInTheForegroundToTheDoor() {
        let arguments = Config.funnelArguments(port: port)
        #expect(arguments == ["funnel", "http://127.0.0.1:41234"])
        #expect(!arguments.contains { $0.hasPrefix("--bg") })
        #expect(Config.tailscaleStatusArguments == ["status", "--json"])
        #expect(Config.funnelStatusArguments == ["funnel", "status", "--json"])
    }

    @Test func aRunningTailscaleGivesTheMacsName() throws {
        #expect(try tailscale(status()).get() == tailnetHost)
        #expect(try tailscale(status(legacy: true)).get() == tailnetHost)
        let range = status(caps: ["https", "funnel", "https://tailscale.com/cap/funnel-ports?ports=80,400-500"])
        #expect(try tailscale(range).get() == tailnetHost)
        let encoded = status(caps: ["https", "funnel", "https://tailscale.com/cap/funnel-ports?ports=8443%2C443"])
        #expect(try tailscale(encoded).get() == tailnetHost)
    }

    @Test func aTailscaleThatCannotFunnelSaysWhy() {
        func problem(_ data: Data) -> Config.TailscaleProblem? {
            if case .failure(let problem) = tailscale(data) { return problem }
            return nil
        }
        #expect(problem(status(state: "NeedsLogin")) == .notLoggedIn)
        #expect(problem(status(state: "NeedsLogin"))?.message == "Tailscale is not logged in.")
        #expect(problem(status(state: "NeedsMachineAuth")) == .needsApproval)
        #expect(problem(status(state: "Stopped")) == .stopped)
        #expect(problem(status(state: "Starting")) == .notRunning)
        #expect(problem(status(state: "NoState")) == .notRunning)
        #expect(problem(status(name: "")) == .noName)
        #expect(problem(status(name: "localhost.")) == .noName)
        #expect(problem(status(caps: ["funnel", "https://tailscale.com/cap/funnel-ports?ports=443"])) == .noHTTPS)
        #expect(problem(status(caps: ["https", "https://tailscale.com/cap/funnel-ports?ports=443"])) == .funnelOff)
        #expect(problem(status(caps: ["https", "funnel"])) == .port443Off)
        #expect(problem(status(caps: ["https", "funnel", "https://tailscale.com/cap/funnel-ports?ports=8443"]))
                == .port443Off)
        #expect(problem(Data("{".utf8)) == .unreadable)
        let problems: [Config.TailscaleProblem] = [.unreadable, .notLoggedIn, .needsApproval, .stopped, .notRunning,
                                                   .noName, .noHTTPS, .funnelOff, .port443Off]
        for problem in problems {
            #expect(!problem.message.isEmpty)
        }
    }

    @Test func aFunnelShareToTheDoorIsOK() {
        #expect(funnel(foreground(share(doorHandler))) == .ok)
        let upper = share(["/": ["Proxy": "http://127.0.0.1:\(port)/"]], host: "MAC.tailnet-0000.ts.net")
        #expect(funnel(foreground(upper)) == .ok)
    }

    @Test func noShareYetIsWaiting() {
        #expect(funnel(json([:] as [String: Any])) == .waiting)
        #expect(funnel(foreground(share(doorHandler, host: "other.tailnet-0000.ts.net"))) == .waiting)
    }

    @Test func aFunnelShareToAnotherPortStops() {
        let other = share(["/": ["Proxy": "http://127.0.0.1:22"]])
        #expect(funnel(foreground(other)) == .stop(.wrongService))
        let files = share(["/": ["Path": "/Users/u"]])
        #expect(funnel(foreground(files)) == .stop(.wrongService))
        let text = share(["/": ["Text": "hello"]])
        #expect(funnel(foreground(text)) == .stop(.wrongService))
        let mounted = share(["/door": ["Proxy": "http://127.0.0.1:\(port)"]])
        #expect(funnel(foreground(mounted)) == .stop(.wrongService))
        let local = share(["/": ["Proxy": "http://localhost:\(port)"]])
        #expect(funnel(foreground(local)) == .stop(.localhost))
    }

    @Test func aDoorHandlerThatAlsoServesSomethingElseStops() {
        // Tailscale serves Text, then Redirect, then Path, and only then Proxy, so any of them wins over the door.
        let others: [String: Any] = ["Path": "/Users/u", "Text": "x",
                                     "Redirect": "308:https://evil.example${REQUEST_URI}", "SomeNewField": true]
        for (field, value) in others {
            let handler: [String: Any] = ["Proxy": "http://127.0.0.1:\(port)", field: value]
            #expect(funnel(foreground(share(["/": handler]))) == .stop(.wrongService), "\(field)")
        }
        let caps: [String: Any] = ["Proxy": "http://127.0.0.1:\(port)", "AcceptAppCaps": ["example.com/cap/mon"]]
        #expect(funnel(foreground(share(["/": caps]))) == .ok)
        let empty: [String: Any] = ["Proxy": "http://127.0.0.1:\(port)", "Path": "", "Text": ""]
        #expect(funnel(foreground(share(["/": empty]))) == .ok, "an empty field is unset, as Tailscale omits it")
    }

    @Test func aSecondHandlerOrARawForwardStops() {
        var handlers = doorHandler
        handlers["/files"] = ["Path": "/Users/u"]
        #expect(funnel(foreground(share(handlers))) == .stop(.otherRule))
        let forward = share(doorHandler, tcp: ["TCPForward": "127.0.0.1:22"])
        #expect(funnel(foreground(forward)) == .stop(.otherService))
        let both = json(["Foreground": ["a": share(doorHandler), "b": share(["/": ["Proxy": "http://127.0.0.1:22"]])]])
        #expect(funnel(both) == .stop(.otherRule))
    }

    @Test func aShareOnlyTheTailnetSeesStops() {
        #expect(funnel(foreground(share(doorHandler, funnel: false))) == .stop(.funnelOff))
    }

    @Test func otherSharesWarn() {
        var background = share(["/": ["Proxy": "http://127.0.0.1:3000"]], host: nil)
        background["Web"] = ["\(tailnetHost):8443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:3000"]]]]
        background["AllowFunnel"] = ["\(tailnetHost):8443": true]
        background["TCP"] = ["8443": ["HTTPS": true]]
        var both = background
        both["Foreground"] = ["a1b2c3": share(doorHandler)]
        #expect(funnel(json(both)) == .warn([.otherShare]))
        let backgroundDoor = json(share(doorHandler))
        #expect(funnel(backgroundDoor) == .warn([.backgroundShare]))
    }

    @Test func anExistingShareIsFoundBeforeStarting() {
        #expect(!Config.funnelShareExists(json([:] as [String: Any])))
        #expect(!Config.funnelShareExists(Data("x".utf8)))
        #expect(Config.funnelShareExists(foreground(share(doorHandler))))
        #expect(Config.funnelShareExists(json(share(doorHandler))))
        #expect(!Config.funnelShareExists(json(share(doorHandler, funnel: false))), "a tailnet-only share")
        #expect(!Config.funnelShareExists(json(["AllowFunnel": ["\(tailnetHost):443": false]])))
    }

    // MARK: restarts

    @Test func restartsWaitOneSecondDoublingToSixty() {
        let waits = (1...9).map(Config.restartWait(attempt:))
        #expect(waits == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(Config.restartWait(attempt: 0) == 1)
        #expect(Config.restartWait(attempt: -3) == 1)
        #expect(Config.restartWait(attempt: Int.max) == 60)
        #expect(Config.checkInterval == 10)
    }

    @Test func theMacIsToldAfterTenMinutesDown() {
        let down = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!Config.notifies(downSince: down, now: down.addingTimeInterval(599)))
        #expect(Config.notifies(downSince: down, now: down.addingTimeInterval(600)))
        #expect(!Config.notifies(downSince: down, now: down.addingTimeInterval(-5)))
    }
}
