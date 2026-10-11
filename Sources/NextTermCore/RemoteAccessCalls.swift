import Foundation

/// The Remote access door's open tool calls (U7): each call from when its rate-limit slot is taken until its answer
/// goes out, so that every call is answered exactly once:
/// - with its result, shaped by the door, when the Mac answers in time;
/// - with "Access was turned off on the Mac." at once when its grant is revoked or Remote access turns off, and its
///   connection then closes (R37, R38);
/// - with the deadline text 100 seconds after it came, when the Mac has not answered (R25).
///
/// A result that comes after its call was answered is dropped. It still gives its rate-limit slot back, since the
/// tool ran on the Mac until then; a call answered before it ran gives its slot back at once.
///
/// The registry has its own lock. Every revoke path goes through the OAuth authority's lock and then this one
/// (KTD15): a revoke on the Mac, Revoke All, the kill switch, refresh reuse, a reused code and `/oauth/revoke`.
/// Just before a call runs, on the main thread, the door reads the grant from the authority under its lock and
/// hands it to `begin`, still under it. So a call either ran before a revoke, and the revoke answers it, or is judged
/// after it, and `begin` refuses it.
///
/// It also keeps the list-changed mark per grant (R20): the next tool call for that grant answered as a stream sends
/// `notifications/tools/list_changed` first.
///
/// The clock is passed in, so the deadline is tested without waiting. Answers run outside the lock, on whatever
/// thread ended the call, so an answer never calls back into the registry under its lock.
public final class RemoteAccessCalls: @unchecked Sendable { // its state lives under `lock`
    /// Every tool call is answered within this many seconds (R25).
    public static let deadline: TimeInterval = 100
    /// A stream sends a keep-alive comment this often while its call runs, well under Cloudflare's 125 seconds.
    public static let keepAlive: TimeInterval = 20
    /// A call answered before its result came gives its slot back when the result comes, or this long after its
    /// answer if it never does (at the next call that opens or the next expire), so a tool that never answers
    /// cannot hold a grant's slots for good.
    public static let abandon: TimeInterval = 300

    public typealias ID = UInt64

    /// How a call ended.
    public enum Ending: Sendable {
        /// The Mac answered in time. The door shapes it before it goes out.
        case result(MCPServer.CallResult)
        /// Its grant was revoked, or Remote access turned off: the connection closes after the answer.
        case turnedOff
        /// The Mac did not answer within the deadline.
        case deadline

        /// What the client gets: the result, or the text as an error result.
        public var callResult: MCPServer.CallResult {
            switch self {
            case .result(let result): return result
            case .turnedOff: return MCPServer.CallResult(text: RemoteAccessText.turnedOff, isError: true)
            case .deadline: return MCPServer.CallResult(text: RemoteAccessText.deadline, isError: true)
            }
        }

        /// The connection closes after this answer (R38).
        public var closesConnection: Bool {
            if case .turnedOff = self { return true }
            return false
        }

        /// The audit line's decision: allowed when it ran and answered, failed when its time or its grant ran out.
        public var decision: RemoteAccessAuditEntry.Decision {
            if case .result = self { return .allowed }
            return .failed
        }
    }

    /// What opening a call gives.
    public enum Opened: Equatable, Sendable {
        /// It is registered. `listChanged`: send `notifications/tools/list_changed` first on its stream.
        case call(ID, listChanged: Bool)
        /// R27's limits: answer with `RemoteAccessText.tooManyCalls`. It took no slot.
        case tooMany
        /// Remote access turned off: answer with `RemoteAccessText.turnedOff` and close.
        case closed
    }

    /// What the check just before a call runs gives.
    public enum Began: Equatable, Sendable {
        /// Run it, under this grant's options as they are now (R60).
        case run(RemoteAccessOAuth.Grant)
        /// Its grant ended, or Remote access turned off, before the check: it was answered with the revoke text
        /// now. Run nothing.
        case refused
        /// It was answered already (a revoke, a turn-off or the deadline), or it runs already. Run nothing.
        case ended
    }

    private struct Call {
        let grant: String
        let connection: UInt64
        let slot: RemoteAccessRateLimiter.Slot
        let opened: Date
        var answer: (@Sendable (Ending) -> Void)?
        /// The main thread began it: a result will come.
        var ran = false
        /// When it was answered without its result: a revoke, a turn-off or the deadline.
        var ended: Date?
        var slotHeld = true
    }

    public let deadline: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var limiter = RemoteAccessRateLimiter()
    private var calls: [ID: Call] = [:]
    private var lastID: ID = 0
    private var listChanged: Set<String> = []
    private var off = false

    public init(deadline: TimeInterval = RemoteAccessCalls.deadline,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.deadline = deadline
        self.clock = clock
    }

    // MARK: a call's life

