/// The window the user is in, while project windows merge as macOS's tabs (plan 032): the tab in front of its group, never
/// a tab behind it. AppKit can leave the keyboard, or the main window, in a tab behind the one in front (it hands them
/// back to the window that last had them, behind a tab chosen since), so whatever asks "is the user in this window" or
/// "where does the keyboard go" asks here, with each window's shown tab: the tab in front of its group, or itself when
/// it is apart.
public enum UsersWindowRule {
    /// Whether `window` is the one the user is in: the tab shown in place of the key window, or in place of the main one
    /// while a panel or a sheet has the keyboard. A tab behind another never is; the tab in front of a key tab behind it is.
    public static func isUsers<W: Equatable>(_ window: W, shown: W, keyShown: W?, mainShown: W?) -> Bool {
        guard window == shown else { return false }
        return window == keyShown || window == mainShown
    }

    /// Whether the keyboard may go to `window` when something gives it there: only while it is the tab in front of its
    /// group, or a window of its own. Making a tab behind another key brings it to the front over the tab the user chose.
    public static func mayTakeKeyboard<W: Equatable>(_ window: W, shown: W) -> Bool { window == shown }

    /// What puts the keyboard back where the user is, when it or the main window is left in a tab behind another.
    public enum Repair<W: Equatable>: Equatable {
        /// The keyboard to the tab in front (made key and main).
        case key(W)
        /// The tab in front made main, the keyboard left in the panel that has it: when that panel goes, AppKit gives the
        /// keyboard to the main window, the tab in front, not the tab left behind.
        case main(W)
    }

    /// The repair for the windows as they are now, or nil when the keyboard and the main window are where the user is.
    /// A key tab behind another gives the keyboard to the tab in front; with a panel or a sheet key, a main tab behind
    /// another gives way to the tab in front as main.
    /// - Parameters:
    ///   - key: the key window, and the tab shown in its place.
    ///   - main: the main window, and the tab shown in its place.
    ///   - appActive: Next Term is the app in front: the keyboard is never taken from another app.
    ///   - modal: a modal session runs (an alert run modally): it keeps the keyboard.
    public static func repair<W: Equatable>(key: (window: W, shown: W)?, main: (window: W, shown: W)?, appActive: Bool,
                                            modal: Bool) -> Repair<W>? {
        guard appActive, !modal else { return nil }
        if let key, key.window != key.shown { return .key(key.shown) }
        if let main, main.window != main.shown { return .main(main.shown) }
        return nil
    }
}
