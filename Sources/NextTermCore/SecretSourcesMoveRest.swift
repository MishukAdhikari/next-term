import Foundation

// A file the MCP-config import rewrites can hold keys outside the servers it moves: Codex's shell `set` and model
// providers' tokens, OpenCode's providers' keys. The app sends a chosen move target to that import for its servers and,
// when the rest of the file has keys, offers them as a copy, each noted that the file still holds it. Claude Code's
// `~/.claude.json` has no rest: past its servers it holds Claude Code's own state.

extension SecretSources {
    /// What a move target's copy leaves to the MCP-config import: the servers' places, as JSON paths from the file's
    /// top (`mcp_servers`, `mcpServers`, `mcp`), and the agent whose file it is.
    struct Leaving {
        let containers: [[String]]
        let agent: String

        /// Whether a place is in one of the servers' containers, or is one.
        func moves(_ place: String) -> Bool {
            containers.contains { (path: [String]) -> Bool in
                let head: String = path.joined(separator: ".")
                return place == head || place.hasPrefix(head + ".") || place.hasPrefix(head + "[")
            }
        }

        /// The values outside the servers, each noted that the file still holds it when its reader gave no note.
        func kept(_ found: [Found]) -> [Found] {
            found.compactMap { (item: Found) -> Found? in
                guard !moves(item.place) else { return nil }
                var kept: Found = item
                kept.note = kept.note ?? .stillInFile
                return kept
            }
        }
    }

    /// The report for a move target's keys outside the servers the MCP-config import moves, read from the file's
    /// `bytes`, which are wiped. The purpose names the open project the file is in, else its folder. Claude Code's
    /// `~/.claude.json` gives an empty report.
    public static func readOutsideServers(_ bytes: inout [UInt8], of source: SecretImport.Source,
                                          stored: Set<String> = [], now: Date = Date()) -> SourceReport {
        let path = source.path as NSString
        let file: String = path.lastPathComponent
        let parent: String = (path.deletingLastPathComponent as NSString).lastPathComponent
        let folder: String = source.project.map { (project: String) -> String in
            (project as NSString).lastPathComponent
        } ?? parent
        let format: Format = source.format == .toml ? .toml : .json
        guard let containers = source.containers, !source.isClaudeConfig else {
            SecretBytes.wipe(&bytes)
            let reason: String = purpose(file: file, folder: folder)
            return SourceReport(format: format, purpose: reason, agent: source.client.name)
        }
        let leaving = Leaving(containers: containers, agent: source.client.name)
        return readReport(&bytes, name: file, folder: folder, format: format, stored: stored, now: now,
                          leaving: leaving)
    }
}
