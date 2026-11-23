import Foundation

/// R57's list and the screen reads the door makes at each remote write (U14): which agents' permission modes Next Term
/// reads, how each mode shows on the agent's screen and whether it asks before the agent runs a command, the agent's
/// input line, its one-time answer labels (R58), the flags on a command line that turn asking off, and what a
/// permission prompt asks to approve (R39, R40).
///
/// The strings are data. Claude Code's are its own mode table's indicators ("accept edits", "plan mode", "bypass
/// permissions", "auto mode", "don't ask", "manual mode") followed by " on" in its footer, with the older "auto-accept
/// edits" too, and "? for shortcuts" in the footer of its default mode. Hand check H16 records the full set on a live
/// screen, with the version, before this ships; Codex, Gemini CLI and Qwen Code join only once H16 records theirs.
public enum RemoteAccessAgentRules {
    /// What the door reads of an agent's permission mode now.
    public enum Mode: Equatable, Sendable {
        /// Its normal input state shows, in a mode that asks before it runs a command (the indicator, or "default").
        case asks(String)
        /// A mode that never asks: on its screen, or a flag on its command line.
        case neverAsks(String)
        /// A listed agent whose mode or input state does not show now: a question, a working screen without its
        /// footer, or a screen Next Term can't classify.
        case hidden
        /// Not on R57's list.
        case unlisted
    }

    /// The agent's input line, as its screen shows it.
    public enum InputLine: Equatable, Sendable {
        case empty
        /// What it holds.
        case text(String)
        /// Not found on the screen.
        case unseen
    }

    /// One agent on R57's list.
    public struct Agent: Sendable {
        public let name: String
        /// Footer indicators, each followed by " on", and whether that mode asks before a command runs.
        public let modes: [(indicator: String, asks: Bool)]
        /// What its footer shows in its default mode, which asks.
        public let defaultMarker: String
        /// The labels of the choices that allow once (R58); a choice that starts with "No" always passes.
        public let oneTimeLabels: [String]
        /// The flags that turn its asking off on a command line, with their values when they take one.
        public let bypassFlags: [[String]]
    }

    public static let claude = Agent(
        name: "claude",
        // Longest first: "auto-accept edits on" holds "accept edits on".
        modes: [("auto-accept edits", true), ("accept edits", true), ("plan mode", true), ("manual mode", true),
                ("bypass permissions", false), ("auto mode", false), ("don't ask", false)],
        defaultMarker: "? for shortcuts",
        oneTimeLabels: ["Yes"],
        bypassFlags: [["--dangerously-skip-permissions"], ["--permission-mode", "bypassPermissions"],
                      ["--permission-mode", "auto"], ["--permission-mode", "dontAsk"]])

    /// R57's list, by the program name a tab runs.
    public static let listed: [String: Agent] = ["claude": claude]

    /// The flags other agents take to stop asking: on a command line they make any agent's mode one that never asks,
    /// listed or not (R57).
    public static let otherBypassFlags: [String: [[String]]] = [
        "codex": [["--yolo"], ["--dangerously-bypass-approvals-and-sandbox"], ["--full-auto"], ["--ask-for-approval", "never"],
                  ["-a", "never"]],
        "gemini": [["--yolo"], ["-y"], ["--approval-mode", "yolo"]],
        "qwen": [["--yolo"], ["-y"], ["--approval-mode", "yolo"]],
    ]

    // MARK: command lines

    /// The command line holds a flag that turns `program`'s asking off: in its two-word form, its `=` form, or as a
    /// short flag in a cluster ("-y" in "-yv" is not counted: only whole words).
    public static func hasBypassFlag(_ commandLine: String, program: String) -> Bool {
        let flags: [[String]] = listed[program]?.bypassFlags ?? otherBypassFlags[program] ?? []
        guard !flags.isEmpty else { return false }
        let words: [String] = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        for flag in flags {
            if flag.count == 1, words.contains(flag[0]) { return true }
            guard flag.count == 2 else { continue }
            if words.contains(flag[0] + "=" + flag[1]) { return true }
            for (index, word) in words.enumerated() where word == flag[0] && index + 1 < words.count {
                if words[index + 1] == flag[1] { return true }
            }
        }
        return false
    }

