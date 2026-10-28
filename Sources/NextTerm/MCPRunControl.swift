import AppKit
import NextTermCore

/// run_command: a command the user has to run themselves (sudo, a login such as `gh auth login`, anything that asks for a
/// password), which an agent would otherwise print for them to copy or type after `!`.
///
/// The user sees it in an AgentApprovalWindow: the command in its box as it will be typed, the agent's reason as its own
/// words, and Run as the primary. Only that click starts it, under a remote connection's grant too: what runs is the
/// user's to start. It then runs in a new pane below the agent's tab (on its host for a remote tab), or, for an agent
/// outside Next Term's tabs, in a new tab in `directory`. The pane takes the keyboard and its window comes forward, as the
/// user has just clicked to run something that may ask them for a password.
///
/// The call waits for the command to end, within its 50 seconds: `ran`, with `exit_code` when the shell reports it and
/// `output` (the pane's last lines, as read_tab gives them), or `running` with a request_id to keep waiting. The pane
/// stays for the user; its id is `tab_id`.
extension MCPWriteControl {
    /// A command typed in its pane, for the calls that wait for it: the first, and each one with its request_id.
    final class Run {
        let id = UUID().uuidString.lowercased()
        let asker: String
        let pane: TerminalTab
        /// Commands the pane had run at its prompt before this one was typed.
        var before = 0
        var typed = false
        var answer: [String: Any]?
        var waiters: [(token: UUID, reply: Reply)] = []
        /// When a call last waited for it: a command nobody has asked about for half an hour is no longer watched.
        var lastAsked = TerminalTab.now

        init(asker: String, pane: TerminalTab) {
            self.asker = asker
            self.pane = pane
        }

        var tabID: String { pane.id.uuidString.lowercased() }
    }

    /// The commands run for agents, by request id, until 10 minutes after their answer.
    private(set) static var runs: [String: Run] = [:]

