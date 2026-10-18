import Foundation

// A file the user picked for an import (Import From › A File…). Its links are followed first; then only a regular file
// is read, and only up to what its reader takes, so a huge file is refused before it is read. Nothing is ever written
// to it. A file the MCP-config import rewrites goes to that import, with its backup and Undo, and the keys outside its
// servers come back as a copy.

extension SecretSources {
    /// What a picked file is for.
    public enum Picked: Sendable {
        /// Keys to copy in, or why the file can't be read.
        case copy(SourceReport)
        /// One of the MCP-config import's own files: its servers go to that import, and `rest` holds the keys outside
        /// them, to copy in.
        case move(SecretImport.Source, rest: SourceReport)
    }

    /// The picked file at `path`, as picked (links not followed yet), read off the main thread: a move target
    /// (`moveSource`, with the open `projects`) or a file to copy from. `stored` names the keys in the vault, whose
    /// rows start unticked. `format` (`nxtrm secret import --from`) is the format a copy is read as.
    public static func readPicked(_ path: String, home: String = NSHomeDirectory(), projects: [String] = [],
                                  stored: Set<String> = [], format: Format? = nil, now: Date = Date()) -> Picked {
        let real: String = canonicalPath(path)
        // The path as given: a project's `.mcp.json` that links into a dotfiles folder is still that project's.
        if let source = moveSource(path: path, home: home, projects: projects) {
            switch fileBytes(atPath: real) {
            case .success(var bytes):
                return .move(source, rest: readOutsideServers(&bytes, of: source, stored: stored, now: now))
            case .failure(let reason):
                return .move(source, rest: unreadableReport(reason, path: real))
            }
        }
        return .copy(readFile(real, stored: stored, format: format, now: now))
    }

    /// The report for the file at `path` (links followed): its name and its folder's name make the purpose ("From .env
    /// in rag-api"). The bytes read are wiped once parsed. `format`, when given, is read instead of what `detect` says.
    public static func readFile(_ path: String, stored: Set<String> = [], format: Format? = nil,
                                now: Date = Date()) -> SourceReport {
        let real: String = canonicalPath(path)
        switch fileBytes(atPath: real) {
        case .success(var bytes):
            let (file, folder) = fileAndFolder(real)
            return read(&bytes, name: file, folder: folder, format: format, stored: stored, now: now)
        case .failure(let reason):
            return unreadableReport(reason, path: real)
        }
    }
}

extension SourceReport {
    /// The report with each row checked against the keys stored now: a row named as one starts unticked, "Replaces
    /// your key". For a copy that opens after the vault changed since the file was read, as the keys outside a move
    /// target's servers do once the move import has stored its own.
    public func checked(against stored: Set<String>) -> SourceReport {
        let marked: [SourceRow] = SecretSources.replacing(rows, stored: stored)
        return SourceReport(format: format, rows: marked, notKeys: notKeys, unlisted: unlisted, unreadable: unreadable,
                            purpose: purpose, exportedBy: exportedBy, agent: agent, fileNote: fileNote)
    }
}

extension SecretSources {
    static func fileAndFolder(_ path: String) -> (file: String, folder: String?) {
        let url = URL(fileURLWithPath: path)
        let folder: String = url.deletingLastPathComponent().lastPathComponent
        return (url.lastPathComponent, folder.isEmpty || folder == "/" ? nil : folder)
    }

    static func unreadableReport(_ reason: Unreadable, path: String) -> SourceReport {
        let (file, folder) = fileAndFolder(path)
        return SourceReport(format: detect(text: "", name: file), unreadable: reason,
                            purpose: purpose(file: file, folder: folder))
    }

    /// A regular file's bytes, opened without following a last link (the path is resolved already) and without
    /// waiting on a pipe. Over `maxBytes` it is read only when it is a zip archive (a 1Password export), up to
    /// `maxArchiveBytes`.
    static func fileBytes(atPath path: String) -> Result<[UInt8], Unreadable> {
        let descriptor: Int32 = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(errno == ELOOP ? .notAFile : .cantOpen) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.cantOpen) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        let size = Int(info.st_size)
        guard size <= maxArchiveBytes else { return .failure(.tooLarge) }
        if size > maxBytes {
            guard let head = readUpTo(descriptor, count: 4), ZipReader.isZip(head) else { return .failure(.tooLarge) }
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { return .failure(.cantOpen) }
        }
        guard let bytes = readUpTo(descriptor, count: size) else { return .failure(.cantOpen) }
        return .success(bytes)
    }

    /// Up to `count` bytes from `descriptor`, or nil on a read error. A file that grew since `fstat` is read only to
    /// `count`; one that shrank, to its end.
    static func readUpTo(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got: Int = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base + filled, count - filled)
            }
            if got < 0, errno == EINTR { continue }
            if got < 0 {
                SecretBytes.wipe(&bytes)
                return nil
            }
            if got == 0 { break }
            filled += got
        }
        if filled < count {
            let tail: Int = count - filled
            bytes.removeLast(tail)
        }
        return bytes
    }
}
