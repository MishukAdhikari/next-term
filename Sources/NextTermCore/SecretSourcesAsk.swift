import Foundation

// import_secrets before anything opens: what a call names, the file it may open, and the audit lines it leaves. A
// refusal says only its class; the agent hears names and counts, never more of the file (`answer(for:)`).

extension SecretSources {
    /// What an import_secrets call names: a file of keys, or a password manager's CLI.
    public enum Asked: Equatable, Sendable {
        /// As given: absolute, from `~`, or relative to the caller's tab.
        case path(String)
        case source(SecretImportPreset)
    }

    /// Why an import_secrets call is refused before anything opens, as its note tells the agent.
    public struct AskRefusal: Error, Equatable, Sendable {
        public let note: String
        public init(_ note: String) { self.note = note }
    }

    public static let askUsage = "Give path (a file of keys) or source (1password, bitwarden or bws), not both."
    public static let askSourceUsage = "Give source as 1password, bitwarden or bws."
    public static let askPathUsage = "Give path: a file's path, at most 4,096 characters."
    public static let moveTargetNote = "That file is an agent's MCP config, whose keys Next Term's own import moves into "
        + "Secrets. The user starts that import in Settings › Secrets with Import From › MCP Configs…"

    /// The file or password manager a call's `path` and `source` name: exactly one of them, where an empty one or one
    /// that isn't text counts as none; a source by its preset's name; a path of at most `maxPathLength` characters with
    /// no NUL in it.
    public static func asked(path: Any?, source: Any?) -> Result<Asked, AskRefusal> {
        let named: String? = (path as? String).flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
        let manager: String? = (source as? String).flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
        guard (named == nil) != (manager == nil) else { return .failure(AskRefusal(askUsage)) }
        if let manager {
            guard let preset = SecretImportPreset(rawValue: manager) else { return .failure(AskRefusal(askSourceUsage)) }
            return .success(.source(preset))
        }
        guard let named, named.count <= maxPathLength, !named.contains("\0") else {
            return .failure(AskRefusal(askPathUsage))
        }
        return .success(.path(named))
    }

    /// The file an agent's `path` names, checked as `checkPath` does, unless it is an agent's MCP config: the user's
    /// own MCP-config import moves those keys, and it looks for the configs in `configHome` (the home folder unless
    /// given) and `projects`. The file to open, or the refusal's note.
    public static func checkAsked(_ path: String, home: String, vaultFolder: String, folder: String?,
                                  configHome: String? = nil, projects: [String] = []) -> Result<String, AskRefusal> {
        switch checkPath(path, home: home, vaultFolder: vaultFolder, folder: folder) {
        case .failure(let refusal): return .failure(AskRefusal(refusal.note))
        case .success(let real):
            let moves: Bool = isMoveTarget(path: real, home: configHome ?? home, projects: projects)
            return moves ? .failure(AskRefusal(moveTargetNote)) : .success(real)
        }
    }
}

// MARK: - Audit lines

extension SecretSources {
    /// The most of a path an audit command keeps ahead of the agent's reason.
    static let maxAskedPath = 120

    /// The audit lines' command for an agent's import: the tool, the file or source, and the agent's reason. With a
    /// reason, a path over `maxAskedPath` characters keeps its end, so the reason still fits in the log's command.
    public static func askedCommand(_ named: String, reason: String?) -> String {
        let tool: String = "import_secrets"
        let said: String = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return tool + " " + named }
        let end: String = String(named.suffix(maxAskedPath - 1))
        let kept: String = named.count > maxAskedPath ? "\u{2026}" + end : named
        return tool + " " + kept + " (reason: " + said + ")"
    }

    /// The audit outcome of an agent's import that copied nothing in and wasn't declined: no key found, or why the file
    /// couldn't be read, by class. Nil for a copy-in, whose line is its own (`SecretCopyIn.auditOutcome`), and for a
    /// decline, whose line is the queue's.
    public static func askedAuditOutcome(_ outcome: CopyInOutcome) -> String? {
        switch outcome {
        case .imported, .declined: return nil
        case .nothingFound(let format): return "nothing imported: no key found in " + SecretCopyIn.formatNoun(format)
        case .unreadable(let reason): return "nothing imported: " + reason.reasonClass
        }
    }
}
