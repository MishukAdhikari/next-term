import CryptoKit
import Darwin
import Foundation

// The Remote access door's grant store and audit log (R15 to R17, R39, R60, KTD9). Both live in
// `~/Library/Application Support/Next Term/remote-access/`: `0600` files in a `0700` folder, each mode set again
// when it is found otherwise. The grants file holds grant records and refresh-token hashes, never a token in the
// clear and never the tunnel token. The audit log is JSON lines, masked and cut, with fixed limits on its size
// and age. Clocks come in with every call, so the app decides when "now" is (KTD3).

/// Where Remote access keeps its files, and how it writes them.
public enum RemoteAccessStore {
    public static let folderMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600

    /// `~/Library/Application Support/Next Term/remote-access`. Self-tests pass a temp folder instead (KTD18).
    public static func defaultFolder(home: String = NSHomeDirectory()) -> URL {
        let path = (home as NSString).appendingPathComponent("Library/Application Support/Next Term/remote-access")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Makes the folder `0700`, or sets it to `0700` when it was not.
    static func prepare(_ folder: URL) throws {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw RemoteAccessStoreError(path: folder.path, code: ENOTDIR) }
        } else {
            do {
                let attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(folderMode)]
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: attributes)
            } catch {
                let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                let code = underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying?.code ?? 0) : EIO
                throw RemoteAccessStoreError(path: folder.path, code: code)
            }
        }
        try fix(folder.path, to: folderMode)
    }

    /// Sets `path` to `mode` when its permission bits are otherwise.
    static func fix(_ path: String, to mode: mode_t) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { throw RemoteAccessStoreError.last(path) }
        guard info.st_mode & 0o7777 != mode else { return }
        guard chmod(path, mode) == 0 else { throw RemoteAccessStoreError.last(path) }
    }

    /// Writes `data` to a new `0600` file beside `url`, flushes it to disk and renames it over `url`, so a reader
    /// finds the old file or the new one, never part of one. The temp file goes when anything fails. The file and
    /// then the folder are flushed past the drive's cache, so the new file survives a power loss or a panic too.
    static func replace(_ url: URL, with data: Data) throws {
        let name = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let temporary = url.deletingLastPathComponent().appendingPathComponent(name).path
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = open(temporary, flags, fileMode)
        guard descriptor >= 0 else { throw RemoteAccessStoreError.last(temporary) }
        do {
            guard fchmod(descriptor, fileMode) == 0 else { throw RemoteAccessStoreError.last(temporary) }
            try writeAll(descriptor, data, path: temporary)
            guard flush(descriptor) else { throw RemoteAccessStoreError.last(temporary) }
        } catch {
            close(descriptor)
            unlink(temporary)
            throw error
        }
        close(descriptor)
        guard rename(temporary, url.path) == 0 else {
            let failure = RemoteAccessStoreError.last(url.path)
            unlink(temporary)
            throw failure
        }
        flushFolder(of: url)
    }

    /// Flushes a file to the disk itself, past the drive's own cache (`F_FULLFSYNC`); `fsync` on a file system
    /// that has no full flush.
    static func flush(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }

    /// Flushes the folder that holds `url`, so a rename in it is on the disk. The rename has happened and readers
    /// find the new file, so a failure here throws nothing: the save must not count as one that failed.
    static func flushFolder(of url: URL) {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        let descriptor = open(url.deletingLastPathComponent().path, flags)
        guard descriptor >= 0 else { return }
        _ = flush(descriptor)
        close(descriptor)
    }

    /// Writes every byte, again after an interruption.
    static func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let written = write(descriptor, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RemoteAccessStoreError.last(path)
                }
                left -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    // MARK: dates

    /// UTC with milliseconds, how every date in the grants file and the audit log is written:
    /// `2027-01-15T08:00:00.000Z`.
    static var timeStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }

    public static func timestamp(_ date: Date) -> String {
        date.formatted(timeStyle)
    }

    static func date(_ text: String) -> Date? {
        try? timeStyle.parse(text)
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RemoteAccessStore.timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let parsed = RemoteAccessStore.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date")
            }
            return parsed
        }
        return decoder
    }
}

/// A file the store could not write, or a folder it could not make. Names the path, never what was in it.
public struct RemoteAccessStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let code: Int32

    public init(path: String, code: Int32) {
        self.path = path
        self.code = code
    }

    static func last(_ path: String) -> RemoteAccessStoreError {
        RemoteAccessStoreError(path: path, code: errno)
    }

    public var description: String {
        "\(path): \(String(cString: strerror(code)))"
    }
}

// MARK: - the grants file

/// The grants file: a version, the registered clients and the grants, under keys of its own so a renamed
/// property never changes the file. Each grant holds its id, name, client, redirect host, options by their stable
/// keys, public host, created, last used, its refresh hash, the hash it replaced and when, and the earlier hashes
/// whose reuse ends it. Access tokens, refresh tokens in the clear and the tunnel token are never in it.
public struct RemoteAccessGrantFile: Equatable, Sendable {
    /// The version this release writes. A file with a later one is moved aside, as an unreadable one is.
    public static let version = 1

    public var clients: [RemoteAccessOAuth.Client]
    public var grants: [RemoteAccessOAuth.Grant]

    public init(clients: [RemoteAccessOAuth.Client], grants: [RemoteAccessOAuth.Grant]) {
        self.clients = clients
        self.grants = grants
    }

    public enum ReadError: Error, Equatable, Sendable {
        case unreadable
        case newer(Int)
    }

