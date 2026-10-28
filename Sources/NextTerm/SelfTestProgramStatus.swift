import AppKit
import NextTermCore

extension SelfTest {
    /// OSC 7501 with a stand-in agent named claude whose screen never shows Claude Code's working hint (as with a custom
    /// status line): the tab answers its query, then follows its reports, working, then blocked with its words as the
    /// question, then idle.
    static func programStatusChecks(_ c: TerminalWindowController) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nextterm-7501-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = dir.appendingPathComponent("reply.txt")
        let agent = dir.appendingPathComponent("claude")
        let asked = Data("Allow the edit to a.swift?".utf8).base64EncodedString()
        try? """
        #!/bin/bash
        saved=$(stty -g); stty raw -echo
        printf '\\033]7501;?\\033\\\\'
        IFS= read -r -t 3 -d '\\' answer
        stty "$saved"
        printf '%s' "$answer" | tr '\\033' 'E' > '\(reply.path)'
        printf '\\033]7501;state=working:app=claude\\033\\\\'; printf 'Thinking it over\\n'; sleep 4
        printf '\\033]7501;state=blocked:kind=permission:app=claude:msg=\(asked)\\033\\\\'; sleep 4
        printf '\\033]7501;state=idle:app=claude\\033\\\\'; printf 'Ready.\\n'
        read line
        """.write(to: agent, atomically: true, encoding: .utf8)
        chmod(agent.path, 0o755)
        let tab = c.addTab(directory: nil, select: false)
        _ = await wait(20) { tab.status.integrated }
        tab.view.send(txt: "PATH=\(dir.path):$PATH claude\r")
        func answered() -> String { (try? String(contentsOf: reply, encoding: .utf8)) ?? "" }
        let replied = await wait(8) { answered().contains("E]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth") }
        check(replied, "program status: the tab answers OSC 7501's query with the states and kinds it takes", answered())
        let working = await wait(8) { tab.status.state == .working && tab.programReports }
        let hintless = !tab.screenTail().joined(separator: "\n").contains("esc to interrupt")
        check(working && hintless, "program status: an agent that reports working shows working, with no hint on its screen",
              "\(tab.status.state.rawValue), reports \(tab.programReports)")
        let asking = await wait(8) { tab.status.state == .attention && tab.status.question == "Allow the edit to a.swift?" }
        check(asking, "program status: reported blocked, it needs you, its own words the question",
              "\(tab.status.state.rawValue): \(tab.status.question ?? "no question")")
        let stopped = await wait(8) { tab.status.state != .working && tab.status.state != .attention && tab.status.question == nil }
        check(stopped, "program status: reported idle, its turn is over", tab.status.state.rawValue)
        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
        c.remove(tab)
    }
}
