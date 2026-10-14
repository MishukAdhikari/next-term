import Foundation

/// System Settings › Privacy & Security, where the user gives Next Term a folder macOS refused it, or every folder at once.
/// Next Term opens these panes only when the user clicks for them; it never asks for access by itself.
public enum PrivacySettings {
    /// The panes Next Term can open.
    public enum Pane: String, Sendable, CaseIterable {
        /// Files and Folders: Desktop, Documents, Downloads, iCloud Drive, cloud storage, removable and network volumes.
        case filesAndFolders = "Privacy_FilesAndFolders"
        /// Full Disk Access: every folder, with no prompts, for the user who wants that.
        case fullDiskAccess = "Privacy_AllFiles"

        /// The pane's name as System Settings shows it.
        public var title: String {
            switch self {
            case .filesAndFolders: return "Files and Folders"
            case .fullDiskAccess: return "Full Disk Access"
            }
        }
    }

    /// The link that opens `pane` in System Settings, on macOS 13 and later.
    public static func url(_ pane: Pane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane.rawValue)!
    }

    /// Where the user can let Next Term into `path` after macOS refused it. Files and Folders has a switch for the places
    /// it lists: Desktop, Documents, Downloads, iCloud Drive, cloud storage, and the volumes. The Trash and the rest of
    /// ~/Library (Mail, Safari, other apps' data) have none there: only Full Disk Access opens them.
    public static func pane(forDenied path: String, protected: ProtectedPlaces = .current) -> Pane {
        let path: String = ProtectedPlaces.trimmed(path)
        let trash: String = protected.home + "/.Trash"
        if path == trash || path.hasPrefix(trash + "/") { return .fullDiskAccess }
        let library: String = protected.home + "/Library"
        let inLibrary: Bool = path == library || path.hasPrefix(library + "/")
        guard inLibrary else { return .filesAndFolders }
        let listed: [String] = [library + "/Mobile Documents", library + "/CloudStorage"]
        let switchable: Bool = listed.contains { (place: String) -> Bool in path == place || path.hasPrefix(place + "/") }
        return switchable ? .filesAndFolders : .fullDiskAccess
    }
}

/// Why a folder the user asked to see could not be listed.
public enum FolderAccess {
    /// macOS's privacy protection refused `path`, a protected place or a folder in one (ProtectedPlaces): the user said
    /// Don't Allow, or turned it off. Its mark is EPERM ("Operation not permitted"), given as is or under Foundation's
    /// "no permission to read" (NSFileReadNoPermissionError). EACCES ("Permission denied") is the folder's own
    /// permissions, which System Settings can't change, so it is not one; nor is a refusal outside the protected places.
    public static func isPrivacyDenial(_ error: Error, path: String, protected: ProtectedPlaces = .current) -> Bool {
        guard protected.holds(path) else { return false }
        let error = error as NSError
        if let code = posixCode(of: error) { return code == EPERM }
        // No POSIX code under it: Foundation's own refusal, in a place macOS guards, is taken for macOS's.
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
    }

    /// The POSIX code an error carries, itself or under it.
    static func posixCode(of error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return posixCode(of: underlying)
    }

    /// The row's line in a folder macOS refused: plain, one line.
    public static let deniedLine = "macOS hasn’t given Next Term access to this folder."

    /// The row's tooltip and what VoiceOver reads: the line, and where to change it.
    public static func deniedHelp(folder name: String, pane: PrivacySettings.Pane) -> String {
        "macOS hasn’t given Next Term access to “\(name)”. You can allow it in System Settings › Privacy & Security › \(pane.title)."
    }
}
