import Foundation
import Network
import NextTermCore

/// Remote access's door (U7): MCP Streamable HTTP at `/mcp` and Next Term's OAuth routes, on `127.0.0.1` at the
/// saved port and nowhere else (R2). The tunnel forwards to it; nothing else may reach it.
///
/// Each connection is read by the Core parser (`RemoteAccessHTTP`), one request at a time, answered in order, with a
/// 10-second deadline for a head, 30 seconds for a body, and 30 seconds idle between requests. Every request passes
/// the checks in order (Host, Origin, path, method); a refusal goes out with no body and the connection closes. Until
/// a host is saved, every request gets 421.
///
/// A tool call runs through the same engine as `nxtrm mcp` (`MCPControl.call`), as a caller outside Next Term's tabs
/// (R3). Its life is `RemoteAccessCalls`': it is registered before the hop to the main thread, its grant is read again
/// there under the authority's lock just before it runs (KTD15), and it is answered exactly once: with its masked and
/// capped result, with the revoke text at once when its grant ends, or with the deadline text after 100 seconds.
///
/// Logic is in Core (U1 to U5, `RemoteAccessCalls`); this file holds the sockets and the binding to MCPControl.
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

    /// At most this many connections at once; one more is closed at once.
    static let maximumConnections = 64

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
    private var summaries: DispatchSourceTimer?
    private var stopped = false

    init(port: UInt16, state: RemoteAccessDoorState) {
        self.port = port
        self.state = state
        self.timings = Timings.current
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
            startSummaries()
        }
    }

    /// Turns the door off within a second (R37): no new connection, every open call answered with the revoke text,
    /// access tokens dropped (every grant ended too with `revokeAll`), then every connection closed. Call it from
    /// the main thread. It can be called again; it does nothing then.
    func stop(revokeAll: Bool = false) {
        let first = queue.sync { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            listener?.cancel()
            listener = nil
            summaries?.cancel()
            summaries = nil
            return true
        }
        guard first else { return }
        // The authority's lock, then the registry: the open calls' answers are queued before the closes below.
        state.turnOff(revokeAll: revokeAll)
        queue.async {
            for connection in self.connections.values { self.finish(connection) }
        }
        queue.asyncAfter(deadline: .now() + 0.8) {
            for connection in self.connections.values { self.close(connection) }
        }
    }

    var isRunning: Bool { queue.sync { listener != nil && !stopped } }

    private func listenerFailed() {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }

    private static func startError(_ error: NWError, port: UInt16) -> StartError {
        if case .posix(let code) = error, code == .EADDRINUSE { return .portInUse(port) }
        return .failed("\(error)")
    }

    /// Refusals before a valid token go to the audit log as one line a minute per kind (R39).
    private func startSummaries() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.state.writeDueRefusals() }
        timer.resume()
        summaries = timer
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
        guard !stopped, connections.count < Self.maximumConnections else { return link.cancel() }
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

    /// The deadline for where the connection stands (R8): a head within 10 seconds, a body within 30, and 30 idle
    /// between requests. None while a request waits for its answer.
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

    /// `/oauth/authorize` and its wait: a 302 back to the client, or a page (U8's, a placeholder until then).
    private func page(_ authorization: RemoteAccessOAuth.Authorization?, request: RemoteAccessHTTP.Request,
                      on connection: Connection) {
        guard let authorization else { return finish(connection, with: RemoteAccessHTTP.refusal(status: 421)) }
        if case .invalid = authorization { state.countRefusal(.badOAuth, request: request) }
        reply(RemoteAccessDoorPages.answer(authorization), on: connection)
    }

    // MARK: /mcp

    private func serveMCP(_ request: RemoteAccessHTTP.Request, on connection: Connection) {
        let token = RemoteAccessOAuth.bearer(request.header("authorization"))
        guard case .valid(let grant) = state.validate(token) else {
            return finish(connection, with: challenge(request, tokenSent: token != nil))
        }
        let incoming = RemoteAccessCalls.read(request.body, protocolVersion: request.header("mcp-protocol-version"))
        if let status = incoming.status {
            guard status == 202 else { return finish(connection, with: RemoteAccessHTTP.refusal(status: status)) }
            return reply(RemoteAccessHTTP.response(status: 202), on: connection)
        }
        switch incoming {
        case .request(let message):
            reply(answer(message, grant: grant), on: connection)
        case .call(let id, let name, let arguments):
            call(Call(id: id, tool: name, arguments: arguments, grant: grant, request: request, started: state.now),
                 on: connection)
        default:
            finish(connection, with: RemoteAccessHTTP.refusal(status: 400))
        }
    }

    /// `initialize`, `ping`, `tools/list` and the rest: answered as `nxtrm mcp` answers them, with the tools the
    /// grant's options admit, the remote instructions for them and `listChanged: true` (R20, R26).
    private func answer(_ message: [String: Any], grant: RemoteAccessOAuth.Grant) -> Data {
        let options = grant.options
        // The client asks for the list, so it has the new one: the mark for a changed list goes (R20).
        if message["method"] as? String == "tools/list" { calls.clearListChanged(grant.id) }
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

    /// One tool call, from the request to its answer.
    private final class Call: @unchecked Sendable { // read on the door's queue and once on the main thread
        let id: Any
        let tool: String
        let arguments: [String: Any]
        let grant: RemoteAccessOAuth.Grant
        let forwarded: RemoteAccessHTTP.Forwarded
        let streamed: Bool
        let started: Date
        /// Refused on the main thread, under options changed since the door's check (R60): the audit line's reason
        /// and the options it names. Set there before the call is finished, read after.
        var refused: (reason: String, by: [RemoteAccessOption.ID])?

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

    /// The policy decides before the main thread (U5); a call it admits takes a slot, starts its stream when the
    /// client takes one, and goes to the main thread.
    private func call(_ call: Call, on connection: Connection) {
        switch RemoteAccessPolicy.decide(tool: call.tool, arguments: call.arguments, options: call.grant.options) {
        case .unknownTool(let text), .invalidParams(let text):
            audit(call, decision: .refused, reason: text)
            reply(json(RemoteAccessCalls.error(id: call.id, code: -32602, message: text)), on: connection)
        case .refuse(let text):
            let refusedBy = RemoteAccessCalls.refusedBy(call.tool, options: call.grant.options)
            audit(call, decision: .refused, reason: text, refusedBy: refusedBy)
            reply(json(RemoteAccessCalls.result(id: call.id, failure(text))), on: connection)
        case .allow:
            open(call, on: connection)
        }
    }

    private func open(_ call: Call, on connection: Connection) {
        let calls = self.calls
        let opened = calls.open(grant: call.grant.id, connection: connection.id, streamed: call.streamed) {
            [weak self, weak connection] ending in
            self?.ended(call, ending, on: connection)
        }
        switch opened {
        case .tooMany:
            audit(call, decision: .refused, reason: RemoteAccessText.tooManyCalls)
            reply(json(RemoteAccessCalls.result(id: call.id, failure(RemoteAccessText.tooManyCalls))), on: connection)
        case .closed:
            let message = RemoteAccessCalls.result(id: call.id, failure(RemoteAccessText.turnedOff))
            finish(connection, with: json(message, close: true))
        case .call(let callID, let listChanged):
            if call.streamed {
                send(RemoteAccessCalls.streamStart(listChanged: listChanged), on: connection)
                startKeepAlive(connection)
            }
            queue.asyncAfter(deadline: .now() + calls.deadline) { calls.expire() }
            DispatchQueue.main.async { [weak self] in self?.run(call, callID) }
        }
    }

    /// On the main thread: the grant read again under the authority's lock (KTD15) and the options as they are
    /// now (R60), then `MCPControl.call` as a caller outside Next Term's tabs, with the connection's approval
    /// policy, its name and its grant id (R56). Its reply may come from any thread.
    private func run(_ call: Call, _ callID: RemoteAccessCalls.ID) {
        let calls = self.calls
        guard case .run(let grant) = state.begin(callID, grant: call.grant.id) else { return }
        let decision = RemoteAccessPolicy.decide(tool: call.tool, arguments: call.arguments, options: grant.options)
        let arguments: [String: Any]
        switch decision {
        case .allow(let allowed):
            arguments = held(allowed, tool: call.tool)
        case .refuse(let text):
            call.refused = (text, RemoteAccessCalls.refusedBy(call.tool, options: grant.options))
            calls.finish(callID, failure(text))
            return
        case .invalidParams(let text), .unknownTool(let text):
            call.refused = (text, [])
            calls.finish(callID, failure(text))
            return
        }
        // U14 adds here, for a control call: one fresh screen read, the tab checks the options ask for, and Allow
        // on the Mac while "Ask on this Mac before changes" is on.
        MCPControl.call(call.tool, arguments, caller: nil, approval: RemoteAccessCalls.approval(for: grant),
                        requester: RemoteAccessCalls.requester(for: grant), connection: grant.id) { result in
            calls.finish(callID, result)
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

    /// The call was answered: its result shaped off the main thread and the door's queue (masking a long screen
    /// takes time), then sent, its stream closed, and its audit line written. The revoke and deadline texts go
    /// out at once, ahead of any close that turning off queued after them.
    private func ended(_ call: Call, _ ending: RemoteAccessCalls.Ending, on connection: Connection?) {
        guard case .result(let raw) = ending else {
            let message = RemoteAccessCalls.result(id: call.id, ending.callResult)
            queue.async { self.deliver(message, ending, call, result: ending.callResult, on: connection) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let shaped = RemoteAccessPolicy.shape(raw, tool: call.tool)
            let message = RemoteAccessCalls.result(id: call.id, shaped)
            self.queue.async { self.deliver(message, ending, call, result: shaped, on: connection) }
        }
    }

    private func deliver(_ message: Data, _ ending: RemoteAccessCalls.Ending, _ call: Call,
                         result: MCPServer.CallResult, on connection: Connection?) {
        if let refused = call.refused {
            audit(call, decision: .refused, reason: refused.reason, refusedBy: refused.by)
        } else {
            let reason = ending.decision == .allowed ? nil : result.text
            audit(call, decision: ending.decision, reason: reason, result: result.text)
            if case .result = ending { state.noteUse(call.grant.id) }
        }
        guard let connection, !connection.ending else { return }
        stopKeepAlive(connection)
        if call.streamed {
            return finish(connection, with: RemoteAccessHTTP.event(message))
        }
        guard !ending.closesConnection else { return finish(connection, with: json(message, close: true)) }
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

    /// The audit line of an authenticated call, allowed or refused (R39). Tokens and tool output never go in it:
    /// only the result's size and the start of its hash.
    private func audit(_ call: Call, decision: RemoteAccessAuditEntry.Decision, reason: String? = nil,
                       refusedBy: [RemoteAccessOption.ID] = [], result: String? = nil) {
        let now = state.now
        let entry = RemoteAccessAuditEntry.call(time: now, grant: call.grant, tool: call.tool,
                                                arguments: call.arguments, decision: decision, reason: reason,
                                                refusedBy: refusedBy, duration: now.timeIntervalSince(call.started),
                                                result: result, forwarded: call.forwarded)
        state.audit([entry])
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

// MARK: - the door's state

/// What the door decides with, under one lock (KTD15): the OAuth authority, the grant store, the audit log and the
/// refusal counts. Every revoke path takes this lock and then the open-call registry's: Revoke on the Mac, Revoke All,
/// the kill switch, refresh reuse, a reused code and `/oauth/revoke`.
///
/// Grant changes are saved before their reply goes out: new tokens (U4), a revoke, an approval, new options. A failed
/// save of new tokens answers `server_error`, the authority keeps the old refresh token current, and the new pair is
/// never sent. Uses are saved at most once an hour.
///
/// Until a host is saved (Confirm Host), there is no authority, and the door answers 421 to everything.
final class RemoteAccessDoorState: @unchecked Sendable { // everything below lives under `lock`
    let calls: RemoteAccessCalls
    /// The authority's events, on the main thread: U9 shows the reuse notice and the other Mac notices.
    var onEvents: (@MainActor ([RemoteAccessOAuth.Event]) -> Void)?

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var authority: RemoteAccessOAuth?
    private var store: RemoteAccessGrantStore
    private var log: RemoteAccessAuditLog
    private var refusals = RemoteAccessRefusals()
    /// The clients and grants as the file holds them, their last uses aside: a change to them is saved.
    private var saved: Saved
    /// What the store held at launch, for when the host is saved.
    private var loaded: RemoteAccessGrantStore.Loaded

    private struct Saved: Equatable {
        var clients: [RemoteAccessOAuth.Client]
        var grants: [RemoteAccessOAuth.Grant]

        init(_ clients: [RemoteAccessOAuth.Client], _ grants: [RemoteAccessOAuth.Grant]) {
            self.clients = clients.map { client in
                var kept = client
                kept.lastUsed = .distantPast
                return kept
            }
            self.grants = grants.map { grant in
                var kept = grant
                kept.lastUsed = .distantPast
                return kept
            }
        }
    }

    /// The state for a door, from the grant store in `folder` (the Remote access folder, or a self-test's temp
    /// folder, KTD18), with the saved public hostname, if there is one. A door's state serves one start: turning
    /// off ends its registry for good, so the next start makes a new one.
    init(folder: URL, host: String?,
         calls: RemoteAccessCalls = RemoteAccessCalls(deadline: RemoteAccessServer.Timings.current.deadline),
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.calls = calls
        self.clock = clock
        store = RemoteAccessGrantStore(folder: folder)
        log = RemoteAccessAuditLog(folder: folder)
        let now = clock()
        loaded = store.load(now: now)
        saved = Saved(loaded.clients, loaded.grants)
        if let host { setHost(host) }
    }

    var now: Date { clock() }

    /// The public hostname, or nil until one is saved.
    var host: String? { locked { authority?.host } }

    /// Confirm Host, or a new hostname: the issuer and the resource follow it, and a new one ends every grant
    /// (R17, KTD17).
    func setHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if authority == nil {
            authority = RemoteAccessOAuth(host: host, clients: loaded.clients, grants: loaded.grants)
        } else {
            authority?.setHost(host, now: now)
        }
        settle(now: now)
    }

    /// Runs `body` on the authority under the lock, then saves the clients and grants if they changed and handles
    /// its events: audit lines, and the registry's revokes. For pairing on the Mac (U8): open, match, approve,
    /// decline, close. Nil without a host.
    func update<T>(_ body: (inout RemoteAccessOAuth, Date) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard authority != nil else { return nil }
        let now = clock()
        let value = body(&authority!, now)
        settle(now: now)
        return value
    }

    // MARK: the door's reads

    func validate(_ token: String?) -> RemoteAccessOAuth.Validation {
        locked { authority?.validate(token, now: clock()) ?? (token == nil ? .missing : .invalid) }
    }

    func wwwAuthenticate(tokenSent: Bool) -> String? {
        locked { authority?.wwwAuthenticate(tokenSent: tokenSent) }
    }

    func protectedResourceMetadata() -> Data? { locked { authority?.protectedResourceMetadata() } }

    func authorizationServerMetadata() -> Data? { locked { authority?.authorizationServerMetadata() } }

    // MARK: OAuth routes

    func register(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in authority.register(body, now: now) }
    }

    func authorize(_ query: String?) -> RemoteAccessOAuth.Authorization? {
        update { authority, now in authority.authorize(RemoteAccessOAuth.parameters(query), now: now) }
    }

    func poll(_ query: String?) -> RemoteAccessOAuth.Authorization? {
        update { authority, now in authority.poll(RemoteAccessOAuth.parameters(query)?["request"], now: now) }
    }

    /// `/oauth/token`: new tokens are saved before they apply and go out. A failed save sends `server_error`, and
    /// the old refresh token stays current.
    func token(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in
            switch authority.token(RemoteAccessOAuth.parameters(body: body), now: now) {
            case .answer(let answer):
                return answer
            case .issue(let issuance):
                let grants = RemoteAccessGrantStore.replacing(issuance.grant, in: authority.grants)
                do {
                    try store.save(clients: authority.clients, grants: grants, now: now)
                } catch {
                    NSLog("Next Term: Remote access could not save new tokens: \(error)")
                    return RemoteAccessOAuth.serverError
                }
                saved = Saved(authority.clients, grants)
                return authority.apply(issuance) ? issuance.answer : RemoteAccessOAuth.serverError
            }
        }
    }

    /// `/oauth/revoke`: a refresh token ends its grant, which answers its open calls (R38).
    func revoke(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in authority.revoke(RemoteAccessOAuth.parameters(body: body), now: now).answer }
    }

    // MARK: calls

    /// Just before a call runs, on the main thread: the grant as the authority holds it now, active, under this
    /// lock and then the registry's.
    func begin(_ id: RemoteAccessCalls.ID, grant grantID: String) -> RemoteAccessCalls.Began {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let grant = authority?.grant(grantID).flatMap { $0.isActive(at: now) ? $0 : nil }
        return calls.begin(id, grant: grant)
    }

    /// A tool call ran: the grant was used (R17). The file gets it at most once an hour.
    func noteUse(_ grantID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var authority else { return }
        let now = clock()
        authority.noteUse(grantID, now: now)
        self.authority = authority
        do {
            try store.saveUse(clients: authority.clients, grants: authority.grants, now: now)
        } catch {
            NSLog("Next Term: Remote access could not save a use: \(error)")
        }
    }

    // MARK: on the Mac

    /// Revoke on the Mac: the grant ends, and its open calls are answered at once (R38).
    func revoke(grant grantID: String) {
        _ = update { authority, now in authority.revoke(grant: grantID, now: now) }
    }

    /// Revoke All.
    func revokeAll() {
        _ = update { authority, now in authority.revokeAll(now: now) }
    }

    /// New options for a grant, after Touch ID or the password (R60). They are saved before they apply; a failed
    /// save changes nothing. The grant's next streamed call carries the list-changed event.
    func changeOptions(of grantID: String, to options: RemoteAccessOptions) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var authority, var grant = authority.grant(grantID) else { return }
        let now = clock()
        grant.options = options
        let grants = RemoteAccessGrantStore.replacing(grant, in: authority.grants)
        try store.save(clients: authority.clients, grants: grants, now: now)
        saved = Saved(authority.clients, grants)
        authority.changeOptions(of: grantID, to: options)
        self.authority = authority
        settle(now: now)
    }

    /// Turn Off, or Turn Off and Revoke All (R37): access tokens dropped (every grant ended too with
    /// `revokeAll`), the refusal counts written, then every open call answered.
    func turnOff(revokeAll: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if revokeAll { _ = authority?.revokeAll(now: now) }
        authority?.dropAccessTokens()
        settle(now: now)
        var lines = [RemoteAccessAuditEntry.turnedOff(revokeAll: revokeAll, time: now)]
        lines += refusals.flush(now: now)
        append(lines, now: now)
        calls.turnOff()
    }

    // MARK: the audit log

    func audit(_ entries: [RemoteAccessAuditEntry]) {
        lock.lock()
        defer { lock.unlock() }
        append(entries, now: clock())
    }

    /// A request refused before a valid token, counted for its kind's line a minute (R39).
    func countRefusal(status: Int, request: RemoteAccessHTTP.Request?) {
        guard let kind = RemoteAccessRefusals.Kind(status: status) else { return }
        countRefusal(kind, request: request)
    }

    func countRefusal(_ kind: RemoteAccessRefusals.Kind, request: RemoteAccessHTTP.Request?) {
        let first = kind == .wrongHost ? request?.header("host") : request?.path
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        append(refusals.count(kind, first: first ?? "", now: now), now: now)
    }

    func writeDueRefusals() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        append(refusals.due(now: now), now: now)
    }

    // MARK: under the lock

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// After the authority changed: saves its clients and grants when they changed (their last uses aside), writes
    /// its events to the audit log, marks the list changed for each grant whose options changed, answers the open
    /// calls of each grant that ended, and tells the Mac.
    private func settle(now: Date) {
        guard var authority else { return }
        let current = Saved(authority.clients, authority.grants)
        if current != saved {
            do {
                try store.save(clients: authority.clients, grants: authority.grants, now: now)
                saved = current
            } catch {
                NSLog("Next Term: Remote access could not save its grants: \(error)")
            }
        }
        let events = authority.takeEvents()
        var ended: [String] = []
        var changed: [String] = []
        for event in events {
            switch event {
            case .revoked(let grantID, _, _):
                ended.append(grantID)
            case .optionsChanged(let grantID, _, _, _):
                // The registry keeps the mark: the grant's next streamed call carries the event (R20).
                _ = authority.takeToolListChanged(grantID)
                changed.append(grantID)
            default:
                break
            }
        }
        self.authority = authority
        guard !events.isEmpty else { return }
        append(events.map { RemoteAccessAuditEntry.event($0, time: now) }, now: now)
        for grantID in changed { calls.markListChanged(grantID) }
        if !ended.isEmpty { calls.revoke(grants: ended) }
        guard let onEvents else { return }
        DispatchQueue.main.async { onEvents(events) }
    }

    private func append(_ entries: [RemoteAccessAuditEntry], now: Date) {
        guard !entries.isEmpty else { return }
        do {
            try log.append(entries, now: now)
        } catch {
            NSLog("Next Term: Remote access could not write its audit log: \(error)")
        }
    }
}

// MARK: - pages (placeholder)

/// The pages `/oauth/authorize` and its wait show. A minimal placeholder: U8 replaces it with
/// `RemoteAccessPages` in Core, with its tests. It already keeps U8's rules: no script, no form, no external
/// resource, text from the request escaped, and headers that keep the page out of frames, referrers and caches.
enum RemoteAccessDoorPages {
    static func answer(_ authorization: RemoteAccessOAuth.Authorization) -> Data {
        switch authorization {
        case .redirect(let link):
            let headers = [("Location", link), ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer")]
            return RemoteAccessHTTP.response(status: 302, headers: headers)
        case .waiting(let requestID, let code):
            let wait = escaped(RemoteAccessOAuth.waitPath(for: requestID))
            let refresh = "<meta http-equiv=\"refresh\" content=\"2;url=\(wait)\">"
            return page(200, "<p>\(escaped(code))</p><p>Type this code in Next Term on your Mac.</p>", head: refresh)
        case .closed:
            let text = "Pairing is closed. On your Mac, open Next Term › Settings › Remote Access › Connect a Client."
            return page(200, "<p>\(escaped(text))</p>")
        case .expired:
            return page(200, "<p>Not approved in time. Start again from your Mac.</p>")
        case .tooMany:
            return page(429, "<p>Too many requests are waiting. Try again in a few minutes.</p>")
        case .invalid(let reason):
            return page(400, "<p>\(escaped(reason))</p>")
        }
    }

    private static func page(_ status: Int, _ body: String, head: String = "") -> Data {
        var html = "<!doctype html><html><head><meta charset=\"utf-8\">"
        html += "<title>Next Term</title>\(head)</head><body>\(body)</body></html>"
        var headers: [(String, String)] = []
        headers.append(("Content-Type", "text/html; charset=utf-8"))
        headers.append(("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'"))
        headers.append(("X-Frame-Options", "DENY"))
        headers.append(("Referrer-Policy", "no-referrer"))
        headers.append(("Cache-Control", "no-store"))
        return RemoteAccessHTTP.response(status: status, headers: headers, body: Data(html.utf8))
    }

    private static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
