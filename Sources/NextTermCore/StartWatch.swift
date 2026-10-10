import Foundation

// The start watch (KTD6, plan 003's U14 and U5). An agent's action settles only once its agent has started: for 5
// seconds after an automatic resume's Return, or after the user runs a line the restore put back, the app reads the
// shell's end mark and, for Claude Code, Codex and Qwen Code, the session file of the agent it started. Here are its
// rules, which read nothing of the Mac: the verdict from what was read, the one fallback each tab gets, its notes, and
// the agent's error as a note quotes it.
//
// - still running at 5 s, or the session file names the session: resumed;
// - a nonzero end within 5 s, with no key pressed first and a status other than 130 (Ctrl-C): failed at start. The
//   agent's plain resume form goes back on the line, unrun, once per tab, and the note quotes the agent's error and names
//   every option the plain form dropped. A second failure, or a plain form that is what failed, gives the note alone;
// - the session file names another id at 5 s: the agent started a new session, and the note says so;
// - Ctrl-C, status 0, or a key pressed first: the tab stays as it is.

public enum StartWatch {
    /// How long the watch lasts after the Return.
    public static let window: TimeInterval = 5
    /// How often the app reads the agent's session file while it watches.
    public static let fileInterval: TimeInterval = 0.5
    /// Ctrl-C's status: the user stopped it.
    public static let interruptedStatus: Int32 = 130
    /// The longest error a note quotes, in characters.
    public static let quoteLimit = 160

    /// What the watch makes of a start.
    public enum Verdict: Equatable, Sendable {
        /// Not known yet.
        case watching
        /// The agent still runs at 5 s, or its session file names the session.
        case resumed
        /// It ended within 5 s with this status, nonzero and not Ctrl-C's, and no key pressed first.
        case failedAtStart(status: Int32)
        /// Its session file names this id, another session's, at 5 s.
        case newSession(String)
        /// It ended within 5 s by the user's hand (Ctrl-C, or a key pressed first) or with status 0: nothing to fall back
        /// from, and the tab stays as it is.
        case leftAsIs

        /// The watch is over.
        public var settled: Bool { self != .watching }

        /// It failed at start: MCP reads it as the agent's resume command on the line, not a resume.
        public var failed: Bool {
            if case .failedAtStart = self { return true }
            return false
        }
    }

    /// The shell's end mark for the command watched, as read when it came.
    public struct End: Equatable, Sendable {
        /// The command's status, as the shell reported it.
        public var status: Int32
        /// Seconds from the Return to the mark.
        public var after: TimeInterval
        /// Something reached the tab from the user between the Return and the mark: a key, a paste, a drop.
        public var keyPressed: Bool

        public init(status: Int32, after: TimeInterval, keyPressed: Bool) {
            self.status = status
            self.after = after
            self.keyPressed = keyPressed
        }
    }

    /// The verdict, from the shell's end mark (nil while the command runs), the id the agent's session file names (nil
    /// when none was read), the session the command resumes, and the seconds since its Return. An end within the window
    /// decides first, then the file, then the time. A file read as the agent starts may still change to the session it
    /// loads, so another id counts only once the window is out.
    public static func verdict(end: End?, sessionFile: String?, session: String?, elapsed: TimeInterval) -> Verdict {
        if let end {
            guard end.after <= window else { return .resumed }
            if end.keyPressed || end.status == 0 || end.status == interruptedStatus { return .leftAsIs }
            return .failedAtStart(status: end.status)
        }
        if let sessionFile, let session {
            if sessionFile.lowercased() == session.lowercased() { return .resumed }
            if elapsed >= window { return .newSession(sessionFile) }
        }
        return elapsed >= window ? .resumed : .watching
    }

    /// One tab's watch, from its Return: what was read as it came, kept as it stood at the end mark.
    public struct Watch: Equatable, Sendable {
        /// The session the command resumes.
        public let session: String?
        /// When the Return went, on the clock the times given are on.
        public let since: TimeInterval
        public private(set) var end: End?
        /// The id the agent's session file named when last read, before the end.
        public private(set) var sessionFile: String?
        /// Something reached the tab from the user since the Return, before the end.
        public private(set) var keyPressed = false

        public init(session: String?, since: TimeInterval) {
            self.session = session
            self.since = since
        }

        /// The user put something in the tab: a key, a paste, a drop.
        public mutating func key() {
            if end == nil { keyPressed = true }
        }

        /// The shell's end mark came, at `now`. Only the first counts.
        public mutating func ended(status: Int32, at now: TimeInterval) {
            guard end == nil else { return }
            end = End(status: status, after: now - since, keyPressed: keyPressed)
        }

