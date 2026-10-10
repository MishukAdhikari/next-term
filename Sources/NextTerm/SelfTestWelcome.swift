import AppKit
import NextTermCore

/// The Welcome window's Return key: "Open…" while no project is chosen, else "Open Project", and never Resume, even with
/// a project's sessions listed, but in the sessions search, where it resumes. A double-click and the buttons are checked
/// with the sessions; the sessions search here too.
extension SelfTest {
    /// `welcome` shows `project`, with its sessions listed. A second Welcome window, never shown, lists nothing and then
    /// the project, as on a new Mac before and after a folder is opened, and then a search that matches nothing.
    static func welcomeReturnKeyChecks(_ welcome: WelcomeWindowController, project: String) {
        let listed: [String] = returnKeyButtons(welcome.window)
        check(listed == ["Open Project"],
              "with a project and its sessions listed, Return on the Welcome window opens the project, and Resume has no key",
              "Return on \(listed)")

        let fresh = WelcomeWindowController()
        defer { fresh.close() }
        fresh.list(projects: [])
        let none: [String] = returnKeyButtons(fresh.window)
        check(none == ["Open…"], "with no recent projects, Return on the Welcome window is Open…", "Return on \(none)")
        fresh.list(projects: [project])
        let one: [String] = returnKeyButtons(fresh.window)
        check(one == ["Open Project"], "once a project is listed, Return moves to Open Project", "Return on \(one)")
        // Open Project is off while no project is chosen: Return never lands on it then.
        fresh.searchProjects("no-such-project-\(getpid())")
        let unmatched: [String] = returnKeyButtons(fresh.window)
        check(unmatched == ["Open…"], "with a search that matches no project, Return on the Welcome window is Open…",
              "Return on \(unmatched)")
        fresh.searchProjects("")
        let cleared: [String] = returnKeyButtons(fresh.window)
        check(cleared == ["Open Project"], "and with the search cleared, Open Project again", "Return on \(cleared)")
    }

