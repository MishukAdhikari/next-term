import Foundation

// MCP across a restart (plan 003's U13, KTD17). An update quits Next Term and opens it again, and a quit under "Resume
// where I left off" brings its tabs back at the next launch: MCP clients keep working through both, by the same tab ids.
// Question ids hash a per-launch nonce (AgentScreen.launchNonce), so an answer meant for a question from before the
// restart is refused. Here is the rest that needs no app: how `nxtrm mcp` reads a socket that does not answer, and when
// it tries again; the quit's answer to each call in flight; a restored tab's `restored` details; and the calls a restore
// or an update's wait refuses.

extension MCPServer {
    /// How a call to the app's socket went without an answer, as `nxtrm mcp` saw it.
    public enum SocketFailure: Error, Equatable, Sendable {
        /// No socket file: no Next Term serves here (it quit, or agent control is off).
        case missing
        /// The socket file is there and nothing listens: Next Term is quitting to install an update, which leaves the file,
        /// or it ended without removing it.
        case refused
        /// The connection failed for another reason.
        case unreachable
        /// The request could not be written: Next Term closed the connection before it read the request, so it did nothing.
        case notSent
        /// The connection ended with no answer, after the request went in.
        case endedWithoutAnswer
        /// No answer within the call's time.
        case timedOut

        /// A failed connect, by its errno.
        public init(connectError code: Int32) {
            switch code {
            case ENOENT, ENOTDIR: self = .missing
            case ECONNREFUSED: self = .refused
            default: self = .unreachable
            }
        }

        /// Next Term looks to be restarting: the socket refused, or the connection ended with no answer.
        public var meansRestarting: Bool {
            switch self {
            case .refused, .notSent, .endedWithoutAnswer: return true
            case .missing, .unreachable, .timedOut: return false
            }
        }
    }

    /// How long `nxtrm mcp` keeps trying a tool that only reads while Next Term restarts, and how often.
    public static let restartRetryWindow: TimeInterval = 20
    public static let restartRetryInterval: TimeInterval = 0.5

    public static let notRunningText = "Next Term is not running, or “Let agents control Next Term” is off in its Settings. Open Next Term and try again."

    /// The wait before `nxtrm mcp` tries `tool` again after `failure`, or nil to answer with `failedAnswer`. Only a tool
    /// that only reads is tried again, so nothing is ever done twice, and only while Next Term restarts: this try or an
    /// earlier one of the same call (`restarting`) was refused or ended with no answer, `elapsed` seconds ago at the first,
    /// less than `restartRetryWindow`. A socket missing meanwhile is the new launch about to listen there.
    public static func retryDelay(_ tool: String, after failure: SocketFailure, restarting: Bool, elapsed: TimeInterval) -> TimeInterval? {
        guard failure != .timedOut, restarting || failure.meansRestarting else { return nil }
        guard self.tool(named: tool)?.readOnly == true, elapsed + restartRetryInterval < restartRetryWindow else { return nil }
        return restartRetryInterval
    }

    /// What the agent reads when a call failed for good. `restarting`: some try of it found Next Term restarting.
    public static func failedAnswer(_ tool: String, _ failure: SocketFailure, restarting: Bool) -> CallResult {
        if failure == .timedOut { return CallResult(text: "Next Term did not answer in time.", isError: true) }
        guard restarting || failure.meansRestarting else { return CallResult(text: notRunningText, isError: true) }
        let text: String
        if self.tool(named: tool)?.readOnly == true {
            text = "Next Term did not answer for \(Int(restartRetryWindow)) seconds: it may still be restarting for an update, or it quit. "
                + "Try again in a moment, or open Next Term."
        } else if failure == .endedWithoutAnswer {
            text = "Next Term closed the connection without answering: it is restarting, perhaps for an update. Whether \(tool) took "
                + "effect is not known: once it is back, list_tabs shows the tabs it brought back, by the same ids."
        } else {
            text = "Next Term is restarting, perhaps for an update, so nothing was sent. Try again in a few seconds: the tabs it "
                + "brings back keep their ids."
        }
        return CallResult(text: text, isError: true)
    }

