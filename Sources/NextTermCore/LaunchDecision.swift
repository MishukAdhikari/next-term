import Foundation

/// How a launch, or a reopen with no window, came about.
public enum LaunchKind: CaseIterable, Sendable {
    /// From the Dock, Finder, Spotlight or a login item, naming nothing.
    case normal
    /// It named a folder or file: `nxtrm` (`--open-request`), a drop on the Dock icon, `open -a` with a
    /// path, Finder's Open With. One that opened its window meets "a terminal window is open"; one that
    /// skipped every item goes on as a normal launch.
    case request
    /// A reopen while Next Term runs with no window visible: a click on the Dock icon, or Finder,
    /// Spotlight or `open -a` with no path.
    case dockReopen
    /// The relaunch after "Relaunch Now", told by a flag `Updater` leaves (`isUpdateRelaunch`). Until
    /// the update that keeps sessions, whose restore takes its place.
    case updateRelaunch
}

/// What a restore did before the launch asks the table: the restore step's result
/// (`RestoreDecision.launchRestore(openedWindow:)`).
public enum LaunchRestoreResult: CaseIterable, Sendable {
    case notRun
    case openedWindows
    case openedNoWindow
}

/// What the launch knows when it asks what to show. The folders are checked by `LaunchDecision.opening`'s
/// `exists`, so nothing here touches the disk.
public struct LaunchInput: Sendable {
    public var kind: LaunchKind
    public var restore: LaunchRestoreResult
    /// A `TerminalWindowController` is open. The Welcome, Settings, Import and Update windows don't count.
    public var terminalWindowOpen: Bool
    public var settings: LaunchSettings
    /// The project windows open at the last quit, in order.
    public var sessionProjects: [String]
    /// The recent projects, most recent first.
    public var recentProjects: [String]
    /// "Coming from another app?" may be offered: it never was (`importOffered`), and there is no recent
    /// project. Whether an app to import from is installed is the app's to find, as it is slow.
    public var mayOfferImport: Bool

    public init(kind: LaunchKind, restore: LaunchRestoreResult, terminalWindowOpen: Bool, settings: LaunchSettings,
                sessionProjects: [String], recentProjects: [String], mayOfferImport: Bool) {
        self.kind = kind
        self.restore = restore
        self.terminalWindowOpen = terminalWindowOpen
        self.settings = settings
        self.sessionProjects = sessionProjects
        self.recentProjects = recentProjects
        self.mayOfferImport = mayOfferImport
    }
}

/// What the launch shows.
public enum LaunchOpening: Equatable, Sendable {
    /// A terminal window is open already.
    case nothing
    /// These projects, each in its window, in order.
    case reopen([String])
    case welcome
    /// "Coming from another app?", then the Welcome window; just the Welcome window when no app to import
    /// from is found.
    case importThenWelcome
}

/// The one table that says what a launch, or a reopen with no window, shows. The app gathers the inputs
/// and acts on the answer.
public enum LaunchDecision {
    /// How long the flag "Relaunch Now" leaves marks the next launch as its relaunch.
    public static let relaunchFlagLifetime: TimeInterval = 15 * 60

    /// The rows in order; the first that matches wins. `exists` says whether a project's folder is still
    /// there.
    public static func opening(_ input: LaunchInput, exists: (String) -> Bool) -> LaunchOpening {
        if input.terminalWindowOpen { return .nothing }
        let reopens = input.settings.opens == .lastProjects
        if input.kind == .dockReopen {
            // The session's windows were closed by hand: Reopen brings back the most recent project.
            guard reopens, let recent = input.recentProjects.first(where: exists) else { return .welcome }
            return .reopen([recent])
        }
        let saved = existing(input.sessionProjects, exists: exists)
        let relaunch = input.kind == .updateRelaunch && input.restore == .notRun
        if (relaunch || reopens) && !saved.isEmpty { return .reopen(saved) }
        // Nothing to reopen: no fallback to the most recent project.
        return input.kind == .normal && input.mayOfferImport ? .importThenWelcome : .welcome
    }

