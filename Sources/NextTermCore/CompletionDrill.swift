import Foundation

/// Walking down a path with Tab: on a folder row of the open list, ⇥ puts `name/` on the line and the same list shows
/// what is inside, its first row chosen; ↩︎ and a click put the name on the line and close, as before; ⌫ that takes the
/// `/` right after goes back up. CompletionSession runs it on each of the list's paths (Next Term's own engine, zsh's
/// own completions through the hook, a server's screen); the decisions are here.
public enum CompletionDrill {
    /// What ⇥ does on a row.
    public enum Target: Equatable, Sendable {
        /// What ↩︎ does: the name goes on the line, and the list closes.
        case file
        /// Into the folder.
        case folder
        /// A folder that can't be entered (shown dimmed): a beep, and the list stays.
        case closed
    }

    /// What going into a folder comes to, once it is listed.
    public enum Step: Equatable, Sendable {
        /// The name goes on the line and the list shows what is inside.
        case into
        /// Nothing inside the list would show (an empty folder, only files after `cd`), or it wasn't read in time: the
        /// name goes on the line and the list closes.
        case wentIn
        /// It can't be read (no permission, gone): a beep, and the list stays as it was.
        case refused
    }

    /// The folder's listing, and how many rows it gives the list.
    public static func step(_ listing: PathCompletion.Listing, shown: Int) -> Step {
        guard listing.readable else { return listing.late ? .wentIn : .refused }
        return shown > 0 ? .into : .wentIn
    }

    /// The single-match rule: the one name Tab puts on the line by itself (PathCompletion.Result.single) is a folder that
    /// can be entered. It goes in, and what is inside is listed when there is anything (zsh's automatic `/`, then a
    /// second Tab). nil: it goes in alone, as before.
    public static func single(_ result: PathCompletion.Result) -> PathCompletion.Candidate? {
        guard let only = result.single, only.isFolder, only.enterable else { return nil }
        return only
    }

    /// ⌫ took the `/` that going into a folder put on the line: the word now is that word without it.
    public static func goesBackUp(_ now: String, from drilled: String) -> Bool {
        !drilled.isEmpty && now + "/" == drilled
    }

    /// What VoiceOver says on going into a folder: "In projects, 12 items".
    public static func announcement(into name: String, total: Int, exact: Bool) -> String {
        let items = total == 1 ? "1 item" : "\(total.formatted()) items"
        return "In \(name), \(items)\(exact ? "" : " shown")"
    }

    /// And on going back up, with the folder chosen: "Back up, projects, 3 of 5".
    public static func backUpAnnouncement(_ name: String, row: Int, of count: Int) -> String {
        "Back up, \(name), \(row + 1) of \(count)"
    }
}
