import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The sessions folder's one writer (KTD1, KTD18). While Next Term runs it keeps the session snapshot current: the app
// captures its windows every 2 seconds and the writer saves them when anything saved changed, marked unclean, so a crash
// leaves the layout. At the quit it writes the last save, in order: the state file (the whole session, or a tombstone),
// then scrollback, then the update's marker. Nothing is written until the save gate opens, so the windows a restore
// builds from the snapshot are on screen before the snapshot is replaced; the gate opens by itself after 10 seconds.
//
// Saves are serial: one runs at a time, each with a higher generation than the one before it (up to a cap no save
// reaches), across launches too, and once the quit's save has run nothing is saved again. A periodic save in flight at
// the quit finishes first, so the final file is the one the marker names.

/// How Next Term quits, as the sessions folder sees it: what the quit's last save writes.
public enum QuitIntent: Equatable, Sendable {
    /// An update quit the user agreed to on the update sheet ("Update Now", "Wait for Them"). With the sheet's box
    /// checked (`keep`), the whole session, unclean and waiting for the marker, its scrollback, then the marker naming the
    /// version that quits (`from`) and the one installed (`to`). Unchecked, the tombstone and no marker.
    case update(keep: Bool, from: String, to: String)
    /// Any other quit, under Settings › General's "At launch". "Resume where I left off" (`resume`) saves the whole
    /// session marked clean, with a one-time resume consent id when the user let this very quit go ahead with the resume
    /// box checked (`consent`, R30), and its scrollback. "Show the Welcome window" leaves the tombstone.
    case quit(resume: Bool, consent: Bool)

    /// The quit saves the whole session for the next launch to bring back, scrollback included. Otherwise it leaves the
    /// tombstone: the header alone, marked clean.
    public var savesSession: Bool {
        switch self {
        case .update(let keep, _, _): return keep
        case .quit(let resume, _): return resume
        }
    }

    /// The intent of a quit no update consent covers: Settings › General's "At launch", read once the quit's answer is
    /// saved. Only a user's quit carries the quit consent; a logout, restart or shutdown, and "Relaunch Now", asked nothing
    /// that could give it. Nil for the plain self-test, which never saves.
    public static func ordinary(reason: QuitReason, settings: LaunchSettings, consent: Bool) -> QuitIntent? {
        guard reason != .selfTest else { return nil }
        let resume = settings.opens == .lastProjects
        return .quit(resume: resume, consent: resume && consent && reason == .user)
    }
}

extension QuitReason {
    /// Whether the quit spawns a staged update's install script. Not at a logout, restart or shutdown, which could end
    /// the install part-way: it waits for the next quit.
    public var installsStagedUpdate: Bool { self != .systemSession }
}

/// A pane's scrollback for the quit's save: the id its record names it by, and its text, worked out (masked) only when
/// it is written.
public struct QuitScrollback: Sendable {
    public var id: UUID
    public var text: @Sendable () -> String

    public init(id: UUID, text: @escaping @Sendable () -> String) {
        self.id = id
        self.text = text
    }
}

public final class SessionWriter: @unchecked Sendable {
    /// How often the app captures its windows for a save.
    public static let interval: TimeInterval = 2
    /// How long saving waits for the restore to build its windows before it starts anyway.
    public static let gateDeadline: TimeInterval = 10

    /// How long the quit may spend on scrollback with `tabs` tabs: a second, a tenth more for each tab, 4 at most. The
    /// state file and the marker are written whatever it takes.
    public static func quitBudget(tabs: Int) -> TimeInterval {
        min(4, 1 + 0.1 * Double(max(tabs, 0)))
    }

    /// The order the quit reads tabs' scrollback in, so a time budget that runs out drops the last: the tabs in view,
    /// then each window's tab in front, then the rest, each in the order given.
    public static func scrollbackOrder<Tab>(_ tabs: [Tab], visible: (Tab) -> Bool, inFront: (Tab) -> Bool) -> [Tab] {
        let shown: [Tab] = tabs.filter(visible)
        let rest: [Tab] = tabs.filter { (tab: Tab) -> Bool in !visible(tab) }
        let fronts: [Tab] = rest.filter(inFront)
        let behind: [Tab] = rest.filter { (tab: Tab) -> Bool in !inFront(tab) }
        return shown + fronts + behind
    }

