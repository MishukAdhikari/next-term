import AppKit
import NextTermCore

/// The door's checks on the main thread, right before a remote call runs (U14), from one fresh read of the tab's
/// screen: the tab rules the connection's options set (R50 to R54, R57, R58, R62), in the plan's order. The first that
/// refuses answers, naming the option to turn on. Nothing is kept between calls, so no earlier read counts.
///
/// herdr's agents (a tab id with a slash) are reached remotely only to read, and only with "Servers: list, check and
/// read changes" on too, until plan 010's options name the rest; typing into one, answering it or closing it stays on
/// this Mac for now.
@MainActor
enum RemoteAccessDoorChecks {
    /// A call refused here, with the options its text names, for the audit line.
    struct Refusal: Equatable {
        let text: String
        let by: [RemoteAccessOption.ID]
    }

    /// What the approval window and the notification say about a call that may run: its tab, the first line of what it
    /// sends, presses or picks, and for an answer, what that approves.
    struct Summary: Equatable {
        var tab: String?
        var sent: String?
        var approved: String?
    }

    enum Outcome: Equatable {
        case run(Summary)
        case refuse(Refusal)
    }

    static let herdrText = "herdr's agents are reached from a remote connection only to read them, for now: type into them, answer "
        + "them or close them on your Mac."

    static func check(_ tool: String, _ arguments: [String: Any], options: RemoteAccessOptions) -> Outcome {
        if let raw = arguments["tab_id"] as? String, HerdrTarget.parse(raw) != nil {
            return herdr(tool, options: options)
        }
        switch tool {
        case "send_to_tab", "press_keys": return typing(tool, arguments, options: options)
        case "answer_agent": return answering(arguments, options: options)
        case "close_tab": return closing(arguments, options: options)
        case "new_tab": return folder(arguments, options: options)
        default: return .run(Summary(tab: tab(arguments)?.title))
        }
    }

    // MARK: herdr's agents

    private static func herdr(_ tool: String, options: RemoteAccessOptions) -> Outcome {
        guard ["read_tab", "wait_for_tab"].contains(tool) else { return .refuse(Refusal(text: herdrText, by: [])) }
        guard options[.serversRead] else {
            return .refuse(Refusal(text: RemoteAccessText.cantUse(tool, needing: [.serversRead]), by: [.serversRead]))
        }
        return .run(Summary())
    }

    // MARK: typing (R50, R51, R52, R57)

    private static func typing(_ tool: String, _ arguments: [String: Any], options: RemoteAccessOptions) -> Outcome {
        guard let tab = tab(arguments) else { return .refuse(Refusal(text: RemoteAccessText.oldTab, by: [])) }
        tab.pollAgentScreen()
        let lines: [String] = tab.screenTail(AgentScreen.scannedLines)
        let text: String = arguments["text"] as? String ?? ""
        let keys: [String] = (arguments["keys"] as? [String] ?? []).map { $0.lowercased() }
        let sent: String = tool == "send_to_tab" ? firstLine(text) : keys.joined(separator: ", ")
        let summary = Summary(tab: tab.title, sent: sent)
        let connecting = tab.remote != nil && !tab.remoteConnected
        guard tab.status.running, tab.status.kind == .agent, !connecting else {
            // A shell, a command that is not an agent, or a remote tab still connecting: the text options don't apply,
            // and the key names were checked before the main thread (R50).
            return options[.typeShells] ? .run(summary) : .refuse(Refusal(text: RemoteAccessText.shellTab, by: [.typeShells]))
        }
        let program = tab.status.program
        if let refusal = modeRefusal(tab, program: program, lines: lines, options: options) { return .refuse(refusal) }
        let line = RemoteAccessAgentRules.inputLine(program: program, screenLines: lines)
        if tool == "send_to_tab" {
            if let refused = RemoteAccessPolicy.textRefusal(text, options: options) {
                return .refuse(Refusal(text: refused, by: [textOption(text, options: options)]))
            }
            // Only into an empty input line, so remote text never joins what the user left there (R51).
            if !(options[.anySlash] && options[.shellAndMemory]), line != .empty {
                return .refuse(Refusal(text: RemoteAccessText.inputLine, by: [.anySlash, .shellAndMemory]))
            }
            return .run(summary)
        }
        guard !options[.everyKey] else { return .run(summary) }
        guard RemoteAccessAgentRules.showsInput(program: program, screenLines: lines) else {
            return .refuse(Refusal(text: RemoteAccessText.keysScreen, by: [.everyKey]))
        }
        if keys.contains("enter"), line != .empty {
            return .refuse(Refusal(text: RemoteAccessText.enterWithText, by: [.everyKey]))
        }
        return .run(summary)
    }

