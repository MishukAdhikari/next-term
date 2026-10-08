import Foundation
import Testing
@testable import NextTermCore

@Suite struct SafeWriteTests {
    func folder() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-safe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func put(_ text: String, _ path: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }

    func mode(_ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    func names(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

    func failure(_ body: () throws -> Void) -> SafeWrite.Failure? {
        do {
            try body()
            return nil
        } catch {
            return error as? SafeWrite.Failure
        }
    }

    @Test func keepsTheFilesPermissions() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for wanted in [0o600, 0o640, 0o644, 0o755, 0o700] {
            let file = dir + "/file-\(String(wanted, radix: 8))"
            try put("before\n", file, mode: wanted)
            try SafeWrite.replace(file, with: Data("after\n".utf8))
            #expect(read(file) == "after\n" && mode(file) == wanted, "\(String(wanted, radix: 8))")
        }
        // A new file is its owner's alone unless the caller says otherwise.
        try SafeWrite.replace(dir + "/new", with: Data("x".utf8))
        try SafeWrite.replace(dir + "/shared", with: Data("x".utf8), newFileMode: 0o644)
        #expect(mode(dir + "/new") == 0o600 && mode(dir + "/shared") == Int(0o644 & ~SafeWrite.umask))
        // Nothing but the files themselves.
        #expect(names(dir).allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func aNewFileIsNeverMoreOpenThanTheUmask() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var system = SafeWrite.System()
        system.umask = 0o077
        try SafeWrite.replace(dir + "/skills-lock.json", with: Data("{}".utf8), expecting: .noFile, newFileMode: 0o644, system: system)
        system.umask = 0o022
        try SafeWrite.replace(dir + "/notes.txt", with: Data("x".utf8), expecting: .anything, newFileMode: 0o644, system: system)
        system.umask = 0o002
        try SafeWrite.replace(dir + "/private", with: Data("x".utf8), expecting: .anything, newFileMode: 0o600, system: system)
        #expect(mode(dir + "/skills-lock.json") == 0o600 && mode(dir + "/notes.txt") == 0o644 && mode(dir + "/private") == 0o600)
        // A file that is there keeps its own permissions, whatever the umask.
        try put("x", dir + "/shared.txt", mode: 0o664)
        system.umask = 0o077
        try SafeWrite.replace(dir + "/shared.txt", with: Data("y".utf8), expecting: .anything, newFileMode: 0o600, system: system)
        #expect(mode(dir + "/shared.txt") == 0o664)
        // The umask read is this process's, as `open` applies it.
        let probe = dir + "/probe"
        close(open(probe, O_CREAT | O_WRONLY, 0o666))
        #expect(mode(probe) == Int(0o666 & ~SafeWrite.umask))
    }

    @Test func theTemporaryFileIsPrivateUntilItHasTheFilesPermissions() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/.env"
        try put("TOKEN=made-up\n", file, mode: 0o600)
        var seen: (mode: mode_t, text: String?)?
        var system = SafeWrite.System()
        system.beforeRename = { temporary in
            var info = stat()
            if lstat(temporary, &info) == 0 { seen = (info.st_mode & 0o7777, self.read(temporary)) }
        }
        try SafeWrite.replace(file, with: Data("TOKEN=other\n".utf8), expecting: .anything, newFileMode: 0o600, system: system)
        #expect(seen?.mode == 0o600 && seen?.text == "TOKEN=other\n")
        #expect(read(file) == "TOKEN=other\n" && mode(file) == 0o600 && names(dir) == [".env"])
    }

