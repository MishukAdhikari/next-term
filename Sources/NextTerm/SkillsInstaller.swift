import AppKit
import NextTermCore

/// Installing skills from GitHub: one commit is fetched, every skill folder in it is checked against
/// the commit's tree hash, the developer reviews them, and the confirmed ones go in place in one change
/// that one Undo reverses (the lock file of `npx skills` and Next Term's record included).
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

        func discard() { try? FileManager.default.removeItem(at: scratch) }
    }

    static var downloads: URL { SkillsStore.supportFolder.appendingPathComponent("skill-downloads", isDirectory: true) }
    static var recordsFile: String { SkillsStore.supportFolder.appendingPathComponent("skills.json").path }

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
        var pinned = source
        if let commit { pinned.ref = commit }
        let found = try await SkillsGitHub.resolve(pinned)
        let resolved = SkillsGitHub.Resolved(source: source, commit: found.commit, date: found.date, skills: found.skills, truncated: found.truncated)
        guard !resolved.skills.isEmpty else {
            let place = source.path.isEmpty ? source.shortName : source.shortName + "/" + source.path
            throw SkillsGitHub.Failure(message: "No skill (a folder with SKILL.md) was found in \(place).")
        }
        async let info = SkillsGitHub.info(owner: source.owner, repo: source.repo)
        let home = SkillsStore.home
        async let lock = lockPath(home: home)
        let scratch = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let top = try await SkillsGitHub.download(owner: source.owner, repo: source.repo, commit: resolved.commit, into: scratch)
            let skills = resolved.skills
            let repo = source.repo
            let candidates = await Task.detached { check(skills, top: top.path, repo: repo) }.value
            return Fetched(resolved: resolved, info: await info, scratch: scratch, candidates: candidates, lockPath: await lock)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Hashes and reviews each downloaded skill folder.
    nonisolated static func check(_ skills: [SkillsGitHub.Found], top: String, repo: String) -> [Candidate] {
        var seen = Set<String>()
        return skills.map { found in
            let folder = found.path.isEmpty ? top : (top as NSString).appendingPathComponent(found.path)
            let upstream = found.path.isEmpty ? repo : (found.path as NSString).lastPathComponent
            let text = ["SKILL.md", "skill.md"].lazy.compactMap { try? String(contentsOfFile: (folder as NSString).appendingPathComponent($0), encoding: .utf8) }.first
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

    // MARK: installing

    static func records() -> [SkillRecord] { SkillRecord.decodeList(FileManager.default.contents(atPath: recordsFile)) }

    /// Whether the skill of that name already came from this source and path (the lock file or Next
    /// Term's record says so): installing it again is then an update.
    static func sameSource(_ candidate: Candidate, fetched: Fetched) -> Bool {
        let source = fetched.resolved.source
        if records().contains(where: { $0.name == candidate.name && $0.owner == source.owner && $0.repo == source.repo && $0.path == candidate.found.path }) {
            return true
        }
        guard case .success(let entries) = SkillLock.entries(at: fetched.lockPath), let entry = entries[candidate.name] else { return false }
        return entry.source.lowercased() == source.shortName.lowercased() && entry.skillPath == candidate.found.skillPath
    }

    /// Project folders open in Next Term: their skills are never touched, but a name they share is named.
    static var openProjects: [String] {
        guard SkillsStore.home == NSHomeDirectory() else { return [] }
        return NSApp.windows.compactMap { ($0.windowController as? TerminalWindowController)?.sidebar.root?.path }
    }

    static func plan(_ candidate: Candidate, fetched: Fetched, linkForClaude: Bool) -> SkillInstallPlan {
        SkillInstall.plan(name: candidate.name, staged: candidate.folder, inventory: SkillsStore.inventory(), linkForClaude: linkForClaude,
                          sameSource: sameSource(candidate, fetched: fetched), projects: openProjects)
    }

    /// Puts the chosen skills in place, with their lock entries and records, as one change for Undo.
    /// The download is removed afterwards either way.
    static func install(_ chosen: [Candidate], fetched: Fetched, linkForClaude: Bool) -> Result<String, SkillsStore.Failure> {
        defer { fetched.discard() }
        let source = fetched.resolved.source
        let now = Date()
        var steps: [SkillStep] = []
        var lockText = try? String(contentsOfFile: fetched.lockPath, encoding: .utf8)
        var lockWritable = true
        let lockEntries = (try? SkillLock.entries(at: fetched.lockPath).get()) ?? [:]
        var records = records()
        var notes: [String] = []
        for candidate in chosen {
            let plan = plan(candidate, fetched: fetched, linkForClaude: linkForClaude)
            steps += plan.steps
            let hash = candidate.found.path.isEmpty ? fetched.resolved.commit : candidate.found.tree
            let installedAt = plan.existing == .update ? (lockEntries[candidate.name]?.installedAt ?? now) : now
            let entry = SkillLock.Entry(source: source.shortName, sourceUrl: source.repositoryURL.absoluteString + ".git",
                                        skillPath: candidate.found.skillPath, skillFolderHash: hash, installedAt: installedAt, updatedAt: now)
            if lockWritable {
                switch SkillLock.updated(lockText, name: candidate.name, entry: entry) {
                case .success(let text): lockText = text
                case .failure:
                    lockWritable = false
                    notes.append("The lock file of npx skills is in a format Next Term does not know, so it was left alone.")
                }
            }
            records.removeAll { $0.name == candidate.name }
            records.append(SkillRecord(name: candidate.name, owner: source.owner, repo: source.repo, path: candidate.found.path,
                                       ref: source.ref, commit: fetched.resolved.commit, tree: candidate.found.tree,
                                       contentHash: SkillHash.folder(candidate.folder) ?? "", installedAt: now,
                                       linkedForClaude: plan.agents.contains(.claudeCode)))
        }
        if lockWritable, let lockText { steps.append(.write(path: fetched.lockPath, text: lockText)) }
        let recordsText = String(decoding: SkillRecord.encodeList(records.sorted { $0.name < $1.name }), as: UTF8.self) + "\n"
        steps.append(.write(path: recordsFile, text: recordsText))
        let title = chosen.count == 1 ? "Install \(chosen[0].name)" : "Install \(chosen.count) skills"
        switch SkillsStore.apply(steps, title: title) {
        case .success: return .success(notes.joined(separator: " "))
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: removing

    /// The steps that remove an installed skill (its shared copy, its Claude Code link, its lock entry
    /// and record), and what it asked for that outlives it.
    static func removal(_ name: String) async -> (steps: [SkillStep], leftovers: [String]) {
        let inventory = SkillsStore.inventory()
        var steps = SkillInstall.removal(name: name, inventory: inventory)
        let lock = await lockPath(home: SkillsStore.home)
        if case .success(let entries) = SkillLock.entries(at: lock), entries[name] != nil,
           case .success(let text) = SkillLock.updated(try? String(contentsOfFile: lock, encoding: .utf8), name: name, entry: nil) {
            steps.append(.write(path: lock, text: text))
        }
        var records = records()
        if records.contains(where: { $0.name == name }) {
            records.removeAll { $0.name == name }
            steps.append(.write(path: recordsFile, text: String(decoding: SkillRecord.encodeList(records), as: UTF8.self) + "\n"))
        }
        let front = inventory.rows.first { $0.name == name }?.copies.first { $0.root.kind == .shared }?.frontMatter
        return (steps, SkillInstall.leftovers(frontMatter: front))
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

    static func tracked() async -> [Tracked] {
        var result: [String: Tracked] = [:]
        let lock = await lockPath(home: SkillsStore.home)
        if case .success(let entries) = SkillLock.entries(at: lock) {
            for (name, entry) in entries {
                let parts = entry.source.split(separator: "/").map(String.init)
                guard parts.count == 2 else { continue }
                let path = entry.skillPath == "SKILL.md" ? "" : (entry.skillPath as NSString).deletingLastPathComponent
                result[name] = Tracked(name: name, source: SkillSource(owner: parts[0], repo: parts[1]), path: path, hash: entry.skillFolderHash)
            }
        }
        for record in records() {
            result[record.name] = Tracked(name: record.name, source: SkillSource(owner: record.owner, repo: record.repo, ref: record.ref),
                                          path: record.path, hash: record.path.isEmpty ? record.commit : record.tree)
        }
        return result.values.sorted { $0.name < $1.name }
    }

    /// The last check's answers, by skill name (shown in Settings › Skills).
    static var updates: [String: UpdateState] = [:]
    static var lastCheck: Date? { UserDefaults.standard.object(forKey: "SkillsLastUpdateCheck") as? Date }
    static let updatesChanged = Notification.Name("NextTermSkillUpdatesChanged")

    /// Asks GitHub for the current commit of each source (one repository at a time, two requests each).
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

    /// What changed between the installed copy and the downloaded one, as `diff -ruN` prints it.
    nonisolated static func changes(installed: String, downloaded: String) -> String {
        let diff = Process()
        diff.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        diff.arguments = ["-ruN", "--exclude=.DS_Store", "--exclude=__pycache__", "--exclude=.git", installed, downloaded]
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
