import Foundation
import Testing
@testable import NextTermCore

@Suite struct PrivacySettingsTests {
    let places = ProtectedPlaces(home: "/Users/ada")

    /// The links open the panes themselves, as System Settings names them.
    @Test func theSettingsLinks() {
        #expect(PrivacySettings.url(.filesAndFolders).absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        #expect(PrivacySettings.url(.fullDiskAccess).absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        #expect(PrivacySettings.Pane.allCases.map(\.title) == ["Files and Folders", "Full Disk Access"])
    }

    /// A refused folder sends the user where a switch for it is: Files and Folders for Desktop, Documents, Downloads,
    /// iCloud Drive, cloud storage and the volumes; Full Disk Access for the rest of ~/Library, which has none there.
    @Test func whereARefusedFolderIsAllowed() {
        func pane(_ path: String) -> PrivacySettings.Pane { PrivacySettings.pane(forDenied: path, protected: places) }
        for path in ["/Users/ada/Desktop", "/Users/ada/Documents/site", "/Users/ada/Downloads/", "/Volumes/Backup",
                     "/Users/ada/Library/Mobile Documents/com~apple~CloudDocs", "/Users/ada/Library/CloudStorage/Dropbox",
                     "/Users/ada/Pictures"] {
            #expect(pane(path) == .filesAndFolders, "\(path)")
        }
        for path in ["/Users/ada/Library", "/Users/ada/Library/Mail", "/Users/ada/Library/Containers/com.apple.x"] {
            #expect(pane(path) == .fullDiskAccess, "\(path)")
        }
    }

    /// macOS's refusal is EPERM, given as is or under Foundation's "no permission to read"; EACCES is the folder's own
    /// permissions, and a refusal outside the protected places is not macOS's privacy protection either.
    @Test func whatCountsAsAPrivacyDenial() {
        func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        func cocoa(_ code: Int, under: NSError? = nil) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        func denial(_ error: Error, _ path: String = "/Users/ada/Documents") -> Bool {
            FolderAccess.isPrivacyDenial(error, path: path, protected: places)
        }
        #expect(denial(posix(EPERM)))
        #expect(denial(cocoa(NSFileReadNoPermissionError, under: posix(EPERM))))
        #expect(denial(cocoa(NSFileReadNoPermissionError))) // no code under it, in a protected place
        #expect(denial(cocoa(NSFileReadNoPermissionError, under: posix(EPERM)), "/Users/ada/Desktop/notes"))
        #expect(denial(posix(EPERM), "/Volumes/Backup"))
        #expect(!denial(posix(EACCES)))
        #expect(!denial(cocoa(NSFileReadNoPermissionError, under: posix(EACCES))))
        #expect(!denial(cocoa(NSFileReadNoSuchFileError, under: posix(ENOENT))))
        #expect(!denial(posix(EPERM), "/Users/ada/Code/app"))
        #expect(!denial(cocoa(NSFileReadNoPermissionError), "/Users/ada/Code/app"))
        #expect(FolderAccess.deniedLine == "macOS hasn’t given Next Term access to this folder.")
        #expect(FolderAccess.deniedHelp(folder: "Documents", pane: .filesAndFolders)
            == "macOS hasn’t given Next Term access to “Documents”. You can allow it in System Settings › Privacy & Security › Files and Folders.")
    }

    /// A folder the tree can't list for its own permissions (EACCES) is an empty folder, as before; the refused mark is
    /// for macOS's refusal only, and goes with the next read that works.
    @Test func aFoldersOwnPermissionsAreNoDenial() throws {
        let fixture = FixtureHome()
        fixture.write("Documents/letter.txt")
        let documents = URL(fileURLWithPath: fixture.path("Documents"))
        let node = FileNode(url: documents)
        #expect(node.install(FileNode.read(documents, protected: fixture.places)))
        #expect(!node.accessDenied && node.children?.map(\.name) == ["letter.txt"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path) }
        let refused = FileNode.read(documents, protected: fixture.places)
        #expect(!refused.denied && refused.nodes.isEmpty)
        // As macOS's refusal would be read: marked, then a read that works takes the mark away.
        #expect(node.install(FileNode.Listing(nodes: [], hidden: 0, denied: true)))
        #expect(node.accessDenied)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path)
        #expect(node.install(FileNode.read(documents, protected: fixture.places)))
        #expect(!node.accessDenied && node.children?.map(\.name) == ["letter.txt"])
    }
}
