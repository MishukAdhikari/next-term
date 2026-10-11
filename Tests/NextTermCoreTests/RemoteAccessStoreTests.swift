import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// The remote door's grant store and audit log: the grants file (versioned, `0600` in a `0700` folder, written
/// through a temp file, moved aside when it can't be read), last used saved at most once an hour, audit lines
/// masked and cut, refusals before a valid token summed once a minute, rotation, retention and the tail reader.
/// Every clock is injected.
@Suite struct RemoteAccessStoreTests {
    typealias OAuth = RemoteAccessOAuth
    typealias Entry = RemoteAccessAuditEntry
    typealias Retention = RemoteAccessAuditRetention
    typealias Flow = RemoteAccessOAuthTests

    /// 2027-01-15 08:00:00 UTC.
    static let start = RemoteAccessOAuthTests.start
    static let tenMB = 10 * 1024 * 1024

    /// A folder of its own under the temp folder, removed when the test ends. `url` is the Remote access
    /// folder inside it, which does not exist until something is saved.
    final class Folder {
        let root: URL
        let url: URL

        init() {
            let name = "nt-remote-access-\(UUID().uuidString)"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            url = root.appendingPathComponent("remote-access", isDirectory: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }

        func make() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func names() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
    }

    static func mode(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    static func setMode(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func hex(_ character: Character) -> String { String(repeating: character, count: 64) }

    static func client(_ id: String = "c1") -> OAuth.Client {
        OAuth.Client(id: id, name: "Claude", redirectURIs: [OAuth.claudeCallback], registered: start,
                     lastUsed: start.addingTimeInterval(30))
    }

    static func grant(_ id: String = "g1", options: RemoteAccessOptions = .readOnly) -> OAuth.Grant {
        OAuth.Grant(id: id, name: "Claude, phone", clientID: "c1", clientName: "Claude", redirectHost: "claude.ai",
                    options: options, host: "mcp.example.com", created: start,
                    lastUsed: start.addingTimeInterval(90), refreshHash: hex("a"), replacedHash: hex("b"),
                    replacedAt: start.addingTimeInterval(60), earlierHashes: [hex("c"), hex("d")])
    }

    static func json(_ data: Data) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func days(_ count: Double) -> Date { start.addingTimeInterval(count * 24 * 3600) }

    /// A token of the door's own form: the prefix and the base64url text of 32 bytes.
    static func token(_ prefix: String, fill: UInt8) -> String {
        let bytes = (0..<32).map { fill &+ UInt8($0) &* 7 }
        return prefix + OAuth.base64URL(bytes)
    }

    // MARK: the grants file

    @Test func grantsComeBackWithTheirOptions() throws {
        let folder = Folder()
        var store = RemoteAccessGrantStore(folder: folder.url)
        var options = RemoteAccessOptions.customStart
        options[.everyKey] = true
        let grants = [Self.grant("g1", options: options), Self.grant("g2", options: .control)]
        try store.save(clients: [Self.client()], grants: grants, now: Self.start)

        var again = RemoteAccessGrantStore(folder: folder.url)
        let loaded = again.load(now: Self.start)
        #expect(loaded.grants == grants)
        #expect(loaded.clients == [Self.client()])
        #expect(loaded.movedAside == nil)
        #expect(loaded.grants.first?.options[.everyKey] == true)
        #expect(loaded.grants.last?.preset == .control)

        // Versioned, with the options under their stable keys and no token in it.
        let document = Self.json(try Data(contentsOf: again.url))
        #expect(document["version"] as? Int == RemoteAccessGrantFile.version)
        let records = document["grants"] as? [[String: Any]] ?? []
        let first = records.first ?? [:]
        let stored = first["options"] as? [String: Bool] ?? [:]
        #expect(stored["keys.every"] == true)
        #expect(stored["see.servers"] == false)
        #expect(first["refresh_hash"] as? String == Self.hex("a"))
        #expect(first["replaced_hash"] as? String == Self.hex("b"))
        #expect(first["replaced_at"] as? String == "2027-01-15T08:01:00.000Z")
        #expect(first["earlier_hashes"] as? [String] == [Self.hex("c"), Self.hex("d")])
        #expect(first["host"] as? String == "mcp.example.com")
        #expect(first["redirect_host"] as? String == "claude.ai")
    }

    @Test func theFileIs0600InA0700Folder() throws {
        let folder = Folder()
        var store = RemoteAccessGrantStore(folder: folder.url)
        try store.save(clients: [], grants: [Self.grant()], now: Self.start)
        #expect(Self.mode(folder.url) == 0o700)
        #expect(Self.mode(store.url) == 0o600)
        // Only the file: the temp file was renamed into place.
        #expect(folder.names() == [RemoteAccessGrantStore.fileName])
    }

    @Test func modesFoundWrongAreFixed() throws {
        let folder = Folder()
        var store = RemoteAccessGrantStore(folder: folder.url)
        try store.save(clients: [], grants: [Self.grant()], now: Self.start)
        try Self.setMode(folder.url, 0o755)
        try Self.setMode(store.url, 0o644)
        let loaded = store.load(now: Self.start)
        #expect(loaded.grants.count == 1)
        #expect(Self.mode(folder.url) == 0o700)
        #expect(Self.mode(store.url) == 0o600)

        try Self.setMode(folder.url, 0o777)
        try store.save(clients: [], grants: [], now: Self.start)
        #expect(Self.mode(folder.url) == 0o700)
        #expect(Self.mode(store.url) == 0o600)
    }

    @Test func noFileMeansAnEmptyStore() {
        let folder = Folder()
        var store = RemoteAccessGrantStore(folder: folder.url)
        let loaded = store.load(now: Self.start)
        #expect(loaded.grants.isEmpty)
        #expect(loaded.clients.isEmpty)
        #expect(loaded.movedAside == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func anUnreadableFileIsMovedAsideAndTheStoreStartsEmpty() throws {
        let folder = Folder()
        try folder.make()
        var store = RemoteAccessGrantStore(folder: folder.url)
        try Data("{ not json".utf8).write(to: store.url)

        let loaded = store.load(now: Self.start)
        #expect(loaded.grants.isEmpty)
        #expect(loaded.clients.isEmpty)
        let aside = try #require(loaded.movedAside)
        #expect(aside.lastPathComponent == "grants-2027-01-15-080000.json")
        #expect(Self.text(aside) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: store.url.path))

        // Clients pair again, and the store saves as usual.
        try store.save(clients: [Self.client()], grants: [Self.grant()], now: Self.start)
        let reloaded = store.load(now: Self.start)
        #expect(reloaded.grants == [Self.grant()])
    }

    @Test func aNewerFileIsMovedAsideToo() throws {
        let folder = Folder()
        try folder.make()
        var store = RemoteAccessGrantStore(folder: folder.url)
        let newer = #"{"version": 2, "clients": [], "grants": [], "more": true}"#
        try Data(newer.utf8).write(to: store.url)
        let first = store.load(now: Self.start)
        #expect(first.movedAside?.lastPathComponent == "grants-2027-01-15-080000.json")

        // A second one in the same second gets its own name.
        try Data(#"{"clients": []}"#.utf8).write(to: store.url)
        let second = store.load(now: Self.start)
        #expect(second.movedAside?.lastPathComponent == "grants-2027-01-15-080000-2.json")
        #expect(second.grants.isEmpty)
        #expect(folder.names().count == 2)
    }

    @Test func aFailedWriteThrowsAndLeavesNoTempFile() throws {
        let folder = Folder()
        var store = RemoteAccessGrantStore(folder: folder.url)
        // A folder where the file goes: the rename fails.
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.url.appendingPathComponent("inside"))
        #expect(throws: RemoteAccessStoreError.self) {
            try store.save(clients: [], grants: [Self.grant()], now: Self.start)
        }
        #expect(folder.names() == [RemoteAccessGrantStore.fileName])
    }

    @Test func theFileNeverHoldsATokenInTheClear() throws {
        let folder = Folder()
        var (paired, first) = try Flow.exchanged(.control)
        let refresh = Flow.refreshParameters(first.refresh, client: paired.client)
        let answer = Flow.send(&paired.oauth, refresh, now: Flow.minutes(5))
        let second = try #require(Flow.tokens(answer))
        var store = RemoteAccessGrantStore(folder: folder.url)
        try store.save(clients: paired.oauth.clients, grants: paired.oauth.grants, now: Flow.minutes(5))

        let saved = Self.text(store.url)
        for value in [first.access, first.refresh, second.access, second.refresh] {
            #expect(!saved.contains(value))
        }
        #expect(!saved.lowercased().contains("ntat_"))
        #expect(!saved.lowercased().contains("ntrt_"))
        #expect(saved.contains(OAuth.hash(second.refresh)))
        #expect(saved.contains(OAuth.hash(first.refresh)))
    }

    @Test func lastUsedReachesTheFileAtMostOnceAnHour() throws {
        let folder = Folder()
        let (paired, _) = try Flow.exchanged()
        var oauth = paired.oauth
        let id = paired.grant.id
        var store = RemoteAccessGrantStore(folder: folder.url)
        _ = store.load(now: Self.start)
        try store.save(clients: oauth.clients, grants: oauth.grants, now: Self.start)

        var written: [Date] = []
        for minute in stride(from: 5.0, through: 155.0, by: 5.0) {
            let now = Flow.minutes(minute)
            oauth.noteUse(id, now: now)
            // In memory it changes on every call.
            #expect(oauth.grant(id)?.lastUsed == now)
            if try store.saveUse(clients: oauth.clients, grants: oauth.grants, now: now) {
                written.append(now)
            }
            // A refresh at 30 minutes saves the grant, last used included, and the hour counts from there.
            if minute == 30 {
                try store.save(clients: oauth.clients, grants: oauth.grants, now: now)
            }
        }
        #expect(written == [Flow.minutes(90), Flow.minutes(150)])
        var reader = RemoteAccessGrantStore(folder: folder.url)
        let hourly = reader.load(now: Flow.minutes(155))
        #expect(hourly.grants.first?.lastUsed == Flow.minutes(150))

        // On quit, a use the file does not hold yet is saved; with none, nothing is written.
        let wrote = try store.saveOnQuit(clients: oauth.clients, grants: oauth.grants, now: Flow.minutes(156))
        #expect(wrote)
        let onQuit = reader.load(now: Flow.minutes(156))
        #expect(onQuit.grants.first?.lastUsed == Flow.minutes(155))
        let again = try store.saveOnQuit(clients: oauth.clients, grants: oauth.grants, now: Flow.minutes(157))
        #expect(!again)
    }

    @Test func aGrantIsReplacedByItsIDBeforeItIsSaved() {
        var changed = Self.grant("g2")
        changed.options = .control
        let grants = [Self.grant("g1"), Self.grant("g2"), Self.grant("g3")]
        let replaced = RemoteAccessGrantStore.replacing(changed, in: grants)
        #expect(replaced.map(\.id) == ["g1", "g2", "g3"])
        #expect(replaced[1].options == .control)
        #expect(replaced[0].options == .readOnly)
    }

    @Test func theFolderIsInApplicationSupport() {
        let folder = RemoteAccessStore.defaultFolder(home: "/tmp/home")
        #expect(folder.path == "/tmp/home/Library/Application Support/Next Term/remote-access")
    }

    // MARK: audit lines

    static let forwarded = RemoteAccessHTTP.Forwarded(forwardedFor: "203.0.113.7", connectingIP: "203.0.113.9",
                                                      ray: "8c1f2a3b4c5d6e7f-SJC")

    @Test func aCallLineHasEveryField() throws {
        let result = #"{"content":[{"type":"text","text":"ok"}]}"#
        let entry = Entry.call(time: Self.start, grant: Self.grant(), tool: "answer_agent",
                               arguments: ["tab_id": "t1", "choice": 2, "force": true], decision: .refused,
                               reason: "That choice isn't a one-time choice Next Term knows.",
                               refusedBy: [.answerStanding], duration: 0.25, result: result,
                               forwarded: Self.forwarded, approved: "npm test")
        let line = try entry.line()
        #expect(line.last == 0x0A)
        #expect(line.filter { $0 == 0x0A }.count == 1)

        let object = Self.json(line)
        let keys = [
            "time", "event", "grant", "grant_name", "client", "client_name", "tool", "decision", "reason",
            "refused_by", "duration_ms", "result_size", "result_sha256", "cf_ray", "cf_connecting_ip",
            "x_forwarded_for", "arguments", "approved",
        ]
        for key in keys { #expect(object[key] != nil, "missing \(key)") }
        #expect(object["time"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(object["event"] as? String == "tool.call")
        #expect(object["grant"] as? String == "g1")
        #expect(object["grant_name"] as? String == "Claude, phone")
        #expect(object["client"] as? String == "c1")
        #expect(object["decision"] as? String == "refused")
        #expect(object["refused_by"] as? [String] == ["agents.answer_standing"])
        #expect(object["duration_ms"] as? Int == 250)
        #expect(object["result_size"] as? Int == result.utf8.count)
        let digest = SHA256.hash(data: Data(result.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(object["result_sha256"] as? String == String(digest.prefix(12)))
        #expect(object["cf_ray"] as? String == "8c1f2a3b4c5d6e7f-SJC")
        #expect(object["cf_connecting_ip"] as? String == "203.0.113.9")
        #expect(object["x_forwarded_for"] as? String == "203.0.113.7")
        let arguments = object["arguments"] as? [String: String] ?? [:]
        #expect(arguments == ["tab_id": "t1", "choice": "2", "force": "true"])
        #expect(object["approved"] as? String == "npm test")
        // The tool's output is never in a line.
        #expect(!String(decoding: line, as: UTF8.self).contains("\"ok\""))

        // A line reads back as the entry it was.
        #expect(try Entry(line: line) == entry)
    }

    @Test func anOptionsChangedLineHoldsTheGrantAndBothSets() throws {
        var oauth = try Flow.pair(.readOnly).oauth
        let id = try #require(oauth.grants.first?.id)
        _ = oauth.takeEvents()
        oauth.changeOptions(of: id, to: .control)
        let event = try #require(oauth.takeEvents().first)
        let object = Self.json(try Entry.event(event, time: Self.start).line())
        #expect(object["event"] as? String == "grant.options_changed")
        #expect(object["grant"] as? String == id)
        #expect(object["grant_name"] as? String == "Claude, phone")
        let old = Set(object["old"] as? [String] ?? [])
        let new = Set(object["new"] as? [String] ?? [])
        #expect(old == Set(RemoteAccessOptions.readOnly.on.map(\.rawValue)))
        #expect(new == Set(RemoteAccessOptions.control.on.map(\.rawValue)))
        let detail = object["detail"] as? [String: String] ?? [:]
        #expect(detail["old_preset"] == "readOnly")
        #expect(detail["new_preset"] == "control")
    }

    @Test func pairingAndRevokeEventsBecomeLines() throws {
        var paired = try Flow.pair(.customStart)
        paired.oauth.revoke(grant: paired.grant.id, now: Self.start)
        let entries = paired.oauth.takeEvents().map { Entry.event($0, time: Self.start) }
        let names = entries.map(\.event)
        #expect(names.contains("pairing.approved"))
        #expect(names.contains("grant.revoked"))
        let approved = try #require(entries.first { $0.event == "pairing.approved" })
        #expect(approved.grant == paired.grant.id)
        #expect(Set(approved.newOptions ?? []) == Set(RemoteAccessOptions.customStart.on.map(\.rawValue)))
        let revoked = try #require(entries.first { $0.event == "grant.revoked" })
        #expect(revoked.reason == "on_mac")
        #expect(revoked.grant == paired.grant.id)

        let off = Entry.turnedOff(revokeAll: true, time: Self.start)
        #expect(off.event == "remote.turned_off")
        #expect(off.reason == "revoke_all")
        let tunnel = Entry.tunnel("reconnecting", detail: "cloudflared exited", time: Self.start)
        #expect(tunnel.event == "tunnel.changed")
        #expect(tunnel.reason == "reconnecting")
    }

    @Test func anArgumentIsCutAt200Characters() {
        let long = String(repeating: "x", count: 1000)
        let entry = Entry.call(time: Self.start, grant: Self.grant(), tool: "read_file",
                               arguments: ["path": long, "lines": ["a": long]], decision: .allowed)
        #expect(entry.arguments?["path"] == String(repeating: "x", count: 200))
        #expect(entry.arguments?["lines"]?.count == 200)
        #expect(entry.arguments?["lines"]?.hasPrefix(#"{"a":"xxx"#) == true)
    }

    @Test func sendToTabTextIsKeptWholeAndMasked() {
        let long = String(repeating: "y", count: 1000)
        let typed = Entry.call(time: Self.start, grant: Self.grant(), tool: "send_to_tab",
                               arguments: ["tab_id": "t1", "text": long], decision: .allowed)
        #expect(typed.text == long)
        #expect(typed.arguments == ["tab_id": "t1"])

        let key = "sk-AbCdEf0123456789GhIjKlMn"
        let withKey = "export OPENAI_KEY=" + key + " && " + String(repeating: "z ", count: 500)
        let masked = Entry.call(time: Self.start, grant: Self.grant(), tool: "send_to_tab",
                                arguments: ["tab_id": "t1", "text": withKey], decision: .allowed)
        let text = masked.text ?? ""
        #expect(!text.contains(key))
        #expect(text.contains(MCPRedaction.mask))
        #expect(text.hasSuffix(String(repeating: "z ", count: 500)))
    }

    @Test func anApprovedCommandIsKeptWholeWithItsTokenMasked() {
        let token = "ghp_" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7c"
        let path = String(repeating: "p", count: 920)
        let command = "curl -H 'Authorization: Bearer " + token + "' https://api.example.com/" + path
        #expect(command.count > 1000)
        let entry = Entry.call(time: Self.start, grant: Self.grant(), tool: "answer_agent",
                               arguments: ["tab_id": "t1", "choice": 1], decision: .allowed, approved: command)
        let approved = entry.approved ?? ""
        #expect(!approved.contains(token))
        #expect(approved.contains(MCPRedaction.mask))
        #expect(approved.hasPrefix("curl -H"))
        #expect(approved.hasSuffix(path))
    }

    @Test func theDoorsOwnTokensNeverAppearInALine() throws {
        let access = Self.token("ntat_", fill: 3)
        let refresh = Self.token("ntrt_", fill: 11)
        let forms = [access, refresh, access.lowercased(), refresh.uppercased(), access.uppercased()]
        for form in forms {
            #expect(form.count == 48)
            let forwarded = RemoteAccessHTTP.Forwarded(forwardedFor: form, connectingIP: form, ray: form)
            let padded = String(repeating: "q", count: 150) + " " + form
            let huge = form + String(repeating: " w", count: 300_000)
            let entry = Entry.call(time: Self.start, grant: Self.grant(), tool: form,
                                   arguments: ["token": form, "near_cut": padded, "nested": ["deep": [form]],
                                               "huge": huge, form: "key"],
                                   decision: .refused, reason: "Bad key " + form, forwarded: forwarded,
                                   approved: "run " + form)
            let typed = Entry.call(time: Self.start, grant: Self.grant(), tool: "send_to_tab",
                                   arguments: ["text": "use \(form) now"], decision: .allowed)
            var refusals = RemoteAccessRefusals()
            _ = refusals.count(.noToken, first: "/mcp?token=" + form, now: Self.start)
            let summary = refusals.flush(now: Self.start)
            let dropped = OAuth.Event.registrationDropped(clientID: "c1", field: "redirect_uris", values: [form])
            let lines = [entry, typed, Entry.event(dropped, time: Self.start)] + summary
            for line in try lines.map({ try $0.line() }) {
                let text = String(decoding: line, as: UTF8.self)
                #expect(!text.contains(form))
                #expect(!text.contains(String(form.dropFirst(5))))
                #expect(!text.lowercased().contains("ntat_"))
                #expect(!text.lowercased().contains("ntrt_"))
            }
        }
    }

    // MARK: refusals before a valid token

    @Test func aThousandTokenlessRequestsInAMinuteGiveOneLine() {
        var refusals = RemoteAccessRefusals()
        var lines: [Entry] = []
        for index in 0..<1000 {
            let now = Self.start.addingTimeInterval(Double(index) * 0.059)
            lines += refusals.count(.noToken, first: "/mcp", now: now)
        }
        #expect(lines.isEmpty)
        #expect(refusals.nextDue == Self.start.addingTimeInterval(60))
        lines += refusals.due(now: Self.start.addingTimeInterval(59.9))
        #expect(lines.isEmpty)
        lines += refusals.due(now: Self.start.addingTimeInterval(60))
        #expect(lines.count == 1)
        let later = refusals.due(now: Self.start.addingTimeInterval(120))
        let line = lines.first
        #expect(line?.event == "requests.refused")
        #expect(line?.kind == "no_token")
        #expect(line?.count == 1000)
        #expect(line?.first == "/mcp")
        #expect(line?.since == Self.start)
        #expect(line?.grant == nil)
        #expect(later.isEmpty)
        #expect(refusals.nextDue == nil)
    }

    @Test func eachKindIsSummedOnItsOwnWithTheFirstHostOrPath() {
        var refusals = RemoteAccessRefusals()
        _ = refusals.count(.wrongHost, first: "127.0.0.1:40123", now: Self.start)
        _ = refusals.count(.wrongHost, first: "localhost", now: Self.start.addingTimeInterval(1))
        _ = refusals.count(.notFound, first: "/.git/config", now: Self.start.addingTimeInterval(2))
        // A request after the minute writes the old window and starts a new one.
        let written = refusals.count(.wrongHost, first: "evil.example", now: Self.start.addingTimeInterval(61))
        #expect(written.map(\.kind) == ["wrong_host"])
        #expect(written.first?.count == 2)
        #expect(written.first?.first == "127.0.0.1:40123")
        // On quit, what is counted is written at once.
        let rest = refusals.flush(now: Self.start.addingTimeInterval(62))
        #expect(rest.map(\.kind) == ["wrong_host", "not_found"])
        #expect(rest.map(\.first) == ["evil.example", "/.git/config"])

        let statuses = [400, 401, 403, 404, 405, 413, 421, 431, 200, 500]
        let kinds = statuses.map { RemoteAccessRefusals.Kind(status: $0)?.rawValue }
        #expect(kinds == ["bad_request", "no_token", "origin", "not_found", "bad_method", "body_too_large",
                          "wrong_host", "headers_too_large", nil, nil])
    }

    // MARK: rotation and retention

    @Test func theLogRotatesAtExactly10MB() {
        let under = Retention.File(index: 0, size: Self.tenMB - 10, oldest: Self.start, newest: Self.start)
        #expect(Retention.plan([under], appending: 10, now: Self.start).isEmpty)
        let full = Retention.File(index: 0, size: Self.tenMB, oldest: Self.start, newest: Self.start)
        #expect(Retention.plan([full], appending: 1, now: Self.start) == [.move(0, to: 1)])
        // An empty file takes a line of any size.
        let empty = Retention.File(index: 0, size: 0)
        #expect(Retention.plan([empty], appending: Self.tenMB + 1, now: Self.start).isEmpty)
    }

    @Test func theSixthFileIsDeleted() {
        let files = (0..<5).map { Retention.File(index: $0, size: $0 == 0 ? Self.tenMB : 100) }
        let steps = Retention.plan(files, appending: 1, now: Self.start)
        #expect(steps == [.delete(4), .move(3, to: 4), .move(2, to: 3), .move(1, to: 2), .move(0, to: 1)])
        // A file past the fifth, left by anything, goes too.
        let stray = files.prefix(2) + [Retention.File(index: 7, size: 5)]
        let strayPlan = Retention.plan(Array(stray), appending: 1, now: Self.start)
        #expect(strayPlan == [.delete(7), .move(1, to: 2), .move(0, to: 1)])
    }

    @Test func entriesOlderThan30DaysAreDropped() {
        let now = Self.days(31)
        let current = Retention.File(index: 0, size: 500, oldest: Self.days(0.8), newest: Self.days(31))
        let older = Retention.File(index: 1, size: 500, oldest: Self.days(0.2), newest: Self.days(0.7))
        let oldest = Retention.File(index: 2, size: 500, oldest: Self.days(-3), newest: Self.days(0.1))
        let steps = Retention.plan([current, older, oldest], appending: 10, now: now)
        #expect(steps == [.delete(1), .delete(2), .trim(0, before: Self.days(1))])
        #expect(Retention.fileName(0) == "audit.jsonl")
        #expect(Retention.fileName(4) == "audit.4.jsonl")
    }

    @Test func aFullFileBecomesAudit1() throws {
        let folder = Folder()
        try folder.make()
        var junk = Data(repeating: 0x20, count: Self.tenMB - 1)
        junk.append(0x0A)
        try junk.write(to: folder.file("audit.jsonl"))
        var log = RemoteAccessAuditLog(folder: folder.url)
        try log.append(Entry.turnedOff(revokeAll: false, time: Self.start), now: Self.start)

        let rotated = try FileManager.default.attributesOfItem(atPath: folder.file("audit.1.jsonl").path)
        #expect((rotated[.size] as? NSNumber)?.intValue == Self.tenMB)
        let lines = Self.text(folder.file("audit.jsonl")).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(Self.mode(folder.file("audit.jsonl")) == 0o600)
        #expect(Self.mode(folder.url) == 0o700)
        #expect(log.tail().map(\.event) == ["remote.turned_off"])
    }

    @Test func rotationKeepsFiveFiles() throws {
        let folder = Folder()
        try folder.make()
        try Data((String(repeating: "j", count: 999) + "\n").utf8).write(to: folder.file("audit.jsonl"))
        for index in 1...4 {
            try Data("file \(index)\n".utf8).write(to: folder.file("audit.\(index).jsonl"))
        }
        var log = RemoteAccessAuditLog(folder: folder.url, maximumFileSize: 1000)
        try log.append(Entry.tunnel("ready", time: Self.start), now: Self.start)
        #expect(folder.names() == ["audit.1.jsonl", "audit.2.jsonl", "audit.3.jsonl", "audit.4.jsonl", "audit.jsonl"])
        #expect(Self.text(folder.file("audit.4.jsonl")) == "file 3\n")
        #expect(Self.text(folder.file("audit.2.jsonl")) == "file 1\n")
        #expect(Self.text(folder.file("audit.1.jsonl")).hasPrefix("jjj"))
    }

    @Test func oldEntriesLeaveTheLog() throws {
        let folder = Folder()
        var log = RemoteAccessAuditLog(folder: folder.url)
        try log.append(Entry.tunnel("ready", time: Self.days(-31)), now: Self.days(-31))
        try log.append(Entry.tunnel("reconnecting", time: Self.days(-1)), now: Self.days(-1))
        let ancient = try Entry.tunnel("ready", time: Self.days(-40)).line()
        try ancient.write(to: folder.file("audit.1.jsonl"))

        try log.append(Entry.tunnel("stopped", time: Self.start), now: Self.start)
        #expect(log.tail().map(\.time) == [Self.days(-1), Self.start])
        #expect(folder.names() == ["audit.jsonl"])
        #expect(Self.mode(folder.file("audit.jsonl")) == 0o600)
    }

    // MARK: the tail and Clear Log

    @Test func theTailIsTheLast500EntriesAcrossFiles() throws {
        let folder = Folder()
        var log = RemoteAccessAuditLog(folder: folder.url, maximumFileSize: 20_000)
        for index in 0..<520 {
            let time = Self.start.addingTimeInterval(Double(index))
            try log.append(Entry.tunnel("n\(index)", time: time), now: time)
        }
        #expect(folder.names().contains("audit.1.jsonl"))
        let tail = log.tail()
        #expect(tail.count == 500)
        #expect(tail.first?.reason == "n20")
        #expect(tail.last?.reason == "n519")
        #expect(log.tail(3).map(\.reason) == ["n517", "n518", "n519"])

        // A broken line, as a crash mid-write leaves, is skipped.
        let handle = try FileHandle(forWritingTo: folder.file("audit.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"time": "2027-01-15T0"#.utf8))
        try handle.close()
        #expect(log.tail(2).map(\.reason) == ["n518", "n519"])

        try log.clear()
        #expect(folder.names().isEmpty)
        #expect(log.tail().isEmpty)
    }

    // MARK: with the OAuth authority

    @Test func aGrantSavedAndReloadedGetsTheSameDecisions() throws {
        let folder = Folder()
        let (paired, first) = try Flow.exchanged(.customStart)
        var oauth = paired.oauth
        let id = paired.grant.id
        let client = paired.client
        let firstRefresh = Flow.refreshParameters(first.refresh, client: client)
        let secondAnswer = Flow.send(&oauth, firstRefresh, now: Flow.minutes(5))
        let second = try #require(Flow.tokens(secondAnswer))
        let secondRefresh = Flow.refreshParameters(second.refresh, client: client)
        let thirdAnswer = Flow.send(&oauth, secondRefresh, now: Flow.minutes(10))
        let third = try #require(Flow.tokens(thirdAnswer))

        var store = RemoteAccessGrantStore(folder: folder.url)
        try store.save(clients: oauth.clients, grants: oauth.grants, now: Flow.minutes(10))
        var reader = RemoteAccessGrantStore(folder: folder.url)
        let loaded = reader.load(now: Flow.minutes(11))
        var relaunched = OAuth(host: Flow.host, clients: loaded.clients, grants: loaded.grants)
        #expect(relaunched.takeEvents().isEmpty)
        #expect(relaunched.grants == oauth.grants)
        #expect(relaunched.clients == oauth.clients)
        #expect(relaunched.grant(id)?.options == .customStart)

        // Access tokens live only in memory: after a relaunch the client refreshes.
        if case .valid = oauth.validate(third.access, now: Flow.minutes(11)) {} else { Issue.record("not valid") }
        #expect(relaunched.validate(third.access, now: Flow.minutes(11)) == .invalid)

        func kind(_ outcome: OAuth.TokenOutcome) -> String {
            switch outcome {
            case .issue: return "issue"
            case .answer(let answer): return Flow.error(answer) ?? "\(answer.status)"
            }
        }
        // The current refresh token works in both, with the same scope.
        let current = Flow.refreshParameters(third.refresh, client: client)
        var before = oauth
        var after = relaunched
        let currentBefore = kind(before.token(current, now: Flow.minutes(12)))
        let currentAfter = kind(after.token(current, now: Flow.minutes(12)))
        #expect(currentBefore == "issue")
        #expect(currentAfter == "issue")
        var sentBefore = oauth
        var sentAfter = relaunched
        let scopeBefore = Flow.tokens(Flow.send(&sentBefore, current, now: Flow.minutes(12)))?.scope
        let scopeAfter = Flow.tokens(Flow.send(&sentAfter, current, now: Flow.minutes(12)))?.scope
        #expect(scopeBefore != nil)
        #expect(scopeBefore == scopeAfter)

        // A token replaced two rotations back ends the grant in both.
        let stale = Flow.refreshParameters(first.refresh, client: client)
        before = oauth
        after = relaunched
        let staleBefore = kind(before.token(stale, now: Flow.minutes(12)))
        let staleAfter = kind(after.token(stale, now: Flow.minutes(12)))
        #expect(staleBefore == "invalid_grant")
        #expect(staleAfter == "invalid_grant")
        #expect(before.grant(id) == nil)
        #expect(after.grant(id) == nil)

        // An unknown token changes nothing in either; after 14 days unused the grant has ended in both.
        let unknown = Flow.refreshParameters(Self.token("ntrt_", fill: 99), client: client)
        before = oauth
        after = relaunched
        let unknownBefore = kind(before.token(unknown, now: Flow.minutes(12)))
        let unknownAfter = kind(after.token(unknown, now: Flow.minutes(12)))
        #expect(unknownBefore == "invalid_grant")
        #expect(unknownAfter == "invalid_grant")
        #expect(before.grant(id) != nil)
        #expect(after.grant(id) != nil)
        let late = Self.days(14.1)
        let lateBefore = kind(before.token(current, now: late))
        let lateAfter = kind(after.token(current, now: late))
        #expect(lateBefore == "invalid_grant")
        #expect(lateAfter == "invalid_grant")
    }
}