    /// Whether a launch flagged at `flaggedAt` is the relaunch after "Relaunch Now": a flag from 0 to 15
    /// minutes old. One from the future is not.
    public static func isUpdateRelaunch(flaggedAt: Date?, now: Date) -> Bool {
        guard let flaggedAt else { return false }
        let age = now.timeIntervalSince(flaggedAt)
        return age >= 0 && age <= relaunchFlagLifetime
    }

    /// `paths` in order, without the missing folders and repeats.
    static func existing(_ paths: [String], exists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return paths.filter { (path: String) -> Bool in seen.insert(path).inserted && exists(path) }
    }
}

// MARK: - The restore step

// Before the table, a launch that holds the sessions folder decides what it restores: the update's sessions, the
// layout after a crash, the layout alone after restores that did not finish, or nothing. Every file it reads there is
// untrusted input. A marker alone runs nothing and skips no question: it only picks the update restore, and only for a
// snapshot that names it, in a folder sandboxed processes cannot write. Each pane still passes the resume gate.

/// Written last at an update quit, beside the snapshot that waits for it (`Header.awaitingMarker`): the next launch is
/// the update's relaunch. It is claimed by an exclusive rename, and its id is then recorded as consumed, so it is
/// never taken twice.
public struct UpdateMarker: Equatable, Sendable {
    public static let fileName = "update-marker.json"
    /// Its name once a launch has claimed it (`SessionFiles.claim`).
    public static let claimedName = "update-marker.claimed.json"
    /// A marker is a few hundred bytes: anything bigger is not one.
    public static let maxSize = 4096
    /// How long after it was written, on the uptime clock, a launch may restore with it.
    public static let lifetime: TimeInterval = 15 * 60

    /// The id the snapshot waits for.
    public var id: UUID
    /// The launch that wrote it, and the snapshot (`Header.launchID`).
    public var launchID: UUID
    /// The version that quit.
    public var fromVersion: String
    /// The version being installed.
    public var toVersion: String
    /// The boot it was written in (`currentBootSession()`).
    public var bootSession: String
    /// When it was written, on the uptime clock (`uptimeNow()`).
    public var uptime: TimeInterval

    public init(id: UUID, launchID: UUID, fromVersion: String, toVersion: String, bootSession: String,
                uptime: TimeInterval) {
        self.id = id
        self.launchID = launchID
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.bootSession = bootSession
        self.uptime = uptime
    }

    /// Why a claimed marker does or does not make the launch the update's relaunch, checked in this order.
    public enum Check: Equatable, Sendable {
        case valid
        /// None was claimed, or the one claimed did not read.
        case missing
        /// The snapshot waits for another marker or none, another launch wrote it, or no snapshot reads.
        case notAwaited
        /// A launch took it before, or the record of the ones taken does not read.
        case consumed
        /// Written in another boot, or this boot's session could not be read.
        case otherBoot
        /// Over `lifetime` old, or from the future.
        case stale
        /// The running version is neither the one that quit (the install failed) nor the one installed.
        case otherVersion
    }

    /// The marker in `data`, nil unless it holds the six fields, each as the writer writes it: the ids as UUIDs, the
    /// versions and the boot session as short tokens, the uptime as a number of seconds not below zero.
    public static func parse(_ data: Data) -> UpdateMarker? {
        guard data.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(UpdateMarker.self, from: data)
    }

    /// The file's bytes.
    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Seconds since boot, counting sleep: the clock a marker's age is measured on, which setting the date does not
    /// move.
    public static func uptimeNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// This boot's session (`kern.bootsessionuuid`), nil when it cannot be read.
    public static func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        return bootToken(text)
    }

    static func versionToken(_ text: String?) -> String? { SnapshotText.token(text, max: 64, extra: ".+-") }
    static func bootToken(_ text: String?) -> String? { SnapshotText.token(text, max: 64, extra: "-") }
}

