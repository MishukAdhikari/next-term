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
/// and acts on the answer. The restore step (`restoring`) runs first: an update, quit or crash restore that built
/// windows meets the first row, and shows nothing more.
public enum LaunchDecision {
    /// The rows in order; the first that matches wins. `exists` says whether a project's folder is still
    /// there.
    public static func opening(_ input: LaunchInput, exists: (String) -> Bool) -> LaunchOpening {
        // Row 1, and row 9: a restore built its windows, or a request opened its window.
        if input.terminalWindowOpen { return .nothing }
        let reopens = input.settings.opens == .lastProjects
        if input.kind == .dockReopen {
            // The session's windows were closed by hand: Reopen brings back the most recent project.
            guard reopens, let recent = input.recentProjects.first(where: exists) else { return .welcome }
            return .reopen([recent])
        }
        // Rows 6 to 8: no restore built a window. Under Resume, the projects open at the last quit, each with one
        // fresh shell.
        let saved = existing(input.sessionProjects, exists: exists)
        if reopens && !saved.isEmpty { return .reopen(saved) }
        // Nothing to reopen: no fallback to the most recent project.
        return input.kind == .normal && input.mayOfferImport ? .importThenWelcome : .welcome
    }

    /// `paths` in order, without the missing folders and repeats.
    static func existing(_ paths: [String], exists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return paths.filter { (path: String) -> Bool in seen.insert(path).inserted && exists(path) }
    }
}

// MARK: - The restore step

// Before the table, a launch that holds the sessions folder decides what it restores: the update's sessions, the
// session a quit under "Resume where I left off" saved, the layout after a crash, the layout alone after restores that
// did not finish, or nothing. Every file it reads there is untrusted input. A marker alone runs nothing and skips no
// question: it only picks the update restore, and only for a snapshot that names it, in a folder sandboxed processes
// cannot write. A quit consent id lets agents resume once, and only from the quit's own clean snapshot. Each pane still
// passes the resume gate.

/// Written last at an update quit, beside the snapshot that waits for it (`Header.awaitingMarker`): the next launch is
/// the update's relaunch. It is claimed by an exclusive rename, and its id is then recorded as consumed, so it is
/// never taken twice.
public struct UpdateMarker: Equatable, Sendable {
    public static let fileName = "update-marker.json"
    /// Its name once a launch has claimed it (`claim(in:consumed:)`), until the launch has recorded it as consumed.
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

extension UpdateMarker {
    /// Claims the marker waiting in `files` for this launch (`SessionFiles.claim`, to `claimedName`) and reads it: nil
    /// when none waits, another process took it, anything fails, or what was claimed is no marker. The claimed file
    /// stays until the launch has recorded what its decision consumes (`RestoreDecision.consumes`); then it removes it.
    ///
    /// A claimed file there already was left by a launch that ended between its claim and that removal. Its name is
    /// fixed, so it would block every claim after it, and every update relaunch would restore as after a crash. It goes
    /// first: its id, when it reads, is added to `consumed` (a record that does not read stays so), and it is removed.
    /// A link is removed, never followed.
    public static func claim(in files: SessionFiles, consumed: inout ConsumedMarkers?) -> UpdateMarker? {
        let leftover: Data? = try? files.read(claimedName, maxSize: maxSize)
        if let id = leftover.flatMap(parse)?.id { consumed = consumed?.adding(id) }
        try? files.remove(claimedName)
        guard (try? files.claim(fileName, as: claimedName)) == true else { return nil }
        let claimed: Data? = try? files.read(claimedName, maxSize: maxSize)
        return claimed.flatMap(parse)
    }
}

/// The markers launches have claimed, and the quit consent ids they used, newest last, so a marker put back is refused
/// and a consent lets agents resume once.
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
        guard ids.count == texts.count else { return nil }
        return ConsumedMarkers(ids: ids)
    }

    public var data: Data {
        let texts: [String] = ids.map { $0.uuidString.lowercased() }
        return (try? JSONEncoder().encode(texts)) ?? Data("[]".utf8)
    }
}

