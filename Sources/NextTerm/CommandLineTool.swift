import AppKit
import NextTermCore

/// `nxtrm`: the app binary run as a command line tool (`NextTerm --cli …`, through the `nxtrm` script in
/// the bundle). It never starts the user interface: it hands the request to the running Next Term, or
/// starts it with the request.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Never {
        switch CommandLineOpen.parse(arguments, cwd: FileManager.default.currentDirectoryPath) {
        case .help:
            print(CommandLineOpen.usage)
            exit(0)
        case .version:
            print("Next Term " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)"))
            exit(0)
        case .error(let message):
            FileHandle.standardError.write(Data("nxtrm: \(message)\n".utf8))
            exit(2)
        case .open(var command):
            for item in command.items where item.isNew {
                guard FileManager.default.createFile(atPath: item.path, contents: nil) else {
                    FileHandle.standardError.write(Data("nxtrm: \(item.path): could not create the file\n".utf8))
                    exit(1)
                }
            }
            command.app = Bundle.main.bundlePath
            deliver(command)
        }
    }

    private static func deliver(_ command: OpenCommand) -> Never {
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              let json = try? JSONEncoder().encode(command), let text = String(data: json, encoding: .utf8) else {
            FileHandle.standardError.write(Data("nxtrm: run the copy inside Next Term.app\n".utf8))
            exit(1)
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if running {
            DistributedNotificationCenter.default().postNotificationName(
                .init(CommandLineOpen.notificationName), object: nil, userInfo: ["request": text], deliverImmediately: true)
        } else {
            configuration.arguments = ["--open-request", text]
        }
        // Launch, or bring the running app to the front (the system lets Launch Services do that).
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            failure = error
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        if let failure {
            FileHandle.standardError.write(Data("nxtrm: could not open Next Term: \(failure.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    // MARK: installing

    /// The `nxtrm` script inside the app, or nil in a development build.
    static var script: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/\(CommandLineOpen.toolName)"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static let installPath = "/usr/local/bin/" + CommandLineOpen.toolName

    /// An app run from a disk image or a quarantine location moves; a link to it would break.
    private static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        let readOnly = (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return !readOnly
    }

    /// What /usr/local/bin/nxtrm points at, if it is a link.
    private static var installedTarget: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: installPath)
    }

    static var isInstalled: Bool { installedTarget == script?.path }

    /// At launch: link /usr/local/bin/nxtrm to this app when that needs no password, so other terminals
    /// have it too (tabs in Next Term always do). Never replaces anything that is not a Next Term link.
    static func registerQuietly() {
        guard let script, isInStableLocation, !isInstalled else { return }
        let directory = (installPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: directory) else { return }
        if let current = installedTarget {
            // Ours from an older copy of the app (moved, or a different version): repoint it.
            guard current.hasSuffix("/Contents/Resources/bin/\(CommandLineOpen.toolName)") else { return }
            try? FileManager.default.removeItem(atPath: installPath)
        } else if FileManager.default.fileExists(atPath: installPath) {
            return // someone else's nxtrm
        }
        try? FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: script.path)
    }

    /// Shell menu: link it, asking for an administrator password when /usr/local/bin needs one.
    static func install(from window: NSWindow?) {
        func tell(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = text
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        guard let script else {
            return tell("Only the installed app has the command", "Build the app with scripts/build-dmg.sh, or run it from Applications.", style: .warning)
        }
        guard isInStableLocation else {
            return tell("Move Next Term to Applications first",
                        "It is running from a disk image or a temporary location, and the command would stop working once it moves.",
                        style: .warning)
        }
        if let current = installedTarget, !current.hasSuffix("/Contents/Resources/bin/\(CommandLineOpen.toolName)") {
            return tell("Another “\(CommandLineOpen.toolName)” is installed", "\(installPath) is not Next Term’s; remove it first.", style: .warning)
        }
        let directory = (installPath as NSString).deletingLastPathComponent
        var installed = false
        if FileManager.default.isWritableFile(atPath: directory) {
            try? FileManager.default.removeItem(atPath: installPath)
            installed = (try? FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: script.path)) != nil
        } else {
            // One password prompt, as editors do for their command (`code`, `subl`).
            let shell = "/bin/mkdir -p \(ShellQuote.quote(directory)) && /bin/ln -sfh \(ShellQuote.quote(script.path)) \(ShellQuote.quote(installPath))"
            let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            installed = error == nil && isInstalled
            if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 { return } // cancelled
        }
        if installed {
            tell("“\(CommandLineOpen.toolName)” is installed",
                 "In any terminal: “nxtrm .” opens the folder as a project, “nxtrm file:42” opens a file at line 42.")
        } else {
            tell("“\(CommandLineOpen.toolName)” could not be installed", "Next Term could not write \(installPath).", style: .warning)
        }
    }
}