    /// What a save wrote.
    public struct SaveResult: Equatable, Sendable {
        public var generation: Int
        public var savedAt: Date
        /// False: it was not written, and the file saved before it stays.
        public var succeeded: Bool
        /// The panes the file leaves out (SessionSnapshot.panesLeftOut): past the count caps, or a remote pane whose
        /// record cannot be trusted. Nothing may promise them back.
        public var panesLeftOut: [UUID]

        public init(generation: Int, savedAt: Date, succeeded: Bool, panesLeftOut: [UUID]) {
            self.generation = generation
            self.savedAt = savedAt
            self.succeeded = succeeded
            self.panesLeftOut = panesLeftOut
        }
    }

    /// What a periodic save did.
    public enum Save: Equatable, Sendable {
        /// It was tried: whether it was written is in the result.
        case wrote(SaveResult)
        /// Nothing saved changed since the last save.
        case unchanged
        /// The gate is closed: the restore has not built its windows yet.
        case waiting
        /// The quit's save has run.
        case finished
    }

    /// What the quit's save wrote.
    public struct QuitSave: Equatable, Sendable {
        /// The state file is on disk: the whole session, or the tombstone.
        public var stateWritten: Bool
        /// The marker the state file waits for: what the install script's result names, written or not.
        public var awaitedMarker: UUID?
        /// The marker is on disk too.
        public var markerWritten: Bool
        /// The panes whose scrollback was written, in the order given.
        public var scrollback: [UUID]
        /// The quit consent's one-time id in the state file.
        public var resumeConsent: UUID?

        public init(stateWritten: Bool = false, awaitedMarker: UUID? = nil, markerWritten: Bool = false, scrollback: [UUID] = [],
                    resumeConsent: UUID? = nil) {
            self.stateWritten = stateWritten
            self.awaitedMarker = awaitedMarker
            self.markerWritten = markerWritten
            self.scrollback = scrollback
            self.resumeConsent = resumeConsent
        }
    }

    public let files: SessionFiles
    /// This launch's id: every save's header, and the name of the scrollback a quit under Resume saves.
    public let launchID: UUID
    public let limits: SessionSnapshot.Limits
    private let bootSession: String?
    private let gateDeadline: Date
    /// Held for a whole save, so saves run one at a time.
    private let writing = NSLock()
    /// Held only to read or set what follows, so asking never waits for a save.
    private let state = NSLock()
    private var gateOpen = false
    private var finished = false
    private var saved: SaveResult?
    /// The last generation used.
    private var generation: Int
    /// What the last save wrote, as compared (`persisted`); nil before the launch's first save.
    private var lastWritten: [SessionSnapshot.Window]?

    /// `generation` is the snapshot's the launch read, so every save of this launch comes after it, up to the cap
    /// (`Header.maxGeneration`), where they stay. `startedAt` starts the gate's deadline.
    public init(files: SessionFiles, launchID: UUID = UUID(), after generation: Int, bootSession: String?, startedAt: Date = Date(),
                limits: SessionSnapshot.Limits = .standard) {
        self.files = files
        self.launchID = launchID
        self.generation = min(max(generation, 0), SessionSnapshot.Header.maxGeneration)
        self.bootSession = bootSession
        self.limits = limits
        gateDeadline = startedAt.addingTimeInterval(Self.gateDeadline)
    }

    /// The snapshot in the folder, repaired; nil when it does not read, and neither does its previous file.
    ///
    /// A previous file is read only when a save after it was cut off or damaged: a launch ran past it, and did not quit
    /// as it should. So it reads as a crash left it, unclean, with no resume consent: a clean quit's file kept by the
    /// next launch's first save never lets agents resume by themselves after a crash (R30).
    public static func load(from files: SessionFiles, limits: SessionSnapshot.Limits = .standard) -> SessionSnapshot? {
        let name = SessionSnapshot.fileName()
        if let current = read(name, from: files, limits: limits) { return current }
        guard var previous = read(name + SessionFiles.previousSuffix, from: files, limits: limits) else { return nil }
        previous.header.clean = false
        previous.header.resumeConsent = nil
        return previous
    }