    public func encoded() throws -> Data {
        let clientRecords = clients.map(ClientRecord.init)
        let grantRecords = grants.map(GrantRecord.init)
        let document = Document(version: Self.version, clients: clientRecords, grants: grantRecords)
        return try RemoteAccessStore.encoder(pretty: true).encode(document)
    }

    public static func decoded(_ data: Data) throws -> RemoteAccessGrantFile {
        let decoder = RemoteAccessStore.decoder()
        guard let head = try? decoder.decode(Head.self, from: data), head.version >= 1 else {
            throw ReadError.unreadable
        }
        guard head.version <= version else { throw ReadError.newer(head.version) }
        guard let document = try? decoder.decode(Document.self, from: data) else { throw ReadError.unreadable }
        let clients = document.clients.map(\.client)
        let grants = document.grants.map(\.grant)
        return RemoteAccessGrantFile(clients: clients, grants: grants)
    }

    struct Head: Decodable {
        var version: Int
    }

    struct Document: Codable {
        var version: Int
        var clients: [ClientRecord]
        var grants: [GrantRecord]
    }

    struct ClientRecord: Codable {
        var id: String
        var name: String?
        var redirectURIs: [String]
        var registered: Date
        var lastUsed: Date

        enum CodingKeys: String, CodingKey {
            case id, name, registered
            case redirectURIs = "redirect_uris"
            case lastUsed = "last_used"
        }

        init(_ client: RemoteAccessOAuth.Client) {
            id = client.id
            name = client.name
            redirectURIs = client.redirectURIs
            registered = client.registered
            lastUsed = client.lastUsed
        }

        var client: RemoteAccessOAuth.Client {
            RemoteAccessOAuth.Client(id: id, name: name, redirectURIs: redirectURIs, registered: registered,
                                     lastUsed: lastUsed)
        }
    }

    struct GrantRecord: Codable {
        var id: String
        var name: String
        var clientID: String
        var clientName: String?
        var redirectHost: String
        var options: RemoteAccessOptions
        var host: String
        var created: Date
        var lastUsed: Date
        var refreshHash: String?
        var replacedHash: String?
        var replacedAt: Date?
        var earlierHashes: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, options, host, created
            case clientID = "client_id"
            case clientName = "client_name"
            case redirectHost = "redirect_host"
            case lastUsed = "last_used"
            case refreshHash = "refresh_hash"
            case replacedHash = "replaced_hash"
            case replacedAt = "replaced_at"
            case earlierHashes = "earlier_hashes"
        }

        init(_ grant: RemoteAccessOAuth.Grant) {
            id = grant.id
            name = grant.name
            clientID = grant.clientID
            clientName = grant.clientName
            redirectHost = grant.redirectHost
            options = grant.options
            host = grant.host
            created = grant.created
            lastUsed = grant.lastUsed
            refreshHash = grant.refreshHash
            replacedHash = grant.replacedHash
            replacedAt = grant.replacedAt
            earlierHashes = grant.earlierHashes
        }

        var grant: RemoteAccessOAuth.Grant {
            RemoteAccessOAuth.Grant(id: id, name: name, clientID: clientID, clientName: clientName,
                                    redirectHost: redirectHost, options: options, host: host, created: created,
                                    lastUsed: lastUsed, refreshHash: refreshHash, replacedHash: replacedHash,
                                    replacedAt: replacedAt, earlierHashes: earlierHashes)
        }
    }
}

/// Grants that survive a relaunch. The app holds one beside the OAuth authority, under the same lock.
///
/// Saving is synchronous and throws. A rotated refresh hash is saved before the token reply goes out, and new
/// options before they take effect (R60): build the grants with `replacing(_:in:)`, save, then apply. If the
/// save fails, nothing is applied, so the old refresh token stays current and the new pair is never sent.
///
/// Last used is kept in memory by the authority and changes on every use (a successful refresh or tool call).
/// `saveUse` writes it at most once an hour, counted from the last write, and `saveOnQuit` writes what is left.
public struct RemoteAccessGrantStore: Sendable {
    public static let fileName = "grants.json"
    /// Uses reach the file at most this often.
    public static let useSaveInterval: TimeInterval = 3600

    public let folder: URL
    /// When the file was last written or read, or a use's save last failed: the hour counts from here.
    public private(set) var lastWrite: Date?
    /// A use since then that the file does not hold.
    public private(set) var unsavedUse = false

    public init(folder: URL) {
        self.folder = folder
    }

    public var url: URL { folder.appendingPathComponent(Self.fileName) }

    /// What a launch starts from. `movedAside` is where an unreadable or newer file went; its clients pair again.
    public struct Loaded: Equatable, Sendable {
        public var clients: [RemoteAccessOAuth.Client]
        public var grants: [RemoteAccessOAuth.Grant]
        public var movedAside: URL?
    }

    /// Reads the file, setting the folder and file modes first when they are wrong. No file is an empty store.
    /// A file that can't be read, or that a later version wrote, is moved aside with the date in its name, and
    /// the store starts empty.
    public mutating func load(now: Date) -> Loaded {
        lastWrite = now
        unsavedUse = false
        let empty = Loaded(clients: [], grants: [], movedAside: nil)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        try? RemoteAccessStore.prepare(folder)
        try? RemoteAccessStore.fix(url.path, to: RemoteAccessStore.fileMode)
        if let data = try? Data(contentsOf: url), let file = try? RemoteAccessGrantFile.decoded(data) {
            return Loaded(clients: file.clients, grants: file.grants, movedAside: nil)
        }
        return Loaded(clients: [], grants: [], movedAside: moveAside(now: now))
    }

