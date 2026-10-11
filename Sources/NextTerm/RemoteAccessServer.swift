import Foundation
import Network
import NextTermCore

/// Remote access's door (U7): MCP Streamable HTTP at `/mcp` and Next Term's OAuth routes, on `127.0.0.1` at the
/// saved port and nowhere else (R2). The tunnel forwards to it; nothing else may reach it.
///
/// Each connection is read by the Core parser (`RemoteAccessHTTP`), one request at a time, answered in order, with
/// 10 seconds for a head (a new connection's first one counted from when it opened), 30 seconds for a body, and 30
/// seconds idle between requests. At 64 connections, the oldest one with no request in hand gives way to a new one,
/// so silent or slow connections can't keep the tunnel out. Every request passes the checks in order (Host, Origin,
/// path, method); a refusal goes out with no body and the connection closes. Until a host is saved, every request
/// gets 421.
///
/// A tool call runs through the same engine as `nxtrm mcp` (`MCPControl.call`), as a caller outside Next Term's tabs
/// (R3). Its life is `RemoteAccessCalls`': it is registered before the hop to the main thread, its grant is read again
/// there under the authority's lock just before it runs (KTD15), and it is answered exactly once: with its masked and
/// capped result, with the main thread's refusal, with the revoke text at once when its grant ends, or with the
/// deadline text after 100 seconds. Every call counts toward its grant's 120 a minute, refused ones too, and the
/// audit lines of calls past the limits are summed (R27, R39).
///
/// Logic is in Core (U1 to U5, `RemoteAccessCalls`, `RemoteAccessDoorState`); this file holds the sockets and the
/// binding to MCPControl.
final class RemoteAccessServer: @unchecked Sendable { // connections live on `queue`; the authority under `state`'s lock
    /// The door's timings. Only a debug build under `--self-test` may shorten them (U12), so the release build
    /// always answers with the plan's values.
    struct Timings: Equatable, Sendable {
        /// A stream's keep-alive comment (R25).
        var keepAlive = RemoteAccessCalls.keepAlive
        /// Every tool call is answered within this (R25).
        var deadline = RemoteAccessCalls.deadline
        /// The longest remote `wait_for_tab`, in seconds (R24).
        var wait = RemoteAccessLimits.waitSeconds

        static let standard = Timings()

        #if DEBUG
        /// What U12 sets before it starts the door, read only under `--self-test`.
        nonisolated(unsafe) static var selfTest: Timings?
        #endif

        /// The timings a door starts with.
        static var current: Timings {
            #if DEBUG
            if SelfTest.isRequested, let shortened = selfTest { return shortened }
            #endif
            return .standard
        }
    }

    enum StartError: Error, Equatable, CustomStringConvertible {
        /// R2: the saved port is taken. Remote access stays off; no other port is tried.
        case portInUse(UInt16)
        case failed(String)

        var description: String {
            switch self {
            case .portInUse(let port): return "Port \(port) is in use"
            case .failed(let reason): return "The door could not start: \(reason)"
            }
        }
    }

    /// At most this many connections at once. One more takes the place of the oldest with no request in hand.
    static let maximumConnections = 64
    /// How late a call's deadline timer may fire, at most.
    static let deadlineLeeway = DispatchTimeInterval.milliseconds(100)

    let port: UInt16
    let state: RemoteAccessDoorState
    let timings: Timings
    var calls: RemoteAccessCalls { state.calls }
    /// The listener failed after it started (U9 turns Remote access off). Called on the main thread.
    var onFailure: (@MainActor () -> Void)?

    private let version: String
    private let queue = DispatchQueue(label: "nextterm.remote-access.door")
    private var listener: NWListener?
    private var connections: [UInt64: Connection] = [:]
    private var lastConnection: UInt64 = 0
    private var ticks: DispatchSourceTimer?
    /// Each open call's own deadline (R25), by its id.
    private var deadlines: [RemoteAccessCalls.ID: DispatchSourceTimer] = [:]
    private var stopped = false