extension UpdateMarker: Codable {
    private enum Keys: String, CodingKey { case id, launchID, fromVersion, toVersion, bootSession, uptime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let invalid = DecodingError.dataCorruptedError(forKey: Keys.id, in: c, debugDescription: "not a marker")
        guard let id = UUID(uuidString: try c.decode(String.self, forKey: .id)),
              let launchID = UUID(uuidString: try c.decode(String.self, forKey: .launchID)),
              let from = Self.versionToken(try c.decode(String.self, forKey: .fromVersion)),
              let to = Self.versionToken(try c.decode(String.self, forKey: .toVersion)),
              let boot = Self.bootToken(try c.decode(String.self, forKey: .bootSession)) else { throw invalid }
        let uptime = try c.decode(Double.self, forKey: .uptime)
        guard uptime.isFinite, uptime >= 0 else { throw invalid }
        self.init(id: id, launchID: launchID, fromVersion: from, toVersion: to, bootSession: boot, uptime: uptime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(launchID.uuidString.lowercased(), forKey: .launchID)
        try c.encode(fromVersion, forKey: .fromVersion)
        try c.encode(toVersion, forKey: .toVersion)
        try c.encode(bootSession, forKey: .bootSession)
        try c.encode(uptime, forKey: .uptime)
    }
}

/// The markers launches have claimed, newest last, so a marker put back is refused.
public struct ConsumedMarkers: Equatable, Sendable {
    public static let fileName = "consumed-markers.json"
    public static let maxSize = 4096
    /// How many are kept. A marker also needs its snapshot, its boot and its 15 minutes, so the newest few are enough.
    static let kept = 32

    public private(set) var ids: [UUID]

    public init(ids: [UUID] = []) {
        self.ids = Array(ids.suffix(Self.kept))
    }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// With `id` as the newest.
    public func adding(_ id: UUID) -> ConsumedMarkers {
        ConsumedMarkers(ids: ids.filter { $0 != id } + [id])
    }

    /// The record in `data`: a list of ids. Nil for anything else, and then every marker counts as consumed. A record
    /// that is not there at all is an empty one.
    public static func parse(_ data: Data) -> ConsumedMarkers? {
        guard data.count <= maxSize else { return nil }
        guard let texts = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let ids: [UUID] = texts.compactMap(UUID.init(uuidString:))
        return ids.count == texts.count ? ConsumedMarkers(ids: ids) : nil
    }

    public var data: Data {
        let texts: [String] = ids.map { $0.uuidString.lowercased() }
        return (try? JSONEncoder().encode(texts)) ?? Data("[]".utf8)
    }
}

/// KTD13's crash-loop counter: launches in a row that tried to restore and did not settle. A launch raises it, and
/// writes it, before it reads the snapshot, so a restore that crashes has counted already. It reads 1 on the first
/// launch after a reset, so the raised count less one is the restores that did not finish.
public struct RestoreAttempts: Equatable, Sendable {
    public static let fileName = "restore-attempts"
    public static let maxSize = 64
    /// The raised count at which the restore builds the layout alone: two restores did not finish.
    public static let safeMode = 3
    /// The raised count at which the snapshot is set aside and the launch is normal: three did not finish.
    public static let quarantine = 4
    /// How long a launch runs, after its last restore action is applied or from its start when it restored nothing,
    /// before the counter resets.
    public static let settleTime: TimeInterval = 60
    /// It never counts past this.
    static let most = 1000

    public private(set) var count: Int

    public init(count: Int = 0) {
        self.count = min(max(count, 0), Self.most)
    }

    public enum Event: CaseIterable, Sendable {
        /// A launch that holds the sessions folder, before it reads the snapshot.
        case launch
        /// Safe mode's "Try Again", before it applies the actions.
        case tryAgain
        /// `settleTime` after the last restore action is applied, or into a launch that restored nothing.
        case settled
        /// A normal quit.
        case cleanQuit
        /// An update quit wrote its marker.
        case markerWritten
    }

    public func after(_ event: Event) -> RestoreAttempts {
        switch event {
        case .launch, .tryAgain: return RestoreAttempts(count: count + 1)
        case .settled, .cleanQuit, .markerWritten: return RestoreAttempts()
        }
    }

    /// The counter in `data`, as `data` writes it. Anything else reads as none: the launch raises it and writes it
    /// whole again, so the count goes on from there.
    public static func parse(_ data: Data) -> RestoreAttempts {
        guard data.count <= maxSize else { return RestoreAttempts() }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = !text.isEmpty && text.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        guard digits, let count = Int(text) else { return RestoreAttempts() }
        return RestoreAttempts(count: count)
    }