    /// Writes the clients and grants now: to a temp file, then renamed into place, `0600` in a `0700` folder.
    public mutating func save(clients: [RemoteAccessOAuth.Client], grants: [RemoteAccessOAuth.Grant],
                              now: Date) throws {
        let data = try RemoteAccessGrantFile(clients: clients, grants: grants).encoded()
        try RemoteAccessStore.prepare(folder)
        try RemoteAccessStore.replace(url, with: data)
        lastWrite = now
        unsavedUse = false
    }

    /// A grant was used, and the authority noted it. Writes only when an hour has passed since the last write,
    /// so a busy connection never writes on every call. True when it wrote. A failed write waits an hour too.
    @discardableResult
    public mutating func saveUse(clients: [RemoteAccessOAuth.Client], grants: [RemoteAccessOAuth.Grant],
                                 now: Date) throws -> Bool {
        unsavedUse = true
        if let lastWrite, now.timeIntervalSince(lastWrite) < Self.useSaveInterval { return false }
        do {
            try save(clients: clients, grants: grants, now: now)
        } catch {
            lastWrite = now
            throw error
        }
        return true
    }

    /// On quit: writes a use the file does not hold yet. True when it wrote.
    @discardableResult
    public mutating func saveOnQuit(clients: [RemoteAccessOAuth.Client], grants: [RemoteAccessOAuth.Grant],
                                    now: Date) throws -> Bool {
        guard unsavedUse else { return false }
        try save(clients: clients, grants: grants, now: now)
        return true
    }

    /// `grants` with `grant` in place of the one with its id: what to save before an issuance or an options
    /// change takes effect. A grant not in the list is added.
    public static func replacing(_ grant: RemoteAccessOAuth.Grant,
                                 in grants: [RemoteAccessOAuth.Grant]) -> [RemoteAccessOAuth.Grant] {
        guard let index = grants.firstIndex(where: { $0.id == grant.id }) else { return grants + [grant] }
        var replaced = grants
        replaced[index] = grant
        return replaced
    }

    /// Renames the file to `grants-<date>.json` (UTC), or `grants-<date>-2.json` and so on when that is taken.
    private func moveAside(now: Date) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let stem = "grants-\(day)-\(time)"
        for attempt in 1...100 {
            let name = attempt == 1 ? "\(stem).json" : "\(stem)-\(attempt).json"
            let aside = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: aside.path) else { continue }
            guard rename(url.path, aside.path) == 0 else { return nil }
            return aside
        }
        return nil
    }
}

// MARK: - audit lines

/// One line of the audit log (R39), as JSON with sorted keys and no line break inside. Every authenticated call,
/// allowed or refused, carries its grant id. Text that came from a client or a screen is masked first:
/// arguments are cut at 200 characters each, while remote `send_to_tab` text and what a remote `answer_agent`
/// approved are kept whole up to a cap (R27's 8,000 for the text), so no line comes near the reader's limit.
/// Controls and bidi marks are written as `\u{…}`, so a line shows as it is. Tokens, the `Authorization` header,
/// tool output and the tunnel token never appear: a result shows only its size and the start of its SHA-256.
public struct RemoteAccessAuditEntry: Codable, Equatable, Sendable {
    /// What happened to a call.
    public enum Decision: String, Codable, Sendable {
        /// It ran.
        case allowed
        /// The connection's options, a limit or a check refused it before it ran.
        case refused
        /// Declined on the Mac (R59).
        case declined
        /// It ran out of time, its grant ended mid-call, or the tool failed.
        case failed
    }

