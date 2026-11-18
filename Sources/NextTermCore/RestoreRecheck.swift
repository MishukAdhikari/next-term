import Foundation

/// Checking a held agent again (plan 046): a pane an update or consented quit restore held on the line only for facts
/// that can clear without the user (`ResumeCheck.isTransient`: its session not available yet, its folder or store not
/// there yet) is checked again once its shell is ready, about 1 s after, then a few more times, backing off, for up to
/// about 30 s. Each time the same gate runs on fresh facts, and the agent resumes only when it passes whole. A pane held
/// for any other reason, or by one that turns up on a re-check, is never checked again: its line waits for the user.
///
/// Nothing is put on the line while it is checked, so a pass has a clean line to run on; anything the user puts in the
/// tab, or a command that runs there, ends the checks, and the pane resumes at most once. When they run out, its line is
/// put back, unrun, as for any held agent.
public enum RestoreRecheck {
    /// When each check runs, in seconds after the pane's shell was ready: 1 s, then backing off, about 30 s in all.
    public static let schedule: [TimeInterval] = [1, 3, 7, 15, 30]

    /// Whether a pane held by `failed` may be checked again: something failed, and every failure is transient.
    public static func mayRecheck(_ failed: [ResumeCheck]) -> Bool {
        !failed.isEmpty && failed.allSatisfy(\.isTransient)
    }

    /// What one check came to.
    public enum Result: Equatable, Sendable {
        /// The gate passed: run this, the command the gate built from the pane's own evidence.
        case resume(String)
        /// Still held, by transient facts alone: the next check may find them cleared.
        case waiting([ResumeCheck])
        /// Held for a reason that guards the user: no more checks, and the line goes back for the user's Return.
        case held([ResumeCheck])
    }

    /// The gate on `evidence` with `facts` read now, as the planner asks it (`RestorePlanner.verdict`): what runs stays out
    /// of every project, the tab's folder and the session's, whatever the facts say.
    public static func check(_ evidence: SessionSnapshot.Evidence, facts: ResumeFacts, projects: [String], tabFolder: String?) -> Result {
        var facts = facts
        let folders: [String] = projects + [tabFolder, evidence.sessionFolder].compactMap { $0 }
        for folder in folders where !facts.outside.contains(folder) {
            facts.outside.append(folder)
        }
        switch evidence.gate(facts) {
        case .resume(let command):
            guard command == evidence.resumeCommand else { return .held([.executable]) }
            return .resume(command)
        case .onTheLine(let failed):
            return mayRecheck(failed) ? .waiting(failed) : .held(failed)
        case .note:
            return .held([.automatic])
        }
    }

    /// The line a pass runs: the gate's command, in the session's folder. A tab that opened elsewhere, its folder not
    /// there at the restore, goes there first with the shell's own `cd` (`builtin`, so no function or alias of that name
    /// runs), and only if that works. Nil when the folder cannot be one plain word of a line.
    public static func line(command: String, folder: String?, tabFolder: String?) -> String? {
        guard let folder, folder != tabFolder else { return command }
        guard SnapshotText.plainPath(folder, max: SessionSnapshot.Limits.standard.path) != nil else { return nil }
        let line = "builtin cd -- " + ShellQuote.quote(folder) + " && " + command
        return SessionSnapshot.Command.problem(with: line) == nil ? line : nil
    }

    /// How one check, or the checks as a whole, ended, as the restore report records it.
    public enum Event: String, CaseIterable, Sendable {
        /// The gate passed, and the resume was started.
        case passed
        /// Still held by transient facts: another check follows.
        case waiting
        /// Held for a reason that guards the user: the checks stop, and the line goes back.
        case held
        /// The checks ran out: the line goes back.
        case exhausted
        /// Something reached the tab's line, or a command ran there: the checks stop, and nothing is typed.
        case stoppedByInput
        /// The tab's shell ended: the checks stop.
        case stoppedShellEnded

        public var word: String { RestoreReport.snake(rawValue) }
    }

    /// One check, for the report: which one (1 for the first), when (seconds after the shell was ready), how it ended,
    /// and what failed.
    public struct Entry: Equatable, Sendable {
        public var attempt: Int
        public var after: TimeInterval
        public var event: Event
        public var failed: [ResumeCheck]

        public init(attempt: Int, after: TimeInterval, event: Event, failed: [ResumeCheck] = []) {
            self.attempt = attempt
            self.after = after
            self.event = event
            self.failed = failed
        }
    }

    /// The tab's note on how the checks ended.
    public static func note(_ event: Event, agent: RestoreAgent?, session: String?, failed: [ResumeCheck]) -> String? {
        let name = agent?.name ?? "The agent"
        switch event {
        case .passed:
            return TerminalText.oneLine("What held \(name) cleared, so session \(session ?? "") resumes now.")
        case .held, .exhausted:
            let why = failed.map(\.heldWords)
            let list: String
            if let last = why.last {
                list = why.count == 1 ? last : why.dropLast().joined(separator: ", ") + " and " + last
            } else {
                list = "it did not pass its checks"
            }
            let checked = event == .exhausted ? "Checked again for \(Int(schedule.last ?? 0)) seconds" : "Checked again"
            return TerminalText.oneLine("\(checked), and still held: \(list).")
        case .waiting, .stoppedByInput, .stoppedShellEnded:
            return nil
        }
    }
}