        /// The agent's session file read: the id it names, or nil when none was found, which keeps the last one read.
        public mutating func read(sessionFile id: String?) {
            guard end == nil, let id else { return }
            sessionFile = id
        }

        public func verdict(at now: TimeInterval) -> Verdict {
            StartWatch.verdict(end: end, sessionFile: sessionFile, session: session, elapsed: now - since)
        }
    }

    // MARK: the fallback

    /// What a watched start ran, and what its fallback puts back.
    public struct Start: Equatable, Sendable {
        public var agent: RestoreAgent
        /// The session it resumes.
        public var session: String?
        /// The plain resume form: the agent's program and resume form with the session, no option
        /// (`RestoreAgent.putBackLine`). Nil with no session named.
        public var plain: String?
        /// The options the run carried that the plain form drops, by name, in order.
        public var dropped: [String]
        /// What ran when it was a line the restore put back, as typed; nil for an automatic resume's command.
        public var line: String?

        /// `evidence` is the agent's record, `session` the one its line or resume names, and `line` the put-back line the
        /// user ran. The options dropped are those the line, or the resume, carried: each of the record's options a line
        /// keeps. One left off, whose value Next Term could not tell from a prompt's, never was on it.
        public init(evidence: SessionSnapshot.Evidence, session: String?, line: String?) {
            agent = evidence.agent
            self.session = session
            self.line = line
            plain = session.flatMap { (id: String) -> String? in
                guard evidence.agent.isSessionID(id) else { return nil }
                return evidence.agent.putBackLine(id: id, folder: evidence.sessionFolder)
            }
            var names: [String] = []
            for option in evidence.options ?? [] {
                let kept = evidence.agent.reading([option], confirmed: []).line
                if !kept.isEmpty, !names.contains(option.name) { names.append(option.name) }
            }
            dropped = names
        }
    }

    /// What a tab gets after a verdict.
    public enum Step: Equatable, Sendable {
        case nothing
        /// The note, then the plain resume form on the line, unrun.
        case putBack(line: String, note: String)
        /// A note alone.
        case note(String)
    }

    /// What the tab gets after `verdict`. A failed start puts the plain resume form back on the line once: not when the
    /// tab had its fallback already (`fallbackUsed`), nor when no session is named or the plain form is the line that
    /// failed. Its note quotes the agent's `error`, and names every option the plain form dropped. A new session gets a
    /// note. Anything else, nothing.
    public static func step(_ verdict: Verdict, start: Start, fallbackUsed: Bool, error: String?) -> Step {
        switch verdict {
        case .failedAtStart(let status):
            let program = start.agent.program ?? "The agent"
            var said = "\(program) exited at once (status \(status))"
            said += error.map { (quoted: String) -> String in ": “\(quoted)”." } ?? "."
            guard !fallbackUsed, let plain = start.plain, plain != start.line else { return .note(TerminalText.oneLine(said)) }
            said += " The plain resume is back on the line."
            if !start.dropped.isEmpty { said += " Left off: " + start.dropped.joined(separator: ", ") + "." }
            return .putBack(line: plain, note: TerminalText.oneLine(said))
        case .newSession:
            guard let session = start.session else { return .nothing }
            return .note(TerminalText.oneLine("\(start.agent.name) started a new session instead of resuming session \(session)."))
        case .watching, .resumed, .leftAsIs:
            return .nothing
        }
    }

    /// The agent's error as a note quotes it, from the lines it printed before it ended: the first that says "error",
    /// else the last with any text. Masked (CommandSecrets, KTD8), one line of printable text, at most `quoteLimit`
    /// characters. Nil when it printed nothing.
    public static func error(in lines: [String]) -> String? {
        var shown: [String] = []
        for line in lines {
            let text = TerminalText.oneLine(CommandSecrets.mask(line)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { shown.append(text) }
        }
        let said = shown.first { (text: String) -> Bool in text.lowercased().contains("error") }
        guard let picked = said ?? shown.last else { return nil }
        guard picked.count > quoteLimit else { return picked }
        return String(picked.prefix(quoteLimit - 1)) + "…"
    }

    /// What the watch told of a restored tab's own resume, for MCP (MCPRestored): its verdict, the note it showed, and
    /// whether it put the plain resume form back on the line.
    public struct Report: Equatable, Sendable {
        public var verdict: Verdict
        public var note: String?
        public var lineBack: Bool

        public init(verdict: Verdict, note: String? = nil, lineBack: Bool = false) {
            self.verdict = verdict
            self.note = note
            self.lineBack = lineBack
        }
    }
}
