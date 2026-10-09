import AppKit
import NextTermCore

/// Agent evidence for a restore (KTD4): a stand-in `claude` runs in a tab, a Claude store made here by hand names
/// its process in sessions/<pid>.json, and capture reads an exact id from that file for the tab's own process and
/// start time. The same file with another start time is a guess. The stand-in is a copy of /bin/sleep named
/// claude, so the kernel shows a process called claude; nothing is resumed or run from what is captured.
extension SelfTest {
    static let evidenceClaudeID = "5e55a0de-0000-4000-8000-0000000000e1"

    static func agentEvidenceChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-evidence-\(getpid())"
        let project = canonicalPath(proj.path)
        let bin = home + "/bin"
        try? fm.removeItem(atPath: home)
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: "/bin/sleep", toPath: bin + "/claude")
        let holder = app.openFolder(project, newWindow: false)
        let tab = holder.addTab(directory: project)
        defer {
            tab.view.send(txt: "\u{03}")
            if let owner = app.controllers.first(where: { $0.tabs.contains { $0 === tab } }) { owner.remove(tab) }
            try? fm.removeItem(atPath: home)
        }
        _ = await wait(20) { tab.status.integrated }
        tab.view.send(txt: bin + "/claude 120\r")
        check(await wait(10) { tab.status.running && tab.status.kind == .agent }, "evidence: a tab runs a stand-in claude", tab.status.command)
        let leader = tcgetpgrp(tab.view.process.childfd)
        guard leader > 0, let start = ProcessInspector.startTime(of: leader) else {
            return check(false, "evidence: the stand-in's process and start time read")
        }

        func capture(started: Date) -> SessionSnapshot.Evidence? {
            let record: [String: Any] = ["pid": Int(leader), "sessionId": evidenceClaudeID, "cwd": project,
                                         "procStart": AgentEvidence.procStartText(started), "status": "busy"]
            let path = home + "/.claude/sessions/\(leader).json"
            let data = (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
            try? data.write(to: URL(fileURLWithPath: path))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd, shellPid: tab.view.process.shellPid,
                                                  status: tab.status, home: home)
        }

        let exact = capture(started: start)
        check(exact?.agent == .claude && exact?.source == .sessionFile && exact?.sessionID == evidenceClaudeID,
              "evidence: Claude's session file for the tab's own process and start time gives an exact id", String(describing: exact))
        check(exact?.sessionFolder == project && exact?.executable == bin + "/claude" && exact?.ranAsTyped == true
              && exact?.flagsAllowed == true && exact?.startedAt != nil,
              "evidence: it records the session's folder, the path that ran, and that the line ran as typed", String(describing: exact))
        let guessed = capture(started: start.addingTimeInterval(-3600))
        check(guessed?.agent == .claude && guessed?.source == .guess && guessed?.sessionID == nil,
              "evidence: the same file for another start of that pid is a guess", String(describing: guessed))
        let line = RestoreAgent.claude.putBackLine(id: exact?.sessionID, folder: exact?.sessionFolder)
        check(line == "claude --resume \(evidenceClaudeID)", "evidence: its put-back line is the resume form alone", line ?? "none")
    }
}
