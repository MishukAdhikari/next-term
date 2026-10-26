import Foundation

/// The warning a close or a quit gives for database tabs that hold a value not saved yet (R22), where a text file
/// would get the save-changes question. It has no Save: a database's save is asynchronous and writes one value at a
/// time, checked against its row as it was read, so a value is saved in its own tab. Cancel comes first and is the
/// default (Return, and ⎋); the other button closes or quits anyway. Neither writes anything to a file.
public enum UnsavedValueWarning {
    /// What the warning lets go ahead.
    public enum Action: Sendable {
        /// Close Others, Close Tabs to the Right, or closing the window.
        case close
        /// A quit.
        case quit
    }

    /// "“agent.db” has a value you haven’t saved.", or "“agent.db” and “notes.db” have values you haven’t saved.":
    /// `files` names the database of each tab with one, a file open in several tabs once.
    public static func title(_ files: [String]) -> String {
        var seen = Set<String>()
        let names = files.filter { (name: String) -> Bool in seen.insert(name).inserted }
        let what: String
        if names.count > 1 {
            what = " have values"
        } else {
            what = files.count > 1 ? " has values" : " has a value"
        }
        return CloseText.names(names) + what + " you haven’t saved."
    }

    /// What going ahead does, and how to keep them: for `count` tabs with a value.
    public static func info(_ count: Int, _ action: Action) -> String {
        let anyway = action == .close ? "If you close anyway" : "If you quit anyway"
        if count == 1 {
            return anyway + ", it is lost and nothing is written. To keep it, click Cancel and save it in its tab."
        }
        return anyway + ", they are lost and nothing is written. To keep them, click Cancel and save each in its tab."
    }

    /// The buttons in the order they are added: Cancel, the default, then "Close Anyway" or "Quit Anyway".
    public static func buttons(_ action: Action) -> [String] {
        ["Cancel", action == .close ? "Close Anyway" : "Quit Anyway"]
    }
}
