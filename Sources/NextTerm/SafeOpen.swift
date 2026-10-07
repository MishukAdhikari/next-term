import AppKit
import UniformTypeIdentifiers

/// Opening a file from the terminal or the project tree should never quietly run code: a cloned repo
/// carries no quarantine flag, so Gatekeeper would not ask. Apps, scripts and executables get a prompt.
enum SafeOpen {
    static func open(_ url: URL, from window: NSWindow?) {
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let target = target(of: url) else { return NSSound.beep() }
        guard let reason = runsCode(target) else {
            NSWorkspace.shared.open(target)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open “\(url.lastPathComponent)”?"
        alert.informativeText = "\(reason) Opening it can run code from this folder."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([target])
            case .alertSecondButtonReturn: NSWorkspace.shared.open(target)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// What opening `url` really opens: a symlink or a Finder alias named readme.md can point at a
    /// .command file or an app. nil for an alias that no longer resolves.
    static func target(of url: URL) -> URL? {
        var target = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
        if (try? target.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
            guard let resolved = try? URL(resolvingAliasFileAt: target) else { return nil }
            target = resolved.resolvingSymlinksInPath()
        }
        return target
    }

    /// Handlers that execute whatever they open.
    static let launchers: Set<String> = [
        "org.python.PythonLauncher", "com.apple.JavaLauncher", "com.apple.installer",
        "com.apple.automator.Automator-Application-Stub",
    ]
    /// Terminals run scripts they are handed, but only display documents (Warp shows Markdown, for one).
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "me.mishuk.nextterm",
    ]
    private static let runningExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "jar", "workflow", "action", "pkg", "mpkg", "prefpane",
        "saver", "fileloc", "inetloc", "webloc", "scpt", "applescript", "osax", "kext", "plugin", "bundle",
    ]

    /// Why opening `url` would run something, or nil if it is just a document.
    static func runsCode(_ url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isExecutableKey, .isDirectoryKey, .isApplicationKey])
        if values?.isApplication == true { return "It is an application." }
        if let type = values?.contentType {
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return "It is an application." }
            if type.conforms(to: .shellScript) || type.conforms(to: .executable) || type.conforms(to: .unixExecutable) {
                return "It is a script or a program."
            }
        }
        if runningExtensions.contains(url.pathExtension.lowercased()) { return "It is a launcher, installer or script." }
        if values?.isDirectory == false, values?.isExecutable == true { return "It is marked executable." }
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url), let id = Bundle(url: app)?.bundleIdentifier {
            let type = values?.contentType
            let isDocument = type.map { $0.conforms(to: .text) && !$0.conforms(to: .script) } ?? false
            if launchers.contains(id) || (terminals.contains(id) && !isDocument) {
                return "It opens in \(FileManager.default.displayName(atPath: app.path)), which runs it."
            }
        }
        return nil
    }
}
