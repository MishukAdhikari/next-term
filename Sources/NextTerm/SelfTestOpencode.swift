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
/// OpenCode's own notifications, in the order OpenCode sends them: its OSC 777 as it stops or asks, before Next Term's
/// next look at its screen. A new tab asks OpenTUI programs for OSC 777, and keeps a value the user set. A stand-in
/// `opencode` in a background tab draws OpenCode's working footer, then sends OSC 777 as OpenTUI writes it (with a title
/// and without, ended with ST) and draws its footer alone: the words are the turn's notification, under the program's
/// name, and the tab ends done, not amber. Its "Permission needs input" before its permission prompt gives way to the
/// decision notice, and one after it adds nothing. Next Term stands as not in front, since a program's words alone show
/// only from another app.
extension SelfTest {
    static let opencodeNoticeStandIn = #"""
    #!/bin/sh
    working() { printf '\033[2J\033[H%s\n\n%s\n' '  ┃  run true' '   ■■⬝⬝⬝⬝ esc interrupt                              ctrl+p commands'; }
    ready() { printf '\033[2J\033[H%s\n\n%s\n' '  ┃  run true' '   ~/stand-in                                         ctrl+p commands'; }
    printf '\033[?1049h\033]2;OC | Stand-in\007'
    working
    sleep 6
    printf '\033]777;notify;Stand-in session;Session error\033\\'
    ready
    read a
    working
    sleep 1
    printf '\033]777;notify;Session done;\033\\'
    ready
    read b
    working
    sleep 1
    printf '\033]777;notify;Stand-in session;Permission needs input\033\\'
    printf '\033[2J\033[H'
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
        /// Nothing more is posted for the tab in `seconds`.
        func quiet(for seconds: Double) async -> Bool {
            let count = mine().count
            let more = await wait(seconds) { mine().count > count }
            return !more
        }

        // A turn long enough for a finish notice: the words it sent as it stopped are that notice, and nothing else.
        tab.view.send(txt: "PATH=\(folder.path):$PATH opencode\r")
        let titled = await wait(14) { mine().contains(where: says("Session error")) }
        let finishOnly = await quiet(for: 2.5) && mine().count == 1
        check(titled && finishOnly, "OpenCode notices: a titled OSC 777 as the turn ends is its one notification, in its words", shown())
        check(tab.status.state == .done, "OpenCode notices: the tab ends done, not amber", tab.status.state.rawValue)

        // A short turn: its words go alone once the stop has settled. Next Term's notice above is forgotten, as if 10
        // seconds had gone (the rule itself is checked last).
        app.ownNoticeAt[tab.id] = nil
        tab.view.send(txt: "\r")
        let untitled = await wait(8) { mine().contains(where: says("Session done")) }
        check(untitled && tab.status.state == .done, "OpenCode notices: one with no title shows its words too, with no amber",
              "\(shown()), \(tab.status.state.rawValue)")

        // "Permission needs input" just before the prompt shows: the decision notice alone.
        app.ownNoticeAt[tab.id] = nil
        let before = mine().count
        tab.view.send(txt: "\r")
        let asked = "Permission required: Shell command ($ true)"
        let decided = await wait(10) { mine().last?.content.body == asked }
        let decisionOnly = await quiet(for: 3) && mine().count == before + 1
        check(decided && decisionOnly, "OpenCode notices: its own notice just before its question gives way to the decision", shown())
        tab.view.send(txt: "\r")
        let after = await quiet(for: 3)
        check(after && mine().last?.content.body == asked,
              "OpenCode notices: its own notice right after the decision posts nothing more, and the decision stays", shown())

