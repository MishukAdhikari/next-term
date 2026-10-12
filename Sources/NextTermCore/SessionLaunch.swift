import Foundation

/// The launch hook's reads and writes in the sessions folder (KTD13, KTD14), around the restore step's decision
/// (`LaunchDecision.restoring`). In order:
/// 1. the restore attempts counter is raised and written whole, before anything else is read, so a restore that crashes
///    has counted already;
/// 2. the record of used ids, the marker (claimed by an exclusive rename), the snapshot, and the install script's result,
///    which is read once and removed;
/// 3. once the decision is made, what it consumes is recorded, and only then is the claimed marker removed (`record`).
/// A snapshot set aside after three restores that did not finish goes out of the way (`setAside`). Every file is read as
/// untrusted, through `SessionFiles`.
public enum SessionLaunch {
    /// Where a snapshot set aside goes, in the sessions folder: no launch reads it as a state file again, and the next one
    /// set aside takes its place.
    public static let setAsideName = "set-aside-state.json"

    /// What the launch found, for the restore step and for the restore after it.
    public struct Found: Sendable {
        public var facts: RestoreFacts
        /// The snapshot, repaired; nil when neither the state file nor its previous file reads.
        public var snapshot: SessionSnapshot?

        public init(facts: RestoreFacts, snapshot: SessionSnapshot?) {
            self.facts = facts
            self.snapshot = snapshot
        }
    }

