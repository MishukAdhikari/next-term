import Foundation
import Testing
@testable import NextTermCore

/// A remote MCP server reached over Streamable HTTP (MCPHubRemote), against a fake one on this Mac (MCPHubFakeRemote):
/// sessions, version negotiation, JSON and event-stream answers, a key refused, redirects, limits and timeouts; and
/// where a server may be (MCPHubAddress): this Mac, or by https a domain on the internet or the user's own network, or
/// by http a Tailscale name; never link-local, reserved, or a private IP literal.
@Suite(.serialized) struct MCPHubRemoteTests {
    func endpoint(_ fake: MCPHubFakeRemote, key: String? = nil) -> MCPHubRemote.Endpoint {
        MCPHubRemote.Endpoint(url: fake.url, headers: key.map { ["Authorization": "Bearer \($0)"] } ?? [:], keyed: key != nil)
    }

    func soon(_ seconds: TimeInterval = 30) -> Date { Date().addingTimeInterval(seconds) }

    func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    // MARK: the transport

    @Test func listsAndCallsWithASessionAndTheNegotiatedVersion() throws {
        let fake = try MCPHubFakeRemote()
        fake.sessions = true
        let remote = MCPHubRemote(name: "linear", clientVersion: "1.0")
        #expect(remote.status == .notStarted)
        let tools = try remote.tools(endpoint(fake), until: soon()).get()
        #expect(tools.compactMap { $0["name"] as? String } == ["echo", "big", "slow"])
        #expect(remote.status == .running(tools: 3))
        let result = try remote.call("echo", arguments: ["say": "hi"], endpoint: endpoint(fake), until: soon()).get()
        #expect(text(result) == "hello from remote")
        #expect((result["structuredContent"] as? [String: Any])?["said"] as? String == "hi")

        let seen = fake.seen
        #expect(seen.map(\.method) == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        // Next Term offers its newest version, then sends the one spoken, with the session's id, on every request after.
        #expect(seen[0].body.contains(#""protocolVersion":"\#(MCPServer.supportedVersions[0])""#))
        #expect(seen[0].headers["mcp-session-id"] == nil && seen[0].headers["mcp-protocol-version"] == nil)
        #expect(seen[0].headers["accept"] == "application/json, text/event-stream")
        let id = try #require(seen[1].headers["mcp-session-id"])
        for later in seen.dropFirst() {
            #expect(later.headers["mcp-session-id"] == id)
            #expect(later.headers["mcp-protocol-version"] == MCPServer.supportedVersions[0])
        }
        // The list is kept: a second ask doesn't reach the server.
        _ = try remote.tools(endpoint(fake), until: soon()).get()
        #expect(fake.seen.count == seen.count)
    }