        // The rule itself: a program's notice within 10 seconds of Next Term's own for the tab is dropped; later, not.
        let words = TabNotice(state: .attention, command: "opencode", program: "opencode", kind: .agent, stillRunning: true,
                              duration: .infinity, fromProgram: true, message: "Permission needs input")
        app.post(words, tab: tab, in: c, appActive: false)
        check(mine().count == before + 1, "OpenCode notices: a program's notice soon after Next Term's own is dropped", shown())
        app.ownNoticeAt[tab.id] = ProcessInfo.processInfo.systemUptime - 11
        app.post(words, tab: tab, in: c, appActive: false)
        check(mine().last.map(says("Permission needs input")) == true, "OpenCode notices: 11 seconds after it, the program's shows", shown())

        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
    }

    /// A new tab's environment asks OpenTUI programs for OSC 777, unless the environment Next Term started with set
    /// another value: that one is kept.
    static func opencodeProtocolCheck(_ c: TerminalWindowController) async {
        let name = ProgramNotice.protocolVariable
        let inherited = ProcessInfo.processInfo.environment[name]
        await protocolPrinted(inherited ?? ProgramNotice.protocolValue, c, "a new tab has \(name)=")
        // The user's own value, as if Next Term had started with it (put back as it was right after the tab starts).
        let own = inherited == "osc9" ? "osc9-stand-in" : "osc9"
        setenv(name, own, 1)
        await protocolPrinted(own, c, "one started with it set keeps the user's ", restore: {
            if let inherited { setenv(name, inherited, 1) } else { unsetenv(name) }
        })
    }

    /// A background tab prints the variable, which is `expected`. `restore` runs once its shell has started.
    static func protocolPrinted(_ expected: String, _ c: TerminalWindowController, _ what: String,
                                restore: () -> Void = {}) async {
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        let started = await wait(20) { tab.status.integrated }
        restore()
        guard started else { return check(false, "OpenCode notices: the protocol tab starts its shell") }
        tab.view.send(txt: "printenv \(ProgramNotice.protocolVariable)\r")
        let printed = await wait(6) { tab.screenTail(6).contains { $0.trimmingCharacters(in: .whitespaces) == expected } }
        check(printed, "OpenCode notices: \(what)\(expected)", tab.screenTail(4).joined(separator: " | "))
    }
}
#endif

// MARK: Send to Agent into a linked OpenCode

/// ⌥⌘K into OpenCode linked to the editor, through the stand-in client opencodeLinkChecks runs (this app's binary as
/// `opencode.exe`, saying it is "opencode"). Selected lines go in as a mention counted from 1; a file from the sidebar is
/// typed in OpenCode's own form, with no mention; a .env in front leaves OpenCode the last file with no text, never its
/// old lines. The stand-in lives eight seconds once it is in, so each case starts its own.
extension SelfTest {
    static func opencodeSendChecks(_ c: TerminalWindowController, dir: URL, port: UInt16) async {
        guard let window = c.window else { return check(false, "OpenCode ⌥⌘K: the window is there") }
        let source = dir.appendingPathComponent("app.ts")
        let numbered = (1...30).map { "const line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let secrets = dir.appendingPathComponent(".env")
        try? numbered.write(to: source, atomically: true, encoding: .utf8)
        try? "EXAMPLE_SETTING=made-up\n".write(to: secrets, atomically: true, encoding: .utf8)
        let tab = c.addTab(directory: dir.path)
        defer {
            if let editor = c.editorArea.activeEditor, editor.document.path == canonicalPath(secrets.path) { c.editorArea.close(editor) }
            if let editor = c.editorArea.activeEditor, editor.document.path == canonicalPath(source.path) { c.editorArea.close(editor) }
            c.remove(tab)
        }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "OpenCode ⌥⌘K: the stand-in's tab starts its shell") }
        func received(_ name: String) -> [[String: Any]] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func last(_ method: String, _ name: String) -> [String: Any]? {
            received(name).last { $0["method"] as? String == method }?["params"] as? [String: Any]
        }
        // A stand-in that writes what it gets to `name`, linked to its tab as OpenCode.
        func link(_ name: String) async -> Bool {
            _ = await wait(10) { !tab.status.running && AppDelegate.shared.claudeClient(for: tab) == nil }
            tab.view.send(txt: "\u{15}./opencode.exe --cli --self-test-ide-client \(port) \(name)\r")
            let linked = await wait(10) { tab.status.running && AppDelegate.shared.claudeClient(for: tab) != nil }
            guard linked, let client = AppDelegate.shared.claudeClient(for: tab) else { return false }
            return ClaudeIDEServer.shared.isOpencode(client)
        }

