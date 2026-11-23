import AppKit
import NextTermCore

/// Settings › Secrets › Agents look here first, in a scratch home (never the user's own folders, and nothing to the Trash):
/// Add writes the skill's text and Claude Code's relative link, a stale copy of Next Term's own is brought up to date, and
/// a copy of someone else's is never written over or removed.
extension SelfTest {
    static func secretsSkillCopyChecks() async {
        let fm = FileManager.default
        let scratch: String = NSTemporaryDirectory() + "nt-skill-copy-\(getpid())"
        try? fm.createDirectory(atPath: scratch + "/.claude", withIntermediateDirectories: true)
        let savedHome: String = SecretsSkillInstall.home
        let savedTrashes: Bool = SecretsSkillInstall.trashes
        SecretsSkillInstall.home = scratch
        SecretsSkillInstall.trashes = false
        SecretsSkillInstall.written = nil
        defer {
            SecretsSkillInstall.home = savedHome
            SecretsSkillInstall.trashes = savedTrashes
            SecretsSkillInstall.written = nil
            try? fm.removeItem(atPath: scratch)
        }
        let paths = SecretsSkillInstall.paths
        let view = SecretsSkillSettingView()
        check(SecretsSkillInstall.state() == .absent && !view.addButton.isHidden && view.addButton.isEnabled && view.removeButton.isHidden,
              "secrets skill copy: with none added, Settings offers Add to Agents…", view.stateLabel.stringValue)

        let added: String? = SecretsSkillInstall.add()
        let text: String? = try? String(contentsOfFile: paths.file, encoding: .utf8)
        let link: String? = try? fm.destinationOfSymbolicLink(atPath: paths.claudeLink)
        let linked: Bool = SecretsSkillCopy.linkIsOurs(destination: link, linkPath: paths.claudeLink, folder: paths.folder)
        check(added == nil && text == BuiltInSkill.secrets.text && linked && link?.hasPrefix("/") == false,
              "secrets skill copy: Add writes the skill's text and a relative link for Claude Code", "\(added ?? "added") | link \(link ?? "none")")
        view.reload()
        check(SecretsSkillInstall.state() == .current && view.addButton.isHidden && !view.removeButton.isHidden,
              "secrets skill copy: once added, Settings says so and offers Remove", view.stateLabel.stringValue)

        // An earlier version of Next Term's own copy is brought up to date at launch.
        let old = "---\nname: next-term-secrets\ndescription: an earlier text\n---\n"
        try? old.write(toFile: paths.file, atomically: true, encoding: .utf8)
        SecretsSkillInstall.written = SecretsSkillCopy.hash(old)
        SecretsSkillInstall.refresh()
        check((try? String(contentsOfFile: paths.file, encoding: .utf8)) == BuiltInSkill.secrets.text,
              "secrets skill copy: Next Term's own copy of an earlier version is brought up to date")

        // The user edits it: theirs now, never written over or removed.
        let edited = BuiltInSkill.secrets.text + "\nMy own line.\n"
        try? edited.write(toFile: paths.file, atomically: true, encoding: .utf8)
        SecretsSkillInstall.refresh()
        let kept: Bool = (try? String(contentsOfFile: paths.file, encoding: .utf8)) == edited
        check(kept && SecretsSkillInstall.state() == .theirs && SecretsSkillInstall.remove() != nil && SecretsSkillInstall.add() != nil
              && (try? String(contentsOfFile: paths.file, encoding: .utf8)) == edited,
              "secrets skill copy: an edited copy is the user's, left as it is by launch, Add and Remove")

        // Back to Next Term's own, then Remove takes the copy and its link.
        try? BuiltInSkill.secrets.text.write(toFile: paths.file, atomically: true, encoding: .utf8)
        SecretsSkillInstall.written = SecretsSkillCopy.hash(BuiltInSkill.secrets.text)
        let removed: String? = SecretsSkillInstall.remove()
        let gone: Bool = !fm.fileExists(atPath: paths.folder) && (try? fm.destinationOfSymbolicLink(atPath: paths.claudeLink)) == nil
        check(removed == nil && gone && SecretsSkillInstall.written == nil,
              "secrets skill copy: Remove takes Next Term's copy and its link", removed ?? "removed")
    }
}

extension SelfTest {
    /// The review's cases: a linked ~/.claude still gets a link that reaches SKILL.md; Remove leaves a folder with
    /// someone's files in it; a linked SKILL.md is not Next Term's.
    static func secretsSkillCopyEdgeChecks() async {
        let fm = FileManager.default
        let scratch: String = NSTemporaryDirectory() + "nt-skill-edge-\(getpid())"
        let dotfiles: String = scratch + "/dotfiles/claude"
        try? fm.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: scratch + "/home", withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: scratch + "/home/.claude", withDestinationPath: dotfiles)
        let savedHome: String = SecretsSkillInstall.home
        let savedTrashes: Bool = SecretsSkillInstall.trashes
        SecretsSkillInstall.home = scratch + "/home"
        SecretsSkillInstall.trashes = false
        SecretsSkillInstall.written = nil
        defer {
            SecretsSkillInstall.home = savedHome
            SecretsSkillInstall.trashes = savedTrashes
            SecretsSkillInstall.written = nil
            try? fm.removeItem(atPath: scratch)
        }
        let paths = SecretsSkillInstall.paths
        let added: String? = SecretsSkillInstall.add()
        let reaches: Bool = fm.fileExists(atPath: paths.claudeLink + "/SKILL.md")
        check(added == nil && reaches && SecretsSkillInstall.claudeNote.contains("through a link"),
              "secrets skill copy: with ~/.claude a link into a dotfiles folder, Claude Code's link still reaches SKILL.md",
              SecretsSkillInstall.claudeNote)
        try? "mine".write(toFile: paths.folder + "/notes.md", atomically: true, encoding: .utf8)
        let refused: String? = SecretsSkillInstall.remove()
        check(refused?.contains("notes.md") == true && fm.fileExists(atPath: paths.file) && fm.fileExists(atPath: paths.folder + "/notes.md"),
              "secrets skill copy: Remove leaves a folder holding someone's files, naming them", refused ?? "removed")
        try? fm.removeItem(atPath: paths.folder + "/notes.md")
        // SKILL.md as a link to the same text: not Next Term's, so the refresh never replaces the link with a file.
        let elsewhere: String = scratch + "/elsewhere.md"
        try? BuiltInSkill.secrets.text.write(toFile: elsewhere, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: paths.file)
        try? fm.createSymbolicLink(atPath: paths.file, withDestinationPath: elsewhere)
        SecretsSkillInstall.refresh()
        let stillLink: Bool = (try? fm.destinationOfSymbolicLink(atPath: paths.file)) != nil
        check(SecretsSkillInstall.state() == .theirs && stillLink,
              "secrets skill copy: a linked SKILL.md is the user's, and the launch's refresh leaves the link")
    }
}
