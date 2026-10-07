import AppKit
import NextTermCore

/// The window's last tab takes the window with it, so a file unsaved in its editor is asked about first, as
/// closing the window asks, whichever way the tab goes (⌘W, `exit`, an agent's close_tab), and nothing is
/// lost. And a Dock click while every window is minimized brings one back rather than opening another.
extension SelfTest {
    static func lastTabChecks() async {
        let app = AppDelegate.shared!
        let root = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-last-tab-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.txt")
        try? "one\n".write(to: file, atomically: true, encoding: .utf8)
        func onDisk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

        // A window with one tab, and the file edited in it but not saved.
        let w = app.openWindow(directory: root.path)
        var welcome: Bool?
        let closing = w.onClose
        w.onClose = { closed, flag in
            welcome = flag
            closing?(closed, flag)
        }
        guard let window = w.window, let tab = w.tabs.first else { return check(false, "a window opens for the last-tab checks") }
        _ = await wait(20) { tab.status.integrated }
        w.openFile(file)
        guard let editor = w.editorArea.activeEditor else { return check(false, "the file opens for the last-tab checks") }
        let doc = editor.document
        editor.textView.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))

        // ⌘W in the terminal, on the window's last tab, its shell idle.
        window.makeFirstResponder(tab.view)
        w.closeTab(nil)
        check(doc.isDirty && window.attachedSheet != nil && w.tabs.first === tab && window.isVisible,
              "⌘W on the window's last tab, with a file unsaved, asks before the window goes",
              "dirty \(doc.isDirty), sheet \(window.attachedSheet != nil), tabs \(w.tabs.count)")
        let asked = sheetWords(window)
        check(asked.contains("Save changes to “notes.txt” before closing?") && asked.contains("closes the window"),
              "it asks as closing the window does, naming the file", asked)
        check(await pressSheetButton("Cancel", in: window), "the sheet offers Cancel")
        await pause(0.2)
        check(window.isVisible && w.tabs.first === tab && !tab.exited && doc.isDirty && onDisk() == "one\n",
              "Cancel keeps the window, its tab and the unsaved edit", "tabs \(w.tabs.count), exited \(tab.exited), on disk \(onDisk().debugDescription)")

        // `exit` in that tab: the same question. Cancel leaves a fresh shell in the window.
        tab.view.send(txt: "\u{15}exit\r")
        let askedAgain = await wait(5) { window.attachedSheet != nil }
        check(askedAgain && tab.exited && window.isVisible && doc.isDirty, "`exit` in the window's last tab asks too",
              "sheet \(askedAgain), exited \(tab.exited)")
        check(sheetWords(window).contains("has ended"), "and says its shell has ended", sheetWords(window))
        _ = await pressSheetButton("Cancel", in: window)
        let replaced = await wait(3) { w.tabs.count == 1 && w.tabs.first !== tab }
        guard let shell = w.tabs.first, replaced, !shell.exited else {
            return check(false, "Cancel after `exit` keeps the window, with a fresh shell in it", "tabs \(w.tabs.count)")
        }
        check(window.isVisible && doc.isDirty && onDisk() == "one\n", "Cancel after `exit` keeps the window, with a fresh shell in it")
        _ = await wait(20) { shell.status.integrated }
        check(canonicalPath(shell.currentDirectory()) == canonicalPath(tab.directory), "in the folder the last one was in",
              shell.currentDirectory() + " vs " + tab.directory)

        // A shell that failed (`exit 3`) stays, to show why. ⌘W asks, and Cancel leaves that tab as it was.
        shell.view.send(txt: "\u{15}exit 3\r")
        let failed = await wait(5) { shell.exited }
        window.makeFirstResponder(shell.view)
        w.closeTab(nil)
        check(failed && window.attachedSheet != nil && doc.isDirty, "⌘W on a last tab whose shell failed asks too",
              "exited \(shell.exited), sheet \(window.attachedSheet != nil)")
        _ = await pressSheetButton("Cancel", in: window)
        await pause(0.2)
        let reason = shell.screenTail(6).joined(separator: " ")
        check(window.isVisible && w.tabs.count == 1 && w.tabs.first === shell && reason.contains("exited with code 3"),
              "Cancel keeps that tab and why its shell ended, not a fresh shell", "tabs \(w.tabs.count), same \(w.tabs.first === shell): \(reason)")

        // A fresh shell, and something running in it: one sheet names the unsaved file and what closing stops.
        // Save saves first.
        let live = w.addTab(directory: root.path)
        w.remove(shell)
        _ = await wait(20) { live.status.integrated }
        live.view.send(txt: "sleep 30\r")
        _ = await wait(3) { live.status.running }
        window.makeFirstResponder(live.view)
        w.closeTab(nil)
        let both = sheetWords(window)
        check(both.contains("“notes.txt”") && both.contains("stops “sleep"), "with a program running, the one sheet names the unsaved file and what closing stops", both)
        check(await pressSheetButton("Save", in: window), "the sheet offers Save")
        let gone = await wait(5) { !app.controllers.contains { $0 === w } }
        check(gone && !window.isVisible && onDisk() == "edited one\n", "Save saves the file, then the window goes with its last tab",
              "closed \(gone), on disk \(onDisk().debugDescription)")
        check(welcome == true, "and, had it been the last window, the Welcome window would follow", "\(String(describing: welcome))")

        // An agent's close_tab on the last tab: the user is asked, and the agent is told so. Don't Save: the
        // window goes, and the file on disk is as it was.
        let v = app.openWindow(directory: root.path)
        if let vWindow = v.window, let vTab = v.tabs.first {
            _ = await wait(20) { vTab.status.integrated }
            v.openFile(file)
            v.editorArea.activeEditor?.textView.insertText("again ", replacementRange: NSRange(location: 0, length: 0))
            if MCPControlServer.shared.isRunning, let mcp = MCPTestClient(socket: MCPControlServer.shared.path) {
                _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
                let reply = await mcp.call(2, "tools/call", ["name": "close_tab", "arguments": ["tab_id": vTab.id.uuidString.lowercased()]])
                let result = reply?["result"] as? [String: Any]
                let told = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                mcp.close()
                let json = (try? JSONSerialization.jsonObject(with: Data(told.utf8))) as? [String: Any]
                check(json?["closed"] as? Bool == false && json?["asking_user"] != nil && vWindow.attachedSheet != nil && v.tabs.first === vTab,
                      "MCP: close_tab on the last tab asks the user, and says so", told)
            } else {
                note("agent control is off: the last tab is closed as close_tab closes it")
                v.remove(vTab)
                check(vWindow.attachedSheet != nil, "closing the last tab as close_tab does asks the user")
            }
            check(await pressSheetButton("Don’t Save", in: vWindow), "the sheet offers Don’t Save")
            let closed = await wait(5) { !app.controllers.contains { $0 === v } }
            check(closed && onDisk() == "edited one\n", "Don’t Save: the window goes, and the file on disk is as it was", onDisk().debugDescription)
        }

        // Nothing unsaved: the last tab closes its window at once, as always.
        let u = app.openWindow(directory: root.path)
        if let uTab = u.tabs.first {
            _ = await wait(20) { uTab.status.integrated }
            u.closeTab(nil)
            let asked = u.window?.attachedSheet != nil
            let closed = await wait(3) { !app.controllers.contains { $0 === u } }
            check(!asked && closed, "with nothing unsaved, closing the last tab closes its window at once", "asked \(asked), closed \(closed)")
        }
    }

    /// Every window minimized, then a click on the Dock icon: the window used last comes back, and no other
    /// window opens (it used to open a second one for the same project).
    static func dockReopenChecks(_ c: TerminalWindowController) async {
        let app = AppDelegate.shared!
        guard let window = c.window else { return }
        let windows = app.controllers.compactMap(\.window)
        window.makeKeyAndOrderFront(nil)
        for other in windows where other !== window { other.miniaturize(nil) }
        window.miniaturize(nil) // last, so it is the one used last
        guard await wait(8, { windows.allSatisfy(\.isMiniaturized) }) else {
            windows.forEach { $0.deminiaturize(nil) }
            return note("the windows did not minimize, so the Dock click was not checked")
        }
        let count = app.controllers.count
        let handled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let back = await wait(5) { !window.isMiniaturized && window.isVisible }
        let others = windows.filter { $0 !== window && !$0.isMiniaturized }.count
        check(back && others == 0 && app.controllers.count == count && !handled,
              "a Dock click with every window minimized brings back the one used last, and opens no other",
              "back \(back), others back \(others), windows \(count) → \(app.controllers.count), AppKit's reopen \(handled)")
        for other in windows where other !== window { other.deminiaturize(nil) }
        _ = await wait(5) { windows.allSatisfy { !$0.isMiniaturized } }
        window.makeKeyAndOrderFront(nil)
    }

    /// The words in the sheet over `window`: an alert's title and text.
    private static func sheetWords(_ window: NSWindow) -> String {
        func fields(_ view: NSView) -> [String] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? fields($0) } }
        return window.attachedSheet?.contentView.map(fields)?.joined(separator: " ") ?? ""
    }

    /// Clicks the button titled `title` in the sheet over `window`.
    private static func pressSheetButton(_ title: String, in window: NSWindow) async -> Bool {
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        guard await wait(5, { window.attachedSheet?.contentView.map(buttons)?.contains { $0.title == title } == true }),
              let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
        button.performClick(nil)
        return true
    }
}