    /// Runs `body` while twice as many GCD threads as this Mac has CPUs spin at user-initiated QoS (at most 10 seconds),
    /// so GCD has no CPU free for a concurrent queue at that QoS or below: what a parallel test run's busiest moment, or
    /// a busy app, does. The spinning ends as soon as `body` returns.
    func whileGCDIsBusy(_ body: () -> Void) {
        final class Stop: @unchecked Sendable {
            private let lock = NSLock()
            private var stopped = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
            func set() { lock.lock(); stopped = true; lock.unlock() }
        }
        let stop = Stop(), group = DispatchGroup(), spinning = DispatchSemaphore(value: 0)
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<count {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                spinning.signal()
                let end = Date().addingTimeInterval(10)
                while !stop.isSet, Date() < end {}
            }
        }
        // As many as GCD admits are spinning once a CPU's worth has started.
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount { _ = spinning.wait(timeout: .now() + 2) }
        body()
        stop.set()
        group.wait()
    }

    /// An answer that has arrived is read at once even while the process is busy: the session's delegate runs on a
    /// queue GCD always gives a thread (MCPHubRemote.delegateQueue). On an OperationQueue's own queue it waited for a
    /// free CPU, 18 to 30 seconds in a parallel test run, and the start timed out with its answer already in.
    @Test func anAnswerIsReadWhileTheProcessIsBusy() throws {
        let fake = try MCPHubFakeRemote()
        let remote = MCPHubRemote(name: "busy", clientVersion: "1.0")
        var result: Result<[[String: Any]], MCPHubRemote.Failure>?
        var took: TimeInterval = 0
        whileGCDIsBusy {
            let started = Date()
            result = remote.tools(endpoint(fake), until: soon(5))
            took = Date().timeIntervalSince(started)
        }
        #expect(try result?.get().count == 3)
        #expect(took < 3)

        // A sign-in's requests the same way.
        var status: Int?
        whileGCDIsBusy {
            let started = Date()
            status = try? MCPHubOAuthHTTP(server: fake.url).fetch(.init(get: fake.url), seconds: 5).get().status
            took = Date().timeIntervalSince(started)
        }
        #expect(status == 405)
        #expect(took < 3)
    }

    @Test func anOlderVersionIsSpokenAndAnUnknownOneRefused() throws {
        let fake = try MCPHubFakeRemote()
        fake.version = "2025-03-26"
        let remote = MCPHubRemote(name: "old", clientVersion: "1.0")
        _ = try remote.tools(endpoint(fake), until: soon()).get()
        #expect(fake.seen.last?.headers["mcp-protocol-version"] == "2025-03-26")

        let odd = try MCPHubFakeRemote()
        odd.version = "1999-01-01"
        let failure = MCPHubRemote(name: "odd", clientVersion: "1.0").tools(endpoint(odd), until: soon())
        guard case .failure(let why) = failure else { Issue.record("an unknown version was spoken"); return }
        #expect(why.text.hasPrefix("odd answered with MCP version 1999-01-01, and Next Term speaks 2025-11-25"))
    }

    /// The server ended the session (a 404 to its id): a new one is started, and the call asked once more.
    @Test func anEndedSessionStartsANewOne() throws {
        let fake = try MCPHubFakeRemote()
        fake.sessions = true
        let remote = MCPHubRemote(name: "linear", clientVersion: "1.0")
        _ = try remote.tools(endpoint(fake), until: soon()).get()
        let first = fake.seen.last?.headers["mcp-session-id"]
        fake.endSessions()
        let result = try remote.call("echo", arguments: [:], endpoint: endpoint(fake), until: soon()).get()
        #expect(text(result) == "hello from remote")
        let methods = fake.seen.map(\.method)
        #expect(methods.suffix(4) == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(fake.seen.last?.headers["mcp-session-id"] != first)
    }

    /// An answer as an event stream: the server's notification is passed over, its ping answered, the answer found by id.
    @Test func anEventStreamAnswerIsRead() throws {
        let fake = try MCPHubFakeRemote()
        fake.stream = true
        let remote = MCPHubRemote(name: "streamy", clientVersion: "1.0")
        let result = try remote.call("echo", arguments: [:], endpoint: endpoint(fake), until: soon()).get()
        #expect(text(result) == "hello from remote")
        // The ping's answer is its own POST, sent beside the call's: on a busy machine (CI) it can land seconds after the
        // call returned, so it is waited for up to 15 s; one that never comes still fails.
        let answered = (0..<300).contains { _ in
            if fake.seen.contains(where: { $0.method == "(answer)" && $0.body.contains("server-1") }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
            return false
        }
        #expect(answered)
    }

    /// A server's ping in an event stream is answered while the process is busy: the answer goes from a queue GCD
    /// always gives a thread (MCPHubRemote.answering), where a utility global queue held it past any server's patience.
    @Test func aPingIsAnsweredWhileTheProcessIsBusy() throws {
        let fake = try MCPHubFakeRemote()
        fake.stream = true
        let remote = MCPHubRemote(name: "streamy", clientVersion: "1.0")
        var answered = false
        whileGCDIsBusy {
            _ = remote.call("echo", arguments: [:], endpoint: endpoint(fake), until: soon(5))
            answered = (0..<60).contains { _ in
                if fake.seen.contains(where: { $0.method == "(answer)" && $0.body.contains("server-1") }) { return true }
                Thread.sleep(forTimeInterval: 0.05)
                return false
            }
        }
        #expect(answered)
    }

    // MARK: keys

    @Test func aRefusedKeySaysToCheckItInSettings() throws {
        let fake = try MCPHubFakeRemote()
        fake.bearer = "right"
        let remote = MCPHubRemote(name: "linear", clientVersion: "1.0")
        guard case .failure(let wrong) = remote.tools(endpoint(fake, key: "wrong"), until: soon()) else {
            Issue.record("a wrong key was taken"); return
        }
        #expect(wrong.text.hasPrefix("linear refused the key Next Term sent (HTTP 401). Ask the user to check linear's key in Next Term › Settings › MCP Servers"))
        guard case .unauthorized(401, let challenge?) = wrong.kind else { Issue.record("not unauthorized: \(wrong.kind)"); return }
        #expect(challenge.contains("resource_metadata")) // where signing in will start
        if case .failed(let why) = remote.status { #expect(why == wrong.text) } else { Issue.record("status: \(remote.status)") }

        guard case .failure(let none) = remote.tools(endpoint(fake), until: soon()) else { Issue.record("no key was taken"); return }
        #expect(none.text.contains("asks for a key or a sign-in (HTTP 401), and Next Term sends none"))
        #expect(none.text.contains("Settings › MCP Servers"))

        let ok = try remote.tools(endpoint(fake, key: "right"), until: soon()).get()
        #expect(ok.count == 3)
        #expect(fake.seen.last?.headers["authorization"] == "Bearer right")
    }

    @Test func theServersOwnHeadersNeverReplaceTheTransports() throws {
        let fake = try MCPHubFakeRemote()
        var given = endpoint(fake)
        given.headers = ["Accept": "text/html", "MCP-Protocol-Version": "1999-01-01", "X-Team": "core"]
        _ = try MCPHubRemote(name: "x", clientVersion: "1.0").tools(given, until: soon()).get()
        let last = try #require(fake.seen.last)
        #expect(last.headers["accept"] == "application/json, text/event-stream")
        #expect(last.headers["mcp-protocol-version"] == MCPServer.supportedVersions[0])
        #expect(last.headers["x-team"] == "core")
    }

    // MARK: where

    @Test func noRedirectToAnotherServer() throws {
        let fake = try MCPHubFakeRemote()
        fake.redirect = "https://elsewhere.example/mcp"
        guard case .failure(let why) = MCPHubRemote(name: "moved", clientVersion: "1.0").tools(endpoint(fake), until: soon()) else {
            Issue.record("a redirect was followed"); return
        }
        #expect(why.text.hasPrefix("moved redirected Next Term to https://elsewhere.example/mcp. Next Term follows no redirect to another server"))
        #expect(fake.seen.count == 1)
    }

    @Test func aCloudflareAccessLoginIsNamedAndNotFollowed() throws {
        let fake = try MCPHubFakeRemote()
        fake.redirect = "https://team.cloudflareaccess.com/cdn-cgi/access/login/mcp.example.com?redirect_url=%2Fmcp"
        guard case .failure(let why) = MCPHubRemote(name: "tunnel", clientVersion: "1.0").tools(endpoint(fake), until: soon()) else {
            Issue.record("a Cloudflare Access login was followed"); return
        }
        #expect(why.text.hasPrefix("tunnel is behind Cloudflare Access"))
        #expect(why.text.contains("CF-Access-Client-Id and CF-Access-Client-Secret"))
        #expect(fake.seen.count == 1)
    }

    @Test func aCloudflareAccessServiceTokenGoesAsTwoFilledHeaders() throws {
        let fake = try MCPHubFakeRemote()
        let server = MCPHubServer.remote("tunnel", url: fake.url.absoluteString, headers: [
            "CF-Access-Client-Id": "${secret:CF_ACCESS_CLIENT_ID}", "CF-Access-Client-Secret": "${secret:CF_ACCESS_CLIENT_SECRET}"])
        let made = try MCPHubRemote.endpoint(for: server, values: ["CF_ACCESS_CLIENT_ID": "abc.access", "CF_ACCESS_CLIENT_SECRET": "s3cret"]).get()
        #expect(made.keyed)
        _ = try MCPHubRemote(name: "tunnel", clientVersion: "1.0").tools(made, until: soon()).get()
        let last = try #require(fake.seen.last)
        #expect(last.headers["cf-access-client-id"] == "abc.access" && last.headers["cf-access-client-secret"] == "s3cret")
    }

    @Test func aRedirectToAnotherPortIsRefused() throws {
        let fake = try MCPHubFakeRemote()
        let target = try MCPHubFakeRemote()
        // Another port is another server: refused.
        fake.redirect = target.url.absoluteString
        guard case .failure = MCPHubRemote(name: "a", clientVersion: "1.0").tools(endpoint(fake), until: soon()) else {
            Issue.record("a redirect to another port was followed"); return
        }
        #expect(target.seen.isEmpty)
    }

    @Test func addresses() {
        func kind(_ text: String) -> MCPHubAddress.Kind? { MCPHubAddress.bytes(text).map(MCPHubAddress.kind) }
        for loopback in ["127.0.0.1", "127.8.9.10", "::1", "[::1]", "::ffff:127.0.0.1"] { #expect(kind(loopback) == .loopback, "\(loopback)") }
        for own in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.254", "fc00::1",
                    "fd12:3456::1", "fd7a:115c:a1e0::1", "::ffff:10.0.0.1", "64:ff9b::a00:1"] {
            #expect(kind(own) == .private, "\(own)")
        }
        for never in ["169.254.169.254", "169.254.0.1", "0.0.0.0", "0.1.2.3", "224.0.0.1", "240.0.0.1", "255.255.255.255",
                      "192.0.2.1", "198.18.0.1", "fe80::1", "fec0::1", "ff02::1", "::", "2001:db8::1", "::ffff:169.254.169.254"] {
            #expect(kind(never) == .never, "\(never)")
        }
        for open in ["1.1.1.1", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700::1111", "::ffff:8.8.8.8"] {
            #expect(kind(open) == .public, "\(open)")
        }
        #expect(MCPHubAddress.bytes("example.com") == nil)
        #expect(MCPHubAddress.connected("fe80::1%en0").map(MCPHubAddress.kind) == .never)
        for tailscale in ["100.64.0.1", "100.101.102.103", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::42", "::ffff:100.100.1.1"] {
            #expect(MCPHubAddress.isTailscale(MCPHubAddress.bytes(tailscale)!), "\(tailscale)")
        }
        for other in ["100.128.0.1", "10.0.0.1", "fd7a:115c:a1e1::1", "fd00::1", "1.1.1.1"] {
            #expect(!MCPHubAddress.isTailscale(MCPHubAddress.bytes(other)!), "\(other)")
        }
        #expect(MCPHubAddress.isTailscaleName("box.tail1234.ts.net") && MCPHubAddress.isTailscaleName("BOX.tail1234.ts.net."))
        #expect(!MCPHubAddress.isTailscaleName("ts.net") && !MCPHubAddress.isTailscaleName(".ts.net") && !MCPHubAddress.isTailscaleName("evil-ts.net"))
    }

    func address(_ text: String) -> [UInt8] { MCPHubAddress.bytes(text)! }
    func reason(_ url: String, _ addresses: [String]) -> String? {
        MCPHubAddress.reason(url: URL(string: url)!, addresses: addresses.map(address), name: "x")
    }

    @Test func thisMacAndTheInternet() {
        #expect(reason("https://mcp.example.com/mcp", ["1.1.1.1"]) == nil)
        #expect(reason("https://1.1.1.1/mcp", ["1.1.1.1"]) == nil)
        #expect(reason("http://localhost:3000/mcp", ["127.0.0.1"]) == nil)
        #expect(reason("http://[::1]:3000/mcp", ["::1"]) == nil)
        #expect(reason("http://localhost/mcp", ["1.1.1.1"])?.contains("should be this Mac") == true)
        #expect(reason("https://mcp.example.com/mcp", [])?.contains("has no address") == true)
        // Another name that resolves to this Mac: refused, so a rebinding can't reach this Mac's own servers.
        #expect(reason("https://mcp.example.com/mcp", ["127.0.0.1"])?.contains("use localhost") == true)
    }

    @Test func httpsToADomainMayBeInTheUsersOwnNetwork() {
        for own in ["10.0.0.5", "192.168.1.10", "172.20.0.2", "100.101.102.103", "fd12::5", "fd7a:115c:a1e0::9"] {
            #expect(reason("https://mcp.home.example.com/mcp", [own]) == nil, "\(own)")
        }
        #expect(reason("https://mcp.example.com/mcp", ["1.1.1.1", "192.168.1.10"]) == nil)
        #expect(reason("https://box.tail1234.ts.net/mcp", ["100.101.102.103"]) == nil)
    }

    @Test func linkLocalAndReservedAreNeverReached() {
        for never in ["169.254.169.254", "fe80::1", "0.0.0.0", "224.0.0.1", "240.0.0.1", "192.0.2.1", "::", "::ffff:169.254.169.254"] {
            #expect(reason("https://mcp.example.com/mcp", [never])?.contains("link-local or reserved") == true, "\(never)")
            #expect(reason("https://mcp.example.com/mcp", ["1.1.1.1", never])?.contains("link-local or reserved") == true, "\(never)")
        }
        #expect(reason("https://169.254.169.254/latest/meta-data", ["169.254.169.254"])?.contains("private network") == true)
    }

    @Test func aPrivateIPLiteralIsRefusedWithTheDomainRecommended() {
        for literal in ["https://10.0.0.5/mcp", "https://192.168.1.10/", "https://[fd12::5]/mcp", "https://100.101.102.103/mcp",
                        "http://10.0.0.5/mcp", "http://100.101.102.103/mcp"] {
            let why = reason(literal, [URL(string: literal)!.host!])
            #expect(why?.contains("names an address in a private network") == true, "\(literal)")
            #expect(why?.contains("own domain over https") == true, "\(literal)")
        }
        #expect(MCPHubRules.urlReason("https://10.0.0.5/mcp")?.contains("own domain over https") == true)
    }

    @Test func httpBeyondThisMacIsATailscaleNameOnTailscalesAddresses() {
        #expect(reason("http://box.tail1234.ts.net:8080/mcp", ["100.101.102.103"]) == nil)
        #expect(reason("http://box.tail1234.ts.net/mcp", ["100.101.102.103", "fd7a:115c:a1e0::9"]) == nil)
        // A Tailscale name that resolves outside Tailscale's ranges: refused, even inside the user's network.
        for outside in ["192.168.1.10", "1.1.1.1", "100.128.0.1", "fd00::1"] {
            #expect(reason("http://box.tail1234.ts.net/mcp", [outside])?.contains("resolves outside Tailscale") == true, "\(outside)")
        }
        #expect(reason("http://box.tail1234.ts.net/mcp", ["100.101.102.103", "1.1.1.1"])?.contains("resolves outside Tailscale") == true)
        #expect(reason("http://box.tail1234.ts.net/mcp", ["169.254.169.254"])?.contains("link-local or reserved") == true)
        // Any other http: refused, whatever it resolves to, with the way to do it.
        for other in ["http://nas.local/mcp", "http://mcp.home.example.com/mcp", "http://example.com/mcp", "http://1.1.1.1/mcp"] {
            let why = reason(other, ["192.168.1.10"])
            #expect(why?.contains("http:// to another machine") == true, "\(other)")
            #expect(why?.contains(MCPHubAddress.recommendation) == true, "\(other)")
        }
    }

    @Test func theConnectedAddressIsHeldToTheSameRule() {
        // What the connection used is checked as one address under the same rule: a private one for an https domain
        // passes, link-local or loopback never does, and http to a Tailscale name must stay on Tailscale.
        func used(_ url: String, _ text: String) -> String? {
            MCPHubAddress.connected(text).flatMap { MCPHubAddress.reason(url: URL(string: url)!, addresses: [$0], name: "x") }
        }
        #expect(used("https://mcp.home.example.com/mcp", "192.168.1.10") == nil)
        #expect(used("https://mcp.home.example.com/mcp", "fd12::5%en0") == nil)
        #expect(used("https://mcp.example.com/mcp", "fe80::1%en0")?.contains("link-local or reserved") == true)
        #expect(used("https://mcp.example.com/mcp", "127.0.0.1") != nil)
        #expect(used("http://box.tail1234.ts.net/mcp", "100.101.102.103") == nil)
        #expect(used("http://box.tail1234.ts.net/mcp", "192.168.1.10")?.contains("resolves outside Tailscale") == true)
        #expect(used("http://localhost:3000/mcp", "127.0.0.1") == nil)
    }

    @Test func aPrivateAddressIsNeverPosted() {
        let remote = MCPHubRemote(name: "lan", clientVersion: "1.0")
        let given = MCPHubRemote.Endpoint(url: URL(string: "https://10.9.9.9/mcp")!, headers: ["Authorization": "Bearer k"], keyed: true)
        guard case .failure(let why) = remote.tools(given, until: soon(2)) else { Issue.record("a private address was reached"); return }
        #expect(why.text.contains("private network"))
    }

    @Test func cloudflareAccessIsNamed() {
        #expect(MCPHubRemote.isCloudflareAccess(to: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login/mcp.example.com")))
        #expect(MCPHubRemote.isCloudflareAccess(to: URL(string: "https://mcp.example.com/cdn-cgi/access/login")))
        #expect(MCPHubRemote.isCloudflareAccess(headers: ["cf-access-domain": "mcp.example.com"]))
        #expect(MCPHubRemote.isCloudflareAccess(headers: ["www-authenticate": "Cloudflare-Access domain=\"x\""]))
        #expect(MCPHubRemote.isCloudflareAccess(body: Data("<a href=\"https://team.cloudflareaccess.com/login\">".utf8)))
        #expect(!MCPHubRemote.isCloudflareAccess(headers: ["www-authenticate": "Bearer realm=\"x\""], body: Data("no".utf8),
                                                 to: URL(string: "https://evil-cloudflareaccess.com/")))
        let none = MCPHubRemote.cloudflareAccess("app", status: 403, sent: [:])
        #expect(none.contains("behind Cloudflare Access") && none.contains("CF-Access-Client-Id and CF-Access-Client-Secret") && none.contains("HTTP 403"))
        let sent = MCPHubRemote.cloudflareAccess("app", status: 403, sent: ["CF-Access-Client-Id": "id.access", "CF-Access-Client-Secret": "s"])
        #expect(sent.contains("refused the service token") && !sent.contains("id.access"))
    }

    // MARK: limits

    @Test func aSlowCallEndsAtItsDeadline() throws {
        let fake = try MCPHubFakeRemote()
        fake.slowSeconds = 3
        let remote = MCPHubRemote(name: "slowpoke", clientVersion: "1.0")
        _ = try remote.tools(endpoint(fake), until: soon()).get()
        let began = Date()
        guard case .failure(let why) = remote.call("slow", arguments: [:], endpoint: endpoint(fake), until: soon(0.6)) else {
            Issue.record("a slow call answered in time"); return
        }
        #expect(why.text == "slowpoke didn't answer Next Term's call in time.")
        #expect(Date().timeIntervalSince(began) < 2)
    }

    @Test func anAnswerOverTheLimitIsRefused() throws {
        let fake = try MCPHubFakeRemote()
        let remote = MCPHubRemote(name: "huge", limits: .init(message: 100_000), clientVersion: "1.0")
        _ = try remote.tools(endpoint(fake), until: soon()).get()
        guard case .failure(let why) = remote.call("big", arguments: [:], endpoint: endpoint(fake), until: soon()) else {
            Issue.record("an answer over the limit was read"); return
        }
        #expect(why.text.hasPrefix("huge sent an answer over the"))
    }

    @Test func nothingListeningSaysItCantBeReached() {
        let remote = MCPHubRemote(name: "gone", clientVersion: "1.0")
        let given = MCPHubRemote.Endpoint(url: URL(string: "http://127.0.0.1:9/mcp?key=abc")!)
        guard case .failure(let why) = remote.tools(given, until: soon(5)) else { Issue.record("reached nothing"); return }
        #expect(why.text.hasPrefix("gone can't be reached at http://127.0.0.1:9/mcp"))
        #expect(!why.text.contains("abc")) // a URL's query may hold a key: never in a sentence
    }

    // MARK: keys filled in by the app

    @Test func keysAreFilledInOnlyForTheNeed() throws {
        let server = MCPHubServer.remote("linear", url: "https://mcp.example.com/mcp?team=${secret:TEAM}",
                                         headers: ["Authorization": "Bearer ${secret:LINEAR_API_KEY}", "X-Plain": "on"])
        let made = try MCPHubRemote.endpoint(for: server, values: ["LINEAR_API_KEY": "lin_123", "TEAM": "a&b c"]).get()
        #expect(made.headers == ["Authorization": "Bearer lin_123", "X-Plain": "on"])
        #expect(made.url.absoluteString == "https://mcp.example.com/mcp?team=a%26b%20c")
        #expect(made.keyed)
        guard case .failure(let missing) = MCPHubRemote.endpoint(for: server, values: ["TEAM": "x"]) else { Issue.record("filled with nothing"); return }
        #expect(missing.text.contains("LINEAR_API_KEY"))
        guard case .failure(let broken) = MCPHubRemote.endpoint(for: server, values: ["LINEAR_API_KEY": "a\r\nX-Evil: 1", "TEAM": "x"]) else {
            Issue.record("a header took a line break"); return
        }
        #expect(broken.text.contains("line break") && !broken.text.contains("X-Evil"))
        #expect(try MCPHubRemote.endpoint(for: .remote("open", url: "https://open.example.com/mcp"), values: [:]).get().keyed == false)
    }

    /// A key in the URL is percent-encoded as SecretMask's own form of it, so a sentence quoting the URL is masked.
    @Test func aKeyInTheURLIsEncodedAsTheMaskKnowsIt() throws {
        let key = "k3y:with@odd!chars$(and)*more,;'~"
        let server = MCPHubServer.remote("odd", url: "https://mcp.example.com/${secret:KEY}/mcp")
        let made = try MCPHubRemote.endpoint(for: server, values: ["KEY": key]).get()
        let masked = String(decoding: SecretMask.percentEncoded(Array(key.utf8)), as: UTF8.self)
        #expect(made.url.absoluteString == "https://mcp.example.com/\(masked)/mcp")
    }

    /// The server's own requests in one answer are answered a few at most: one answer never makes Next Term send many.
    @Test func aServersOwnRequestsAreCapped() {
        let exchange = MCPHubRemote.Exchange(origin: URL(string: "https://mcp.example.com/mcp")!, expecting: 7, name: "busy", limit: 1 << 20)
        exchange.isStream = true
        var stream = ""
        for id in 0..<500 { stream += "data: {\"jsonrpc\":\"2.0\",\"id\":\(1000 + id),\"method\":\"ping\"}\n\n" }
        stream += "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n"
        #expect(exchange.received(Data(stream.utf8)))
        #expect(exchange.found && exchange.serverRequests.count == MCPHubRemote.Exchange.mostServerRequests)
    }

    // MARK: through an agent's session

    /// A plan's server at a URL is ready, its URL carried as written and never its headers, and an older SSE one isn't.
    @Test func thePlanCarriesTheURLAndNeverTheHeaders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-remote-\(UUID().uuidString)").path
        let userFile = MCPHubScope.userPath(home: home)
        _ = MCPHubScope.save(.set(.remote("linear", url: "https://mcp.linear.app/mcp", headers: ["Authorization": "Bearer ${secret:LINEAR_API_KEY}"])),
                             to: userFile, place: .user)
        _ = MCPHubScope.save(.set(MCPHubServer(name: "older", transport: .sse, url: "https://old.example.com/sse")), to: userFile, place: .user)
        let resolution = MCPHubScope.servers(folder: home, userFile: userFile)
        let plan = MCPHubPlan.make(resolution, folder: home, path: [])
        #expect(plan.server(named: "linear")?.state == .ready && plan.server(named: "linear")?.isRemote == true)
        #expect(plan.server(named: "older")?.state == .remote)
        #expect(plan.isActive)
        #expect(!plan.text.contains("LINEAR_API_KEY") && !plan.text.contains("Authorization"))
    }

    /// The bridge's catalog reaches a remote server through the app (here, a stand-in that reaches the fake as the app
    /// does), lists it running, and passes a tool's result on.
    @Test func theCatalogReachesARemoteServerThroughTheApp() throws {
        let fake = try MCPHubFakeRemote()
        fake.sessions = true
        let remote = MCPHubRemote(name: "linear", clientVersion: "1.0")
        let asked = Asked()
        let app: MCPHubSession.Remote = { arguments, _ in
            asked.add(arguments)
            let given = MCPHubRemote.Endpoint(url: URL(string: arguments["url"] as? String ?? "")!)
            let deadline = Date().addingTimeInterval((arguments["seconds"] as? Double) ?? 10)
            let tools: [[String: Any]]
            switch remote.tools(given, until: deadline) {
            case .success(let found): tools = found
            case .failure(let failure): return (failure.text, true)
            }
            if arguments["op"] as? String == "tools" { return (MCPServer.json(["tools": tools]), false) }
            // As the app answers a call: the tool's name checked against the list, then the call, in one need.
            let names = tools.compactMap { $0["name"] as? String }, tool = arguments["tool"] as? String ?? ""
            guard names.contains(tool) else { return (MCPServer.json(["names": names]), false) }
            switch remote.call(tool, arguments: arguments["arguments"] as? [String: Any] ?? [:], endpoint: given, until: deadline) {
            case .success(let result): return (MCPServer.json(["result": result, "names": names]), false)
            case .failure(let failure): return (failure.text, true)
            }
        }
        let plan = MCPHubPlan(folder: NSTemporaryDirectory(), servers: [
            MCPHubPlan.Server(name: "linear", state: .ready, url: fake.url.absoluteString, list: "/u/mcp.json"),
            MCPHubPlan.Server(name: "older", state: .remote, url: "https://old.example.com/sse", list: "/u/mcp.json"),
        ])
        let session = MCPHubSession(plan: plan, refresh: { plan }, nxtrm: ["/usr/bin/true"], environment: [:], version: "0", remote: app)
        #expect(session.isActive)
        let called = session.call("mcp_call", ["server": "linear", "tool": "echo", "arguments": ["say": "hi"]])
        #expect(text(called) == "hello from remote" && called["isError"] as? Bool != true)
        // One need of the app for a call, so a key allowed once is asked for once.
        #expect(asked.all.map { $0["op"] as? String } == ["call"])
        #expect(asked.all.allSatisfy { $0["list"] as? String == "/u/mcp.json" && $0["server"] as? String == "linear" })

        let listed = (try? JSONSerialization.jsonObject(with: Data(text(session.call("mcp_servers", [:])).utf8))) as? [String: Any]
        let servers = listed?["servers"] as? [[String: Any]] ?? []
        #expect(servers.first?["state"] as? String == "running" && servers.first?["tools"] as? Int == 3)
        #expect(servers.first?["url"] as? String == fake.url.absoluteString && servers.first?["command"] == nil)
        #expect((servers.last?["note"] as? String)?.contains("HTTP+SSE") == true)

        let typo = session.call("mcp_call", ["server": "linear", "tool": "ecko"])
        #expect(text(typo).contains("linear has no tool named ecko. Its tools: echo") && typo["isError"] as? Bool == true)
        #expect(asked.all.count == 2)

        let older = session.call("mcp_tools", ["server": "older"])
        #expect(text(older).contains("older HTTP+SSE transport") && older["isError"] as? Bool == true)

        // The app gone: a sentence, never a hang.
        let gone = MCPHubSession(plan: plan, refresh: { plan }, nxtrm: ["/usr/bin/true"], environment: [:], version: "0", remote: { _, _ in nil })
        let failed = gone.call("mcp_tools", ["server": "linear"])
        #expect(text(failed).contains("Next Term didn't answer for linear") && failed["isError"] as? Bool == true)
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String: Any]] = []
        func add(_ arguments: [String: Any]) { lock.lock(); list.append(arguments); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return list }
    }
}