    @Test func throughALinkTheLinkStays() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/dotfiles", withIntermediateDirectories: true)
        let real = dir + "/dotfiles/settings.json"
        let link = dir + "/settings.json"
        try put("{}\n", real, mode: 0o600)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try SafeWrite.replace(link, with: Data("{\"a\": 1}\n".utf8), expecting: .contents(Data("{}\n".utf8)))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(read(real) == "{\"a\": 1}\n" && mode(real) == 0o600)
        #expect(names(dir + "/dotfiles") == ["settings.json"] && names(dir) == ["dotfiles", "settings.json"])
        // A link to a file that is not there stays a link to nothing: a file would take its place.
        let dangling = dir + "/gone.json"
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: dir + "/unmounted/settings.json")
        #expect(failure { try SafeWrite.replace(dangling, with: Data("{}".utf8)) } == .notAFile)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling) == dir + "/unmounted/settings.json")
    }

    @Test func aReadOnlyFileIsLeftAlone() throws {
        let dir = try folder()
        defer {
            chmod(dir, 0o755)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let file = dir + "/locked.txt"
        try put("keep\n", file, mode: 0o444)
        #expect(failure { try SafeWrite.replace(file, with: Data("lost\n".utf8)) } == .readOnly)
        #expect(read(file) == "keep\n" && mode(file) == 0o444 && names(dir) == ["locked.txt"])
        // A folder it can't write in: the temporary file can't be made, and the file stays.
        try put("keep\n", dir + "/open.txt")
        chmod(dir, 0o555)
        let folderFailure = failure { try SafeWrite.replace(dir + "/open.txt", with: Data("lost\n".utf8)) }
        chmod(dir, 0o755)
        #expect(folderFailure == .system(EACCES))
        #expect(folderFailure?.errorDescription == "You don’t have permission to write in its folder.")
        #expect(read(dir + "/open.txt") == "keep\n" && names(dir) == ["locked.txt", "open.txt"])
        // Not a plain file.
        try FileManager.default.createDirectory(atPath: dir + "/folder", withIntermediateDirectories: true)
        #expect(failure { try SafeWrite.replace(dir + "/folder", with: Data("x".utf8)) } == .notAFile)
    }

    @Test func aFileChangedSinceItWasReadIsLeftAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/settings.json"
        try put("{\"theme\": \"light\"}\n", file)
        let read = Data("{\"theme\": \"light\"}\n".utf8)
        // Already changed when the write starts.
        try put("{\"theme\": \"dark\"}\n", file)
        #expect(failure { try SafeWrite.replace(file, with: Data("{}\n".utf8), expecting: .contents(read)) } == .changed)
        #expect(self.read(file) == "{\"theme\": \"dark\"}\n" && names(dir) == ["settings.json"])
        // Saved by its program while the write is under way: after the temporary file is ready, before the rename.
        try put("{\"theme\": \"light\"}\n", file)
        var system = SafeWrite.System()
        system.beforeRename = { _ in try? self.put("{\"theme\": \"dark\"}\n", file) }
        let changed = failure {
            try SafeWrite.replace(file, with: Data("{}\n".utf8), expecting: .contents(read), newFileMode: 0o600, system: system)
        }
        #expect(changed == .changed && self.read(file) == "{\"theme\": \"dark\"}\n" && names(dir) == ["settings.json"])
        // A file that turns up where there was none.
        system.beforeRename = { _ in try? self.put("theirs\n", dir + "/new.json") }
        let appeared = failure {
            try SafeWrite.replace(dir + "/new.json", with: Data("ours\n".utf8), expecting: .noFile, newFileMode: 0o600, system: system)
        }
        #expect(appeared == .changed && self.read(dir + "/new.json") == "theirs\n")
        #expect(failure { try SafeWrite.replace(dir + "/new.json", with: Data("ours\n".utf8), expecting: .noFile) } == .changed)
        #expect(names(dir) == ["new.json", "settings.json"])
        // As expected: written.
        try SafeWrite.replace(file, with: Data("{}\n".utf8), expecting: .contents(Data("{\"theme\": \"dark\"}\n".utf8)))
        #expect(self.read(file) == "{}\n")
    }

    @Test func nothingIsLeftBehindWhateverFails() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/notes.txt"
        try put("before\n", file, mode: 0o640)
        func fail(_ make: (inout SafeWrite.System) -> Void) -> SafeWrite.Failure? {
            var system = SafeWrite.System()
            make(&system)
            return failure {
                try SafeWrite.replace(file, with: Data(String(repeating: "after\n", count: 50_000).utf8), expecting: .anything,
                                      newFileMode: 0o600, system: system)
            }
        }
        // The disk fills up part way.
        var calls = 0
        let full = fail { system in
            system.write = { descriptor, bytes, count in
                calls += 1
                guard calls == 1 else {
                    errno = ENOSPC
                    return -1
                }
                return Darwin.write(descriptor, bytes, min(count, 4096))
            }
        }
        #expect(full == .system(ENOSPC) && full?.errorDescription == "The disk is full.")
        #expect(read(file) == "before\n" && mode(file) == 0o640 && names(dir) == ["notes.txt"])
        // A write that makes no progress.
        #expect(fail { $0.write = { _, _, _ in 0 } } == .system(EIO))
        #expect(names(dir) == ["notes.txt"])
        // Interrupted, then done: written whole.
        var interrupted = false
        #expect(fail { system in
            system.write = { descriptor, bytes, count in
                if !interrupted {
                    interrupted = true
                    errno = EINTR
                    return -1
                }
                return Darwin.write(descriptor, bytes, count)
            }
        } == nil)
        #expect(read(file) == String(repeating: "after\n", count: 50_000) && mode(file) == 0o640)
        try put("before\n", file, mode: 0o640)
        // The flush to disk fails.
        #expect(fail { $0.fsync = { _ in
            errno = EIO
            return -1
        } } == .system(EIO))
        #expect(read(file) == "before\n" && names(dir) == ["notes.txt"])
        // The rename fails.
        #expect(fail { $0.rename = { _, _ in
            errno = EXDEV
            return -1
        } } == .system(EXDEV))
        #expect(read(file) == "before\n" && names(dir) == ["notes.txt"])
        // Changed meanwhile.
        #expect(fail { system in system.beforeRename = { _ in try? self.put("theirs\n", file) } } == nil) // .anything: replaced
        try put("before\n", file, mode: 0o640)
        var system = SafeWrite.System()
        system.beforeRename = { _ in try? self.put("theirs\n", file) }
        let changed = failure {
            try SafeWrite.replace(file, with: Data("after\n".utf8), expecting: .contents(Data("before\n".utf8)), newFileMode: 0o600, system: system)
        }
        #expect(changed == .changed && read(file) == "theirs\n" && names(dir) == ["notes.txt"])
    }

    @Test func aVolumeWithoutExclusiveRenamesStillGetsANewFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/config.json"
        func create(_ exclusiveRename: @escaping (String, String) -> Int32) -> SafeWrite.Failure? {
            var system = SafeWrite.System()
            system.exclusiveRename = exclusiveRename
            return failure { try SafeWrite.replace(file, with: Data("{}\n".utf8), expecting: .noFile, newFileMode: 0o600, system: system) }
        }
        // exFAT has no exclusive rename (ENOTSUP); a volume may also refuse the flag (EINVAL).
        for code in [ENOTSUP, EINVAL] {
            #expect(create { _, _ in
                errno = code
                return -1
            } == nil)
            #expect(read(file) == "{}\n" && mode(file) == 0o600 && names(dir) == ["config.json"])
            try FileManager.default.removeItem(atPath: file)
        }
        // A file that turns up meanwhile stays as it is.
        let appeared = create { _, target in
            try? "theirs\n".write(toFile: target, atomically: false, encoding: .utf8)
            errno = ENOTSUP
            return -1
        }
        #expect(appeared == .changed && read(file) == "theirs\n" && names(dir) == ["config.json"])
        try FileManager.default.removeItem(atPath: file)
        // Any other error is a failed write, with nothing left behind.
        #expect(create { _, _ in
            errno = EIO
            return -1
        } == .system(EIO))
        #expect(names(dir).isEmpty)
        // The real thing, on this Mac's volume.
        #expect(create { renamex_np($0, $1, UInt32(RENAME_EXCL)) } == nil)
        #expect(read(file) == "{}\n")
    }

    @Test func extendedAttributesStay() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/tagged.md"
        try put("# notes\n", file)
        let value = Array("kept".utf8)
        #expect(setxattr(file, "me.mishuk.nextterm.test", value, value.count, 0, 0) == 0)
        try SafeWrite.replace(file, with: Data("# notes, edited\n".utf8))
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(file, "me.mishuk.nextterm.test", &buffer, buffer.count, 0, 0)
        #expect(size == value.count && Array(buffer.prefix(max(size, 0))) == value)
        #expect(read(file) == "# notes, edited\n")
    }

    @Test func editorSavesGoThroughIt() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = URL(fileURLWithPath: dir + "/.env")
        try put("A=1\n", env.path, mode: 0o600)
        try TextFile.write(Data("A=2\n".utf8), to: env)
        #expect(read(env.path) == "A=2\n" && mode(env.path) == 0o600 && names(dir) == [".env"])
        // A file deleted on disk and saved again from the editor comes back as files are made.
        try TextFile.write(Data("x\n".utf8), to: URL(fileURLWithPath: dir + "/again.txt"))
        #expect(mode(dir + "/again.txt") == Int(0o644 & ~SafeWrite.umask))
        try put("keep\n", dir + "/locked.txt", mode: 0o444)
        #expect(throws: SafeWrite.Failure.readOnly) { try TextFile.write(Data("lost\n".utf8), to: URL(fileURLWithPath: dir + "/locked.txt")) }
    }
}
