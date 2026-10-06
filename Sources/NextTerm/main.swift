import AppKit

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
