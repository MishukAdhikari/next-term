import AppKit
import CryptoKit
import NextTermCore

#if DEBUG
/// Through your agent from the Add Task sheet, with three agent tabs (cat under the name claude, so the tty echoes
/// what it is given): one done, one working, one with "abc" typed. The rows say which is ready and why the others
/// aren't; a tab that starts working before Add gets nothing; Add types into the done tab only, with no Return, and
/// brings it to the front. The task holds a stored key, and the typed line holds it as •••. Called from
/// `destinationSheetChecks`.
extension SelfTest {
    static func agentSheetChecks(_ c: TerminalWindowController) async {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("nt-task-agents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? FileManager.default.createSymbolicLink(at: fake, withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        var tabs: [TerminalTab] = []
        for name in ["nt-done", "nt-busy", "nt-typed"] {
            let tab = c.addTab(directory: c.project ?? NSTemporaryDirectory())
            tab.userTitle = name
            tabs.append(tab)
        }
        var started = true
        for tab in tabs {
            _ = await wait(20) { tab.status.integrated }
            // Its output goes nowhere; the tty's echo shows what the agent was given.
            tab.view.send(txt: "\u{15}PATH=\(bin.path):$PATH claude >/dev/null\r")
            started = await wait(5) { tab.status.running && tab.status.kind == .agent } && started
        }
        if started {
            await agentRowChecks(c, done: tabs[0], busy: tabs[1], typed: tabs[2])
        } else {
            check(false, "destinations: three fake agent tabs start", tabs.map(\.status.program).joined(separator: ", "))
        }
        AddTaskSheet.current?.pressCancel()
        GitToast.dismiss()
        for tab in tabs {
            tab.view.send(txt: "\u{15}\u{03}")
            _ = await wait(4) { !tab.status.running }
            c.requestClose(tab)
        }
        try? FileManager.default.removeItem(at: bin)
    }

    /// The agent's screen shows the working hint, or nothing.
    private static func setWorking(_ tab: TerminalTab, _ working: Bool) async -> Bool {
        tab.view.feed(text: working ? "\u{1b}[H\u{1b}[2J✻ Working… (esc to interrupt)\r\n" : "\u{1b}[H\u{1b}[2J")
        return await wait(5) { (tab.status.state == .working) == working }
    }

    private static func agentRowChecks(_ c: TerminalWindowController, done: TerminalTab, busy: TerminalTab,
                                       typed: TerminalTab) async {
        let task = "Rename the build step"
        // A stored key in the task: the typed line and What's sent hold it as •••, never its value.
        let savedMask = SecretMask.current
        defer { SecretMask.current = savedMask }
        let value = "nt-agent-key-" + UUID().uuidString.prefix(12)
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let busyNow = await setWorking(busy, true)
        typed.view.send(txt: "abc")
        let hasText = await wait(3) { AgentReadiness.shared.check(typed) == .notReady(.hasText) }
        check(busyNow && hasText, "destinations: one agent tab works and one has text in its prompt",
              "\(busy.status.state) \(AgentReadiness.shared.check(typed))")
        guard let sheet = await destinationSheet(c, task + " token=" + value) else { return }
        sheet.pickDestination(.throughAgent(tracker: "Linear"))
        let rows = sheet.agentTitles
        let expected = ["“nt-done” (Claude Code)", "“nt-busy” (Claude Code) · working",
                        "“nt-typed” (Claude Code) · has your text in its prompt"]
        check(expected.allSatisfy { rows.contains($0) }, "destinations: each agent tab is listed ready, or greyed with why",
              rows.joined(separator: " | "))
        let line = "Types a request to post it to Linear into “nt-done” (Claude Code), with no Return"
        check(sheet.placeText == line && sheet.addTitle == "Type into Tab",
              "destinations: the done tab is picked, and the line says where the request is typed", sheet.placeText)
        // The picked tab starts working before Add: nothing is typed, and the line says why.
        let working = await setWorking(done, true)
        sheet.pressAdd()
        let refused = sheet.placeText.contains("working") && sheet.placeIsRed && AddTaskSheet.current === sheet
        check(working && refused && !screen(done).contains(task),
              "destinations: a tab that started working before Add gets nothing, and the line says working",
              sheet.placeText)
        // It finishes: Add types into it only.
        let finished = await setWorking(done, false)
        sheet.reread()
        check(finished && sheet.canAdd && sheet.placeText == line, "destinations: once it finished, it is ready again",
              sheet.placeText)
        check(!sheet.sentText.contains("\n") && sheet.sentText.contains(" / \(task)"),
              "destinations: with no bracketed paste, What's sent is the request on one line", sheet.sentText)
        check(sheet.sentText.contains("token=•••") && !sheet.sentText.contains(value),
              "destinations: What's sent for the agent holds the key as •••")
        let before = postedToday()
        sheet.pressAdd()
        let typedIn = await wait(5) { AddTaskSheet.current == nil && screen(done).contains(task) }
        check(typedIn && c.activeTab === done, "destinations: Add types the request into the done tab and brings it to the front",
              screen(done))
        check(screen(done).contains("token=•••") && !screen(done).contains(value),
              "destinations: the line typed into the agent tab holds the key as •••, never its value")
        // A Return would have sent the line to the agent and emptied its prompt; the request still sits there.
        check(AgentReadiness.shared.check(done) == .notReady(.hasText), "destinations: no Return goes in with the request")
        check(!screen(busy).contains(task) && !screen(typed).contains(task),
              "destinations: the other two agent tabs are left untouched")
        check(await wait(3) { postedToday() == before + 1 }, "destinations: one line goes in the posted record")
        let toast = "Typed into “nt-done”. Read it there and press Return to send it to Linear."
        check(GitToast.text == toast, "destinations: the notice says where it was typed", GitToast.text ?? "no notice")
        _ = await setWorking(busy, false)
    }

    /// The bottom of a tab's screen as one string, with wrapped rows joined.
    private static func screen(_ tab: TerminalTab) -> String { tab.screenTail(12).joined() }

    /// What this run's report holds so far, read from the file the self-test writes it to.
    static func reportSoFar() -> String {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--self-test"), at + 1 < args.count else { return "" }
        return (try? String(contentsOfFile: args[at + 1], encoding: .utf8)) ?? ""
    }
}
#endif
