import Foundation
import Testing
@testable import NextTermCore

/// The tunnel's supervision (U10), all pure: what each check, exit and tick reports to the status reducer and when
/// the child restarts; the child's output kept with the token masked; the watchdog's arguments; and what Test
/// Connection says.
@Suite struct RemoteAccessTunnelWatchTests {
    typealias Watch = RemoteAccessTunnelWatch
    typealias Config = RemoteAccessTunnelConfig
    typealias Output = RemoteAccessTunnelWatch.Output

    static let host = "mcp.example.com"
    static let port = 41234
    static let tailnetHost = "mac.tailnet-0000.ts.net"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: helpers

    func at(_ seconds: TimeInterval) -> Date { Self.t0.addingTimeInterval(seconds) }

    func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    /// `/config` with these rules, then the 404 catch-all.
    func config(_ rules: [[String: Any]], version: Int = 3) -> Data {
        let all = rules + [["service": "http_status:404"]]
        return json(["version": version, "config": ["ingress": all]] as [String: Any])
    }

    func rule(_ host: String = host, _ service: String = "http://127.0.0.1:\(port)",
              origin: [String: Any] = [:]) -> [String: Any] {
        ["hostname": host, "service": service, "originRequest": origin]
    }

    /// cloudflared's own `/config` before the tunnel's routing arrives.
    var noRoutingYet: Data {
        json(["version": -1, "config": ["ingress": [["service": "http_status:503"]]]] as [String: Any])
    }

    var up: (status: Int, body: Data) { (200, json(["status": 200, "readyConnections": 4])) }
    var down: (status: Int, body: Data) { (503, json(["status": 503, "readyConnections": 0])) }

    func cloudflare(ready: (status: Int, body: Data)?, config: Data?) -> Watch.Check {
        .cloudflare(ready: ready, config: config)
    }

    /// A Funnel share in the foreground from this Mac's name to `target`.
    func share(_ target: String = "http://127.0.0.1:\(port)") -> Data {
        let key = "\(Self.tailnetHost):443"
        let session: [String: Any] = [
            "TCP": ["443": ["HTTPS": true]],
            "Web": [key: ["Handlers": ["/": ["Proxy": target]]]],
            "AllowFunnel": [key: true],
        ]
        return json(["Foreground": ["a1b2c3": session]])
    }

    func watch(_ kind: Config.Kind = .cloudflare, host: String? = host,
               limits: Watch.Limits = .standard) -> Watch {
        var watch = Watch(kind: kind, host: host, port: Self.port, limits: limits)
        _ = watch.started(at: Self.t0)
        return watch
    }

    // MARK: Cloudflare

