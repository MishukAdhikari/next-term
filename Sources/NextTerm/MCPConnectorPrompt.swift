import AppKit
import NextTermCore

/// A window's connector bar and what it asks about (MCPConnectorAttention): the servers an agent in this window needed
/// and the user must mend, and the folder each was needed from (to find the server as its list has it now). Reported by
/// the hub where an agent's need ends (MCPHubRemoteControl, MCPHubControl.report); mended by the bar's own action or
/// anywhere else (Settings' Reconnect), seen on MCPHubControl.changed.
@MainActor
final class MCPConnectorPrompt {
    let bar = MCPConnectorBar()
    private(set) var items: [MCPConnectorAttention.Item] = []
    private var folders: [String: String] = [:]
    /// The bar's own action is under way: its sign-ins, one after another, or a retry.
    private var acting = false
    private var hideWork: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// Not Now, held for the app's run, for every window.
    static var held = MCPConnectorAttention.Held()

    init() {
        bar.onPrimary = { [weak self] in self?.primary() }
        bar.onNotNow = { [weak self] in self?.notNow() }
        bar.onSettings = { [weak self] in self?.openSettings() }
        bar.onCancel = { [weak self] in self?.cancelSignIn() }
        observer = NotificationCenter.default.addObserver(forName: MCPHubControl.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mendedElsewhere() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isShowing: Bool { !items.isEmpty && !bar.isHidden }

    func shows(url: String) -> Bool {
        let key = MCPHubOverview.signInKey(url)
        return isShowing && items.contains { $0.url.map(MCPHubOverview.signInKey) == key }
    }

    // MARK: reported

    /// An agent's need of a server ended in something only the user can mend.
    func add(_ item: MCPConnectorAttention.Item, folder: String) {
        guard !Self.held.holds(item) else { return }
        folders[item.key] = folder
        if let at = items.firstIndex(where: { $0.key == item.key }) {
            items[at] = item
        } else {
            items.append(item)
        }
        guard !acting else { return } // the bar's own sign-in shows its progress; this joins the list it walks
        hideWork?.cancel()
        bar.show(MCPConnectorAttention.words(items))
    }

    // MARK: actions

    private func primary() {
        guard let words = MCPConnectorAttention.words(items), let action = bar.shown?.action ?? words.action else { return }
        switch action {
        case .openSettings: openSettings()
        case .retry: retry()
        case .signIn: signIn(step: 1, of: items.filter { $0.need.signsIn }.count)
        }
    }

    private func notNow() {
        for item in items { Self.held.hold(item) }
        items = []
        bar.show(nil)
    }

    private func openSettings() {
        if let url = items.first?.url {
            AppDelegate.shared.showMCPServer(url: url)
        } else {
            AppDelegate.shared.showMCPServersSettings(nil)
        }
    }

    private func cancelSignIn() {
        for item in items { if let url = item.url { MCPHubSignIns.cancelSignIn(url) } }
    }

    /// Signs in to each server that needs it, one after another, the browser's progress in the bar.
    private func signIn(step: Int, of steps: Int) {
        guard let item = items.first(where: { $0.need.signsIn }) else { return finish(mended: true) }
        guard let server = server(for: item) else {
            items.removeAll { $0.key == item.key }
            return signIn(step: step, of: steps)
        }
        acting = true
        var scopes: [String]?
        if case .moreAccess(let wanted) = item.need, !wanted.isEmpty { scopes = wanted }
        bar.show(MCPConnectorAttention.browser(item.server, step: step, of: steps), cancellable: true)
        MCPHubSignIns.signIn(server, scopes: scopes, progress: { [weak self] _ in
            self?.bar.show(MCPConnectorAttention.browser(item.server, step: step, of: steps), cancellable: true)
        }, done: { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.acting = false
                return self.bar.show(MCPConnectorAttention.failed(failure, retry: .signIn))
            }
            Self.held.release(item.key)
            self.mended.append(item)
            self.items.removeAll { $0.key == item.key }
            if self.items.contains(where: { $0.need.signsIn }) {
                self.signIn(step: step + 1, of: steps)
            } else {
                self.finish(mended: true)
            }
        })
    }

    /// The servers mended by the bar's own action, for "connected".
    private var mended: [MCPConnectorAttention.Item] = []

    /// Check Now for a server out of reach (one whose URL and headers name no key: the others are reached only for an
    /// agent, so the agent's next call is the retry, and Settings is offered).
    private func retry() {
        guard let item = items.first(where: { if case .unreachable = $0.need { return true } else { return false } }),
              let server = server(for: item), MCPHubRemoteControl.canCheck(server), let folder = folders[item.key] else { return openSettings() }
        acting = true
        bar.show(MCPConnectorAttention.Words(message: "Reaching \(item.server)\u{2026}", primary: nil, action: nil, glyph: .working))
        MCPHubRemoteControl.check(server, list: item.list, folder: folder, userFile: MCPHubControl.userFile ?? MCPHubScope.userPath()) { [weak self] failure in
            guard let self else { return }
            self.acting = false
            if let failure { return self.bar.show(MCPConnectorAttention.failed(failure, retry: .retry)) }
            self.mended.append(item)
            self.items.removeAll { $0.key == item.key }
            self.finish(mended: true)
        }
    }

    /// Done acting: "connected" for a moment when everything was mended, else the rest still asked about.
    private func finish(mended done: Bool) {
        acting = false
        if !items.isEmpty { return bar.show(MCPConnectorAttention.words(items)) }
        let connected = mended
        mended = []
        guard done, !connected.isEmpty else { return bar.show(nil) }
        bar.show(MCPConnectorAttention.connected(connected))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.items.isEmpty, self.bar.shown?.glyph == .done else { return }
                self.bar.show(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectedFor, execute: work)
    }

    static var connectedFor: TimeInterval = 4

    /// Something changed in the hub: a server mended outside the bar (Settings' Reconnect, an agent's call that got
    /// through) leaves it, and the bar says "connected" when it was the last.
    private func mendedElsewhere() {
        guard !acting, !items.isEmpty else { return }
        let fixed = items.filter(isMended)
        guard !fixed.isEmpty else { return }
        for item in fixed { Self.held.release(item.key) }
        items.removeAll { item in fixed.contains { $0.key == item.key } }
        mended.append(contentsOf: fixed)
        finish(mended: true)
    }

    private func isMended(_ item: MCPConnectorAttention.Item) -> Bool {
        switch item.need {
        case .signIn, .reconnect, .moreAccess:
            guard let url = item.url, let record = MCPHubSignIns.record(for: url) else { return false }
            if case .signedIn = record.state { return !MCPHubSignIns.isSigningIn(url) }
            return false
        case .unreachable, .didntStart:
            let run = MCPHubControl.lastRuns[MCPHubOverview.runKey(list: item.list, server: item.server)]
            return run != nil && run?.failure == nil
        }
    }

    /// The server as its list has it now, from the folder its need came from.
    private func server(for item: MCPConnectorAttention.Item) -> MCPHubServer? {
        let file = MCPHubControl.userFile ?? MCPHubScope.userPath()
        let folder = folders[item.key] ?? NSHomeDirectory()
        return MCPHubScope.servers(folder: folder, userFile: file).servers
            .first { $0.name == item.server && $0.source.file == item.list }?.server
    }
}

/// Where the hub tells the bars: the calling tab's window, if it has one.
@MainActor
enum MCPConnectorPrompts {
    /// An agent's need of a server ended in `need`: the bar in its tab's window says so. An agent outside Next Term's tabs
    /// has no window; the notice is its prompt.
    static func report(_ need: MCPConnectorAttention.Need, server: String, list: String, url: String?, folder: String, caller: TerminalTab?) {
        guard let caller, let controller = AppDelegate.shared.controllers.first(where: { $0.tabs.contains { $0 === caller } }) else { return }
        var agent: String?
        if caller.status.running, caller.status.kind == .agent {
            agent = MCPHubSignInWords.agentTitle(MCPHubSignInWords.agentKey(program: caller.status.program))
        }
        let tab = controller.activeTab === caller ? nil : caller.title
        let item = MCPConnectorAttention.Item(server: server, list: list, url: url, need: need, agent: agent, tab: tab)
        controller.connector.add(item, folder: folder)
    }

    /// The need, from how a remote need ended and the sign-in's state now; nil for an answer only the agent can act on.
    static func need(server: MCPHubServer, kind: MCPHubRemote.Failure.Kind?, text: String) -> MCPConnectorAttention.Need? {
        if let record = MCPHubSignIns.record(for: server.url) {
            switch record.state {
            case .signedOut: return .reconnect
            case .needsMoreAccess(let scopes): return .moreAccess(scopes)
            case .signedIn, .refreshing: break
            }
        }
        if text == MCPHubSignInWords.needsSignIn(server.name) { return .signIn }
        if text == MCPHubSignInWords.tampered(server.name) || text == MCPHubSignInWords.lapsed(server.name) { return .reconnect }
        if text == MCPHubSignInWords.unreachable(server.name) || kind == .unreachable { return .unreachable(text) }
        return nil
    }

    /// Whether a window in front shows the bar for this server now: its notice would only repeat it.
    static func showing(url: String) -> Bool {
        guard NSApp.isActive else { return false }
        return AppDelegate.shared.controllers.contains { $0.window?.isVisible == true && $0.window?.occlusionState.contains(.visible) == true
            && $0.connector.shows(url: url) }
    }
}
