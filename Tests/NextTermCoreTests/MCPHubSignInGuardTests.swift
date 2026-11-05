import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// What keeps a sign-in's token where it belongs: found by the server's own URL, never by an unchecked id; an older
/// copy of the file put back is tampered; a sign-in server out of reach spends nothing; a token a server quotes back
/// is hidden however it is written; and a slow connection can't hold the loopback callback.
@Suite(.serialized) struct MCPHubSignInGuardTests {
    final class Folder {
        let folder: SecretFolder
        let key = SymmetricKey(size: .bits256)
        var store: SignInStore { SignInStore(folder: folder, key: key) }

        init() {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-signin-guard-\(UUID().uuidString)", isDirectory: true)
            folder = SecretFolder(url: base.appendingPathComponent("Secrets.noindex", isDirectory: true))
        }

        deinit { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }

        func record(_ server: String, resource: String, access: String = "access-1", refresh: String? = "refresh-1") throws -> SignInFile.Record {
            let meta = MCPHubOAuthDiscovery.Metadata(resource: resource, issuer: "https://auth.example", authorizationEndpoint: "https://auth.example/a",
                                                     tokenEndpoint: "https://auth.example/t")
            return try SignInFile.record(name: "linear", server: URL(string: server), metadata: meta,
                                         client: .init(issuer: "https://auth.example", clientID: "c", kind: .registered),
                                         tokens: .init(access: access, refresh: refresh, expires: nil, scopes: nil), scopes: [], key: key)
        }

        var file: URL { URL(fileURLWithPath: folder.path(SignInFile.name)) }
    }

    @Test func aSignInIsFoundByItsServersURLEvenWhenItsResourceIsTheOrigin() throws {
        let setup = Folder()
        let client = MCPHubOAuthRegistration.Client(issuer: "https://auth.example", clientID: "c", kind: .registered)
        // Resource metadata at the root names the origin (RFC 9728 §3.3): the sign-in is still the /mcp server's alone.
        let mcp = try setup.store.add(try setup.record("https://mcp.example.com/mcp", resource: "https://mcp.example.com"), client: client)
        let other = try setup.store.add(try setup.record("https://mcp.example.com/other", resource: "https://mcp.example.com", access: "access-2"),
                                        client: client)
        let body = try setup.store.read().get()
        #expect(body.records.count == 2) // one origin, two servers: neither replaced the other
        #expect(body.record(server: "https://MCP.example.com:443/mcp")?.id == mcp.id)
        #expect(body.record(server: "https://mcp.example.com/other")?.id == other.id)
        #expect(body.record(server: "https://mcp.example.com/mcp/") == nil)
        #expect(body.record(server: "https://mcp.example.com") == nil)
        #expect(body.record(server: "https://evil.example/mcp") == nil)
        // A record from before `server` is found by its resource.
        var older = try setup.record("https://a.example/mcp", resource: "https://a.example/mcp")
        older.server = nil
        #expect(SignInFile.Body(records: [older]).record(server: "https://a.example/mcp")?.id == older.id)
    }

    @Test func anOlderCopyOfTheFilePutBackReadsAsTampered() throws {
        let setup = Folder()
        let client = MCPHubOAuthRegistration.Client(issuer: "https://auth.example", clientID: "c", kind: .registered)
        let made = try setup.store.add(try setup.record("https://mcp.example.com/mcp", resource: "https://mcp.example.com/mcp"), client: client)
        try setup.store.setConsent(id: made.id, agent: "codex", allowed: true)
        let allowed = try Data(contentsOf: setup.file)
        // The user takes Codex away (Change…); an agent puts the copy that allowed it back, its MAC good under the key.
        try setup.store.setConsent(id: made.id, agent: "codex", allowed: false)
        try allowed.write(to: setup.file)
        #expect(setup.store.read() == .failure(.tampered))
        #expect(SignInStore(folder: setup.folder, key: setup.key).read() == .failure(.tampered)) // every store of this file and key
        #expect(throws: SignInFile.Failure.tampered) { try setup.store.setConsent(id: made.id, agent: "claude", allowed: true) }
        // Signing in again starts it over, past the copy.
        _ = try setup.store.add(try setup.record("https://mcp.example.com/mcp", resource: "https://mcp.example.com/mcp"), client: client)
        let now = try setup.store.read().get()
        #expect(now.records.count == 1 && now.records[0].consents.isEmpty)
        // A key made anew (the last sign-out took the old one) starts its own count.
        let fresh = SignInStore(folder: setup.folder, key: SymmetricKey(size: .bits256))
        try FileManager.default.removeItem(at: setup.file)
        _ = try fresh.add(try setup.record("https://mcp.example.com/mcp", resource: "https://mcp.example.com/mcp"), client: client)
        #expect(fresh.read().map(\.records.count) == .success(1))
    }

