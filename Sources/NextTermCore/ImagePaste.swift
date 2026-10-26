import Darwin
import Foundation

/// What ⌘V pastes in a terminal tab, from what the clipboard holds.
public enum PasteContent: Equatable, Sendable {
    /// Files Finder copied: their full paths, as a drop gives them.
    case files
    case text
    /// An image alone, a screenshot copied to the clipboard.
    case image
    case nothing

    /// Files when the clipboard has them and any text on it only names them (Finder writes each file's name as text
    /// beside it); else text; else an image alone. Text an app put beside a file it means to paste is pasted as text.
    public static func choose(files: [String], text: String?, image: Bool) -> PasteContent {
        let words: String = text ?? ""
        if !files.isEmpty, words.isEmpty || namesOnly(words, files) { return .files }
        if !words.isEmpty { return .text }
        return image ? .image : .nothing
    }

    /// Whether every line of `text` is one of `files`' names or paths.
    static func namesOnly(_ text: String, _ files: [String]) -> Bool {
        let known = Set(files + files.map { ($0 as NSString).lastPathComponent })
        let lines: [String] = text.split(whereSeparator: \.isNewline).map(String.init)
        return !lines.isEmpty && lines.allSatisfy { known.contains($0) }
    }
}

/// How ⌘V hands an image alone to the program in a tab.
public enum ImagePaste: Equatable, Sendable {
    /// The agent takes an image on ⌃V and reads it from the clipboard itself: the tab gets the ⌃V its own key sends.
    case controlV
    /// Kept as a PNG in a new folder only this user can read, and its quoted path pasted: a shell, an editor, an agent
    /// that takes images by path.
    case path
    /// A tab on a server: copied there first, its path there pasted (RemoteDrop).
    case copyToServer
    /// A tab logged in to another machine by hand (ssh): the image is on this Mac, so nothing is pasted.
    case elsewhere

    /// The agents that read an image from the clipboard on ⌃V, as each documents it. Copilot CLI's ⌃V pastes raw data
    /// (copilot-cli #4013), so it gets a path, as every other program does.
    public static let controlVAgents: Set<AgentKind> = [.claude, .codex, .commandCode, .gemini, .qwen, .opencode, .cursor]
    /// Programs that log in to another machine: a path on this Mac means nothing there.
    public static let remoteLogins: Set<String> = ["ssh", "mosh", "mosh-client", "autossh", "et"]

    /// The way for a tab: on a server, or local with `agent` running, or `program` in front (nil at the prompt).
    public static func way(remote: Bool, agent: AgentKind?, program: String?) -> ImagePaste {
        if remote { return .copyToServer }
        if let agent, controlVAgents.contains(agent) { return .controlV }
        if let program, remoteLogins.contains((program as NSString).lastPathComponent) { return .elsewhere }
        return .path
    }

    /// Where pasted images are kept, in the temporary folder: one private folder each, named `prefix` and more.
    public static let parentName = "next-term-paste"
    public static var parent: URL { FileManager.default.temporaryDirectory.appendingPathComponent(parentName, isDirectory: true) }
    public static let prefix = "image-"
    /// How long a kept image stays: the launch after this removes it.
    public static let kept: TimeInterval = 24 * 60 * 60

    /// `png` written as `pasted-<time>.png` in a new private folder in `parent`: the file made 0600, never over a file or
    /// through a link already at its name.
    public static func keep(_ png: Data, in parent: URL, at date: Date) throws -> URL {
        let folder = try PrivateFolder.make(in: parent, prefix: prefix)
        let file = folder.url.appendingPathComponent(RemoteUpload.imageName(at: date))
        let descriptor: Int32 = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.path]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: png)
        try handle.close()
        return file
    }

    /// The pasted images kept longer than `kept`, from earlier launches: removed as Next Term starts.
    public static func removeOld(in parent: URL, now: Date) {
        for folder in PrivateFolder.leftovers(in: parent, prefix: prefix, madeBefore: now.addingTimeInterval(-kept)) { folder.remove() }
    }
}