/// KTD13's crash-loop counter: launches in a row that tried to restore and did not settle. A launch raises it, and
/// writes it, before it reads the snapshot, so a restore that crashes has counted already. It reads 1 on the first
/// launch after a reset, so the raised count less one is the restores that did not finish. A counter that does not
/// read, or was not written, never lets a restore run actions (`unread`, `RestoreFacts.attemptsWritten`).
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
    /// What a counter there that does not read counts as, one the folder refuses included: one restore that did not
    /// finish, so the launch, raising it, restores in safe mode. Reading it as none would let a loop start over.
    public static let unread = RestoreAttempts(count: safeMode - 1)

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
        /// The snapshot the tries were counted for was set aside: the next one gets tries of its own.
        case setAside
    }

    public func after(_ event: Event) -> RestoreAttempts {
        switch event {
        case .launch, .tryAgain: return RestoreAttempts(count: count + 1)
        case .settled, .cleanQuit, .markerWritten, .setAside: return RestoreAttempts()
        }
    }

    /// The counter in `data`, as `data` writes it; more digits than a number holds count as `most`. Anything else reads
    /// as `unread`: the launch raises it and writes it whole again, so the count goes on from there.
    public static func parse(_ data: Data) -> RestoreAttempts {
        guard data.count <= maxSize else { return unread }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = !text.isEmpty && text.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        guard digits else { return unread }
        return RestoreAttempts(count: Int(text) ?? most)
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
    /// The markers claimed before, and the quit consent ids used; nil when the record is there but does not read.
    public var consumed: ConsumedMarkers?
    /// The counter, raised for this launch.
    public var attempts: RestoreAttempts
    /// The raised counter was written whole before the snapshot was read. When it was not (a full disk, a refused
    /// file), a restore that crashes would not count, and the same snapshot would be restored forever.
    public var attemptsWritten: Bool
    /// Now, on the uptime clock (`UpdateMarker.uptimeNow()`).
    public var uptime: TimeInterval
    /// This boot's session (`UpdateMarker.currentBootSession()`).
    public var bootSession: String?
    /// The running app's version.
    public var version: String
    /// The install script's result, read once and removed.
    public var installResult: InstallResult?
    /// Settings › General's "At launch" reads "Resume where I left off": a clean snapshot with windows comes back.
    public var resumesAtLaunch: Bool

    public init(lockTaken: Bool, marker: UpdateMarker? = nil, header: SessionSnapshot.Header? = nil, windows: Int = 0,
                consumed: ConsumedMarkers? = ConsumedMarkers(), attempts: RestoreAttempts, attemptsWritten: Bool,
                uptime: TimeInterval, bootSession: String?, version: String, installResult: InstallResult? = nil,
                resumesAtLaunch: Bool = false) {
        self.lockTaken = lockTaken
        self.marker = marker
        self.header = header
        self.windows = windows
        self.consumed = consumed
        self.attempts = attempts
        self.attemptsWritten = attemptsWritten
        self.uptime = uptime
        self.bootSession = bootSession
        self.version = version
        self.installResult = installResult
        self.resumesAtLaunch = resumesAtLaunch
    }
}

