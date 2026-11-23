import Foundation

/// herdr's own agent integrations as `herdr integration status` lists them (plan 040 U12): one line each,
/// "claude: not installed (/path/to/hook)", "codex: installed (…)", "pi: outdated (…)". Read so Next Term shows which
/// agents herdr follows by their own hooks, and offers Install or Uninstall.
public struct HerdrIntegration: Equatable, Sendable {
    public enum State: String, Sendable {
        case installed, notInstalled = "not installed", outdated, other
    }

    public var kind: String
    public var state: State
    /// What herdr said after the kind, whole ("not installed (…/hook.sh)").
    public var said: String

    /// Each line herdr gave that names a kind herdr's rule takes; lines that don't are left out.
    public static func parse(_ text: String) -> [HerdrIntegration] {
        text.split(whereSeparator: \.isNewline).compactMap { (row: Substring) -> HerdrIntegration? in
            let line = String(row)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let kind: String = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let said: String = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard HerdrCommand.isKind(kind) else { return nil }
            let lower = said.lowercased()
            let state: State = lower.hasPrefix("not installed") ? .notInstalled : lower.hasPrefix("outdated") ? .outdated
                : lower.hasPrefix("installed") ? .installed : .other
            return HerdrIntegration(kind: kind, state: state, said: said)
        }
    }
}