    /// Takes a slot and registers a call from `grant` on `connection`, answered by `answer` exactly once. With
    /// `streamed`, it takes the grant's list-changed mark: the door then sends the notification as the stream's
    /// first event. A call answered as JSON leaves the mark for a later stream.
    public func open(grant: String, connection: UInt64, streamed: Bool,
                     answer: @escaping @Sendable (Ending) -> Void) -> Opened {
        lock.lock()
        defer { lock.unlock() }
        guard !off else { return .closed }
        let now = clock()
        prune(now)
        guard let slot = limiter.acquire(grant: grant, now: now) else { return .tooMany }
        lastID += 1
        calls[lastID] = Call(grant: grant, connection: connection, slot: slot, opened: now, answer: answer)
        let changed = streamed && listChanged.remove(grant) != nil
        return .call(lastID, listChanged: changed)
    }

    /// The check just before the call runs, on the main thread, with the grant the door read from the authority
    /// under its lock: nil when it ended, or when Remote access is off. Call it while still holding that lock.
    public func begin(_ id: ID, grant: RemoteAccessOAuth.Grant?) -> Began {
        lock.lock()
        guard var call = calls[id], call.ended == nil, !call.ran else {
            lock.unlock()
            return .ended
        }
        guard !off, let grant, grant.id == call.grant else {
            let answer = end(id, at: clock())
            lock.unlock()
            answer?(.turnedOff)
            return .refused
        }
        call.ran = true
        calls[id] = call
        lock.unlock()
        return .run(grant)
    }

    /// The tool's result. It answers the call when it is still open, and gives its slot back either way. False
    /// when it was dropped: the call was answered already, or is unknown.
    @discardableResult
    public func finish(_ id: ID, _ result: MCPServer.CallResult) -> Bool {
        lock.lock()
        guard let call = calls.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        if call.slotHeld { limiter.release(call.slot) }
        lock.unlock()
        guard call.ended == nil, let answer = call.answer else { return false }
        answer(.result(result))
        return true
    }

    /// Answers every open call of these grants with the revoke text at once, and drops their late results (R38).
    /// It clears their list-changed marks. Returns how many it answered.
    @discardableResult
    public func revoke(grants: [String]) -> Int {
        let ended = Set(grants)
        lock.lock()
        listChanged.subtract(ended)
        let now = clock()
        let ids = calls.filter { ended.contains($0.value.grant) && $0.value.ended == nil }.keys
        let answers = ids.sorted().compactMap { end($0, at: now) }
        lock.unlock()
        for answer in answers { answer(.turnedOff) }
        return answers.count
    }

    /// Turned off, or quitting (R37, R42): every open call is answered with the revoke text, and no call opens
    /// after it. Returns how many it answered.
    @discardableResult
    public func turnOff() -> Int {
        lock.lock()
        off = true
        listChanged.removeAll()
        let now = clock()
        let ids = calls.filter { $0.value.ended == nil }.keys
        let answers = ids.sorted().compactMap { end($0, at: now) }
        lock.unlock()
        for answer in answers { answer(.turnedOff) }
        return answers.count
    }

    /// Answers each call that has waited `deadline` seconds with the deadline text, and gives back the slot of a
    /// call answered `abandon` seconds ago whose result never came. The door runs it at each call's deadline.
    /// Returns how many it answered.
    @discardableResult
    public func expire() -> Int {
        lock.lock()
        let now = clock()
        prune(now)
        let due = calls.filter { $0.value.ended == nil && now.timeIntervalSince($0.value.opened) >= deadline }.keys
        let answers = due.sorted().compactMap { end($0, at: now) }
        lock.unlock()
        for answer in answers { answer(.deadline) }
        return answers.count
    }

    /// Gives back the slot of each call answered `abandon` seconds ago whose result never came, and forgets it.
    /// Call it under the lock.
    private func prune(_ now: Date) {
        for (id, call) in calls {
            guard let ended = call.ended, now.timeIntervalSince(ended) >= Self.abandon else { continue }
            if call.slotHeld { limiter.release(call.slot) }
            calls[id] = nil
        }
    }

    /// Marks the call answered without its result and hands back its answer, to run after the lock. A call that
    /// never ran gives its slot back now, since no result will come. Call it under the lock.
    private func end(_ id: ID, at now: Date) -> (@Sendable (Ending) -> Void)? {
        guard var call = calls[id], call.ended == nil else { return nil }
        let answer = call.answer
        call.answer = nil
        call.ended = now
        if !call.ran, call.slotHeld {
            limiter.release(call.slot)
            call.slotHeld = false
        }
        calls[id] = call
        return answer
    }

    // MARK: list changed

    /// The grant's options changed on the Mac (R60): its next streamed call sends the notification first.
    public func markListChanged(_ grant: String) {
        lock.lock()
        listChanged.insert(grant)
        lock.unlock()
    }

    /// A `tools/list` from the grant: the client has the new list, so the mark goes.
    public func clearListChanged(_ grant: String) {
        lock.lock()
        listChanged.remove(grant)
        lock.unlock()
    }