    public var time: Date
    /// `tool.call`, `requests.refused`, `remote.turned_off`, `tunnel.changed`, or an OAuth event's kind.
    public var event: String
    public var grant: String?
    public var grantName: String?
    public var client: String?
    public var clientName: String?
    public var tool: String?
    public var decision: Decision?
    public var reason: String?
    /// The stable keys of the options that left a call off, when an option did.
    public var refusedBy: [String]?
    public var durationMs: Int?
    /// The result's size in UTF-8 bytes.
    public var resultSize: Int?
    /// The first 12 hex characters of the result's SHA-256.
    public var resultSHA256: String?
    /// `Cf-Ray`, `CF-Connecting-IP` and `X-Forwarded-For`, as the tunnel sent them. No decision reads them (R7).
    public var ray: String?
    public var connectingIP: String?
    public var forwardedFor: String?
    /// Each argument as text, masked and cut at 200 characters. Two names that cut or mask alike each keep
    /// their value: the second is named with ` (2)` after it, and so on.
    public var arguments: [String: String]?
    /// Arguments past the first 50, by name, that the line leaves out.
    public var argumentsLeftOut: Int?
    /// Remote `send_to_tab` text, masked, and whole up to R27's 8,000 Unicode scalars. A longer one, which the
    /// door refuses, is cut to that, and `cut` says how long it was.
    public var text: String?
    /// The command or action a remote `answer_agent` approved on a permission prompt, masked, and whole up to
    /// `RemoteAccessAuditMask.approvedLength`.
    public var approved: String?
    /// A summary of refusals before a valid token: the kind, how many, the first Host or path, and since when.
    public var kind: String?
    public var count: Int?
    public var first: String?
    public var since: Date?
    /// The stable keys of the options that were on before and after a change, or at an approval.
    public var oldOptions: [String]?
    public var newOptions: [String]?
    /// Values an event lists: callbacks dropped at registration, or a client's redirect hosts.
    public var values: [String]?
    /// Anything else an event says, such as its pairing request or preset names.
    public var detail: [String: String]?
    /// The fields a cap cut short (`text`, `approved` or `reason`), each with how many Unicode scalars it held.
    public var cut: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case time, event, grant, client, tool, decision, reason, text, approved, kind, count, first, since, values,
             detail, arguments, cut
        case grantName = "grant_name"
        case clientName = "client_name"
        case refusedBy = "refused_by"
        case durationMs = "duration_ms"
        case resultSize = "result_size"
        case resultSHA256 = "result_sha256"
        case ray = "cf_ray"
        case connectingIP = "cf_connecting_ip"
        case forwardedFor = "x_forwarded_for"
        case argumentsLeftOut = "arguments_left_out"
        case oldOptions = "old"
        case newOptions = "new"
    }

    public init(time: Date, event: String) {
        self.time = time
        self.event = event
    }

    /// Reads one line back, as the activity view does.
    public init(line: Data) throws {
        self = try RemoteAccessStore.decoder().decode(Self.self, from: line)
    }

    /// The line to append: JSON and one line break.
    public func line() throws -> Data {
        var data = try RemoteAccessStore.encoder(pretty: false).encode(self)
        data.append(0x0A)
        return data
    }

    /// Arguments a line shows by name, at most.
    public static let maximumArguments = 50

    /// One authenticated call, allowed or refused. `arguments` are the call's as the client sent them; `result`
    /// is what was sent back, of which only the size and the hash are kept; `approved` is what a remote
    /// `answer_agent` approved on a permission prompt, as the prompt showed it.
    public static func call(time: Date, grant: RemoteAccessOAuth.Grant, tool: String, arguments: [String: Any]?,
                            decision: Decision, reason: String? = nil, refusedBy: [RemoteAccessOption.ID] = [],
                            duration: TimeInterval? = nil, result: String? = nil,
                            forwarded: RemoteAccessHTTP.Forwarded = RemoteAccessHTTP.Forwarded(),
                            approved: String? = nil) -> RemoteAccessAuditEntry {
        typealias Mask = RemoteAccessAuditMask
        var entry = RemoteAccessAuditEntry(time: time, event: "tool.call")
        var cut: [String: Int] = [:]
        /// Masked and capped, with the length noted when the cap cut it.
        func capped(_ value: String, _ field: String, limit: Int, lines: Bool) -> String {
            let shown = Mask.capped(value, limit: limit, lines: lines)
            if let length = shown.length { cut[field] = length }
            return shown.text
        }
        entry.grant = grant.id
        entry.grantName = Mask.cut(grant.name)
        entry.client = grant.clientID
        entry.clientName = grant.clientName.map(Mask.cut)
        entry.tool = Mask.cut(tool)
        entry.decision = decision
        entry.reason = reason.map { capped($0, "reason", limit: Mask.reasonLength, lines: false) }
        entry.refusedBy = refusedBy.isEmpty ? nil : refusedBy.map(\.rawValue)
        entry.durationMs = duration.map { Int(($0 * 1000).rounded()) }
        if let result {
            let bytes = Data(result.utf8)
            entry.resultSize = bytes.count
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            entry.resultSHA256 = String(digest.prefix(12))
        }
        entry.ray = forwarded.ray.map(Mask.cut)
        entry.connectingIP = forwarded.connectingIP.map(Mask.cut)
        entry.forwardedFor = forwarded.forwardedFor.map(Mask.cut)
        if var given = arguments {
            if tool == "send_to_tab", let text = given["text"] as? String {
                entry.text = capped(text, "text", limit: Mask.textLength, lines: true)
                given["text"] = nil
            }
            let names = given.keys.sorted()
            var shown: [String: String] = [:]
            for name in names.prefix(maximumArguments) {
                guard let value = given[name] else { continue }
                let cutName = Mask.cut(name)
                var key = cutName
                var copy = 1
                while shown[key] != nil {
                    copy += 1
                    key = "\(cutName) (\(copy))"
                }
                shown[key] = Mask.argument(value)
            }
            entry.arguments = shown
            let left = names.count - maximumArguments
            entry.argumentsLeftOut = left > 0 ? left : nil
        }
        entry.approved = approved.map { capped($0, "approved", limit: Mask.approvedLength, lines: true) }
        entry.cut = cut.isEmpty ? nil : cut
        return entry
    }

    /// The line for one of the OAuth authority's events: pairing steps, options changes, values dropped at
    /// registration, reuse and revokes.
    public static func event(_ event: RemoteAccessOAuth.Event, time: Date) -> RemoteAccessAuditEntry {
        typealias Mask = RemoteAccessAuditMask
        var entry = RemoteAccessAuditEntry(time: time, event: event.kind)
        switch event {
        case .clientRegistered(let clientID, let clientName, let redirectHosts):
            entry.client = clientID
            entry.clientName = clientName.map(Mask.cut)
            entry.values = redirectHosts.map(Mask.cut)
        case .registrationDropped(let clientID, let field, let values):
            entry.client = clientID
            entry.detail = ["field": Mask.cut(field)]
            entry.values = values.map(Mask.cut)
        case .pairingOpened(let until):
            entry.detail = ["until": RemoteAccessStore.timestamp(until)]
        case .pairingClosed(let reason):
            entry.reason = reason.rawValue
        case .pairingAsked(let request, let clientID, let clientName, let redirectHost):
            entry.client = clientID
            entry.clientName = clientName.map(Mask.cut)
            entry.detail = ["request": request, "redirect_host": Mask.cut(redirectHost)]
        case .pairingApproved(let request, let grantID, let name, let options):
            entry.grant = grantID
            entry.grantName = Mask.cut(name)
            entry.newOptions = keys(options)
            entry.detail = ["request": request, "preset": options.preset.rawValue]
        case .pairingDeclined(let request, let clientID), .pairingExpired(let request, let clientID):
            entry.client = clientID
            entry.detail = ["request": request]
        case .optionsChanged(let grantID, let name, let old, let new):
            entry.grant = grantID
            entry.grantName = Mask.cut(name)
            entry.oldOptions = keys(old)
            entry.newOptions = keys(new)
            entry.detail = ["old_preset": old.preset.rawValue, "new_preset": new.preset.rawValue]
        case .refreshReused(let grantID, let name), .codeReused(let grantID, let name):
            entry.grant = grantID
            entry.grantName = Mask.cut(name)
        case .revoked(let grantID, let name, let reason):
            entry.grant = grantID
            entry.grantName = Mask.cut(name)
            entry.reason = reason.rawValue
        case .accessTokensDropped:
            break
        }
        return entry
    }

    /// Turn Off, or Turn Off and Revoke All (the kill switch).
    public static func turnedOff(revokeAll: Bool, time: Date) -> RemoteAccessAuditEntry {
        var entry = RemoteAccessAuditEntry(time: time, event: "remote.turned_off")
        entry.reason = revokeAll ? "revoke_all" : "turn_off"
        return entry
    }

    /// The tunnel changed: started, ready, reconnecting, stopped, or its route changed.
    public static func tunnel(_ state: String, detail: String? = nil, time: Date) -> RemoteAccessAuditEntry {
        var entry = RemoteAccessAuditEntry(time: time, event: "tunnel.changed")
        entry.reason = RemoteAccessAuditMask.cut(state)
        if let detail { entry.detail = ["detail": RemoteAccessAuditMask.cut(detail)] }
        return entry
    }

    /// The stable keys of the options that are on, sorted.
    static func keys(_ options: RemoteAccessOptions) -> [String] {
        options.on.map(\.rawValue).sorted()
    }
}

