import AppKit
import NextTermCore

/// The review sheet's Claude Code part: which skills the checkbox (plain skills) and the popup (plugin
/// folders, SkillsClaudeChoice) cover, each plugin folder's own default, and the choice each skill installs
/// with. The sheet calls these from its ticks, selection and Install.
extension SkillsReviewSheet {
    static let linkTitle = "Link it for Claude Code (in ~/.claude/skills)"

    /// The skills Claude Code's checkbox and popup cover: the ticked ones, or the selected one with none ticked.
    var covered: [SkillsInstaller.Candidate] {
        let chosen = chosen
        guard chosen.isEmpty else { return chosen }
        return fetched.candidates.indices.contains(selected) ? [fetched.candidates[selected]] : []
    }

    var coveredNames: Set<String> { Set(covered.map(\.name)) }

    /// Each plugin folder's own default, worked out once per change of ticks. Reads nothing from disk: the
    /// installed copies were read with the fetch.
    func refreshPresets() {
        presets = [:]
        guard claudeAvailable else { return }
        let chosen = chosen
        for candidate in fetched.candidates where candidate.review.package?.claude != nil {
            presets[candidate.name] = SkillsInstaller.defaultClaudeLink(candidate, fetched: fetched, together: chosen)
        }
    }

    /// A plugin folder the popup newly covers whose own default leaves it out sets the popup back to that.
    func coverChanged(from before: Set<String>) {
        let added = covered.filter { !before.contains($0.name) && $0.review.package?.claude != nil }
        if added.contains(where: { presets[$0.name] == .skip }) { choice.reset() }
    }

    /// Claude Code's link for one skill: the checkbox for a plain skill, the popup for a plugin folder it
    /// covers, and the folder's own default for one it doesn't (selected while others are ticked).
    func claudeChoice(_ candidate: SkillsInstaller.Candidate) -> SkillInstall.ClaudeLink {
        guard claudeAvailable else { return .skip }
        guard candidate.review.package?.claude != nil else { return claudeLink.state == .on ? .link : .skip }
        if covered.contains(where: { $0.name == candidate.name }) { return choice.value }
        return presets[candidate.name] ?? .skip
    }

    /// The checkbox shows when a plain skill is covered, the popup when a plugin folder is; both for both,
    /// and then the checkbox says it is for the plain skills.
    func updateControls() {
        let covered = covered
        let plain = covered.filter { $0.review.package?.claude == nil }
        claudeLink.isHidden = !claudeAvailable || plain.isEmpty
        let folders = claudeAvailable ? covered.compactMap(folder) : []
        choice.show(folders)
        if folders.isEmpty {
            claudeLink.title = Self.linkTitle
        } else {
            claudeLink.title = plain.count == 1 ? "Link the plain skill for Claude Code" : "Link the plain skills for Claude Code"
        }
    }

    func folder(_ candidate: SkillsInstaller.Candidate) -> SkillsClaudeChoice.Folder? {
        guard let plugin = candidate.review.package?.claude else { return nil }
        // The kept link and the clashes don't depend on the choice.
        let plan = SkillsInstaller.plan(candidate, fetched: fetched, claude: .skip, together: chosen)
        let start = plugin.start(key: fetched.claude.value(for: plugin.name))
        return SkillsClaudeChoice.Folder(skill: candidate.name, plugin: plugin, start: start, keptLink: plan.keptLink != nil,
                                         clashes: plan.clashes, preset: presets[candidate.name] ?? .skip)
    }

    /// After Install refused because the skill folders or Claude Code's plugins changed: the review is planned
    /// again from the disk as it is now, for the user to look at again. A covered plugin folder whose own
    /// default leaves it out (a plugin of the same name appeared, say) sets the popup back to that, even after
    /// the user picked "Add".
    func reread() async {
        let inventory = await SkillsStore.scan()
        let candidates = fetched.candidates
        let claude = await SkillsInstaller.claudeFacts(candidates)
        let codex = await SkillsInstaller.codexFacts()
        let installed = await Task.detached { SkillsInstaller.installedPackages(candidates, inventory: inventory) }.value
        fetched = fetched.with(inventory: inventory, claude: claude, codex: codex, installed: installed)
        refreshPresets()
        if covered.contains(where: { $0.review.package?.claude != nil && presets[$0.name] == .skip }) { choice.reset() }
        updateControls()
        updateDetails()
    }
}