/// What a launch restores.
public enum LaunchRestoreKind: Equatable, Sendable {
    /// Nothing: the launch table decides what shows.
    case normal
    /// The windows come back, each pane planned as this kind (`.update`, `.quit` or `.crash`).
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
        /// An update or quit restore reads those named for its quit (`scrollbackQuit`), deleting each once read.
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
        /// Once the snapshot is set aside (`RestoreAttempts.Event.setAside`): the tries counted were its own, so a launch
        /// that crashes early does not set the next one aside untried. If it cannot be set aside, as `afterLaunch`.
        case afterSetAside
    }

    public var kind: LaunchRestoreKind
    /// What the claimed marker came to.
    public var marker: UpdateMarker.Check
    /// The launch keeps the snapshot current: it holds the folder.
    public var saves: Bool
    /// The markers to record as consumed, before the claimed file is removed: any marker claimed, whatever it came to,
    /// and the one the snapshot waits for, as this launch deals with that update quit now. Then the snapshot's quit
    /// consent id, whatever restores: it lets agents resume once, so it is recorded before the restore runs.
    public var consumes: [UUID]
    /// A quit restore whose quit consent id no launch has used (R30): Claude Code, Codex and Qwen Code may resume by
    /// themselves, as on an update restore. Without it, every agent's resume command goes on the line.
    public var quitConsent: Bool
    public var scrollback: Scrollback
    /// The quit the scrollback read is named for: the marker's id after an update quit, the snapshot's launch id after a
    /// quit under Resume. Nil when none is read.
    public var scrollbackQuit: UUID?
    /// The install script's failed outcome: one alert says the update did not install, whatever restores.
    public var installAlert: InstallResult.Outcome?
    /// The note that the update did not install, shown once with what restores: the snapshot was saved at an update
    /// quit no launch has dealt with (the marker it waits for is not consumed), the running version is not the one that
    /// update installs, and no alert says so already.
    public var didNotInstallNote: Bool
    public var attemptsReset: AttemptsReset

    /// The launch table's `restore` input, once the restore has built what it builds.
    public func launchRestore(openedWindow: Bool) -> LaunchRestoreResult {
        guard kind.restores else { return .notRun }
        return openedWindow ? .openedWindows : .openedNoWindow
    }
}

extension LaunchRestoreKind {
    /// The windows come back.
    var restores: Bool {
        switch self {
        case .normal, .quarantine: return false
        case .restore, .safeMode: return true
        }
    }
}

