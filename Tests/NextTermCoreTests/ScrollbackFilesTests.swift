import Foundation
import Testing
@testable import NextTermCore

/// Scrollback files in the sessions folder (R4, KTD9): each saved under the id its pane's record names, chosen before the
/// file is written, read back only for the quit that is restored, and every one removed at the launch after, read or not.
/// What a planted hand puts at a scrollback file's name is never read.
@Suite struct ScrollbackFilesTests {
    static let marker = UUID(uuidString: "c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f")!
    static let launch = UUID(uuidString: "7d6c5b4a-3928-4716-a5b4-c3d2e1f0a9b8")!
    static let first = UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")!
    static let second = UUID(uuidString: "0f0e0d0c-0b0a-4908-8706-050403020100")!

    /// A sessions folder for a made-up app at /Users/x/Applications/Next Term.app, its lock taken, in a temporary folder
    /// of the test's own. Removed after `body`.
    func withFolder(_ body: (SessionFiles, String) throws -> Void) throws {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-scrollback-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let files = try SessionFiles.open(in: URL(fileURLWithPath: path), bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(files.lock())
        defer { files.unlock() }
        try body(files, path)
    }

    func scrollbackNames(_ files: SessionFiles) -> [String] {
        ((try? files.names()) ?? ["unreadable"]).filter { (name: String) -> Bool in name.hasPrefix(ScrollbackText.filePrefix) }
    }

    @Test func eachPanesTextIsSavedUnderTheIdItsRecordNames() throws {
        try withFolder { (files: SessionFiles, _: String) in
            // The id is the caller's, chosen at capture: the state file that names it is written before the file.
            #expect(ScrollbackText.save("old one\r\nold two", id: Self.first, quit: Self.marker, in: files))
            #expect(scrollbackNames(files) == [ScrollbackText.fileName(quit: Self.marker, id: Self.first)])
            // Nothing to save: no file.
            #expect(!ScrollbackText.save("", id: Self.second, quit: Self.marker, in: files))
            // A name already taken (a planted file there included) is not written through.
            #expect(!ScrollbackText.save("again", id: Self.first, quit: Self.marker, in: files))
            #expect(ScrollbackText.take([Self.first], quit: Self.marker, from: files) == [Self.first: "old one\r\nold two"])
            #expect(scrollbackNames(files).isEmpty)
        }
    }

    @Test func aQuitRestoreReadsTheFilesNamedForItsSnapshotsLaunch() throws {
        try withFolder { (files: SessionFiles, _: String) in
            #expect(ScrollbackText.save("from the update", id: Self.first, quit: Self.marker, in: files))
            #expect(ScrollbackText.save("from the quit", id: Self.second, quit: Self.launch, in: files))
            let texts = ScrollbackText.take([Self.first, Self.second], quit: Self.launch, from: files)
            #expect(texts == [Self.second: "from the quit"])
            #expect(scrollbackNames(files).isEmpty)
            // A launch that restores no quit removes them all unread.
            #expect(ScrollbackText.save("unread", id: Self.first, quit: Self.launch, in: files))
            ScrollbackText.removeAll(from: files)
            #expect(scrollbackNames(files).isEmpty)
        }
    }

    @Test func aPlantedLinkAHardLinkOrAnOversizedFileIsNotReadAndIsRemoved() throws {
        try withFolder { (files: SessionFiles, folder: String) in
            let outside = folder + "-outside.txt"
            try Data("secret elsewhere".utf8).write(to: URL(fileURLWithPath: outside))
            defer { try? FileManager.default.removeItem(atPath: outside) }
            let linked = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
            let hardLinked = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
            let oversized = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
            let at = { (id: UUID) -> String in files.url.path + "/" + ScrollbackText.fileName(quit: Self.marker, id: id) }
            // Private, so only its second name is wrong with the hard link.
            #expect(chmod(outside, 0o600) == 0)
            #expect(symlink(outside, at(linked)) == 0)
            #expect(link(outside, at(hardLinked)) == 0)
            // One byte over the 512 KB a pane keeps.
            let over = Data(repeating: 0x61, count: ScrollbackText.Limits.standard.bytes + 1)
            #expect(FileManager.default.createFile(atPath: at(oversized), contents: over, attributes: [.posixPermissions: 0o600]))
            #expect(ScrollbackText.save("kept", id: Self.first, quit: Self.marker, in: files))
            let texts = ScrollbackText.take([linked, hardLinked, oversized, Self.first], quit: Self.marker, from: files)
            #expect(texts == [Self.first: "kept"])
            #expect(scrollbackNames(files).isEmpty)
            // The link went, not what it pointed at.
            #expect(FileManager.default.contents(atPath: outside) == Data("secret elsewhere".utf8))
        }
    }
}
