#if DEBUG
import AppKit
import NextTermCore

/// The terminal and chat switch (plan 036 U7, AE1–AE13), on screen, with stand-ins named claude and codex first on the
/// PATH of every tab this part opens (its own zsh config, TerminalTab.testUserZDOTDIR), so the user's own CLIs never
/// run. Each stand-in is a dispatcher: `claude -p` and `codex app-server` go to plan 035's stand-ins (SelfTestAgentSession,
/// in bin/chat), anything else to a stand-in of the agent's own terminal interface (bin/tui), which reads raw keys at a
/// prompt row, logs what it gets beside itself, quits on /exit or /quit, and goes on with `--resume ID` or `resume ID`.
/// It names its session in a Claude Code store or holds a Codex rollout open, under the part's own CLAUDE_CONFIG_DIR and
/// CODEX_HOME, as the real ones do, so Next Term's evidence reads an exact id from them. Folder trust, the CLI versions
/// and the Settings default go to a defaults suite of this part's own.
extension SelfTest {
    /// `claude` and `codex` on the PATH: the chat view's protocols go to plan 035's stand-ins, anything else to the
    /// terminal interface's. That one runs as `python3 <tui/agent>`, so the kernel shows an interpreter running a script
    /// named for the agent, as an npm install shows, and Next Term's evidence knows the process.
    static let viewSwitchDispatcher = #"""
    #!/usr/bin/python3
    # Next Term's self-test stand-in: the agent's own terminal interface (tui/NAME), or its session protocol (chat/NAME).
    import os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    name = os.path.basename(__file__)
    args = sys.argv[1:]
    chat = ("-p" in args or "--version" in args) if name == "claude" else args[:1] == ["app-server"]
    if chat:
        os.execv(sys.executable, [sys.executable, os.path.join(here, "chat", name)] + args)
    python = os.path.join(sys.base_prefix, "Resources/Python.app/Contents/MacOS/Python")
    if not os.path.exists(python): python = sys.executable
    os.execv(python, ["python3", os.path.join(here, "tui", name)] + args)
    """#

    /// The terminal interface's stand-in, for both agents by its file's name. ⌃C clears a typed line or arms the quit, a
    /// second ⌃C quits; the quit word (/exit, /quit) and Return quits. "busy" shows "esc to interrupt" for 3 seconds, "ask"
    /// a "Do you want to…?" question that 1, 2 or Esc answers, anything else is a turn. STANDIN_TUI=slow ignores the quit
    /// word, stubborn ignores it and every ⌃C, guess names its process with another start time (a guessed id), fresh
    /// keeps no transcript. STANDIN_ID names a new session.
    static let viewSwitchTUIStandIn = #"""
    # A stand-in for Claude Code's or Codex's own terminal interface (by this file's name), for testing the view switch.
    # Never a real model or account. It reads raw keys at a prompt row and logs what it gets beside itself.
    import json, os, re, select, subprocess, sys, termios, time, tty, uuid
    me = sys.argv[0]
    agent = os.path.basename(me)
    log = open(me + ".log", "a", buffering=1)
    def note(*words): log.write(" ".join(str(w) for w in words) + "\n")
    args = sys.argv[1:]
    mode = os.environ.get("STANDIN_TUI", "")
    name = "Claude Code" if agent == "claude" else "Codex"
    quit_word = "/exit" if agent == "claude" else "/quit"
    shape = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    given = None
    form = "--resume" if agent == "claude" else "resume"
    if form in args:
        given = next((a for a in args[args.index(form) + 1:] if shape.match(a)), None)
    sid = given or os.environ.get("STANDIN_ID") or str(uuid.uuid4())
    note("start", os.getpid(), json.dumps(args), "resume" if given else "new", sid)
    cwd = os.getcwd()
    def private(path, text, append=False):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | (os.O_APPEND if append else os.O_TRUNC), 0o600)
        os.write(fd, text.encode())
        os.close(fd)
    rollout = None
    transcript = None
    if agent == "claude":
        store = os.environ["CLAUDE_CONFIG_DIR"]
        try:
            started = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())], env={"TZ": "UTC"},
                                     capture_output=True, text=True).stdout.strip()
        except Exception:
            started = time.strftime("%a %b %e %H:%M:%S %Y", time.gmtime())
        if mode == "guess": started = "Thu Jan  1 00:00:00 2026"
        record = {"pid": os.getpid(), "sessionId": sid, "cwd": cwd, "procStart": started, "status": "idle"}
        private(os.path.join(store, "sessions", "%d.json" % os.getpid()), json.dumps(record))
        transcript = os.path.join(store, "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")
    else:
        folder = os.path.join(os.environ["CODEX_HOME"], "sessions", "2026", "11", "08")
        os.makedirs(folder, exist_ok=True)
        found = [f for f in os.listdir(folder) if f.endswith("-" + sid + ".jsonl")]
        path = os.path.join(folder, found[0] if found else "rollout-2026-11-08T10-00-00-" + sid + ".jsonl")
        fresh = not found
        rollout = open(path, "a", buffering=1)
        if fresh: rollout.write(json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd}}) + "\n")
    def out(text): os.write(1, text.encode())
    saved = termios.tcgetattr(0)
    tty.setraw(0)
    def leave(code):
        termios.tcsetattr(0, termios.TCSADRAIN, saved)
        out("\r\n")
        note("exit", code)
        sys.exit(code)
    out("%s stand-in, %s session %s\r\n> " % (name, "resumed" if given else "new", sid))
    line = ""
    armed = False
    busy_until = 0
    asking = False
    while True:
        wait = max(0.05, busy_until - time.time()) if busy_until else None
        ready = select.select([0], [], [], wait)[0]
        if busy_until and time.time() >= busy_until:
            busy_until = 0
            out("\r\x1b[K* Done\r\n> " + line)
            note("busy over")
        if not ready: continue
        data = os.read(0, 1024)
        if not data: leave(0)
        note("keys", data.hex())
        for byte in data:
            ch = chr(byte)
            if asking:
                if ch in "12\x1b":
                    asking = False
                    note("answer", repr(ch))
                    out("\r\x1b[K\x1b[1A\r\x1b[K\x1b[1A\r\x1b[K" + "Answered.\r\n> ")
                continue
            if byte == 3:
                if mode == "stubborn":
                    note("ctrl-c ignored")
                elif line:
                    line = ""
                    armed = False
                    note("ctrl-c cleared")
                    out("\r\x1b[K> ")
                elif armed:
                    note("ctrl-c twice")
                    leave(0)
                else:
                    armed = True
                    note("ctrl-c")
                    out("\r\x1b[K(Press Ctrl-C again to exit)\r\n> ")
            elif byte in (13, 10):
                typed, line = line, ""
                note("line", typed)
                if typed == quit_word:
                    if mode in ("slow", "stubborn"):
                        note("quit ignored")
                        out("\r\n> ")
                        continue
                    leave(0)
                elif typed == "busy":
                    busy_until = time.time() + 3
                    out("\r\n* Working... (3s - esc to interrupt)")
                elif typed == "ask":
                    asking = True
                    out("\r\nDo you want to make this edit?\r\n❯ 1. Yes\r\n  2. No")
                elif typed:
                    note("turn", typed)
                    if transcript and mode != "fresh":
                        private(transcript, json.dumps({"type": "user", "sessionId": sid, "cwd": cwd, "message": {"role": "user", "content": typed}}) + "\n", True)
                    if rollout:
                        rollout.write(json.dumps({"type": "response_item", "payload": {"role": "user", "text": typed}}) + "\n")
                    out("\r\n* Reply to: %s\r\n> " % typed)
                else:
                    out("\r\n> ")
            elif byte in (127, 8):
                line = line[:-1]
                out("\r\x1b[K> " + line)
            elif byte >= 32:
                armed = False
                line += ch
                out(ch)
    """#

    static func viewSwitchChecks(_ c: TerminalWindowController) async {
        viewSwitchIconChecks()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), Bundle.main.executablePath != nil else {
            return note("view switch: skipped, no /usr/bin/python3 for the stand-ins")
        }
        guard let rig = ViewSwitchRig(c) else { return check(false, "view switch: the stand-ins and their folders are made") }
        defer { rig.tearDown() }
        await viewSwitchRoundTrip(rig)
        await viewSwitchLauncher(rig)
        await viewSwitchCodex(rig)
        await viewSwitchRefusals(rig)
        await viewSwitchQuitChecks(rig)
        await viewSwitchMCP(rig)
        await viewSwitchOffers(rig)
        await viewSwitchDefaults(rig)
    }

    // MARK: AE8, the icon

    /// The icon in a top bar and in tab list rows of their own, offscreen, at the narrowest tab: a terminal view shows it
    /// only under the pointer or selected, a chat view a dim bubble at rest and the terminal glyph selected, a shell none.
    static func viewSwitchIconChecks() {
        let terminal = ViewSwitch.Offer(agent: .claude, view: .terminal)
        let chat = ViewSwitch.Offer(agent: .claude, view: .chat)
        func item(_ title: String, _ key: String, _ offer: ViewSwitch.Offer?) -> TabBarItem {
            TabBarItem(title: title, state: .idle, tooltip: "", accessibilityStatus: "Idle", shortcut: key, viewSwitch: offer)
        }
        let items: [TabBarItem] = [item("claude", "⌘1", terminal), item("Claude Code", "⌘2", chat), item("zsh", "⌘3", nil),
                                   item("notes", "⌘4", nil)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: TabBarView.height), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.contentView = nil }
        func bar(selected: Int, with shown: [TabBarItem] = items) -> TabBarView {
            let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 12 + 36 + 24 + TabBarView.minTabWidth * CGFloat(shown.count),
                                               height: TabBarView.height))
            bar.leadingInset = 12
            window.setContentSize(bar.frame.size)
            window.contentView = bar
            bar.update(items: shown, selectedIndex: selected)
            bar.layoutSubtreeIfNeeded()
            return bar
        }
        let rest = bar(selected: 3)
        let shown = (0..<3).map { (index: Int) in rest.viewSwitchForTest(at: index) }
        let width: CGFloat = shown[1]?.tabWidth ?? 0
        let dim = shown[1]
        let slotted = dim.map { abs($0.frame.minX - ($0.tabWidth - 44)) < 0.5 && $0.frame.width == 18 } ?? false
        check(width > 0 && width <= TabBarView.minTabWidth + 1, "view switch icon: the bar's tabs are at the narrowest width", "\(width)")
        check(shown[0]?.mark == nil && shown[2]?.mark == nil,
              "view switch icon: at rest, a terminal-view tab and a shell tab show no icon", "\(shown.map { $0?.mark?.glyph.rawValue ?? "none" })")
        let dimBubble: Bool = dim?.mark?.glyph == .chat && dim?.mark?.dimmed == true && dim?.alpha == CGFloat(0.5)
        let dimRoom: Bool = (dim?.titleEnd ?? .infinity) <= width - 48 && rest.shownShortcut(at: 1) == nil
        check(dimBubble && slotted && dimRoom,
              "view switch icon: at rest, a chat-view tab shows the dimmed bubble before the ×, its title ending before it and its ⌘N given way",
              "\(String(describing: dim))")
        check(dim?.mark?.spoken == "Chat view, Switch to Terminal", "view switch icon: VoiceOver says the chat view at rest",
              dim?.mark?.spoken ?? "none")
        rest.pointForTest(at: 0)
        rest.layoutSubtreeIfNeeded()
        let hovered = rest.viewSwitchForTest(at: 0)
        let tip = hovered?.mark.map(ViewSwitchButton.toolTip(for:)) ?? ""
        let bubble: Bool = hovered?.mark?.glyph == .chat && hovered?.mark?.dimmed == false && hovered?.alpha == CGFloat(1)
        let room: Bool = (hovered?.titleEnd ?? .infinity) <= width - 48 && rest.shownShortcut(at: 0) == nil
        check(bubble && room,
              "view switch icon: under the pointer, a terminal-view tab shows the bubble, its title before it", "\(String(describing: hovered))")
        check(hovered?.mark?.spoken == "Switch to Chat" && tip.hasPrefix("Switch to Chat (") && tip.hasSuffix(")"),
              "view switch icon: its tooltip and VoiceOver say Switch to Chat, the tooltip with the key", tip)
        rest.pointForTest(at: 2)
        rest.layoutSubtreeIfNeeded()
        let left = rest.viewSwitchForTest(at: 0)
        check(left?.mark == nil && rest.viewSwitchForTest(at: 2)?.mark == nil,
              "view switch icon: the pointer gone, it goes; a shell tab under the pointer shows none", "\(String(describing: left))")
        rest.pointForTest(at: nil)
        let selected = bar(selected: 1).viewSwitchForTest(at: 1)
        let glyph: Bool = selected?.mark?.glyph == .terminal && selected?.mark?.dimmed == false && selected?.alpha == CGFloat(1)
        check(glyph && selected?.mark?.tooltip == "Switch to Terminal",
              "view switch icon: a selected chat-view tab shows the terminal glyph, Switch to Terminal", "\(String(describing: selected))")
        var running = items
        running[0].viewSwitch = ViewSwitch.Offer(agent: .claude, view: .terminal, switching: true)
        let switching = bar(selected: 0, with: running).viewSwitchForTest(at: 0)
        check(switching?.mark?.glyph == .chat && switching?.mark?.dimmed == true && switching?.mark?.enabled == false,
              "view switch icon: while a switch runs, the destination's glyph is dimmed and off", "\(String(describing: switching))")
        viewSwitchRowChecks(terminal: terminal, chat: chat)
    }

    /// The tab list's rows match the bar's tabs; collapsed, and on a pane's row, there is none.
    static func viewSwitchRowChecks(terminal: ViewSwitch.Offer, chat: ViewSwitch.Offer) {
        func row(_ offer: ViewSwitch.Offer?, kind: TabListRow.Kind = .tab, selected: Bool = false, hovering: Bool = false,
                 collapsed: Bool = false) -> (mark: ViewSwitch.Mark?, frame: NSRect, alpha: CGFloat, titleEnd: CGFloat) {
            let view = TabListRowView(frame: NSRect(x: 0, y: 0, width: collapsed ? 40 : 160, height: 28))
            view.collapsed = collapsed
            view.configure(row: TabListRow(key: "view-switch-row", kind: kind, title: "Claude Code", shortcut: "⌘2", viewSwitch: offer),
                           selected: selected)
            view.hoverForTest(hovering)
            view.layoutSubtreeIfNeeded()
            return view.viewSwitchForTest
        }
        let terminalRest = row(terminal)
        let terminalHover = row(terminal, hovering: true)
        let chatRest = row(chat)
        let chatSelected = row(chat, selected: true)
        let hoverShows: Bool = terminalRest.mark == nil && terminalHover.mark?.glyph == .chat && terminalHover.mark?.dimmed == false
        let placed: Bool = abs(terminalHover.frame.minX - CGFloat(160 - 44)) < 0.5 && terminalHover.titleEnd <= CGFloat(160 - 48)
        check(hoverShows && placed,
              "view switch icon: a terminal-view row shows the bubble only under the pointer, before the ×",
              "\(String(describing: terminalRest.mark)) / \(String(describing: terminalHover))")
        let rested: Bool = chatRest.mark?.glyph == .chat && chatRest.alpha == CGFloat(0.5)
        let picked: Bool = chatSelected.mark?.glyph == .terminal && chatSelected.alpha == CGFloat(1)
        check(rested && picked,
              "view switch icon: a chat-view row shows the dim bubble at rest and the terminal glyph selected",
              "\(String(describing: chatRest)) / \(String(describing: chatSelected))")
        let shell = row(nil, selected: true, hovering: true)
        let collapsed = row(chat, selected: true, hovering: true, collapsed: true)
        let pane = row(chat, kind: .pane(index: 0, count: 2), selected: true, hovering: true)
        check(shell.mark == nil && collapsed.mark == nil && pane.mark == nil,
              "view switch icon: a shell's row, a collapsed list's slot and a pane's row show none",
              "shell \(shell.mark != nil), collapsed \(collapsed.mark != nil), pane \(pane.mark != nil)")
    }

    // MARK: AE1, AE2, AE9: the round trip

    /// A plain `claude` with one turn goes to chat by ⇧⌘J and comes back by its right-click menu, in the same tab.
    static func viewSwitchRoundTrip(_ rig: ViewSwitchRig) async {
        let c = rig.c
        let id = "5e55a0de-0000-4000-8000-00000000a001"
        guard let shell = await rig.shell(), let tab = await rig.tui("claude", id: id) else {
            return check(false, "view switch: a tab runs the stand-in claude", rig.tuiLog("claude").suffix(3).joined(separator: " | "))
        }
        // AE4: an exact id but no turn yet.
        let fresh = await rig.switchView(tab)
        check(rig.refusal(fresh) == "No conversation to carry over yet: send a prompt first." && !rig.tuiKeys("claude", since: 0).contains("ctrl-c"),
              "view switch: before its first turn, the switch is refused with nothing typed", rig.refusal(fresh) ?? "it ran")
        guard await rig.turn(tab, "hello") else { return check(false, "view switch: the stand-in claude takes a turn", rig.flat(tab)) }

        // AE9: View's item follows the tab in front; off in front of a shell.
        guard let item = viewMenuItems().first(where: { $0.action == #selector(TerminalWindowController.switchView(_:)) }) else {
            return check(false, "view switch: View has Switch to Chat")
        }
        rig.front(shell)
        let offShell = !c.validateMenuItem(item) && item.title == "Switch to Chat"
        rig.front(tab)
        let onClaude = c.validateMenuItem(item) && item.title == "Switch to Chat"
        let keyed = item.keyEquivalent == "j" && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
        check(offShell && onClaude && keyed && MenuKeys.defaults["switchView:"]?.display == "\u{21E7}\u{2318}J",
              "view switch: View's item is Switch to Chat on ⇧⌘J, on for a Claude Code tab and off for a shell",
              "shell \(offShell), claude \(onClaude), key \(item.keyEquivalent) \(item.keyEquivalentModifierMask.rawValue)")

        // AE1: ⇧⌘J (View's item): ⌃C, /exit and Return, the prompt, the separator and the chat line, in the same tab.
        tab.userTitle = "switch here"
        let tabsBefore = c.tabs.count
        let mark = rig.tuiLog("claude").count
        var quiet = false
        c.switchView(item)
        let inChat = await wait(25) {
            if tab.status.suppressesNotices { quiet = true }
            return rig.chatReady(tab, id)
        }
        let keys = rig.tuiKeys("claude", since: mark)
        let typed = "agent claude --resume \(id) --resume-only"
        check(keys == ["ctrl-c", "line /exit", "exit 0"], "view switch: the stand-in gets ⌃C, then /exit and Return, and quits", "\(keys)")
        check(inChat && rig.shows(tab, "Switched to Chat: Claude Code conversation \(id.prefix(8))") && rig.shows(tab, typed),
              "view switch: at the prompt, the separator line shows and nxtrm agent claude --resume ID --resume-only runs",
              rig.flat(tab).suffix(400).description)
        let resumed = rig.chatLog("claude").last { $0.hasPrefix("session ") } ?? ""
        check(resumed.contains("\"--resume\", \"\(id)\""), "view switch: the chat view's claude -p goes on with the conversation", resumed)
        check(c.tabs.count == tabsBefore && c.tabs.contains { $0 === tab } && tab.title == "switch here" && rig.flat(tab).contains("Reply to: hello"),
              "view switch: the same tab keeps its id, its title and its scrollback", "\(tab.title): \(c.tabs.count) tabs")
        check(quiet && !tab.status.suppressesNotices && rig.view(of: tab) == .chat,
              "view switch: no notice posts for the quit, and notices are back once the line runs", "quiet \(quiet)")
        check(c.validateMenuItem(item) && item.title == "Switch to Terminal", "view switch: View's item says Switch to Terminal for a chat view",
              item.title)
        await viewSwitchChatRefusals(rig, tab)

        // AE2: back by the right-click menu on the tab in the background: the line it was started with, with the resume form.
        rig.front(shell)
        let back = rig.tuiLog("claude").count
        let menuItem = rig.groupIndex(of: tab).flatMap { c.terminalTabMenu(at: $0) }?.items.first { $0.title == "Switch to Terminal" }
        if let menuItem, let action = menuItem.action { NSApp.sendAction(action, to: menuItem.target, from: menuItem) }
        let inTerminal = await wait(20) { rig.tuiStarted("claude", since: back, resuming: id) && rig.view(of: tab) == .terminal }
        let started = rig.tuiLog("claude").dropFirst(back).first { $0.hasPrefix("start ") } ?? ""
        check(menuItem != nil && inTerminal && started.contains("[\"--resume\", \"\(id)\"]")
                  && rig.shows(tab, "Switched to Terminal: Claude Code conversation \(id.prefix(8))"),
              "view switch: the tab's right-click Switch to Terminal, in the background, resumes it with claude --resume ID",
              "\(started): \(rig.flat(tab).suffix(300))")
        rig.type(tab, "/exit")
        _ = await wait(6) { !tab.status.running }
    }

    /// AE3, the chat side: a session reporting working, or asking, refuses the switch.
    static func viewSwitchChatRefusals(_ rig: ViewSwitchRig, _ tab: TerminalTab) async {
        await prompt(tab, "wait a while")
        let busy = await wait(10) { AgentSessionSocket.reports[tab.id]?.state == "working" }
        let working = await rig.switchView(tab)
        check(busy && rig.refusal(working) == "Claude Code is working. Switch when its turn ends.",
              "view switch: a session reporting working refuses the switch", rig.refusal(working) ?? "it ran")
        tab.view.send(txt: "\u{03}")
        _ = await wait(10) { AgentSessionSocket.reports[tab.id]?.state != "working" && tab.status.state != .working }
        await prompt(tab, "please rm it")
        let asks = await wait(10) { tab.status.state == .attention }
        let asking = await rig.switchView(tab)
        check(asks && rig.refusal(asking) == "Claude Code is asking you something. Answer it first.",
              "view switch: a session asking for permission refuses the switch", rig.refusal(asking) ?? "it ran")
        _ = await answerTab(tab, "Reject")
        // The turn ends as Reject's reply is drawn: the tab, its mark timed by that output, settles before the next switch.
        _ = await wait(10) {
            let reported = AgentSessionSocket.reports[tab.id]?.state
            return tab.status.state != .attention && tab.status.state != .working && reported != "attention" && reported != "working"
        }
    }

    // MARK: AE2: a launcher alias

    /// `cw`, an alias for `claude --model opus`: Chat names the option it drops, and the way back puts `cw` back.
    static func viewSwitchLauncher(_ rig: ViewSwitchRig) async {
        let id = "5e55a0de-0000-4000-8000-00000000a002"
        guard let tab = await rig.tui("claude", id: id, line: "cw"), await rig.turn(tab, "hello") else {
            return check(false, "view switch: cw runs the stand-in claude", rig.tuiLog("claude").suffix(3).joined(separator: " | "))
        }
        let toChat = await rig.switchView(tab)
        let inChat = await wait(20) { rig.chatReady(tab, id) }
        let separator = rig.flat(tab)
        check(rig.reached(toChat) == .chat && inChat && rig.shows(tab, "Not carried: --model") && !rig.shows(tab, "opus"),
              "view switch: from a launcher's claude --model opus, the separator names --model as not carried, never its value",
              separator.suffix(300).description)
        let back = rig.tuiLog("claude").count
        let toTerminal = await rig.switchView(tab)
        let inTerminal = await wait(20) { rig.tuiStarted("claude", since: back, resuming: id) }
        let started = rig.tuiLog("claude").dropFirst(back).first { $0.hasPrefix("start ") } ?? ""
        check(rig.reached(toTerminal) == .terminal && inTerminal && rig.shows(tab, "cw --resume \(id)")
                  && started.contains("[\"--model\", \"opus\", \"--resume\", \"\(id)\"]"),
              "view switch: back in the terminal, the launcher is replayed: cw --resume ID", "\(started): \(rig.flat(tab).suffix(300))")
        rig.type(tab, "/exit")
        _ = await wait(6) { !tab.status.running }
    }

    // MARK: AE5: Codex

    /// A stand-in `codex` goes to chat with /quit, and back with `codex resume ID`.
    static func viewSwitchCodex(_ rig: ViewSwitchRig) async {
        let id = "5e55a0de-0000-4000-8000-00000000a005"
        guard let tab = await rig.tui("codex", id: id), await rig.turn(tab, "hello") else {
            return check(false, "view switch: a tab runs the stand-in codex", rig.tuiLog("codex").suffix(3).joined(separator: " | "))
        }
        let mark = rig.tuiLog("codex").count
        let toChat = await rig.switchView(tab)
        let inChat = await wait(20) { rig.chatReady(tab, id) }
        let keys = rig.tuiKeys("codex", since: mark)
        check(rig.reached(toChat) == .chat && inChat && keys == ["ctrl-c", "line /quit", "exit 0"]
                  && rig.shows(tab, "agent codex --resume \(id) --resume-only")
                  && rig.chatLog("codex").contains("thread resumed \(id)"),
              "view switch: codex quits with ⌃C and /quit, and the chat view goes on with its thread",
              "\(rig.refusal(toChat) ?? "switched"), \(keys): \(rig.flat(tab).suffix(300))")
        let back = rig.tuiLog("codex").count
        let toTerminal = await rig.switchView(tab)
        let inTerminal = await wait(20) { rig.tuiStarted("codex", since: back, resuming: id) }
        check(rig.reached(toTerminal) == .terminal && inTerminal && rig.shows(tab, "codex resume \(id)"),
              "view switch: back in the terminal, codex resume ID", "\(rig.refusal(toTerminal) ?? "switched"): \(rig.flat(tab).suffix(300))")
        rig.type(tab, "/quit")
        _ = await wait(6) { !tab.status.running }
    }

    // MARK: AE3, AE4: refused before any key

    static func viewSwitchRefusals(_ rig: ViewSwitchRig) async {
        let id = "5e55a0de-0000-4000-8000-00000000a003"
        guard let tab = await rig.tui("claude", id: id), await rig.turn(tab, "hello") else {
            return check(false, "view switch: a tab runs the stand-in claude for the refusals")
        }
        rig.type(tab, "busy")
        let busy = await wait(8) { tab.status.state == .working }
        let mark = rig.tuiLog("claude").count
        let working = await rig.switchView(tab)
        check(busy && rig.refusal(working) == "Claude Code is working. Switch when its turn ends." && rig.tuiKeys("claude", since: mark).isEmpty,
              "view switch: while claude shows esc to interrupt, the switch is refused and nothing is typed",
              "\(rig.refusal(working) ?? "it ran"), \(tab.status.state.rawValue)")
        _ = await wait(8) { tab.status.state != .working }
        rig.type(tab, "ask")
        let asks = await wait(8) { tab.status.question != nil }
        let asked = rig.tuiLog("claude").count
        let asking = await rig.switchView(tab)
        check(asks && rig.refusal(asking) == "Claude Code is asking you something. Answer it first." && rig.tuiKeys("claude", since: asked).isEmpty,
              "view switch: while claude asks Do you want to…?, the switch is refused and nothing is typed",
              "\(rig.refusal(asking) ?? "it ran"), \(tab.status.question ?? "no question")")
        tab.view.send(txt: "1")
        _ = await wait(6) { tab.status.question == nil }
        rig.type(tab, "/exit")
        _ = await wait(6) { !tab.status.running }

        // An id named with another start of the process is a guess: never moved.
        let guessed = "5e55a0de-0000-4000-8000-00000000a004"
        guard let guess = await rig.tui("claude", id: guessed, env: "STANDIN_TUI=guess"), await rig.turn(guess, "hello") else {
            return check(false, "view switch: a tab runs the stand-in claude with a guessed id")
        }
        let refused = await rig.switchView(guess)
        check(rig.refusal(refused) == "Next Term can\u{2019}t tell which Claude Code conversation this is.",
              "view switch: an id with only a guessed source is refused", rig.refusal(refused) ?? "it ran")
        rig.type(guess, "/exit")
        _ = await wait(6) { !guess.status.running }
    }

    // MARK: AE6, AE7: the user's keys, the fallback and giving up

    static func viewSwitchQuitChecks(_ rig: ViewSwitchRig) async {
        let id = "5e55a0de-0000-4000-8000-00000000a006"
        guard let tab = await rig.tui("claude", id: id, env: "STANDIN_TUI=slow"), await rig.turn(tab, "hello") else {
            return check(false, "view switch: a tab runs the slow stand-in claude")
        }
        // AE6: MCP's typing waits out a switch; the user's keys never do, and the line is left to them.
        var outcome: ViewSwitchRunner.Outcome?
        ViewSwitchRunner.start(tab: tab) { outcome = $0 }
        let sent = await agentCall("send_to_tab", ["tab_id": tab.id.uuidString.lowercased(), "text": "hello from an agent"])
        check(sent.isError && sent.text.contains("switching views"), "view switch: send_to_tab into a switching tab is refused", sent.text)
        try? await Task.sleep(nanoseconds: 600_000_000)
        tab.userInput()
        tab.view.send(txt: "ls")
        _ = await wait(8) { outcome != nil }
        let left = rig.refusal(outcome) ?? ""
        check(left.hasPrefix("You typed in the tab, so Next Term left the line to you: ") && left.contains("--resume \(id) --resume-only")
                  && !rig.shows(tab, "Switched to Chat"),
              "view switch: keys the user types meanwhile leave the resume line to them, named, untyped", left)
        tab.view.send(txt: "\u{03}") // the stand-in clears the line typed
        try? await Task.sleep(nanoseconds: 300_000_000)

        // AE7: one that ignores /exit quits on the fallback's double ⌃C, and the switch goes on.
        let mark = rig.tuiLog("claude").count
        let slow = await rig.switchView(tab, within: 15)
        let keys = rig.tuiKeys("claude", since: mark)
        check(rig.reached(slow) == .chat && keys.suffix(3) == ["ctrl-c", "ctrl-c twice", "exit 0"] && keys.contains("quit ignored"),
              "view switch: a claude that ignores /exit quits on the fallback's double ⌃C, and the switch goes on",
              "\(keys): \(rig.refusal(slow) ?? "")")
        _ = await wait(15) { rig.chatReady(tab, id) }
        rig.close(tab)

        let stubbornID = "5e55a0de-0000-4000-8000-00000000a007"
        guard let stubborn = await rig.tui("claude", id: stubbornID, env: "STANDIN_TUI=stubborn"), await rig.turn(stubborn, "hello") else {
            return check(false, "view switch: a tab runs the stubborn stand-in claude")
        }
        let began = Date()
        let gaveUp = await rig.switchView(stubborn, within: 15)
        let took = Date().timeIntervalSince(began)
        check(rig.refusal(gaveUp) == "Claude Code didn\u{2019}t quit, so nothing more was typed." && took > 7 && took < 11
                  && stubborn.status.running && !rig.shows(stubborn, "--resume-only"),
              "view switch: a claude that ignores every ⌃C gets the give-up note after about 8 seconds, with nothing typed",
              String(format: "%.1f s: ", took) + (rig.refusal(gaveUp) ?? "it ran"))
        rig.close(stubborn)
    }

    // MARK: AE10: switch_view

    static func viewSwitchMCP(_ rig: ViewSwitchRig) async {
        let id = "5e55a0de-0000-4000-8000-00000000a010"
        guard let tab = await rig.tui("claude", id: id), await rig.turn(tab, "hello") else {
            return check(false, "view switch: a tab runs the stand-in claude for switch_view")
        }
        let tabID = tab.id.uuidString.lowercased()
        let before = await rig.listedView(tabID)
        rig.type(tab, "busy")
        _ = await wait(8) { tab.status.state == .working }
        let working = await rig.call("switch_view", ["tab_id": tabID])
        check(working.isError && working.text.contains("is working") && MCPWriteControl.pending == nil,
              "view switch: switch_view on a working tab fails with the refusal's words, before any question", working.text)
        _ = await wait(8) { tab.status.state != .working }

        let mark = rig.tuiLog("claude").count
        let declined = await rig.asked("switch_view", ["tab_id": tabID, "view": "chat"], approve: false)
        check(declined.asked && declined.result.isError && rig.tuiKeys("claude", since: mark).isEmpty && rig.view(of: tab) == .terminal,
              "view switch: switch_view asks on the Mac, and Decline changes nothing", declined.result.text)
        let approved = await rig.asked("switch_view", ["tab_id": tabID, "view": "chat"], approve: true)
        let answer = (try? JSONSerialization.jsonObject(with: Data(approved.result.text.utf8))) as? [String: Any] ?? [:]
        _ = await wait(15) { rig.chatReady(tab, id) }
        let after = await rig.listedView(tabID)
        check(approved.asked && !approved.result.isError && answer["view"] as? String == "chat" && answer["session_id"] as? String == id,
              "view switch: approved, switch_view switches and answers the chat view", approved.result.text)
        check(before == "terminal" && after == "chat", "view switch: list_tabs gives the view, terminal before and chat after",
              "\(before ?? "none") / \(after ?? "none")")
        rig.close(tab)
    }

    // MARK: AE11, AE13: Open in Terminal

    static func viewSwitchOffers(_ rig: ViewSwitchRig) async {
        // AE11: /login in a session with a conversation isn't sent; the bar's button resumes it in the terminal view.
        let id = "5e55a0de-0000-4000-8000-00000000a011"
        guard let tab = await rig.shell() else { return check(false, "view switch: a tab for the /login session") }
        rig.type(tab, "export STANDIN_SESSION_ID=\(id)")
        rig.type(tab, ACPSessionTabs.launcher + " agent claude")
        let ready = await wait(15) { flatScreen(tab).contains("(stand-in-model) is ready.") }
        await prompt(tab, "hello")
        let turned = await wait(10) { (AgentSessionSocket.reports[tab.id]?.turns ?? 0) > 0 && tab.status.state != .working }
        let turnsBefore = rig.chatLog("claude").filter { $0.hasPrefix("turn ") }.count
        rig.type(tab, "/login")
        let barShown = await wait(8) { ViewSwitchOfferBar.open(for: tab) != nil }
        let bar = ViewSwitchOfferBar.open(for: tab)
        check(ready && turned && barShown && bar?.shownText == "/login works in the terminal view."
                  && rig.shows(tab, "/login works in the terminal view: Open in Terminal")
                  && rig.chatLog("claude").filter { $0.hasPrefix("turn ") }.count == turnsBefore,
              "view switch: /login in a session isn't sent, and the bar offers the terminal view", rig.flat(tab).suffix(300).description)
        let back = rig.tuiLog("claude").count
        bar?.pressOpen()
        let opened = await wait(20) { rig.tuiStarted("claude", since: back, resuming: id) }
        check(opened && rig.shows(tab, "claude --resume \(id)") && ViewSwitchOfferBar.open(for: tab) == nil,
              "view switch: the bar's Open in Terminal switches to the terminal view with claude --resume ID", rig.flat(tab).suffix(300).description)
        rig.type(tab, "/exit")
        _ = await wait(6) { !tab.status.running }

        // AE11: not signed in, the session ends with the bar, whose button starts claude at the prompt.
        guard let unsigned = await rig.shell() else { return check(false, "view switch: a tab for the sign-in session") }
        rig.type(unsigned, "export STANDIN_MODE=auth")
        rig.type(unsigned, ACPSessionTabs.launcher + " agent claude --prompt hi")
        let ended = await wait(15) { !unsigned.status.running && ViewSwitchOfferBar.open(for: unsigned) != nil }
        let signIn = ViewSwitchOfferBar.open(for: unsigned)
        check(ended && signIn?.shownText == "Claude Code needs you to sign in, in the terminal view.",
              "view switch: a session that isn't signed in ends with the Open in Terminal bar", rig.flat(unsigned).suffix(300).description)
        // A draft the user left on the prompt meanwhile is theirs: Open in Terminal types nothing, the draft stays, a note
        // says why, and the bar stays for when the prompt is clear.
        let draft = "echo nt-draft"
        let draftMark = rig.tuiLog("claude").count
        unsigned.userInput()
        unsigned.view.send(txt: draft)
        let drafted = await wait(8) { ViewSwitchRunner.lineState(unsigned) == .holdsText && unsigned.lastBuffer?.report.buffer == draft }
        signIn?.pressOpen()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let leftNote = "The prompt has text on it, so Next Term left the line to you: claude"
        check(drafted && rig.tuiLog("claude").count == draftMark && !unsigned.status.running
                  && unsigned.lastBuffer?.report.buffer == draft && rig.showsNote(unsigned, leftNote)
                  && ViewSwitchOfferBar.open(for: unsigned) != nil && !rig.shows(unsigned, "Switched to Terminal"),
              "view switch: a draft on the prompt while the bar is open: Open in Terminal types nothing, leaves the draft and says why",
              "drafted \(drafted), line \(unsigned.lastBuffer?.report.buffer ?? "unknown"): \(rig.flat(unsigned).suffix(200))")
        unsigned.view.send(txt: String(repeating: "\u{7f}", count: draft.count))
        _ = await wait(8) { ViewSwitchRunner.lineState(unsigned) == .empty }
        let plain = rig.tuiLog("claude").count
        signIn?.pressOpen()
        let started = await wait(15) { rig.tuiLog("claude").dropFirst(plain).contains { $0.hasPrefix("start ") && $0.contains(" [] new ") } }
        check(started && unsigned.status.running, "view switch: its button types claude at the prompt", rig.flat(unsigned).suffix(300).description)
        rig.type(unsigned, "/exit")
        _ = await wait(6) { !unsigned.status.running }

        // AE13: a switch's resume that fails ends with the bar, never a fresh conversation.
        let staleID = "5e55a0de-0000-4000-8000-00000000a013"
        guard let stale = await rig.tui("claude", id: staleID, env: "STANDIN_MODE=stale"), await rig.turn(stale, "hello") else {
            return check(false, "view switch: a tab runs the stand-in claude for a failed resume")
        }
        let sessions = rig.chatLog("claude").filter { $0.hasPrefix("session ") }.count
        let toChat = await rig.switchView(stale)
        let barred = await wait(15) { !stale.status.running && ViewSwitchOfferBar.open(for: stale) != nil }
        let tried = rig.chatLog("claude").filter { $0.hasPrefix("session ") }.dropFirst(sessions)
        check(rig.reached(toChat) == .chat && barred && ViewSwitchOfferBar.open(for: stale)?.shownText == "This conversation couldn\u{2019}t go on in Chat. Open it in Terminal."
                  && tried.count == 1 && tried.allSatisfy { $0.contains("\"--resume\", \"\(staleID)\"") },
              "view switch: a switch whose --resume fails ends with the bar, starting no new conversation", "\(Array(tried)): \(rig.flat(stale).suffix(300))")
        let again = rig.tuiLog("claude").count
        ViewSwitchOfferBar.open(for: stale)?.pressOpen()
        let reopened = await wait(15) { rig.tuiStarted("claude", since: again, resuming: staleID) }
        check(reopened, "view switch: its Open in Terminal resumes the conversation in the terminal view", rig.flat(stale).suffix(300).description)
        rig.type(stale, "/exit")
        _ = await wait(6) { !stale.status.running }
    }

    // MARK: AE12: the Settings default

    static func viewSwitchDefaults(_ rig: ViewSwitchRig) async {
        // Nothing chosen: Terminal. new_tab's bare claude with a prompt starts the agent's own interface, and says so.
        let plainMark = rig.tuiLog("claude").count
        let plain = await rig.call("new_tab", ["directory": rig.work, "command": "claude", "prompt": "fix it"])
        let plainJSON = (try? JSONSerialization.jsonObject(with: Data(plain.text.utf8))) as? [String: Any] ?? [:]
        let plainTab = rig.adopt(plainJSON["id"] as? String)
        let own = await wait(15) { rig.tuiLog("claude").dropFirst(plainMark).contains { $0.hasPrefix("start ") && $0.contains("[\"fix it\"]") } }
        check(AgentOpenView.opensIn(.claude, defaults: rig.suite) == .terminal && !plain.isError
                  && plainJSON["view"] as? String == "terminal" && own,
              "view switch: with Terminal, new_tab's bare claude with a prompt starts claude and answers the terminal view", plain.text)
        if let plainTab {
            rig.type(plainTab, "/exit")
            _ = await wait(6) { !plainTab.status.running }
        }

        // Settings › Editor's popup writes the key, Claude Code's alone.
        let control = AgentOpenViewControls.control(.claude)
        let popup = control.subviews.compactMap { $0 as? NSPopUpButton }.first
        popup?.selectItem(withTitle: "Chat")
        if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        check(AgentOpenView.opensIn(.claude, defaults: rig.suite) == .chat && AgentOpenView.opensIn(.codex, defaults: rig.suite) == .terminal,
              "view switch: Settings' Open Claude Code in: Chat writes Claude Code's key and leaves Codex's",
              rig.suite.string(forKey: AgentOpenView.key(.claude)) ?? "unset")

        let bare = await rig.call("new_tab", ["directory": rig.work, "command": "claude", "prompt": "fix it"])
        let bareJSON = (try? JSONSerialization.jsonObject(with: Data(bare.text.utf8))) as? [String: Any] ?? [:]
        let bareTab = rig.adopt(bareJSON["id"] as? String)
        let ran = await wait(15) { rig.chatLog("claude").contains { $0.hasPrefix("turn ") && $0.hasSuffix(" fix it") } }
        check(!bare.isError && bareJSON["view"] as? String == "chat" && ran && bareTab.map { rig.shows($0, "agent claude --prompt") } == true,
              "view switch: with Chat, new_tab's bare claude with a prompt starts nxtrm agent claude --prompt and answers the chat view",
              "\(bare.text): \(bareTab.map { rig.flat($0).suffix(200).description } ?? "no tab")")

        let mark = rig.tuiLog("claude").count
        let options = await rig.call("new_tab", ["directory": rig.work, "command": "claude --model opus"])
        let optionsJSON = (try? JSONSerialization.jsonObject(with: Data(options.text.utf8))) as? [String: Any] ?? [:]
        _ = rig.adopt(optionsJSON["id"] as? String)
        let terminal = await wait(15) { rig.tuiLog("claude").dropFirst(mark).contains { $0.hasPrefix("start ") && $0.contains("\"--model\", \"opus\"") } }
        check(!options.isError && optionsJSON["view"] as? String != "chat" && terminal,
              "view switch: new_tab's claude --model opus stays in the terminal view", options.text)

        guard let typed = await rig.shell() else { return check(false, "view switch: a shell for a typed claude") }
        let typedMark = rig.tuiLog("claude").count
        rig.type(typed, "claude")
        let typedOwn = await wait(15) { rig.tuiLog("claude").dropFirst(typedMark).contains { $0.hasPrefix("start ") } && rig.view(of: typed) == .terminal }
        check(typedOwn, "view switch: claude typed in a shell stays in the terminal view", rig.flat(typed).suffix(200).description)
        rig.type(typed, "/exit")
        _ = await wait(6) { !typed.status.running }
    }
}

/// What the view switch part works in: its folders and stand-ins, its own zsh config, its defaults suite and the tabs it
/// opened, all undone by `tearDown`.
@MainActor
final class ViewSwitchRig {
    let c: TerminalWindowController
    let root: String
    let bin: String
    /// The folder the tabs run in, by its real path, as the stand-ins' own folder reads.
    let work: String
    let suite: UserDefaults
    private let suiteName: String
    private var opened: [TerminalTab] = []
    private let savedTrust: UserDefaults
    private let savedVersions: UserDefaults
    private let savedOpenView: UserDefaults
    private let savedZDOTDIR: String?
    private let savedFront: TerminalTab?

    init?(_ c: TerminalWindowController) {
        self.c = c
        let fm = FileManager.default
        root = canonicalPath(NSTemporaryDirectory()) + "/nt-vs-\(getpid())-\(UUID().uuidString.prefix(6))"
        bin = root + "/bin"
        work = root + "/work"
        let zdot = root + "/zsh"
        let claudeStore = root + "/claude-store"
        let codexHome = root + "/codex-home"
        for folder in [bin + "/tui", bin + "/chat", work, claudeStore, codexHome] {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let files: [(String, String)] = [
            ("claude", SelfTest.viewSwitchDispatcher), ("codex", SelfTest.viewSwitchDispatcher),
            ("tui/claude", SelfTest.viewSwitchTUIStandIn), ("tui/codex", SelfTest.viewSwitchTUIStandIn),
            ("chat/claude", SelfTest.claudeStandIn), ("chat/codex", SelfTest.codexStandIn),
        ]
        for (name, text) in files {
            let path = bin + "/" + name
            guard (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
            chmod(path, 0o755)
        }
        // Every tab this part opens reads this config: the stand-ins first on its PATH, their stores, a launcher alias.
        guard IsolatedShellConfig.prepare(URL(fileURLWithPath: zdot, isDirectory: true)) else { return nil }
        let exports = "export PATH=\(ShellQuote.quote(bin)):$PATH CLAUDE_CONFIG_DIR=\(ShellQuote.quote(claudeStore)) "
            + "CODEX_HOME=\(ShellQuote.quote(codexHome)) STANDIN_CODEX_RESUMES=1\nalias cw='claude --model opus'\n"
        let zshrc = (try? String(contentsOfFile: zdot + "/.zshrc", encoding: .utf8)) ?? ""
        guard (try? (zshrc + exports).write(toFile: zdot + "/.zshrc", atomically: true, encoding: .utf8)) != nil else { return nil }

        // Trust, versions and the Settings default in this part's own suite: the user's are never read or changed.
        suiteName = "nt-selftest-view-switch-\(getpid())"
        guard let suite = UserDefaults(suiteName: suiteName) else { return nil }
        self.suite = suite
        suite.set(AgentSessionTrust.adding(work, to: []), forKey: AgentSessionTrust.defaultsKey)
        savedTrust = AgentSessionSocket.trustStore
        savedVersions = AgentSessionSocket.versionStore
        savedOpenView = AgentOpenView.defaults
        savedZDOTDIR = TerminalTab.testUserZDOTDIR
        AgentSessionSocket.trustStore = suite
        AgentSessionSocket.versionStore = suite
        AgentOpenView.defaults = suite
        TerminalTab.testUserZDOTDIR = zdot
        savedFront = c.activeTab
    }

    func tearDown() {
        if let pending = MCPWriteControl.pending?.window { pending.declineButton.performClick(nil) }
        for window in SelfTest.approvals() { window.declineButton.performClick(nil) }
        for tab in opened { close(tab) }
        if let savedFront { front(savedFront) }
        TerminalTab.testUserZDOTDIR = savedZDOTDIR
        AgentSessionSocket.trustStore = savedTrust
        AgentSessionSocket.versionStore = savedVersions
        AgentOpenView.defaults = savedOpenView
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: tabs

    /// A tab at the shell's prompt in `work`.
    func shell() async -> TerminalTab? {
        let tab = c.addTab(directory: work, select: false)
        opened.append(tab)
        guard await SelfTest.wait(20, { tab.status.integrated }) else { return nil }
        return tab
    }

    /// A tab running the terminal interface's stand-in of `agent` with session `id` (`line` starts it), `env` exported,
    /// once its tab has settled. An agent whose screen hasn't shown its working hint yet is timed by its output: its
    /// first frame, drawn later than a keystroke's echo (a cold start of Python takes over half a second), marks it
    /// working until it has been quiet for `TabStatus.quietAfter`, as a real Claude Code's or Codex's start does, and
    /// a switch then is refused as working. A person sees that mark and waits; so does the part.
    func tui(_ agent: String, id: String, env: String = "", line: String? = nil) async -> TerminalTab? {
        guard let tab = await shell() else { return nil }
        type(tab, "export STANDIN_ID=\(id)" + (env.isEmpty ? "" : " " + env))
        type(tab, line ?? agent)
        let ready = await SelfTest.wait(15) {
            tab.status.running && tab.status.kind == .agent && flat(tab).contains("stand-in, new session \(id)")
                && tab.status.state != .working
        }
        return ready ? tab : nil
    }

    /// One turn in a terminal interface's stand-in: its conversation then exists.
    func turn(_ tab: TerminalTab, _ words: String) async -> Bool {
        type(tab, words)
        return await SelfTest.wait(10) { flat(tab).contains("Reply to: \(words)") }
    }

    func type(_ tab: TerminalTab, _ line: String) { tab.view.send(txt: line + "\r") }

    func flat(_ tab: TerminalTab) -> String { SelfTest.flatScreen(tab) }

    /// The tab's screen shows `text`, read across the screen's soft wraps: a long line (the debug build's path to
    /// `nxtrm`, in a worktree) wraps mid-word, so `flat` reads "agent claud e --resume". Whitespace is dropped on both
    /// sides.
    func shows(_ tab: TerminalTab, _ text: String) -> Bool {
        func squeezed(_ words: String) -> String { words.filter { !$0.isWhitespace } }
        return squeezed(flat(tab)).contains(squeezed(text))
    }

    /// The tab's window's tab with the keyboard, as a click on it makes it.
    func front(_ tab: TerminalTab) {
        guard let owner = MCPControl.controller(of: tab),
              let index = owner.groups.firstIndex(where: { (group: PaneGroup) -> Bool in group.panes.contains { $0 === tab } }) else { return }
        owner.select(index)
    }

    func groupIndex(of tab: TerminalTab) -> Int? {
        c.groups.firstIndex { (group: PaneGroup) -> Bool in group.panes.contains { $0 === tab } }
    }

    /// A tab an MCP call opened, by its id, closed with the part's own.
    func adopt(_ id: String?) -> TerminalTab? {
        guard let id else { return nil }
        let tab = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == id }
        if let tab { opened.append(tab) }
        return tab
    }

    func close(_ tab: TerminalTab) {
        ViewSwitchOfferBar.close(tab)
        MCPControl.controller(of: tab)?.remove(tab)
    }

    // MARK: the switch

    /// Runs the switch as the icon does, and waits for how it ends.
    func switchView(_ tab: TerminalTab, wanted: ViewSwitch.View? = nil, within seconds: Double = 20) async -> ViewSwitchRunner.Outcome? {
        var outcome: ViewSwitchRunner.Outcome?
        ViewSwitchRunner.start(tab: tab, wanted: wanted) { outcome = $0 }
        _ = await SelfTest.wait(seconds) { outcome != nil }
        return outcome
    }

    func refusal(_ outcome: ViewSwitchRunner.Outcome?) -> String? {
        guard case .failure(let failure)? = outcome else { return nil }
        return failure.text
    }

    func reached(_ outcome: ViewSwitchRunner.Outcome?) -> ViewSwitch.View? {
        guard case .success(let switched)? = outcome else { return nil }
        return switched.view
    }

    /// The note the tab shows now (TerminalTab.showNote's label), if it is `text`.
    func showsNote(_ tab: TerminalTab, _ text: String) -> Bool {
        tab.view.subviews.contains { ($0 as? NSTextField)?.stringValue == text }
    }

    func view(of tab: TerminalTab) -> ViewSwitch.View? { ViewSwitchRunner.offer(for: tab)?.view }

    /// The chat view runs, its session going on with conversation `id`, as its report says.
    func chatReady(_ tab: TerminalTab, _ id: String) -> Bool {
        guard let report = AgentSessionSocket.reports[tab.id] else { return false }
        return tab.status.running && report.resumed && report.sessionID == id && view(of: tab) == .chat
    }

    // MARK: the stand-ins' logs

    func tuiLog(_ agent: String) -> [String] { SelfTest.standInLog(URL(fileURLWithPath: bin + "/tui/\(agent).log")) }
    func chatLog(_ agent: String) -> [String] { SelfTest.standInLog(URL(fileURLWithPath: bin + "/chat/\(agent).log")) }

    /// What the terminal interface's stand-in did with the keys it got after line `since` of its log: its ⌃C, the lines
    /// it read and how it exited, without the raw bytes.
    func tuiKeys(_ agent: String, since: Int) -> [String] {
        tuiLog(agent).dropFirst(since).filter { (line: String) -> Bool in
            line.hasPrefix("ctrl-c") || line.hasPrefix("line ") || line.hasPrefix("exit ") || line == "quit ignored"
        }
    }

    /// The terminal interface's stand-in started again after line `since`, going on with `id`.
    func tuiStarted(_ agent: String, since: Int, resuming id: String) -> Bool {
        tuiLog(agent).dropFirst(since).contains { $0.hasPrefix("start ") && $0.hasSuffix(" resume \(id)") }
    }

    // MARK: MCP

    func call(_ tool: String, _ arguments: [String: Any], within seconds: Double = 30) async -> (text: String, isError: Bool) {
        var result: MCPServer.CallResult?
        MCPControl.call(tool, arguments, caller: nil) { result = $0 }
        _ = await SelfTest.wait(seconds) { result != nil }
        return (result?.text ?? "(no answer)", result?.isError ?? true)
    }

    /// A tool that asks on the Mac, answered there as the user would.
    func asked(_ tool: String, _ arguments: [String: Any], approve: Bool) async -> (asked: Bool, result: (text: String, isError: Bool)) {
        var result: MCPServer.CallResult?
        MCPControl.call(tool, arguments, caller: nil) { result = $0 }
        let asked = await SelfTest.wait(10) { MCPWriteControl.pending?.window != nil || result != nil }
        let window = MCPWriteControl.pending?.window
        if approve { window?.approveButton.performClick(nil) } else { window?.declineButton.performClick(nil) }
        _ = await SelfTest.wait(30) { result != nil }
        return (asked && window != nil, (result?.text ?? "(no answer)", result?.isError ?? true))
    }

    /// The `view` list_tabs gives tab `id`.
    func listedView(_ id: String) async -> String? {
        let listed = await call("list_tabs", [:])
        let json = (try? JSONSerialization.jsonObject(with: Data(listed.text.utf8))) as? [String: Any] ?? [:]
        let windows = json["windows"] as? [[String: Any]] ?? []
        let tabs = windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
        return tabs.first { $0["id"] as? String == id }?["view"] as? String
    }
}
#endif
