import AppKit
import NextTermCore

/// Claude Code's link for the skill folders in a review that are also Claude Code plugins: a popup with
/// two choices, leave them out of Claude Code or add them as plugins, and a line beside it saying what
/// Install does with each. One popup covers every ticked plugin folder (or the selected one, with none
/// ticked); plain skills keep the review's checkbox. Neither choice writes any agent's settings: to keep an
/// added plugin off, the user turns it off in Claude Code's own /plugin. Settings › Skills' Link asks the
/// same question (askToLink), and Unify shows the same popup (SkillsUnifyChoice).
@MainActor
final class SkillsClaudeChoice: NSObject {
    /// One plugin folder the popup covers, with what its line needs.
    struct Folder {
        let skill: String
        let plugin: SkillPackage.ClaudePlugin
        let start: SkillPackage.Start
        /// A link to the shared copy is in ~/.claude/skills now (an update), or, in Unify, Claude Code's link
        /// to the copy kept: leaving it out removes that link.
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
        popup.setAccessibilityLabel("Claude Code")
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

    /// Laid out for a narrow sheet (Unify's): the line under the popup, wrapping at `width`.
    func stack(width: CGFloat) {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 4
        line.preferredMaxLayoutWidth = width
    }

    /// The line names what Install does with each folder (the first three), and stands out when a folder
    /// added this way starts programs by itself. VoiceOver hears it with the popup, and again when it changes.
    private func updateLine() {
        let choice = value
        let clauses = folders.map { folder in
            SkillReviewText.choiceLine(skill: folder.skill, plugin: folder.plugin, choice: choice, start: folder.start,
                                       keptLink: folder.keptLink, clashes: folder.clashes)
        }
        let warns = choice == .link && folders.contains { SkillReviewText.choiceWarns($0.plugin, start: $0.start, clashes: $0.clashes) }
        line.stringValue = SkillReviewText.choiceSummary(clauses, choice: choice, warns: warns)
        line.textColor = warns ? .labelColor : .secondaryLabelColor
        popup.setAccessibilityHelp(line.stringValue)
        NSAccessibility.post(element: line, notification: .valueChanged)
    }

    @objc private func changed() {
        picked = popup.indexOfSelectedItem == 1 ? .link : .skip
        updateLine()
        onChange?()
    }
}

// MARK: Settings › Skills

extension SkillsClaudeChoice {
    /// Settings › Skills' Link: a link at `at`, in ~/.claude/skills, to the shared copy `to`, as one change for
    /// Undo. A shared copy that is also a Claude Code plugin that runs something, or whose name meets another
    /// plugin, is asked about first (R10), with what it would start; Cancel, on Return, links nothing. The
    /// question is read again in the change's own turn: if the folder or Claude Code's plugins changed since,
    /// nothing is linked. No agent's settings are written.
    static func askToLink(_ name: String, at: String, to: String, in window: NSWindow) async {
        let home = SkillsStore.home
        let shown = await Task.detached { SkillInstall.pluginLink(skill: name, inventory: SkillInventory.scan(home: home)) }.value
        if let shown, shown.asks {
            guard await confirm(linkAlert(shown), in: window) else { return }
        }
        let check: @Sendable () -> String? = {
            let now = SkillInstall.pluginLink(skill: name, inventory: SkillInventory.scan(home: home))
            return now == shown ? nil : "“\(name)” changed since you looked. Look again before linking it."
        }
        let applied = await SkillsStore.apply([.link(at: at, to: to)], title: "Link \(name) for Claude Code", precheck: check)
        if case .failure(let failure) = applied { SkillsSettingsView.tell(failure.message, in: window) }
    }

    /// Link's question about a plugin folder: "Add with Its Programs" (or "Add as Plugin"), and Cancel, which
    /// Return presses. What it would start goes in a scroll view of a fixed height, so a plugin with many
    /// parts never pushes the buttons off the screen.
    static func linkAlert(_ link: SkillInstall.PluginLink) -> NSAlert {
        let question = SkillReviewText.linkQuestion(link)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        if !question.detail.isEmpty { alert.accessoryView = detailView(question.detail) }
        alert.addButton(withTitle: question.button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    /// The question's list: read only, scrolling past its height.
    private static func detailView(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 150)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isRichText = false
            view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            view.textContainerInset = NSSize(width: 4, height: 4)
            view.string = text
            view.setAccessibilityLabel("What the plugin starts")
        }
        return scroll
    }