    /// The sessions search over `welcome`'s list of `project`'s three sessions (sessionChecks): “Fix the login redirect
    /// loop” (Claude Code, opus), “Rate limits” (Claude Code, in src) and “Tidy the billing tests” (Command Code, opus).
    /// What needs no keyboard runs on a second Welcome window, never shown; the keys need the app in front, and skip
    /// with a note without it. True when they ran: the search then holds “loop fix”, its one session selected, with the
    /// keyboard, for the caller's Return.
    static func welcomeSessionSearchChecks(_ welcome: WelcomeWindowController, project: String) async -> Bool {
        let src = project + "/src"
        let fresh = WelcomeWindowController()
        defer { fresh.close() }
        fresh.list(projects: [project, src])
        fresh.select(project: project)
        guard await wait(10, { fresh.shownSessionTitles.count == 3 }) else {
            check(false, "sessions search: a second Welcome window lists the three sessions", fresh.shownSessionTitles.joined(separator: " | "))
            return false
        }
        let field = fresh.sessionSearchField
        check(field.placeholderString == "Search sessions" && field.accessibilityLabel() == "Search agent sessions",
              "the Welcome window's sessions search says “Search sessions”, and VoiceOver “Search agent sessions”",
              "\(field.placeholderString ?? "none"), \(field.accessibilityLabel() ?? "none")")
        let fix = "Fix the login redirect loop", rate = "Rate limits", tidy = "Tidy the billing tests"
        fresh.sessionQuery = "opus"
        check(fresh.shownSessionTitles == [fix, tidy], "typing in it narrows the sessions, by their model too",
              fresh.shownSessionTitles.joined(separator: " | "))
        check(fresh.sessionFilterLabels == ["All  2", "Claude Code  1", "Command Code  1"], "the filter counts what it matches",
              fresh.sessionFilterLabels.joined(separator: " | "))
        fresh.sessionQuery = "LOOP fix"
        check(fresh.shownSessionTitles == [fix], "every word, in any order and any case", fresh.shownSessionTitles.joined(separator: " | "))
        fresh.sessionQuery = "opus"
        fresh.filterSessions(by: .commandCode)
        check(fresh.shownSessionTitles == [tidy], "within the agent chosen in the filter",
              fresh.shownSessionTitles.joined(separator: " | "))
        fresh.sessionQuery = "rate"
        check(fresh.shownSessionTitles.isEmpty && fresh.sessionFilterLabels == ["All  1", "Claude Code  1", "Command Code  0"],
              "which stays chosen with no match there, its count 0",
              fresh.shownSessionTitles.joined(separator: " | ") + " — " + fresh.sessionFilterLabels.joined(separator: " | "))
        fresh.filterSessions(by: nil)
        let none = "zzq\(getpid())"
        fresh.sessionQuery = none
        check(fresh.shownSessionTitles.isEmpty && fresh.emptyText == "No sessions match “\(none)”.",
              "a search that matches none says so in the list", fresh.emptyText ?? "no text")
        check(fresh.sessionFilterLabels == ["All  0", "Claude Code  0", "Command Code  0"], "and counts none",
              fresh.sessionFilterLabels.joined(separator: " | "))
        fresh.sessionQuery = "rate"
        fresh.searchProjects((project as NSString).lastPathComponent)
        check(fresh.selectedProject == project && fresh.sessionQuery == "rate" && fresh.shownSessionTitles == [rate],
              "typing in the projects search leaves the sessions search alone", "\(fresh.selectedProject ?? "none"), “\(fresh.sessionQuery)”")
        fresh.searchProjects("")
        fresh.select(project: src)
        check(fresh.sessionQuery.isEmpty, "choosing another project empties the sessions search", "“\(fresh.sessionQuery)”")
        fresh.select(project: project)
        check(await wait(5) { fresh.shownSessionTitles.count == 3 } && fresh.sessionQuery.isEmpty,
              "and the first project's sessions all show again", fresh.shownSessionTitles.joined(separator: " | "))

        // The keys, as the keyboard sends them.
        guard let window = welcome.window else { return false }
        guard await bringToFront(window) else {
            note("sessions search: the keys skipped, the app is not frontmost (\(notFrontmost(window)))")
            return false
        }
        let search = welcome.sessionSearchField
        func typing() -> Bool { search.currentEditor() != nil && window.firstResponder === search.currentEditor() }
        window.makeFirstResponder(nil)
        pressAppKey(window, "f", code: 3, flags: .command)
        check(typing(), "⌘F on the Welcome window goes to the sessions search", "\(String(describing: window.firstResponder))")
        guard typing() else { return false }
        typeKeys(window, "opus")
        check(await wait(2) { welcome.shownSessionTitles == [fix, tidy] }, "typed there, it narrows the list",
              "“\(welcome.sessionQuery)”: " + welcome.shownSessionTitles.joined(separator: " | "))
        pressKey(window, "\u{F701}", code: 125)
        check(welcome.selectedSessionTitle == tidy && typing(), "↓ in it selects the next session, and the search keeps the keyboard",
              "\(welcome.selectedSessionTitle ?? "none"), typing \(typing())")
        pressKey(window, "\u{F700}", code: 126)
        check(welcome.selectedSessionTitle == fix && typing(), "↑ the one before", welcome.selectedSessionTitle ?? "none")
        check(await wait(WelcomeWindowController.announceDelay + 2) { welcome.announcedSessionCount == "2 sessions" },
              "once typing settles, VoiceOver hears how many match", welcome.announcedSessionCount ?? "nothing")
        pressKey(window, "\u{1B}", code: 53)
        check(welcome.sessionQuery.isEmpty && welcome.shownSessionTitles.count == 3 && typing(), "Esc empties it, and they all show",
              "“\(welcome.sessionQuery)”, \(welcome.shownSessionTitles.count) shown")
        pressKey(window, "\u{1B}", code: 53)
        check(window.isVisible && welcome.selectedProject == project && welcome.shownSessionTitles.count == 3,
              "a second Esc leaves the window and its list as they were")
        window.makeFirstResponder(search)
        typeKeys(window, "zzq")
        check(await wait(2) { welcome.emptyText == "No sessions match “zzq”." }, "typed with no match, the list says so", welcome.emptyText ?? "no text")
        pressAppKey(window, "\r", code: 36)
        await pause(0.5)
        check(window.isKeyWindow && typing(), "Return there with nothing to resume does nothing: not Open Project",
              notFrontmost(window))
        pressKey(window, "\u{1B}", code: 53)
        typeKeys(window, "loop fix")
        check(await wait(2) { welcome.shownSessionTitles == [fix] && welcome.selectedSessionTitle == fix } && typing(),
              "typed again, the one it matches is selected, ready for Return", welcome.shownSessionTitles.joined(separator: " | "))
        return typing() && welcome.selectedSessionTitle == fix
    }

    /// The titles of the buttons in `window` that Return presses: one at most.
    private static func returnKeyButtons(_ window: NSWindow?) -> [String] {
        guard let content = window?.contentView else { return [] }
        var found: [String] = []
        var views: [NSView] = [content]
        while let view = views.popLast() {
            if let button = view as? NSButton, button.keyEquivalent == "\r" { found.append(button.title) }
            views.append(contentsOf: view.subviews)
        }
        return found
    }
}
