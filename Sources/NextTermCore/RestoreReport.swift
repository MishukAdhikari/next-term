import Foundation

/// Why each pane came back as it did (plan 046): `last-restore.json` in the sessions folder, written by every launch that
/// holds the folder and replaced by the next, never removed after the restore. It says what the launch decided (its
/// restore kind and the update marker's check), and for each pane its planned outcome, the gate's checks that held an
/// agent that could have resumed by itself, and, where the gate was not asked, the first condition that stopped it.
///
/// It holds ids, names and codes only: no screen text, no line, no argument but the agent's name, no folder, no secret.
public struct RestoreReport: Equatable, Sendable {
    public static let fileName = "last-restore.json"
    /// The format's version, for whoever reads it.
    public static let format = 1

    /// What the launch restored.
    public enum Launch: String, Sendable {
        /// Nothing came back.
        case normal
        /// The windows came back, each pane planned as `kind`.
        case restore
        /// The layout came back with nothing typed or run, until Try Again.
        case safeMode
        /// The snapshot was set aside.
        case quarantine
    }

    /// One pane, in reading order: its window's index, its tab's index in that window, and the pane's id (the tab id MCP
    /// knows it by).
    public struct Pane: Equatable, Sendable {
        public var window: Int
        public var tab: Int
        public var id: UUID
        /// The agent it ran, by the restore's name for it (`claude`); nil when it ran none.
        public var agent: String?
        public var outcome: RestoreOutcome
        public var heldBecause: [ResumeCheck]
        public var stop: ResumeStop?

        public init(window: Int, tab: Int, id: UUID, agent: String?, outcome: RestoreOutcome, heldBecause: [ResumeCheck] = [],
                    stop: ResumeStop? = nil) {
            self.window = window
            self.tab = tab
            self.id = id
            self.agent = agent
            self.outcome = outcome
            self.heldBecause = heldBecause
            self.stop = stop
        }
    }

    public var launch: Launch
    /// The kind each pane was planned as: nil when nothing came back.
    public var kind: SessionSnapshot.RestoreKind?
    public var marker: UpdateMarker.Check
    public var appVersion: String
    public var writtenAt: Date
    /// The planner ran out of its time budget, so the plan read nothing more of the Mac: no agent could resume.
    public var planTimedOut: Bool
    public var panes: [Pane]

    public init(launch: Launch, kind: SessionSnapshot.RestoreKind?, marker: UpdateMarker.Check, appVersion: String, writtenAt: Date,
                planTimedOut: Bool = false, panes: [Pane] = []) {
        self.launch = launch
        self.kind = kind
        self.marker = marker
        self.appVersion = appVersion
        self.writtenAt = writtenAt
        self.planTimedOut = planTimedOut
        self.panes = panes
    }

    /// The report of a launch that decided `decision` and, when it restored `snapshot`, planned `plans` for its panes.
    public init(decision: RestoreDecision, snapshot: SessionSnapshot?, plans: [PanePlan], planTimedOut: Bool, appVersion: String,
                writtenAt: Date = Date()) {
        let launch: Launch
        let kind: SessionSnapshot.RestoreKind?
        switch decision.kind {
        case .normal: (launch, kind) = (.normal, nil)
        case .quarantine: (launch, kind) = (.quarantine, nil)
        case .restore(let planned): (launch, kind) = (.restore, planned)
        case .safeMode(let planned): (launch, kind) = (.safeMode, planned)
        }
        self.init(launch: launch, kind: kind, marker: decision.marker, appVersion: appVersion, writtenAt: writtenAt,
                  planTimedOut: planTimedOut, panes: Self.panes(snapshot, plans: plans))
    }

    /// Each pane of `snapshot` with its plan, matched by the pane's id. A pane with no plan is left out.
    static func panes(_ snapshot: SessionSnapshot?, plans: [PanePlan]) -> [Pane] {
        guard let snapshot else { return [] }
        var byID: [UUID: PanePlan] = [:]
        for plan in plans where byID[plan.pane] == nil { byID[plan.pane] = plan }
        var panes: [Pane] = []
        for (windowIndex, window) in snapshot.windows.enumerated() {
            for (tabIndex, group) in window.groups.enumerated() {
                for pane in group.panes {
                    guard let plan = byID[pane.id] else { continue }
                    let agent = pane.remote == nil ? (pane.agent?.agent.rawValue ?? pane.agentSession.flatMap { ACPAgent.named($0.agent)?.id }) : nil
                    panes.append(Pane(window: windowIndex, tab: tabIndex, id: pane.id, agent: agent, outcome: plan.outcome,
                                      heldBecause: plan.heldBecause, stop: plan.stop))
                }
            }
        }
        return panes
    }

    /// The report as JSON, keys sorted, dates in ISO 8601 (UTC).
    public var data: Data {
        let dates = ISO8601DateFormatter()
        var object: [String: Any] = [
            "format": Self.format,
            "launch": Self.snake(launch.rawValue),
            "marker": marker.word,
            "app_version": appVersion,
            "written_at": dates.string(from: writtenAt),
            "plan_timed_out": planTimedOut,
        ]
        if let kind { object["restore_kind"] = Self.snake(kind.rawValue) }
        object["panes"] = panes.map { (pane: Pane) -> [String: Any] in
            var fields: [String: Any] = [
                "window": pane.window,
                "tab": pane.tab,
                "pane": pane.id.uuidString.lowercased(),
                "outcome": Self.snake(pane.outcome.rawValue),
            ]
            if let agent = pane.agent { fields["agent"] = agent }
            if !pane.heldBecause.isEmpty { fields["held_because"] = pane.heldBecause.map(\.word) }
            if let stop = pane.stop { fields["stopped_before_gate"] = stop.word }
            return fields
        }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
    }

    /// Writes it in `files` (a 0600 file, replaced whole: SessionFiles.replace). False when it could not be written.
    @discardableResult
    public func write(in files: SessionFiles) -> Bool {
        (try? files.replace(Self.fileName, with: data)) != nil
    }

    static func snake(_ name: String) -> String {
        var word = ""
        for character in name {
            if character.isUppercase { word += "_" + character.lowercased() } else { word.append(character) }
        }
        return word
    }
}

extension UpdateMarker.Check {
    /// Its name as the restore report gives it: `not_awaited`.
    public var word: String {
        switch self {
        case .valid: return "valid"
        case .missing: return "missing"
        case .notAwaited: return "not_awaited"
        case .consumed: return "consumed"
        case .otherBoot: return "other_boot"
        case .stale: return "stale"
        case .otherVersion: return "other_version"
        }
    }
}