    /// The sessions folder in `parent` this launch takes, its lock held (KTD12):
    /// - none for a translocated copy (`isTranslocated`), which runs from a new random path each launch, so nothing it
    ///   saved would ever be read or removed;
    /// - the folder the install script names with `InstallScript.folderKeyArgument` when it opens the old app from its
    ///   backup, once `LaunchDecision.acceptsBackupOpen` takes it: a folder there already, whose app is gone, holding the
    ///   result that says so for the marker its snapshot waits for. Its result stays for `read`;
    /// - else the app's own, made when it is not there.
    /// Nil when another Next Term holds the folder, or it cannot be made private. `exists` is for the tests.
    public static func takeFolder(in parent: URL, bundlePath: String, arguments: [String],
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> SessionFiles? {
        guard !isTranslocated(bundlePath: bundlePath) else { return nil }
        if let key = backupKey(in: arguments), let files = backupFolder(in: parent, key: key, exists: exists) { return files }
        guard let files = try? SessionFiles.open(in: parent, bundlePath: bundlePath), files.lock() else { return nil }
        return files
    }

    /// Whether the app at `bundlePath` runs from a translocated copy, which the next launch will not find again.
    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// The folder key the install script passed, or nil when it passed none.
    static func backupKey(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: InstallScript.folderKeyArgument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The folder `key` names, locked, when the backup-open check takes it; otherwise it is left as it was. A key never
    /// makes a folder.
    private static func backupFolder(in parent: URL, key: String, exists: (String) -> Bool) -> SessionFiles? {
        guard SessionFiles.isKey(key) else { return nil }
        let url = parent.appendingPathComponent(SessionFiles.folderName(key: key), isDirectory: true)
        guard PrivateFolder.isPrivate(url.path), let files = try? SessionFiles.open(in: parent, key: key), files.lock() else { return nil }
        let data: Data? = (try? files.read(InstallResult.fileName, maxSize: InstallResult.maxSize)) ?? nil
        let result: InstallResult? = data.flatMap(InstallResult.parse)
        let awaiting: UUID? = SessionWriter.load(from: files)?.header.awaitingMarker
        let recorded = SessionFiles.recordedBundlePath(in: files.url)
        guard LaunchDecision.acceptsBackupOpen(key: key, recordedBundlePath: recorded, result: result, awaitingMarker: awaiting,
                                               exists: exists) else {
            files.unlock()
            return nil
        }
        return files
    }

    /// The facts the restore step decides on, read from `files`, whose lock this process holds. `resumesAtLaunch`:
    /// Settings › General's "At launch" reads "Resume where I left off".
    public static func read(_ files: SessionFiles, version: String, resumesAtLaunch: Bool,
                            uptime: TimeInterval = UpdateMarker.uptimeNow(),
                            bootSession: String? = UpdateMarker.currentBootSession()) -> Found {
        let attempts = current(in: files).after(.launch)
        let written = (try? files.replace(RestoreAttempts.fileName, with: attempts.data)) != nil
        var consumed = consumedRecord(in: files)
        let marker = UpdateMarker.claim(in: files, consumed: &consumed)
        let snapshot = SessionWriter.load(from: files)
        let result = installResult(in: files)
        var facts = RestoreFacts(lockTaken: true, marker: marker, header: snapshot?.header, windows: snapshot?.windows.count ?? 0,
                                 consumed: consumed, attempts: attempts, attemptsWritten: written, uptime: uptime,
                                 bootSession: bootSession, version: version, installResult: result)
        facts.resumesAtLaunch = resumesAtLaunch
        return Found(facts: facts, snapshot: snapshot)
    }

    /// Records the ids `decision` consumes, added to `consumed` (the record as read; one that did not read is replaced
    /// by these alone), then removes the claimed marker. False when the record could not be written: a quit consent is
    /// then not used, and the claimed marker stays for the next claim to use up.
    public static func record(_ decision: RestoreDecision, consumed: ConsumedMarkers?, in files: SessionFiles) -> Bool {
        guard !decision.consumes.isEmpty else {
            try? files.remove(UpdateMarker.claimedName)
            return true
        }
        let start: ConsumedMarkers = consumed ?? ConsumedMarkers()
        let record = decision.consumes.reduce(start) { (record: ConsumedMarkers, id: UUID) -> ConsumedMarkers in record.adding(id) }
        guard (try? files.replace(ConsumedMarkers.fileName, with: record.data)) != nil else { return false }
        try? files.remove(UpdateMarker.claimedName)
        return true
    }

    /// Sets the snapshot aside: the state file moves to `setAsideName`, in place of one set aside before, and its previous
    /// file is removed, so no launch restores it again. The name it went to, or nil when there was none or it could not be
    /// moved.
    public static func setAside(in files: SessionFiles) -> String? {
        let state = SessionSnapshot.fileName()
        try? files.remove(setAsideName)
        guard (try? files.claim(state, as: setAsideName)) == true else { return nil }
        try? files.remove(state + SessionFiles.previousSuffix)
        return setAsideName
    }

    /// Moves the counter on by `event` and writes it: the counter after, or nil when it could not be written.
    @discardableResult
    public static func count(_ event: RestoreAttempts.Event, in files: SessionFiles) -> RestoreAttempts? {
        let next = current(in: files).after(event)
        guard (try? files.replace(RestoreAttempts.fileName, with: next.data)) != nil else { return nil }
        return next
    }

    /// The counter as written: none written is a fresh one, and one there that does not read is `RestoreAttempts.unread`.
    static func current(in files: SessionFiles) -> RestoreAttempts {
        do {
            guard let data = try files.read(RestoreAttempts.fileName, maxSize: RestoreAttempts.maxSize) else { return RestoreAttempts() }
            return RestoreAttempts.parse(data)
        } catch {
            return RestoreAttempts.unread
        }
    }

    /// The record of used ids: an empty one when there is none, nil when one is there and does not read.
    static func consumedRecord(in files: SessionFiles) -> ConsumedMarkers? {
        do {
            guard let data = try files.read(ConsumedMarkers.fileName, maxSize: ConsumedMarkers.maxSize) else { return ConsumedMarkers() }
            return ConsumedMarkers.parse(data)
        } catch {
            return nil
        }
    }

    /// The install script's result, read once: it is removed whether it reads or not.
    static func installResult(in files: SessionFiles) -> InstallResult? {
        let data: Data? = (try? files.read(InstallResult.fileName, maxSize: InstallResult.maxSize)) ?? nil
        try? files.remove(InstallResult.fileName)
        return data.flatMap(InstallResult.parse)
    }
}