    // MARK: state

    /// Slots taken: calls running, on the Mac or on their way to it.
    public var running: Int {
        lock.lock()
        defer { lock.unlock() }
        return limiter.runningCount
    }

    /// Calls not answered yet.
    public var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.values.filter { $0.ended == nil }.count
    }

    /// Turned off: no call opens.
    public var isOff: Bool {
        lock.lock()
        defer { lock.unlock() }
        return off
    }

    // MARK: messages

    /// One POST to `/mcp`, as the door reads it (KTD10): no session, one message per request.
    public enum Incoming {
        /// `tools/call`, with its tool's name ("" when there is none) and its arguments.
        case call(id: Any, name: String, arguments: [String: Any])
        /// Any other request, for `MCPServer.respond`.
        case request([String: Any])
        /// A notification, or a response from the client: 202, no body.
        case notification
        /// A JSON-RPC batch: 400.
        case batch
        /// Not a JSON object: 400.
        case invalid
        /// An `MCP-Protocol-Version` the server does not speak: 400.
        case badVersion

        /// The status to answer with and no body, or nil for a message the door answers with JSON-RPC.
        public var status: Int? {
            switch self {
            case .call, .request: return nil
            case .notification: return 202
            case .batch, .invalid, .badVersion: return 400
            }
        }
    }

    /// Reads a request's body. `protocolVersion` is its `MCP-Protocol-Version` header: when sent, it must be one
    /// of `MCPServer.supportedVersions`.
    public static func read(_ body: Data, protocolVersion: String?) -> Incoming {
        if let protocolVersion, !MCPServer.supportedVersions.contains(protocolVersion) { return .badVersion }
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else { return .invalid }
        if parsed is [Any] { return .batch }
        guard let message = parsed as? [String: Any] else { return .invalid }
        guard let method = message["method"] as? String else { return .notification }
        guard let id = message["id"], !(id is NSNull) else { return .notification }
        guard method == "tools/call" else { return .request(message) }
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return .call(id: id, name: name, arguments: arguments)
    }

    /// A tool call's answer: the envelope `MCPServer.respond` gives for the same result.
    public static func result(id: Any, _ result: MCPServer.CallResult) -> Data {
        var content: [String: Any] = [:]
        content["type"] = "text"
        content["text"] = result.text
        var body: [String: Any] = [:]
        body["content"] = [content]
        body["isError"] = result.isError
        var message: [String: Any] = [:]
        message["jsonrpc"] = "2.0"
        message["id"] = id
        message["result"] = body
        return encode(message)
    }

    /// A JSON-RPC error, such as -32602 for invalid params.
    public static func error(id: Any, code: Int, message text: String) -> Data {
        var error: [String: Any] = [:]
        error["code"] = code
        error["message"] = text
        var message: [String: Any] = [:]
        message["jsonrpc"] = "2.0"
        message["id"] = id
        message["error"] = error
        return encode(message)
    }

    /// `notifications/tools/list_changed`.
    public static let listChangedNotification: Data = {
        var message: [String: Any] = [:]
        message["jsonrpc"] = "2.0"
        message["method"] = "notifications/tools/list_changed"
        return encode(message)
    }()

    /// The start of a tool call's stream: its head, then the list-changed event when the grant's list changed.
    public static func streamStart(listChanged: Bool) -> Data {
        let head = RemoteAccessHTTP.streamHead()
        guard listChanged else { return head }
        return head + RemoteAccessHTTP.event(listChangedNotification)
    }

    /// A message as compact JSON with slashes as they are, as `nxtrm mcp` writes it.
    public static func encode(_ message: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(message) else { return Data("{}".utf8) }
        let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        return data ?? Data("{}".utf8)
    }

    // MARK: the MCPControl binding

    /// The approval policy the door passes to `MCPControl.call` (R56, R59): `askOnMac` while "Ask on this Mac
    /// before changes" is on, the grant's own pre-approval while it is off.
    public static func approval(for grant: RemoteAccessOAuth.Grant) -> MCPApproval {
        grant.options[.askOnMac] ? .askOnMac : .preApprovedByGrant(grant.id)
    }

    /// Who asks, as the approval window names it: "the connection “Claude, phone”".
    public static func requester(for grant: RemoteAccessOAuth.Grant) -> String {
        "the connection “\(grant.name)”"
    }

    /// The options the audit line of a refused call names: the first of each half the tool needs that has none on
    /// (`RemoteAccessPolicy.needs`). None for a tool the options admit, or one no option names.
    public static func refusedBy(_ tool: String, options: RemoteAccessOptions) -> [RemoteAccessOption.ID] {
        let halves = RemoteAccessPolicy.needs(tool)
        let missing = halves.filter { half in !half.contains { options[$0] } }
        return missing.compactMap(\.first)
    }
}