    // MARK: the quit's answer

    /// What an update does to a tab, as the sheet the user pressed "Update Now" or "Wait for Them" on said it.
    public struct PlannedTab: Equatable, Sendable {
        /// The restore's outcome; nil when the tab does not come back.
        public var outcome: RestoreOutcome?
        /// The sheet's words: "Claude Code resumes", "closes".
        public var words: String

        public init(outcome: RestoreOutcome?, words: String) {
            self.outcome = outcome
            self.words = words
        }
    }

    /// Each tab's planned outcome under the update consent, by its id as MCP gives it. With the box unchecked nothing comes
    /// back but kept remote tabs, which reattach.
    public static func planned(_ consent: UpdateConsent) -> [String: PlannedTab] {
        var planned: [String: PlannedTab] = [:]
        for pane in consent.covered.panes {
            let id = pane.id.uuidString.lowercased()
            if pane.leftOut {
                planned[id] = PlannedTab(outcome: nil, words: "closes")
            } else if consent.keep && consent.covered.refusal == nil {
                planned[id] = PlannedTab(outcome: pane.outcome, words: pane.listLine)
            } else if pane.outcome == .reattach {
                planned[id] = PlannedTab(outcome: .reattach, words: "reattaches")
            } else {
                planned[id] = PlannedTab(outcome: nil, words: pane.outcome == .freshConnection ? "connection closes" : "closes")
            }
        }
        return planned
    }

    /// What an update's quit tells the calls in flight: whether its relaunch brings the tabs back, as the sheet's box and
    /// its plan said, and each tab's planned outcome by its id.
    public struct UpdateRestart: Equatable, Sendable {
        /// The relaunch restores the session, every tab by its id. With the box unchecked only kept remote tabs come back,
        /// as they reattach.
        public var bringsTabsBack: Bool
        public var planned: [String: PlannedTab]

        public init(_ consent: UpdateConsent) {
            bringsTabsBack = consent.keep && consent.covered.refusal == nil
            planned = MCPServer.planned(consent)
        }
    }

    static let restartingText = "Next Term is restarting for an update"
    static let comesBackText = "This tab comes back with the same id: call wait_for_tab again in a few seconds; list_tabs then shows "
        + "what the restart did to it."
    static let nothingBackText = "This update brings no tab back but kept remote tabs: once Next Term is back, list_tabs shows "
        + "what is open."

    /// The quit's answer to a call it was serving (R26): definite, never a timeout. `tool` and `arguments` are the call's,
    /// nil when its request had not been read; `started` when the tool had begun, so what it did stays done. An update's
    /// quit (`update`) says Next Term restarts, and a wait_for_tab hears what the update does to its tab; only a tab the
    /// relaunch brings back is said to keep its id. Any other quit says Next Term quit.
    public static func quitAnswer(tool: String?, arguments: [String: Any], started: Bool, update: UpdateRestart?) -> CallResult {
        guard let update else {
            let what = started ? "before this call finished" : "before this call ran"
            return CallResult(text: "Next Term quit \(what). When it opens again, its tabs keep their ids if it brings them back.", isError: true)
        }
        if tool == "wait_for_tab", let id = (arguments["tab_id"] as? String)?.lowercased() {
            var fields: [String: Any] = ["id": id, "state": "restarting"]
            let plan = update.planned[id]
            if let plan {
                fields["planned"] = plan.words
                if let outcome = plan.outcome { fields["planned_outcome"] = MCPRestored.word(outcome) }
            }
            let after: String
            if let plan, plan.outcome == nil {
                after = "This tab does not come back after the update, so its id ends: once Next Term is back, list_tabs shows "
                    + "what is open."
            } else if plan?.outcome != nil || update.bringsTabsBack {
                after = comesBackText
            } else {
                after = nothingBackText
            }
            fields["note"] = restartingText + ". " + after
            return CallResult(text: json(fields))
        }
        let ran = started ? "before this call finished; what it did so far stays done" : ", so this call was not run"
        let after = update.bringsTabsBack ? "Try again in a few seconds: the tabs it brings back keep their ids." : nothingBackText
        let text = restartingText + (started ? " " : "") + ran + ". " + after
        return CallResult(text: text, isError: true)
    }
}

