import Foundation
import Testing
@testable import NextTermCore

/// The private folder an update's disk image waits in, made in a temporary folder of each test's own.
@Suite struct PrivateFolderTests {
    /// A parent folder for one test. Remove it after.
    func makeParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("nt-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }

    func mode(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    func isLink(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    @Test func eachIsANewFolderWithARandomNameThatOnlyThisUserCanReach() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let one = try PrivateFolder.make(in: parent, prefix: "NextTerm-update-")
        let two = try PrivateFolder.make(in: parent, prefix: "NextTerm-update-")
        #expect(one.url != two.url)
        #expect(one.url.lastPathComponent.hasPrefix("NextTerm-update-"))
        #expect(one.url.lastPathComponent.count > "NextTerm-update-".count + 16)
        #expect(one.url.deletingLastPathComponent().path == parent.path)
        #expect(mode(one.url.path) == 0o700)
        #expect(mode(two.url.path) == 0o700)
        let owner = try FileManager.default.attributesOfItem(atPath: one.url.path)[.ownerAccountID] as? NSNumber
        #expect(owner?.uint32Value == geteuid())
        #expect(PrivateFolder.isPrivate(one.url.path))
    }

    @Test func itGoesInTheTemporaryFolderUnlessToldOtherwise() throws {
        let folder = try PrivateFolder.make(prefix: "nt-private-test-")
        defer { folder.remove() }
        let parent: String = folder.url.deletingLastPathComponent().standardizedFileURL.path
        let temporary: String = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(parent == temporary)
        #expect(PrivateFolder.isPrivate(folder.url.path))
    }

    @Test func onlyARealFolderOfThisUsersThatNoOneElseCanReachIsPrivate() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(PrivateFolder.isPrivate(folder.path))
        // Another owner.
        #expect(!PrivateFolder.isPrivate(folder.path, owner: geteuid() + 1))
        #expect(!PrivateFolder.isPrivate(folder.path, owner: 0))
        // Others can enter, read or write.
        for loose in [0o755, 0o711, 0o701, 0o770, 0o707] {
            try FileManager.default.setAttributes([.posixPermissions: loose], ofItemAtPath: folder.path)
            #expect(!PrivateFolder.isPrivate(folder.path), "\(String(loose, radix: 8))")
        }
        // A file, a link to a private folder, and nothing at all.
        let file = parent.appendingPathComponent("file")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        #expect(!PrivateFolder.isPrivate(file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(!PrivateFolder.isPrivate(link.path))
        #expect(!PrivateFolder.isPrivate(parent.appendingPathComponent("missing").path))
    }

    @Test func aLinkPlantedAtItsNameIsRefusedAndNotFollowed() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // A link to a private folder of the user's: the folder it leads to is never taken for a new one.
        let elsewhere = parent.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let planted = parent.appendingPathComponent("NextTerm-update-planted")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try PrivateFolder.make(at: planted) }
        #expect(isLink(planted.path))
        // A link to nothing yet: no folder is made where it leads.
        let missing = parent.appendingPathComponent("missing")
        let dangling = parent.appendingPathComponent("NextTerm-update-dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        #expect(throws: (any Error).self) { try PrivateFolder.make(at: dangling) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(isLink(dangling.path))
    }

    @Test func aNameAlreadyTakenIsRefused() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Even a folder that would pass, with a file left in it: it was not made here.
        let taken = parent.appendingPathComponent("NextTerm-update-taken")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("old".utf8).write(to: taken.appendingPathComponent("NextTerm-update.dmg"))
        #expect(throws: (any Error).self) { try PrivateFolder.make(at: taken) }
        let file = parent.appendingPathComponent("NextTerm-update-file")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try PrivateFolder.make(at: file) }
    }

    @Test func removingItTakesWhatIsInIt() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = try PrivateFolder.make(in: parent, prefix: "NextTerm-update-")
        try Data("image".utf8).write(to: folder.url.appendingPathComponent("NextTerm-update.dmg"))
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("mount"), withIntermediateDirectories: false)
        folder.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
        // Removing it twice does nothing.
        folder.remove()
        let left: [String] = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(left.isEmpty, "\(left)")
    }
}