    @Test func aRefusalWithTheSignInServerOutOfReachKeepsTheSignIn() throws {
        let setup = Folder()
        let client = MCPHubOAuthRegistration.Client(issuer: "https://auth.example", clientID: "c", kind: .registered)
        let made = try setup.store.add(try setup.record("https://mcp.example.com/mcp", resource: "https://mcp.example.com/mcp"), client: client)
        // The server answered 401 to access-1; the sign-in server can't be reached, and nothing left.
        let refresher = SignInRefresher(id: made.id, store: setup.store) { _ in .failure(.unsent("no route")) }
        let outcome = refresher.token(refused: "access-1")
        #expect(outcome == .unreachable("no route"))
        #expect(SignInRefresher.afterRefusal(outcome, refused: "access-1") == .unreachable("no route"))
        let kept = try setup.store.read().get().record(id: made.id)
        #expect(kept?.state == .signedIn && kept.flatMap(setup.store.tokens)?.refresh == "refresh-1")
        // The other answers: a new token is sent once more, the refused one again is a lapse the need marks.
        #expect(SignInRefresher.afterRefusal(.token("access-2"), refused: "access-1") == .again("access-2"))
        #expect(SignInRefresher.afterRefusal(.token("access-1"), refused: "access-1") == .signedOut(lapse: nil))
        #expect(SignInRefresher.afterRefusal(.signedOut(lapse: 3), refused: "access-1") == .signedOut(lapse: 3))
        #expect(SignInRefresher.afterRefusal(.needsMoreAccess(["write"]), refused: "x") == .needsMoreAccess(["write"]))
        #expect(SignInRefresher.afterRefusal(.missing, refused: "x") == .missing)
        #expect(SignInRefresher.afterRefusal(.tampered, refused: "x") == .tampered)
    }

    @Test func aTokenAServerQuotesIsHiddenAsWrittenAndAsJSONWritesIt() throws {
        let token = "ab/cd+ef:gh"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["description": "use \(token)"]), as: UTF8.self)
        #expect(json.contains("ab\\/cd")) // JSON writes `/` as `\/`
        let hidden = MCPHubSignInWords.hiding([token, ""], in: json + " and " + token)
        #expect(!hidden.contains("ab/cd") && !hidden.contains("ab\\/cd") && !hidden.contains("ef:gh"))
        #expect(hidden.components(separatedBy: "\u{2022}\u{2022}\u{2022}").count == 3)
        #expect(MCPHubSignInWords.hiding([], in: "nothing") == "nothing")
    }

    @Test func aConnectionSendingAByteNowAndThenDoesNotHoldTheCallback() throws {
        let listener = try MCPHubLoopback { query in query.contains { $0 == ("state", "s") } ? MCPHubLoopback.page("done") : nil }
        let port = listener.port
        func connect() -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
        let slow = connect()
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for byte in "GET /callback?state=s&code=slow".utf8 { // never ends its head
                var one = byte
                guard write(slow, &one, 1) == 1, stop.wait(timeout: .now() + 0.3) == .timedOut else { break }
            }
            close(slow)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        let real = connect()
        let request = Array("GET /callback?state=s&code=real HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        _ = request.withUnsafeBufferPointer { write(real, $0.baseAddress, $0.count) }
        let query = listener.wait(until: Date().addingTimeInterval(8))
        stop.signal()
        close(real)
        #expect(query?.contains { $0 == ("code", "real") } == true)
        #expect(Date().timeIntervalSince(started) < MCPHubLoopback.headTime + 1.5)
    }
}
