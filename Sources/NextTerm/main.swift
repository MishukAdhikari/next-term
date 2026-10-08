import AppKit
import NextTermCore

// Read while this is the only thread: reading the umask sets it for a moment (SafeWrite.umask).
_ = SafeWrite.umask

// `nxtrm …` runs this binary as a command line tool: no window, no Dock icon.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cli" {
    CommandLineTool.run(Array(CommandLine.arguments.dropFirst(2)))
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
