import AppKit
import NextTermCore

/// Installing skills from GitHub: one commit is fetched, every skill folder in it is checked against
/// the commit's tree hash, the developer reviews them, and the confirmed ones go in place in one change
/// that one Undo reverses (their entries in the lock file of `npx skills` and Next Term's record too).
@MainActor
enum SkillsInstaller {
    /// One skill found at the fetched commit: downloaded and reviewed, not installed.
    struct Candidate: Sendable {
        let found: SkillsGitHub.Found
        /// The downloaded folder, in Next Term's own downloads folder.
        let folder: String
        /// The name it installs under: its `name` field (the folder's name when there is none).
        let name: String
        let review: SkillReview
        /// Why it can't be installed whatever the review says: files that differ from the commit, or a
        /// name another skill in the same source also has.
        let refusal: String?
        let notes: [String]
        var installable: Bool { refusal == nil && !review.refused }
    }

    struct Fetched: Sendable {
        let resolved: SkillsGitHub.Resolved
        let info: SkillsGitHub.RepoInfo?
        let scratch: URL
        let candidates: [Candidate]
        /// Where the lock file of `npx skills` is for this user.
        let lockPath: String
        /// The personal skills when this was fetched (read off the main thread): what the sheet plans with.
        let inventory: SkillInventory
        /// Skills of these names were changed on disk since they were installed (an update replaces that).
        let editedSinceInstall: Set<String>
        /// Projects open when this was fetched.
        let projects: [String]

        func discard() { try? FileManager.default.removeItem(at: scratch) }

        /// The same review, planned against the skill folders as they are now.
        func with(inventory: SkillInventory) -> Fetched {
            Fetched(resolved: resolved, info: info, scratch: scratch, candidates: candidates, lockPath: lockPath, inventory: inventory,
                    editedSinceInstall: editedSinceInstall, projects: projects)
        }
    }

    static var downloads: URL { SkillsStore.supportFolder.appendingPathComponent("skill-downloads", isDirectory: true) }
    static var recordsFile: String { SkillsStore.supportFolder.appendingPathComponent("skills.json").path }
    /// Downloads a review still uses; any other folder in `downloads` is left over (from before a quit).
    private static var liveDownloads = Set<String>()

    /// The lock file's place: XDG_STATE_HOME from the login shell moves it (read off the main thread,
    /// the probe can take a few seconds).
    nonisolated static func lockPath(home: String) async -> String {
        guard home == NSHomeDirectory() else { return SkillLock.path(home: home, environment: [:]) }
        let state = await Task.detached { LoginShell.xdgStateHome }.value
        return SkillLock.path(home: home, environment: state.map { ["XDG_STATE_HOME": $0] } ?? [:])
    }

    // MARK: fetching

