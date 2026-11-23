import CryptoKit
import Foundation

/// Next Term's own skills (BuiltInSkill) on disk: a copy of each in ~/.agents/skills, which Codex (the app and the CLI),
/// Gemini CLI, Copilot CLI, Cursor, OpenCode, Qwen Code and Command Code load themselves, and a link to it in
/// ~/.claude/skills for Claude Code. Agents then have them even where Next Term's MCP server doesn't reach them (the
/// Codex app, outside Next Term's tabs).
///
/// The rules here, with no file access: where each copy goes, whose a copy on disk is (Next Term's own by the hash it
/// wrote, else the user's), and what to do with it. A copy that is not Next Term's own is never overwritten or removed,
/// and one the user deleted is never written again. The text written is the skill's constant, the one get_skill serves.
public enum BuiltInSkillCopy {
    /// A copy's folder and its SKILL.md, and Claude Code's link to that folder.
    public struct Paths: Equatable, Sendable {
        public let folder: String
        public let file: String
        public let claudeLink: String

        public init(home: String, name: String) {
            folder = (home as NSString).appendingPathComponent(".agents/skills/" + name)
            file = (folder as NSString).appendingPathComponent("SKILL.md")
            claudeLink = (home as NSString).appendingPathComponent(".claude/skills/" + name)
        }
    }

    /// What is at a copy's place.
    public enum State: Equatable, Sendable {
        /// Nothing there.
        case absent
        /// Next Term's own copy, as it is now.
        case current
        /// Next Term's own copy, of an earlier version: brought up to date.
        case stale
        /// Something of the user's or another tool's: left alone.
        case theirs
    }

    /// What to do with one skill's copy.
    public enum Action: Equatable, Sendable {
        /// Write the copy and Claude Code's link.
        case write
        /// Write today's text over Next Term's own earlier copy, and make the link if it is missing.
        case refresh
        /// The copy is current: make the link if it is missing.
        case link
        /// Take Next Term's own copy and its link away: the skill is off, or the user said no to it.
        case remove
        /// Not Next Term's: never touched.
        case leave
        /// Next Term's copy was deleted: record that the user said no, and never write it again.
        case decline
        case nothing
    }

    /// One skill, what to do with its copy, and the text a write puts there.
    public struct Step: Equatable, Sendable {
        public let skill: BuiltInSkill
        public let action: Action
        /// The skill's constant, the same text get_skill serves; nothing else is ever written.
        public var text: String { skill.text }

        public init(skill: BuiltInSkill, action: Action) {
            self.skill = skill
            self.action = action
        }
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

    /// What to do with one copy. `recorded`: Next Term has a hash on record for it, so an absent copy is one it wrote and
    /// someone deleted; `wanted`: offered now (agent control on, and for next-term-tabs the tabs setting on); `declined`:
    /// the user removed it, which holds until they restore it.
    public static func action(state: State, recorded: Bool, wanted: Bool, declined: Bool) -> Action {
        switch state {
        case .theirs: return .leave
        case .current, .stale:
            guard wanted, !declined else { return .remove }
            return state == .current ? .link : .refresh
        case .absent:
            guard wanted, !declined else { return .nothing }
            return recorded ? .decline : .write
        }
    }

    /// Every built-in skill and what to do with its copy. `states`: by name, absent when missing; `written`: the hashes
    /// on record, by name; `wanted`: the skills offered now (as get_skill offers them); `declined`: the names the user
    /// removed.
    public static func plan(states: [String: State], written: [String: String], wanted: [BuiltInSkill], declined: Set<String>) -> [Step] {
        BuiltInSkill.all.map { skill in
            Step(skill: skill, action: action(state: states[skill.name] ?? .absent, recorded: written[skill.name] != nil,
                                              wanted: wanted.contains(skill), declined: declined.contains(skill.name)))
        }
    }

    /// The records, with the hash an earlier Next Term kept for next-term-secrets alone moved in. A record already there
    /// wins.
    public static func migrate(written: [String: String], oldSecretsHash: String?) -> [String: String] {
        var records = written
        if let oldSecretsHash, records[BuiltInSkill.secrets.name] == nil { records[BuiltInSkill.secrets.name] = oldSecretsHash }
        return records
    }

    /// Whether Claude Code's link is Next Term's: a link whose target is the copy's folder (relative or absolute).
    public static func linkIsOurs(destination: String?, linkPath: String, folder: String) -> Bool {
        guard let destination else { return false }
        let base = (linkPath as NSString).deletingLastPathComponent
        let resolved = destination.hasPrefix("/") ? destination : (base as NSString).appendingPathComponent(destination)
        return (resolved as NSString).standardizingPath == (folder as NSString).standardizingPath
    }

    /// What Settings › Secrets says of the next-term-secrets copy, by state.
    public static func secretsSummary(_ state: State, declined: Bool) -> String {
        switch state {
        case .absent where declined:
            return "Removed: agents learn of Secrets from Next Term\u{2019}s MCP server only. Restore puts the skill back."
        case .absent: return "Not in your skills folder: Next Term adds it while agents may control Next Term."
        case .current, .stale: return "In your agents\u{2019} skills folder, kept current by Next Term."
        case .theirs: return "~/.agents/skills already has a next-term-secrets skill that isn\u{2019}t Next Term\u{2019}s: it stays as it is."
        }
    }

    /// The row's title and help in Settings › Secrets.
    public static let secretsTitle = "Agents look here first"
    public static let secretsHelp = "Next Term keeps the next-term-secrets skill in ~/.agents/skills, which Codex, Gemini CLI, Copilot CLI, "
        + "Cursor, OpenCode and Qwen Code load themselves, with a link for Claude Code, so your agents check Secrets before they ask "
        + "you for a key or read your shell files, even outside Next Term. It holds rules only, never a key\u{2019}s name or value."
}