// MARK: - Restored details

/// A restored tab's `restored` details, which list_tabs, read_tab and wait_for_tab give (R24): why it came back, what the
/// restore does or did to it, its state before the restart, whether the restart cut its work off, and a one-line note.
/// They last until the first command the user or MCP starts in the tab after the restore: the shell's first prompt starts
/// none, and the restore's own resume is not one of theirs. An automatic resume reads "pending" until the start watch
/// settles it, and "resume" only once it settled it as resumed (KTD6, KTD17): a start that failed reads as the agent's
/// resume command on the line, with its error; a new session as "new_session"; one that ended within the watch as
/// "ended".
public struct MCPRestored: Equatable, Sendable {
    /// An update, a quit under "Resume where I left off", a crash, or safe mode.
    public var reason: SessionSnapshot.RestoreKind
    /// What the restore does or did to the tab; nil when its action that types was cancelled before it typed anything,
    /// which MCP gives as "cancelled". MCP reads it with the start watch's verdict (`reading`).
    public var outcome: RestoreOutcome?
    /// The restore's action: pending until the shell is ready, then applied, or cancelled when the user typed first, or
    /// dismissed (a shell not ready in time, Keep As Is).
    public var action: SessionSnapshot.ActionState
    public var stateBefore: SessionSnapshot.PriorState
    public var interrupted: Bool
    /// What happened, in one line; nil while the action is pending.
    public var note: String?
    /// The line the restore put back is still on the prompt, unrun, and the user has not typed in the tab since.
    public var lineHeld: Bool
    /// What the start watch told of the restore's own resume: nil when the restore pressed no Return, `watching` until
    /// it settles.
    public var start: StartWatch.Report?

    public init(reason: SessionSnapshot.RestoreKind, outcome: RestoreOutcome?, action: SessionSnapshot.ActionState,
                stateBefore: SessionSnapshot.PriorState, interrupted: Bool, note: String?, lineHeld: Bool,
                start: StartWatch.Report? = nil) {
        self.reason = reason
        self.outcome = outcome
        self.action = action
        self.stateBefore = stateBefore
        self.interrupted = interrupted
        self.note = note
        self.lineHeld = lineHeld
        self.start = start
    }

    /// What has happened in a restored tab since the restore, as its details read it.
    public struct Since: Equatable, Sendable {
        /// Commands started at its prompt (TabStatus.commandsAtPrompt): what was already running in front as a remote tab
        /// reattached is none of them.
        public var commands: Int
        /// How many of them had started when the user first put something in the tab (a key, a paste, a drop); nil while
        /// they have not.
        public var beforeInput: Int?

        public init(commands: Int, beforeInput: Int?) {
            self.commands = commands
            self.beforeInput = beforeInput
        }
    }

    /// A restored tab's details now, from its plan, the record it was restored from (its pending action, its state before
    /// and whether its work was cut off), what has happened in it since, and what the start watch told of the restore's
    /// own resume; nil once they have ended. A start the watch settled is told by its own note, when it showed one.
    public init?(plan: PanePlan, record: SessionSnapshot.Pane, since: Since, start: StartWatch.Report? = nil) {
        guard let pending = record.pending else { return nil }
        let outcome = Self.outcome(planned: plan.outcome, action: pending.state, start: start?.verdict)
        var note = plan.note
        let text: String?
        if let outcome {
            note.outcome = outcome
            if pending.state == .pending {
                text = nil
            } else if let said = start?.note {
                text = said
            } else if start?.verdict == .leftAsIs {
                text = note.endedText
            } else {
                text = note.text()
            }
        } else {
            text = note.cancelledText()
        }
        let typed = since.beforeInput != nil
        let held = record.remote == nil
            && Self.lineHeld(action: pending.action, state: pending.state, userTyped: typed, commandsRun: since.commands, start: start)
        self.init(reason: plan.reason, outcome: outcome, action: pending.state, stateBefore: record.stateBefore,
                  interrupted: record.interrupted, note: text, lineHeld: held, start: start)
        guard shows(commands: since.commands) else { return nil }
    }

