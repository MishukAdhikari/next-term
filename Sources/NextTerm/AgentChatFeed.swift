import AppKit
import Darwin
import NextTermCore

/// The chat of one agent session tab (plan 047 U3): the journal `nxtrm agent` writes as its session changes, named in its
/// report (AgentSessionSocket), replayed into a session of the app's own. The file is watched for what is appended (a
/// file event, and a look every second for a new journal: a session started again in the tab) and read off the main
/// thread from where the last read ended. Every text is masked as it is read. Nothing is read until a chat view asks.
@MainActor
final class AgentChatFeed {
    let tabID: UUID
    /// The journal read now, nil while the tab's session has reported none.
    private(set) var path: String?
    /// The session as the journal has built it so far.
    private(set) var session = ACPSession()
    /// Called on the main thread after the session changed; `reset` when it started again (a new journal).
    var onChange: ((_ reset: Bool) -> Void)?

    private var reader = ACPSessionJournal.Reader()
    private var offset = 0
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var reading = false
    private var again = false
    private static let queue = DispatchQueue(label: "nt.agent-chat", qos: .userInitiated)

    init(tabID: UUID) {
        self.tabID = tabID
    }

    /// Starts following the tab's journal.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        look()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.cancel()
        source = nil
    }

    /// Follows the journal the tab's session reports now (a new one when the session started again), then reads.
    private func look() {
        let reported = AgentSessionSocket.reports[tabID]?.journal
        if reported != path {
            path = reported
            reader = ACPSessionJournal.Reader()
            offset = 0
            session = ACPSession()
            source?.cancel()
            source = nil
            if let reported { watch(reported) }
            onChange?(true)
        }
        read()
    }

    private func watch(_ path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Reads what was appended since the last read, off the main thread, and replays it.
    private func read() {
        guard let path else { return }
        if reading {
            again = true
            return
        }
        reading = true
        let from = offset
        var reader = self.reader
        var session = self.session
        Self.queue.async { [weak self] in
            var data = Data()
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.seek(toOffset: UInt64(from))
                data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
            }
            let ops = reader.feed(data)
            for op in ops {
                ACPSessionJournal.apply(ACPSessionJournal.masked(op) { MCPRedaction.redact($0).text }, to: &session)
            }
            let read = data.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.take(session: session, reader: reader, read: read, changed: !ops.isEmpty, path: path)
                }
            }
        }
    }

    private func take(session: ACPSession, reader: ACPSessionJournal.Reader, read: Int, changed: Bool, path: String) {
        reading = false
        guard path == self.path else { return }
        self.reader = reader
        self.session = session
        offset += read
        if changed { onChange?(false) }
        if again {
            again = false
            self.read()
        }
    }
}

/// The feeds of the agent session tabs whose chat view is open, and the journals the app removes.
@MainActor
enum AgentChatWatch {
    private static var feeds: [UUID: AgentChatFeed] = [:]

    /// Whether `tab` can show a native chat: an agent session tab whose session reported its journal.
    static func offers(_ tab: TerminalTab) -> Bool {
        tab.status.running && tab.status.program == CommandClassifier.agentSessionProgram
            && AgentSessionSocket.reports[tab.id]?.journal != nil
    }

    /// The feed of `tab`, started on first use.
    static func feed(for tab: TerminalTab) -> AgentChatFeed {
        if let feed = feeds[tab.id] { return feed }
        let feed = AgentChatFeed(tabID: tab.id)
        feeds[tab.id] = feed
        feed.start()
        return feed
    }

    /// The tab closed: its feed stops and its session's journal is removed.
    static func closed(_ tabID: UUID) {
        feeds.removeValue(forKey: tabID)?.stop()
        if let journal = AgentSessionSocket.reports[tabID]?.journal { try? FileManager.default.removeItem(atPath: journal) }
    }

    /// At launch: journals left by sessions of an earlier run (nothing replays them) are removed.
    static func removeLeftovers(socket: String) {
        let folder = ACPSessionJournal.folder(socket: socket)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
            try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
        }
    }
}
