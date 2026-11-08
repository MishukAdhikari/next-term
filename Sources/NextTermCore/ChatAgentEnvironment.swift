import Foundation

/// The environment a chat tab's agent starts with (plan 037 KTD7): the user's login shell's own, as their terminal tabs'
/// shells have it (PATH from nvm or volta, `ANTHROPIC_*` and `CODEX_HOME` exports), less what belongs to one shell or to
/// Next Term, plus what a Next Term tab gives every program. When the login shell's listing couldn't be read, the app's
/// own environment, cleaned as a terminal's is, with the login PATH.
public enum ChatAgentEnvironment {
    /// Names a shell sets for itself or Next Term sets for its own shells: never handed on.
    public static let dropped: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "ZDOTDIR"]

    /// Next Term's own variables (the shell integration's nonce, completion and suggestion switches, the user's ZDOTDIR):
    /// dropped by this prefix. The MCP socket is set again on top.
    public static let droppedPrefix = "NEXTTERM"

    /// `/usr/bin/env`'s listing as a dictionary. A line that doesn't start with a name and `=` goes on the value before
    /// it, as a value with a line break prints. Nil for an empty listing.
    public static func parse(listing: String) -> [String: String]? {
        var environment: [String: String] = [:]
        var last: String?
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if let equals = line.firstIndex(of: "="), isName(line[line.startIndex..<equals]) {
                let name = String(line[line.startIndex..<equals])
                environment[name] = String(line[line.index(after: equals)...])
                last = name
            } else if let name = last {
                environment[name, default: ""] += "\n" + line
            }
        }
        // The listing's own last line break isn't part of the last value.
        if let name = last, let value = environment[name], value.hasSuffix("\n") { environment[name] = String(value.dropLast()) }
        return environment.isEmpty ? nil : environment
    }

    /// A shell variable's name: a letter or `_`, then letters, digits and `_`.
    static func isName(_ text: Substring) -> Bool {
        guard let first = text.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return text.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// The agent's environment, and whether it is the login shell's (false: the fallback, which the chat says once).
    /// - login: the login shell's environment (`parse`), or nil when the probe failed.
    /// - app: Next Term's own environment, for the fallback.
    /// - loginPath: the login PATH with the usual install folders, for the fallback.
    /// - socket: the MCP control socket's path, when it runs.
    /// - toolFolder: the folder `nxtrm` is in, added to PATH.
    /// - version: Next Term's version, for `TERM_PROGRAM_VERSION`.
    public static func make(login: [String: String]?, app: [String: String], loginPath: [String], socket: String?,
                            toolFolder: String?, version: String) -> (environment: [String: String], fromLoginShell: Bool) {
        var env: [String: String]
        if let login {
            env = TerminalEnvironment.clean(login)
        } else {
            env = TerminalEnvironment.clean(app)
            if !loginPath.isEmpty { env["PATH"] = loginPath.joined(separator: ":") }
        }
        for key in env.keys where dropped.contains(key) || key.hasPrefix(droppedPrefix) { env[key] = nil }
        env["TERM_PROGRAM"] = "NextTerm"
        env["TERM_PROGRAM_VERSION"] = version
        if let socket { env[MCPServer.socketVariable] = socket }
        if let toolFolder, !toolFolder.isEmpty {
            let path = env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = path.split(separator: ":").contains(Substring(toolFolder)) ? path : path + ":" + toolFolder
        }
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        return (env, login != nil)
    }

    /// The note a chat shows once when its agent started with the fallback environment.
    public static let fallbackNote = "Started with Next Term\u{2019}s PATH; your shell\u{2019}s setup didn\u{2019}t load."
}

/// How a chat tab's host turns its session's reports into the tab's state (plan 037 KTD9), as a session tab's OSC 7501
/// records do: working is work, attention is the card's question, done and idle are the agent at rest.
public enum ChatHostStatus {
    /// The activity for a report's `state`; `question` is the open card's words (ACPTranscript.question).
    public static func activity(state: String, question: String?) -> AgentActivity {
        switch state {
        case "working": return .working
        case "attention": return .asking(question.flatMap { $0.isEmpty ? nil : $0 } ?? ProgramStatus.words(for: .permission))
        default: return .ready
        }
    }

    /// The host's state from its session's facts: an ended session, the trust wait, an open card, a turn, a ready
    /// session, else starting.
    public static func state(ended: Bool, waiting: Bool, asking: Bool, working: Bool, ready: Bool) -> ChatHostState {
        if ended { return .ended }
        if waiting { return .trusting }
        if asking { return .asking }
        if working { return .working }
        return ready ? .ready : .starting
    }
}
