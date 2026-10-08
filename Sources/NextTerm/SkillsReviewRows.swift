import Foundation
import NextTermCore

/// The review's rows for one skill after "Goes to …": what else its folder is (the Claude Code plugin
/// block, then other agents' packages) and "Needs MCP servers", with each agent's conditions. The text is
/// Core's (SkillReviewText); the facts are the fetch's: Claude Code's plugins and Codex's config, read when
/// the skill was fetched.
enum SkillsReviewRows {
    /// `plan`: the install plan with `choice`, Claude Code's link for this skill now.
    static func lines(_ candidate: SkillsInstaller.Candidate, fetched: SkillsInstaller.Fetched, plan: SkillInstallPlan,
                      choice: SkillInstall.ClaudeLink) -> [String] {
        let review = candidate.review
        let plugin = review.package?.claude
        let start = plugin.map { $0.start(key: fetched.claude.value(for: $0.name)) } ?? .on
        var lines: [String] = []
        if let plugin {
            lines.append("")
            lines += SkillReviewText.pluginBlock(plugin, start: start, clashes: plan.clashes)
        }
        let others = review.package.map(SkillReviewText.otherPackages) ?? []
        if !others.isEmpty {
            lines.append("")
            lines += others
        }
        let trigger = SkillServers.codexTrigger(name: candidate.name, package: review.package)
        let servers = SkillReviewText.serverRows(review.servers, choice: choice, start: start, codex: fetched.codex, trigger: trigger)
        if !servers.isEmpty {
            lines.append("")
            lines += servers
        }
        return lines
    }

    /// The plan's notes, without the clashes the plugin block names.
    static func notes(_ plan: SkillInstallPlan) -> [String] {
        let clashes = Set(plan.clashes.map(\.text))
        return plan.untouched.filter { !clashes.contains($0) }
    }
}