/// How text is masked before it goes in a line. `MCPRedaction` is unchanged, so local results stay the same; the
/// door's own tokens are masked by a rule of the log's own, `nt(at|rt)_[A-Za-z0-9_-]+` in any case, and the same
/// with any of its characters percent-encoded after the prefix, as in `ntat%5F…`.
public enum RemoteAccessAuditMask {
    /// An argument is cut to this many Unicode scalars, in whole characters.
    public static let argumentLength = 200
    /// Remote `send_to_tab` text is kept whole up to R27's limit; a longer one, which the door refuses, is cut.
    public static let textLength = RemoteAccessLimits.sendText
    /// What a remote `answer_agent` approved is kept whole up to this many Unicode scalars, about the text of a
    /// whole 200-by-80 screen, which a prompt's box doesn't pass.
    public static let approvedLength = 16_000
    /// A reason is cut to this many: the door's own refusal texts are far shorter.
    public static let reasonLength = 1_000
    /// Text is read this far past its cap before it is masked and cut, so a 1 MB `write_file` costs no more than
    /// a short one. A secret that starts before the cut is read whole, so it is masked, not shown in part.
    static let readLength = 4000

    static let remoteToken = try! NSRegularExpression(
        pattern: #"nt(?:at|rt)(?:_|%5f)(?:[a-z0-9_\-]|%[0-9a-f]{2})+"#, options: [.caseInsensitive])

    /// The text with secrets masked as the door masks a result's screens and commands (`RemoteAccessPolicy.mask`
    /// with the command rules), so a password typed against a flag, such as `mysql -pS3cret`, is never logged in
    /// clear. The door's tokens go first, so no pattern of `MCPRedaction` can split one and leave part of it. When
    /// a pattern could not read the whole text, the text goes as one mask.
    public static func whole(_ text: String) -> String {
        RemoteAccessPolicy.mask(text, commands: true).text
    }

    /// Masked, cut to `argumentLength`, and on one line (see `visible`).
    public static func cut(_ text: String) -> String {
        let head = RemoteAccessOAuth.prefix(text, scalars: readLength)
        let masked = RemoteAccessOAuth.prefix(whole(head), scalars: argumentLength)
        return visible(masked, lines: false)
    }

    /// Masked, and whole when it holds at most `limit` Unicode scalars, however much masking lengthens it. A
    /// longer text is read only to `readLength` past the limit, masked, and cut to `limit`; `length` then says
    /// how many it held. With `lines`, its line breaks and tabs stay (see `visible`).
    static func capped(_ text: String, limit: Int, lines: Bool) -> (text: String, length: Int?) {
        let head = RemoteAccessOAuth.prefix(text, scalars: limit + readLength)
        guard head.unicodeScalars.count > limit else { return (visible(whole(head), lines: lines), nil) }
        let masked = RemoteAccessOAuth.prefix(whole(head), scalars: limit)
        return (visible(masked, lines: lines), text.unicodeScalars.count)
    }

    /// The text with each scalar that changes how the text around it shows written as `\u{…}` in hex: controls,
    /// format characters such as the bidi overrides and zero-width spaces, and line and paragraph separators.
    /// With `lines`, line feeds and tabs stay, as a typed text or a command has them. The zero-width joiner stays
    /// too, since emoji are made with it.
    static func visible(_ text: String, lines: Bool) -> String {
        guard text.unicodeScalars.contains(where: { hides($0, lines: lines) }) else { return text }
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard hides(scalar, lines: lines) else {
                shown.append(scalar)
                continue
            }
            let code = String(scalar.value, radix: 16, uppercase: true)
            shown.append(contentsOf: "\\u{\(code)}".unicodeScalars)
        }
        return String(shown)
    }

