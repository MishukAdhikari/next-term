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
        // This Mac only: every peer of a large tailnet would pass the 4 MB a read keeps, every 10 seconds.
        #expect(Config.tailscaleStatusArguments == ["status", "--json", "--peers=false"])
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

    /// Funnel or HTTPS not enabled for the tailnet: `tailscale funnel` prints its own message, with the link that
    /// enables it, and waits there. So the start goes on, with a warning that points at that message. Anything else
    /// Tailscale says stops the start with its reason.
    @Test func funnelNotEnabledStartsSoTailscaleShowsItsOwnMessage() {
        #expect(Config.funnelStart(.success(tailnetHost)) == .go)
        for problem: Config.TailscaleProblem in [.funnelOff, .noHTTPS] {
            guard case .waitForEnabling(let warning) = Config.funnelStart(.failure(problem)) else {
                Issue.record("\(problem) starts and waits")
                continue
            }
            #expect(warning.hasPrefix(problem.message))
            #expect(warning.contains("link"))
        }
        let refused: [Config.TailscaleProblem] = [.unreadable, .notLoggedIn, .needsApproval, .stopped, .notRunning,
                                                  .noName, .port443Off]
        for problem in refused {
            #expect(Config.funnelStart(.failure(problem)) == .refuse(problem.message))
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

    // MARK: your own server over ssh (U15)

    let web1 = RemoteHost(id: "a1b2c3d4e5f6", name: "web-1", destination: "deploy@203.0.113.5", port: 2222)
    let serverPort = 24567

    func server(_ host: RemoteHost? = nil, port: Int? = nil) -> Config.OwnServer {
        Config.OwnServer(host: host ?? web1, port: port ?? serverPort)
    }

    /// The value after each `-o`.
    func options(_ arguments: [String]) -> [String] {
        zip(arguments, arguments.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
    }

    @Test func sshForwardsOnlyTheDoorFromTheServersLoopback() {
        let arguments = Config.sshArguments(server(), doorPort: port, configFile: nil)
        let forwards = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-R" }.map(\.1)
        #expect(forwards == ["127.0.0.1:24567:127.0.0.1:41234"])
        #expect(!arguments.contains("-L") && !arguments.contains("-D") && !arguments.contains("-W"))
        #expect(arguments.first == "-N", "no session: no command, no shell, no agent or X11 forwarding")
    }

    @Test func sshNeverPromptsNeverTakesAHostKeyAndEndsWhenTheForwardFails() {
        let set = options(Config.sshArguments(server(), doorPort: port, configFile: nil))
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ExitOnForwardFailure=yes",
                       "ServerAliveInterval=15", "ServerAliveCountMax=3", "UpdateHostKeys=no"] {
            #expect(set.contains(option), "\(option)")
        }
        // Its own connection: never a master for other sessions, never one of theirs.
        #expect(set.contains("ControlMaster=no"))
        #expect(set.contains("ControlPath=none"))
        // The forward's success shows only in ssh's debug lines.
        #expect(set.contains("LogLevel=DEBUG1"))
        // A config's "yes" would clear the door's forward too; "no" here wins over it.
        #expect(set.contains("ClearAllForwardings=no"))
        #expect(!set.contains("ClearAllForwardings=yes"))
    }

    /// What the user's ssh config may set for every ssh they run, and the child must not do: go to the background
    /// out of the process group Turn Off and quit end, run a command there or here, or forward anything else.
    @Test func sshKeepsTheUsersConfigFromChangingWhatTheChildDoes() {
        let set = options(Config.sshArguments(server(), doorPort: port, configFile: "/tmp/nt-ssh/ssh_config"))
        for option in ["ForkAfterAuthentication=no", "RemoteCommand=none", "PermitLocalCommand=no", "Tunnel=no",
                       "ForwardAgent=no", "ForwardX11=no"] {
            #expect(set.contains(option), "\(option)")
        }
    }

    @Test func sshChecksItsSettingsWithTheSameArguments() {
        let arguments = Config.sshArguments(server(), doorPort: port, configFile: "/tmp/nt-ssh/ssh_config")
        let check = Config.sshCheckArguments(server(), doorPort: port, configFile: "/tmp/nt-ssh/ssh_config")
        // ssh -G prints the settings it would connect with, and connects to nothing.
        #expect(check == ["-G"] + arguments)
    }

    /// `ssh -G` as OpenSSH 10.2 prints it, with the door's forward and `extra` lines.
    func printedSettings(_ extra: [String] = [], door: Bool = true) -> String {
        var lines = ["host web-1", "hostname 203.0.113.5", "port 2222", "clearallforwardings no",
                     "exitonforwardfailure yes", "gatewayports no", "sessiontype none", "forkafterauthentication no"]
        if door { lines.append("remoteforward [127.0.0.1]:24567 [127.0.0.1]:41234") }
        return (lines + extra).joined(separator: "\n") + "\n"
    }

    @Test func sshsSettingsWithOnlyTheDoorsForwardAreFine() {
        #expect(Config.sshSettingsProblem(printedSettings(), server: server(), doorPort: port) == nil)
        let plain = printedSettings().replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        #expect(Config.sshSettingsProblem(plain, server: server(), doorPort: port) == nil, "older ssh, no brackets")
        let windows = printedSettings().replacingOccurrences(of: "\n", with: "\r\n")
        #expect(Config.sshSettingsProblem(windows, server: server(), doorPort: port) == nil)
    }

    /// A forward the user's config sets for the server would ride along on the child: refused before it starts,
    /// naming the config and the forwards.
    @Test func forwardsFromTheUsersSSHConfigAreRefused() throws {
        let extra = ["localforward 5432 [127.0.0.1]:5432", "dynamicforward 1080",
                     "remoteforward [127.0.0.1]:2222 [127.0.0.1]:22"]
        let problem = try #require(Config.sshSettingsProblem(printedSettings(extra), server: server(), doorPort: port))
        #expect(problem.contains("web-1"))
        #expect(problem.contains("~/.ssh/config"))
        #expect(problem.contains("LocalForward 5432 127.0.0.1:5432"))
        #expect(problem.contains("DynamicForward 1080"))
        #expect(problem.contains("RemoteForward 127.0.0.1:2222 127.0.0.1:22"))
        #expect(!problem.contains("24567 127.0.0.1:41234"), "the door's own forward is not one of them")
        for one in extra {
            let printed = printedSettings([one])
            #expect(Config.sshSettingsProblem(printed, server: server(), doorPort: port) != nil, "\(one)")
        }
        // The same server port to another port on this Mac is not the door's.
        let elsewhere = ["remoteforward [127.0.0.1]:24567 [127.0.0.1]:22"]
        #expect(Config.sshSettingsProblem(printedSettings(elsewhere), server: server(), doorPort: port) != nil)
        let socket = ["remoteforward /tmp/agent.sock [127.0.0.1]:22"]
        #expect(Config.sshSettingsProblem(printedSettings(socket), server: server(), doorPort: port) != nil)
    }

    @Test func sshsSettingsThatDropTheDoorsForwardOrForkAreRefused() throws {
        let cleared = try #require(Config.sshSettingsProblem(printedSettings(door: false), server: server(),
                                                             doorPort: port))
        #expect(cleared.contains("web-1"))
        let forks = printedSettings().replacingOccurrences(of: "forkafterauthentication no",
                                                           with: "forkafterauthentication yes")
        #expect(Config.sshSettingsProblem(forks, server: server(), doorPort: port) != nil)
        let unread = try #require(Config.sshSettingsProblem(nil, server: server(), doorPort: port))
        #expect(unread.contains("web-1") && unread.contains("ssh -G"))
        #expect(Config.sshSettingsProblem("", server: server(), doorPort: port) == unread)
    }

    @Test func sshEndsWithTheSavedPortAndDestination() {
        let arguments = Config.sshArguments(server(), doorPort: port, configFile: "/tmp/nt-ssh/ssh_config")
        #expect(Array(arguments.suffix(4)) == ["-p", "2222", "--", "deploy@203.0.113.5"])
        #expect(Array(arguments.prefix(2)) == ["-F", "/tmp/nt-ssh/ssh_config"])
        let plain = RemoteHost(name: "box", destination: "box")
        let noPort = Config.sshArguments(server(plain), doorPort: port, configFile: nil)
        #expect(Array(noPort.suffix(2)) == ["--", "box"])
        #expect(!noPort.contains("-p"))
    }

    @Test func aDestinationWithSpacesOrQuotesStaysOneArgument() {
        for destination in ["we ird host", "o'brien@host", "\"quoted\" host", "-oProxyCommand=evil"] {
            let odd = RemoteHost(name: "odd", destination: destination)
            let arguments = Config.sshArguments(server(odd), doorPort: port, configFile: nil)
            #expect(arguments.last == destination)
            #expect(arguments.dropLast().last == "--", "never read as an option")
            #expect(arguments.filter { $0.contains(destination) }.count == 1)
        }
    }

    @Test func sshNeverCarriesTheMCPSocketOrAnIDEPort() {
        let arguments = Config.sshArguments(server(), doorPort: port, configFile: nil)
        let text = arguments.joined(separator: " ")
        #expect(!text.contains("mcp.sock"))
        #expect(!text.contains(MCPServer.socketVariable))
        #expect(!text.contains(MCPServer.socketPath(home: "/Users/someone")))
        // Only the door's port, the server port and ssh's own port: nothing else on this Mac is reachable.
        let ports = arguments.flatMap { $0.split(separator: ":") }.compactMap { Int($0) }
        #expect(Set(ports) == [serverPort, port, 2222])
    }

    /// Below Linux's ephemeral ports (32768 to 60999), so a reconnect's listen never meets an outgoing connection's
    /// port.
    @Test func theServerPortIsPickedOnceBelowLinuxsEphemeralPorts() {
        #expect(Config.serverPorts == 20000...32767)
        #expect(Config.serverPort(saved: 24567, random: { _ in 0 }) == 24567, "the saved one, never another")
        #expect(Config.serverPort(saved: nil, random: { _ in 0 }) == 20000)
        #expect(Config.serverPort(saved: nil, random: { $0 - 1 }) == 32767)
        #expect(Config.serverPort(saved: nil, random: { _ in 12345 }) == 32345)
        // Out of the range, or nonsense from the random source, is never used.
        #expect(Config.serverPort(saved: 22, random: { _ in 7 }) == 20007)
        #expect(Config.serverPort(saved: 34567, random: { _ in 7 }) == 20007, "an ephemeral port")
        #expect(Config.serverPort(saved: 70000, random: { _ in 7 }) == 20007)
        #expect(Config.serverPort(saved: nil, random: { _ in -1 }) == 32767)
        #expect(Config.serverPort(saved: nil, random: { _ in 12768 }) == 20000)
        for _ in 0..<200 { #expect(Config.serverPorts.contains(Config.serverPort(saved: nil))) }
    }

    /// "New Server Port": another one from the range, never the one it replaces.
    @Test func aNewServerPortIsNeverTheOldOne() {
        #expect(Config.newServerPort(replacing: 20000, random: { _ in 0 }) == 20001)
        #expect(Config.newServerPort(replacing: 24567, random: { _ in 0 }) == 20000)
        #expect(Config.newServerPort(replacing: 32767, random: { $0 - 1 }) == 32766)
        #expect(Config.newServerPort(replacing: 20005, random: { _ in 5 }) == 20006)
        #expect(Config.newServerPort(replacing: 40000, random: { _ in 5 }) == 20005, "one out of range is no rule")
        for old in [20000, 26000, 32767] {
            for _ in 0..<100 {
                let new = Config.newServerPort(replacing: old)
                #expect(new != old && Config.serverPorts.contains(new))
            }
        }
    }

    @Test func sshsLinesSayWhereTheForwardStands() {
        func line(_ text: String) -> Config.SSHLine? { Config.sshLine(text, serverPort: serverPort) }
        #expect(line("Authenticated to 203.0.113.5 ([203.0.113.5]:2222) using \"publickey\".") == .loggedIn)
        let success = "debug1: remote forward success for: listen 127.0.0.1:24567, connect 127.0.0.1:41234"
        #expect(line(success) == .forwardHolds)
        #expect(line("debug1: remote forward success for: listen 127.0.0.1:245670, connect 127.0.0.1:1") == nil)
        #expect(line("debug1: remote forward success for: listen 127.0.0.1:2456, connect 127.0.0.1:1") == nil)
        #expect(line("Error: remote port forwarding failed for listen port 24567") == .serverPortBusy)
        #expect(line("Error: remote port forwarding failed for listen port 245678") == nil)
        #expect(line("debug1: remote forward failure for: listen 127.0.0.1:24567, connect 127.0.0.1:41234")
                == .serverPortBusy)
        #expect(line("Host key verification failed.") == .hostKey)
        #expect(line("No ED25519 host key is known for [203.0.113.5]:2222 and you have requested strict checking.")
                == .hostKey)
        #expect(line("@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @") == .hostKey)
        #expect(line("deploy@203.0.113.5: Permission denied (publickey,password).") == .loginNeeded)
        #expect(line("Received disconnect from 203.0.113.5 port 2222:2: Too many authentication failures")
                == .loginNeeded)
        // Debug lines say these words about other things: only ssh's own messages count.
        #expect(line("debug1: Permission denied (publickey) for a file") == nil)
        #expect(line("debug1: Host key verification failed.") == nil)
        #expect(line("debug1: Connection established.") == nil)
        #expect(line("") == nil)
    }

    @Test func settingsKeepsSSHsOwnMessagesNotItsDebugLines() {
        #expect(Config.keepsSSHLine("deploy@203.0.113.5: Permission denied (publickey)."))
        #expect(Config.keepsSSHLine("Authenticated to 203.0.113.5 ([203.0.113.5]:22) using \"publickey\"."))
        #expect(Config.keepsSSHLine("debug1: remote forward success for: listen 127.0.0.1:24567, connect 127.0.0.1:1"))
        #expect(!Config.keepsSSHLine("debug1: channel 1: new forwarded-tcpip [127.0.0.1]"))
        #expect(!Config.keepsSSHLine("debug2: channel 1: rcvd adjust 65536"))
        #expect(!Config.keepsSSHLine("debug3: send packet: type 98"))
        #expect(!Config.keepsSSHLine(""))
    }

    @Test func sshsOutputSplitsIntoLinesAsItComes() {
        var lines = Config.SSHLines()
        #expect(lines.read(Data("Authenticated to h".utf8)) == [])
        #expect(lines.read(Data("ost.\r\ndebug1: one\nde".utf8)) == ["Authenticated to host.", "debug1: one"])
        #expect(lines.finish() == ["de"])
        #expect(lines.finish() == [])
        var long = Config.SSHLines()
        let cut = long.read(Data(String(repeating: "x", count: 5000).utf8))
        #expect(cut.count == 1 && cut[0].count == Config.SSHLines.longest)
        #expect(long.read(Data("yyy\nnext\n".utf8)) == ["next"], "the rest of a cut line is dropped")
    }

    @Test func theSSHMessagesNameTheServerAndSayWhatToDo() {
        #expect(Config.sshHostKeyProblem("web-1").contains("web-1"))
        #expect(Config.sshHostKeyProblem("web-1").contains("remote tab"))
        #expect(Config.sshLoginProblem("web-1").contains("web-1"))
        #expect(Config.sshLoginNeeded("web-1").contains("web-1"))
        let busy = Config.RouteWarning.serverPortBusy(server: "web-1", port: serverPort).message
        #expect(busy.contains("24567") && busy.contains("web-1"))
    }

    /// The server port's listen failing has three causes ssh can't tell apart, and one of them takes the requests:
    /// the warning names each, what to do, and the way to another port.
    @Test func aBusyServerPortSaysWhyItMayBeAndWhatHoldsTheRequests() {
        let busy = Config.RouteWarning.serverPortBusy(server: "web-1", port: serverPort).message
        #expect(busy.contains("earlier connection") && busy.contains("ClientAliveInterval"))
        #expect(busy.contains("AllowTcpForwarding") && busy.contains("PermitListen"))
        #expect(busy.contains("another program"))
        #expect(busy.contains("requests meant for Next Term"))
        #expect(busy.contains(Config.newServerPortTitle) && busy.contains("Caddy"))
    }

    /// A login tab opened while the user wasn't turning Remote access on stays in the background; the Mac says
    /// where it is.
    @Test func aLoginTabInTheBackgroundIsNamedInANotification() {
        let notice = Config.sshLoginTabNotice("web-1")
        #expect(notice.title.contains("log in"))
        #expect(notice.body.contains("web-1") && notice.body.contains("tab"))
    }

    // MARK: Caddy on your own server (R48)

    @Test func theCaddyfileUsesTheSavedHostnameAndServerPort() {
        let text = Config.caddyfile(hostname: host, serverPort: serverPort)
        #expect(text == "mcp.example.com {\n\treverse_proxy 127.0.0.1:24567\n}\n")
    }

    @Test func caddysSetupInstallsAddsTheSiteAndReloads() throws {
        let apt = try #require(Config.caddySetup(.apt, hostname: host, serverPort: serverPort))
        #expect(Array(apt.prefix(2)) == ["sudo apt-get update", "sudo apt-get install -y caddy"])
        let dnf = try #require(Config.caddySetup(.dnf, hostname: host, serverPort: serverPort))
        #expect(dnf.first == "sudo dnf install -y caddy")
        let installed = try #require(Config.caddySetup(.installed, hostname: host, serverPort: serverPort))
        #expect(!installed.contains { $0.contains("install") })
        for commands in [apt, dnf, installed] {
            #expect(commands.last == "sudo systemctl reload caddy")
            let site = commands.filter { $0.contains(Config.caddySiteFile) && $0.contains("tee") }
            #expect(site.count == 1)
            #expect(site.first?.contains("mcp.example.com {\\n\\treverse_proxy 127.0.0.1:24567\\n}\\n") == true)
            #expect(commands.contains { $0.contains("caddy validate") })
        }
    }

    /// The user's own Caddyfile keeps its sites: the door's site is a file of its own, imported once.
    @Test func caddysSetupNeverReplacesTheUsersCaddyfile() throws {
        let commands = try #require(Config.caddySetup(.apt, hostname: host, serverPort: serverPort))
        let main = "/etc/caddy/Caddyfile"
        for command in commands where command.contains(main + " ") || command.hasSuffix(main) {
            #expect(!command.contains("> \(main)") || command.contains(">> \(main)"), "\(command)")
            #expect(!command.contains("tee \(main)"), "\(command)")
        }
        let append = commands.filter { $0.contains(">> \(main)") }
        #expect(append.count == 1)
        #expect(append.first?.contains("grep") == true, "only when no import is there yet")
    }

    /// Typed as one line into the user's login shell, whatever it is: no history, variable or command expansion,
    /// one sudo prompt for all of it.
    @Test func caddysSetupIsOneLineAnyLoginShellReadsTheSame() throws {
        for system in Config.CaddySystem.allCases {
            let commands = try #require(Config.caddySetup(system, hostname: host, serverPort: serverPort))
            let line = Config.caddySetupLine(commands)
            #expect(line == commands.joined(separator: " && "))
            for character in ["!", "$", "`", "\n", "\r", "\t", "~"] {
                #expect(!line.contains(character), "\(system): \(character)")
            }
            // Outside quotes, nothing fish or tcsh reads otherwise: no ( for fish's command substitution, no
            // braces, globs, comments or redirections.
            let bare = unquoted(line)
            for character in "(){}*?[]#<>;" {
                #expect(!bare.contains(character), "\(system): \(character) in \(bare)")
            }
        }
    }

    /// The text of a shell line outside its single and double quotes.
    func unquoted(_ line: String) -> String {
        var bare = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else {
                bare.append(character)
            }
        }
        return bare
    }

    /// The typed line run for real by /bin/sh in a folder standing in for /etc/caddy, with sudo, systemctl and
    /// Caddy's check left out: whether the check passes is `validates`.
    func runCaddySetup(in folder: URL, validates: Bool) throws -> Int32 {
        let commands = try #require(Config.caddySetup(.installed, hostname: host, serverPort: serverPort))
        var line = Config.caddySetupLine(commands)
        line = line.replacingOccurrences(of: "caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile",
                                         with: validates ? "true" : "false")
        line = line.replacingOccurrences(of: "systemctl enable --now caddy", with: "true")
        line = line.replacingOccurrences(of: "systemctl reload caddy", with: "true")
        line = line.replacingOccurrences(of: "sudo ", with: "")
        line = line.replacingOccurrences(of: "/etc/caddy", with: folder.path)
        #expect(!line.contains("/etc/"), "everything stays in the test's folder")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func caddyFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ra-caddy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("other.example.com {\n\trespond 200\n}\n".utf8).write(to: folder.appendingPathComponent("Caddyfile"))
        return folder
    }

    func contents(_ folder: URL) throws -> [String: String] {
        var found: [String: String] = [:]
        let manager = FileManager.default
        for name in try manager.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            found[name] = try String(contentsOf: url, encoding: .utf8)
        }
        return found
    }

    /// A Caddyfile that fails Caddy's check with the door's site, such as one that already has a block for the
    /// hostname, is put back as it was, and so is the door's earlier site, so the next restart still works.
    @Test func aFailedCaddyCheckPutsEverythingBackAsItWas() throws {
        let folder = try caddyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try contents(folder)
        #expect(try runCaddySetup(in: folder, validates: false) != 0, "the line stops there")
        #expect(try contents(folder) == before, "no site file, no import, no copy left")

        let earlier = "mcp.example.com {\n\treverse_proxy 127.0.0.1:20001\n}\n"
        let site = folder.appendingPathComponent("Caddyfile.d/next-term.caddyfile")
        try FileManager.default.createDirectory(at: site.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(earlier.utf8).write(to: site)
        let imported = "other.example.com {\n\trespond 200\n}\n\nimport \(folder.path)/Caddyfile.d/*.caddyfile\n"
        try Data(imported.utf8).write(to: folder.appendingPathComponent("Caddyfile"))
        let set = try contents(folder)
        #expect(try runCaddySetup(in: folder, validates: false) != 0)
        #expect(try contents(folder) == set, "the earlier site is back")
    }

    @Test func aPassedCaddyCheckKeepsTheSiteAndTheImportOnly() throws {
        let folder = try caddyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try runCaddySetup(in: folder, validates: true) == 0)
        let after = try contents(folder)
        #expect(after["Caddyfile.d/next-term.caddyfile"] == Config.caddyfile(hostname: host, serverPort: serverPort))
        let main = try #require(after["Caddyfile"])
        #expect(main.hasPrefix("other.example.com {\n\trespond 200\n}\n"), "the user's sites stay")
        #expect(main.hasSuffix("\nimport \(folder.path)/Caddyfile.d/*.caddyfile\n"), "at its end, on a line of its own")
        #expect(main.components(separatedBy: "Caddyfile.d/*.caddyfile").count == 2, "imported once")
        #expect(after.count == 2, "no copy left: \(after.keys.sorted())")
        // Again: the import is there already, and the site is written fresh.
        #expect(try runCaddySetup(in: folder, validates: true) == 0)
        let again = try contents(folder)
        #expect(again["Caddyfile"] == main)
        #expect(again.count == 2)
    }

    @Test func caddysSetupRefusesAnythingButAPublicHostnameAndAServerPort() {
        #expect(Config.caddySetup(.apt, hostname: "mcp.example.com'; rm -rf /", serverPort: serverPort) == nil)
        #expect(Config.caddySetup(.apt, hostname: "localhost", serverPort: serverPort) == nil)
        #expect(Config.caddySetup(.apt, hostname: "%s.example.com", serverPort: serverPort) == nil)
        #expect(Config.caddySetup(.apt, hostname: host, serverPort: 22) == nil)
        #expect(Config.caddySetup(.apt, hostname: "MCP.Example.com", serverPort: serverPort)?
                    .contains { $0.contains("mcp.example.com {") } == true)
    }

    /// Copies first, then the changes, then Caddy's check, which puts the copies back when it fails; only past it
    /// are the copies removed and Caddy started.
    @Test func caddysSetupChecksBeforeItStartsCaddy() throws {
        let commands = try #require(Config.caddySetup(.apt, hostname: host, serverPort: serverPort))
        func index(_ text: String) throws -> Int {
            try #require(commands.firstIndex { $0.contains(text) }, "\(text)")
        }
        let copy = try index("cp -p /etc/caddy/Caddyfile ")
        let site = try index("tee \(Config.caddySiteFile)")
        let imports = try index(">> /etc/caddy/Caddyfile")
        let check = try index("caddy validate")
        let removed = try index("rm -f /etc/caddy/Caddyfile.before-next-term")
        let start = try index("systemctl enable")
        #expect(copy < site && site < imports && imports < check && check < removed && removed < start)
        #expect(commands[check].contains("exit 1"), "a failed check stops the line")
    }

    /// Each label names only systems its command works on as it is; any other installs Caddy itself first.
    @Test func eachCaddySystemHasALabel() {
        let labels = Config.CaddySystem.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Config.CaddySystem.apt.label.contains("Debian 12") && Config.CaddySystem.apt.label.contains("24.04"))
        #expect(Config.CaddySystem.dnf.label == "Fedora")
    }
}