    private static func read(_ name: String, from files: SessionFiles, limits: SessionSnapshot.Limits) -> SessionSnapshot? {
        guard let data = (try? files.read(name, maxSize: limits.bytes)) ?? nil else { return nil }
        return try? SessionSnapshot.decode(data, limits: limits)
    }

    // MARK: the gate

    /// Lets saving start: the restore has built its windows, or had nothing to build. Every way out of the restore
    /// opens it.
    public func openGate() {
        state.lock()
        gateOpen = true
        state.unlock()
    }

    /// Whether a save now would wait: the gate is closed and its deadline has not passed.
    public func isWaiting(at now: Date) -> Bool {
        state.lock()
        defer { state.unlock() }
        return !gateOpen && now < gateDeadline
    }

    /// The last save's result, periodic or the quit's; nil before the first.
    public var lastSave: SaveResult? {
        state.lock()
        defer { state.unlock() }
        return saved
    }

    // MARK: saving

    /// Saves `windows`, unclean, when anything saved changed since the last save, and always for the launch's first:
    /// it marks the file unclean, so a crash from here on restores the layout. A pane's state before and whether its work
    /// was cut off follow its status dot, so a change to them alone writes nothing; they are saved with the next change,
    /// and at the quit. The file before is kept as `state-v1.json.prev` while it reads.
    public func save(_ windows: [SessionSnapshot.Window], now: Date = Date()) -> Save {
        writing.lock()
        defer { writing.unlock() }
        if isFinished { return .finished }
        if isWaiting(at: now) { return .waiting }
        let persisted = Self.persisted(windows)
        if let lastWritten, lastWritten == persisted { return .unchanged }
        let header = SessionSnapshot.Header(launchID: launchID, generation: nextGeneration(), clean: false, bootSession: bootSession,
                                            savedAt: now)
        let result = write(SessionSnapshot(header: header, windows: windows), keepingPrevious: true)
        if result.succeeded { lastWritten = persisted }
        return .wrote(result)
    }

    /// The quit's save, once: no save is written after it. Waits for a save in flight. Before the gate opens it writes
    /// nothing: the windows the restore builds are not all there, and the snapshot it reads from stays.
    /// - The whole session (`QuitIntent.savesSession`): at an update quit, unclean, waiting for a fresh marker id, with the
    ///   version it installs; at a quit under Resume, clean, with a fresh resume consent id when the quit carried the
    ///   consent. Else the tombstone; when it cannot be written, the state file and the one before are removed, so the
    ///   layout the user turned down does not come back as after a crash.
    /// - Once the state file is on disk, the previous file and any temporary file a cut-off save left are removed.
    /// - Then each pane's scrollback, in the order given, until `clock` passes `deadline`: what is left is dropped. Named
    ///   for the marker id at an update quit, for this launch's id at a quit under Resume. None with the tombstone.
    /// - Then, at an update quit, the marker, at `uptime` on the uptime clock. None without a boot session or with a version
    ///   it could not name, and none when the state file was not written: then nothing after it is either.
    /// - A clean quit and a marker written reset the restore attempts.
    public func finish(_ intent: QuitIntent, windows: [SessionSnapshot.Window], scrollback: [QuitScrollback] = [], now: Date = Date(),
                       uptime: TimeInterval = UpdateMarker.uptimeNow(), deadline: Date = .distantFuture,
                       clock: () -> Date = Date.init) -> QuitSave {
        writing.lock()
        defer { writing.unlock() }
        guard markFinished(), !isWaiting(at: now) else { return QuitSave() }
        var header = SessionSnapshot.Header(launchID: launchID, generation: nextGeneration(), clean: true, bootSession: bootSession,
                                            savedAt: now)
        switch intent {
        case .update(true, _, let to):
            header.clean = false
            header.awaitingMarker = UUID()
            header.pendingToVersion = to
        case .quit(true, let consent):
            header.resumeConsent = consent ? UUID() : nil
        case .update(false, _, _), .quit(false, _):
            break
        }
        let snapshot = SessionSnapshot(header: header, windows: intent.savesSession ? windows : [])
        guard write(snapshot, keepingPrevious: false).succeeded else {
            if !intent.savesSession { removeSession() }
            return QuitSave()
        }
        var quit = QuitSave(stateWritten: true, awaitedMarker: header.awaitingMarker, resumeConsent: header.resumeConsent)
        removeLeftovers()
        if intent.savesSession {
            quit.scrollback = saveScrollback(scrollback, quit: header.awaitingMarker ?? launchID, deadline: deadline, clock: clock)
        }
        if case .update(true, let from, let to) = intent, let id = header.awaitingMarker {
            quit.markerWritten = writeMarker(id: id, from: from, to: to, uptime: uptime)
        }
        if header.clean || quit.markerWritten {
            try? files.replace(RestoreAttempts.fileName, with: RestoreAttempts().data)
        }
        return quit
    }