    static func runCommand(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        if let id = (arguments["request_id"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty {
            guard let run = runs[id], run.asker == context.asker else {
                return reply(MCPControl.fail("No open request has that id; call run_command with the command to ask the user again."))
            }
            return wait(run, until: TerminalTab.now + answerWithin, reply: reply)
        }
        guard let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty,
              command.count <= 2000, SecretRun.isOneLine(command) else {
            return reply(MCPControl.fail("Give command: one line, at most 2,000 characters."))
        }
        if SecretMask.current.masked(command).count > 0 {
            return reply(MCPControl.fail("The command holds a stored key's value; run_with_secrets runs a command with a key by its name."))
        }
        let caller = context.caller
        let callerWindow = caller.flatMap(MCPControl.controller(of:))
        // Where it runs is settled here, as the window says it: below the caller's pane while that has a window, else a
        // new tab in `directory`.
        let beside = callerWindow == nil ? nil : caller
        var directory: String?
        if let raw = arguments["directory"] {
            if caller?.remote != nil {
                return reply(MCPControl.fail("Beside a remote tab the command runs on its host, in that tab's folder: leave directory out."))
            }
            guard let path = SecretsMCP.absoluteFolder(raw) else { return reply(MCPControl.fail("directory is an absolute folder on this Mac.")) }
            directory = path
        }
        let place: String
        if let caller, let controller = callerWindow {
            let folder = directory ?? caller.remote.map { "\(caller.directory) on \($0.host.name)" } ?? caller.currentDirectory()
            place = "It runs in a new pane below \u{201C}\(SecretApprovalPanel.sanitized(caller.title, limit: 60))\u{201D} in \(Self.place(controller)), in \(folder)."
        } else if let directory {
            place = "It runs in a new tab in \(directory)."
        } else {
            return reply(MCPControl.fail("Give directory: outside Next Term's tabs the command runs in a new tab in that folder."))
        }
        let ask = Ask(title: "An agent asks you to run a command",
                      details: place + " The pane takes the keyboard, for a password or a prompt. What it prints goes back to the agent, stored keys masked.",
                      command: command, approveTitle: "Run")
        // Asked on the Mac under any policy: a grant lets a connection change things, not start what the user runs.
        let asked = Context(caller: caller, approval: .askOnMac, reason: context.reason, asker: context.asker, who: context.who,
                            projects: context.projects, isRemote: context.isRemote)
        let started = TerminalTab.now
        approve(ask, asked, reply: reply) { _, window in
            window?.finish()
            guard let pane = openPane(beside: beside, directory: directory) else {
                return reply(MCPControl.fail("Your tab closed meanwhile; nothing ran."))
            }
            let run = Run(asker: context.asker, pane: pane)
            runs[run.id] = run
            MCPControl.driven.insert(pane.id)
            MCPControl.whenReady(pane, until: TerminalTab.now + 10) {
                guard MCPControl.canType(pane) else {
                    return finish(run, ["status": "refused", "tab_id": run.tabID, "note": "Next Term couldn't type the command in the new pane; nothing ran."])
                }
                run.before = pane.status.commandsAtPrompt
                MCPControl.type(command, into: pane, submit: true)
                run.typed = true
                watch(run)
            }
            wait(run, until: max(started + answerWithin, TerminalTab.now + 2), reply: reply)
        }
    }

    /// The pane the command runs in, with the keyboard: below the caller's pane (on its host for a remote tab), or a new
    /// tab in `directory` for a caller outside the tabs. Nil when the caller's tab has closed.
    private static func openPane(beside caller: TerminalTab?, directory: String?) -> TerminalTab? {
        let controller: TerminalWindowController
        let pane: TerminalTab
        if let caller {
            guard let window = MCPControl.controller(of: caller),
                  let made = window.split(vertical: false, from: caller, directory: directory, focus: false, byAgent: true) else { return nil }
            (controller, pane) = (window, made)
        } else if let directory {
            controller = MCPControl.window(for: directory).0
            pane = controller.addTab(directory: directory, select: false, byAgent: true)
        } else {
            return nil
        }
        // The user's click on Run is their choice of it: its window comes forward and it takes the keyboard.
        pane.view.awaitsChoice = false
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.show(pane)
        controller.window?.makeFirstResponder(pane.view)
        controller.refresh()
        return pane
    }

    /// Follows the pane until the command ends there (its shell is at the prompt again, one command on) or the pane goes. A
    /// remote shell Next Term follows only by polling may finish a quick command between two looks: the call then answers
    /// running, and read_tab shows how it went.
    private static func watch(_ run: Run) {
        guard run.answer == nil, runs[run.id] === run else { return }
        let pane = run.pane
        if TerminalTab.now - run.lastAsked > 1800 { runs[run.id] = nil; return }
        let gone = pane.exited || MCPControl.controller(of: pane) == nil
        if gone || (pane.status.commandsAtPrompt > run.before && !pane.status.running) {
            return MCPControl.whenLineReported(pane, until: TerminalTab.now + 0.2) { finish(run, ended(run, gone: gone)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { watch(run) } }
    }

    /// How the command ended: its exit code when the shell reports one, and the pane's last lines as read_tab gives them.
    private static func ended(_ run: Run, gone: Bool) -> [String: Any] {
        var answer: [String: Any] = ["status": "ran", "tab_id": run.tabID]
        if gone {
            answer["status"] = "closed"
            answer["note"] = "The pane closed before the command was seen to end; ask the user how it went."
            return answer
        }
        if let code = run.pane.status.exitCode {
            answer["exit_code"] = Int(code)
        } else {
            answer["note"] = "This pane's shell doesn't report exit codes: output shows how it ended."
        }
        let screen = MCPControl.screenFields(run.pane, lines: 40)["screen"] as? String ?? ""
        answer["output"] = screen.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return answer
    }

    /// Answers with how the command ended, or, at `deadline`, that it still runs (or that its pane is starting).
    private static func wait(_ run: Run, until deadline: TimeInterval, reply: @escaping Reply) {
        run.lastAsked = TerminalTab.now
        if let answer = run.answer { return reply(MCPControl.ok(answer)) }
        let token = UUID()
        run.waiters.append((token, reply))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - TerminalTab.now)) {
            MainActor.assumeIsolated {
                guard let index = run.waiters.firstIndex(where: { $0.token == token }) else { return }
                run.waiters.remove(at: index)
                let note = run.typed
                    ? "It still runs in the pane (perhaps waiting for the user there). Call again with only request_id to keep waiting; read_tab with tab_id shows it."
                    : "The pane is starting. Call again with only request_id to keep waiting."
                reply(MCPControl.ok(["status": run.typed ? "running" : "pending", "request_id": run.id, "tab_id": run.tabID, "note": note]))
            }
        }
    }

    private static func finish(_ run: Run, _ answer: [String: Any]) {
        guard run.answer == nil else { return }
        run.answer = answer
        let waiters = run.waiters
        run.waiters = []
        for waiter in waiters { waiter.reply(MCPControl.ok(answer)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            MainActor.assumeIsolated { if runs[run.id] === run { runs[run.id] = nil } }
        }
    }
}