    static func hides(_ scalar: Unicode.Scalar, lines: Bool) -> Bool {
        if lines, scalar == "\n" || scalar == "\t" { return false }
        if scalar == "\u{200D}" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// An argument as text: a string as it is, a number or a boolean as JSON writes it, a list or an object as
    /// compact JSON; then masked and cut.
    static func argument(_ value: Any) -> String {
        if let text = value as? String { return cut(text) }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            if isBoolean { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value) else { return "(value)" }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "(value)" }
        return cut(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - refusals before a valid token

/// Requests refused before a valid token are counted per kind and written as one line a minute, so a flood
/// cannot push the real history out of the log (R39). The first refusal of a kind starts its minute; the line
/// holds the kind, the count and the first Host (for a wrong Host) or path. The door calls `due` on a timer
/// (`nextDue` says when) and `flush` when it closes.
public struct RemoteAccessRefusals: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// 421: the Host was not the public hostname.
        case wrongHost = "wrong_host"
        /// 400: a request that could not be read.
        case badRequest = "bad_request"
        /// 401: no token, or one that is not valid.
        case noToken = "no_token"
        /// 403: a request with an `Origin`.
        case origin
        /// 404: a path the door does not answer.
        case notFound = "not_found"
        /// 405: the wrong method.
        case badMethod = "bad_method"
        /// 413: a body over 1 MB.
        case bodyTooLarge = "body_too_large"
        /// 431: headers over 16 KB.
        case headersTooLarge = "headers_too_large"
        /// An OAuth request the authority refused.
        case badOAuth = "bad_oauth"

        /// The kind for a status the door refused with; nil for any other status.
        public init?(status: Int) {
            switch status {
            case 400: self = .badRequest
            case 401: self = .noToken
            case 403: self = .origin
            case 404: self = .notFound
            case 405: self = .badMethod
            case 413: self = .bodyTooLarge
            case 421: self = .wrongHost
            case 431: self = .headersTooLarge
            default: return nil
            }
        }
    }

    public static let interval: TimeInterval = 60

    struct Window: Sendable {
        var since: Date
        var count: Int
        var first: String
    }

    private var windows: [Kind: Window] = [:]

    public init() {}

    /// Counts one refusal. Returns the lines whose minute has ended, this kind's included, before this one
    /// starts a new minute.
    public mutating func count(_ kind: Kind, first hostOrPath: String, now: Date) -> [RemoteAccessAuditEntry] {
        let lines = due(now: now)
        if windows[kind] != nil {
            windows[kind]?.count += 1
        } else {
            windows[kind] = Window(since: now, count: 1, first: RemoteAccessAuditMask.cut(hostOrPath))
        }
        return lines
    }

    /// The lines whose minute has ended.
    public mutating func due(now: Date) -> [RemoteAccessAuditEntry] {
        take(now: now) { now.timeIntervalSince($0.since) >= Self.interval }
    }

    /// Every line, whether its minute has ended or not: Remote access is turning off.
    public mutating func flush(now: Date) -> [RemoteAccessAuditEntry] {
        take(now: now) { _ in true }
    }

    /// When the next line is due; nil while nothing is counted.
    public var nextDue: Date? {
        windows.values.map { $0.since.addingTimeInterval(Self.interval) }.min()
    }

    private mutating func take(now: Date, where ended: (Window) -> Bool) -> [RemoteAccessAuditEntry] {
        var lines: [RemoteAccessAuditEntry] = []
        for kind in Kind.allCases {
            guard let window = windows[kind], ended(window) else { continue }
            windows[kind] = nil
            var entry = RemoteAccessAuditEntry(time: now, event: "requests.refused")
            entry.kind = kind.rawValue
            entry.count = window.count
            entry.first = window.first
            entry.since = window.since
            lines.append(entry)
        }
        return lines
    }
}

// MARK: - rotation and retention

/// Which audit files to rotate, trim or delete: a new file once the current one would pass 10 MB, 5 files kept
/// (`audit.jsonl`, then `audit.1.jsonl` to `audit.4.jsonl`, older as the number grows), and entries older than 30
/// days dropped. A pure function of what the files hold; `RemoteAccessAuditLog` carries the steps out in order.
public enum RemoteAccessAuditRetention {
    public static let maximumFileSize = 10 * 1024 * 1024
    public static let filesKept = 5
    public static let maximumAge: TimeInterval = 30 * 24 * 3600

    /// An audit file: its number (0 for `audit.jsonl`), its size, and the times of its first and last entries
    /// when they can be read.
    public struct File: Equatable, Sendable {
        public var index: Int
        public var size: Int
        public var oldest: Date?
        public var newest: Date?

        public init(index: Int, size: Int, oldest: Date? = nil, newest: Date? = nil) {
            self.index = index
            self.size = size
            self.oldest = oldest
            self.newest = newest
        }
    }

    public enum Step: Equatable, Sendable {
        case delete(Int)
        /// Rewrite the file without its entries from before the date.
        case trim(Int, before: Date)
        /// Rename the file to the next number.
        case move(Int, to: Int)
    }

    public static func fileName(_ index: Int) -> String {
        index == 0 ? "audit.jsonl" : "audit.\(index).jsonl"
    }

    /// The steps before `bytes` are appended to `audit.jsonl`, in the order to take them: deletes, trims, then the
    /// moves of a rotation, the oldest file first. A file past the fifth goes, and so does one whose last entry
    /// is older than 30 days; one whose first entry is that old is trimmed. The current file rotates when the
    /// line would take it past the limit, unless it is empty; the fifth file then goes.
    public static func plan(_ files: [File], appending bytes: Int, now: Date,
                            maximumFileSize: Int = maximumFileSize) -> [Step] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let last = filesKept - 1
        var deleted = Set<Int>()
        for file in files {
            let aged = file.newest.map { $0 < cutoff } ?? false
            if file.index > last || aged { deleted.insert(file.index) }
        }
        let current = files.first { $0.index == 0 && !deleted.contains(0) }
        let rotates = current.map { $0.size > 0 && $0.size + bytes > maximumFileSize } ?? false
        if rotates, files.contains(where: { $0.index == last }) { deleted.insert(last) }

