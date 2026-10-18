import Foundation

// What the import sheet says about where `nxtrm secret import`'s keys came from, and how to end the password manager's
// session after. It goes by the process tree and by the line the tab's shell said it ran, never by the tab alone and
// never by what was piped.

extension SecretImportPipe {
    public static let agentWarning = "An agent ran this command. It may have seen these keys."
    public static let untracedWarning = "Next Term couldn\u{2019}t tell which tab ran this command. If you didn\u{2019}t "
        + "run it, an agent may have, and may have seen these keys."

    /// Who ran the importer, as the process tree and the tabs tell it.
    public enum Runner: Equatable, Sendable {
        /// The user, in a tab of Next Term's with no agent above the importer.
        case user
        /// An agent runs above the importer.
        case agent
        /// No tab of Next Term's is above it: a process that left its tab, as `( … &)`, nohup or setsid make it, or one
        /// run in another terminal app.
        case untraced

        /// Handled as the user: Secrets comes forward with the keyboard, and the sheet's action answers Return. An
        /// agent's run, and one Next Term can't trace to a tab of its own, get the sheet without the keyboard, its
        /// action answering only a click, as for an agent's import_secrets.
        public var isUser: Bool { self == .user }

        /// May open the MCP-config import for a file it names. Moving keys out of an MCP config rewrites that file, so
        /// only the user starts it: an agent's run, or an untraced one, is refused as import_secrets refuses such a
        /// file.
        public var mayStartMove: Bool { self == .user }
    }

    /// The importer's runner: an agent above it, else the user when it runs in a tab of Next Term's, else untraced.
    public static func runner(agent: String?, inTab: Bool) -> Runner {
        if agent != nil { return .agent }
        return inTab ? .user : .untraced
    }

    /// The warning under the sheet's header: an agent above the importer, or no tab of Next Term's above it (a process
    /// that left its tab, as `( … &)` does, or one run outside Next Term); nil in a tab with no agent above it.
    public static func originWarning(agent: String?, inTab: Bool) -> String? {
        switch runner(agent: agent, inTab: inTab) {
        case .agent: return agentWarning
        case .untraced: return untracedWarning
        case .user: return nil
        }
    }

    /// What a FILE given to the importer opens: what `picked` says, or nil (`moveRefused`, with nothing opened) when it
    /// is one of the MCP-config import's files and `runner` may not start a move.
    public static func opens(_ picked: SecretSources.Picked, runner: Runner) -> SecretSources.Picked? {
        if case .move = picked, !runner.mayStartMove { return nil }
        return picked
    }
}

extension SecretImportPreset {
    public static let onePasswordLine = "Close this tab to end 1Password\u{2019}s authorization for it."
    public static let lockedLine = "Bitwarden is locked again."
    public static let unlockedLine = "Bitwarden is still unlocked in that tab: run bw lock there."
    public static let lockedIfLine = "If the line still ends with bw lock, Bitwarden is locked again."

    /// Whether `command`, the line the tab's shell said it ran, is `line`, a preset's line as Next Term typed it: only
    /// then does the sheet name the preset. Spaces around either don't count; an empty command never matches.
    public static func ran(_ command: String, as line: String) -> Bool {
        let ran: String = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return !ran.isEmpty && ran == line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `command`'s last command, after `;` or a line break, is `bw lock`: it runs however the import ended.
    /// After `&&` it would not run when nothing was imported.
    public static func endsWithLock(_ command: String) -> Bool {
        let parts: [Substring] = command.split { (character: Character) -> Bool in character == ";" || character == "\n" }
        let commands: [Substring] = parts.filter { (part: Substring) -> Bool in
            !part.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let last = commands.last else { return false }
        return last.split(whereSeparator: \.isWhitespace) == ["bw", "lock"]
    }

    /// Whether `command` runs `program` as a word of its own: at the start, after a space, or after `|`, `;`, `&` or
    /// `(`. It only decides whether a session line is worth showing, so a word that isn't a command costs nothing.
    static func runs(_ program: String, in command: String) -> Bool {
        let pattern: String = "(^|[\\s|;&(])" + NSRegularExpression.escapedPattern(for: program) + "(\\s|$)"
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// The done line on how to end the password manager's session, for keys piped in as `format`:
    /// - 1Password: its authorization lasts until the tab closes, so the line needs a tab, and a known command that
    ///   ran `op`;
    /// - Bitwarden: locked again when the line, as the shell said it ran, ends with `bw lock`; still unlocked when it
    ///   ran `bw` without it. A shell that doesn't say (only zsh's integration does) gets a line with an if, and only
    ///   in the preset's own tab.
    /// `command` is nil, or blank, when the shell didn't say.
    public static func sessionLine(format: SecretSources.Format, command: String?, tabPreset: SecretImportPreset?,
                                   inTab: Bool) -> String? {
        let said: String = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let known: String? = said.isEmpty ? nil : said
        switch format {
        case .onePassword:
            guard inTab else { return nil }
            if let known, !runs("op", in: known) { return nil }
            return onePasswordLine
        case .bitwarden:
            guard let known else { return tabPreset == .bitwarden ? lockedIfLine : nil }
            if endsWithLock(known) { return lockedLine }
            return runs("bw", in: known) ? unlockedLine : nil
        default:
            return nil
        }
    }
}
