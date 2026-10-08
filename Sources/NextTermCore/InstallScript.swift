import Foundation

/// What the install script did with a staged update, left in the sessions folder for the next launch,
/// which says once that an update did not install.
public struct InstallResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The new app is in place.
        case installed
        /// The new app could not be put in place, and the old one is where it was: it never moved, or it
        /// was moved back.
        case failedKeptOld = "failed-kept-old"
        /// Neither app could be put in place, so the old one was opened from its backup, at another path.
        case failedRestoredBackup = "failed-restored-backup"
    }

    public var outcome: Outcome
    /// The marker written at the quit that ran the script; none when no marker was written.
    public var marker: UUID?

    public static let fileName = "install-result.json"
    /// A result is a few dozen bytes: anything bigger is not one.
    public static let maxSize = 4096

    public init(outcome: Outcome, marker: UUID?) {
        self.outcome = outcome
        self.marker = marker
    }

    public static func parse(_ data: Data) -> InstallResult? {
        guard data.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(InstallResult.self, from: data)
    }

    /// The file's text, as the script writes it.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The script that puts a staged update in place once Next Term has quit. It waits for the app's
/// process to end, moves the old app to a backup, moves the new one into place and removes the backup.
/// If the new app cannot go in, the old one goes back. If the old one cannot go back either, it is
/// opened from its backup, told which sessions folder is its own. Every path is quoted.
public struct InstallScript: Sendable {
    /// Hands an app opened from its backup the folder key of its install path, so it finds its sessions.
    public static let folderKeyArgument = "--sessions-folder-key"

    /// The app's process: the script starts once it has ended.
    public var pid: Int32
    /// Where the app is installed.
    public var app: String
    /// The new app, staged on the same volume.
    public var newApp: String
    /// Where the old app waits while the new one is moved in.
    public var backup: String
    /// The staging folder, removed with the backup once the new app is in place.
    public var staging: String
    /// Open the app again afterwards. "When I Quit" installs without it. A backup that could not be
    /// put back is opened either way: otherwise no copy of the app would be where the user looks.
    public var relaunch: Bool
    /// The sessions folder the result is written into; nothing is written without one.
    public var sessions: String?
    /// The marker the result names.
    public var marker: UUID?
    /// The folder key of the install path, passed to an app opened from its backup.
    public var folderKey: String?
    /// The command that opens an app (tests stub it).
    public var open = "/usr/bin/open"

    public init(pid: Int32, app: String, newApp: String, backup: String, staging: String, relaunch: Bool) {
        self.pid = pid
        self.app = app
        self.newApp = newApp
        self.backup = backup
        self.staging = staging
        self.relaunch = relaunch
    }

    public var text: String {
        let q = ShellQuote.quote
        let app = q(self.app), backup = q(backup)
        let installed = write(.installed) + ["/bin/rm -rf \(backup) \(q(staging))"]
        let restoredBackup = write(.failedRestoredBackup) + [openBackup, "exit 0"]
        var lines = ["while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done",
                     "if /bin/mv \(app) \(backup); then",
                     "  if /bin/mv \(q(newApp)) \(app); then"]
        lines += Self.branch(installed, depth: 2)
        lines.append("  elif /bin/mv \(backup) \(app); then")
        lines += Self.branch(write(.failedKeptOld), depth: 2)
        lines.append("  else")
        lines += Self.branch(restoredBackup, depth: 2)
        lines += ["  fi", "else"]
        lines += Self.branch(write(.failedKeptOld), depth: 1)
        lines.append("fi")
        if relaunch { lines.append(q(open) + " " + app) }
        return lines.joined(separator: "\n")
    }

    /// A branch's lines, indented: `:` for an empty one, which bash refuses.
    private static func branch(_ lines: [String], depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        return (lines.isEmpty ? [":"] : lines).map { indent + $0 }
    }

    private var openBackup: String {
        let q = ShellQuote.quote
        let command = q(open) + " " + q(backup)
        guard let folderKey else { return command }
        return command + " --args " + Self.folderKeyArgument + " " + q(folderKey)
    }

    /// Writes the result privately (umask 077) into a temp file in the sessions folder, then renames it
    /// over the result file: a link planted there is replaced, never written through. No sessions folder
    /// (or a missing one) writes nothing.
    private func write(_ outcome: InstallResult.Outcome) -> [String] {
        guard let sessions else { return [] }
        let q = ShellQuote.quote
        let json = q(InstallResult(outcome: outcome, marker: marker).json)
        let template = q(sessions + "/install-result.XXXXXX")
        let target = q(sessions + "/" + InstallResult.fileName)
        let put = "printf '%s\\n' \(json) > \"$t\" && /bin/mv -f \"$t\" \(target) || /bin/rm -f \"$t\""
        return ["(umask 077; t=$(/usr/bin/mktemp \(template) 2>/dev/null) && { \(put); })"]
    }
}