extension LaunchDecision {
    /// What a launch restores (KTD13):
    /// - without the lock, nothing, and nothing is saved;
    /// - a marker that holds (`check`) restores the update's snapshot;
    /// - otherwise an unclean snapshot restores as after a crash;
    /// - otherwise, under "Resume where I left off", a quit's clean snapshot restores as a quit restore, with the quit
    ///   consent when its id is unused (R3, R30); under "Show the Welcome window" it is none;
    /// - a snapshot with no windows is none;
    /// - at a raised counter of 3, or one that was not written, the restore is safe mode; at 4 or more, the snapshot is
    ///   set aside.
    /// Telling the user that an update did not install is decided alongside (R18): the alert whatever restores, the
    /// note once, with what restores.
    public static func restoring(_ facts: RestoreFacts) -> RestoreDecision {
        guard facts.lockTaken else {
            return RestoreDecision(kind: .normal, marker: .missing, saves: false, consumes: [], quitConsent: false,
                                   scrollback: .leave, scrollbackQuit: nil, installAlert: nil, didNotInstallNote: false,
                                   attemptsReset: .never)
        }
        let check = check(facts)
        let kind = held(found(facts, marker: check), attempts: facts.attempts, counted: facts.attemptsWritten)
        let alert = failure(facts.installResult)
        let note = alert == nil && kind.restores && didNotInstall(facts, marker: check)
        let quit = scrollbackQuit(kind, facts: facts)
        let scrollback: RestoreDecision.Scrollback = quit == nil ? .deleteUnread : .read
        return RestoreDecision(kind: kind, marker: check, saves: true, consumes: used(facts), quitConsent: consented(kind, facts),
                               scrollback: scrollback, scrollbackQuit: quit, installAlert: alert, didNotInstallNote: note,
                               attemptsReset: reset(after: kind))
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
    /// unclaimed result that says the old app was left in its backup, written at the quit the folder's snapshot was
    /// saved at. That result names the marker the snapshot waits for (`awaitingMarker`, the header's): the update
    /// quit's, or none for both after a "When I Quit" install, whose quit is a normal one and writes no marker. Anything
    /// else is ignored, and the app opens its own folder.
    public static func acceptsBackupOpen(key: String, recordedBundlePath: String?, result: InstallResult?,
                                         awaitingMarker: UUID?, exists: (String) -> Bool) -> Bool {
        guard SessionFiles.isKey(key), let path = recordedBundlePath, !exists(path) else { return false }
        guard let result, result.outcome == .failedRestoredBackup else { return false }
        return result.marker == awaitingMarker
    }

    /// The kind of restore the snapshot asks for, before the counter: none without windows. A clean snapshot is a
    /// quit's: it comes back as a quit restore under "Resume where I left off", unless it waits for an update's marker
    /// that never came.
    private static func found(_ facts: RestoreFacts, marker check: UpdateMarker.Check) -> SessionSnapshot.RestoreKind? {
        guard let header = facts.header, facts.windows > 0 else { return nil }
        if check == .valid { return .update }
        guard header.clean else { return .crash }
        return facts.resumesAtLaunch && header.awaitingMarker == nil ? .quit : nil
    }

    /// Whether a quit restore may let agents resume by themselves: its snapshot holds a consent id that no launch has
    /// used. Never out of safe mode, and never when the record of used ids does not read.
    private static func consented(_ kind: LaunchRestoreKind, _ facts: RestoreFacts) -> Bool {
        guard kind == .restore(.quit), let id = facts.header?.resumeConsent, let consumed = facts.consumed else { return false }
        return !consumed.contains(id)
    }

    /// The quit whose scrollback a restore reads: an update restore's marker, a quit restore's snapshot launch. Safe mode
    /// reads none.
    private static func scrollbackQuit(_ kind: LaunchRestoreKind, facts: RestoreFacts) -> UUID? {
        switch kind {
        case .restore(.update): return facts.marker?.id
        case .restore(.quit): return facts.header?.launchID
        default: return nil
        }
    }

    /// The restore, held back by the restores that did not finish before it. One whose try was not `counted` runs
    /// nothing either: if it crashed, the next launch would not know.
    private static func held(_ kind: SessionSnapshot.RestoreKind?, attempts: RestoreAttempts,
                             counted: Bool) -> LaunchRestoreKind {
        guard let kind else { return .normal }
        if attempts.count >= RestoreAttempts.quarantine { return .quarantine }
        if attempts.count >= RestoreAttempts.safeMode || !counted { return .safeMode(kind) }
        return .restore(kind)
    }

    /// The install script's outcome when it failed: the one alert says so.
    private static func failure(_ result: InstallResult?) -> InstallResult.Outcome? {
        let outcome: InstallResult.Outcome? = result?.outcome
        return outcome == .installed ? nil : outcome
    }

    /// Whether the snapshot was saved at an update quit no launch has dealt with yet, and the running version is not the
    /// one that update installs: the valid marker's to-version, else the snapshot's pending one. A launch that took the
    /// marker the snapshot waits for, or restored the snapshot without it, has told the user already; a record that
    /// does not read cannot say it has not.
    private static func didNotInstall(_ facts: RestoreFacts, marker check: UpdateMarker.Check) -> Bool {
        guard let header = facts.header, let awaited = header.awaitingMarker else { return false }
        guard let consumed = facts.consumed, !consumed.contains(awaited) else { return false }
        let installing: String? = check == .valid ? facts.marker?.toVersion : header.pendingToVersion
        guard let installing else { return false }
        return installing != facts.version
    }

    /// The ids the launch uses up: the marker it claimed, the one the snapshot waits for, then its quit consent id.
    private static func used(_ facts: RestoreFacts) -> [UUID] {
        var ids: [UUID] = facts.marker.map { [$0.id] } ?? []
        for id in [facts.header?.awaitingMarker, facts.header?.resumeConsent].compactMap({ $0 }) where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// When the counter resets after a launch that holds the folder.
    private static func reset(after kind: LaunchRestoreKind) -> RestoreDecision.AttemptsReset {
        if kind == .quarantine { return .afterSetAside }
        return kind.restores ? .afterRestore : .afterLaunch
    }
}
