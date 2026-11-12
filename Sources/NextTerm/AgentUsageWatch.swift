import AppKit
import Darwin
import NextTermCore

/// How full each local Claude Code and Codex tab's context is (`AgentUsage`), read every few seconds from the transcript
/// its own screen writes, and only when that file changed. The tab shows it as a small gauge after its title and in
/// its tooltip; `list_tabs` gives it as `context`. Started by the first tab that asks.
@MainActor
final class AgentUsageWatch {
    static let shared = AgentUsageWatch()

    static let interval: TimeInterval = 5
    /// Whose `~/.claude` and `~/.codex` are read: the self-test's own home instead of the user's.
    var home = NSHomeDirectory()

    /// By tab id.
    private(set) var usage: [UUID: AgentUsage] = [:]
    /// The transcript last read for a tab, and its size then.
    private var read: [UUID: (path: String, size: Int)] = [:]
    /// A Claude session's transcript path, once found (a look through the project folders).
    private var claudePaths: [String: String] = [:]
    private var timer: Timer?
    private var busy = false

    private init() {}

    /// Starts the polling the first time a tab asks.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { AgentUsageWatch.shared.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private struct Probe: Sendable {
        let tab: UUID
        let kind: AgentTranscript.Kind
        let agent: AgentKind
        let pid: Int32
        let resumed: String?
        let known: (path: String, size: Int)?
        let home: String
    }

    private struct Found: Sendable {
        let tab: UUID
        let path: String?
        let size: Int
        /// nil: unchanged since the last read, keep what shows.
        let usage: AgentUsage??
        let claudeID: String?
    }

    func poll() {
        guard !busy, let app = AppDelegate.shared else { return }
        var probes: [Probe] = []
        var live = Set<UUID>()
        for tab in app.controllers.flatMap(\.tabs) {
            guard let agent = tab.localAgent, let kind = AgentTranscript.Kind(agent: agent.rawValue) else { continue }
            let pid = tcgetpgrp(tab.view.process.childfd)
            guard pid > 0 else { continue }
            live.insert(tab.id)
            probes.append(Probe(tab: tab.id, kind: kind, agent: agent, pid: pid, resumed: agent.resumedID(in: tab.status.command),
                                known: read[tab.id], home: home))
        }
        for id in Array(usage.keys) where !live.contains(id) { usage[id] = nil }
        for id in Array(read.keys) where !live.contains(id) { read[id] = nil }
        guard !probes.isEmpty else { return }
        busy = true
        let paths = claudePaths
        Task.detached(priority: .utility) {
            let found = probes.map { Self.look($0, claudePaths: paths) }
            await MainActor.run { AgentUsageWatch.shared.take(found) }
        }
    }

    private func take(_ found: [Found]) {
        busy = false
        var changed = false
        for item in found {
            if let claudeID = item.claudeID, let path = item.path { claudePaths[claudeID] = path }
            guard let path = item.path else {
                if usage[item.tab] != nil { usage[item.tab] = nil; changed = true }
                read[item.tab] = nil
                continue
            }
            read[item.tab] = (path, item.size)
            if let new = item.usage, usage[item.tab] != new { usage[item.tab] = new; changed = true }
        }
        if claudePaths.count > 200 { claudePaths.removeAll() }
        if changed { AppDelegate.shared?.controllers.forEach { $0.refresh() } }
    }

    nonisolated private static func look(_ probe: Probe, claudePaths: [String: String]) -> Found {
        let home = probe.home
        var path: String?
        var claudeID: String?
        switch probe.kind {
        case .claude:
            guard let id = AgentSessions.sessionID(of: probe.agent, pid: probe.pid, home: home) ?? probe.resumed else { break }
            claudeID = id
            if let known = claudePaths[id], FileManager.default.fileExists(atPath: known) {
                path = known
            } else if case .success(let only) = AgentTranscript.only(AgentTranscript.candidates(.claude(id: id), home: home,
                                                                                                 environment: home == NSHomeDirectory() ? ProcessInfo.processInfo.environment : [:])) {
                path = only
            }
        case .codex:
            for pid in ProcessInspector.family(of: probe.pid).prefix(12) {
                if let rollout = ProcessInspector.openFiles(of: pid).first(where: { AgentLocation.isCodexRollout($0, home: home) }) {
                    path = rollout
                    break
                }
            }
        }
        guard let path else { return Found(tab: probe.tab, path: nil, size: 0, usage: nil, claudeID: claudeID) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if let known = probe.known, known.path == path, known.size == size {
            return Found(tab: probe.tab, path: path, size: size, usage: nil, claudeID: claudeID)
        }
        guard let tail = AgentTranscript.readTail(path) else { return Found(tab: probe.tab, path: path, size: size, usage: .some(nil), claudeID: claudeID) }
        return Found(tab: probe.tab, path: path, size: tail.size, usage: .some(AgentUsage.read(tail: tail.tail, kind: probe.kind)), claudeID: claudeID)
    }
}

extension TerminalTab {
    /// How full this agent's context is, when Next Term has read it (local Claude Code and Codex tabs).
    var contextUsage: AgentUsage? {
        let agent = localAgent != nil
        let id = id
        return MainActor.assumeIsolated {
            let watch = AgentUsageWatch.shared
            if agent { watch.start() }
            return watch.usage[id]
        }
    }
}

/// The small gauge after an agent tab's title: an arc filled as far as its context is, amber from
/// `AgentUsage.warnPercent`.
final class ContextGaugeView: NSView {
    static let size: CGFloat = 11
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    var usage: AgentUsage? {
        didSet {
            guard usage != oldValue else { return }
            isHidden = usage == nil
            apply()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        isHidden = true
        setAccessibilityElement(false) // the tab's own help says it
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let path = CGMutablePath()
        let inset = bounds.insetBy(dx: 1, dy: 1)
        // From twelve o'clock, clockwise (the view is not flipped: angles run counter-clockwise from three).
        path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2, startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, fill] {
            shape.frame = bounds
            shape.path = path
        }
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        guard let usage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = Theme.textDim.withAlphaComponent(0.3).cgColor
            fill.strokeColor = (usage.percent >= AgentUsage.warnPercent ? NSColor.systemOrange : Theme.textDim).cgColor
        }
        fill.strokeEnd = CGFloat(usage.percent) / 100
        CATransaction.commit()
    }

    /// For the self-test.
    var shownPercent: Int? { isHidden ? nil : usage?.percent }
}
