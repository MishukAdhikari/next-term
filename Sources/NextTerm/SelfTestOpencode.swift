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
        await opencodeAnswerChecks(c, dir: dir)
        #if DEBUG
        await opencodeNoticeChecks(c, dir: dir)
        #endif
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

/// answer_agent in an OpenCode tab: a stand-in draws OpenCode's buttons, the selected one on a background of its own and
/// the others on the row's (OpenCode's default theme), reads keys in raw mode, and logs each key and the button it
/// picked. Its requests, one after another: "Allow once" selected; the selection on "Reject"; "Allow once" selected
/// again, for Esc; every button on one background; then a question with two options, the first drawn selected on a
/// background of its own, as 1.19 draws it (with none shown selected, a digit could land in "Type your own answer").
extension SelfTest {
    static let opencodeAnswerStandIn = #"""
    #!/bin/sh
    log="$OC_LOG"
    stty raw -echo
    printf '\033[?1049h\033]2;OC | Stand-in\007'
    key() { dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
    draw() {
      printf '\033[2J\033[H'
      printf '%s\r\n' '  ┃' '  ┃  △ Permission required' '  ┃    # Shell command' '  ┃' "  ┃  \$ true $1" '  ┃' '  ┃'
      printf '  ┃\033[48;2;30;30;30m  '
      i=0
      for label in 'Allow once' 'Allow always' 'Reject'; do
        if [ "$i" = "$2" ]; then printf '\033[48;2;250;178;80m %s \033[48;2;30;30;30m ' "$label"
        else printf ' %s  ' "$label"; fi
        i=$((i + 1))
      done
      printf '       ⇆ select  enter confirm\033[0m\r\n  ┃\r\n'
    }
    ask() {
      sel=$2; keys=''
      while :; do
        draw "$1" "$sel"
        b=$(key)
        case $b in
          0d) keys="$keys enter"; picked=$sel; break ;;
          1b) stty min 0 time 2; rest=$(dd bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'); stty min 1 time 0
              case $rest in
                5b43) keys="$keys right"; [ "$sel" != none ] && sel=$(( (sel + 1) % 3 )) ;;
                5b44) keys="$keys left"; [ "$sel" != none ] && sel=$(( (sel + 2) % 3 )) ;;
                *) keys="$keys escape"; picked=2; break ;;
              esac ;;
          *) keys="$keys $b" ;;
        esac
      done
      printf 'request %s keys:%s picked:%s\n' "$1" "$keys" "$picked" >> "$log"
    }
    ask 1 0
    ask 2 2
    ask 3 0
    ask 4 none
    printf '\033[2J\033[H'
    printf '\033[48;2;30;30;30m'
    printf '%s\r\n' '  ┃' '  ┃  Which database should the tests use?' '  ┃'
    printf '  ┃  \033[48;2;60;60;60m1. Postgres\033[48;2;30;30;30m\r\n'
    printf '%s\r\n' '  ┃  2. SQLite' '  ┃  3. Type your own answer' '  ┃' '  ┃  ↑↓ select  enter submit  esc dismiss' '  ┃'
    printf '\033[0m'
    b=$(key)
    stty min 0 time 10
    after=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    stty sane
    printf 'question keys:%s after:%s\n' "$b" "$after" >> "$log"
    printf '\033[2J\033[H%s\r\n' '  ┃  done'
    read answer
    printf '\033[?1049l'
    """#

    static func opencodeAnswerChecks(_ c: TerminalWindowController, dir: URL) async {
        let folder = dir.appendingPathComponent("answers")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("opencode")
        try? opencodeAnswerStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        let log = dir.appendingPathComponent("answers.log")
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode answers: the stand-in's tab starts its shell") }
        tab.view.send(txt: "OC_LOG='\(log.path)' PATH=\(folder.path):$PATH opencode\r")

        func asks(_ request: Int) async -> Bool {
            let words = "Permission required: Shell command ($ true \(request))"
            return await wait(10) { tab.status.state == .attention && tab.status.question == words }
        }
        func answer(_ given: [String: Any]) async -> (json: [String: Any], text: String, isError: Bool) {
            var arguments = given
            arguments["tab_id"] = tab.id.uuidString
            arguments["question_id"] = MCPControl.questionID(tab) ?? ""
            var result: MCPServer.CallResult?
            MCPControl.call("answer_agent", arguments, caller: nil) { result = $0 }
            _ = await wait(10) { result != nil }
            let text = result?.text ?? "(no answer)"
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            return (json, text, result?.isError ?? true)
        }
        func logged(_ count: Int) async -> [String] {
            var lines: [String] = []
            _ = await wait(5) {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                lines = text.split(separator: "\n").map(String.init)
                return lines.count >= count
            }
            return lines
        }

        // "Allow once" selected: Return alone.
        let first = await asks(1)
        let choices = MCPControl.questionInfo(tab)["choices"] as? [String]
        check(first && choices == ["Allow once", "Allow always", "Reject"], "OpenCode answers: list_tabs gives its buttons as the choices",
              "\(tab.status.question ?? "no question"), \(choices ?? [])")
        let once = await answer(["answer": "Allow once"])
        check(!once.isError && once.json["answered"] as? String == "Allow once", "OpenCode answers: answer_agent picks Allow once", once.text)
        let onceKeys = await logged(1)
        check(onceKeys.last == "request 1 keys: enter picked:0", "OpenCode answers: Allow once, selected, takes Return alone",
              onceKeys.joined(separator: " | "))

        // The selection on "Reject": Right once (the row wraps), a look that "Allow once" is selected, then Return.
        _ = await asks(2)
        let wrapped = await answer(["choice": 1])
        check(!wrapped.isError && wrapped.json["answered"] as? String == "Allow once", "OpenCode answers: choice 1 from Reject", wrapped.text)
        let wrappedKeys = await logged(2)
        check(wrappedKeys.last == "request 2 keys: right enter picked:0", "OpenCode answers: Right to Allow once, then Return",
              wrappedKeys.joined(separator: " | "))

        // Reject: Esc alone.
        _ = await asks(3)
        let rejected = await answer(["answer": "Reject"])
        check(!rejected.isError && rejected.json["answered"] as? String == "Reject", "OpenCode answers: answer_agent picks Reject", rejected.text)
        let rejectedKeys = await logged(3)
        check(rejectedKeys.last == "request 3 keys: escape picked:2", "OpenCode answers: Reject is Esc alone",
              rejectedKeys.joined(separator: " | "))

        // Every button on one background: which is selected is not shown, so Allow once is refused; Reject still works.
        _ = await asks(4)
        let unseen = await answer(["answer": "Allow once"])
        check(unseen.isError && unseen.text.contains("does not show which choice is selected"),
              "OpenCode answers: Allow once is refused when no button shows selected", unseen.text)
        let refusedKeys = await logged(4)
        check(refusedKeys.count == 3, "OpenCode answers: nothing was typed for the refused answer", refusedKeys.joined(separator: " | "))
        let stillRejected = await answer(["answer": "Reject"])
        let stillKeys = await logged(4)
        check(!stillRejected.isError && stillKeys.last == "request 4 keys: escape picked:2",
              "OpenCode answers: Reject still works with no selection shown", stillRejected.text + " " + stillKeys.joined(separator: " | "))

        // A question: its digit, and no Return after it.
        let question = await wait(10) { tab.status.question == "Which database should the tests use?" }
        let options = MCPControl.questionInfo(tab)["choices"] as? [String]
        check(question && options == ["Postgres", "SQLite"], "OpenCode answers: a question's options are its choices", "\(options ?? [])")
        let picked = await answer(["choice": 2])
        check(!picked.isError && picked.json["answered"] as? String == "SQLite", "OpenCode answers: answer_agent picks SQLite", picked.text)
        let digitKeys = await logged(5)
        check(digitKeys.last == "question keys:32 after:", "OpenCode answers: the question takes the digit 2 alone",
              digitKeys.joined(separator: " | "))

        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
    }
}

#if DEBUG
/// OpenCode's own notifications. A new tab asks OpenTUI programs for OSC 777 (a value the user set is kept: the Core
/// tests pin that). A stand-in `opencode` in a background tab sends OSC 777 as OpenTUI writes it, with a title and
/// without, ended with ST: its words are the notification's body, under the program's name. Then it asks for a
/// permission and, right after the decision notice, sends its own "Permission needs input": nothing more is posted.
/// Next Term stands as not in front, since a program's notification shows only from another app.
extension SelfTest {
    static let opencodeNoticeStandIn = #"""
    #!/bin/sh
    printf '\033]777;notify;Stand-in session;Session error\033\\'
    read a
    printf '\033]777;notify;Session done;\033\\'
    read b
    printf '\033[?1049h\033]2;OC | Stand-in\007\033[2J\033[H'
    printf '%s\n' '  ┃' '  ┃  △ Permission required' '  ┃    # Shell command' '  ┃' '  ┃  $ true' '  ┃' '  ┃'
    printf '%s\n' '  ┃   Allow once   Allow always   Reject          ⇆ select  enter confirm' '  ┃'
    read c
    printf '\033]777;notify;Stand-in session;Permission needs input\033\\'
    read d
    printf '\033[?1049l'
    """#

    static func opencodeNoticeChecks(_ c: TerminalWindowController, dir: URL) async {
        guard let app = AppDelegate.shared else { return }
        await opencodeProtocolCheck(c)
        let folder = dir.appendingPathComponent("notices")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("opencode")
        try? opencodeNoticeStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        app.appActiveStandIn = false
        defer { app.appActiveStandIn = nil }
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode notices: the stand-in's tab starts its shell") }
        let mine: () -> [UNNotificationRequest] = { app.testNotifications.filter { $0.identifier == tab.id.uuidString } }
        let says: (String) -> (UNNotificationRequest) -> Bool = { body in
            { request in request.content.title == "opencode" && request.content.body == body }
        }
        let shown: () -> String = { mine().suffix(3).map { "\($0.content.title) | \($0.content.body)" }.joined(separator: " || ") }

        tab.view.send(txt: "PATH=\(folder.path):$PATH opencode\r")
        let titled = await wait(6) { mine().contains(where: says("Session error")) }
        check(titled, "OpenCode notices: a titled OSC 777 shows its words, under the program's name", shown())
        tab.status.setVisible(true) // seen: the next notice is news again
        tab.status.setVisible(false)
        tab.view.send(txt: "\r")
        let untitled = await wait(6) { mine().contains(where: says("Session done")) }
        check(untitled, "OpenCode notices: one with no title shows its words too", shown())

        tab.view.send(txt: "\r")
        let asked = "Permission required: Shell command ($ true)"
        let decided = await wait(10) { mine().last?.content.body == asked }
        check(decided, "OpenCode notices: the stand-in's permission prompt posts the decision notice", shown())
        let before = mine().count
        tab.view.send(txt: "\r")
        _ = await wait(2) { mine().count > before }
        check(mine().count == before && mine().last?.content.body == asked,
              "OpenCode notices: its own notice right after the decision posts nothing more, and the decision stays", shown())

        // The rule itself: a program's notice within 10 seconds of Next Term's own for the tab is dropped; later, not.
        let words = TabNotice(state: .attention, command: "opencode", program: "opencode", kind: .agent, stillRunning: true,
                              duration: .infinity, fromProgram: true, message: "Permission needs input")
        app.post(words, tab: tab, in: c, appActive: false)
        check(mine().count == before, "OpenCode notices: a program's notice soon after Next Term's own is dropped", shown())
        app.ownNoticeAt[tab.id] = ProcessInfo.processInfo.systemUptime - 11
        app.post(words, tab: tab, in: c, appActive: false)
        check(mine().last.map(says("Permission needs input")) == true, "OpenCode notices: 11 seconds after it, the program's shows", shown())

        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
    }

    /// A new tab's environment asks OpenTUI programs for OSC 777.
    static func opencodeProtocolCheck(_ c: TerminalWindowController) async {
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode notices: the protocol tab starts its shell") }
        let inherited = ProcessInfo.processInfo.environment[ProgramNotice.protocolVariable]
        let expected = inherited ?? ProgramNotice.protocolValue
        tab.view.send(txt: "printenv \(ProgramNotice.protocolVariable)\r")
        let printed = await wait(6) { tab.screenTail(6).contains { $0.trimmingCharacters(in: .whitespaces) == expected } }
        check(printed, "OpenCode notices: a new tab has \(ProgramNotice.protocolVariable)=\(expected)",
              tab.screenTail(4).joined(separator: " | "))
    }
}
#endif