    @Test func readyWithTheDoorsRouteReportsReady() {
        var watch = watch()
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(10)) == [
            .report(.ready(host: Self.host)),
        ])
        #expect(watch.downSince == nil)
        #expect(watch.attempt == 0)
        #expect(watch.warnings.isEmpty)
    }

    @Test func nothingAnsweringYetIsNotReady() {
        var watch = watch()
        #expect(watch.checked(cloudflare(ready: nil, config: nil), at: at(10)) == [.report(.notReady)])
        #expect(watch.checked(cloudflare(ready: down, config: config([rule()])), at: at(20)) == [.report(.notReady)])
        #expect(watch.downSince == Self.t0, "down since the child started")
    }

    /// AE8: the route pointed at port 22 stops it within one check.
    @Test func aRouteToPort22StopsAtTheNextCheck() {
        var watch = watch()
        _ = watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(10))
        let moved = config([rule(Self.host, "http://127.0.0.1:22")])
        let message = Config.RouteStop.wrongService.message(host: Self.host, port: Self.port)
        #expect(watch.checked(cloudflare(ready: up, config: moved), at: at(20)) == [.report(.routeChanged(message))])
        #expect(watch.finished)
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(30)) == [])
        #expect(watch.exited(at: at(31)) == [], "the stop ends the child; that is no reason to restart")
        #expect(watch.tick(at: at(9999)) == [])
    }

    @Test func aRouteStopCountsWhileNotReadyToo() {
        var watch = watch()
        let bastion = config([rule(Self.host, "bastion")])
        let message = Config.RouteStop.otherService.message(host: Self.host, port: Self.port)
        #expect(watch.checked(cloudflare(ready: down, config: bastion), at: at(10)) == [
            .report(.routeChanged(message)),
        ])
    }

    @Test func withNoSavedHostTheConfigsHostnameIsReported() {
        var watch = watch(host: nil)
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(10)) == [
            .report(.ready(host: Self.host)),
        ])
    }

    /// Another hostname is reported as such, so the reducer stops and offers to use it (U10).
    @Test func anotherHostnameIsReportedForTheReducerToStop() {
        var watch = watch()
        let other = config([rule("other.example.com")])
        #expect(watch.checked(cloudflare(ready: up, config: other), at: at(10)) == [
            .report(.ready(host: "other.example.com")),
        ])
    }

    /// Once the user confirms the hostname (or Funnel's is saved), the watch names it: a second hostname then says
    /// to keep only it, and a stop names it, as with a host saved before the start.
    @Test func theConfirmedHostIsNamedFromThenOn() {
        var watch = watch(host: nil)
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(10)) == [
            .report(.ready(host: Self.host)),
        ])
        watch.use(host: Self.host)
        #expect(watch.host == Self.host)
        let two = config([rule(), rule("other.example.com")])
        let message = Config.RouteStop.otherRule.message(host: Self.host, port: Self.port)
        #expect(watch.checked(cloudflare(ready: up, config: two), at: at(20)) == [.report(.routeChanged(message))])
        var moved = self.watch(host: nil)
        moved.use(host: Self.host)
        let port22 = config([rule(Self.host, "http://127.0.0.1:22")])
        let wrong = Config.RouteStop.wrongService.message(host: Self.host, port: Self.port)
        #expect(moved.checked(cloudflare(ready: up, config: port22), at: at(10)) == [.report(.routeChanged(wrong))])
    }

    @Test func noRouteAtAllNamesTheSavedHost() {
        var watch = watch()
        let message = Config.RouteStop.noRule.message(host: Self.host, port: Self.port)
        #expect(watch.checked(cloudflare(ready: up, config: config([])), at: at(10)) == [
            .report(.routeChanged(message)),
        ])
        var first = self.watch(host: nil)
        let reported = first.checked(cloudflare(ready: up, config: config([])), at: at(10))
        guard case .report(.routeChanged(let text))? = reported.first else {
            Issue.record("a stop")
            return
        }
        #expect(reported.count == 1)
        #expect(text.contains("http://127.0.0.1:\(Self.port)"))
    }

    /// 2026-10-11: a tunnel connected to Cloudflare whose routing hasn't come after 2 minutes stops.
    @Test func waitingForRoutingWhileConnectedFailsAfterTwoMinutes() {
        var watch = watch()
        #expect(watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(10)) == [.report(.notReady)])
        #expect(watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(129)) == [.report(.notReady)])
        #expect(watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(130)) == [
            .report(.tunnelFailed(Config.noRoutes)),
        ])
        #expect(watch.finished)
    }

    @Test func theRoutingWaitCountsOnlyWhileConnected() {
        var watch = watch()
        _ = watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(10))
        _ = watch.checked(cloudflare(ready: down, config: noRoutingYet), at: at(100))
        _ = watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(110))
        #expect(watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(229)) == [.report(.notReady)])
        #expect(watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(230)) == [
            .report(.tunnelFailed(Config.noRoutes)),
        ])
    }

    @Test func routingThatArrivesInTimeIsReady() {
        var watch = watch()
        _ = watch.checked(cloudflare(ready: up, config: noRoutingYet), at: at(10))
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(60)) == [
            .report(.ready(host: Self.host)),
        ])
        #expect(watch.waitingSince == nil)
    }

    @Test func aRoutesWarningsAreKept() {
        var watch = watch()
        let odd = config([rule(origin: ["unknownSetting": "x"])])
        #expect(watch.checked(cloudflare(ready: up, config: odd), at: at(10)) == [.report(.ready(host: Self.host))])
        #expect(watch.warnings == [.unknownSettings(["unknownSetting"])])
    }

    // MARK: restarts (R32)

    @Test func anExitRestartsAfterOneSecondThenTwoThenFour() {
        var watch = watch()
        #expect(watch.exited(at: at(5)) == [.report(.notReady), .restart(after: 1)])
        #expect(!watch.running)
        _ = watch.started(at: at(6))
        #expect(watch.exited(at: at(7)) == [.report(.notReady), .restart(after: 2)])
        _ = watch.started(at: at(9))
        #expect(watch.exited(at: at(10)) == [.report(.notReady), .restart(after: 4)])
        _ = watch.started(at: at(14))
        _ = watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(20))
        #expect(watch.exited(at: at(30)) == [.report(.notReady), .restart(after: 1)], "ready again starts over")
    }

    @Test func theRestartWaitsFollowTheScale() {
        var watch = watch(limits: Watch.Limits(restartScale: 0.25))
        #expect(watch.exited(at: at(5)) == [.report(.notReady), .restart(after: 0.25)])
        _ = watch.started(at: at(6))
        #expect(watch.exited(at: at(7)) == [.report(.notReady), .restart(after: 0.5)])
    }

    @Test func aCheckWhileNoChildRunsIsDropped() {
        var watch = watch()
        _ = watch.exited(at: at(5))
        #expect(watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(6)) == [])
        #expect(watch.exited(at: at(7)) == [], "one exit per start")
    }

    // MARK: ten minutes down (R32)

    @Test func tenMinutesDownTellsTheMacOncePerOutage() {
        var watch = watch()
        let notUp = cloudflare(ready: down, config: nil)
        #expect(watch.checked(notUp, at: at(300)) == [.report(.notReady)])
        #expect(watch.checked(notUp, at: at(600)) == [.report(.notReady), .report(.tunnelDown)])
        #expect(watch.checked(notUp, at: at(610)) == [.report(.notReady)])
        _ = watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(620))
        #expect(watch.checked(notUp, at: at(630)) == [.report(.notReady)])
        #expect(watch.checked(notUp, at: at(1229)) == [.report(.notReady)])
        #expect(watch.checked(notUp, at: at(1230)) == [.report(.notReady), .report(.tunnelDown)])
    }

    @Test func ticksBetweenRestartsCountTheTimeDown() {
        var watch = watch()
        _ = watch.checked(cloudflare(ready: up, config: config([rule()])), at: at(10))
        _ = watch.exited(at: at(20))
        #expect(watch.tick(at: at(619)) == [])
        #expect(watch.tick(at: at(620)) == [.report(.tunnelDown)])
        #expect(watch.tick(at: at(700)) == [])
        let quick = Watch.Limits(notifyAfter: 5)
        var short = self.watch(limits: quick)
        #expect(short.tick(at: at(5)) == [.report(.tunnelDown)])
    }

    // MARK: Funnel

    @Test func funnelReadyWithTheDoorsShareReportsTheMacsName() {
        var watch = watch(.funnel, host: nil)
        let check = Watch.Check.funnel(name: .success(Self.tailnetHost), share: share())
        #expect(watch.checked(check, at: at(10)) == [.report(.ready(host: Self.tailnetHost))])
    }

    @Test func funnelWithNoShareYetWaitsWithoutALimit() {
        var watch = watch(.funnel, host: Self.tailnetHost)
        let none = Watch.Check.funnel(name: .success(Self.tailnetHost), share: json([:] as [String: Any]))
        #expect(watch.checked(none, at: at(10)) == [.report(.notReady)])
        #expect(watch.checked(none, at: at(500)) == [.report(.notReady)])
        #expect(!watch.finished)
    }

    @Test func aFunnelShareToAnotherPortStops() {
        var watch = watch(.funnel, host: Self.tailnetHost)
        let moved = Watch.Check.funnel(name: .success(Self.tailnetHost), share: share("http://127.0.0.1:22"))
        let message = Config.RouteStop.wrongService.message(host: Self.tailnetHost, port: Self.port)
        #expect(watch.checked(moved, at: at(10)) == [.report(.routeChanged(message))])
    }

    @Test func tailscaleTroubleOrAnUnreadableShareIsNotReady() {
        var watch = watch(.funnel, host: Self.tailnetHost)
        let loggedOut = Watch.Check.funnel(name: .failure(.notLoggedIn), share: share())
        #expect(watch.checked(loggedOut, at: at(10)) == [.report(.notReady)])
        let garbled = Watch.Check.funnel(name: .success(Self.tailnetHost), share: Data("oops".utf8))
        #expect(watch.checked(garbled, at: at(20)) == [.report(.notReady)])
        let silent = Watch.Check.funnel(name: nil, share: nil)
        #expect(watch.checked(silent, at: at(30)) == [.report(.notReady)])
        #expect(!watch.finished)
    }

    // MARK: the child's output

    @Test func outputKeepsTheLastTwentyCompleteLines() {
        var output = RemoteAccessTunnelOutput()
        for index in 1...25 { output.append(Data("line \(index)\n".utf8)) }
        #expect(output.lines.count == 20)
        #expect(output.lines.first == "line 6")
        #expect(output.lines.last == "line 25")
        output.append(Data("part".utf8))
        #expect(output.lines.last == "line 25", "a line shows once it ends")
        output.append(Data("ial\r\n".utf8))
        #expect(output.lines.last == "partial")
    }

    @Test func outputNeverShowsTheTokenInAnyForm() throws {
        let json = #"{"a":"0f1e2d3c4b5a69788796a5b4c3d2e1f0","s":"c2VjcmV0LXNlY3JldA==","t":"C2A9E5D4-1B3F-4E6A-9C8D-7F0E1A2B3C4D","e":"~~~???x"}"#
        let pasted = Data(json.utf8).base64EncodedString()
        guard case .success(let token) = Config.token(pasted) else {
            Issue.record("a token")
            return
        }
        let forms = Config.tokenForms(token)
        #expect(forms.count == 4)
        var output = RemoteAccessTunnelOutput(token: token)
        for form in forms { output.append(Data("INF token is \(form) here\n".utf8)) }
        output.append(Data("ERR GET https://user:hunter2@example.com failed\n".utf8))
        for line in output.lines {
            for form in forms { #expect(!line.contains(form)) }
        }
        #expect(output.lines.prefix(4).allSatisfy { $0 == "INF token is \(MCPRedaction.mask) here" })
        #expect(!(output.lines.last ?? "").contains("hunter2"))
    }

    /// Turn Off: the lines stay for Settings, but the token's forms and a line not ended yet, which may hold it,
    /// are dropped, so nothing of the token stays in memory once the switch is off.
    @Test func forgettingTheTokenKeepsOnlyTheMaskedLines() {
        let json = #"{"a":"0f1e2d3c","s":"c2VjcmV0","t":"C2A9E5D4-1B3F-4E6A-9C8D-7F0E1A2B3C4D"}"#
        guard case .success(let token) = Config.token(Data(json.utf8).base64EncodedString()) else {
            Issue.record("a token")
            return
        }
        var output = RemoteAccessTunnelOutput(token: token)
        #expect(output.mayHoldToken)
        output.append(Data("INF connected\n".utf8))
        output.append(Data("INF half a line".utf8))
        output.forgetToken()
        #expect(!output.mayHoldToken)
        #expect(output.lines == ["INF connected"])
        #expect(!RemoteAccessTunnelOutput().mayHoldToken)
        var partial = RemoteAccessTunnelOutput()
        partial.append(Data("no newline yet".utf8))
        #expect(partial.mayHoldToken, "a line not ended yet is held unmasked")
    }

    /// Funnel not enabled for the tailnet: `tailscale funnel` prints its own message with the link that enables it,
    /// and Settings shows those lines as they came (U10), while the watch waits with no limit.
    @Test func tailscalesOwnEnableMessageShowsWhole() {
        let link = "https://login.tailscale.com/f/funnel?node=nAbCdEf1CNTRL"
        var output = RemoteAccessTunnelOutput()
        output.append(Data("Funnel is not enabled on your tailnet.\nTo enable, visit:\n\n         \(link)\n\n".utf8))
        #expect(output.lines.contains("Funnel is not enabled on your tailnet."))
        #expect(output.lines.contains { $0.contains(link) })
        var watch = watch(.funnel, host: nil)
        let off = Watch.Check.funnel(name: .failure(.funnelOff), share: nil)
        #expect(watch.checked(off, at: at(10)) == [.report(.notReady)])
        #expect(watch.checked(off, at: at(300)) == [.report(.notReady)])
        #expect(!watch.finished)
    }

    @Test func aLongLineIsCut() {
        var output = RemoteAccessTunnelOutput()
        output.append(Data((String(repeating: "word ", count: 400) + "\n").utf8))
        #expect((output.lines.first ?? "").count <= RemoteAccessTunnelOutput.longestLine + 1)
        output.append(Data(String(repeating: "x y ", count: 10_000).utf8))
        #expect(output.lines.count == 2, "an endless line is kept cut, not held whole")
        #expect((output.lines.last ?? "").count <= RemoteAccessTunnelOutput.longestLine + 1)
    }

    // MARK: the watchdog's arguments

    static let targets = RemoteAccessGuardTargets(
        owner: 812, ownerStart: .init(seconds: 1_800_000_000, microseconds: 123_456),
        child: 4021, childStart: .init(seconds: 1_800_000_100, microseconds: 7))

    @Test func theWatchdogsArgumentsReadBackTheSame() {
        let arguments = Self.targets.arguments
        #expect(arguments == ["tunnel-guard", "812", "1800000000", "123456", "4021", "1800000100", "7"])
        #expect(RemoteAccessGuardTargets.parse(arguments) == Self.targets)
    }

    /// `nxtrm tunnel-guard` with anything else opens a file of that name, as `nxtrm mcp` does.
    @Test func anythingElseIsNotTheWatchdog() {
        let good = Self.targets.arguments
        var cases: [[String]] = [["tunnel-guard"], [], Array(good.dropLast()), good + ["1"]]
        for index in 1..<good.count {
            for bad in ["", "x", "-1", "+5", " 5", "0x10", "99999999999999999999"] {
                var changed = good
                changed[index] = bad
                cases.append(changed)
            }
        }
        var renamed = good
        renamed[0] = "tunnel-guards"
        cases.append(renamed)
        var zeroPid = good
        zeroPid[1] = "0"
        cases.append(zeroPid)
        var tooManyMicroseconds = good
        tooManyMicroseconds[3] = "1000000"
        cases.append(tooManyMicroseconds)
        for arguments in cases { #expect(RemoteAccessGuardTargets.parse(arguments) == nil, "\(arguments)") }
    }

    // MARK: Test Connection (R36)

    func metadata(_ host: String = host) -> Data {
        json(["resource": "https://\(host)/mcp", "authorization_servers": ["https://\(host)"]] as [String: Any])
    }

    func said(_ status: Int, _ body: Data = Data(), server: String? = nil,
              kind: Config.Kind = .cloudflare) -> String {
        let answer = RemoteAccessConnectionTest.Answer.response(status: status, body: body, server: server)
        return RemoteAccessConnectionTest.message(answer, kind: kind, host: Self.host)
    }

    @Test func testConnectionAsksForTheResourceMetadata() {
        let url = RemoteAccessConnectionTest.url(host: Self.host)
        #expect(url?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource")
    }

    @Test func reachingNextTermSaysThrough() {
        #expect(said(200, metadata()) == "Reached Next Term through mcp.example.com.")
        #expect(said(200, metadata(), kind: .ownServer) == "Reached Next Term through mcp.example.com.")
    }

    /// The Mac may reach its own ts.net name through the tailnet, so a pass doesn't prove the public relay.
    @Test func aFunnelPassSaysToCheckFromAPhone() {
        let text = said(200, metadata(), kind: .funnel)
        #expect(text == "Reached Next Term from this Mac. Check from a phone off Wi-Fi to test the public path.")
    }

    @Test func otherAnswersSayWhatCameBack() {
        #expect(said(403, server: "cloudflare") == "Cloudflare answered 403: check Bot Fight Mode.")
        #expect(said(403, kind: .advanced) == "mcp.example.com answered 403.")
        #expect(said(530, server: "cloudflare").hasPrefix("Cloudflare answered 530"))
        #expect(said(502).hasPrefix("Cloudflare answered 502"))
        #expect(said(421).contains("Host"))
        #expect(said(404).hasPrefix("mcp.example.com answered 404"))
        #expect(said(200, metadata("other.example.com")).contains("not as Next Term"))
        #expect(said(200, Data("<html>".utf8)).contains("not as Next Term"))
        #expect(said(500, kind: .funnel) == "mcp.example.com answered 500.")
    }

    @Test func noAnswerSaysWhy() {
        let test = RemoteAccessConnectionTest.self
        func failed(_ failure: RemoteAccessConnectionTest.Failure) -> String {
            test.message(.failed(failure), kind: .cloudflare, host: Self.host)
        }
        #expect(failed(.noSuchHost).contains("DNS"))
        #expect(failed(.timedOut) == "mcp.example.com didn't answer within 15 seconds.")
        #expect(failed(.cannotConnect) == "Couldn't connect to mcp.example.com.")
        #expect(failed(.certificate).contains("certificate"))
        #expect(failed(.other) == "Couldn't reach mcp.example.com.")
        #expect(test.failure(.cannotFindHost) == .noSuchHost)
        #expect(test.failure(.dnsLookupFailed) == .noSuchHost)
        #expect(test.failure(.timedOut) == .timedOut)
        #expect(test.failure(.cannotConnectToHost) == .cannotConnect)
        #expect(test.failure(.notConnectedToInternet) == .cannotConnect)
        #expect(test.failure(.serverCertificateUntrusted) == .certificate)
        #expect(test.failure(.secureConnectionFailed) == .certificate)
        #expect(test.failure(.badURL) == .other)
    }

    /// Nothing the network sent is shown: a body is read only for its resource.
    @Test func noMessageRepeatsWhatCameBack() {
        let body = Data("ntat_secret-from-the-wire".utf8)
        for status in [200, 400, 403, 404, 421, 500, 502, 530] {
            for kind in Config.Kind.allCases {
                #expect(!said(status, body, server: "evil-proxy", kind: kind).contains("ntat_"))
                #expect(!said(status, body, server: "evil-proxy", kind: kind).contains("evil"))
            }
        }
    }
}
