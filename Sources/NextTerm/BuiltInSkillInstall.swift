import AppKit
import NextTermCore

/// Next Term's own skills on disk (BuiltInSkillCopy has the rules): `sync` writes each skill offered now into
/// ~/.agents/skills with Claude Code's link, brings Next Term's own copies up to date and takes away those no longer
/// offered. It runs at launch and when agent control or the tabs setting changes, never from an update and never in a
/// self-test's run against the user's home. A copy or link that is not Next Term's own is never written over or removed,
/// and one the user removed (in Settings or by deleting it) stays removed until they restore it.
@MainActor
enum BuiltInSkillInstall {
    /// The home the copies go in; the self-test sets a scratch one, so it never touches the user's own folders.
    static var home: String = NSHomeDirectory()
    /// Where the records live; the self-test points it at a suite of its own.
    static var defaults: UserDefaults = .standard
    /// The hash of the text Next Term last wrote, by skill name (never a key's name or value).
    static let writtenKey = "builtInSkillCopies"
    /// The skills the user removed: never written again until they restore one.
    static let declinedKey = "builtInSkillsDeclined"
    /// The hash an earlier Next Term kept for its next-term-secrets copy alone, in Secrets' records.
    static let oldSecretsKey = "secretsSkillCopyHash"
    static let changed = Notification.Name("NextTermBuiltInSkillCopiesChanged")
    /// A user's Remove sends to the Trash; the self-test deletes its scratch copy instead, leaving the user's Trash alone.
    static var trashes = true

    static func paths(_ name: String) -> BuiltInSkillCopy.Paths { BuiltInSkillCopy.Paths(home: home, name: name) }

    static var written: [String: String] {
        get { defaults.dictionary(forKey: writtenKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: writtenKey) }
    }

