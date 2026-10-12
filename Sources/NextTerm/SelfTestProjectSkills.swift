import AppKit
import NextTermCore

/// Settings › Skills › Project, in a project and a home of the self-test's own: it opens on Personal and makes Project
/// only when chosen, fits Settings, and each agent's column names the copy that agent loads (the user's copy over the
/// project's for Claude Code, "via Next Term" for a folder an agent doesn't read), with Next Term's own skill last.
extension SelfTest {
    static func projectSkillsChecks(home: String) async {
        let manager = FileManager.default
        let project = canonicalPath(NSTemporaryDirectory()) + "/nt-skills-project-\(getpid())"
        func skill(_ root: String, _ name: String, _ body: String) {
            try? manager.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
            try? "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: root + "/" + name + "/SKILL.md", atomically: true, encoding: .utf8)
        }
        try? manager.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
        skill(project + "/.agents/skills", "st-deploy", "same")
        skill(project + "/.claude/skills", "st-deploy", "same")
        skill(project + "/.claude/skills", "st-lint", "lint")
        skill(home + "/.claude/skills", "st-deploy", "mine")
        let saved = ProjectSkillsView.projectsForTest
        ProjectSkillsView.projectsForTest = [project]
        defer {
            ProjectSkillsView.projectsForTest = saved
            try? manager.removeItem(atPath: project)
            try? manager.removeItem(atPath: home + "/.claude/skills/st-deploy")
        }

        let pane = SkillsPane(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        let tabs = NSTabView()
        let tab = NSTabViewItem(identifier: "skills")
        tab.view = pane
        tabs.addTabViewItem(tab)
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: true)
        probe.contentView = tabs
        check(pane.scope.selectedSegment == 0 && pane.project == nil && !pane.personal.isHidden,
              "skills project: Settings › Skills opens on Personal, and Project is made only when chosen")
        pane.show(1)
        guard let view = pane.project else { return check(false, "skills project: choosing Project shows it") }
        _ = await wait(10) { view.rows.count >= 3 }
        probe.layoutIfNeeded()
        check(probe.frame.width <= 621 && pane.personal.isHidden && view.rows.map(\.name) == ["st-deploy", "st-lint", "next-term-tabs"],
              "skills project: Project lists the project's skills and Next Term's own last, fits Settings, and Personal is hidden",
              "\(probe.frame.width) \(view.rows.map(\.name))")

        func text(_ name: String, _ column: String) -> String {
            guard let row = view.rows.first(where: { $0.name == name }) else { return "none" }
            return view.cellText(row, column: column).text
        }
        let app: AppDelegate = AppDelegate.shared
        let reachable = app.agentControl ? "via Next Term" : "—"
        let claude = SkillAgent.claudeCode.rawValue, codex = SkillAgent.codex.rawValue, commandCode = SkillAgent.commandCode.rawValue
        check(text("st-deploy", "where") == ".agents + .claude" && text("st-deploy", claude) == "● personal"
              && text("st-deploy", codex) == "● project" && text("st-deploy", commandCode) == "● project",
              "skills project: each agent's copy is named, Claude Code's own over the project's, and identical copies are one place",
              ["where", claude, codex, commandCode].map { text("st-deploy", $0) }.joined(separator: " | "))
        check(text("st-lint", claude) == "● project" && text("st-lint", codex) == reachable && text("st-lint", commandCode) == reachable,
              "skills project: a folder an agent doesn't read is offered through Next Term",
              [claude, codex, commandCode].map { text("st-lint", $0) }.joined(separator: " | "))
        let builtIn = !app.agentControl ? "—" : app.agentsOfferTabs ? "via Next Term" : "off"
        check(text("next-term-tabs", "where") == "Next Term" && text("next-term-tabs", codex) == builtIn && view.openButton.isEnabled == false
              && view.summary.stringValue == "2 skills · read-only",
              "skills project: Next Term's own skill follows its switch, and the summary counts the project's", text("next-term-tabs", codex) + " " + view.summary.stringValue)

        ProjectSkillsView.projectsForTest = []
        view.reload()
        check(view.showsEmpty, "skills project: with no project open it asks for one")
        pane.show(0)
        check(!pane.personal.isHidden && view.isHidden, "skills project: back on Personal, Project is hidden")
    }
}
