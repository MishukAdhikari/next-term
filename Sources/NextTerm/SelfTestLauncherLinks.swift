#if DEBUG
import AppKit
import NextTermCore

/// Launchers' way in: nextterm:// links (LinkHandler) bring a tab forward with the keyboard, find the agent waiting for
/// the user, open Go to Anything and a folder; `nxtrm call` answers a tool through the app's socket.
extension SelfTest {
    static func launcherLinksChecks(_ c: TerminalWindowController) async {
        guard let window = c.window else { return check(false, "Links: a window to start from") }
        guard await bringToFront(window) else { return note("Links: skipped, " + notFrontmost(window)) }
        let first = c.activeTab
        let other = c.addTab(directory: nil, select: false)
        defer { c.remove(other) }

        // A tab by its id: in front, with the keyboard.
        LinkHandler.follow(URL(string: "nextterm://tab?id=" + other.id.uuidString)!)
        let shown = await wait(3) { c.activeTab === other && window.firstResponder === other.view }
        check(shown, "Links: nextterm://tab brings that tab forward with the keyboard")

        // The tab waiting for the user (a bell, as a waiting agent rings it), while another tab is in front.
        other.status.setVisible(true)
        other.view.send(txt: "sleep 0.5; printf '\\a'\r")
        _ = await wait(3) { other.status.running }
        if let first { c.show(first) }
        let rang = await wait(5) { other.status.state == .attention }
        check(rang && LinkHandler.waiting() === other, "Links: nextterm://attention finds the tab that waits", other.status.state.rawValue)
        LinkHandler.follow(.attention)
        check(await wait(3) { c.activeTab === other }, "Links: nextterm://attention brings it forward")

        // Go to Anything, over the window in front.
        LinkHandler.follow(URL(string: "nextterm://goto")!)
        let opened = await wait(3) { GoToAnythingPanel.open?.isVisible == true }
        check(opened, "Links: nextterm://goto opens Go to Anything")
        GoToAnythingPanel.open?.close()

        // nxtrm call: list_tabs through the socket, the tab's id in it; a tool that doesn't exist refuses with exit 1.
        let socket = MCPControlServer.shared.path
        let listed = await runCLI(["call", "list_tabs"], socket: socket)
        check(listed.status == 0 && listed.output.lowercased().contains(other.id.uuidString.lowercased()),
              "Links: nxtrm call list_tabs prints the tabs", "exit \(listed.status): \(listed.output.prefix(200))")
        let refused = await runCLI(["call", "no_such_tool"], socket: socket)
        check(refused.status == 1, "Links: nxtrm call refuses a tool that doesn't exist", "exit \(refused.status)")
        let badJSON = await runCLI(["call", "show_tab", "not json"], socket: socket)
        check(badJSON.status == 2, "Links: nxtrm call refuses arguments that aren't JSON", "exit \(badJSON.status)")
    }

    /// This binary as `nxtrm`, its exit status and what it printed.
    private static func runCLI(_ arguments: [String], socket: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
                process.arguments = ["--cli"] + arguments
                var environment = ProcessInfo.processInfo.environment
                environment[MCPServer.socketVariable] = socket
                process.environment = environment
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                guard (try? process.run()) != nil else { return done.resume(returning: (-1, "")) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
#endif
