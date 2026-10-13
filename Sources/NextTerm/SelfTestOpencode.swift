import AppKit
import NextTermCore
import UserNotifications

/// OpenCode in a tab, Next Term's part: a stand-in `opencode`, on a PATH of the self-test's own, draws OpenCode's
/// working footer and then its permission prompt in a background tab. The tab works, then asks: amber, a decision
/// notification with the question (captured in AppDelegate.testNotifications), and list_tabs gives the question and
/// its id. Then a stand-in under another agent's name that titles itself as OpenCode does ("OC | …", as OpenCode over
/// ssh or in tmux shows): its screen is read as OpenCode's too. Nothing of the user's OpenCode is read or run.
extension SelfTest {
    /// Rows in OpenCode 1.19's layout, in the alternate screen, under OpenCode's title.
    static let opencodeStandIn = #"""
    #!/bin/sh
    printf '\033[?1049h\033]2;OC | Stand-in\007\033[2J\033[H'
    printf '%s\n' '  ┃  run true' '' '   ■■⬝⬝⬝⬝ esc interrupt                              ctrl+p commands'
    sleep 3
    printf '\033[2J\033[H'
    printf '%s\n' '  ┃' '  ┃  △ Permission required' '  ┃    # Shell command' '  ┃' '  ┃  $ true' '  ┃' '  ┃'
    printf '%s\n' '  ┃   Allow once   Allow always   Reject          ⇆ select  enter confirm' '  ┃'
    read answer
    printf '\033[?1049l'
    """#

    static func opencodeScreenChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared else { return }
        let restore = defaultNotificationSettings()
        defer { restore() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nextterm-opencode-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let standIn = dir.appendingPathComponent("opencode")
        try? opencodeStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)

        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode: the stand-in's tab starts its shell") }
        check(!c.isOnScreen(tab), "OpenCode: the stand-in runs in a tab that is not on screen")
        tab.view.send(txt: "PATH=\(dir.path):$PATH opencode\r")
        let working = await wait(6) { tab.status.state == .working && tab.status.screenSynced }
        check(working && tab.isOpencodeScreen, "OpenCode: its working footer shows the tab working, from its screen",
              "\(tab.status.state.rawValue), synced \(tab.status.screenSynced)")

        let asked = "Permission required: Shell command ($ true)"
        let asking = await wait(10) { tab.status.state == .attention && tab.status.question == asked }
        check(asking, "OpenCode: its permission prompt turns the tab amber, with the question",
              tab.status.question ?? tab.status.state.rawValue)
        let quotes: (UNNotificationRequest) -> Bool = { request in
            guard request.identifier == tab.id.uuidString else { return false }
            return request.content.title == "opencode needs your decision" && request.content.body == asked
        }
        let posted = await wait(4) { app.testNotifications.contains(where: quotes) }
        let recent: [String] = app.testNotifications.suffix(3).map { "\($0.content.title) | \($0.content.body)" }
        check(posted, "OpenCode: the decision notification quotes the question", "\(recent)")

        var listed = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("list_tabs", [:], caller: nil) { listed = $0 }
        _ = await wait(10) { !listed.text.isEmpty }
        let json = try? JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any]
        let windows = json?["windows"] as? [[String: Any]] ?? []
        let rows = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        let row = rows.first { $0["id"] as? String == tab.id.uuidString.lowercased() }
        let id = row?["question_id"] as? String
        let listedQuestion = row?["question"] as? String
        let sameID = id != nil && id == MCPControl.questionID(tab)
        check(listedQuestion == asked && sameID, "OpenCode: list_tabs gives the question and its id", String(listed.text.prefix(400)))

        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
        await opencodeTitleChecks(c, dir: dir)
    }

    /// `goose` here: an agent, but not OpenCode by its name, so only its title makes the tab read OpenCode's screen.
    static let opencodeTitledStandIn = #"""
    #!/bin/sh
    printf '\033[?1049h\033]2;OC | Stand-in\007\033[2J\033[H'
    printf '%s\n' '  ┃  run true' '' '   ■■⬝⬝⬝⬝ esc interrupt                              ctrl+p commands'
    read answer
    printf '\033[?1049l'
    """#

    /// The title rule (TerminalTab.isOpencodeScreen): "esc interrupt" is OpenCode's working hint, not every agent's,
    /// so the tab works, from its screen, only if its title made it read OpenCode's shapes.
    static func opencodeTitleChecks(_ c: TerminalWindowController, dir: URL) async {
        let standIn = dir.appendingPathComponent("goose")
        try? opencodeTitledStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode: the titled stand-in's tab starts its shell") }
        tab.view.send(txt: "PATH=\(dir.path):$PATH goose\r")
        let titled = await wait(6) { tab.programTitle == "OC | Stand-in" && tab.status.program == "goose" }
        check(titled && AgentKind(program: tab.status.program) == nil, "OpenCode: the titled stand-in runs as another agent, under OpenCode's title",
              "\(tab.status.program), title \(tab.programTitle ?? "none")")
        let working = await wait(6) { tab.isOpencodeScreen && tab.status.state == .working && tab.status.screenSynced }
        check(working, "OpenCode: a tab titled as OpenCode reads its working footer, from its screen",
              "\(tab.status.state.rawValue), synced \(tab.status.screenSynced)")
        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
    }
}
