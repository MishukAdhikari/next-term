import Foundation

/// Scrollback files in the sessions folder (R4, KTD9). Each pane's text is saved in a private file of its own, named for
/// the quit that saved it and for an id its record in the state file names (`SessionSnapshot.Pane.scrollback`). The id is
/// chosen at capture and passed in, so the state file, written first (KTD18), can name it before the file exists. At the
/// next launch only the restore of that quit reads them, each as untrusted, and every scrollback file is removed, read or
/// not.
extension ScrollbackText {
    public static let filePrefix = "scrollback-"

    /// The file a pane's scrollback is saved in at `quit`: the marker's id at an update quit, the snapshot's launch id at a
    /// quit under "Resume where I left off". Two UUIDs, so it can name nothing outside the sessions folder, whatever the
    /// snapshot says.
    public static func fileName(quit: UUID, id: UUID) -> String {
        filePrefix + quit.uuidString.lowercased() + "-" + id.uuidString.lowercased()
    }

    /// The quit and id a scrollback file is named for; nil for any other name.
    public static func parseFileName(_ name: String) -> (quit: UUID, id: UUID)? {
        guard name.hasPrefix(filePrefix) else { return nil }
        let ids = name.dropFirst(filePrefix.count)
        guard ids.utf8.count == 73, let quit = UUID(uuidString: String(ids.prefix(36))),
              let id = UUID(uuidString: String(ids.suffix(36))), fileName(quit: quit, id: id) == name else { return nil }
        return (quit, id)
    }

    /// Of the names in a sessions folder, the scrollback files to read, by id, and every scrollback file, each removed
    /// once read or unread: only those named for the restored `quit` are read (none without one), and only for an id the
    /// snapshot names.
    public static func sort(_ names: [String], quit: UUID?, ids: Set<UUID>) -> (read: [UUID: String], remove: [String]) {
        var read: [UUID: String] = [:]
        var remove: [String] = []
        for name in names where name.hasPrefix(filePrefix) {
            remove.append(name)
            guard let quit, let parsed = parseFileName(name), parsed.quit == quit, ids.contains(parsed.id) else { continue }
            read[parsed.id] = name
        }
        return (read, remove)
    }

    /// Saves `text` as the scrollback `id` names, for `quit`, as a new private file in the sessions folder. False when
    /// there was nothing to save, or it was not written (a file already at its name included).
    public static func save(_ text: String, id: UUID, quit: UUID, in files: SessionFiles) -> Bool {
        guard !text.isEmpty else { return false }
        do {
            try files.create(fileName(quit: quit, id: id), with: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    /// At the launch after: the saved scrollback of each of `ids` (those the snapshot's panes name), read only for the
    /// restored `quit`, as untrusted files no larger than `limits` allows. Every scrollback file in the folder is removed,
    /// read or not. Nil `quit`: none is read.
    public static func take(_ ids: Set<UUID>, quit: UUID?, from files: SessionFiles,
                            limits: Limits = .standard) -> [UUID: String] {
        guard let names = try? files.names() else { return [:] }
        let sorted = sort(names, quit: quit, ids: ids)
        var texts: [UUID: String] = [:]
        for (id, name) in sorted.read {
            guard let data = (try? files.read(name, maxSize: limits.bytes)) ?? nil else { continue }
            texts[id] = String(decoding: data, as: UTF8.self)
        }
        for name in sorted.remove { try? files.remove(name) }
        return texts
    }

    /// Removes every scrollback file unread: a launch that holds the folder and restores no quit (a crash restore, safe
    /// mode, a normal launch).
    public static func removeAll(from files: SessionFiles) {
        _ = take([], quit: nil, from: files)
    }
}
