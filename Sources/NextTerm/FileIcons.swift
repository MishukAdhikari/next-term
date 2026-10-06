import AppKit
import NextTermCore
import UniformTypeIdentifiers

/// Icons for the project tree. One place to swap the icon set.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for node: FileNode, expanded: Bool) -> NSImage {
        // A symlink gets its target's icon, so a link to a script does not pass for a document.
        let real = node.isSymlink ? node.url.resolvingSymlinksInPath() : node.url
        let key = node.isDirectory ? "/folder" : real.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }

    /// A file's icon by its extension (editor tabs).
    static func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        let key = url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }
}