        c.openFile(source)
        guard let editor = c.editorArea.activeEditor, editor.document.path == canonicalPath(source.path),
              editor.document.lines.count > 21 else { return check(false, "OpenCode ⌥⌘K: a file of 30 lines opens") }
        let starts = editor.document.lines.starts
        // Lines 10 to 20 as the editor numbers them: from the start of line 10 to the start of line 21.
        editor.textView.setSelectedRange(NSRange(location: starts[9], length: starts[20] - starts[9]))
        guard await link("send-lines.jsonl") else {
            return check(false, "OpenCode ⌥⌘K: the stand-in links from its tab as OpenCode", tab.screenTail(3).joined(separator: " | "))
        }
        check(c.agentTab === tab, "OpenCode ⌥⌘K: its tab is the one Send to Agent types into", c.agentTab?.title ?? "none")
        let chord = KeyboardShortcuts.shared.key(for: #selector(TerminalWindowController.sendToAgent(_:)))
        check(chord == KeyChord(key: "k", command: true, option: true), "OpenCode ⌥⌘K: Send to Agent is on ⌥⌘K", chord?.display ?? "no key")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        let screen = tab.screenTail(3).joined()
        pressSendToAgentKey()
        let mentioned = await wait(4) { last("at_mentioned", "send-lines.jsonl")?["lineStart"] as? Int == 10 }
        let mention = last("at_mentioned", "send-lines.jsonl")
        let exact = mention?["lineEnd"] as? Int == 20 && mention?["filePath"] as? String == editor.document.path
        check(mentioned && exact, "OpenCode ⌥⌘K: lines 10-20 go in as a mention of lines 10 to 20, counted from 1", "\(mention ?? [:])")
        check(tab.screenTail(3).joined() == screen, "OpenCode ⌥⌘K: and nothing is typed into its tab", tab.screenTail(3).joined(separator: " | "))

        // A whole file has no lines, which OpenCode's mention needs: it is typed, in OpenCode's own form.
        guard await link("send-file.jsonl") else { return check(false, "OpenCode sidebar: the stand-in links again") }
        c.sidebar(c.sidebar, sendToAgent: [(url: source, isFolder: false)])
        let typed = await wait(4) { tab.screenTail(3).joined().contains("@app.ts") }
        await pause(0.5) // a mention would be written by now
        check(typed && last("at_mentioned", "send-file.jsonl") == nil, "OpenCode sidebar: a whole file is typed as @app.ts, with no mention",
              tab.screenTail(3).joined(separator: " | "))

        // It starts with what the editor shows (app.ts), then a .env comes in front.
        guard await link("send-env.jsonl") else { return check(false, "OpenCode .env: the stand-in links again") }
        let shared = await wait(3) { last("selection_changed", "send-env.jsonl")?["filePath"] as? String == editor.document.path }
        c.openFile(secrets)
        let told = await wait(4) {
            let params = last("selection_changed", "send-env.jsonl")
            let front = c.editorArea.activeEditor?.document.holdsSecrets == true
            return front && params?["filePath"] as? String == editor.document.path && params?["text"] as? String == ""
        }
        check(shared && told, "OpenCode .env: with a .env in front it is told the last file with no text, so the old lines go",
              "\(last("selection_changed", "send-env.jsonl") ?? [:])")
        let named = received("send-env.jsonl").contains { message in
            (message["params"] as? [String: Any])?["filePath"] as? String == canonicalPath(secrets.path)
        }
        check(!named, "OpenCode .env: and never the .env's name")
        _ = await wait(10) { !tab.status.running }

        // Not linked: the lines are typed, in OpenCode's own form.
        let unlinked = c.agentText([ContextItem(path: "src/app.ts", lines: 10...20)], for: "opencode")
        check(unlinked == "@src/app.ts#10-20 ", "OpenCode not linked: ⌥⌘K types @src/app.ts#10-20", unlinked)
    }

    /// ⌥⌘K as the keyboard sends it: a key down made from a CGEvent (K is key 40), so AppKit reads its characters off the
    /// keyboard layout as it does a real key's, and it goes to the window that has the keyboard (SelfTestGitKeys.pressKey).
    private static func pressSendToAgentKey() {
        guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 40, keyDown: true) else { return }
        key.flags = [.maskCommand, .maskAlternate]
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }
}