    /// The windows as a save compares them: with each pane's state before and whether its work was cut off left out.
    static func persisted(_ windows: [SessionSnapshot.Window]) -> [SessionSnapshot.Window] {
        windows.map { (window: SessionSnapshot.Window) -> SessionSnapshot.Window in
            var compared = window
            compared.groups = window.groups.map { (group: SessionSnapshot.Group) -> SessionSnapshot.Group in
                var plain = group
                plain.root = group.root.mapPanes { (pane: SessionSnapshot.Pane) -> SessionSnapshot.Pane in
                    var quiet = pane
                    quiet.stateBefore = .unknown
                    quiet.interrupted = false
                    return quiet
                }
                return plain
            }
            return compared
        }
    }

    // MARK: writing

    private var isFinished: Bool {
        state.lock()
        defer { state.unlock() }
        return finished
    }

    /// True for the quit's save, false once it has run.
    private func markFinished() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    /// One more than the last, held at the cap: never past what decoding takes, never an overflow.
    private func nextGeneration() -> Int {
        generation = min(generation + 1, SessionSnapshot.Header.maxGeneration)
        return generation
    }

    /// Writes the state file, repaired and within the caps, and records the result. A file bigger than the cap is not
    /// written: no launch would read it.
    private func write(_ snapshot: SessionSnapshot, keepingPrevious: Bool) -> SaveResult {
        let left = snapshot.panesLeftOut(limits: limits)
        let limits = self.limits
        let previous = SessionFiles.Previous(maxSize: limits.bytes) { (data: Data) -> Bool in
            (try? SessionSnapshot.decode(data, limits: limits)) != nil
        }
        var succeeded = false
        if let data = try? snapshot.encoded(limits: limits), data.count <= limits.bytes {
            let kept: SessionFiles.Previous? = keepingPrevious ? previous : nil
            succeeded = (try? files.replace(SessionSnapshot.fileName(), with: data, keepingPrevious: kept)) != nil
        }
        let result = SaveResult(generation: snapshot.header.generation, savedAt: snapshot.header.savedAt, succeeded: succeeded,
                                panesLeftOut: left)
        state.lock()
        saved = result
        state.unlock()
        return result
    }

    /// The state file and the one before, when the tombstone could not take their place (a full disk, where removing
    /// still works): the layout the user turned down never comes back as after a crash.
    private func removeSession() {
        try? files.remove(SessionSnapshot.fileName())
        try? files.remove(SessionSnapshot.fileName() + SessionFiles.previousSuffix)
    }

    /// The previous state file and what cut-off saves left: once the quit's file is on disk, nothing lingers.
    private func removeLeftovers() {
        try? files.remove(SessionSnapshot.fileName() + SessionFiles.previousSuffix)
        _ = try? files.sweep()
    }

    private func saveScrollback(_ items: [QuitScrollback], quit: UUID, deadline: Date, clock: () -> Date) -> [UUID] {
        var written: [UUID] = []
        for item in items {
            guard clock() < deadline else { break }
            if ScrollbackText.save(item.text(), id: item.id, quit: quit, in: files) { written.append(item.id) }
        }
        return written
    }

    private func writeMarker(id: UUID, from: String, to: String, uptime: TimeInterval) -> Bool {
        guard let boot = UpdateMarker.bootToken(bootSession), let fromVersion = UpdateMarker.versionToken(from),
              let toVersion = UpdateMarker.versionToken(to), uptime.isFinite, uptime >= 0 else { return false }
        let marker = UpdateMarker(id: id, launchID: launchID, fromVersion: fromVersion, toVersion: toVersion, bootSession: boot,
                                  uptime: uptime)
        return (try? files.replace(UpdateMarker.fileName, with: marker.data)) != nil
    }
}