    /// A door on `state`, made by `RemoteAccessDoorState.forDoor` so its registry has the door's deadline. The
    /// approval windows of a grant that ends close with it (`RemoteAccessApprovals`).
    init(port: UInt16, state: RemoteAccessDoorState) {
        self.port = port
        self.state = state
        self.timings = Timings.current
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        state.onGrantsEnded = { grants in RemoteAccessApprovals.close(grants: Set(grants)) }
    }

    // MARK: start and stop

    /// Binds `127.0.0.1:<port>` and waits up to a second for it. A port another process holds throws `portInUse`
    /// (AE9); the caller starts no tunnel then.
    func start() throws {
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw StartError.failed("no port") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.failed("\(error)")
        }
        let outcome = StartOutcome()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                outcome.settle(nil)
            case .failed(let error), .waiting(let error):
                let started = outcome.settle(Self.startError(error, port: self?.port ?? 0))
                if started { self?.listenerFailed() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard outcome.ready.wait(timeout: .now() + 1) == .success else {
            listener.cancel()
            throw StartError.failed("the listener did not start in time")
        }
        if let error = outcome.error {
            listener.cancel()
            throw error
        }
        queue.sync {
            self.listener = listener
            startTicks()
        }
    }

    /// Turns the door off within a second (R37): no new connection, every open call answered with the revoke text,
    /// access tokens dropped (every grant ended too with `revokeAll`), the approval windows remote calls opened
    /// and the pairing window closed, then every connection closed. Call it from the main thread, and never inside `state.update {}`: it
    /// waits on the door's queue, which may be waiting for the state's lock. It can be called again; it does
    /// nothing then.
    func stop(revokeAll: Bool = false) {
        let first = queue.sync { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            listener?.cancel()
            listener = nil
            ticks?.cancel()
            ticks = nil
            return true
        }
        guard first else { return }
        // The authority's lock, then the registry: every open call's answer is on the door's queue after this.
        state.turnOff(revokeAll: revokeAll)
        let state = self.state
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                RemoteAccessApprovals.close(grants: nil)
                RemoteAccessPairingWindow.close(for: state)
            }
        } else {
            DispatchQueue.main.async {
                RemoteAccessApprovals.close(grants: nil)
                RemoteAccessPairingWindow.close(for: state)
            }
        }
        queue.async {
            for timer in self.deadlines.values { timer.cancel() }
            self.deadlines.removeAll()
            // A connection waiting for its call closes once that answer is out (`deliver`); the others close now.
            for connection in self.connections.values where !connection.busy { self.finish(connection) }
        }
        queue.asyncAfter(deadline: .now() + 0.8) {
            for connection in self.connections.values { self.close(connection) }
        }
    }

    var isRunning: Bool { queue.sync { listener != nil && !stopped } }

    /// Waits until what the door's queue holds now has run: at quit, so the answers `stop` queued are handed to
    /// their connections before the process ends (U9). Never inside `state.update {}`, as for `stop`.
    func drain() { queue.sync {} }

    private func listenerFailed() {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }

    private static func startError(_ error: NWError, port: UInt16) -> StartError {
        if case .posix(let code) = error, code == .EADDRINUSE { return .portInUse(port) }
        return .failed("\(error)")
    }

    /// Every 15 seconds: the summed refusal lines whose minute has ended go to the audit log (R39), and a grant
    /// save that failed is tried again.
    private func startTicks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.state.tick() }
        timer.resume()
        ticks = timer
    }

    // MARK: connections

    /// One client connection. Used only on the door's queue.
    private final class Connection {
        let id: UInt64
        let link: NWConnection
        var parser = RemoteAccessHTTP.Parser()
        /// A request was handed out and is not answered yet.
        var busy = false
        /// Its last answer is going out, or it is closed: nothing more is read or sent.
        var ending = false
        var closed = false
        /// The client finished sending: close once the answer it waits for is out.
        var peerDone = false
        var armed: RemoteAccessHTTP.Phase?
        var deadline: DispatchSourceTimer?
        var keepAlive: DispatchSourceTimer?

        init(id: UInt64, link: NWConnection) {
            self.id = id
            self.link = link
        }
    }

    private func accept(_ link: NWConnection) {
        guard !stopped else { return link.cancel() }
        if connections.count >= Self.maximumConnections {
            // The oldest connection with no request in hand gives way: one waiting for its head, its body or its
            // next request. Only a call in progress (six at most, R27) keeps its place.
            let waiting = connections.values.filter { !$0.busy }
            guard let oldest = waiting.min(by: { $0.id < $1.id }) else { return link.cancel() }
            close(oldest)
        }
        lastConnection += 1
        let connection = Connection(id: lastConnection, link: link)
        connections[connection.id] = connection
        link.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(connection)
            default: break
            }
        }
        link.start(queue: queue)
        receive(connection)
        pump(connection)
    }

    private func receive(_ connection: Connection) {
        let link = connection.link
        link.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, !connection.ending else { return }
            var reading = true
            if let data, !data.isEmpty, !connection.parser.append(data) { reading = false }
            if done || error != nil {
                connection.peerDone = true
                reading = false
            }
            if reading { self.receive(connection) }
            if !connection.busy { self.pump(connection) }
            // The client is gone with nothing to answer. An answer on its way (`ending`) closes it once sent.
            if connection.peerDone, !connection.busy, !connection.ending { self.close(connection) }
        }
    }

    /// Hands out the next request, if one is whole: refuses it at its head when a check fails, or serves it. Stops
    /// while one is being answered; `answered` calls it again.
    private func pump(_ connection: Connection) {
        while !connection.ending, !connection.busy {
            switch connection.parser.next() {
            case .needMore:
                arm(connection)
                return
            case .head(let request):
                if let refusal = refusal(atHead: request) { return finish(connection, with: refusal) }
            case .request(let request):
                connection.busy = true
                disarm(connection)
                serve(request, on: connection)
            case .failure(let failure):
                // A head that was read gets the checks' answer first, so a wrong Host still counts as one.
                let host = state.host
                let checked = failure.request.map { RemoteAccessHTTP.check($0, host: host) }
                if case .refused(let status, _)? = checked {
                    state.countRefusal(status: status, request: failure.request)
                } else {
                    state.countRefusal(status: failure.status, request: failure.request)
                }
                return finish(connection, with: RemoteAccessHTTP.refusal(failure, host: host))
            }
        }
    }

    /// The answer to a request went out: read the next one, or close if the client is gone.
    private func answered(_ connection: Connection) {
        connection.busy = false
        guard !connection.ending else { return }
        if connection.peerDone {
            pump(connection)
            if !connection.busy { finish(connection) }
            return
        }
        pump(connection)
    }

    /// The deadline for where the connection stands (R8): a head within 10 seconds (a new connection's first from
    /// when it opened), a body within 30, and 30 idle between requests. None while a request waits for its answer.
    private func arm(_ connection: Connection) {
        let phase = connection.parser.phase
        guard phase != connection.armed else { return }
        disarm(connection)
        connection.armed = phase
        let seconds: TimeInterval
        switch phase {
        case .idle: seconds = RemoteAccessHTTP.idleDeadline
        case .head: seconds = RemoteAccessHTTP.headerDeadline
        case .body: seconds = RemoteAccessHTTP.bodyDeadline
        case .answering: return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, !connection.ending, !connection.busy else { return }
            guard connection.parser.phase == phase else { return }
            if phase == .idle { return self.close(connection) }
            self.finish(connection, with: RemoteAccessHTTP.refusal(status: 408))
        }
        timer.resume()
        connection.deadline = timer
    }

    private func disarm(_ connection: Connection) {
        connection.deadline?.cancel()
        connection.deadline = nil
        connection.armed = nil
    }

    private func send(_ data: Data, on connection: Connection) {
        guard !connection.ending else { return }
        connection.link.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends `data`, if any, as the connection's last bytes, then closes it.
    private func finish(_ connection: Connection, with data: Data? = nil) {
        guard !connection.ending else { return }
        connection.ending = true
        disarm(connection)
        stopKeepAlive(connection)
        if let data { connection.link.send(content: data, completion: .contentProcessed { _ in }) }
        connection.link.send(content: nil, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }

    private func close(_ connection: Connection) {
        guard !connection.closed else { return }
        connection.closed = true
        connection.ending = true
        disarm(connection)
        stopKeepAlive(connection)
        connection.link.cancel()
        connections[connection.id] = nil
    }

    private func reply(_ data: Data, on connection: Connection) {
        send(data, on: connection)
        answered(connection)
    }

    // MARK: checks

    /// A request refused at its head, before its body is read: the checks (R4 to R6), then, for `/mcp`, the token.
    private func refusal(atHead request: RemoteAccessHTTP.Request) -> Data? {
        let checked = RemoteAccessHTTP.check(request, host: state.host)
        switch checked {
        case .refused(let status, _):
            state.countRefusal(status: status, request: request)
            return checked.answer
        case .route(.mcp):
            return unauthorized(request)
        case .route:
            return nil
        }
    }

    /// 401 when the request has no valid access token, with the challenge that points at the metadata (and
    /// `error="invalid_token"` when a token was sent). Nil when the token is valid.
    private func unauthorized(_ request: RemoteAccessHTTP.Request) -> Data? {
        let token = RemoteAccessOAuth.bearer(request.header("authorization"))
        switch state.validate(token) {
        case .valid: return nil
        case .missing: return challenge(request, tokenSent: false)
        case .invalid: return challenge(request, tokenSent: true)
        }
    }

    private func challenge(_ request: RemoteAccessHTTP.Request, tokenSent: Bool) -> Data {
        state.countRefusal(status: 401, request: request)
        var headers: [(String, String)] = []
        if let value = state.wwwAuthenticate(tokenSent: tokenSent) { headers.append(("WWW-Authenticate", value)) }
        return RemoteAccessHTTP.response(status: 401, headers: headers, close: true)
    }

    // MARK: routes

    private func serve(_ request: RemoteAccessHTTP.Request, on connection: Connection) {
        // A request read before Turn Off is not served after it: no token is issued, no grant saved.
        guard !stopped else { return close(connection) }
        // The host can change between a head and its body (Confirm Host): the checks run again on the whole request.
        let checked = RemoteAccessHTTP.check(request, host: state.host)
        guard case .route(let route) = checked else {
            if case .refused(let status, _) = checked { state.countRefusal(status: status, request: request) }
            return finish(connection, with: checked.answer)
        }
        switch route {
        case .mcp:
            serveMCP(request, on: connection)
        case .protectedResource:
            metadata(state.protectedResourceMetadata(), on: connection)
        case .authorizationServer:
            metadata(state.authorizationServerMetadata(), on: connection)
        case .register:
            oauth(state.register(request.body), request: request, on: connection)
        case .token:
            oauth(state.token(request.body), request: request, on: connection)
        case .revoke:
            oauth(state.revoke(request.body), request: request, on: connection)
        case .authorize:
            page(state.authorize(request.query), request: request, on: connection)
        case .authorizeWait:
            page(state.poll(request.query), request: request, on: connection)
        }
    }

    private func metadata(_ body: Data?, on connection: Connection) {
        guard let body else { return finish(connection, with: RemoteAccessHTTP.refusal(status: 421)) }
        reply(RemoteAccessHTTP.json(status: 200, body: body), on: connection)
    }

    /// An OAuth endpoint's JSON. It may hold a token or a client id, so no cache keeps it.
    private func oauth(_ answer: RemoteAccessOAuth.Answer?, request: RemoteAccessHTTP.Request,
                       on connection: Connection) {
        guard let answer else { return finish(connection, with: RemoteAccessHTTP.refusal(status: 421)) }
        if answer.status >= 400 { state.countRefusal(.badOAuth, request: request) }
        let headers = [("Cache-Control", "no-store"), ("Pragma", "no-cache")]
        guard !answer.body.isEmpty else {
            return reply(RemoteAccessHTTP.response(status: answer.status, headers: headers), on: connection)
        }
        reply(RemoteAccessHTTP.json(status: answer.status, body: answer.body, headers: headers), on: connection)
    }

    /// `/oauth/authorize` and its wait: a 302 back to the client, or one of the pairing pages (U8).
    private func page(_ authorization: RemoteAccessOAuth.Authorization?, request: RemoteAccessHTTP.Request,
                      on connection: Connection) {
        guard let authorization else { return finish(connection, with: RemoteAccessHTTP.refusal(status: 421)) }
        if case .invalid = authorization { state.countRefusal(.badOAuth, request: request) }
        reply(RemoteAccessPages.response(authorization), on: connection)
    }

    // MARK: /mcp

    private func serveMCP(_ request: RemoteAccessHTTP.Request, on connection: Connection) {
        let token = RemoteAccessOAuth.bearer(request.header("authorization"))
        guard case .valid(let grant) = state.validate(token) else {
            return finish(connection, with: challenge(request, tokenSent: token != nil))
        }
        let incoming = RemoteAccessCalls.read(request.body, protocolVersion: request.header("mcp-protocol-version"))
        switch incoming {
        case .request(let message):
            reply(answer(message, grant: grant), on: connection)
        case .call(let id, let name, let arguments):
            call(Call(id: id, tool: name, arguments: arguments, grant: grant, request: request, started: state.now),
                 on: connection)
        case .notification:
            reply(RemoteAccessHTTP.response(status: 202), on: connection)
        case .batch, .invalid, .badVersion:
            unreadable(incoming, grant: grant, request: request, on: connection)
        }
    }

    /// `initialize`, `ping`, `tools/list` and the rest: answered as `nxtrm mcp` answers them, with the tools the
    /// grant's options admit now, the remote instructions for them and `listChanged: true` (R20, R26).
    private func answer(_ message: [String: Any], grant: RemoteAccessOAuth.Grant) -> Data {
        // A tools/list gives the client the new list, so the mark for a changed list goes in the same step as the
        // options are read (R20).
        let listed = message["method"] as? String == "tools/list"
        let options = state.options(of: grant.id, listed: listed) ?? grant.options
        let tools = RemoteAccessTools.tools(for: options)
        let instructions = RemoteAccessTools.instructions(for: options)
        let response = MCPServer.respond(to: message, version: version, tools: tools, instructions: instructions,
                                         listChanged: true) { _, _ in
            // Tool calls never come here: the door runs them itself.
            MCPServer.CallResult(text: RemoteAccessText.notAvailable, isError: true)
        }
        guard let response else { return RemoteAccessHTTP.response(status: 202) }
        return RemoteAccessHTTP.json(status: 200, body: RemoteAccessCalls.encode(response))
    }

    /// An authenticated POST the door can't read: a batch, not JSON-RPC, or a protocol version it doesn't speak.
    /// It gets 400 and the connection closes. It counts toward its grant's calls a minute and has its audit line
    /// like a refused call, summed past the limits (R27, R39).
    private func unreadable(_ incoming: RemoteAccessCalls.Incoming, grant: RemoteAccessOAuth.Grant,
                            request: RemoteAccessHTTP.Request, on connection: Connection) {
        if calls.countRefused(grant: grant.id) == .tooMany {
            state.countOverLimit(grant, tool: "")
        } else {
            let entry = RemoteAccessAuditEntry.call(time: state.now, grant: grant, tool: "", arguments: nil,
                                                    decision: .refused, reason: incoming.reason,
                                                    forwarded: request.forwarded)
            state.audit([entry])
        }
        finish(connection, with: RemoteAccessHTTP.refusal(status: incoming.status ?? 400))
    }

    /// One tool call, from the request to its answer.
    private final class Call: @unchecked Sendable { // read on the door's queue and once on the main thread
        let id: Any
        let tool: String
        let arguments: [String: Any]
        let grant: RemoteAccessOAuth.Grant
        let forwarded: RemoteAccessHTTP.Forwarded
        let streamed: Bool
        let started: Date
        /// Its id in the registry, once it is open. Set and read only on the door's queue.
        var callID: RemoteAccessCalls.ID?

        init(id: Any, tool: String, arguments: [String: Any], grant: RemoteAccessOAuth.Grant,
             request: RemoteAccessHTTP.Request, started: Date) {
            self.id = id
            self.tool = tool
            self.arguments = arguments
            self.grant = grant
            forwarded = request.forwarded
            streamed = request.acceptsEventStream
            self.started = started
        }
    }

    /// The policy decides before the main thread (U5). A call it admits takes a slot, starts its stream when the
    /// client takes one, and goes to the main thread; one it refuses is answered here.
    private func call(_ call: Call, on connection: Connection) {
        let options = call.grant.options
        switch RemoteAccessPolicy.decide(tool: call.tool, arguments: call.arguments, options: options) {
        case .allow:
            open(call, on: connection)
        case .unknownTool(let text), .invalidParams(let text):
            refuse(call, .invalidParams(text), on: connection)
        case .refuse(let text):
            refuse(call, .options(text, by: RemoteAccessCalls.refusedBy(call.tool, options: options)), on: connection)
        }
    }

    /// A call answered without running. It counts toward its grant's 120 calls a minute (R27), so past them it gets
    /// the too-many text and its audit line is summed (R39).
    private func refuse(_ call: Call, _ refusal: RemoteAccessCalls.Refusal, on connection: Connection) {
        switch calls.countRefused(grant: call.grant.id) {
        case .counted:
            let ending = RemoteAccessCalls.Ending.refused(refusal)
            audit(call, ending)
            reply(json(RemoteAccessCalls.answer(id: call.id, ending)), on: connection)
        case .tooMany:
            tooMany(call, on: connection)
        case .closed:
            turnedOff(call, on: connection)
        }
    }

    /// Past R27's limits: the too-many text, and one summed audit line a minute for the grant (R39).
    private func tooMany(_ call: Call, on connection: Connection) {
        state.countOverLimit(call.grant, tool: call.tool)
        reply(json(RemoteAccessCalls.result(id: call.id, failure(RemoteAccessText.tooManyCalls))), on: connection)
    }

    /// Remote access turned off after the call's token was checked: the revoke text, and the connection closes.
    private func turnedOff(_ call: Call, on connection: Connection) {
        audit(call, .turnedOff)
        finish(connection, with: json(RemoteAccessCalls.answer(id: call.id, .turnedOff), close: true))
    }

    private func open(_ call: Call, on connection: Connection) {
        let calls = self.calls
        let opened = calls.open(grant: call.grant.id, connection: connection.id, streamed: call.streamed) {
            [weak self, weak connection] ending in
            self?.ended(call, ending, on: connection)
        }
        switch opened {
        case .tooMany:
            tooMany(call, on: connection)
        case .closed:
            turnedOff(call, on: connection)
        case .call(let callID, let listChanged):
            call.callID = callID
            if call.streamed {
                send(RemoteAccessCalls.streamStart(listChanged: listChanged), on: connection)
                startKeepAlive(connection)
            }
            startDeadline(callID)
            DispatchQueue.main.async { [weak self] in self?.run(call, callID) }
        }
    }

    /// On the main thread: the grant read again under the authority's lock (KTD15) and the options as they are
    /// now (R60), then `MCPControl.call` as a caller outside Next Term's tabs, with the connection's approval
    /// policy, its name and its grant id (R56). A refusal here is the call's answer, carried through the registry.
    /// The reply may come from any thread: the result is shaped off the main thread and the door's queue (masking
    /// a long screen takes time) while the call is still open, so a revoke or a turn-off meanwhile still answers it.
    private func run(_ call: Call, _ callID: RemoteAccessCalls.ID) {
        let calls = self.calls
        guard case .run(let grant) = state.begin(callID, grant: call.grant.id) else { return }
        let tool = call.tool
        let arguments: [String: Any]
        switch RemoteAccessPolicy.decide(tool: tool, arguments: call.arguments, options: grant.options) {
        case .allow(let allowed):
            arguments = held(allowed, tool: tool)
        case .refuse(let text):
            let refusedBy = RemoteAccessCalls.refusedBy(tool, options: grant.options)
            calls.finish(callID, refused: .options(text, by: refusedBy))
            return
        case .invalidParams(let text), .unknownTool(let text):
            calls.finish(callID, refused: .invalidParams(text))
            return
        }
        // U14 adds here, for a control call: one fresh screen read, the tab checks the options ask for, and Allow
        // on the Mac while "Ask on this Mac before changes" is on. Its window must close with the grant
        // (RemoteAccessApprovals), and the grant must be read again after Allow.
        MCPControl.call(tool, arguments, caller: nil, approval: RemoteAccessCalls.approval(for: grant),
                        requester: RemoteAccessCalls.requester(for: grant), connection: grant.id) { result in
            DispatchQueue.global(qos: .userInitiated).async {
                calls.finish(callID, RemoteAccessPolicy.shape(result, tool: tool))
            }
        }
    }

    /// `wait_for_tab` held to the door's wait: 50 seconds, or what a debug self-test set.
    private func held(_ arguments: [String: Any], tool: String) -> [String: Any] {
        guard tool == "wait_for_tab", let seconds = arguments["timeout_seconds"] as? Int,
              seconds > timings.wait else { return arguments }
        var held = arguments
        held["timeout_seconds"] = timings.wait
        return held
    }

    /// The call's own deadline (R25), on the monotonic clock with a small leeway, so it fires on time whatever the
    /// wall clock does.
    private func startDeadline(_ callID: RemoteAccessCalls.ID) {
        let calls = self.calls
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + calls.deadline, leeway: Self.deadlineLeeway)
        timer.setEventHandler { [weak self] in
            calls.expire(callID)
            self?.stopDeadline(callID)
        }
        timer.resume()
        deadlines[callID] = timer
    }

    private func stopDeadline(_ callID: RemoteAccessCalls.ID?) {
        guard let callID, let timer = deadlines.removeValue(forKey: callID) else { return }
        timer.cancel()
    }

    /// The call was answered, on whatever thread ended it: its answer goes out on the door's queue. The revoke and
    /// deadline texts go out at once, ahead of any close that turning off queued after them.
    private func ended(_ call: Call, _ ending: RemoteAccessCalls.Ending, on connection: Connection?) {
        queue.async { self.deliver(call, ending, on: connection) }
    }

    /// Writes the call's audit line, then sends its answer: as the stream's last event, or as JSON. The connection
    /// closes after a stream, after the revoke text, and once the door is turning off.
    private func deliver(_ call: Call, _ ending: RemoteAccessCalls.Ending, on connection: Connection?) {
        stopDeadline(call.callID)
        audit(call, ending)
        if case .result = ending { state.noteUse(call.grant.id) }
        guard let connection, !connection.ending else { return }
        stopKeepAlive(connection)
        let message = RemoteAccessCalls.answer(id: call.id, ending)
        if call.streamed {
            return finish(connection, with: RemoteAccessHTTP.event(message))
        }
        guard !ending.closesConnection, !stopped else { return finish(connection, with: json(message, close: true)) }
        reply(json(message), on: connection)
    }

    private func startKeepAlive(_ connection: Connection) {
        stopKeepAlive(connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timings.keepAlive, repeating: timings.keepAlive)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.send(RemoteAccessHTTP.keepAlive, on: connection)
        }
        timer.resume()
        connection.keepAlive = timer
    }

    private func stopKeepAlive(_ connection: Connection) {
        connection.keepAlive?.cancel()
        connection.keepAlive = nil
    }

    private func json(_ message: Data, close: Bool = false) -> Data {
        RemoteAccessHTTP.json(status: 200, body: message, close: close)
    }

    private func failure(_ text: String) -> MCPServer.CallResult {
        MCPServer.CallResult(text: text, isError: true)
    }

    /// The audit line of a call as it ended (R39). Tokens and tool output never go in it: only the result's size
    /// and the start of its hash.
    private func audit(_ call: Call, _ ending: RemoteAccessCalls.Ending) {
        var result: String?
        if case .result(let shaped) = ending { result = shaped.text }
        let now = state.now
        let entry = RemoteAccessAuditEntry.call(time: now, grant: call.grant, tool: call.tool,
                                                arguments: call.arguments, decision: ending.decision,
                                                reason: ending.reason, refusedBy: ending.refusedBy,
                                                duration: now.timeIntervalSince(call.started), result: result,
                                                forwarded: call.forwarded)
        state.audit([entry])
    }
}

