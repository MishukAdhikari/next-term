import AppKit
import NextTermCore
import SwiftTerm

/// Tab completion's folders and files on servers (Connect VPS), over a tab's own connection: a script that lists
/// one folder and writes nothing (RemoteListing). Sessions on a connection are scarce: sshd allows MaxSessions (10
/// by default) on one, every tab is one, and so is every check (RemoteConnection.tabsPerMaster). A refused one
/// pauses every check on that connection for 30 s, status polling included. So: one listing at a time per
/// connection, shared by a Tab and the prefetch; none on a connection that already carries 7 tabs; and a short
/// cache per host and folder.
final class RemoteCompletion {
    static let shared = RemoteCompletion()

    /// How long a listing is good for, and how long a Tab waits for one before it is the shell's own.
    static let cacheSeconds: TimeInterval = 10
    static let deadline: TimeInterval = 0.8

    private struct Cached {
        let time: TimeInterval
        let result: RemoteListing.Result
    }
    private var cache: [String: Cached] = [:]
    /// The listing running on each connection (by control path): its key, and who waits for it.
    private var inFlight: [String: (key: String?, waiters: [(RemoteListing.Result?) -> Void])] = [:]
    /// How long the last listing on each connection took: about one round trip.
    private var roundTrips: [String: TimeInterval] = [:]
    /// The folder last prefetched for each tab.
    private var prefetched: [ObjectIdentifier: String] = [:]

    /// What a word on a server's screen asks to list, and its key in the cache: nil for a folder relative to a
    /// shell whose folder the status checks don't report (no /proc there), which is listed afresh each time.
    struct Request {
        let folder: RemoteListing.Folder
        let key: String?
    }

    func request(for word: ScreenWord, in tab: TerminalTab) -> Request? {
        request(typed: word.folder, in: tab)
    }

    /// A folder as typed: absolute, from the server's home (`~/`), or relative to the shell's own folder.
    func request(typed: String, in tab: TerminalTab) -> Request? {
        guard let remote = tab.remote else { return nil }
        let place: String
        if typed.hasPrefix("/") {
            place = (typed as NSString).standardizingPath
        } else if typed.hasPrefix("~/") {
            place = typed // the server's home: never expanded here
        } else {
            guard Self.live(tab) != .none else { return nil }
            guard tab.completion.serverFolderKnown, tab.directory.hasPrefix("/") else { return Request(folder: .typed(typed), key: nil) }
            place = ((tab.directory as NSString).appendingPathComponent(typed) as NSString).standardizingPath
        }
        return Request(folder: .typed(typed), key: remote.host.id + "\u{0}" + place)
    }

    /// An absolute folder on the server (from a hooked shell's report).
    func request(absolute folder: String, in tab: TerminalTab) -> Request? {
        guard let remote = tab.remote, folder.hasPrefix("/") else { return nil }
        return Request(folder: .absolute(folder), key: remote.host.id + "\u{0}" + (folder as NSString).standardizingPath)
    }

    /// Where a tab's shell's own folder is read on the server.
    static func live(_ tab: TerminalTab) -> RemoteListing.Live {
        guard let remote = tab.remote else { return .none }
        if tab.fellBack { return .pid(tabKey: tab.remoteKey) }
        switch remote.keep {
        case .tmux: return .tmux(session: remote.session)
        case .off: return .pid(tabKey: tab.remoteKey)
        case .herdr: return .none
        }
    }

    /// The tab's connection can take a listing: it is up, carries fewer than 7 tabs, and hasn't refused a session
    /// lately.
    func hasRoom(for tab: TerminalTab) -> Bool {
        guard let remote = tab.remote, let path = tab.controlPath, RemoteConnection.refusal(remote.host) == nil else { return false }
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs).filter { !$0.exited && $0.controlPath == path }
        return tabs.count < RemoteConnection.tabsPerMaster && RemoteConnection.masterAlive(path: path)
    }

    /// About one round trip on the tab's connection (the last listing's time), between 20 and 200 ms.
    func roundTrip(for tab: TerminalTab) -> TimeInterval {
        let measured = tab.controlPath.flatMap { roundTrips[$0] } ?? 0.08
        return min(0.2, max(0.02, measured))
    }

    /// The listing for `request`: from the cache at once, or the one running for it, or a new one. False, and
    /// `done` never called: none can be made now (another listing runs on that connection, or it has no room).
    func list(_ request: Request, for tab: TerminalTab, done: @escaping (RemoteListing.Result?) -> Void) -> Bool {
        let now = TerminalTab.now
        cache = cache.filter { now - $0.value.time < Self.cacheSeconds }
        if let key = request.key, let cached = cache[key] {
            done(cached.result)
            return true
        }
        guard let path = tab.controlPath else { return false }
        if let running = inFlight[path] {
            guard running.key != nil, running.key == request.key else { return false }
            inFlight[path]?.waiters.append(done)
            return true
        }
        guard hasRoom(for: tab), let host = tab.remote?.host else { return false }
        inFlight[path] = (request.key, [done])
        let started = now
        RemoteConnection.run(host, path: path, script: RemoteListing.script(request.folder, live: Self.live(tab)), timeout: 10) { [weak self] output in
            guard let self else { return }
            let waiters = self.inFlight.removeValue(forKey: path)?.waiters ?? []
            let result = output.status == 0 ? RemoteListing.parse(output.output) : nil
            if output.status >= 0 { self.roundTrips[path] = TerminalTab.now - started }
            if let result, let key = request.key { self.cache[key] = Cached(time: TerminalTab.now, result: result) }
            for waiter in waiters { waiter(result) }
        }
        return true
    }

    /// A status report moved the tab in front to another folder: list it now, so its first Tab answers at once.
    /// Only with Tab completion on, and within the connection's room.
    func prefetch(_ tab: TerminalTab) {
        guard CompletionPreferences.isOn, tab.status.visible, tab.completion.usesScreen, !tab.status.running,
              prefetched[ObjectIdentifier(tab)] != tab.directory else { return }
        guard let path = tab.controlPath, inFlight[path] == nil, let request = request(typed: "", in: tab), request.key != nil else { return }
        prefetched[ObjectIdentifier(tab)] = tab.directory
        _ = list(request, for: tab) { _ in }
    }

    /// For the self-test: listings kept, and whether one runs on a connection.
    var cachedKeys: [String] { Array(cache.keys) }
    func isListing(on path: String) -> Bool { inFlight[path] != nil }
    func forget() {
        cache = [:]
        prefetched = [:]
    }
}

extension TerminalTab {
    /// The cursor's line left of the cursor, its wrapped rows joined: what a word on a server's screen is read from
    /// (cells never written read as blanks). nil when the cursor isn't on the visible screen.
    func lineLeftOfCursor() -> String? {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        let atBottom = !view.canScroll || view.scrollPosition >= 1
        guard atBottom, let line = terminal.getLine(row: cursor.y) else { return nil }
        func text(_ line: BufferLine, to end: Int) -> String {
            line.translateToString(trimRight: false, startCol: 0, endCol: end, skipNullCellsFollowingWide: true) { cell in
                let character = cell.getCharacter()
                return character == "\u{0}" ? " " : character
            }
        }
        var left = text(line, to: min(cursor.x, terminal.cols))
        var row = cursor.y
        var current = line
        while current.isWrapped, row > 0, let previous = terminal.getLine(row: row - 1) {
            left = text(previous, to: terminal.cols) + left
            current = previous
            row -= 1
        }
        return left
    }
}
