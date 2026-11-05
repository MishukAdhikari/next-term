import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One local MCP server an agent's bridge started for its session (R16): a child process spoken to over its stdin and
/// stdout, one JSON-RPC message a line. It starts on first need (`tools`, `call`), and ends with the bridge (`stop`),
/// or when it stops by itself; the next need starts it again.
///
/// Everything that can go wrong ends in a sentence for the agent, never a hang or a crash: a program not found, no answer
/// within the limits, an exit (with the last of what it wrote to stderr), output that isn't MCP (counted, the first line
/// quoted), and a message over `Limits.message`, which stops it.
public final class MCPHubUpstream: @unchecked Sendable {
    public struct Limits: Sendable {
        /// From starting the program to its tool list. `nxtrm secret run` may wait up to 25 seconds for the user's approval.
        public var start: TimeInterval = 30
        /// A whole catalog call, starting included: under the 60 seconds agents give a tool call (Codex's tool_timeout_sec).
        public var call: TimeInterval = 50
        /// The longest message read: a server past it is stopped.
        public var message = 32 * 1024 * 1024

        public init(start: TimeInterval = 30, call: TimeInterval = 50, message: Int = 32 * 1024 * 1024) {
            self.start = start
            self.call = call
            self.message = message
        }

        public static let standard = Limits()
    }

    /// What is started: the program (a full path), its arguments, its whole environment and its folder.
    public struct Launch: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var directory: String

