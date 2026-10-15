import Darwin
import Foundation
import NextTermCore

/// `nxtrm secret import [--from FORMAT] [FILE | -]`, run as the app binary in its command line mode: it opens the import
/// preview in the running Next Term and waits for the user there. A FILE goes as its absolute path, and the app reads
/// it. Standard input is read to its end, up to 5 MB, before anything is sent; then the header (no key in it), and only
/// after the app's `ready` the raw bytes, which are wiped here once sent.
///
/// It checks that the socket's owner is this same program before it sends anything, as `secret run` does. It prints
/// only fixed sentences with counts, on standard error: never a name, a value or any other byte of the input. It never
/// launches Next Term.
enum SecretPipe {
    /// How long the app has to take the header before the body.
    static let readyWait: TimeInterval = 15

    static func run(_ arguments: [String]) -> Never {
        let invocation: SecretImportPipe.Invocation
        switch SecretImportPipe.parse(arguments, standardInputIsTerminal: isatty(0) == 1) {
        case .help: end(.help)
        case .usage(let reason): end(.usage(reason))
        case .run(let parsed): invocation = parsed
        }
        var body: [UInt8] = []
        var path: String?
        switch invocation.input {
        case .file(let given):
            let full: String = absolute(given)
            guard access(full, F_OK) == 0 else { end(.noFile(given)) }
            path = full
        case .standardInput:
            switch SecretImportPipe.readAll(0, into: &body) {
            case .tooLarge: end(.tooLarge)
            case .failed: end(.empty)
            case .ended: if body.isEmpty { end(.empty) }
            }
        }
        let ending: SecretImportPipe.Ending = send(&body, path: path, format: invocation.format)
        end(ending)
    }

    /// Connects, sends the header and the body, and waits for the import to end. `body` is wiped before it returns,
    /// whatever happens.
    private static func send(_ body: inout [UInt8], path: String?, format: SecretSources.Format?) -> SecretImportPipe.Ending {
        defer {
            SecretBytes.wipe(&body)
            body = []
        }
        let fd: Int32 = SecretWrapper.connect(socketPath)
        guard fd >= 0 else { return .noSocket }
        defer { close(fd) }
        guard let token = PeerCode.auditToken(of: fd), PeerCode.current.isThisProgram(auditToken: token) else {
            return .peerCheck
        }
        let request = SecretImportPipe.Request(format: format?.rawValue, bytes: body.count, path: path,
                                               directory: FileManager.default.currentDirectoryPath,
                                               argvFull: CommandLine.arguments)
        guard let line = request.line(), SecretWrapper.send(line, on: fd) else { return .noSocket }
        let reader = ReplyReader(fd: fd)
        if !body.isEmpty {
            // The body goes only after `ready`: the app's line reader must never take a byte of it.
            if !sendsEagerly {
                switch reader.next(within: readyWait) {
                case .reply(let reply) where reply.status == .ready: break
                case .reply(let reply): return SecretImportPipe.ending(for: reply)
                case .closed, .timedOut: return .refused
                }
            }
            let sent: Bool = write(body, to: fd)
            SecretBytes.wipe(&body)
            body = []
            guard sent else { return .closed }
        }
        while true {
            switch reader.next(within: nil) {
            case .reply(let reply):
                switch reply.status {
                case .found: say(SecretImportPipe.text(.found(reply.count ?? 0)).line)
                case .unreadable: say(SecretImportPipe.text(.unreadable).line)
                default: return SecretImportPipe.ending(for: reply)
                }
            case .closed, .timedOut:
                return .closed
            }
        }
    }

    #if DEBUG
    static let eagerVariable = "NEXTTERM_SELFTEST_EAGER_BODY"
    #endif

    /// The self-test's importer that sends its keys before `ready`, which the app must refuse. A release build has none.
    private static var sendsEagerly: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[eagerVariable] == "1"
        #else
        return false
        #endif
    }

    /// The app's socket at its fixed path. A debug build takes the tab's `NEXTTERM_MCP_SOCKET`, so the self-test's
    /// line reaches the self-test's app, never the user's; the owner check holds either way.
    private static var socketPath: String {
        #if DEBUG
        if let socket = ProcessInfo.processInfo.environment[MCPServer.socketVariable], !socket.isEmpty { return socket }
        #endif
        return MCPServer.socketPath()
    }

    private static func absolute(_ path: String) -> String {
        let full: String = path.hasPrefix("/") ? path
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    private static func write(_ bytes: [UInt8], to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written: Int = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func end(_ ending: SecretImportPipe.Ending) -> Never {
        let result = SecretImportPipe.text(ending)
        say(result.line)
        exit(result.exit)
    }

    static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

extension SecretPipe {
    /// The app's reply lines, one at a time: what comes after a line in the same read waits for the next call. Replies
    /// hold counts only.
    final class ReplyReader {
        enum Read {
            case reply(SecretImportPipe.Reply)
            /// Next Term closed the connection, or sent what isn't a reply.
            case closed
            case timedOut
        }

        /// The longest reply line read.
        static let limit = 4096
        private let fd: Int32
        private var pending = Data()

        init(fd: Int32) {
            self.fd = fd
        }

        /// The next reply within `seconds`, or with no limit when nil.
        func next(within seconds: TimeInterval?) -> Read {
            let deadline: Date? = seconds.map { (wait: TimeInterval) -> Date in Date().addingTimeInterval(wait) }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                if let end = pending.firstIndex(of: 0x0A) {
                    let line: Data = pending[pending.startIndex..<end]
                    pending = Data(pending[(end + 1)...])
                    return SecretImportPipe.Reply.decode(line).map(Read.reply) ?? .closed
                }
                guard pending.count <= Self.limit else { return .closed }
                var waitMilliseconds: Int32 = 1000
                if let deadline {
                    let left: TimeInterval = deadline.timeIntervalSinceNow
                    guard left > 0 else { return .timedOut }
                    waitMilliseconds = Int32(min(1000, max(1, left * 1000)))
                }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready: Int32 = poll(&poller, 1, waitMilliseconds)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { continue }
                let count: Int = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return .closed }
                pending.append(contentsOf: buffer[0..<count])
            }
        }
    }
}