    /// R57: a bypass flag on the command line, as typed or as its alias expands, is a mode that never asks; else the
    /// mode the screen shows now.
    private static func modeRefusal(_ tab: TerminalTab, program: String, lines: [String], options: RemoteAccessOptions) -> Refusal? {
        let flagged = [tab.status.command, tab.status.expandedCommand].contains { (line: String) -> Bool in
            !line.isEmpty && RemoteAccessAgentRules.hasBypassFlag(line, program: program)
        }
        let mode: RemoteAccessAgentRules.Mode = flagged ? .neverAsks("flag") : RemoteAccessAgentRules.mode(program: program, screenLines: lines)
        switch mode {
        case .asks:
            return options[.typeAsking] ? nil : Refusal(text: RemoteAccessText.asksFirst, by: [.typeAsking])
        case .neverAsks:
            return options[.typeNeverAsking] ? nil : Refusal(text: RemoteAccessText.neverAsks, by: [.typeNeverAsking])
        case .unlisted:
            return options[.typeNeverAsking] ? nil : Refusal(text: RemoteAccessText.modeUnknown, by: [.typeNeverAsking])
        case .hidden:
            return options[.typeNeverAsking] ? nil : Refusal(text: RemoteAccessText.modeHidden, by: [.typeNeverAsking])
        }
    }

    /// The option a refused text names, for the audit line (R51).
    private static func textOption(_ text: String, options: RemoteAccessOptions) -> RemoteAccessOption.ID {
        let trimmed = text.drop { $0.isWhitespace }
        if trimmed.first == "!" || trimmed.first == "#" { return .shellAndMemory }
        let word = String(trimmed.prefix { !$0.isWhitespace })
        return RemoteAccessPolicy.slashAllowlist.contains(word) && !options[.slashAllowlist] ? .slashAllowlist : .anySlash
    }

    // MARK: answers (R58)

    private static func answering(_ arguments: [String: Any], options: RemoteAccessOptions) -> Outcome {
        guard let tab = tab(arguments) else { return .refuse(Refusal(text: RemoteAccessText.oldTab, by: [])) }
        tab.pollAgentScreen()
        let lines: [String] = tab.screenTail(AgentScreen.scannedLines)
        let approved = RemoteAccessAgentRules.approves(screenLines: lines)
        // No menu, or a choice it doesn't have: answer_agent says so itself, and types nothing.
        guard let menu = AgentScreen.menu(screenLines: lines),
              case .success(let index) = menu.index(choice: arguments["choice"] as? Int, answer: arguments["answer"] as? String) else {
            return .run(Summary(tab: tab.title, approved: approved))
        }
        let label = menu.choices[index]
        let summary = Summary(tab: tab.title, sent: label, approved: approved)
        if options[.answerStanding] { return .run(summary) }
        let form = RemoteAccessAgentRules.isQuestionForm(screenLines: lines)
        guard form || RemoteAccessAgentRules.isOneTime(label, program: tab.status.program) else {
            return .refuse(Refusal(text: RemoteAccessText.standingChoice, by: [.answerStanding]))
        }
        return .run(summary)
    }

    // MARK: tabs (R53, R54, R62)

    private static func closing(_ arguments: [String: Any], options: RemoteAccessOptions) -> Outcome {
        guard let tab = tab(arguments) else { return .refuse(Refusal(text: RemoteAccessText.oldTab, by: [])) }
        if !options[.closeBusyTabs], tab.closeWarning != nil {
            return .refuse(Refusal(text: RemoteAccessText.busyTab, by: [.closeBusyTabs]))
        }
        return .run(Summary(tab: tab.title))
    }

    /// new_tab's folder, cleaned as MCPControl cleans it: `~` expanded, absolute, then resolved (`..` and links). Without
    /// "Open projects and show things on the Mac" it is an open project or inside one.
    private static func folder(_ arguments: [String: Any], options: RemoteAccessOptions) -> Outcome {
        let summary = Summary(sent: arguments["command"] as? String)
        guard !options[.showOnMac], let raw = arguments["directory"] as? String, !raw.isEmpty else { return .run(summary) }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .run(summary) } // MCPControl refuses it
        let path = canonicalPath(expanded)
        let projects: [String] = AppDelegate.shared.controllers.compactMap(\.project).map(canonicalPath)
        let inside = projects.contains { (project: String) -> Bool in path == project || path.hasPrefix(project + "/") }
        return inside ? .run(summary) : .refuse(Refusal(text: RemoteAccessText.folderOff, by: [.showOnMac]))
    }

    // MARK: reading

    private static func tab(_ arguments: [String: Any]) -> TerminalTab? {
        guard let id = arguments["tab_id"] as? String else { return nil }
        return MCPControl.tab(withID: id)
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }
}
