import AppKit
import Darwin
import NextTermCore

/// The live chat of one agent tab (plan 041 U2): the session file its agent writes, found as the context gauge finds it
/// (AgentUsageWatch.transcriptPath) or, for Command Code, in its projects folder (LiveChat.commandCodeFile); watched
/// for what is appended (a file event, and a look every second for a file that moved), read off the main thread from
/// where the last read ended, and handed on as items. A new session in the tab (/clear, a resume) is a new file: the
/// items start again. Nothing is read until a chat view asks for the feed, and nothing after it lets the feed go.
@MainActor
final class LiveChatFeed {
    let tabID: UUID
    let agent: LiveChat.Agent
    /// The file read now, nil while none is found.
    private(set) var path: String?
    /// Every item read from it, in order.
    private(set) var items: [LiveChat.Item] = []
    /// Called on the main thread with the items just read, or with `reset` when the items started again (a new file).
    var onChange: ((_ added: [LiveChat.Item], _ reset: Bool) -> Void)?

    private weak var tab: TerminalTab?
    private var reader: LiveChat.Reader?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var reading = false
    private var again = false
    private static let queue = DispatchQueue(label: "nt.live-chat", qos: .utility)

    init(tab: TerminalTab, agent: LiveChat.Agent) {
        self.tab = tab
        self.tabID = tab.id
        self.agent = agent
    }

    /// Starts finding and following the file.
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

    /// Finds the file (it may have changed), then reads what was appended.
    private func look() {
        guard let tab, tab.localAgent.flatMap(LiveChat.Agent.init) == agent else { return }
        let pid = tcgetpgrp(tab.view.process.childfd)
        guard pid > 0 else { return }
        let agent = self.agent, kind = tab.localAgent, resumed = tab.localAgent?.resumedID(in: tab.status.command)
        let folder = tab.directory, home = LiveChatWatch.home
        Self.queue.async { [weak self] in
            // A session written to since the agent started (its process's start, a little before): not an older one.
            let since = (ProcessInspector.startTime(of: pid) ?? .distantPast).addingTimeInterval(-5)
            let found = Self.locate(agent: agent, kind: kind, pid: pid, resumed: resumed, folder: folder, since: since, home: home)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow(found) }
            }
        }
    }

    nonisolated static func locate(agent: LiveChat.Agent, kind: AgentKind?, pid: Int32, resumed: String?, folder: String,
                                   since: Date, home: String) -> String? {
        switch agent {
        case .claude:
            guard let kind else { return nil }
            return AgentUsageWatch.transcriptPath(kind: .claude, agent: kind, pid: pid, resumed: resumed, home: home).path
        case .codex:
            guard let kind else { return nil }
            return AgentUsageWatch.transcriptPath(kind: .codex, agent: kind, pid: pid, resumed: resumed, home: home).path
        case .commandCode:
            return LiveChat.commandCodeFile(folder: folder, since: since, id: resumed, home: home)
        }
    }

    private func follow(_ found: String?) {
        guard let found else { return }
        if found != path {
            path = found
            reader = nil
            let had = !items.isEmpty
            items = []
            if had { onChange?([], true) }
            watch(found)
        }
        read()
    }

    private func watch(_ path: String) {
        source?.cancel()
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

    /// Reads from where the last read ended to the end, off the main thread. A file that got shorter was rewritten:
    /// it is read again from its start.
    private func read() {
        guard let path else { return }
        if reading {
            again = true
            return
        }
        reading = true
        let agent = self.agent
        let current = reader
        Self.queue.async { [weak self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            var reader = current ?? LiveChat.Reader(agent: agent, start: LiveChat.Reader.start(size: size))
            var restarted = false
            if size < reader.offset {
                reader = LiveChat.Reader(agent: agent, start: LiveChat.Reader.start(size: size))
                restarted = true
            }
            var added: [LiveChat.Item] = []
            if size > reader.offset, let handle = FileHandle(forReadingAtPath: path) {
                try? handle.seek(toOffset: UInt64(reader.offset))
                let data = (try? handle.read(upToCount: size - reader.offset)) ?? Data()
                try? handle.close()
                added = reader.feed(data)
            }
            let result = reader
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.take(added, reader: result, path: path, restarted: restarted) }
            }
        }
    }

    private func take(_ added: [LiveChat.Item], reader: LiveChat.Reader, path: String, restarted: Bool) {
        reading = false
        guard path == self.path else { return }
        self.reader = reader
        if restarted {
            items = added
            onChange?(added, true)
        } else if !added.isEmpty {
            items += added
            onChange?(added, false)
        }
        if again {
            again = false
            read()
        }
    }
}

/// The feeds of the tabs whose chat view is open, by tab id.
@MainActor
enum LiveChatWatch {
    private static var feeds: [UUID: LiveChatFeed] = [:]
    /// Whose agent folders are read: the self-test's own home instead of the user's.
    static var home = NSHomeDirectory()

    /// Whether `tab` can show a live chat: a local tab running Claude Code, Codex or Command Code.
    static func offers(_ tab: TerminalTab) -> Bool {
        tab.localAgent.flatMap(LiveChat.Agent.init) != nil
    }

    /// The feed of `tab`, started when first asked for; nil for a tab that offers none.
    static func feed(for tab: TerminalTab) -> LiveChatFeed? {
        guard let agent = tab.localAgent.flatMap(LiveChat.Agent.init) else { return nil }
        if let feed = feeds[tab.id], feed.agent == agent { return feed }
        feeds[tab.id]?.stop()
        let feed = LiveChatFeed(tab: tab, agent: agent)
        feeds[tab.id] = feed
        feed.start()
        return feed
    }

    /// The tab's chat view closed: its feed stops.
    static func release(_ tab: TerminalTab) {
        feeds.removeValue(forKey: tab.id)?.stop()
    }
}
