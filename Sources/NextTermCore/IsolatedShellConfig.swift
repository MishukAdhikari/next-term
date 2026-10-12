import Foundation

/// A zsh config folder of its own, for shells that must never read the user's (a self-test's tabs). The zsh integration
/// hands a tab's shell over to the folder in `NEXTTERM_USER_ZDOTDIR`; given this one, zsh reads its `.zshrc` here and
/// none of the user's `.zshenv`, `.zprofile`, `.zshrc` or `.zlogin`. Its history stays in the folder, so no line typed
/// in a test reaches the user's history file, and its prompt is short and the same on every Mac, so no theme, plugin or
/// slow start of the user's changes what a test reads on the screen.
public enum IsolatedShellConfig {
    /// The `.zshrc` written in `folder`.
    public static func zshrc(in folder: String) -> String {
        "# A test's own zsh config: its history stays in this folder, and its prompt names no one.\n"
            + "HISTFILE=" + ShellQuote.quote(folder + "/.zsh_history") + "\n"
            + "PROMPT='%1~ %# '\n"
    }

    /// Makes `folder`, private to the user, with its `.zshrc`. False when it can't be written: a shell given the folder
    /// then reads no config at all, still never the user's.
    @discardableResult
    public static func prepare(_ folder: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try Data(zshrc(in: folder.path).utf8).write(to: folder.appendingPathComponent(".zshrc"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The folder a tab's zsh hands over to for its config (the integration's `NEXTTERM_USER_ZDOTDIR`): `isolated` when
    /// there is one, else the `ZDOTDIR` the app was given, or "" for the home folder.
    public static func userConfigFolder(environment: [String: String], isolated: String?) -> String {
        if let isolated, !isolated.isEmpty { return isolated }
        return environment["ZDOTDIR"] ?? ""
    }
}
