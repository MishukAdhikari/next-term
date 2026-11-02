import CryptoKit
import Foundation

/// Settings › Secrets › "Add to Agents": a copy of Next Term's next-term-secrets skill in ~/.agents/skills, which Codex
/// (the app and the CLI), Gemini CLI, Copilot CLI, Cursor, OpenCode, Qwen Code and Command Code load themselves, and a
/// link to it in ~/.claude/skills for Claude Code. Agents then look in Secrets for a key even where Next Term's MCP
/// instructions don't reach them (the Codex app, outside Next Term's tabs). Written only when the user clicks Add, never
/// by an agent; the owner chose it on 2026-11-02 for this one skill, over the rule that Next Term's skills stay off disk.
///
/// The rules here, with no file access: where the copy goes, whose a copy on disk is (Next Term's own by the hash it
/// wrote, else the user's), and when Next Term's own copy is brought up to date. A copy that is not Next Term's own is
/// never overwritten or removed.
public enum SecretsSkillCopy {
    public static let name = "next-term-secrets"

    /// The copy's folder and its SKILL.md, and Claude Code's link to that folder.
    public struct Paths: Equatable, Sendable {
        public let folder: String
        public let file: String
        public let claudeLink: String

        public init(home: String) {
            folder = (home as NSString).appendingPathComponent(".agents/skills/" + SecretsSkillCopy.name)
            file = (folder as NSString).appendingPathComponent("SKILL.md")
            claudeLink = (home as NSString).appendingPathComponent(".claude/skills/" + SecretsSkillCopy.name)
        }
    }

    /// What is at the copy's place.
    public enum State: Equatable, Sendable {
        /// Nothing there: Add writes it.
        case absent
        /// Next Term's own copy, as it is now.
        case current
        /// Next Term's own copy, of an earlier version: brought up to date.
        case stale
        /// Something of the user's or another tool's: left alone, and Add refuses.
        case theirs
    }

    /// The hash Next Term keeps of the text it wrote.
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whose the copy on disk is. `onDisk`: its SKILL.md's text, nil when there is none; `folderExists`: something is
    /// at the folder's place (a folder without SKILL.md, or a file, is someone else's); `written`: the hash Next Term
    /// recorded when it last wrote the copy, nil if it never did; `current`: the skill's text now.
    public static func state(onDisk: String?, folderExists: Bool, written: String?, current: String) -> State {
        guard let onDisk else { return folderExists ? .theirs : .absent }
        let found = hash(onDisk)
        if found == hash(current) { return written == nil ? .theirs : .current }
        return found == written ? .stale : .theirs
    }

    /// Whether Claude Code's link is Next Term's: a link whose target is the copy's folder (relative or absolute).
    public static func linkIsOurs(destination: String?, linkPath: String, folder: String) -> Bool {
        guard let destination else { return false }
        let base = (linkPath as NSString).deletingLastPathComponent
        let resolved = destination.hasPrefix("/") ? destination : (base as NSString).appendingPathComponent(destination)
        return (resolved as NSString).standardizingPath == (folder as NSString).standardizingPath
    }

    /// What Settings says of it, by state.
    public static func summary(_ state: State) -> String {
        switch state {
        case .absent: return "Not added: agents learn of Secrets from Next Term\u{2019}s MCP server only."
        case .current, .stale: return "Added: your agents\u{2019} skills folder has the next-term-secrets skill."
        case .theirs: return "~/.agents/skills already has a next-term-secrets skill that isn\u{2019}t Next Term\u{2019}s: it stays as it is."
        }
    }

    /// The row's title and help in Settings › Secrets.
    public static let title = "Agents look here first"
    public static let help = "Adds the next-term-secrets skill to ~/.agents/skills, which Codex, Gemini CLI, Copilot CLI, Cursor, "
        + "OpenCode and Qwen Code load themselves, with a link for Claude Code, so your agents check Secrets before they ask you "
        + "for a key or read your shell files, even outside Next Term. It holds rules only, never a key\u{2019}s name or value."
}
