import AppKit
import CryptoKit
import NextTermCore

/// Updates from GitHub Releases: checks once a day (and on demand). A new version opens the
/// update window with its release notes (Skip This Version, Remind Me Later, Install and Relaunch), and
/// a blue Update button stays at the top right of each window until it is installed or skipped. One
/// click downloads the new DMG, checks it as the installer (site/src/install.sh) does (the release's
/// SHA-256 signed with the Next Term release key, and the download matching it), puts the new app in
/// place of this one when Next Term quits, and starts it again.
///
/// Only the latest-release endpoint is contacted, with no identifying data beyond the version in the
/// User-Agent. Downloads are accepted only over https from GitHub.
@MainActor
final class Updater {
    static let shared = Updater()
    // Constants, read from URLSession's callbacks too: not tied to the main actor.
    nonisolated static let repository = "MishukAdhikari/next-term"
    nonisolated static let feed = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Redirects to the newest release's page; used when the API is rate-limited.
    nonisolated static let latestPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60
    /// Remind Me Later: how long before the automatic check opens the window for that version again.
    static let snooze: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var checking = false
    private var progress: UpdateProgressWindow?
    /// A new app staged next to this one, swapped in when Next Term quits.
    private var staged: (newApp: URL, version: AppVersion)? { didSet { changed() } }
    /// A newer version a check found, until it is installed: the Update button offers it.
    private(set) var available: ReleaseInfo? { didSet { changed() } }
    /// The releases whose notes the window shows for `available`, newest first.
    private var availableNotes: [ReleaseInfo] = []
    /// The version `available` was compared with (this app's, or a test's).
    private var offeredTo: AppVersion?
    private var downloading = false { didSet { changed() } }
    private(set) var prompt: UpdateWindowController?

    /// What the Update button at the top right of each window says, if anything.
    enum Badge: Equatable { case update(AppVersion), relaunch(AppVersion) }
    var badge: Badge? {
        if let staged { return .relaunch(staged.version) }
        guard !downloading, let available, available.tag != skippedTag else { return nil }
        return .update(available.version)
    }

    private var skippedTag: String? { UserDefaults.standard.string(forKey: "skippedVersion") }

