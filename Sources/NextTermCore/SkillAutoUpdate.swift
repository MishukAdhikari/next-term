import Foundation

/// Which skill updates may install by themselves (Settings › Skills › Update automatically). An update installs
/// unattended only when it brings nothing that can run, or warn, beyond what the installed copy already had; anything
/// more waits in Settings › Skills for the user's review, as every update did before.
public enum SkillAutoUpdate {
    /// Why `update` waits for a review, or nil when it may install by itself over `installed`. `edited`: the installed
    /// copy was changed on disk since it was installed (an update would replace those changes).
    public static func hold(installed: SkillReview?, update: SkillReview, edited: Bool) -> String? {
        if edited { return "You changed it since it was installed; an update would replace your changes." }
        if update.refused { return "The update can\u{2019}t be installed: " + (update.flags.first { $0.level == .refuse }?.text ?? "its review refuses it.") }
        guard let installed else { return "The installed copy couldn\u{2019}t be read to compare with." }
        let runs = { (review: SkillReview) in Set(review.files.filter { $0.executable || $0.script || $0.binary || $0.program }.map(\.path)) }
        let added = runs(update).subtracting(runs(installed)).sorted()
        if !added.isEmpty { return "It adds something that runs: " + added.prefix(3).joined(separator: ", ") + (added.count > 3 ? "\u{2026}" : "") + "." }
        if update.servers != installed.servers { return "It changes the MCP servers it starts." }
        if update.package?.claude != installed.package?.claude { return "It changes what its Claude Code plugin starts." }
        let warnings = { (review: SkillReview) in Set(review.flags.filter { $0.level >= .warning }.map { $0.file + ": " + $0.text }) }
        if let new = warnings(update).subtracting(warnings(installed)).sorted().first { return "Its review warns: " + new }
        if !Set(update.capabilities).isSubset(of: Set(installed.capabilities)) {
            return "It asks to do more in an agent."
        }
        return nil
    }
}