        var steps = deleted.sorted().map { Step.delete($0) }
        let sorted = files.sorted { $0.index < $1.index }
        for file in sorted where !deleted.contains(file.index) {
            guard let oldest = file.oldest, oldest < cutoff else { continue }
            steps.append(.trim(file.index, before: cutoff))
        }
        guard rotates else { return steps }
        let moving = sorted.map(\.index).filter { !deleted.contains($0) && $0 < last }
        for index in moving.reversed() { steps.append(.move(index, to: index + 1)) }
        return steps
    }
}

/// The audit log's files: appends lines, rotates and drops old entries as `RemoteAccessAuditRetention` plans,
/// and reads the last entries back for the activity view. Ages are checked by `prune`, which the app calls at
/// launch, and by `append` and `tail` when an hour has passed since the last check; the size on every append.
public struct RemoteAccessAuditLog: Sendable {
    /// Entries the activity view shows.
    public static let tailCount = 500
    static let pruneInterval: TimeInterval = 3600
    /// Files are read in blocks of this size, from the start for a first entry and from the end for the rest.
    static let block = 64 * 1024
    /// How far into a file its first entry is looked for: past one line too long to read, and a little more.
    static let firstReach = 2 * 1024 * 1024 + 64 * 1024
    /// A line longer than this, in bytes, is skipped when read back and dropped by a trim. The caps on what a
    /// line holds keep every line the log writes well under it.
    static let maximumLine = 1024 * 1024

    public let folder: URL
    public let maximumFileSize: Int
    private var lastPrune: Date?

    public init(folder: URL, maximumFileSize: Int = RemoteAccessAuditRetention.maximumFileSize) {
        self.folder = folder
        self.maximumFileSize = maximumFileSize
    }

    func url(_ index: Int) -> URL {
        folder.appendingPathComponent(RemoteAccessAuditRetention.fileName(index))
    }

    public mutating func append(_ entry: RemoteAccessAuditEntry, now: Date) throws {
        try append([entry], now: now)
    }

    /// Appends the lines to `audit.jsonl`, `0600` in a `0700` folder, after any rotation or trim they call for.
    public mutating func append(_ entries: [RemoteAccessAuditEntry], now: Date) throws {
        guard !entries.isEmpty else { return }
        var data = Data()
        for entry in entries { data.append(try entry.line()) }
        try RemoteAccessStore.prepare(folder)
        let current = url(0)
        let size = Self.size(current)
        let pruneDue = isPruneDue(now)
        let rotates = size > 0 && size + data.count > maximumFileSize
        if pruneDue || rotates {
            try retain(appending: data.count, withTimes: pruneDue, now: now)
        }
        try Self.appendBytes(data, to: current)
    }

    /// Drops the entries older than 30 days, and any file past the fifth, now. The app calls it at launch, so old
    /// entries go while Remote access stays off. With no folder it makes none.
    public mutating func prune(now: Date) throws {
        try retain(appending: 0, withTimes: true, now: now)
    }

    /// The last `count` entries of the last 30 days, oldest first, from `audit.jsonl` and then the older files.
    /// When an hour has passed since the last check, older entries are dropped first; between checks they are
    /// left out. Lines that can't be read, such as one a crash cut short, are skipped.
    public mutating func tail(_ count: Int = RemoteAccessAuditLog.tailCount, now: Date) -> [RemoteAccessAuditEntry] {
        if isPruneDue(now) { try? prune(now: now) }
        let cutoff = now.addingTimeInterval(-RemoteAccessAuditRetention.maximumAge)
        var found: [RemoteAccessAuditEntry] = []
        for index in 0..<RemoteAccessAuditRetention.filesKept where found.count < count {
            found += Self.lastEntries(of: url(index), count: count - found.count)
        }
        return found.filter { $0.time >= cutoff }.reversed()
    }

    private func isPruneDue(_ now: Date) -> Bool {
        lastPrune.map { now.timeIntervalSince($0) >= Self.pruneInterval } ?? true
    }

    /// Carries out what retention plans before `bytes` are appended; with `withTimes`, the ages too.
    private mutating func retain(appending bytes: Int, withTimes: Bool, now: Date) throws {
        let files = describe(withTimes: withTimes)
        let steps = RemoteAccessAuditRetention.plan(files, appending: bytes, now: now,
                                                     maximumFileSize: maximumFileSize)
        try carryOut(steps)
        if withTimes { lastPrune = now }
    }

    /// Clear Log: every audit file goes.
    public func clear() throws {
        for (_, name) in auditFiles() {
            let path = folder.appendingPathComponent(name).path
            guard unlink(path) == 0 || errno == ENOENT else { throw RemoteAccessStoreError.last(path) }
        }
    }

    // MARK: files