    public var data: Data { Data("\(count)\n".utf8) }
}

/// What the launch hook found in the sessions folder before the restore step decides.
public struct RestoreFacts: Sendable {
    /// This process took the folder's lock. Without it, nothing else here is read.
    public var lockTaken: Bool
    /// The marker this launch claimed, nil when none was there or it did not read.
    public var marker: UpdateMarker?
    /// The snapshot's header, nil when no state file reads.
    public var header: SessionSnapshot.Header?
    /// The windows in the snapshot.
    public var windows: Int
    /// The markers claimed before; nil when the record is there but does not read.
    public var consumed: ConsumedMarkers?
    /// The counter, raised for this launch.
    public var attempts: RestoreAttempts
    /// Now, on the uptime clock (`UpdateMarker.uptimeNow()`).
    public var uptime: TimeInterval
    /// This boot's session (`UpdateMarker.currentBootSession()`).
    public var bootSession: String?
    /// The running app's version.
    public var version: String
    /// The install script's result, read once and removed.
    public var installResult: InstallResult?

    public init(lockTaken: Bool, marker: UpdateMarker? = nil, header: SessionSnapshot.Header? = nil, windows: Int = 0,
                consumed: ConsumedMarkers? = ConsumedMarkers(), attempts: RestoreAttempts, uptime: TimeInterval,
                bootSession: String?, version: String, installResult: InstallResult? = nil) {
        self.lockTaken = lockTaken
        self.marker = marker
        self.header = header
        self.windows = windows
        self.consumed = consumed
        self.attempts = attempts
        self.uptime = uptime
        self.bootSession = bootSession
        self.version = version
        self.installResult = installResult
    }
}

/// What a launch restores.
public enum LaunchRestoreKind: Equatable, Sendable {
    /// Nothing: the launch table decides what shows.
    case normal
    /// The windows come back, each pane planned as this kind (`.update` or `.crash`).
    case restore(SessionSnapshot.RestoreKind)
    /// Two restores did not finish: the layout comes back with nothing typed or run, planned as this kind for "Try
    /// Again", with one alert offering "Keep As Is" and "Try Again".
    case safeMode(SessionSnapshot.RestoreKind)
    /// Three did not finish: the snapshot is set aside, the launch is normal, and one alert says where it went.
    case quarantine
}

/// The restore step's answer.
public struct RestoreDecision: Equatable, Sendable {
    /// What happens to the scrollback files.
    public enum Scrollback: Equatable, Sendable {
        /// An update restore reads those named for its marker, deleting each once read.
        case read
        /// Every other launch that holds the folder deletes them unread.
        case deleteUnread
        /// Another process holds the folder: they are its.
        case leave
    }

    /// When the counter resets (`RestoreAttempts.Event.settled`).
    public enum AttemptsReset: Equatable, Sendable {
        /// Never: another process holds the folder.
        case never
        /// `settleTime` into the launch, which restored nothing.
        case afterLaunch
        /// `settleTime` after the restore's last action is applied, or after "Keep As Is" ends safe mode.
        case afterRestore
    }

    public var kind: LaunchRestoreKind
    /// What the claimed marker came to.
    public var marker: UpdateMarker.Check
    /// The launch keeps the snapshot current: it holds the folder.
    public var saves: Bool
    /// The marker to record as consumed: any marker claimed, whatever it came to.
    public var consumes: UUID?
    public var scrollback: Scrollback
    /// The install script's failed outcome: one alert says the update did not install, whatever restores.
    public var installAlert: InstallResult.Outcome?
    /// The note that the update did not install: an update was being installed, the running version is not the one it
    /// installs, and no alert says so already.
    public var didNotInstallNote: Bool
    public var attemptsReset: AttemptsReset

