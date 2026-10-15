import AppKit
import Darwin
import NextTermCore

/// `secret_import` on the app's MCP socket: `nxtrm secret import`'s request, answered on its own connection, as
/// `secret_run` is (SecretSocket). It is not an MCP tool.
///
/// - **The peer.** Its audit token must pass `PeerCode`, its whole argv must read `…/NextTerm --cli secret import …`, and
///   that argv must equal the `argv_full` it sent. Anything else gets `refused`, with no window and a `refused` line in
///   the audit log.
/// - **The keys.** The header line holds none. For standard input the app answers `ready`, and only then reads the raw
///   body, exactly the byte count the header gave, into one buffer that Core's parse wipes. A body sent before `ready`
///   is refused: it would have passed through the socket's line reader, which never wipes what it read.
/// - **A file** is read by the app, as Import From › A File… reads one.
/// - **The answers** are counts only: `found` once the preview is open, then `imported` or `nothing` once it closes.
///   An importer that leaves meanwhile leaves the preview open.
enum SecretPipeSocket {
    static let tool = SecretImportPipe.tool

    /// Serves one importer's request on the serve thread. The MCP server's call closes `fd` when this returns.
    static func handle(fd: Int32, arguments: [String: Any], peer: pid_t?, auditToken token: audit_token_t?) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let token, let pid = peer, PeerCode.pid(token) == pid, PeerCode.current.isThisProgram(auditToken: token) else {
            return refuse(fd, reason: "the program at the socket is not Next Term's own nxtrm", pid: peer)
        }
        guard let request = SecretImportPipe.Request.decode(arguments), request.isWellFormed else {
            return refuse(fd, reason: "the import request could not be read", pid: pid)
        }
        guard let full = ProcessInspector.fullCommandLine(of: pid) else {
            return refuse(fd, reason: "its arguments are over the caps or can't be read", pid: pid)
        }
        guard SecretImportPipe.isImporter(full.arguments), full.arguments == request.argvFull else {
            return refuse(fd, reason: "its arguments are not nxtrm secret import's", pid: pid)
        }
        if PeerCode.usesPathFallback, !PeerCode.isSameProcess(socket: fd, as: token) {
            return refuse(fd, reason: "the process changed while it asked", pid: pid)
        }
        let agent: SecretSocket.Agent? = SecretSocket.agentAbove(pid)
        let format: SecretSources.Format? = request.format.flatMap(SecretImportPipe.format(named:))
        let channel = Channel(fd: fd)
        if let path = request.path {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let origin = SecretPipeImport.origin(pid: pid, agent: agent?.name, piped: false)
                    SecretPipeImport.openFile(path, format: format, origin: origin, channel: channel)
                }
            }
            return channel.serve()
        }
        guard !bytesWaiting(fd) else {
            return refuse(fd, reason: "it sent keys before Next Term was ready for them", pid: pid)
        }
        write(SecretImportPipe.Reply(status: .ready).line(), to: fd)
        var body = [UInt8](repeating: 0, count: request.bytes)
        guard readBody(fd, into: &body) else {
            SecretBytes.wipe(&body)
            return refuse(fd, reason: "its keys didn't all come", pid: pid)
        }
        // Parsed here, off the main thread; the parse wipes the body. Rows are checked against the vault as the
        // preview opens.
        let report: SourceReport = SecretSources.read(&body, name: SecretPipeImport.standardInput, format: format)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let origin = SecretPipeImport.origin(pid: pid, agent: agent?.name, piped: true)
                SecretPipeImport.openPiped(report, origin: origin, channel: channel)
            }
        }
        channel.serve()
    }

    /// Whether the importer has sent anything after its header: a byte waits, read nowhere yet.
    static func bytesWaiting(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    /// Reads exactly `body.count` bytes into `body`, each read within the serve thread's receive timeout.
    static func readBody(_ fd: Int32, into body: inout [UInt8]) -> Bool {
        var filled = 0
        let total: Int = body.count
        while filled < total {
            let count: Int = body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base + filled, total - filled)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            filled += count
        }
        return true
    }

    static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written: Int = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// `refused`, with no window, and a `refused` line in the audit log.
    private static func refuse(_ fd: Int32, reason: String, pid: pid_t?) {
        write(SecretImportPipe.Reply(status: .refused).line(), to: fd)
        let who: String = "a program at Next Term's socket" + (pid.map { (process: pid_t) -> String in " (process \(process))" } ?? "")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: [], who: who, outcome: reason))
            }
        }
    }
}

extension SecretPipeSocket {
    /// The importer's connection, between the main thread, which decides what to tell it, and the serve thread, which
    /// writes it and watches for the importer leaving.
    final class Channel: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [SecretImportPipe.Reply] = []
        private var ended = false
        private let fd: Int32

        init(fd: Int32) {
            self.fd = fd
        }

        /// Queues a reply for the importer; nothing once the connection has ended.
        func send(_ reply: SecretImportPipe.Reply) {
            lock.lock()
            if !ended { queued.append(reply) }
            lock.unlock()
        }

        /// Whether the importer is gone: the serve thread stopped, or its end of the connection closed.
        var hasLeft: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended || SecretRun.peerLeft(fd)
        }

        private func take() -> [SecretImportPipe.Reply] {
            lock.lock()
            defer { lock.unlock() }
            let replies: [SecretImportPipe.Reply] = queued
            queued = []
            return replies
        }

        private func end() {
            lock.lock()
            ended = true
            queued = []
            lock.unlock()
        }

        /// On the serve thread: writes each reply as it comes, until the last one, or until the importer leaves.
        func serve() {
            defer { end() }
            var scratch = [UInt8](repeating: 0, count: 256)
            while true {
                for reply in take() {
                    SecretPipeSocket.write(reply.line(), to: fd)
                    if reply.isLast { return }
                }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 200) > 0 else { continue }
                if SecretRun.peerLeft(fd) { return }
                // It sent more than it should: read and drop it.
                _ = recv(fd, &scratch, scratch.count, MSG_DONTWAIT)
                SecretBytes.wipe(&scratch)
            }
        }
    }
}