    // MARK: the screen

    /// How many lines from the bottom the reads look at.
    static let scanned = 12

    /// `program`'s mode as `lines` (its screen) show it now. Nothing is kept between calls.
    public static func mode(program: String, screenLines lines: [String]) -> Mode {
        guard let agent = listed[program] else { return .unlisted }
        let bottom: [String] = Array(lines.suffix(scanned))
        // A question hides the mode: only the normal input state shows it, working or not.
        guard showsInput(program: program, screenLines: lines) else { return .hidden }
        for line in bottom.reversed() {
            let lower = line.lowercased()
            for mode in agent.modes where lower.contains(mode.indicator + " on") {
                return mode.asks ? .asks(mode.indicator) : .neverAsks(mode.indicator)
            }
            if lower.contains(agent.defaultMarker) { return .asks("default") }
        }
        return .hidden
    }

    /// The agent's input line: the row of its prompt box that starts with its prompt mark (">" or "❯"), inside the
    /// box's sides when it draws them, between the box's edges. A dim placeholder ("Try "…"") reads as text: the door
    /// takes the line as empty only when nothing is on it.
    public static func inputLine(program: String, screenLines lines: [String]) -> InputLine {
        guard listed[program] != nil else { return .unseen }
        let bottom: [String] = Array(lines.suffix(scanned))
        for (offset, line) in bottom.enumerated().reversed() {
            let inner = Self.inner(line)
            guard let mark = inner.first, mark == ">" || mark == "❯" else { continue }
            // The prompt box: an edge right above it (a full box's top or Claude Code's rule), so a quoted "> " in the
            // transcript is never the line.
            guard offset > 0, isEdge(bottom[offset - 1]) else { continue }
            let rest = inner.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? .empty : .text(rest)
        }
        return .unseen
    }

    /// The agent shows its normal input state, working or not: no question or form covers it, and its input line
    /// shows where it draws it (R52).
    public static func showsInput(program: String, screenLines lines: [String]) -> Bool {
        guard listed[program] != nil else { return false }
        if case .asking = AgentScreen.activity(screenLines: lines) { return false }
        if isQuestionForm(screenLines: lines) { return false }
        return inputLine(program: program, screenLines: lines) != .unseen
    }

    // MARK: answers

    /// Whether a choice of a permission prompt allows once (R58): a label that starts with "No", or one on the agent's
    /// list, compared without case, with ' and ’ alike. An agent with no labels allows only a No.
    public static func isOneTime(_ label: String, program: String) -> Bool {
        let plain = label.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces).lowercased()
        if plain == "no" || plain.hasPrefix("no,") || plain.hasPrefix("no ") { return true }
        let labels: [String] = listed[program]?.oneTimeLabels ?? []
        return labels.contains { $0.replacingOccurrences(of: "’", with: "'").lowercased() == plain }
    }

    /// The menu on screen is Claude Code's question form, whose choices are the model's own words: every choice is
    /// one-time there (R58).
    public static func isQuestionForm(screenLines lines: [String]) -> Bool {
        AgentScreen.form(in: lines) != nil
    }

    /// What a permission prompt asks to approve (R39, R40): the lines between the top of its box and its question,
    /// such as the command under Claude Code's "Bash command", without the box's sides; nil when it shows none.
    public static func approves(screenLines lines: [String]) -> String? {
        guard let (row, _) = AgentScreen.prompt(in: lines) else { return nil }
        var top = row - 1
        while top >= 0, !lines[top].trimmingCharacters(in: .whitespaces).hasPrefix("╭") { top -= 1 }
        guard top >= 0, top + 1 < row else { return nil }
        let inside: [String] = lines[(top + 1)..<row].map(inner).filter { !$0.isEmpty }
        // The first line is the box's title ("Bash command", "Edit file"); what is approved is below it.
        let body = inside.count > 1 ? Array(inside.dropFirst()) : inside
        let text = body.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: rows

    private static func inner(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃| ").union(.whitespaces))
    }

    private static func isEdge(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        return "╭─━═┌".contains(first)
    }
}
