import Foundation

// What Undo Import puts back, and the two guards around it: an Apply that changes nothing keeps the Undo of
// the import before it, and Undo can say which values were changed by hand since the import before it puts
// them back. Only Next Term's own settings are read here.

/// The settings one import changed: each as it was before and just after, so Undo restores it exactly.
/// Stored as JSON (the app's `importSnapshot` key); snapshots saved before `after` and `id` existed still read.
public struct ImportSnapshot: Codable, Equatable, Sendable {
    /// A saved setting's value as UserDefaults holds it.
    public enum Value: Codable, Equatable, Sendable {
        case double(Double), bool(Bool), string(String), strings([String])
        /// Saved bytes, as they were (`keyBindings`, the palettes).
        case data(Data)
    }

    public let date: Date
    /// The app imported from ("Cursor").
    public let source: String
    /// "VS Code shortcuts, 3 settings".
    public let summary: String
    /// Each changed key → its value before (missing: there was none).
    public let before: [String: Value]
    /// The keys the import changed.
    public let touched: [String]
    /// Each changed key → its value just after the import (missing: none). Nil in older snapshots.
    public let after: [String: Value]?
    /// Names this import, so a later request can say which one it means. Nil in older snapshots.
    public let id: String?

    public init(id: String? = UUID().uuidString, date: Date = Date(), source: String, summary: String,
                before: [String: Value], touched: [String], after: [String: Value]?) {
        self.id = id
        self.date = date
        self.source = source
        self.summary = summary
        self.before = before
        self.touched = touched
        self.after = after
    }

    /// The value saved under `key`, or nil when there is none (or not one of the kinds an import writes).
    public static func value(of key: String, in defaults: UserDefaults) -> Value? {
        switch defaults.object(forKey: key) {
        case let value as Bool where ImportedSetting.boolKeys.contains(key): return .bool(value)
        case let value as Data: return .data(value)
        case let value as Double: return .double(value)
        case let value as String: return .string(value)
        case let value as [String]: return .strings(value)
        default: return nil
        }
    }

    public static func values(of keys: [String], in defaults: UserDefaults) -> [String: Value] {
        var values: [String: Value] = [:]
        for key in keys { values[key] = value(of: key, in: defaults) }
        return values
    }

    /// Two saved values of `key` mean the same. The shortcuts are compared as shortcuts: the same ones can be
    /// saved in another order.
    public static func same(_ key: String, _ one: Value?, _ other: Value?) -> Bool {
        if one == other { return true }
        if key == "keyBindings", case .data(let first)? = one, case .data(let second)? = other {
            return KeyBindings.decode(first) == KeyBindings.decode(second)
        }
        return false
    }

    /// The keys among `keys` whose value differs between `before` and `after`, in `keys`' order.
    public static func changed(_ keys: [String], before: [String: Value], after: [String: Value]) -> [String] {
        keys.filter { !same($0, before[$0], after[$0]) }
    }

    /// The snapshot for an Apply, or nil when it changed nothing: then the Undo kept is the earlier import's.
    public static func applied(keys: [String], before: [String: Value], after: [String: Value],
                               source: String, summary: String, date: Date = Date()) -> ImportSnapshot? {
        let changed = changed(keys, before: before, after: after)
        guard !changed.isEmpty else { return nil }
        return ImportSnapshot(date: date, source: source, summary: summary, before: before.filter { changed.contains($0.key) },
                              touched: changed, after: after.filter { changed.contains($0.key) })
    }

    /// The keys this import changed that hold something else now (`current`: their values today), changed by
    /// hand or by another import since. Empty for a snapshot without `after`. Recent projects are never among them:
    /// opening a project changes that list, and Undo only takes back the folders the import added
    /// (`recentProjectsAfterUndo`), so nothing done since is put back.
    public func changedSince(_ current: [String: Value]) -> [String] {
        guard let after else { return [] }
        return touched.filter { $0 != Self.recentsKey && !Self.same($0, after[$0], current[$0]) }
    }

    static let recentsKey = "recentProjects"

    /// The recent projects after Undo: the list as it is now (`current`), less the folders this import added, so
    /// the projects opened since stay. A snapshot from before `after` existed puts back the list as it was.
    public func recentProjectsAfterUndo(current: [String]) -> [String] {
        var before: [String] = []
        if case .strings(let paths)? = self.before[Self.recentsKey] { before = paths }
        guard let after else { return before }
        guard case .strings(let imported)? = after[Self.recentsKey] else { return current }
        let added = Set(imported).subtracting(before)
        return current.filter { !added.contains($0) }
    }

    /// How a key is named to the user ("Font size"): the names Settings and the preview use.
    public static func title(of key: String) -> String {
        switch key {
        case "keymapPreset": return "Shortcut set"
        case "keyBindings": return "Your shortcuts"
        case "recentProjects": return "Recent projects"
        case "fontSize": return "Font size"
        case "terminalFontSize": return "Terminal font size"
        case "editorLineHeight": return "Line height"
        case "softWrap": return "Wrap long lines"
        case "optionAsMeta": return "Option as Meta"
        case "terminalPosition": return "Terminal position"
        case "sidebarSide": return "Project sidebar side"
        case TerminalTabsSetting.key: return "Terminal tabs"
        case TabListImport.showsFoldersKey: return "Folders in the tab list"
        case "editorFontFamily": return "Editor font"
        case "terminalFontFamily": return "Terminal font"
        case "terminalPalette", "customTerminalPalette": return "Terminal colours"
        case "terminalScrollback": return "Terminal scrollback"
        case "terminalStartFolder": return "Where new tabs open"
        case "terminalCursorShape": return "Terminal cursor"
        case "terminalCursorBlink": return "Terminal cursor blink"
        case "trimTrailingWhitespace": return "Trim trailing spaces on save"
        case "insertFinalNewline": return "Final newline on save"
        case "hiddenFilePatterns": return "Hidden files"
        case "sidebarSingleClickOpens": return "Open files and folders with a single click"
        case "backgroundFetch": return "Fetch in the background"
        case "diffLayout": return "Unified diffs"
        case "currentLineBlame": return "Current line blame"
        case "openProjectsIn": return "Open projects in"
        case LaunchSettings.Key.opens: return "At launch"
        default: return key
        }
    }

    /// The titles of `keys`, each once, in order.
    public static func titles(of keys: [String]) -> [String] {
        var titles: [String] = []
        for key in keys where !titles.contains(title(of: key)) { titles.append(title(of: key)) }
        return titles
    }
}