    /// Shows `alert` as a sheet over `window`: whether its first button was pressed.
    private static func confirm(_ alert: NSAlert, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
        }
    }

    /// Unify's check in the change's own turn: what it asked about Claude Code's link for the copy it keeps
    /// (`winner`, by path) is still what the user answered, read from the disk again.
    static func unifyCheck(_ name: String, winner: String, shown: SkillInstall.PluginLink?) -> @Sendable () -> String? {
        let home = SkillsStore.home
        return {
            let changed = "“\(name)” changed since you looked. Look again before unifying it."
            let inventory = SkillInventory.scan(home: home)
            guard let row = inventory.rows.first(where: { $0.name == name }),
                  let copy = row.copies.first(where: { $0.path == winner }) else { return changed }
            let read = SkillInstall.pluginFacts(row.distinctCopies, home: home)
            return SkillsUnifyChoice.asking(row, winner: copy, in: inventory, read: read) == shown ? nil : changed
        }
    }
}

/// Unify's Claude Code part, for a kept copy that is also a Claude Code plugin Link would ask about, while
/// Claude Code had the skill in a folder of its own: the popup with the line under it, then the plugin block
/// (what it is, how it starts, its clashes and what it would start). Hidden for any other copy, which is
/// linked as before.
@MainActor
final class SkillsUnifyChoice {
    /// The popup and its line (readable by the self-test).
    let choice = SkillsClaudeChoice()
    let view: NSStackView
    private let blockView: NSTextView
    /// The plugin shown; nil while the part is hidden.
    private(set) var shown: SkillInstall.PluginLink?
    /// What the part adds to Unify's sheet when it can show.
    static let height: CGFloat = 190

    init(width: CGFloat) {
        choice.stack(width: width)
        let scroll = NSTextView.scrollableTextView()
        blockView = scroll.documentView as? NSTextView ?? NSTextView()
        blockView.isEditable = false
        blockView.isRichText = false
        blockView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        blockView.textContainerInset = NSSize(width: 4, height: 4)
        blockView.setAccessibilityLabel("What the plugin starts")
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        view = NSStackView(views: [choice.view, scroll])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.isHidden = true
    }

    /// The plugin block as shown (readable by the self-test).
    var block: String { blockView.string }

    /// What Unify asks about Claude Code's link when `winner` is kept: a plugin folder that Link would ask
    /// about too (it runs something, or its name meets another plugin). Nil for any other copy, which is
    /// linked as before.
    nonisolated static func asking(_ row: SkillRow, winner: SkillCopy, in inventory: SkillInventory,
                                   read: SkillInstall.PluginFacts) -> SkillInstall.PluginLink? {
        guard let link = SkillUnify.pluginLink(row, winner: winner, in: inventory, read: read), link.asks else { return nil }
        return link
    }

    /// Claude Code's link after Unify: the popup's choice for a plugin shown, else a link as before.
    var value: SkillInstall.ClaudeLink { shown == nil ? .link : choice.value }

    /// Shows the part for `link`, or hides it for nil. `linked`: Claude Code's copy is a link to the kept one,
    /// so leaving it out removes that link. A newly kept copy whose own default leaves it out sets the popup
    /// back to that.
    func show(_ link: SkillInstall.PluginLink?, linked: Bool) {
        if link != shown, link?.preset == .skip { choice.reset() }
        shown = link
        view.isHidden = link == nil
        guard let link else { return choice.show([]) }
        let folder = SkillsClaudeChoice.Folder(skill: link.skill, plugin: link.plugin, start: link.start, keptLink: linked,
                                               clashes: link.clashes, preset: link.preset)
        choice.show([folder])
        blockView.string = SkillReviewText.pluginBlock(link.plugin, start: link.start, clashes: link.clashes).joined(separator: "\n")
    }
}
