import AppKit
import Network
import NextTermCore

/// An MCP server at a URL that Next Term couldn't reach is tried again on its own (MCPHubReconnect has the waits): while
/// Next Term is the active app, at once when the Mac wakes or the network comes back. A try is Settings' Check Now (one
/// need of the server's tools, its sign-in's token when it has one), so its end is the server's state everywhere it
/// shows: Settings › MCP Servers, and the bar at the foot of a window that asked about it, which then says it is back.
///
/// Only servers that need no key from Secrets (those are released only for an agent's need, on Secrets' panel) and no
/// sign-in the user must give. One timer at a time, set for the next try due; nothing runs while Next Term is in the
/// background, and nothing at all while no server is out of reach.
@MainActor
enum MCPHubReconnectControl {
    struct Watched {
        var entry: MCPHubReconnect.Entry
        let server: MCPHubServer
        let list: String
        let folder: String
        let userFile: String
    }

    private(set) static var watched: [String: Watched] = [:]
    private static var timer: DispatchWorkItem?
    private static var observers: [NSObjectProtocol] = []
    private static var network: NWPathMonitor?
    private static var networkWasUp = true
    /// The clock, for the tests.
    static var now: () -> Date = Date.init

    /// A need of the server ended: out of reach, it is watched; reached (or failed for another reason), it is not.
    static func noted(_ need: MCPHubRemoteControl.Need, run: MCPHubOverview.Run) {
        let key = MCPHubOverview.runKey(list: need.list, server: need.server.name)
        guard run.unreachable, MCPHubRemoteControl.canCheck(need.server) else {
            if watched.removeValue(forKey: key) != nil { schedule() }
            return
        }
        if var known = watched[key] {
            known.entry.tried(at: now())
            watched[key] = known
        } else {
            watched[key] = Watched(entry: MCPHubReconnect.Entry(lastTry: now()), server: need.server, list: need.list,
                                   folder: need.folder, userFile: need.userFile)
            start()
        }
        schedule()
    }

    /// Whether Next Term is trying the server again on its own, for Settings' words.
    static func isWatching(list: String, server: String) -> Bool { watched[MCPHubOverview.runKey(list: list, server: server)] != nil }

    // MARK: when

    private static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { tryDue() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { startOver() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if up && !networkWasUp { startOver() }
                    networkWasUp = up
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "nextterm.hub-reconnect.network"))
        network = monitor
    }

    private static func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        network?.cancel()
        network = nil
        timer?.cancel()
        timer = nil
    }

    /// The Mac woke, or the network came back: every watched server is due at once.
    static func startOver() {
        let at = now()
        for key in watched.keys { watched[key]?.entry.startOver(at: at) }
        tryDue()
    }

    /// One timer, for the soonest try due.
    private static func schedule() {
        timer?.cancel()
        timer = nil
        guard !watched.isEmpty else { return stop() }
        guard let next = MCPHubReconnect.next(watched.mapValues(\.entry)) else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { tryDue() } }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now())), execute: work)
    }

    /// Tries the servers due, while Next Term is the active app; the rest wait for it to be.
    static func tryDue() {
        guard NSApp.isActive || SelfTest.isRequested else { return schedule() }
        for key in MCPHubReconnect.due(watched.mapValues(\.entry), at: now()) {
            guard let item = watched[key] else { continue }
            // Marked tried now: a check that fails comes back through noted, which counts it again only as a later try.
            watched[key]?.entry.lastTry = now()
            MCPHubRemoteControl.check(item.server, list: item.list, folder: item.folder, userFile: item.userFile) { _ in }
        }
        schedule()
    }
}
