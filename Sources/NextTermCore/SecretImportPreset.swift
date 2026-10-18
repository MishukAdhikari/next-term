import Foundation

/// Import From › 1Password…, Bitwarden… and Bitwarden Secrets Manager…: the user's own CLI, run by the user in a visible
/// tab, piped into `nxtrm secret import`. Next Term types the line and never presses its Return, never runs a CLI
/// itself, installs nothing and probes for nothing. Unlocking happens at the CLI's own prompt. No line carries a
/// credential Next Term stores: `bws` reads its access token from the tab's environment, never through `secret run`.
public enum SecretImportPreset: String, CaseIterable, Sendable {
    case onePassword = "1password"
    case bitwarden
    case bws

    /// The shells whose syntax the line is written in: the sh family, and fish, which reads `VAR=value command` and
    /// `"$(…)"` too.
    public static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "mksh", "fish"]

    public init?(format: SecretSources.Format) {
        self.init(rawValue: format.rawValue)
    }

    /// The format `nxtrm secret import --from` reads it as.
    public var format: SecretSources.Format {
        switch self {
        case .onePassword: return .onePassword
        case .bitwarden: return .bitwarden
        case .bws: return .bws
        }
    }

    /// The app's name, as the menu, the sheet and the tab name it.
    public var app: String {
        switch self {
        case .onePassword: return "1Password"
        case .bitwarden: return "Bitwarden"
        case .bws: return "Bitwarden Secrets Manager"
        }
    }

    /// The CLI's program.
    public var program: String {
        switch self {
        case .onePassword: return "op"
        case .bitwarden: return "bw"
        case .bws: return "bws"
        }
    }

    public var tabTitle: String { "Import from " + app }

    /// Where the CLI is downloaded from; the sheet links it, and Next Term fetches nothing.
    public var download: URL {
        switch self {
        case .onePassword: return URL(string: "https://1password.com/downloads/command-line")!
        case .bitwarden: return URL(string: "https://bitwarden.com/help/cli/")!
        case .bws: return URL(string: "https://bitwarden.com/help/secrets-manager-cli/")!
        }
    }

    /// What runs before `nxtrm`, and after it.
    /// - 1Password: `op item get -` reads the listed items on standard input; `--reveal` gives concealed fields' values.
    /// - Bitwarden: `bw unlock` asks on standard error while `$(…)` takes its session key, which sets `bw list`'s
    ///   environment for that one process: in no shell variable, on no screen, in no argv. `bw lock` ends the session.
    /// - Bitwarden Secrets Manager: `bws` takes its access token from the tab's own environment, or asks for it.
    var parts: (head: String, tail: String) {
        switch self {
        case .onePassword:
            return ("op item list --categories \"API Credential,Password\" --format json | op item get - --format json --reveal | ", "")
        case .bitwarden:
            return ("BW_SESSION=\"$(bw unlock --raw)\" bw list items | ", "; bw lock")
        case .bws:
            return ("bws secret list --output json | ", "")
        }
    }

    /// The line typed into the tab, with `nxtrm` (the app's script, or its binary with `--cli`) quoted for `shell`; nil
    /// for a shell the line can't be written in, or a word it can't quote.
    public func line(nxtrm: [String], shell: String) -> String? {
        guard Self.shells.contains(shell), !nxtrm.isEmpty else { return nil }
        let words: [String] = nxtrm + ["secret", "import", "--from", format.rawValue, "-"]
        guard let importer = SecretRun.typedLine(words, shell: shell) else { return nil }
        let parts = self.parts
        return parts.head + importer + parts.tail
    }
}
