import AppKit
import NextTermCore

/// Next Term's own skills in the agents' skills folders, in a scratch home with scratch records (never the user's own
/// folders or defaults, and nothing to the Trash): the sync writes every skill offered with Claude Code's relative link,
/// brings an earlier copy of Next Term's own up to date, takes away only a skill turned off, never writes over a copy of
/// someone else's, and never writes again one the user deleted or removed until they restore it.
extension SelfTest {
    /// Points the installer at a scratch home and scratch records for `body`, and puts everything back after.
    private static func withScratchSkillCopies(_ tag: String, claude: String? = nil, _ body: (String) async -> Void) async {
        let fm = FileManager.default
        let scratch: String = NSTemporaryDirectory() + "nt-\(tag)-\(getpid())"
        let home: String = scratch + "/home"
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        if let claude {
            try? fm.createDirectory(atPath: claude, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: home + "/.claude", withDestinationPath: claude)
        } else {
            try? fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        }
        let suite = "nt-selftest-\(tag)-\(getpid())"
        let saved = (home: BuiltInSkillInstall.home, trashes: BuiltInSkillInstall.trashes, defaults: BuiltInSkillInstall.defaults,
                     records: SecretReminderRecords.defaults)
        let scratchDefaults: UserDefaults = UserDefaults(suiteName: suite) ?? saved.defaults
        BuiltInSkillInstall.home = home
        BuiltInSkillInstall.trashes = false
        BuiltInSkillInstall.defaults = scratchDefaults
        SecretReminderRecords.defaults = scratchDefaults
        defer {
            BuiltInSkillInstall.home = saved.home
            BuiltInSkillInstall.trashes = saved.trashes
            BuiltInSkillInstall.defaults = saved.defaults
            SecretReminderRecords.defaults = saved.records
            UserDefaults().removePersistentDomain(forName: suite)
            try? fm.removeItem(atPath: scratch)
        }
        await body(scratch)
    }