    /// What the restore did, as it turned out. An action that types, cancelled because something reached the line before
    /// the shell was ready, typed nothing: no agent resumed and no line waits (nil). An automatic resume stays pending
    /// until the start watch settles it (`start`, KTD6), and then ran its command, unless it failed at start, which put
    /// its plain resume form back on the line. Applied with no verdict, the restore pressed no Return: its session was
    /// taken by another process since, or the user typed over it first, and the agent's resume command is on the line
    /// instead, unrun. A command that started meanwhile does not make it a resume. How the resume it ran turned out is
    /// MCP's to read (`reading`).
    public static func outcome(planned: RestoreOutcome, action: SessionSnapshot.ActionState,
                               start: StartWatch.Verdict? = nil) -> RestoreOutcome? {
        if action == .cancelled && planned.action.types { return nil }
        guard planned == .resume, action == .applied else { return planned }
        guard let start, start.settled, !start.failed else { return .agentOnTheLine }
        return .resume
    }

    /// The outcome as MCP reads it (KTD17, R26): `outcome`'s word, or "cancelled" when the restore typed nothing. An
    /// automatic resume reads "resume" only once its start watch settled it as resumed: "pending" until then, while its
    /// shell is not ready or the watch runs; "new_session" when its agent started another session; and "ended" when it
    /// ended within the watch with nothing to fall back from (status 0, Ctrl-C, a key pressed first, its shell gone), as
    /// no agent runs there then. One that failed at start reads as its resume command on the line.
    public static func reading(_ outcome: RestoreOutcome?, action: SessionSnapshot.ActionState, start: StartWatch.Verdict?) -> String {
        guard let outcome else { return "cancelled" }
        guard outcome == .resume else { return word(outcome) }
        guard action != .pending else { return "pending" }
        switch start {
        case .newSession?: return "new_session"
        case .leftAsIs?: return "ended"
        case .resumed?, .watching?, .failedAtStart?, nil: return word(outcome)
        }
    }

    /// Whether they still show, with `commands` started at the tab's prompt since it started. An automatic resume whose
    /// Return the restore pressed ran the restore's own command, so the next one is the first after it.
    public func shows(commands: Int) -> Bool {
        let own = start != nil || (outcome == .resume && action == .applied) ? 1 : 0
        return commands <= own
    }

    /// Whether the line an applied action typed is still the restore's, not the user's (R25): the action typed a line, and
    /// since then the user has not typed in the tab and nothing has run there. A resume whose Return the restore pressed
    /// (`start`) ran its command: the line is the restore's only when the watch put the plain resume form back, until a
    /// command runs after it. One whose session another process had taken was put back instead.
    public static func lineHeld(action: SessionSnapshot.Action, state: SessionSnapshot.ActionState, userTyped: Bool,
                                commandsRun: Int, start: StartWatch.Report? = nil) -> Bool {
        guard action.types, state == .applied, !userTyped else { return false }
        guard let start else { return commandsRun == 0 }
        return start.lineBack && commandsRun <= 1
    }

    /// As MCP gives them, under "restored". A resume still pending also gives the outcome it plans.
    public var fields: [String: Any] {
        let read = Self.reading(outcome, action: action, start: start?.verdict)
        var fields: [String: Any] = [
            "reason": Self.word(reason),
            "outcome": read,
            "action": action.rawValue,
            "state_before": stateBefore.rawValue,
            "interrupted": interrupted,
        ]
        if read == "pending", let outcome { fields["planned_outcome"] = Self.word(outcome) }
        if action != .pending, let note { fields["note"] = note }
        if lineHeld { fields["line_held"] = true }
        return fields
    }

