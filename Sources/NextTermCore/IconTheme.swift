import Foundation

/// A VS Code file-icon theme (Material Icon Theme), resolved the way VS Code resolves it: by exact file
/// name (with its parent folder first), then by extension from the longest compound one down
/// (`blade.php` before `php`, again parent first), then by language, else the default.
public struct IconTheme: Decodable, Sendable {
    public let file: String
    public let folder: String
    public let folderExpanded: String
    public let rootFolder: String
    public let rootFolderExpanded: String
    let fileNames: [String: String]
    let fileExtensions: [String: String]
    let folderNames: [String: String]
    let folderNamesExpanded: [String: String]
    let languageIds: [String: String]

    public static func load(_ data: Data) -> IconTheme? {
        try? JSONDecoder().decode(IconTheme.self, from: data)
    }

    /// Next Term's language ids that VS Code names differently.
    static let vscodeLanguage = ["docker": "dockerfile", "make": "makefile", "jsx": "javascriptreact", "tsx": "typescriptreact"]

    /// The icon for a file. `parent` is the folder it is in (its name only); `language` is the editor's
    /// language id, used only when nothing else matches (files with no extension, scripts).
    public func icon(forFile name: String, parent: String? = nil, language: String? = nil) -> String {
        let name = name.lowercased()
        let parent = parent?.lowercased()
        func lookup(_ table: [String: String], _ key: String) -> String? {
            if let parent, let hit = table[parent + "/" + key] { return hit }
            return table[key]
        }
        if let hit = lookup(fileNames, name) { return hit }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for i in 1..<parts.count {
                let ext = parts[i...].joined(separator: ".")
                if ext.isEmpty { continue }
                if let hit = lookup(fileExtensions, ext) { return hit }
            }
        }
        if let language, let hit = languageIds[Self.vscodeLanguage[language] ?? language] { return hit }
        return file
    }

    /// The icon for a folder, open or closed; the project root gets the plain folder, not the theme's root icon.
    public func icon(forFolder name: String, parent: String? = nil, expanded: Bool, isRoot: Bool = false) -> String {
        // The theme's root icon is a ring, which reads as a radio button in a tree: the project root is a folder.
        if isRoot { return expanded ? folderExpanded : folder }
        let name = name.lowercased()
        let table = expanded ? folderNamesExpanded : folderNames
        if let parent, let hit = table[parent.lowercased() + "/" + name] { return hit }
        return table[name] ?? (expanded ? folderExpanded : folder)
    }
}
