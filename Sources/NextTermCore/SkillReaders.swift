import Foundation

// The agents that read the personal skill folders, beyond the three the library manages (SkillAgent), as
// of October 2026. They are text only: Settings › Skills, list_skills and Unify keep their three agents.
// From the per-agent tables of the skills library research (2026-10-07, section 2.2) and the skills and
// MCP research (2026-10-08, section 2, for goose):
// - ~/.agents/skills: Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and goose read it
//   themselves, besides Codex and Command Code. Antigravity CLI does not.
// - ~/.claude/skills: Amp, Cursor, opencode and goose read it too, so they also find a skill through
//   Claude Code's link to the shared copy.

public enum SkillReaders {
    /// Other agents that read ~/.agents/skills themselves.
    public static let shared = ["Gemini CLI", "Qwen Code", "Cursor", "opencode", "Copilot CLI", "Amp", "Junie", "goose"]
    /// Other agents that also read ~/.claude/skills.
    public static let claude = ["Amp", "Cursor", "opencode", "goose"]

    /// The review's "Agents that load it, if you use them" sentence. `agents`: the managed agents that load the skill (an
    /// install plan's). `linked`: Claude Code reads it through a link of its own in ~/.claude/skills (made
    /// or kept); without one, Claude Code in `agents` reads the shared folder itself, as when
    /// ~/.claude/skills is a link to it. `pluginOff`: Claude Code's settings turn the folder's plugin off,
    /// so Claude Code loads nothing from it.
    public static func loadedBy(_ agents: [SkillAgent], linked: Bool, pluginOff: Bool) -> String {
        var names = [SkillAgent.codex, .commandCode].filter(agents.contains).map(\.title)
        let claudeReads = agents.contains(.claudeCode)
        if claudeReads, !pluginOff { names.append(linked ? "Claude Code (through its link)" : "Claude Code") }
        names += shared
        var sentences = ["Agents that load it, if you use them: " + SkillPackage.list(names) + "."]
        if claudeReads, pluginOff { sentences.append("Claude Code loads nothing from it while its plugin is off.") }
        if claudeReads, linked { sentences.append(SkillPackage.list(claude) + " also find it through the Claude Code link.") }
        return sentences.joined(separator: " ")
    }
}
