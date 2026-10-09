import Foundation

/// Walking down a path with Tab: on a folder row of the open list, ⇥ (or →) puts `name/` on the line and the same list
/// shows what is inside, its first row chosen; ↩︎ and a click put the name on the line and close, as before; ⌫ that
/// takes the `/` right after, or ←, goes back up. CompletionSession runs it on each of the list's paths (Next Term's
/// own engine, zsh's own completions through the hook, a server's screen); the decisions are here.
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

    // MARK: the keys

    /// The keys that walk the list through folders (↓ ↑ only choose a row).
    public enum Key: Equatable, Sendable {
        /// ⇥: into a folder; anything else on the line.
        case tab
        /// →: the same as ⇥.
        case right
        /// ←: back up.
        case left
    }

    /// What a key does on the open list.
    public enum Action: Equatable, Sendable {
        /// Into the chosen folder: `name/` on the line, and the list shows what is inside.
        case goIn
        /// The chosen name on the line, and the list closes: ↩︎'s way.
        case putOnLine
        /// A beep, and the list stays: a folder that can't be entered.
        case beep
        /// Back to the list this one went into a folder from: the word as it was before going in, and that folder
        /// chosen.
        case backUp
        /// The list closes and the key goes on to the shell, as it always did: the cursor moves.
        case closeAndPass
        /// It waits: for the rows (⇥ before they show), or for the folder being listed.
        case wait
    }

    /// What `key` does with `row` chosen (nil: no rows yet) on a list that does (`inside`) or doesn't show a folder's
    /// inside that going in opened. `drills`: the shell's hook can go into a folder (a server's from before can't: ⇥
    /// and → put the name on the line there). `drilling`: a folder is being listed.
    public static func action(_ key: Key, on row: Target?, inside: Bool, drills: Bool = true, drilling: Bool = false) -> Action {
        if drilling { return .wait }
        if key == .left { return inside ? .backUp : .closeAndPass }
        guard let row else { return key == .tab ? .wait : .closeAndPass }
        switch row {
        case .file: return .putOnLine
        case .folder: return drills ? .goIn : .putOnLine
        case .closed: return drills ? .beep : .putOnLine
        }
    }

    /// ← on a server's screen: Backspaces from the word on screen (`from`) back to where it and `to` part, then the
    /// rest of `to` as text. nil when what goes isn't plain ASCII: a Backspace takes a byte or a character there, by
    /// the server's locale.
    public static func retype(_ from: String, to: String) -> (erase: Int, text: String)? {
        let now = Array(from.unicodeScalars), then = Array(to.unicodeScalars)
        var common = 0
        while common < now.count, common < then.count, now[common] == then[common] { common += 1 }
        let gone = now[common...]
        guard gone.allSatisfy(\.isASCII) else { return nil }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: then[common...])
        return (gone.count, String(text))
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