    static var declined: Set<String> {
        get { Set(defaults.stringArray(forKey: declinedKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: declinedKey) }
    }

    private static var manager: FileManager { .default }

    /// The old next-term-secrets hash, in Secrets' records, moves into the records here once.
    static func migrate() {
        let old: UserDefaults = SecretReminderRecords.defaults
        guard let hash = old.string(forKey: oldSecretsKey) else { return }
        written = BuiltInSkillCopy.migrate(written: written, oldSecretsHash: hash)
        old.removeObject(forKey: oldSecretsKey)
    }

    /// Whose the copy at a skill's place is now.
    static func state(_ skill: BuiltInSkill) -> BuiltInSkillCopy.State {
        let paths = paths(skill.name)
        let text: String? = readSkill(paths.file)
        let isLink: Bool = (try? manager.destinationOfSymbolicLink(atPath: paths.folder)) != nil
        let exists: Bool = isLink || manager.fileExists(atPath: paths.folder)
        // A link at the folder's place is someone's own arrangement, whatever it points to.
        if isLink { return .theirs }
        return BuiltInSkillCopy.state(onDisk: text, folderExists: exists, written: written[skill.name], current: skill.text)
    }

    /// Brings the copies on disk in line with `wanted`, the skills offered now (AppDelegate.builtInSkills).
    static func sync(wanted: [BuiltInSkill]) {
        migrate()
        let states: [String: BuiltInSkillCopy.State] = Dictionary(uniqueKeysWithValues: BuiltInSkill.all.map { ($0.name, state($0)) })
        let plan = BuiltInSkillCopy.plan(states: states, written: written, wanted: wanted, declined: declined)
        var touched = false
        for step in plan {
            let name: String = step.skill.name
            switch step.action {
            case .write, .refresh:
                guard (try? write(step)) != nil else { continue }
                linkForClaude(name)
                touched = true
            case .link:
                linkForClaude(name)
            case .remove:
                // Not the Trash: nothing the user chose goes, only Next Term's own copy of a skill now off.
                if take(name, trash: false) == nil { touched = true }
            case .decline:
                declined.insert(name)
                written[name] = nil
                touched = true
            case .leave, .nothing:
                break
            }
        }
        if touched { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Settings' Remove: Next Term's copy and its link go to the Trash, and the skill is not written again until the
    /// user restores it. Nil when done, else why not.
    @discardableResult
    static func remove(_ skill: BuiltInSkill) -> String? {
        let now: BuiltInSkillCopy.State = state(skill)
        guard now == .current || now == .stale else { return "There is no copy of Next Term\u{2019}s to remove." }
        if let problem = take(skill.name, trash: trashes) { return problem }
        declined.insert(skill.name)
        NotificationCenter.default.post(name: changed, object: nil)
        return nil
    }

    /// Settings' Restore: the user takes back their no, and the copy and its link are written. Nil when done, else why not.
    @discardableResult
    static func restore(_ skill: BuiltInSkill) -> String? {
        guard state(skill) != .theirs else { return BuiltInSkillCopy.secretsSummary(.theirs, declined: false) }
        declined.remove(skill.name)
        do {
            try write(BuiltInSkillCopy.Step(skill: skill, action: .write))
        } catch {
            return "Couldn\u{2019}t write ~/.agents/skills/\(skill.name): \(error.localizedDescription)"
        }
        linkForClaude(skill.name)
        NotificationCenter.default.post(name: changed, object: nil)
        return nil
    }

    /// Takes Next Term's copy and its own link away, and its record; nil when done, else why not. A folder holding files
    /// someone added beside SKILL.md stays, and the user is told which.
    private static func take(_ name: String, trash: Bool) -> String? {
        let paths = paths(name)
        let extra: [String] = extraFiles(name)
        guard extra.isEmpty else {
            return "~/.agents/skills/\(name) also holds \(extra.prefix(5).joined(separator: ", ")): move them out, then Remove."
        }
        do {
            try discard(paths.folder, trash: trash)
        } catch {
            return "Couldn\u{2019}t move ~/.agents/skills/\(name) to the Trash: \(error.localizedDescription)"
        }
        let link: String = paths.claudeLink
        let destination: String? = try? manager.destinationOfSymbolicLink(atPath: link)
        if destination != nil, BuiltInSkillCopy.linkIsOurs(destination: destination, linkPath: link, folder: paths.folder) || reachesCopy(link, name) {
            try? discard(link, trash: trash)
        }
        written[name] = nil
        return nil
    }

    /// SKILL.md's text: a regular file only, never through a link, 64 KB at most. A linked SKILL.md is someone's own
    /// arrangement, and the refresh's write would replace their link with a file.
    static func readSkill(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd: Int32 = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 * 1024 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count: Int = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if data.count > 64 * 1024 { return nil }
        }
        return String(data: data, encoding: .utf8)
    }

    /// The folder's entries other than SKILL.md (and Finder's .DS_Store): Remove leaves a folder holding them alone.
    static func extraFiles(_ name: String) -> [String] {
        let entries: [String] = (try? manager.contentsOfDirectory(atPath: paths(name).folder)) ?? []
        return entries.filter { $0 != "SKILL.md" && $0 != ".DS_Store" }.sorted()
    }

    private static func discard(_ path: String, trash: Bool) throws {
        if trash { try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } else { try manager.removeItem(atPath: path) }
    }

    private static func write(_ step: BuiltInSkillCopy.Step) throws {
        let paths = paths(step.skill.name)
        let made: Bool = !manager.fileExists(atPath: paths.folder)
        try manager.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
        do {
            try step.text.write(toFile: paths.file, atomically: true, encoding: .utf8)
        } catch {
            // The empty folder it made would count as someone else's and lock the copy for good.
            if made { try? manager.removeItem(atPath: paths.folder) }
            throw error
        }
        written[step.skill.name] = BuiltInSkillCopy.hash(step.text)
    }

    /// Claude Code reads ~/.claude/skills, not ~/.agents/skills: a relative link there, worked out from the folders' real
    /// paths (~/.claude or its skills folder can be a link into a dotfiles repository), only where Claude Code has its
    /// folder and nothing is at the link's place. A link that doesn't reach SKILL.md is taken away again.
    private static func linkForClaude(_ name: String) {
        let paths = paths(name)
        let claude: String = (home as NSString).appendingPathComponent(".claude")
        guard manager.fileExists(atPath: claude) else { return }
        let link: String = paths.claudeLink
        let taken: Bool = (try? manager.destinationOfSymbolicLink(atPath: link)) != nil || manager.fileExists(atPath: link)
        guard !taken else { return }
        try? manager.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? manager.createSymbolicLink(atPath: link, withDestinationPath: SkillChanges.linkTarget(at: link, to: paths.folder))
        if !manager.fileExists(atPath: (link as NSString).appendingPathComponent("SKILL.md")) { try? manager.removeItem(atPath: link) }
    }

    /// Whether Claude Code gets a copy, for Settings: through Next Term's link, or why not.
    static func claudeNote(_ name: String) -> String {
        let paths = paths(name)
        let link: String = paths.claudeLink
        let destination: String? = try? manager.destinationOfSymbolicLink(atPath: link)
        let reaches: Bool = manager.fileExists(atPath: (link as NSString).appendingPathComponent("SKILL.md"))
        if reaches, destination != nil, readSkill(paths.file) != nil,
           BuiltInSkillCopy.linkIsOurs(destination: destination, linkPath: link, folder: paths.folder) || reachesCopy(link, name) {
            return "Claude Code gets it through a link in ~/.claude/skills."
        }
        if !manager.fileExists(atPath: (home as NSString).appendingPathComponent(".claude")) {
            return "Claude Code isn\u{2019}t set up here (no ~/.claude), so it has no link."
        }
        if destination != nil || manager.fileExists(atPath: link) {
            return "Claude Code has no link: ~/.claude/skills/\(name) is something else, left as it is."
        }
        return "Claude Code has no link: it couldn\u{2019}t be made in ~/.claude/skills."
    }

    /// The link resolves to the copy's folder through real paths (a relative link from a linked ~/.claude).
    private static func reachesCopy(_ link: String, _ name: String) -> Bool {
        canonicalPath(link) == canonicalPath(paths(name).folder)
    }
}