    /// Remind Me Later: the automatic check stays quiet about this version until the time is up.
    private func snoozed(_ release: ReleaseInfo) -> Bool {
        UserDefaults.standard.string(forKey: "updateRemindTag") == release.tag
            && Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: "updateRemindAfter")
    }

    private func changed() {
        AppDelegate.shared.controllers.forEach { $0.updateUpdateButton() }
    }

    var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }

    /// For testing the whole flow against a local feed (`-updateFeedURL file:///…/feed.json`). The release's
    /// files must still be signed with the release key, e.g. a real release's DMG, .sha256 and .sig.
    private var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) ?? Self.feed
    }

    private var testing: Bool { UserDefaults.standard.string(forKey: "updateFeedURL") != nil }

    /// The recent releases, for the notes of every version since this one (`-updateReleasesURL` in tests;
    /// none when only the feed is overridden).
    private var releasesURL: URL? {
        if let url = UserDefaults.standard.string(forKey: "updateReleasesURL").flatMap(URL.init(string:)) { return url }
        return testing ? nil : URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=10")
    }

    /// Starts the daily check (a development build, with no version, never checks).
    func start() {
        guard current != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A little after launch, so it never slows the first window.
        DispatchQueue.main.asyncAfter(deadline: .now() + (testing ? 1 : 20)) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard testing || Date().timeIntervalSince1970 - last > Self.interval else { return }
        check(userInitiated: false)
    }

    /// "Check for Updates…": says so either way. The daily check speaks only when there is something new.
    func check(userInitiated: Bool) {
        guard !checking else { return }
        guard let current else {
            if userInitiated { tell("This is a development build", "Updates are for the released app.") }
            return
        }
        checking = true
        var request = URLRequest(url: feedURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NextTerm/\(current)", forHTTPHeaderField: "User-Agent")
        let allowFiles = testing
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? (data != nil ? 200 : 0)
            let release = status == 200 ? data.flatMap { ReleaseInfo.parse($0, allowingFileURLs: allowFiles) } : nil
            let finish = { (release: ReleaseInfo?, failed: Bool) in
                DispatchQueue.main.async {
                    self.checking = false
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                    self.handle(release, current: current, userInitiated: userInitiated, failed: failed)
                }
            }
            guard status == 403 || status == 429, !allowFiles else { return finish(release, release == nil && status != 404) }
            // Rate-limited: the releases page names the newest tag by redirecting to it.
            var page = URLRequest(url: Self.latestPage, timeoutInterval: 15)
            page.httpMethod = "HEAD"
            URLSession.shared.dataTask(with: page) { _, response, _ in
                let final = (response as? HTTPURLResponse)?.url
                let fallback = final.flatMap { ReleaseInfo.fromLatestRedirect($0, repository: Self.repository) }
                finish(fallback, fallback == nil)
            }.resume()
        }.resume()
    }

    private func handle(_ release: ReleaseInfo?, current: AppVersion, userInitiated: Bool, failed: Bool) {
        guard let release, current < release.version else {
            if !failed { available = nil } // withdrawn, or this is the newest
            if userInitiated {
                failed ? tell("Could not check for updates", "GitHub did not answer. Try again later.")
                    : tell("Next Term is up to date", "Version \(current) is the newest.")
            }
            return
        }
        if staged?.version == release.version {
            if userInitiated { relaunchPrompt(release.version) }
            return
        }
        if testing, UserDefaults.standard.bool(forKey: "updateInstallWithoutAsking") {
            available = release
            return download(release)
        }
        offer(release, current: current, userInitiated: userInitiated)
    }

    /// Makes `release` the available update and, unless the automatic check should stay quiet about it
    /// (skipped, or Remind Me Later not yet up), opens the window. `notes` given: shown as they are.
    func offer(_ release: ReleaseInfo, current: AppVersion, userInitiated: Bool, notes: [ReleaseInfo]? = nil) {
        if available?.tag != release.tag { availableNotes = [] }
        offeredTo = current
        available = release
        if !userInitiated, release.tag == skippedTag || snoozed(release) { return }
        if let notes {
            availableNotes = notes
            return showWindow(takingFocus: userInitiated)
        }
        fetchNotes(for: release, current: current) { [weak self] notes in
            guard let self, self.available?.tag == release.tag else { return }
            self.availableNotes = notes
            self.showWindow(takingFocus: userInitiated)
        }
    }

    /// Forgets the available update (a test's, or one that was withdrawn), and stops waiting for its signature.
    func withdraw() {
        awaitingSignature?.timer.invalidate()
        awaitingSignature = nil
        prompt?.dismiss()
        prompt = nil
        availableNotes = []
        available = nil
    }

    /// The Update button: the window again (or, with an update ready, the offer to relaunch).
    func showAvailable() {
        if let staged { return relaunchPrompt(staged.version) }
        guard let available, let current = offeredTo else { return check(userInitiated: true) }
        if availableNotes.isEmpty {
            offer(available, current: current, userInitiated: true)
        } else {
            showWindow(takingFocus: true)
        }
    }

    private func showWindow(takingFocus: Bool) {
        guard let release = available, let current = offeredTo else { return }
        if let prompt, prompt.release.tag == release.tag {
            return prompt.present(over: prompt.window?.parent ?? Self.frontWindow, takingFocus: takingFocus)
        }
        prompt?.dismiss()
        let canInstall = release.dmgURL != nil && release.checksumURL != nil
        let controller = UpdateWindowController(release: release, notes: availableNotes.isEmpty ? [release] : availableNotes,
                                                current: current, canInstall: canInstall) { [weak self] choice in
            self?.answered(choice, for: release, canInstall: canInstall)
        }
        prompt = controller
        controller.present(over: Self.frontWindow, takingFocus: takingFocus)
    }

    private static var frontWindow: NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow] + NSApp.orderedWindows
        return candidates.compactMap { $0 }.first { window in
            window.isVisible && !window.isMiniaturized && (window is TerminalWindow || window === AppDelegate.shared.welcomeController?.window)
        }
    }

    private func answered(_ choice: UpdateWindowController.Choice, for release: ReleaseInfo, canInstall: Bool) {
        prompt = nil
        switch choice {
        case .install:
            UserDefaults.standard.removeObject(forKey: "updateRemindTag")
            if canInstall { download(release) } else { NSWorkspace.shared.open(release.pageURL) }
        case .later:
            UserDefaults.standard.set(release.tag, forKey: "updateRemindTag")
            UserDefaults.standard.set(Date().timeIntervalSince1970 + Self.snooze, forKey: "updateRemindAfter")
        case .skip:
            UserDefaults.standard.set(release.tag, forKey: "skippedVersion")
            changed()
        }
    }

    /// The notes of every release since `current` (at most five); the latest's alone if GitHub does not answer.
    private func fetchNotes(for release: ReleaseInfo, current: AppVersion, then show: @escaping ([ReleaseInfo]) -> Void) {
        guard let url = releasesURL else { return show([release]) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NextTerm/\(current)", forHTTPHeaderField: "User-Agent")
        let allowFiles = testing
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? (data != nil ? 200 : 0)
            let list = status == 200 ? data.map { ReleaseInfo.parseList($0, allowingFileURLs: allowFiles) } ?? [] : []
            DispatchQueue.main.async { show(ReleaseInfo.since(current, latest: release, among: list)) }
        }.resume()
    }

    // MARK: download, verify, stage

    /// A release whose checksum is not signed yet (each is signed a few minutes after it is published):
    /// the install that was asked for is tried again, quietly, every `signatureRetry` for as long as
    /// `SignatureWait` says.
    private(set) var awaitingSignature: (tag: String, since: Date, timer: Timer)?
    static let signatureRetry: TimeInterval = 10 * 60
    /// A download, or the signature check before it, is under way.
    private(set) var installing = false

    /// `quietly`: a retry of an install asked for earlier (maybe hours ago), which opens nothing until it
    /// is done or fails: no progress window, and no offer to relaunch, only the Update button reading
    /// Relaunch to Update. Whatever is being typed stays where it is.
    func download(_ release: ReleaseInfo, quietly: Bool = false) {
        guard let dmgURL = release.dmgURL, release.checksumURL != nil, !installing else { return }
        let waitingSince = awaitingSignature?.tag == release.tag ? awaitingSignature?.since : nil
        awaitingSignature?.timer.invalidate()
        awaitingSignature = nil
        installing = true
        if !quietly { showProgress(release) }
        Task {
            var signed = false
            do {
                // The checksum and its signature first: nothing big is downloaded for a release that is not signed yet.
                guard let expected = try await ReleaseSignature.signedChecksum(of: release) else {
                    installing = false
                    hideProgress()
                    return waitForSignature(release, since: waitingSince ?? Date(), quietly: quietly)
                }
                signed = true
                if quietly { downloading = true } // the Update button hides, as it does under the progress window
                let dmg = try await fetch(dmgURL)
                progress?.message = "Checking the download…"
                let actual = try await Task.detached { try Self.sha256(of: dmg) }.value
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: dmg)
                    throw ReleaseSignature.Refusal.mismatch
                }
                progress?.message = "Preparing…"
                let version = release.version
                let app = try await Task.detached { try Self.stage(dmg: dmg, version: version) }.value
                staged = (app, release.version)
                installing = false
                hideProgress()
                if !quietly { relaunchPrompt(release.version) }
            } catch {
                let beforeDownload = quietly && !signed
                installing = false
                hideProgress()
                if let refusal = error as? ReleaseSignature.Refusal { return refuse(release, Self.text(of: refusal)) }
                // A quiet try that could not reach GitHub: the next one may.
                if beforeDownload { return waitForSignature(release, since: waitingSince ?? Date(), quietly: true, unreachable: true) }
                var message = (error as? UpdateError)?.text ?? error.localizedDescription
                if let failure = error as? ReleaseSignature.Unavailable { message = "GitHub did not answer (HTTP \(failure.status))." }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Next Term \(release.version) was not installed"
                alert.informativeText = message + "\n\nYou can download it from the release page instead."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
            }
        }
    }

    private func showProgress(_ release: ReleaseInfo) {
        downloading = true
        progress = UpdateProgressWindow(title: "Downloading Next Term \(release.version)…")
        progress?.show()
    }

    private func hideProgress() {
        downloading = false
        progress?.close()
        progress = nil
    }

    /// No signature yet. One published in the last day is about to be signed: say so (once) and try
    /// again every 10 minutes without a word, for two hours. One published before that is refused.
    /// Each try fetches only the checksum and its signature. `unreachable`: this try got no answer from
    /// GitHub (offline, or an error page), so whether the release is signed by now is not known.
    private func waitForSignature(_ release: ReleaseInfo, since: Date, quietly: Bool, unreachable: Bool = false) {
        let outcome = SignatureWait.decide(published: release.published, since: since, now: Date())
        if let text = Self.endOfWait(outcome, unreachable: unreachable) { return refuse(release, text) }
        let timer = Timer(timeInterval: Self.signatureRetry, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Skipped, put off or replaced by a newer version since: no more tries.
                guard self.available?.tag == release.tag, release.tag != self.skippedTag, !self.snoozed(release), self.staged == nil else {
                    self.awaitingSignature = nil
                    return
                }
                self.download(release, quietly: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        awaitingSignature = (release.tag, since, timer)
        if quietly { return }
        tell("Next Term \(release.version) is not signed yet",
             "Each release is signed with the Next Term release key a few minutes after it is published, and only a signed one is installed. Next Term checks again every 10 minutes for the next two hours, and downloads it once it is signed. The Update button then reads Relaunch to Update.")
    }

    /// Why the wait for a release's signature ended, or nil while it goes on.
    static func endOfWait(_ outcome: SignatureWait, unreachable: Bool) -> String? {
        guard outcome != .wait else { return nil }
        if unreachable { return "GitHub did not answer, so the release's signature could not be checked and it was not installed. Try again later." }
        if outcome == .tooOld { return "The release has no signature from the Next Term release key, so it was not installed." }
        return "The release is still not signed with the Next Term release key, so it was not installed. Try again later."
    }

    private static func text(of refusal: ReleaseSignature.Refusal) -> String {
        switch refusal {
        case .notSigned: return "Its checksum is not signed with the Next Term release key, so it was not installed."
        case .notFor(let file): return "The signed checksum is not for \(file), so it was not installed."
        case .mismatch: return "The download does not match its signed checksum, so it was not installed."
        case .noChecksum: return "The release has no checksum for its disk image, so it was not installed."
        }
    }

    /// A release the release-key check refuses. Its page offers the same files, so it is not suggested.
    private func refuse(_ release: ReleaseInfo, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Next Term \(release.version) was not installed"
        alert.informativeText = text
        alert.runModal()
    }

    struct UpdateError: Error { let text: String; init(_ text: String) { self.text = text } }

    private func fetch(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url, delegate: progress)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("The download failed (HTTP \(http.statusCode)).") }
        // The temporary file goes away when this returns: keep it.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("NextTerm-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the app out of the disk image into a folder on the same volume as this app, and checks
    /// it is Next Term at the expected version with an intact signature.
    private nonisolated static func stage(dmg: URL, version: AppVersion) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("NextTerm-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = try? Self.runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: dmg)
        }
        guard try Self.runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path]) else {
            throw UpdateError("The disk image could not be opened.")
        }
        let source = mount.appendingPathComponent("Next Term.app")
        let here = Bundle.main.bundleURL
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: here, create: true)
        let target = folder.appendingPathComponent("Next Term.app")
        guard try Self.runTool("/usr/bin/ditto", [source.path, target.path]) else { throw UpdateError("The new app could not be copied.") }
        let info = Bundle(url: target)
        guard info?.bundleIdentifier == Bundle.main.bundleIdentifier,
              (info?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init) == version else {
            throw UpdateError("The disk image does not hold Next Term \(version).")
        }
        guard try Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]) else {
            throw UpdateError("The new app's signature is broken.")
        }
        return target
    }

    private nonisolated static func runTool(_ path: String, _ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func relaunchPrompt(_ version: AppVersion) {
        if testing, UserDefaults.standard.bool(forKey: "updateInstallWithoutAsking") { return NSApp.terminate(nil) }
        let alert = NSAlert()
        alert.messageText = "Next Term \(version) is ready"
        alert.informativeText = "It replaces this version when Next Term quits. Relaunch now? Running commands and agents stop."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "When I Quit")
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    /// Called as Next Term quits: if an update is staged, a small script waits for this process to end,
    /// swaps the apps (putting the old one back if anything fails) and starts the new one.
    func installStagedUpdateOnQuit() {
        guard let staged else { return }
        let here = Bundle.main.bundleURL.path
        let backup = staged.newApp.deletingLastPathComponent().appendingPathComponent("Next Term (previous).app").path
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        if /bin/mv \(ShellQuote.quote(here)) \(ShellQuote.quote(backup)); then
          if /bin/mv \(ShellQuote.quote(staged.newApp.path)) \(ShellQuote.quote(here)); then
            /bin/rm -rf \(ShellQuote.quote(backup)) \(ShellQuote.quote(staged.newApp.deletingLastPathComponent().path))
          else
            /bin/mv \(ShellQuote.quote(backup)) \(ShellQuote.quote(here))
          fi
        fi
        /usr/bin/open \(ShellQuote.quote(here))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run() // outlives this process
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// A small window with the download's progress.
final class UpdateProgressWindow: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    @MainActor init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Software Update"
        label.stringValue = title
        Typography.singleLine(label, truncation: .byTruncatingTail)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.contentView = stack
    }

    @MainActor var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue; bar.isIndeterminate = true; bar.startAnimation(nil) }
    }

    @MainActor func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor func close() { panel.close() }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.bar.doubleValue = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