    /// Resolves the source to one commit, downloads it, and reviews every skill in it (under the
    /// source's path). Nothing is installed; `discard()` removes the download. `commit` fetches that
    /// commit (a Featured skill's reviewed one) while updates keep following `source`.
    static func fetch(_ source: SkillSource, at commit: String? = nil) async throws -> Fetched {
        removeLeftoverDownloads()
        var pinned = source
        if let commit { pinned.ref = commit }
        let found = try await SkillsGitHub.resolve(pinned)
        var resolved = SkillsGitHub.Resolved(source: source, commit: found.commit, date: found.date, skills: found.skills, truncated: found.truncated)
        resolved.namedRef = commit == nil && found.namedRef
        guard !resolved.skills.isEmpty else {
            let place = source.path.isEmpty ? source.shortName : source.shortName + "/" + source.path
            throw SkillsGitHub.Failure(message: "No skill (a folder with SKILL.md) was found in \(place).")
        }
        async let info = SkillsGitHub.info(owner: source.owner, repo: source.repo)
        let home = SkillsStore.home
        async let lock = lockPath(home: home)
        let scratch = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        liveDownloads.insert(scratch.path)
        do {
            let top = try await SkillsGitHub.download(owner: source.owner, repo: source.repo, commit: resolved.commit,
                                                       paths: resolved.skills.map(\.path), into: scratch)
            let skills = resolved.skills
            let repo = source.repo
            let candidates = await Task.detached { check(skills, top: top.path, repo: repo) }.value
            let inventory = await SkillsStore.scan()
            let lockPath = await lock
            let records = records()
            let names = candidates.map(\.name)
            let edited = await editedSinceInstall(names, inventory: inventory, lockPath: lockPath, records: records)
            return Fetched(resolved: resolved, info: await info, scratch: scratch, candidates: candidates, lockPath: lockPath,
                           inventory: inventory, editedSinceInstall: edited, projects: openProjects)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// No review survives a quit: downloads no open review uses are removed.
    private static func removeLeftoverDownloads() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: downloads.path)) ?? [] {
            let path = downloads.appendingPathComponent(name).path
            guard !liveDownloads.contains(path) else { continue }
            try? manager.removeItem(atPath: path)
        }
        liveDownloads = liveDownloads.filter { manager.fileExists(atPath: $0) }
    }

    /// Hashes and reviews each downloaded skill folder.
    nonisolated static func check(_ skills: [SkillsGitHub.Found], top: String, repo: String) -> [Candidate] {
        var seen = Set<String>()
        return skills.map { found in
            let folder = found.path.isEmpty ? top : (top as NSString).appendingPathComponent(found.path)
            let upstream = found.path.isEmpty ? repo : (found.path as NSString).lastPathComponent
            let text = ["SKILL.md", "skill.md"].lazy.compactMap { FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent($0)) }.first
                .map { String(decoding: $0, as: UTF8.self) }
            let declared = text.flatMap(SkillFrontMatter.parse)?.name?.trimmingCharacters(in: .whitespaces)
            let name = declared.flatMap { $0.isEmpty ? nil : $0 } ?? upstream
            var refusal: String?
            if GitHash.folder(folder) != found.tree {
                refusal = "The downloaded files differ from the commit's. Some repositories leave files out of downloads; Next Term installs only files it can check against the commit."
            } else if !seen.insert(name).inserted {
                refusal = "Another skill in this source is also named “\(name)”."
            }
            var notes: [String] = []
            if name != upstream { notes.append("Installs as “\(name)”, its name; the repository's folder is “\(upstream)”.") }
            return Candidate(found: found, folder: folder, name: name, review: SkillReview.review(folder: folder, folderName: name),
                             refusal: refusal, notes: notes)
        }
    }

    /// Installed skills of these names whose files differ from what was installed. For Next Term's own
    /// installs, the installed copy's tree hash (without caches Python writes when it runs) against the
    /// recorded tree. For `npx skills` installs, file by file against the tree GitHub lists for the
    /// recorded hash, leaving out what the CLI doesn't copy. Anything that can't be told is not a warning.
    nonisolated static func editedSinceInstall(_ names: [String], inventory: SkillInventory, lockPath: String, records: [SkillRecord]) async -> Set<String> {
        let lock = (try? SkillLock.entries(at: lockPath).get()) ?? [:]
        var edited = Set<String>()
        for name in names {
            guard let shared = inventory.rows.first(where: { $0.name == name })?.copies.first(where: { $0.root.kind == .shared && !$0.broken }) else { continue }
            if let record = records.first(where: { $0.name == name }) {
                let expected = record.contentHash.isEmpty ? record.tree : record.contentHash
                if SkillEdits.installedHash(shared.realPath) != expected { edited.insert(name) }
                continue
            }
            guard let entry = lock[name], entry.sourceType == nil || entry.sourceType == "github" else { continue }
            let parts = entry.source.split(separator: "/").map(String.init)
            guard parts.count == 2, let blobs = await SkillsGitHub.treeBlobs(owner: parts[0], repo: parts[1], tree: entry.skillFolderHash) else { continue }
            if SkillEdits.differs(shared.realPath, from: blobs) == true { edited.insert(name) }
        }
        return edited
    }

    // MARK: installing

    static func records() -> [SkillRecord] { SkillRecord.decodeList(FileManager.default.contents(atPath: recordsFile)) }

    /// Whether the skill of that name already came from this source and path (the lock file or Next
    /// Term's record says so): installing it again is then an update.
    static func sameSource(_ candidate: Candidate, fetched: Fetched) -> Bool {
        let source = fetched.resolved.source
        if records().contains(where: { $0.name == candidate.name && $0.owner.lowercased() == source.owner.lowercased()
            && $0.repo.lowercased() == source.repo.lowercased() && $0.path == candidate.found.path }) {
            return true
        }
        guard case .success(let entries) = SkillLock.entries(at: fetched.lockPath), let entry = entries[candidate.name],
              entry.sourceType == nil || entry.sourceType == "github" else { return false }
        return entry.source.lowercased() == source.shortName.lowercased() && entry.skillPath == candidate.found.skillPath
    }

    /// Project folders open in Next Term: their skills are never touched, but a name they share is named.
    static var openProjects: [String] {
        guard SkillsStore.home == NSHomeDirectory() else { return [] }
        return NSApp.windows.compactMap { ($0.windowController as? TerminalWindowController)?.sidebar.root?.path }
    }

    static func plan(_ candidate: Candidate, fetched: Fetched, linkForClaude: Bool, inventory: SkillInventory? = nil) -> SkillInstallPlan {
        SkillInstall.plan(name: candidate.name, staged: candidate.folder, inventory: inventory ?? fetched.inventory, linkForClaude: linkForClaude,
                          sameSource: sameSource(candidate, fetched: fetched), projects: fetched.projects)
    }

    /// Puts the chosen skills in place, with their lock entries and records, as one change for Undo.
    /// It installs only what the review showed: if the skill folders changed since, nothing happens and
    /// the review is redrawn. The downloaded files are checked against the commit right before they are
    /// copied, and the installed copy again after. The download is removed once installed; after a
    /// failure it stays, so Install can be tried again.
    static func install(_ chosen: [Candidate], fetched: Fetched, linkForClaude: Bool) async -> Result<String, SkillsStore.Failure> {
        let inventory = await SkillsStore.scan()
        for candidate in chosen {
            let shown = plan(candidate, fetched: fetched, linkForClaude: linkForClaude)
            let now = plan(candidate, fetched: fetched, linkForClaude: linkForClaude, inventory: inventory)
            guard shown.steps == now.steps, shown.existing == now.existing else {
                return .failure(SkillsStore.Failure(message: "Your skill folders changed since the review (\(candidate.name)). Nothing was installed; look at the review again."))
            }
        }
        let source = fetched.resolved.source
        let date = Date()
        var steps: [SkillStep] = []
        var notes: [String] = []
        var lockKnown = true
        if SkillLock.isDanglingLink(fetched.lockPath) {
            lockKnown = false
            notes.append("The lock file of npx skills is a link to a missing file, so it was left alone.")
        } else if case .failure = SkillLock.entries(at: fetched.lockPath) {
            lockKnown = false
            notes.append("The lock file of npx skills is in a format Next Term does not know, so it was left alone.")
        }
        for candidate in chosen {
            let plan = plan(candidate, fetched: fetched, linkForClaude: linkForClaude, inventory: inventory)
            steps += plan.steps
            if lockKnown {
                let hash = candidate.found.path.isEmpty ? fetched.resolved.commit : candidate.found.tree
                // An update keeps the date it was first installed (nil keeps what the file has).
                let entry = SkillLock.Entry(source: source.shortName, sourceUrl: source.repositoryURL.absoluteString + ".git",
                                            skillPath: candidate.found.skillPath, skillFolderHash: hash,
                                            ref: fetched.resolved.namedRef ? source.ref : nil,
                                            installedAt: plan.existing == .update ? nil : date, updatedAt: date)
                steps.append(.lockEntry(path: fetched.lockPath, name: candidate.name, entry: entry))
            }
            let record = SkillRecord(name: candidate.name, owner: source.owner, repo: source.repo, path: candidate.found.path,
                                     ref: fetched.resolved.namedRef ? source.ref : nil, commit: fetched.resolved.commit, tree: candidate.found.tree,
                                     contentHash: candidate.found.tree, installedAt: date, linkedForClaude: plan.agents.contains(.claudeCode))
            steps.append(.recordEntry(path: recordsFile, name: candidate.name, record: record))
        }
        // The files sat on disk during the review: checked against the commit right before copying.
        let folders = chosen.map { ($0.folder, $0.found.tree) }
        let intact = await Task.detached { folders.allSatisfy { GitHash.folder($0.0) == $0.1 } }.value
        guard intact else {
            fetched.discard()
            return .failure(SkillsStore.Failure(message: "The downloaded files changed after the review. Nothing was installed; fetch it again to review it."))
        }
        let title = chosen.count == 1 ? "Install \(chosen[0].name)" : "Install \(chosen.count) skills"
        if case .failure(let failure) = await SkillsStore.apply(steps, title: title) { return .failure(failure) }
        // And what was written is what was reviewed.
        let sharedRoot = (SkillsStore.home as NSString).appendingPathComponent(".agents/skills")
        let written = chosen.map { ((sharedRoot as NSString).appendingPathComponent($0.name), $0.found.tree) }
        let same = await Task.detached { written.allSatisfy { GitHash.folder($0.0) == $0.1 } }.value
        guard same else {
            _ = await SkillsStore.undo()
            return .failure(SkillsStore.Failure(message: "The installed files did not match the reviewed commit, so the install was undone."))
        }
        fetched.discard()
        return .success(notes.joined(separator: " "))
    }

    // MARK: removing

    /// Whether Next Term or `npx skills` installed a skill of that name (its record or lock entry), as
    /// far as can be told without waiting for the login shell.
    static func tracksInstall(_ name: String) -> Bool {
        if records().contains(where: { $0.name == name }) { return true }
        let state = SkillsStore.home == NSHomeDirectory() && LoginShell.isProbed ? LoginShell.xdgStateHome : nil
        let lock = SkillLock.path(home: SkillsStore.home, environment: state.map { ["XDG_STATE_HOME": $0] } ?? [:])
        return (try? SkillLock.entries(at: lock).get())?[name] != nil
    }

    /// The steps that remove a skill (its shared copy, every agent folder's link to it, its lock entry
    /// and record), what it asked for that outlives it, and whether it was installed (by Next Term or
    /// `npx skills`) rather than made by hand. Worked out from the disk as it is now: call it again when
    /// the user confirms, so nothing planned earlier overwrites what changed meanwhile.
    static func removal(_ name: String) async -> (steps: [SkillStep], leftovers: [String], installed: Bool) {
        let inventory = await SkillsStore.scan()
        var steps = SkillInstall.removal(name: name, inventory: inventory)
        let lock = await lockPath(home: SkillsStore.home)
        var installed = false
        if case .success(let entries) = SkillLock.entries(at: lock), entries[name] != nil {
            steps.append(.lockEntry(path: lock, name: name, entry: nil))
            installed = true
        }
        if records().contains(where: { $0.name == name }) {
            steps.append(.recordEntry(path: recordsFile, name: name, record: nil))
            installed = true
        }
        let front = inventory.rows.first { $0.name == name }?.copies.first { $0.root.kind == .shared }?.frontMatter
        return (steps, SkillInstall.leftovers(frontMatter: front), installed)
    }

    // MARK: updates

    enum UpdateState: Equatable, Sendable {
        case current
        case available(commit: String)
        /// The repository or the skill's folder is gone, or GitHub refused.
        case unknown(String)
    }

    /// One installed skill whose source is known: from Next Term's record, or the lock file of `npx skills`.
    struct Tracked: Sendable {
        let name: String
        let source: SkillSource
        /// The folder in the repository, and the hash recorded for it (tree, or commit for a root skill).
        let path: String
        let hash: String
    }

    /// Installed skills with a GitHub source. Entries are checked before use: a lock entry from another
    /// kind of source (a local folder, another git host) or with names GitHub can't hold is left out.
    static func tracked() async -> [Tracked] {
        var result: [String: Tracked] = [:]
        let lock = await lockPath(home: SkillsStore.home)
        if case .success(let entries) = SkillLock.entries(at: lock) {
            for (name, entry) in entries where entry.sourceType == nil || entry.sourceType == "github" {
                let parts = entry.source.split(separator: "/").map(String.init)
                guard parts.count == 2 else { continue }
                let path = entry.skillPath == "SKILL.md" ? "" : (entry.skillPath as NSString).deletingLastPathComponent
                let source = SkillSource(owner: parts[0], repo: parts[1], ref: entry.ref, path: path)
                guard source.isValid else { continue }
                result[name] = Tracked(name: name, source: source, path: path, hash: entry.skillFolderHash)
            }
        }
        for record in records() where record.source.isValid {
            result[record.name] = Tracked(name: record.name, source: record.source, path: record.path,
                                          hash: record.path.isEmpty ? record.commit : record.tree)
        }
        return result.values.sorted { $0.name < $1.name }
    }

    /// The last check's answers, by skill name (shown in Settings › Skills).
    static var updates: [String: UpdateState] = [:]
    static var lastCheck: Date? { UserDefaults.standard.object(forKey: "SkillsLastUpdateCheck") as? Date }
    static let updatesChanged = Notification.Name("NextTermSkillUpdatesChanged")

    /// Asks GitHub for the current commit of each source (one repository and branch at a time).
    static func checkForUpdates() async {
        var answers: [String: UpdateState] = [:]
        let all = await tracked()
        let groups = Dictionary(grouping: all) { "\($0.source.owner)/\($0.source.repo)@\($0.source.ref ?? "")".lowercased() }
        for (_, group) in groups {
            let first = group[0].source
            do {
                let resolved = try await SkillsGitHub.resolve(SkillSource(owner: first.owner, repo: first.repo, ref: first.ref))
                for item in group {
                    guard let found = resolved.skills.first(where: { $0.path == item.path }) else {
                        answers[item.name] = .unknown("Its folder is no longer in \(first.shortName).")
                        continue
                    }
                    let now = item.path.isEmpty ? resolved.commit : found.tree
                    answers[item.name] = now == item.hash ? .current : .available(commit: resolved.commit)
                }
            } catch {
                let message = (error as? SkillsGitHub.Failure)?.message ?? error.localizedDescription
                for item in group { answers[item.name] = .unknown(message) }
            }
        }
        updates = answers
        UserDefaults.standard.set(Date(), forKey: "SkillsLastUpdateCheck")
        NotificationCenter.default.post(name: updatesChanged, object: nil)
    }

    /// What changed between the installed copy and the downloaded one, as `diff -ruN` prints it. Caches
    /// are not left out: a fresh download holds only what its author committed.
    nonisolated static func changes(installed: String, downloaded: String) -> String {
        let diff = Process()
        diff.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        diff.arguments = ["-ruN", "--exclude=.DS_Store", "--exclude=.git", installed, downloaded]
        let out = Pipe()
        diff.standardOutput = out
        diff.standardError = FileHandle.nullDevice
        guard (try? diff.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        diff.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: installed, with: "installed")
            .replacingOccurrences(of: downloaded, with: "new")
    }
}
