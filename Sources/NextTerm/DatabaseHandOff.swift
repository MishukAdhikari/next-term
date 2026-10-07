import AppKit
import NextTermCore

/// Hand-offs from a Databases row: TablePlus, `mysql`/`psql` in a new tab, Vercel's dashboard. Each reads
/// the password again from the project's file at that moment; none puts it in argv, a log, the
/// clipboard or a tab's environment, and none listens on a socket.
@MainActor
enum DatabaseHandOff {
    static let tablePlusID = "com.tinyapp.TablePlus"

    /// TablePlus, if it is installed (never the default handler for `mysql://`: another app can claim it).
    static var tablePlus: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: tablePlusID) }

    static func tablePlusOpens(_ db: DetectedDatabase) -> Bool {
        db.isConnection && [.mysql, .mariadb, .postgres, .cockroach, .mongodb, .sqlserver, .sqlite].contains(db.engine)
    }

    /// Where programs are looked for: the login shell's PATH (once it is known), the usual folders, and
    /// where Herd, Homebrew's keg-only clients and Postgres.app keep theirs.
    static func findProgram(_ name: String, extraFolders: Bool = true) -> String? {
        var folders: [String]
        if LoginShell.isProbed {
            folders = LoginShell.path
        } else {
            LoginShell.warmUp()
            folders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin",
                       NSHomeDirectory() + "/.bun/bin", NSHomeDirectory() + "/.volta/bin", "/usr/bin", "/bin"]
        }
        if extraFolders {
            folders.append(NSHomeDirectory() + "/Library/Application Support/Herd/bin")
            for base in ["/opt/homebrew/opt", "/usr/local/opt"] {
                let kegs = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
                    .filter { $0.hasPrefix("postgresql") || $0.hasPrefix("mysql") || $0.hasPrefix("mariadb") || $0 == "libpq" }.sorted().reversed()
                folders += kegs.map { "\(base)/\($0)/bin" }
            }
            folders.append("/Applications/Postgres.app/Contents/Versions/latest/bin")
        }
        for folder in folders {
            let candidate = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The client a terminal hand-off would run: local and development connections only.
    static func terminalClient(for db: DetectedDatabase) -> (name: String, path: String)? {
        guard db.isConnection, db.environment.allowsTerminal else { return nil }
        for name in DatabaseClientCommand.clients(for: db.engine) {
            if let path = findProgram(name) { return (name, path) }
        }
        return nil
    }

    /// The `vercel` CLI on the login shell's PATH (never a project's node_modules).
    static var vercelCLI: String? { findProgram("vercel", extraFolders: false) }

    // MARK: TablePlus

    /// What the confirmation for a remote connection says: it names the host.
    static func confirmation(for db: DetectedDatabase) -> (title: String, detail: String) {
        let host = db.host ?? db.socket ?? "a host that is not on this Mac"
        return ("Open “\(db.name)” on \(host) in TablePlus?",
                "\(host) is not on this Mac, so Next Term treats it as production. TablePlus gets this connection’s password, and anything you run there runs on that server.")
    }

    static func openInTablePlus(_ db: DetectedDatabase, root: String, window: NSWindow?) {
        guard let app = tablePlus, tablePlusOpens(db) else { return NSSound.beep() }
        let open = {
            DispatchQueue.global(qos: .userInitiated).async {
                let url = Databases.credentials(for: db, root: root)?.url
                DispatchQueue.main.async {
                    guard let url else {
                        return report("“\(db.name)” is no longer in \(db.sourceFile ?? "the project’s files")",
                                      "The file changed since the sidebar read it. Try again once it shows the database.", window: window)
                    }
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        guard error != nil else { return }
                        // The error can quote the URL it was given: say nothing from it.
                        DispatchQueue.main.async { report("TablePlus did not open “\(db.name)”", "Open TablePlus and try again.", window: window) }
                    }
                }
            }
        }
        guard db.environment == .remote else { return open() }
        let text = confirmation(for: db)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Open in TablePlus").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r" // Return cancels
        let handle: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { open() } }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: mysql and psql in a tab

    static func openInTerminal(_ db: DetectedDatabase, root: String, controller: TerminalWindowController) {
        guard let client = terminalClient(for: db) else { return NSSound.beep() }
        DispatchQueue.global(qos: .userInitiated).async {
            let credentials = Databases.credentials(for: db, root: root)
            DispatchQueue.main.async {
                guard let credentials else {
                    return report("“\(db.name)” is no longer in \(db.sourceFile ?? "the project’s files")",
                                  "The file changed since the sidebar read it.", window: controller.window)
                }
                var file: URL?
                if let password = credentials.password, !password.isEmpty {
                    do {
                        file = try HandOffFile.write(DatabaseClientCommand.secretFileContents(for: db.engine, password: password),
                                                     suffix: DatabaseClientCommand.isPostgres(db.engine) ? ".pgpass" : ".cnf")
                    } catch {
                        return report("Next Term could not hand “\(db.name)” to \(client.name)", "A private temporary file could not be written.",
                                      window: controller.window)
                    }
                }
                let command = DatabaseClientCommand.commandLine(for: db, program: client.path, secretFile: file?.path)
                let tab = controller.runInNewTab(directory: root, command: command, title: "\(client.name) · \(db.name)")
                if let file { HandOffFile.delete(file, onceStartedIn: tab) }
            }
        }
    }

    // MARK: Vercel

    static func openInVercel(_ db: DetectedDatabase, root: String, controller: TerminalWindowController) {
        guard let cli = vercelCLI else { return NSSound.beep() }
        // The provider's dashboard through Vercel's sign-in, or the project's resources when it is not known.
        let arguments = db.providers.compactMap(\.vercelSlug).first.map { ["integration", "open", $0] } ?? ["integration", "list"]
        controller.runInNewTab(directory: root, command: ([cli] + arguments).map(ShellQuote.quote).joined(separator: " "), title: "Vercel")
    }

    static func report(_ title: String, _ detail: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = DatabaseMask.redact(title)
        alert.informativeText = DatabaseMask.redact(detail)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// The 0600 file a terminal hand-off puts the password in, in a 0700 folder of the user's temporary
/// directory. Deleted once the client has started (it reads the file at start), and at the latest after
/// 20 seconds; leftovers from a crash go the next time one is written.
enum HandOffFile {
    static var folder: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nextterm-handoff", isDirectory: true) }

    struct WriteError: Error {}

    static func write(_ contents: String, suffix: String) throws -> URL {
        let dir = folder.path
        mkdir(dir, 0o700)
        var info = stat()
        guard lstat(dir, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw WriteError() }
        chmod(dir, 0o700)
        removeLeftovers(olderThan: 60)
        let url = folder.appendingPathComponent(UUID().uuidString + suffix)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError() }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let bytes = Array(contents.utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            unlink(url.path)
            throw WriteError()
        }
        return url
    }

    /// Deletes the file three seconds after the tab's command starts, when the tab closes, or after 20 seconds.
    @MainActor
    static func delete(_ url: URL, onceStartedIn tab: TerminalTab, waited: TimeInterval = 0, startedAt: TimeInterval? = nil) {
        var started = startedAt
        if started == nil, tab.status.running { started = waited }
        if tab.exited || waited >= 20 || (started.map { waited - $0 >= 3 } ?? false) {
            unlink(url.path)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tab] in
            guard let tab else { unlink(url.path); return }
            delete(url, onceStartedIn: tab, waited: waited + 0.5, startedAt: started)
        }
    }

    static func removeLeftovers(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let path = folder.appendingPathComponent(name).path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, Date().timeIntervalSince(date) > seconds {
                unlink(path)
            }
        }
    }
}
