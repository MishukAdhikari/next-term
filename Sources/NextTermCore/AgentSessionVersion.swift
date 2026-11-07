import Foundation

/// The CLI version an agent session runs, and what the app keeps of it (plan 035 U7): Claude Code's from the first line of
/// `claude --version`, Codex's from its app-server's user agent. The app keeps the last version each agent ran, by agent
/// id, and a session whose version differs gets one line saying so. No network, no changelog, no update of the CLI.
public enum AgentSessionVersion {
    /// The first version number in `line`'s first line ("2.1.4 (Claude Code)" gives 2.1.4), or nil.
    public static func parse(_ line: String) -> String? {
        guard let first = line.split(whereSeparator: \.isNewline).first else { return nil }
        let text = String(first.prefix(200))
        return firstVersion(in: text)
    }

    /// The version in a user agent: the one after the first "/" ("codex_cli_rs/0.154.0 (Mac OS …)" gives 0.154.0), or
    /// the first version number in it.
    public static func fromUserAgent(_ agent: String) -> String? {
        let text = String(agent.prefix(400))
        if let slash = text.firstIndex(of: "/"), let found = firstVersion(in: String(text[text.index(after: slash)...])) {
            return found
        }
        return firstVersion(in: text)
    }

    private static let version = try! NSRegularExpression(pattern: #"\b\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?"#)

    private static func firstVersion(in text: String) -> String? {
        let ns = text as NSString
        guard let match = version.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range)
    }

    /// `version` seen for agent `id`, against the versions kept so far: what to keep now, and the version it replaced
    /// when that differs (nil the first time, and when it is the same).
    public static func remember(_ version: String, for id: String, in stored: [String: String])
        -> (stored: [String: String], previous: String?) {
        var kept = stored
        let before = stored[id]
        kept[id] = version
        let changed: Bool = before != nil && before != version
        return (kept, changed ? before : nil)
    }

    /// The session's line when the CLI changed since the last session: "Claude Code updated 2.1.4 → 2.2.0".
    public static func updatedLine(agent: String, from old: String, to new: String) -> String {
        agent + " updated " + old + " \u{2192} " + new
    }

    /// A session id a resume may name: 1 to 128 of letters, digits, `-`, `_` and `.`, so the line that resumes it needs
    /// no quoting and holds nothing a shell reads.
    public static func isSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { (byte: UInt8) -> Bool in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            default: return byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
            }
        }
    }
}