extension RemoteAccessDoorState {
    /// The state for a door, its registry with the door's deadline: 100 seconds, shortened only under a debug
    /// self-test (U12). Its log is written on the app's one audit queue, and it takes over what the last state
    /// left (`carried`).
    static func forDoor(folder: URL, host: String?, carrying carried: Carried?) -> RemoteAccessDoorState {
        let calls = RemoteAccessCalls(deadline: RemoteAccessServer.Timings.current.deadline)
        return RemoteAccessDoorState(folder: folder, host: host, calls: calls, auditQueue: RemoteAccess.auditQueue,
                                     carrying: carried)
    }
}

/// The approval windows a remote connection's calls opened on the Mac, the write tools' and the skill requests',
/// closed while nobody has answered them when the connection's grant ends or Remote access turns off. Closing one is
/// a decline, so nothing it asked for happens after access was cut (R37, R38). A call's deadline closes none: the
/// write tools' window gives up by itself at 50 seconds, inside the door's 100, and a skill request is made to
/// outlive one call (the client asks again with its request id).
@MainActor
enum RemoteAccessApprovals {
    /// The windows of these grants' calls, or of every remote connection's when nil.
    static func close(grants: Set<String>?) {
        func cut(_ asker: String) -> Bool {
            guard let grants else { return asker.hasPrefix("remote") }
            let prefix = "remote:"
            guard asker.hasPrefix(prefix) else { return false }
            return grants.contains(String(asker.dropFirst(prefix.count)))
        }
        if let asking = MCPWriteControl.pending, !asking.answered, cut(asking.asker) {
            asking.window?.close()
        }
        let requests = Array(SkillsMCP.requests.values)
        for request in requests where request.answer == nil && cut(request.asker) {
            request.window?.close()
        }
    }
}

/// The listener's first state, waited for by `start`.
private final class StartOutcome: @unchecked Sendable { // `error` is written before `ready` is signalled
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var settled = false
    private(set) var error: RemoteAccessServer.StartError?

    /// The first state that settles the start. True when the start had settled already, as when a listener that
    /// was ready fails later.
    @discardableResult
    func settle(_ error: RemoteAccessServer.StartError?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return true }
        settled = true
        self.error = error
        ready.signal()
        return false
    }
}
