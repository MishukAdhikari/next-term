import AppKit
import NextTermCore

/// Claude Code's link for the skill folders in a review that are also Claude Code plugins: a popup with
/// two choices, leave them out of Claude Code or add them as plugins, and a line beside it saying what
/// Install does with each. One popup covers every ticked plugin folder (or the selected one, with none
/// ticked); plain skills keep the review's checkbox. Neither choice writes any agent's settings: a plugin
/// added here is kept off in Claude Code's own /plugin.
@MainActor
final class SkillsClaudeChoice: NSObject {
    /// One plugin folder the popup covers, with what its line needs.
    struct Folder {
        let skill: String
        let plugin: SkillPackage.ClaudePlugin
        let start: SkillPackage.Start
        /// A link to the shared copy is in ~/.claude/skills now (an update).
        let keptLink: Bool
        let clashes: [SkillInstall.Clash]
        /// Its own default (SkillInstall.defaultClaudeLink).
        let preset: SkillInstall.ClaudeLink
    }

    /// The popup and the line beside it, as one row: hidden when no plugin folder is covered.
    let view: NSStackView
    /// Readable by the self-test.
    let popup = NSPopUpButton()
    let line = NSTextField(wrappingLabelWithString: "")
    /// Called when the user picks.
    var onChange: (() -> Void)?
    /// The user's pick; nil until they pick, so the popup follows the safest of the folders' defaults.
    private var picked: SkillInstall.ClaudeLink?
    private var folders: [Folder] = []

    override init() {
        line.font = .systemFont(ofSize: 11.5)
        line.textColor = .secondaryLabelColor
        line.isSelectable = true
        // Fits beside the popup in the review's narrowest window (720 pt), and wraps.
        line.preferredMaxLayoutWidth = 420
        popup.toolTip = "A skill folder that is also a Claude Code plugin loads through its link in ~/.claude/skills as a plugin, "
            + "and its MCP servers, hooks and programs start with it. Next Term changes none of Claude Code's settings: "
            + "to keep an added plugin off, turn it off in Claude Code's /plugin."
        view = NSStackView(views: [popup, line])
        view.alignment = .firstBaseline
        view.spacing = 10
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    /// What Install does for the covered plugin folders now.
    var value: SkillInstall.ClaudeLink { picked ?? SkillInstall.ClaudeLink.safest(folders.map(\.preset)) }

    /// Shows the popup for these folders, or hides it for none.
    func show(_ covered: [Folder]) {
        folders = covered
        view.isHidden = covered.isEmpty
        guard !covered.isEmpty else { return }
        let removes = covered.allSatisfy(\.keptLink)
        popup.removeAllItems()
        popup.addItems(withTitles: SkillReviewText.choiceItems(count: covered.count, removesLink: removes))
        popup.selectItem(at: value == .link ? 1 : 0)
        updateLine()
    }

    /// Back to the default: a newly covered folder whose own default leaves it out resets the pick to that.
    func reset() { picked = nil }

    /// While Install runs, nothing changes the choice.
    func setEnabled(_ enabled: Bool) { popup.isEnabled = enabled }

    private func updateLine() {
        let choice = value
        let clauses = folders.map { folder in
            SkillReviewText.choiceLine(skill: folder.skill, plugin: folder.plugin, choice: choice, start: folder.start,
                                       keptLink: folder.keptLink, clashes: folder.clashes)
        }
        line.stringValue = clauses.joined(separator: " ")
    }

    @objc private func changed() {
        picked = popup.indexOfSelectedItem == 1 ? .link : .skip
        updateLine()
        onChange?()
    }
}
