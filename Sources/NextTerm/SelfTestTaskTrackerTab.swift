import AppKit
import NextTermCore

#if DEBUG
/// Connect a Tracker's Open in a New Tab, with a made-up `claude` on a made-up PATH: one tab in the home folder titled
/// for the pair, its line typed and not run, refused to agents until it closes, and let go once it has.
extension SelfTest {
    static func connectTrackerTabChecks(_ c: TerminalWindowController, bin: URL, expected: String) async {
        let program = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: program.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        guard let sheet = await connectTrackerSheetAgain(c) else { return }
        let row: ConnectTrackerSheet.RowViews? = sheet.rowViews[.claude]
        check(row?.open?.isHidden == false && row?.notFound?.isHidden == true,
              "connect a tracker: with claude on PATH its row has Open in a New Tab")
        let title = "Connect Linear to Claude Code"
        let before: Set<UUID> = Set(AppDelegate.shared.controllers.flatMap(\.tabs).map(\.id))
        row?.open?.performClick(nil)
        let isNew: (TerminalTab) -> Bool = { (tab: TerminalTab) -> Bool in !before.contains(tab.id) && tab.userTitle == title }
        _ = await wait(10) { AppDelegate.shared.controllers.flatMap(\.tabs).contains(where: isNew) }
        let made: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs).filter(isNew)
        guard made.count == 1, let tab = made.first else {
            return check(false, "connect a tracker: Open in a New Tab makes one tab titled \(title)", "\(made.count)")
        }
        var closed = false
        // The sheet stays open for the next agent by design; it is closed before its tab, so the tab check sees
        // only what closing the tab leaves.
        defer {
            if !closed {
                ConnectTrackerSheet.current?.done()
                closeSecretsTabs([tab], "connect a tracker")
            }
        }
        _ = await wait(10) { tab.status.integrated }
        _ = await wait(8) { secretPipeScreen(tab).contains("linear-server") }
        await pause(1)
        let screen: String = await secretPipeReadTab(tab)
        check(secretPipeEndsWith(screen, expected) && tab.status.commandsRun == 0 && !tab.status.running,
              "connect a tracker: the tab ends with exactly the line, not run", screen)
        check(tab.directory == NSHomeDirectory() && sheet.status.stringValue == ConnectTrackerSheet.typedLine,
              "connect a tracker: the tab is in the home folder, and the sheet says the line is there",
              sheet.status.stringValue)
        check(ConnectTrackerSheet.current === sheet, "connect a tracker: the sheet stays open for the next agent")
        let id: String = tab.id.uuidString.lowercased()
        let typed = await secretPipeTool("send_to_tab", ["tab_id": id, "text": "echo made-up"])
        let pressed = await secretPipeTool("press_keys", ["tab_id": id, "keys": ["enter"]])
        let answered = await secretPipeTool("answer_agent", ["tab_id": id, "question_id": "made-up", "choice": 1])
        let closing = await secretPipeTool("close_tab", ["tab_id": id, "force": true])
        let results: [MCPServer.CallResult] = [typed, pressed, answered, closing]
        let refused: Bool = results.allSatisfy { (result: MCPServer.CallResult) -> Bool in
            result.isError && result.text.contains(ConnectTrackerSheet.lock)
        }
        check(refused && tab.status.commandsRun == 0, "connect a tracker: agents can't type, press keys, answer or close there",
              results.map(\.text).joined(separator: " / "))
        sheet.done()
        _ = await wait(5) { ConnectTrackerSheet.current == nil && c.window?.attachedSheet == nil }
        closeSecretsTabs([tab], "connect a tracker")
        closed = true
        let next: TerminalTab = c.addTab(directory: NSHomeDirectory(), select: false)
        check(ConnectTrackerSheet.inputRefusal(next) == nil, "connect a tracker: a tab no line was typed into isn't refused")
        ConnectTrackerSheet.register(next)
        check(ConnectTrackerSheet.tabs == [next.id] && MCPInputLine.refusal(next) == ConnectTrackerSheet.lock,
              "connect a tracker: the next tab locked lets the closed one go", "\(ConnectTrackerSheet.tabs.count)")
        closeSecretsTabs([next], "connect a tracker")
    }

    private static func connectTrackerSheetAgain(_ c: TerminalWindowController) async -> ConnectTrackerSheet? {
        ConnectTrackerSheet.present(over: c.window)
        guard let sheet = ConnectTrackerSheet.current, await wait(5, { sheet.found?.contains(.claude) == true }) else {
            check(false, "connect a tracker: the sheet finds claude on the made-up PATH")
            return nil
        }
        return sheet
    }
}
#endif