    /// Why input into the tab is refused, or nil (R25): its action waits for the shell, or its prompt holds the line the
    /// restore put back. Either is not the user's own line, and no tool can run, edit or clear it.
    public var inputRefusal: String? {
        if outcome?.action.types == true && action == .pending, start != nil {
            return "That tab is being restored after Next Term restarted: its agent's resume just ran, and Next Term watches for a "
                + "few seconds that it starts. Nothing was typed: try again in a few seconds."
        }
        if outcome?.action.types == true && action == .pending {
            return "That tab is being restored after Next Term restarted, and what the restore types there waits for its shell. "
                + "Nothing was typed: try again in a few seconds."
        }
        if lineHeld {
            return "That tab's prompt holds a line Next Term put back after the restart, unrun: it is not the user's own until they "
                + "type in that tab, so nothing was typed. list_tabs shows what it is."
        }
        return nil
    }

    /// A word MCP gives: snake case, as its other words are.
    static func word(_ kind: SessionSnapshot.RestoreKind) -> String { snake(kind.rawValue) }
    static func word(_ outcome: RestoreOutcome) -> String { snake(outcome.rawValue) }

    private static func snake(_ name: String) -> String {
        var word = ""
        for character in name {
            if character.isUppercase { word += "_" + character.lowercased() } else { word.append(character) }
        }
        return word
    }
}

// MARK: - The gate

/// The calls refused before they run, while a restore or an update needs them held (KTD14, KTD16).
public enum MCPRestoreGate {
    /// Input tools a waited tab still takes while an update waits for it.
    static let waitedInput: Set<String> = ["send_to_tab", "press_keys", "answer_agent"]

    /// Why `tool` is refused now, or nil. In safe mode only the tools that only read run, until the user chooses Keep As Is
    /// or Try Again. While an update waits for busy tabs (`waitingFor`, their ids as MCP gives them), reading, input into a
    /// waited tab and a `followUp` (isFollowUp) still work, and new work elsewhere is refused with `update_pending` until
    /// the wait ends.
    public static func refusal(tool: String, tabID: String?, followUp: Bool, safeMode: Bool, waitingFor waited: Set<String>?) -> String? {
        guard let entry = MCPServer.tool(named: tool), !entry.readOnly else { return nil }
        if safeMode {
            return "Next Term restored its windows in safe mode, after two restores that did not finish: nothing runs until the user "
                + "chooses Keep As Is or Try Again. Until then only the tools that read work."
        }
        guard let waited else { return nil }
        if followUp { return nil }
        if waitedInput.contains(tool), let id = tabID?.lowercased(), waited.contains(id) { return nil }
        return "update_pending: Next Term waits for busy tabs to finish before it updates, so it takes no new work now. Reading, "
            + "input into the tabs it waits for (list_tabs marks them update_wait: waits_for_this_tab), and asking again with the "
            + "proposal_id or request_id of a request already open still work, and this works again once the wait ends. The tabs "
            + "the update brings back keep their ids."
    }

    /// Tools where a call with an id asks again for the answer to a request already open, and that id's argument.
    static let followUpID: [String: String] = [
        "propose_edit": "proposal_id", "install_skill": "request_id", "remove_skill": "request_id",
        "apply_import": "request_id", "undo_import": "request_id",
        "request_secret": "request_id", "store_secret": "request_id", "run_with_secrets": "request_id",
        "import_secrets": "request_id",
    ]

    /// Whether the call asks again for the answer to a request already open (its proposal_id or request_id), which starts
    /// nothing new. Told as the tools' handlers tell it: a non-empty id, whatever else the call gives.
    public static func isFollowUp(_ tool: String, _ arguments: [String: Any]) -> Bool {
        guard let key = followUpID[tool], let id = arguments[key] as? String else { return false }
        return !id.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What a tab says while an update waits for busy tabs (KTD16): `waits_for_this_tab` on a tab it waits for, where input
    /// still works, and `update_pending` on every other, where new work is refused until the wait ends. Nothing when no
    /// update waits.
    public static func waitFields(tabID: String, waitingFor waited: Set<String>?) -> [String: Any] {
        guard let waited else { return [:] }
        return ["update_wait": waited.contains(tabID.lowercased()) ? "waits_for_this_tab" : "update_pending"]
    }
}