    /// The audit files in the folder, by number.
    private func auditFiles() -> [(Int, String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [(Int, String)] = []
        for name in names {
            guard name.hasPrefix("audit."), name.hasSuffix(".jsonl") else { continue }
            if name == "audit.jsonl" {
                files.append((0, name))
                continue
            }
            let middle = name.dropFirst("audit.".count).dropLast(".jsonl".count)
            guard let index = Int(middle), index > 0, String(index) == middle else { continue }
            files.append((index, name))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// Each audit file's size and, when asked, the times of its first and last entries.
    private func describe(withTimes: Bool) -> [RemoteAccessAuditRetention.File] {
        auditFiles().map { index, name in
            let file = folder.appendingPathComponent(name)
            var described = RemoteAccessAuditRetention.File(index: index, size: Self.size(file))
            if withTimes {
                described.oldest = Self.firstTime(of: file)
                described.newest = Self.lastEntries(of: file, count: 1, skipping: false).first?.time
            }
            return described
        }
    }

    private func carryOut(_ steps: [RemoteAccessAuditRetention.Step]) throws {
        for step in steps {
            switch step {
            case .delete(let index):
                let path = url(index).path
                guard unlink(path) == 0 || errno == ENOENT else { throw RemoteAccessStoreError.last(path) }
            case .trim(let index, let before):
                try trim(url(index), before: before)
            case .move(let index, let next):
                // A trim that left nothing has deleted the file already.
                let from = url(index).path
                guard rename(from, url(next).path) == 0 || errno == ENOENT else {
                    throw RemoteAccessStoreError.last(from)
                }
            }
        }
    }

    /// Rewrites a file with only its entries from `before` on, through a temp file; a file left empty goes. Lines
    /// that can't be read, or that are longer than `maximumLine`, go too.
    private func trim(_ file: URL, before: Date) throws {
        guard let data = try? Data(contentsOf: file) else { return }
        var kept = Data()
        for line in data.split(separator: 0x0A) {
            guard line.count <= Self.maximumLine else { continue }
            guard let stamp = Self.stamp(Data(line)), stamp >= before else { continue }
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        if kept.isEmpty {
            guard unlink(file.path) == 0 || errno == ENOENT else { throw RemoteAccessStoreError.last(file.path) }
            return
        }
        try RemoteAccessStore.replace(file, with: kept)
    }

    static func size(_ file: URL) -> Int {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return 0 }
        return Int(info.st_size)
    }

    /// Appends to the file, made `0600` if it is new or found otherwise. A link is never followed. A line a crash
    /// cut short gets its line break first, so the new line stays whole.
    static func appendBytes(_ data: Data, to file: URL) throws {
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let descriptor = open(file.path, flags, RemoteAccessStore.fileMode)
        guard descriptor >= 0 else { throw RemoteAccessStoreError.last(file.path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RemoteAccessStoreError.last(file.path) }
        if info.st_mode & 0o7777 != RemoteAccessStore.fileMode {
            guard fchmod(descriptor, RemoteAccessStore.fileMode) == 0 else {
                throw RemoteAccessStoreError.last(file.path)
            }
        }
        var bytes = data
        if info.st_size > 0 {
            var lastByte: UInt8 = 0
            let read = pread(descriptor, &lastByte, 1, info.st_size - 1)
            if read == 1, lastByte != 0x0A { bytes.insert(0x0A, at: bytes.startIndex) }
        }
        try RemoteAccessStore.writeAll(descriptor, bytes, path: file.path)
    }

    /// Only an entry's time, for retention.
    struct Stamp: Decodable {
        var time: Date
    }

    static func stamp(_ line: Data) -> Date? {
        (try? RemoteAccessStore.decoder().decode(Stamp.self, from: line))?.time
    }

    /// The time of the file's first entry: the first line that can be read, read forwards a block at a time. A
    /// line before it that can't be read, such as one a crash cut short, or that is longer than `maximumLine`, is
    /// passed over, so a trim still finds the file and drops that line. It reads no further than `firstReach`.
    static func firstTime(of file: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        // True while the line being read has passed `maximumLine`: the rest of it is passed over.
        var overlong = false
        var reached = 0
        while reached < firstReach {
            guard let read = try? handle.read(upToCount: block), !read.isEmpty else { return nil }
            reached += read.count
            var start = read.startIndex
            while let end = read[start...].firstIndex(of: 0x0A) {
                if !overlong {
                    line.append(read[start..<end])
                    if line.count <= maximumLine, let time = stamp(line) { return time }
                }
                line = Data()
                overlong = false
                start = read.index(after: end)
            }
            guard !overlong else { continue }
            line.append(read[start...])
            if line.count > maximumLine {
                line = Data()
                overlong = true
            }
        }
        return nil
    }

    /// The last `count` entries that can be read, newest first, read backwards a block at a time. A line
    /// longer than `maximumLine` is skipped. With `skipping` false it stops at the first whole line, whether it
    /// can be read or not, so a file of junk costs one line.
    static func lastEntries(of file: URL, count: Int, skipping: Bool = true) -> [RemoteAccessAuditEntry] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return [] }
        var entries: [RemoteAccessAuditEntry] = []
        // The end of a line whose start is in a block not read yet.
        var carry = Data()
        var overlong = false
        while offset > 0 && entries.count < count {
            let length = min(UInt64(block), offset)
            offset -= length
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let read = try? handle.read(upToCount: Int(length)) else { break }
            var pieces = (read + carry).split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = Data()
            if overlong {
                // The last piece is the start of the line too long to read.
                pieces.removeLast()
                guard !pieces.isEmpty else { continue }
                overlong = false
            }
            if offset > 0 { carry = Data(pieces.removeFirst()) }
            for piece in pieces.reversed() where !piece.isEmpty {
                var entry: RemoteAccessAuditEntry?
                if piece.count <= maximumLine { entry = try? RemoteAccessAuditEntry(line: Data(piece)) }
                if let entry { entries.append(entry) }
                if !skipping { return entries }
                if entries.count == count { return entries }
            }
            if carry.count > maximumLine {
                if !skipping { return entries }
                carry = Data()
                overlong = true
            }
        }
        return entries
    }
}