        public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
        }
    }

    /// Why a need wasn't met, as a sentence for the agent.
    public struct Failure: Error, Equatable, Sendable {
        public let text: String
        public init(_ text: String) { self.text = text }
    }

    public let name: String
    public let launch: Launch
    let limits: Limits
    let clientVersion: String

    private let lock = NSLock()
    /// Held while starting, so a second need waits for the first one's start.
    private let starting = NSLock()
    private let writing = NSLock()
    private var process: Process?
    private var input: Int32 = -1
    private var nextID = 1
    private var pending: [Int: Waiter] = [:]
    /// Its tool list, once it started.
    private var listed: [[String: Any]]?
    /// Why it stopped, once it has: every need until the next start is told this.
    private var ended: String?
    private var lastFailure: String?
    private var stderrTail = Data()
    private var garbage = 0
    private var firstGarbage: String?

    public init(name: String, launch: Launch, limits: Limits = .standard, clientVersion: String) {
        self.name = name
        self.launch = launch
        self.limits = limits
        self.clientVersion = clientVersion
    }

    // MARK: state

    public enum Status: Equatable, Sendable {
        case notStarted
        case running(tools: Int)
        case failed(String)
    }

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        if let listed, ended == nil { return .running(tools: listed.count) }
        if let lastFailure { return .failed(lastFailure) }
        return .notStarted
    }

    // MARK: needs

    /// Its tools as it listed them, starting it first if it isn't running.
    public func tools(until deadline: Date) -> Result<[[String: Any]], Failure> {
        lock.lock()
        if let listed, ended == nil { lock.unlock(); return .success(listed) }
        lock.unlock()
        guard starting.lock(before: deadline) else {
            return .failure(Failure("\(name) is still starting for another call; try again in a moment."))
        }
        defer { starting.unlock() }
        lock.lock()
        if let listed, ended == nil { lock.unlock(); return .success(listed) }
        lock.unlock()
        let result = start(until: min(deadline, Date().addingTimeInterval(limits.start)))
        lock.lock()
        switch result {
        case .success(let tools):
            listed = tools
            lastFailure = nil
        case .failure(let failure):
            lastFailure = failure.text
        }
        lock.unlock()
        return result
    }

    /// Calls one of its tools: the result object it answered (content, isError, structuredContent), as it is.
    public func call(_ tool: String, arguments: [String: Any], until deadline: Date) -> Result<[String: Any], Failure> {
        if case .failure(let failure) = tools(until: deadline) { return .failure(failure) }
        switch request("tools/call", ["name": tool, "arguments": arguments], until: deadline) {
        case .failure(let failure): return .failure(failure)
        case .success(let answer):
            if let error = answer["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "no message"
                return .failure(Failure("\(name) answered \(tool) with an error: \(message)"))
            }
            guard let result = answer["result"] as? [String: Any] else {
                return .failure(Failure("\(name) answered \(tool) with something that isn't a tool's result."))
            }
            return .success(result)
        }
    }

    /// Ends it: its stdin closes, which ends a well-behaved server; one still running a moment later is terminated, then
    /// killed.
    public func stop() {
        lock.lock()
        let running = process
        process = nil
        let fd = input
        input = -1
        listed = nil
        if running != nil { ended = "\(name) was stopped." }
        lock.unlock()
        if fd >= 0 { close(fd) }
        guard let running else { return }
        for (wait, signal) in [(0.5, SIGTERM), (1.0, SIGKILL)] {
            let until = Date().addingTimeInterval(wait)
            while running.isRunning, Date() < until { usleep(20_000) }
            guard running.isRunning else { return }
            kill(running.processIdentifier, signal)
        }
    }

    // MARK: starting

    private func start(until deadline: Date) -> Result<[[String: Any]], Failure> {
        stop() // what is left of the last run
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            return .failure(Failure("\(name) didn't start: \(launch.executable) is not a program this Mac can run."))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.directory, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(Failure("\(name) didn't start: its folder, \(launch.directory), is not there."))
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: launch.executable)
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }
        do {
            try child.run()
        } catch {
            return .failure(Failure("\(name) didn't start: \(error.localizedDescription)"))
        }
        let fd = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1) // a server gone while we write: an error, not this process's end
        lock.lock()
        process = child
        input = dup(fd)
        ended = nil
        stderrTail = Data()
        garbage = 0
        firstGarbage = nil
        lock.unlock()
        // Its own descriptor (`dup`), closed when it stops; Process closes the child's ends of the pipes itself.
        try? stdin.fileHandleForWriting.close()
        let reader = Thread { [weak self] in self?.read(stdout.fileHandleForReading, of: child, exited: exited) }
        reader.stackSize = 1 << 20
        reader.start()
        let errors = Thread { [weak self] in self?.readErrors(stderr.fileHandleForReading) }
        errors.start()

        let hello: [String: Any] = [
            "protocolVersion": MCPServer.supportedVersions[1], "capabilities": [String: Any](),
            "clientInfo": ["name": MCPServer.name, "title": "Next Term", "version": clientVersion],
        ]
        let started: [String: Any]
        switch request("initialize", hello, until: deadline, starting: true) {
        case .failure(let failure):
            stop()
            return .failure(failure)
        case .success(let answer): started = answer
        }
        if let error = started["error"] as? [String: Any] {
            stop()
            return .failure(Failure("\(name) refused to start: \(error["message"] as? String ?? "no reason given")."))
        }
        notify("notifications/initialized")
        var tools: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<50 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let page: [String: Any]
            switch request("tools/list", params, until: deadline, starting: true) {
            case .failure(let failure):
                stop()
                return .failure(failure)
            case .success(let answer): page = answer
            }
            guard let result = page["result"] as? [String: Any], let found = result["tools"] as? [[String: Any]] else {
                stop()
                return .failure(Failure("\(name) started, and its tool list isn't one MCP has."))
            }
            tools += found.filter { $0["name"] is String }
            cursor = result["nextCursor"] as? String
            if cursor == nil || tools.count >= 2_000 { break }
        }
        return .success(tools)
    }

    // MARK: messages

    private final class Waiter: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var answer: [String: Any]?
        var failure: String?
    }

    /// One request and its answer (the whole message, its `result` or `error` in it).
    private func request(_ method: String, _ params: [String: Any], until deadline: Date, starting: Bool = false)
        -> Result<[String: Any], Failure> {
        let waiter = Waiter()
        lock.lock()
        if let ended {
            lock.unlock()
            return .failure(Failure(ended))
        }
        let id = nextID
        nextID += 1
        pending[id] = waiter
        lock.unlock()
        guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
            lock.lock()
            pending[id] = nil
            let why = ended ?? "\(name) stopped reading what Next Term sends it."
            lock.unlock()
            return .failure(Failure(why))
        }
        if waiter.done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
            lock.lock()
            let late = pending.removeValue(forKey: id) == nil
            let noise = garbageNote
            lock.unlock()
            if !late {
                if !starting { notify("notifications/cancelled", ["requestId": id, "reason": "Next Term stopped waiting"]) }
                let what = starting ? "start" : "call"
                return .failure(Failure("\(name) didn't answer Next Term's \(what) in time" + (noise.map { "; " + $0 } ?? ".")))
            }
            waiter.done.wait() // answered as the wait ran out
        }
        if let failure = waiter.failure { return .failure(Failure(failure)) }
        return .success(waiter.answer ?? [:])
    }

    private func notify(_ method: String, _ params: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        _ = send(message)
    }

    /// Writes one message: false when it couldn't be written (the server is gone).
    private func send(_ message: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return false }
        data.append(0x0A)
        writing.lock()
        defer { writing.unlock() }
        lock.lock()
        let fd = input
        lock.unlock()
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Its stdout, line by line, until it closes.
    private func read(_ handle: FileHandle, of child: Process, exited: DispatchSemaphore) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        var line = Data()
        var why: String?
        reading: while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            var start = 0
            for index in 0..<count where buffer[index] == 0x0A {
                line.append(contentsOf: buffer[start..<index])
                received(line)
                line.removeAll(keepingCapacity: true)
                start = index + 1
            }
            line.append(contentsOf: buffer[start..<count])
            if line.count > limits.message {
                let most = ByteCountFormatter.string(fromByteCount: Int64(limits.message), countStyle: .binary)
                why = "\(name) sent a message over the \(most) Next Term reads, so Next Term stopped it."
                kill(child.processIdentifier, SIGKILL)
                break reading
            }
        }
        try? handle.close()
        if why == nil {
            _ = exited.wait(timeout: .now() + 2)
            let status = child.isRunning ? nil : child.terminationStatus
            let reason = child.isRunning ? nil : child.terminationReason
            lock.lock()
            let said = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            var text = "\(name) stopped"
            if let status { text += reason == .uncaughtSignal ? " (signal \(status))" : " (exit status \(status))" }
            if !said.isEmpty { text += ". The last it wrote to stderr: " + String(said.suffix(600)) }
            why = text + "."
        }
        end(why ?? "\(name) stopped.", child: child)
    }

    /// The last 4 KB of its stderr, for why it stopped.
    private func readErrors(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            lock.lock()
            stderrTail.append(contentsOf: buffer[0..<count])
            if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
            lock.unlock()
        }
        try? handle.close()
    }

    private func received(_ line: Data) {
        let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        guard !trimmed.isEmpty else { return }
        guard let message = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else {
            lock.lock()
            garbage += 1
            if firstGarbage == nil { firstGarbage = String(decoding: trimmed.prefix(160), as: UTF8.self) }
            lock.unlock()
            return
        }
        if let method = message["method"] as? String {
            // A request of its own: Next Term offers no capability a server may ask of it, so only a ping is answered.
            guard let id = message["id"], !(id is NSNull) else { return }
            if method == "ping" { _ = send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()]) }
            else { _ = send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Next Term doesn't offer \(method)"]]) }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let waiter = pending.removeValue(forKey: id)
        lock.unlock()
        waiter?.answer = message
        waiter?.done.signal()
    }

    /// It stopped: every need waiting is told why, and so is each one until the next start.
    private func end(_ why: String, child: Process) {
        lock.lock()
        // Stopped by Next Term (`stop`, no process now): its needs are told, and why it was stopped stays. A later run's
        // process: nothing of this one's is left to tell.
        guard process === child || process == nil else { lock.unlock(); return }
        if process === child {
            ended = why
            lastFailure = why
            listed = nil
            process = nil
        }
        let waiting = pending
        pending = [:]
        let fd = input
        input = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        for waiter in waiting.values {
            waiter.failure = why
            waiter.done.signal()
        }
    }

    /// What it wrote that isn't MCP, for a message about a wait that ran out (call with `lock` held).
    private var garbageNote: String? {
        guard garbage > 0, let firstGarbage else { return nil }
        let lines = garbage == 1 ? "a line" : "\(garbage) lines"
        return "it wrote \(lines) to its output that \(garbage == 1 ? "isn't" : "aren't") MCP, the first: \(firstGarbage)"
    }
}
