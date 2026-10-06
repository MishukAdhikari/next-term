import AppKit
import NextTermCore
import SwiftDraw
import UniformTypeIdentifiers

/// File and folder icons: Material Icon Theme (open source, MIT; Resources/Icons, built by
/// scripts/update-icons.py), resolved by VS Code's rules, with framework files (Laravel, Next.js, Vite,
/// Docker…) getting their own. Drawn from SVG as vectors, so they stay sharp at any scale.
enum FileIcons {
    /// Contents/Resources/Icons in the app; the source tree's copy for `swift run`.
    private static let folder: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Icons"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/Icons"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.json").path) }
    }()

    static let theme: IconTheme? = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("theme.json")) }.flatMap(IconTheme.load)

    private static let svgs: [String: String] = folder
        .flatMap { try? Data(contentsOf: $0.appendingPathComponent("icons.json")) }
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

    private static var cache: [String: NSImage] = [:]

    /// A theme icon by name, as a vector image of `size` points.
    static func image(named name: String, size: CGFloat = 16) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = cache[key] { return cached }
        guard let xml = svgs[name], let svg = SVG(xml: xml) else { return nil }
        let image = NSImage(svg)
        image.size = NSSize(width: size, height: size)
        image.accessibilityDescription = name
        cache[key] = image
        return image
    }

    /// The sidebar's icon for a file or folder.
    static func image(for node: FileNode, expanded: Bool) -> NSImage {
        if let theme {
            let name: String
            if node.isDirectory {
                // Dot folders are configuration (.claude, .idea, .phpunit.cache): a quiet plain folder, so the
                // code folders (app, routes, tests) stand out. Settings can show their icons too.
                let quiet = node.name.hasPrefix(".") && node.parent != nil && !(AppDelegate.shared?.iconsOnDotFolders ?? false)
                name = quiet ? (expanded ? theme.folderExpanded : theme.folder)
                    : theme.icon(forFolder: node.name, parent: node.parent?.name, expanded: expanded, isRoot: node.parent == nil)
            } else {
                // A symlink gets its target's icon, so a link to a script does not pass for a document.
                let real = node.isSymlink ? node.url.resolvingSymlinksInPath() : node.url
                name = theme.icon(forFile: real.lastPathComponent, parent: node.url.deletingLastPathComponent().lastPathComponent,
                                  language: language(of: real))
            }
            if let image = image(named: name) { return image }
        }
        return systemIcon(for: node.url, isDirectory: node.isDirectory)
    }

    /// A deleted file or folder's icon, by its name alone (there is nothing on disk to look at).
    static func image(forDeleted name: String, parent: String?, isDirectory: Bool, expanded: Bool) -> NSImage {
        if let theme {
            let icon = isDirectory ? theme.icon(forFolder: name, parent: parent, expanded: expanded)
                : theme.icon(forFile: name, parent: parent)
            if let image = image(named: icon) { return image }
        }
        return systemIcon(for: URL(fileURLWithPath: "/" + name), isDirectory: isDirectory)
    }

    /// A file's icon by its name and folder (editor tabs, search results).
    static func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        if let theme {
            let name = theme.icon(forFile: url.lastPathComponent, parent: url.deletingLastPathComponent().lastPathComponent,
                                  language: language(of: url))
            if let image = image(named: name, size: size) { return image }
        }
        return systemIcon(for: url, isDirectory: false)
    }

    /// For files with no extension: `#!/usr/bin/env bash` and the like. Only regular files are read: opening
    /// a named pipe (common in /tmp) would wait for a writer forever.
    private static func language(of url: URL) -> String? {
        guard url.pathExtension.isEmpty else { return nil }
        guard isRegularFile(url.path), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 128)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return EditorLanguage.id(forFileName: url.lastPathComponent, firstLine: head.components(separatedBy: "\n").first ?? "")
    }

    /// Without the theme (a broken build): the system's icons.
    private static func systemIcon(for url: URL, isDirectory: Bool) -> NSImage {
        let key = isDirectory ? "/folder" : "." + url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }
}