    /// The launch table's `restore` input, once the restore has built what it builds.
    public func launchRestore(openedWindow: Bool) -> LaunchRestoreResult {
        switch kind {
        case .normal, .quarantine: return .notRun
        case .restore, .safeMode: return openedWindow ? .openedWindows : .openedNoWindow
        }
    }
}

extension LaunchDecision {
    /// What a launch restores (KTD13):
    /// - without the lock, nothing, and nothing is saved;
    /// - a marker that holds (`check`) restores the update's snapshot;
    /// - otherwise an unclean snapshot restores as after a crash;
    /// - a snapshot with no windows is none;
    /// - at a raised counter of 3, the restore is safe mode; at 4 or more, the snapshot is set aside.
    /// Telling the user that an update did not install is decided alongside, whatever restores (R18).
    public static func restoring(_ facts: RestoreFacts) -> RestoreDecision {
        guard facts.lockTaken else {
            return RestoreDecision(kind: .normal, marker: .missing, saves: false, consumes: nil, scrollback: .leave,
                                   installAlert: nil, didNotInstallNote: false, attemptsReset: .never)
        }
        let check = check(facts)
        let kind = held(found(facts, marker: check), attempts: facts.attempts)
        let restores = kind != .normal && kind != .quarantine
        let alert: InstallResult.Outcome? = facts.installResult.map(\.outcome).flatMap { $0 == .installed ? nil : $0 }
        let pending: String? = facts.header?.pendingToVersion
        let notInstalled = alert == nil && pending != nil && pending != facts.version
        return RestoreDecision(kind: kind, marker: check, saves: true, consumes: facts.marker?.id,
                               scrollback: kind == .restore(.update) ? .read : .deleteUnread, installAlert: alert,
                               didNotInstallNote: notInstalled, attemptsReset: restores ? .afterRestore : .afterLaunch)
    }

    /// Whether the claimed marker makes this launch the update's relaunch: the snapshot waits for it and was written by
    /// the same launch, no launch took it before, it is from this boot and at most `UpdateMarker.lifetime` old on the
    /// uptime clock, and the running version is the one it installs or, after a failed install, the one that quit.
    public static func check(_ facts: RestoreFacts) -> UpdateMarker.Check {
        guard let marker = facts.marker else { return .missing }
        guard let header = facts.header, header.awaitingMarker == marker.id, header.launchID == marker.launchID else {
            return .notAwaited
        }
        guard let consumed = facts.consumed, !consumed.contains(marker.id) else { return .consumed }
        guard let boot = facts.bootSession, boot == marker.bootSession else { return .otherBoot }
        let age = facts.uptime - marker.uptime
        guard age >= 0, age <= UpdateMarker.lifetime else { return .stale }
        let version = facts.version
        guard version == marker.toVersion || version == marker.fromVersion else { return .otherVersion }
        return .valid
    }

    /// Whether the old app, opened from its backup by the install script (KTD12), may take the sessions folder its
    /// `InstallScript.folderKeyArgument` names: a folder key, for a folder whose recorded app is gone, holding the
    /// unclaimed result that says the old app was left in its backup, for the marker that quit wrote. Anything else is
    /// ignored, and the app opens its own folder.
    public static func acceptsBackupOpen(key: String, recordedBundlePath: String?, result: InstallResult?,
                                         exists: (String) -> Bool) -> Bool {
        guard SessionFiles.isKey(key), let path = recordedBundlePath, !exists(path) else { return false }
        guard let result, result.outcome == .failedRestoredBackup else { return false }
        return result.marker != nil
    }

    /// The kind of restore the snapshot asks for, before the counter: none without windows.
    private static func found(_ facts: RestoreFacts, marker check: UpdateMarker.Check) -> SessionSnapshot.RestoreKind? {
        guard let header = facts.header, facts.windows > 0 else { return nil }
        if check == .valid { return .update }
        return header.clean ? nil : .crash
    }

    /// The restore, held back by the restores that did not finish before it.
    private static func held(_ kind: SessionSnapshot.RestoreKind?, attempts: RestoreAttempts) -> LaunchRestoreKind {
        guard let kind else { return .normal }
        if attempts.count >= RestoreAttempts.quarantine { return .quarantine }
        if attempts.count >= RestoreAttempts.safeMode { return .safeMode(kind) }
        return .restore(kind)
    }
}