    static func builtInSkillCopyChecks() async {
        await withScratchSkillCopies("skill-copy") { _ in
            let fm = FileManager.default
            let view = SecretsSkillSettingView()
            check(BuiltInSkillInstall.state(.secrets) == .absent && view.restoreButton.isHidden && view.removeButton.isHidden,
                  "built-in skill copies: before the first sync, Settings › Secrets offers no button", view.stateLabel.stringValue)

            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            for skill in BuiltInSkill.all {
                let paths = BuiltInSkillInstall.paths(skill.name)
                let text: String? = try? String(contentsOfFile: paths.file, encoding: .utf8)
                let link: String? = try? fm.destinationOfSymbolicLink(atPath: paths.claudeLink)
                let linked: Bool = BuiltInSkillCopy.linkIsOurs(destination: link, linkPath: paths.claudeLink, folder: paths.folder)
                check(text == skill.text && linked && link?.hasPrefix("/") == false && BuiltInSkillInstall.state(skill) == .current,
                      "built-in skill copies: the sync writes \(skill.name)'s text and a relative link for Claude Code", link ?? "no link")
            }
            view.reload()
            check(view.restoreButton.isHidden && !view.removeButton.isHidden,
                  "built-in skill copies: once written, Settings › Secrets offers Remove", view.stateLabel.stringValue)

            // An earlier Next Term's next-term-secrets hash, in Secrets' records, moves over: its copy is brought up to date.
            let secrets = BuiltInSkillInstall.paths(BuiltInSkill.secrets.name)
            let old = "---\nname: next-term-secrets\ndescription: an earlier text\n---\n"
            try? old.write(toFile: secrets.file, atomically: true, encoding: .utf8)
            var records = BuiltInSkillInstall.written
            records[BuiltInSkill.secrets.name] = nil
            BuiltInSkillInstall.written = records
            SecretReminderRecords.defaults.set(BuiltInSkillCopy.hash(old), forKey: BuiltInSkillInstall.oldSecretsKey)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            check((try? String(contentsOfFile: secrets.file, encoding: .utf8)) == BuiltInSkill.secrets.text
                  && SecretReminderRecords.defaults.string(forKey: BuiltInSkillInstall.oldSecretsKey) == nil,
                  "built-in skill copies: the old next-term-secrets record moves over, and its earlier copy is brought up to date")

            // The user edits one: theirs now, never written over or removed.
            let worktrees = BuiltInSkillInstall.paths(BuiltInSkill.worktrees.name)
            let edited = BuiltInSkill.worktrees.text + "\nMy own line.\n"
            try? edited.write(toFile: worktrees.file, atomically: true, encoding: .utf8)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            BuiltInSkillInstall.sync(wanted: [])
            check((try? String(contentsOfFile: worktrees.file, encoding: .utf8)) == edited && BuiltInSkillInstall.state(.worktrees) == .theirs
                  && BuiltInSkillInstall.remove(.worktrees) != nil,
                  "built-in skill copies: an edited copy is the user's, left as it is by the sync, agent control off and Remove")
            // Agent control off took Next Term's own copies away; on again writes them back. next-term-secrets, added by
            // an earlier version (its record moved over above), is the user's choice and stays, as it did there.
            let gone: Bool = [BuiltInSkill.tabs, .setup].allSatisfy { !fm.fileExists(atPath: BuiltInSkillInstall.paths($0.name).folder) }
            let kept: Bool = BuiltInSkillInstall.state(.secrets) == .current
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            let back: Bool = [BuiltInSkill.tabs, .setup, .secrets].allSatisfy { BuiltInSkillInstall.state($0) == .current }
            check(gone && kept && back,
                  "built-in skill copies: agent control off takes Next Term's own copies away but keeps a chosen next-term-secrets, and on writes them back",
                  "gone \(gone), secrets kept \(kept), back \(back)")

            // The tabs setting off takes next-term-tabs alone, and its link.
            let tabs = BuiltInSkillInstall.paths(BuiltInSkill.tabs.name)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.offered(tabs: false))
            check(!fm.fileExists(atPath: tabs.folder) && (try? fm.destinationOfSymbolicLink(atPath: tabs.claudeLink)) == nil
                  && BuiltInSkillInstall.state(.setup) == .current && BuiltInSkillInstall.state(.secrets) == .current,
                  "built-in skill copies: the tabs setting off takes next-term-tabs and its link, and nothing else")

            // The user deletes one: it stays deleted.
            let setup = BuiltInSkillInstall.paths(BuiltInSkill.setup.name)
            try? fm.removeItem(atPath: setup.folder)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            check(!fm.fileExists(atPath: setup.folder) && BuiltInSkillInstall.declined.contains(BuiltInSkill.setup.name),
                  "built-in skill copies: a copy the user deleted is never written again")

            // Settings' Remove takes next-term-secrets and its link; it stays removed until Restore.
            let removed: String? = BuiltInSkillInstall.remove(.secrets)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            view.reload()
            check(removed == nil && !fm.fileExists(atPath: secrets.folder) && (try? fm.destinationOfSymbolicLink(atPath: secrets.claudeLink)) == nil
                  && !view.restoreButton.isHidden && view.removeButton.isHidden,
                  "built-in skill copies: Remove takes next-term-secrets and its link, the sync leaves it out, and Settings offers Restore",
                  removed ?? view.stateLabel.stringValue)
            let restored: String? = BuiltInSkillInstall.restore(.secrets)
            view.reload()
            check(restored == nil && BuiltInSkillInstall.state(.secrets) == .current && !BuiltInSkillInstall.declined.contains(BuiltInSkill.secrets.name)
                  && view.restoreButton.isHidden && !view.removeButton.isHidden,
                  "built-in skill copies: Restore writes it back", restored ?? view.stateLabel.stringValue)
        }
    }

    /// The review's cases: a linked ~/.claude still gets a link that reaches SKILL.md; Remove leaves a folder with
    /// someone's files in it; a linked SKILL.md is not Next Term's.
    static func builtInSkillCopyEdgeChecks() async {
        let dotfiles: String = NSTemporaryDirectory() + "nt-skill-edge-dotfiles-\(getpid())/claude"
        defer { try? FileManager.default.removeItem(atPath: (dotfiles as NSString).deletingLastPathComponent) }
        await withScratchSkillCopies("skill-edge", claude: dotfiles) { scratch in
            let fm = FileManager.default
            let paths = BuiltInSkillInstall.paths(BuiltInSkill.secrets.name)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            let reaches: Bool = fm.fileExists(atPath: paths.claudeLink + "/SKILL.md")
            let note: String = BuiltInSkillInstall.claudeNote(BuiltInSkill.secrets.name)
            check(reaches && note.contains("through a link"),
                  "built-in skill copies: with ~/.claude a link into a dotfiles folder, Claude Code's link still reaches SKILL.md", note)
            try? "mine".write(toFile: paths.folder + "/notes.md", atomically: true, encoding: .utf8)
            let refused: String? = BuiltInSkillInstall.remove(.secrets)
            BuiltInSkillInstall.sync(wanted: [])
            check(refused?.contains("notes.md") == true && fm.fileExists(atPath: paths.file) && fm.fileExists(atPath: paths.folder + "/notes.md"),
                  "built-in skill copies: Remove and agent control off leave a folder holding someone's files, naming them", refused ?? "removed")
            try? fm.removeItem(atPath: paths.folder + "/notes.md")
            // SKILL.md as a link to the same text: not Next Term's, so the sync never replaces the link with a file.
            let elsewhere: String = scratch + "/elsewhere.md"
            try? BuiltInSkill.secrets.text.write(toFile: elsewhere, atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: paths.file)
            try? fm.createSymbolicLink(atPath: paths.file, withDestinationPath: elsewhere)
            BuiltInSkillInstall.sync(wanted: BuiltInSkill.all)
            let stillLink: Bool = (try? fm.destinationOfSymbolicLink(atPath: paths.file)) != nil
            check(BuiltInSkillInstall.state(.secrets) == .theirs && stillLink,
                  "built-in skill copies: a linked SKILL.md is the user's, and the sync leaves the link")
        }
    }
}
