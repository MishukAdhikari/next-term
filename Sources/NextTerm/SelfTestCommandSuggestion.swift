import AppKit
import Darwin
import NextTermCore

/// Suggest a Command (File › Suggest a Command…), with a stand-in agent: a script in place of Claude Code that writes
/// down what it was given (its folder, its environment, its arguments, the prompt) and answers by the request. No
/// network, and no agent of the user's runs. Apple's on-device model is asked once where this Mac has it.
extension SelfTest {
    #if DEBUG
    /// The stand-in's answers, by the words in the request.
    private static let standInAgent = #"""
        #!/bin/sh
        LOG="@LOG@"
        mkdir -p "$LOG"
        pwd > "$LOG/pwd"
        ls -A > "$LOG/ls"
        env > "$LOG/env"
        printf '%s\n' "$@" > "$LOG/args"
        cat > "$LOG/prompt"
        answer() { printf '{"type":"result","is_error":false,"result":"","structured_output":{"command":"%s"}}' "$1"; }
        case "$(cat "$LOG/prompt")" in
          *"Request: find large files"*) answer 'find . -size +100M' ;;
          *"Request: two lines"*) answer 'cd /tmp\nls' ;;
          *"Request: hidden"*) answer 'ls \u202etxt.exe' ;;
          *"Request: risky"*) answer 'sudo rm -rf /tmp/nt-suggest-none' ;;
          *"Request: late"*) sleep 1.5; answer 'ls -la' ;;
          *"Request: fail"*) echo 'stand-in: not logged in' >&2; exit 3 ;;
          *"Request: slow"*) sleep 30 & echo $! > "$LOG/child"; sleep 30 ;;
          *) answer 'pwd' ;;
        esac
        """#

    static func commandSuggestionChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Suggest a Command: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 90 s)") }
        let log = dir.appendingPathComponent("agent-log")
        let agent = dir.appendingPathComponent("stand-in-agent")
        try? standInAgent.replacingOccurrences(of: "@LOG@", with: log.path).write(to: agent, atomically: true, encoding: .utf8)
        chmod(agent.path, 0o755)
        CommandSuggestionRunner.testProgram = agent.path
        CommandSuggestionRunner.testTimeout = 2
        defer {
            CommandSuggestionRunner.testProgram = nil
            CommandSuggestionRunner.testTimeout = nil
            CommandSuggestionPanel.current?.panel.close()
        }
        func logged(_ name: String) -> String { (try? String(contentsOf: log.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        // Off by default: the menu item is off, and Settings offers Off first.
        CompletionPreferences.suggestion = nil
        CompletionPreferences.mode = .nextTerm
        guard let tab = await completionTab(c, in: dir, zshrc: plainZshrc, name: "suggest") else { return }
        defer { c.remove(tab) }
        let item = NSMenuItem(title: "Suggest a Command…", action: #selector(CommandSuggestionController.suggestCommand(_:)), keyEquivalent: "")
        let controller = CommandSuggestionController.shared
        check(!controller.validateMenuItem(item), "Suggest a Command: off by default, its menu item is off")
        let settingsRow = CommandSuggestionSettingsView()
        check(settingsRow.titles.first == "Off" && settingsRow.noteText.contains("nothing is ever sent"),
              "Suggest a Command: Settings offers Off first, and says nothing is sent", "\(settingsRow.titles) \(settingsRow.noteText)")
        UserDefaults.standard.set("some-agent", forKey: CompletionPreferences.suggestionKey)
        check(CompletionPreferences.suggestion == nil, "Suggest a Command: an unknown stored choice is Off")

        // The last command, with a password in it, is shown masked before anything is sent.
        CompletionPreferences.suggestion = CommandSuggestion.claude.id
        tab.view.send(txt: "echo --password=S3cretPass API_KEY=sk-live-0123456789abcdefghij\r")
        _ = await wait(3) { tab.status.commandsStarted > 0 && !tab.status.running }
        _ = await wait(3) { tab.completion.state.isArmed }
        check(controller.validateMenuItem(item), "Suggest a Command: on, its menu item is on at a shell prompt")
        func open() async -> CommandSuggestionPanel? {
            _ = await focus(c, tab)
            controller.suggestCommand(nil)
            _ = await wait(2) { CommandSuggestionPanel.current?.panel.isVisible == true }
            return CommandSuggestionPanel.current
        }
        func closed() async -> Bool { await wait(5) { CommandSuggestionPanel.current == nil } }
        guard let first = await open() else { return check(false, "Suggest a Command: the panel opens from the menu") }
        check(first.contextShown.contains("--password=•••") && !first.contextShown.contains("S3cretPass")
              && !first.contextShown.contains("sk-live-0123456789abcdefghij") && first.contextShown.contains("Claude Code"),
              "Suggest a Command: the panel shows the last command, secrets masked, before anything is sent", first.contextShown)
        check(!FileManager.default.fileExists(atPath: log.path), "and nothing is sent until the sentence is submitted")

        // AE10: a command on the line, and nothing runs.
        let before = tab.status.commandsStarted
        first.type("find large files here")
        first.submit()
        check(await closed(), "AE10: the stand-in agent answers and the panel closes", CommandSuggestionPanel.current?.statusShown ?? "")
        check(await wait(3) { promptLine(tab).hasSuffix("find . -size +100M") } && tab.status.commandsStarted == before && !tab.status.running,
              "AE10: the command is on the line, and nothing ran", promptLine(tab))
        let prompt = logged("prompt")
        check(prompt.contains("Request: find large files here") && prompt.contains("Folder: \(dir.path)") && prompt.contains("Shell: zsh")
              && !prompt.contains("S3cretPass") && !prompt.contains("sk-live-0123456789abcdefghij") && !prompt.contains("Recent output"),
              "Suggest a Command: the agent gets the sentence, the folder, the shell and the last command masked; no output unasked", prompt)
        let environment = logged("env").split(separator: "\n")
        check(!environment.isEmpty && !environment.contains { $0.hasPrefix("NEXTTERM") || $0.hasPrefix(MCPServer.socketVariable) },
              "Suggest a Command: the agent's environment has nothing of Next Term's", environment.filter { $0.hasPrefix("NEXT") }.joined(separator: " "))
        let folder = logged("pwd").trimmingCharacters(in: .whitespacesAndNewlines)
        check(folder.contains("nt-suggest-") && logged("ls").isEmpty && !FileManager.default.fileExists(atPath: folder),
              "Suggest a Command: the agent ran in an empty folder of its own, gone afterwards", folder)
        check(logged("args").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) == CommandSuggestion.claude.arguments,
              "Suggest a Command: the agent's arguments are Claude Code's with no tools and no MCP")
        await clearLine(tab)

        // Several lines go on as one edit through the hook, and run only with Return.
        guard let multi = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        multi.type("two lines")
        multi.submit()
        check(await closed(), "Suggest a Command: several lines go on the line in a zsh tab with the hook")
        let tail = tab.screenTail(3).joined(separator: "\n")
        check(tail.contains("cd /tmp") && tail.hasSuffix("ls") && tab.status.commandsStarted == before, "and as one edit, with nothing run", tail)
        await clearLine(tab)

        // Recent output only when included, after seeing it masked; for that one request.
        guard let withOutput = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        withOutput.askToIncludeOutput()
        _ = await wait(2) { CommandSuggestionPanel.outputQuestion != nil }
        if let question = CommandSuggestionPanel.outputQuestion {
            let shown = ((question.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
            check(shown.contains("API_KEY=") && !shown.contains("sk-live-0123456789abcdefghij"),
                  "Suggest a Command: recent output is shown masked before it is included", shown.suffix(200).description)
            question.buttons.first?.performClick(nil)
            _ = await wait(2) { CommandSuggestionPanel.outputQuestion == nil }
            withOutput.type("print the folder")
            withOutput.submit()
            _ = await closed()
            let sent = logged("prompt")
            check(sent.contains("Recent output:") && !sent.contains("sk-live-0123456789abcdefghij"),
                  "and sent masked once included", sent.suffix(300).description)
        } else {
            check(false, "Suggest a Command: Include Recent Output… asks first")
        }
        await clearLine(tab)
        guard let again = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        again.type("print the folder")
        again.submit()
        _ = await closed()
        check(!logged("prompt").contains("Recent output"), "Suggest a Command: the next request has no output until included again")
        await clearLine(tab)

        // Hidden characters and risky commands wait in the panel, spelled out and noted.
        guard let hidden = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        hidden.type("hidden")
        hidden.submit()
        _ = await wait(5) { hidden.stage == .answered }
        check(hidden.resultShown == "ls \\u{202E}txt.exe" && hidden.notesShown.contains("invisible") && CommandSuggestionPanel.current === hidden,
              "Suggest a Command: a direction-changing character is spelled out, and the command waits", hidden.resultShown)
        hidden.panel.close()
        guard let risky = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        risky.type("risky")
        risky.submit()
        _ = await wait(5) { risky.stage == .answered }
        check(risky.notesShown.contains("sudo") && risky.primaryTitle == "Put on Line" && !promptLine(tab).contains("sudo"),
              "Suggest a Command: a risky command gets a note and waits for Put on Line", risky.notesShown)
        risky.submit()
        check(await closed(), "and Put on Line puts it there")
        check(await wait(3) { promptLine(tab).contains("sudo rm -rf") } && tab.status.commandsStarted == before, "with nothing run", promptLine(tab))
        await clearLine(tab)

        // A line changed while it was asked: Replace Line.
        guard let late = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        late.type("late")
        late.submit()
        await pause(0.4)
        tab.view.send(txt: "typed meanwhile")
        _ = await wait(5) { late.stage == .answered }
        check(late.primaryTitle == "Replace Line" && promptLine(tab).hasSuffix("typed meanwhile"),
              "Suggest a Command: a line changed while it was asked waits for Replace Line", "\(late.primaryTitle) | \(promptLine(tab))")
        late.submit()
        let replaced = await closed()
        check(await wait(3) { replaced && promptLine(tab).hasSuffix("ls -la") && !promptLine(tab).contains("typed") },
              "and Replace Line replaces it", promptLine(tab))
        await clearLine(tab)

        // The agent fails: its message; too slow: stopped, with what it started; Cancel: the same.
        guard let failing = await open() else { return check(false, "Suggest a Command: the panel opens again") }
        failing.type("fail")
        failing.submit()
        _ = await wait(5) { failing.stage == .asking && !failing.statusShown.hasPrefix("Asking") }
        check(failing.statusShown.contains("status 3") && failing.statusShown.contains("not logged in") && !CommandSuggestionRunner.isRunning(for: tab),
              "Suggest a Command: an agent that fails says why", failing.statusShown)
        try? FileManager.default.removeItem(at: log.appendingPathComponent("child"))
        failing.type("slow")
        failing.submit()
        check(await wait(6) { failing.statusShown.contains("took more than 2 s") }, "Suggest a Command: an agent past its time is stopped",
              failing.statusShown)
        check(await gone(logged("child")), "and so is what it started (its process group)", logged("child"))
        try? FileManager.default.removeItem(at: log.appendingPathComponent("child"))
        failing.submit()
        _ = await wait(2) { !logged("child").isEmpty }
        failing.panel.close()
        check(await gone(logged("child")) && !CommandSuggestionRunner.isRunning(for: tab), "Suggest a Command: Cancel stops the agent and what it started")

        // A tab whose zsh has no hook (opened with Tab completion off): one line is typed in, several stay to copy.
        CompletionPreferences.set(.off)
        let plain = c.addTab(directory: dir.path)
        defer { c.remove(plain) }
        CompletionPreferences.mode = .nextTerm
        _ = await wait(20) { plain.status.integrated }
        await pause(0.5)
        if await focus(c, plain), plain.completion.state.arm == nil {
            controller.suggestCommand(nil)
            _ = await wait(2) { CommandSuggestionPanel.current != nil }
            if let lines = CommandSuggestionPanel.current {
                lines.type("two lines")
                lines.submit()
                _ = await wait(5) { lines.stage == .answered }
                check(lines.primaryTitle.isEmpty && lines.notesShown.contains("copy it") && CommandSuggestionPanel.current === lines,
                      "Suggest a Command: several lines stay in the panel to copy where the shell can't take them as one edit", lines.notesShown)
                lines.panel.close()
            }
            controller.suggestCommand(nil)
            _ = await wait(2) { CommandSuggestionPanel.current != nil }
            if let one = CommandSuggestionPanel.current {
                one.type("find large files")
                one.submit()
                let typed = await closed()
                check(await wait(3) { typed && promptLine(plain).hasSuffix("find . -size +100M") },
                      "Suggest a Command: one line is typed in where there is no hook", promptLine(plain))
            }
            plain.view.send(txt: "\u{3}")
        } else {
            note("Suggest a Command: the tab without the hook could not be checked (\(String(describing: plain.completion.state.arm)))")
        }

        // While a program runs, it is off.
        _ = await focus(c, tab)
        tab.view.send(txt: "sleep 2\r")
        _ = await wait(3) { tab.status.running }
        check(!controller.validateMenuItem(item), "Suggest a Command: off while a program runs in the tab")
        _ = await wait(4) { !tab.status.running }

        await onDeviceChecks(c, tab)
    }

    /// The process in `pidText` has gone (within 3 s).
    private static func gone(_ pidText: String) async -> Bool {
        guard let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return await wait(3) { kill(pid, 0) != 0 && errno == ESRCH }
    }

    /// U16: what Settings says for each state of Apple's on-device model, and one real request where this Mac has it.
    private static func onDeviceChecks(_ c: TerminalWindowController, _ tab: TerminalTab) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let reasons = OnDeviceSuggestion.everyReason
            let texts = reasons.dropFirst().compactMap { $0 }
            check(reasons.first == .some(nil) && Set(texts).count == 3,
                  "Suggest a Command: each state of the on-device model has its own words in Settings", texts.joined(separator: " | "))
            check(CommandSuggestionSettingsView().titles.contains("Apple’s On-Device Model"), "Suggest a Command: Settings offers the on-device model")
            guard OnDeviceSuggestion.unavailable == nil else {
                return note("Suggest a Command: the on-device model isn't ready here (\(OnDeviceSuggestion.unavailable ?? "")), so it isn't asked")
            }
            CompletionPreferences.suggestion = CompletionPreferences.onDevice
            CommandSuggestionRunner.testTimeout = 30
            _ = await focus(c, tab)
            CommandSuggestionController.shared.suggestCommand(nil)
            guard await wait(2, { CommandSuggestionPanel.current != nil }), let panel = CommandSuggestionPanel.current else {
                return check(false, "Suggest a Command: the panel opens for the on-device model")
            }
            check(panel.contextShown.contains("stays on this Mac"), "Suggest a Command: the panel says the on-device model keeps it on this Mac")
            let before = tab.status.commandsStarted
            panel.type("list the files in this folder")
            panel.submit()
            let answered = await wait(30) { CommandSuggestionPanel.current == nil || panel.stage != .waiting }
            let onLine = CommandSuggestionPanel.current == nil && promptLine(tab).count > 2
            check(answered && (onLine || panel.suggestion != nil || !panel.statusShown.isEmpty) && tab.status.commandsStarted == before,
                  "Suggest a Command: the on-device model answers, and nothing runs", onLine ? promptLine(tab) : panel.statusShown)
            CommandSuggestionPanel.current?.panel.close()
            await clearLine(tab)
            return
        }
        #endif
        check(!CommandSuggestionSettingsView().titles.contains("Apple’s On-Device Model"), "Suggest a Command: no on-device model is offered here")
        note("Suggest a Command: the on-device model needs macOS 26 and an SDK with it; skipped")
    }
    #endif
}
