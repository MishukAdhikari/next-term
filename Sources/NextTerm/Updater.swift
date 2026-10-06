import AppKit
import CryptoKit
import NextTermCore

/// Updates from GitHub Releases: checks once a day (and on demand), and with one click downloads the
/// new DMG, checks it against the release's SHA-256, puts the new app in place of this one when Next
/// Term quits, and starts it again.
///
/// Only the latest-release endpoint is contacted, with no identifying data beyond the version in the
/// User-Agent. Downloads are accepted only over https from GitHub.
@MainActor
final class Updater {
    static let shared = Updater()
    static let feed = URL(string: "https://api.github.com/repos/MishukAdhikari/next-term/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var checking = false
    private var progress: UpdateProgressWindow?
    /// A new app staged next to this one, swapped in when Next Term quits.
    private var staged: (newApp: URL, version: AppVersion)?

    var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }

    /// For testing the whole flow against a local feed (`-updateFeedURL file:///…/feed.json`).
    private var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) ?? Self.feed
    }

    private var testing: Bool { UserDefaults.standard.string(forKey: "updateFeedURL") != nil }

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
            DispatchQueue.main.async {
                self.checking = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                self.handle(release, current: current, userInitiated: userInitiated, failed: release == nil && status != 404)
            }
        }.resume()
    }

    private func handle(_ release: ReleaseInfo?, current: AppVersion, userInitiated: Bool, failed: Bool) {
        guard let release, current < release.version else {
            if userInitiated {
                failed ? tell("Could not check for updates", "GitHub did not answer. Try again later.")
                    : tell("Next Term is up to date", "Version \(current) is the newest.")
            }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == release.tag { return }
        if testing, UserDefaults.standard.bool(forKey: "updateInstallWithoutAsking") { return download(release) }
        let alert = NSAlert()
        alert.messageText = "Next Term \(release.version) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have \(current)." + (notes.isEmpty ? "" : "\n\n" + Typography.shortened(notes, to: 600))
        alert.addButton(withTitle: release.dmgURL != nil && release.checksumURL != nil ? "Install and Relaunch" : "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        alert.showsSuppressionButton = !userInitiated
        alert.suppressionButton?.title = "Skip this version"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(release.tag, forKey: "skippedVersion") }
        switch response {
        case .alertFirstButtonReturn:
            if release.dmgURL != nil, release.checksumURL != nil { download(release) } else { NSWorkspace.shared.open(release.pageURL) }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    // MARK: download, verify, stage

    private func download(_ release: ReleaseInfo) {
        guard let dmgURL = release.dmgURL, let checksumURL = release.checksumURL else { return }
        progress = UpdateProgressWindow(title: "Downloading Next Term \(release.version)…")
        progress?.show()
        Task {
            do {
                let expected = try await fetchChecksum(checksumURL)
                let dmg = try await fetch(dmgURL)
                progress?.message = "Checking the download…"
                let actual = try await Task.detached { try Self.sha256(of: dmg) }.value
                guard actual == expected else { throw UpdateError("The download does not match its published checksum, so it was not installed.") }
                progress?.message = "Preparing…"
                let version = release.version
                let app = try await Task.detached { try Self.stage(dmg: dmg, version: version) }.value
                staged = (app, release.version)
                progress?.close()
                progress = nil
                relaunchPrompt(release.version)
            } catch {
                progress?.close()
                progress = nil
                let message = (error as? UpdateError)?.text ?? error.localizedDescription
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

    struct UpdateError: Error { let text: String; init(_ text: String) { self.text = text } }

    private func fetchChecksum(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8), let hex = ReleaseInfo.checksum(fromShasumLine: text) else {
            throw UpdateError("The release has no usable checksum.")
        }
        return hex
    }

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
