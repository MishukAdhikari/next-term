import Foundation

/// What the install script did with a staged update, left in the sessions folder for the next launch,
/// which says once that an update did not install.
public struct InstallResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The new app is in place.
        case installed
        /// The new app was refused or could not be put in place, and the old one is where it was: it never
        /// moved, or it was moved back.
        case failedKeptOld = "failed-kept-old"
        /// Neither app could be put in place, so the old one is left in its backup, beside its install path.
        /// It is opened from there only when the script has a folder key to hand it.
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
/// process to end and checks the staged app's signature. Then it moves the old app into a new private
/// folder beside it, moves the new one into place, checks it again there and removes the backup. If
/// the new app is refused or cannot go in, the old one goes back. Every path is quoted.
///
/// The staged app waits in the temporary items, which agents can write, so nothing from there is
/// trusted: the backup never goes there, and every app is checked right before it is opened.
public struct InstallScript: Sendable {
    /// Hands an app opened from its backup the folder key of its install path, so it finds its sessions.
    public static let folderKeyArgument = "--sessions-folder-key"

    /// The app's process: the script starts once it has ended.
    public var pid: Int32
    /// Where the app is installed.
    public var app: String
    /// The new app, staged on the same volume.
    public var newApp: String
    /// The staging folder, removed with the backup once the new app is in place.
    public var staging: String
    /// The code requirement the new app must meet (`codesign -R`), see `CodeSignature.updateRequirement`.
    public var requirement: String
    /// The requirement the old app must meet before it is opened again: the running app's designated one.
    public var oldRequirement: String
    /// Open the app again afterwards. "When I Quit" installs without it.
    public var relaunch: Bool
    /// The sessions folder the result is written into; nothing is written without one.
    public var sessions: String?
    /// The marker the result names.
    public var marker: UUID?
    /// The folder key of the install path. An old app that could not be put back is opened from its
    /// backup only with one, so it finds its sessions. That happens with relaunch off too, the one time
    /// "When I Quit" opens the app: otherwise no app would be where the user looks. Without a key it
    /// stays in its backup, unopened.
    public var folderKey: String?
    /// The command that opens an app (tests stub it).
    public var open = "/usr/bin/open"
    /// The command that checks a signature (tests wrap it).
    public var codesign = "/usr/bin/codesign"

    public init(pid: Int32, app: String, newApp: String, staging: String, requirement: String,
                oldRequirement: String, relaunch: Bool) {
        self.pid = pid
        self.app = app
        self.newApp = newApp
        self.staging = staging
        self.requirement = requirement
        self.oldRequirement = oldRequirement
        self.relaunch = relaunch
    }

    /// The private folder the old app waits in, beside it and out of agents' reach. `mktemp -d` makes it
    /// fresh, so nothing can be planted where the old app goes.
    var backupTemplate: String {
        let folder = (app as NSString).deletingLastPathComponent
        let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        return folder + "/." + name + " (previous).XXXXXX"
    }

    public var text: String {
        let q = ShellQuote.quote
        let app = q(self.app), newApp = q(self.newApp)
        let moveAside = "backup=$(/usr/bin/mktemp -d \(q(backupTemplate)) 2>/dev/null) && /bin/mv \(app) \(held)"
        let present = "{ [ -e \(app) ] || [ -L \(app) ]; }"
        let absent = "[ ! -e \(app) ] && [ ! -L \(app) ]"
        var lines = ["while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done",
                     check("new_ok", requirement),
                     check("old_ok", oldRequirement),
                     "if ! new_ok \(newApp); then"]
        lines += Self.branch(keptOld, depth: 1)
        lines.append("elif ! { \(moveAside); }; then")
        lines += Self.branch(["[ -n \"$backup\" ] && /bin/rmdir \"$backup\""] + keptOld, depth: 1)
        // Checked again in place: the staged app could have changed between the check and the move.
        lines.append("elif /bin/mv \(newApp) \(app) && new_ok \(app); then")
        lines += Self.branch(installed, depth: 1)
        lines.append("else")
        lines += Self.branch(["\(present) && /bin/mv \(app) \"$backup\"/rejected",
                              "if \(absent) && /bin/mv \(held) \(app); then"], depth: 1)
        lines += Self.branch(["/bin/rm -rf \"$backup\""] + keptOld, depth: 2)
        lines.append("  else")
        lines += Self.branch(write(.failedRestoredBackup) + openBackup, depth: 2)
        lines += ["  fi", "fi"]
        return lines.joined(separator: "\n")
    }

    /// The old app in its backup folder.
    private var held: String {
        "\"$backup\"/" + ShellQuote.quote((app as NSString).lastPathComponent)
    }

    /// A shell function that passes for a real folder, not a link, with no file linked from elsewhere
    /// (a hard link would let whoever holds the other name change the app once it is installed), whose
    /// signature is intact and meets `requirement`.
    private func check(_ name: String, _ requirement: String) -> String {
        let q = ShellQuote.quote
        let real = "[ -d \"$1\" ] && [ ! -L \"$1\" ]"
        let unlinked = "[ -z \"$(/usr/bin/find \"$1\" -type f -links +1 -print -quit 2>/dev/null)\" ]"
        let signed = "\(q(codesign)) --verify --deep --strict -R \(q("=" + requirement)) \"$1\" 2>/dev/null"
        return "\(name)() { \(real) && \(unlinked) && \(signed); }"
    }

    private var installed: [String] {
        let q = ShellQuote.quote
        let reopen = relaunch ? [q(open) + " " + q(app)] : []
        return write(.installed) + ["/bin/rm -rf \"$backup\" \(q(staging))"] + reopen
    }

    /// The old app is where it was. It is opened again with relaunch on, once it passes its check.
    private var keptOld: [String] {
        let q = ShellQuote.quote
        let reopen = relaunch ? ["old_ok \(q(app)) && \(q(open)) \(q(app))"] : []
        return write(.failedKeptOld) + reopen
    }

    private var openBackup: [String] {
        guard let folderKey else { return [] }
        let q = ShellQuote.quote
        let arguments = " --args " + Self.folderKeyArgument + " " + q(folderKey)
        return ["old_ok \(held) && \(q(open)) \(held)" + arguments]
    }

    /// A branch's lines, indented: `:` for an empty one, which bash refuses.
    private static func branch(_ lines: [String], depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        return (lines.isEmpty ? [":"] : lines).map { indent + $0 }
    }

    /// Writes the result into a temp file in the sessions folder, then renames it over the result file
    /// (`-h`: a link planted there is replaced, never followed, even one to a folder). A real folder in its
    /// place gets nothing. No sessions folder (or a missing one) writes nothing. `mktemp` makes the file
    /// 0600 whatever the umask; umask 077 is there in case anything else ever creates one.
    private func write(_ outcome: InstallResult.Outcome) -> [String] {
        guard let sessions else { return [] }
        let q = ShellQuote.quote
        let json = q(InstallResult(outcome: outcome, marker: marker).json)
        let template = q(sessions + "/install-result.XXXXXX")
        let target = q(sessions + "/" + InstallResult.fileName)
        let folder = "[ -d \(target) ] && [ ! -L \(target) ]"
        let put = "printf '%s\\n' \(json) > \"$t\""
        let rename = "/bin/mv -f -h \"$t\" \(target)"
        return ["(umask 077; t=$(/usr/bin/mktemp \(template) 2>/dev/null) || exit 0",
                " if \(folder) || ! \(put) || ! \(rename); then /bin/rm -f \"$t\"; fi)"]
    }
}
