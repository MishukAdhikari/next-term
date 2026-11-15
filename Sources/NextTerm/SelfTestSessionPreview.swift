import AppKit
import NextTermCore

/// ⌥⌘O's preview (plan 039 U4): the selected session's last turns beside the list, read from its transcript; another
/// selected session shows its own; an agent whose conversations Next Term doesn't read says so. Sessions are a
/// made-up Claude Code transcript in a home folder of the test's own.
extension SelfTest {
    static func sessionPreviewChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-preview-\(getpid())")
        let home = base.appendingPathComponent("home"), project = base.appendingPathComponent("project").path
        try? fm.removeItem(at: base)
        try? fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        let claudeDir = home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(project))
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        func transcript(_ id: String, prompt: String, reply: String, title: String, ago: TimeInterval) {
            let when = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-ago))
            let lines = [
                line(["type": "summary"]), // a tail's first line is dropped, as it may start inside a record
                line(["type": "user", "cwd": project, "timestamp": when, "gitBranch": "main", "message": ["role": "user", "content": prompt]]),
                line(["type": "assistant", "cwd": project, "timestamp": when,
                      "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": reply], ["type": "tool_use", "name": "Edit"]]]]),
                line(["type": "custom-title", "customTitle": title]),
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: claudeDir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }
        transcript("p1", prompt: "Fix the login redirect", reply: "The redirect loops because the cookie path is wrong.", title: "Login loop", ago: 60)
        transcript("p2", prompt: "Add rate limiting", reply: "Added a token bucket per user.", title: "Rate limits", ago: 3600)

        let sessionsHome = SessionStore.home
        SessionStore.home = home.path
        let holder = app.openWindow(directory: project)
        let panel = holder.sessionsPanel
        defer {
            panel.close()
            SessionStore.home = sessionsHome
            holder.window?.close()
            try? fm.removeItem(at: base)
        }
        holder.window?.makeKeyAndOrderFront(nil)
        holder.resumeSession(nil)
        check(await wait(10) { panel.shownTitles == ["Login loop", "Rate limits"] }, "session preview: ⌥⌘O lists the sessions",
              panel.shownTitles.joined(separator: " | "))
        let first = await wait(5) { panel.preview.text.contains("cookie path is wrong") && panel.preview.text.contains("Fix the login redirect") }
        check(first && panel.preview.frame.width > 200, "session preview: the selected session's last turns show beside the list",
              "\(Int(panel.preview.frame.width)) wide: " + panel.preview.text.debugDescription)
        panel.query = "rate"
        check(await wait(5) { panel.preview.text.contains("token bucket") }, "session preview: another session selected shows its own",
              panel.preview.text.debugDescription)
        await screenshot(panel.panelWindow, suffix: "session-preview")
        let other = AgentSession(agent: .gemini, id: "g1", cwd: project, title: "Gemini work", named: false, createdAt: nil, updatedAt: Date(),
                                 gitBranch: nil, model: nil, isRunning: false)
        check(SessionPreview.read(other, home: home.path).hasPrefix("No preview for Gemini CLI sessions"),
              "session preview: an agent Next Term doesn't read says so", SessionPreview.read(other, home: home.path))
    }
}
