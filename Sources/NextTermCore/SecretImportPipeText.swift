import Foundation

// The only lines `nxtrm secret import` prints, on standard error: fixed sentences with counts. None holds a name, a
// value or any other byte of what was piped in.

extension SecretImportPipe {
    /// How far the importer got, or how it ended.
    public enum Ending: Equatable, Sendable {
        /// The preview opened with this many keys (a line along the way).
        case found(Int)
        /// The preview opened, saying why the input couldn't be read (a line along the way).
        case unreadable
        /// The file is an agent's MCP config: the MCP-config import opened for it.
        case moved
        case imported(Int)
        case nothing
        case refused
        case busy
        /// Next Term closed the connection before the preview ended.
        case closed
        /// Next Term is not running, or agent control is off.
        case noSocket
        /// The socket's owner is not this copy of Next Term.
        case peerCheck
        case tooLarge
        /// Nothing came on standard input: the CLI before it failed, or was not unlocked.
        case empty
        /// The FILE given isn't there.
        case noFile(String)
        case usage(String)
        case help
    }

    /// The line for `ending`, and the exit code it ends with (a line along the way has 0, unused).
    public static func text(_ ending: Ending) -> (line: String, exit: Int32) {
        switch ending {
        case .found(let count):
            guard count > 0 else { return ("Next Term: no keys found. The Import window says what it read.", 0) }
            let one: Bool = count == 1
            return ("Next Term: \(count) \(one ? "key" : "keys") found. Choose \(one ? "it" : "them") in the Import window.", 0)
        case .unreadable:
            return ("Next Term: it couldn\u{2019}t read keys from this. The Import window says why.", 0)
        case .moved:
            return ("Next Term: this is an agent\u{2019}s MCP config. Choose its keys in the Import window, which moves them out of it.", 0)
        case .imported(let count):
            guard count > 0 else { return ("Nothing imported.", 1) }
            return ("Imported \(count) \(count == 1 ? "key" : "keys").", 0)
        case .nothing:
            return ("Nothing imported.", 1)
        case .refused:
            return ("nxtrm: Next Term refused this import.", 1)
        case .busy:
            return ("nxtrm: Next Term is showing another import or sheet in Secrets. Finish it, then run this again.", 1)
        case .closed:
            return ("nxtrm: Next Term closed before the Import window ended. Secrets lists any key it imported.", 1)
        case .noSocket:
            return ("nxtrm: Next Term is not running, or \u{201C}Let agents control Next Term\u{201D} is off in its Settings. "
                    + "Open Next Term, then run this again.", 1)
        case .peerCheck:
            return ("nxtrm: the program at Next Term\u{2019}s socket is not this copy of Next Term, so nothing was sent.", 1)
        case .tooLarge:
            return ("nxtrm: the input is over 5 MB, so nothing was sent.", 1)
        case .empty:
            return ("nxtrm: nothing came in on standard input, so nothing was sent.", 1)
        case .noFile(let path):
            return ("nxtrm: \(path): no such file", 1)
        case .usage(let reason):
            return (reason.isEmpty ? usage : "nxtrm: \(reason)\n\(usage)", 2)
        case .help:
            return (help, 0)
        }
    }

    /// The ending a last reply gives; a reply that can't end the import is a refusal.
    public static func ending(for reply: Reply) -> Ending {
        switch reply.status {
        case .imported: return .imported(reply.count ?? 0)
        case .nothing: return .nothing
        case .busy: return .busy
        case .moved: return .moved
        case .refused, .ready, .found, .unreadable: return .refused
        }
    }

    /// `nxtrm secret import --help`, and its part of `nxtrm secret help`.
    public static let help = """
        \(usage)

        Opens Next Term's Import window for a file of keys, or for keys piped in (-) from a password manager's CLI. \
        You choose which keys to copy into Secrets there, and approve with Touch ID or your password. FORMAT is \
        1password, bitwarden, bws, env, json, csv, yaml or toml; without it, Next Term reads the format from the \
        content. Standard input is read up to 5 MB. It prints only how many keys were found and imported, never a \
        name or a value.

        For a password manager, Settings › Secrets › Import From › 1Password…, Bitwarden… or Bitwarden Secrets \
        Manager… types its CLI's line in a new tab, for you to read and run.
        """
}
