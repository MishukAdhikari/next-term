import AppKit
import NextTermCore

/// Settings › Skills › Update automatically: after the day's update check (SkillsUpdateCheck, once every 24 hours), each
/// skill with an update installs it by itself, through the same fetch, commit check and install as Update…, when
/// SkillAutoUpdate allows it unattended. An update that adds something that runs, changes its servers or plugin, brings
/// a new warning, or would replace your own changes waits for your review, as before, and says why. Each install is a
/// change Settings › Skills' Undo takes back. Off by default: turning it on is the user's choice.
@MainActor
enum SkillsAutoUpdate {
    static let key = "SkillsAutoUpdate"
    private static let lastRunKey = "SkillsAutoUpdateLastRun"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Why each update not installed by itself waits for a review, by skill name (shown in Settings › Skills).
    private(set) static var held: [String: String] = [:]
    /// Skills updated by themselves, and when: the summary says so for a day.
    private(set) static var lastRun: (date: Date, updated: [String])? = {
        guard let saved = UserDefaults.standard.dictionary(forKey: lastRunKey), let date = saved["date"] as? Date,
              let names = saved["updated"] as? [String] else { return nil }
        return (date, names)
    }()
    private static var running = false
    /// The self-test's commit, in place of GitHub's; it also lets the run work in the self-test's home.
    static var fetchForTest: ((SkillSource) async throws -> SkillsInstaller.Fetched)?

    /// The summary's words for the last day's updates: "3 updated automatically"; nil for none.
    static var summary: String? {
        guard let lastRun, !lastRun.updated.isEmpty, Date().timeIntervalSince(lastRun.date) < 24 * 60 * 60 else { return nil }
        return "\(lastRun.updated.count) updated automatically"
    }

    /// Installs each available update that may go unattended. Nothing while off, while another change or a review is
    /// open (it waits for the next look), or in someone else's home.
    static func run() async {
        guard isOn, !running, fetchForTest != nil || SkillsStore.home == NSHomeDirectory(), SkillsStore.running == 0,
              !SkillsReviewSheet.open.values.contains(where: { $0.window?.isVisible == true }) else { return }
        let waiting = SkillsInstaller.updates.compactMap { name, state -> String? in
            if case .available = state { return name } else { return nil }
        }.sorted()
        guard !waiting.isEmpty else { return }
        running = true
        defer { running = false }
        let tracked = await SkillsInstaller.tracked()
        var updated: [String] = []
        for name in waiting {
            guard isOn, let item = tracked.first(where: { $0.name == name }) else { continue }
            guard let reason = await update(item) else {
                updated.append(name)
                held[name] = nil
                continue
            }
            held[name] = reason
        }
        if !updated.isEmpty {
            lastRun = (Date(), updated)
            UserDefaults.standard.set(["date": Date(), "updated": updated], forKey: lastRunKey)
        }
        NotificationCenter.default.post(name: SkillsInstaller.updatesChanged, object: nil)
    }

    /// One skill: nil once installed, else why it waits.
    private static func update(_ item: SkillsInstaller.Tracked) async -> String? {
        let fetched: SkillsInstaller.Fetched
        do {
            let source = SkillSource(owner: item.source.owner, repo: item.source.repo, ref: item.source.ref, path: item.path)
            if let fetchForTest { fetched = try await fetchForTest(source) } else { fetched = try await SkillsInstaller.fetch(source) }
        } catch {
            return (error as? SkillsGitHub.Failure)?.message ?? error.localizedDescription
        }
        guard let candidate = fetched.candidates.first(where: { $0.name == item.name }) ?? (fetched.candidates.count == 1 ? fetched.candidates.first : nil),
              candidate.name == item.name else {
            fetched.discard()
            return "Its source no longer holds it under this name."
        }
        if let refusal = candidate.refusal {
            fetched.discard()
            return refusal
        }
        let installedPath = fetched.inventory.rows.first { $0.name == item.name }?.copies.first { $0.root.kind == .shared && !$0.broken }?.realPath
        let installed = installedPath.map { SkillReview.review(folder: $0, folderName: item.name) }
        if let reason = SkillAutoUpdate.hold(installed: installed, update: candidate.review, edited: fetched.editedSinceInstall.contains(item.name)) {
            fetched.discard()
            return reason
        }
        switch await SkillsInstaller.install([candidate], fetched: fetched) {
        case .success:
            SkillsInstaller.updates[item.name] = .current
            return nil
        case .failure(let failure):
            fetched.discard()
            return failure.message
        }
    }
}
