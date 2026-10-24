import Foundation
import Testing
@testable import NextTermCore

/// The rows of the sheet's Destination popup (and Send Tasks To ▸): the current destination first, then one row per
/// kind in a fixed order, with the details it has, or a row that opens Settings for the details it lacks.
@Suite struct DestinationChoicesTests {
    static func facts(_ change: (inout DestinationFacts) -> Void = { _ in }) -> DestinationFacts {
        var facts = DestinationFacts()
        facts.installed = [.things, .todoist, .omnifocus]
        change(&facts)
        return facts
    }

    @Test func theOrderAndTheFirstRow() {
        let rows = DestinationChoices.rows(current: .todoFolder, default: nil, inProject: true, facts: Self.facts())
        #expect(rows.map(\.title) == ["Todo Folder (this project’s)", "Reminders", "Things", "Run a Shortcut…", "Todoist",
                                      "OmniFocus", "GitHub Issues…", "GitLab Issues…", "Linear", "Trello", "Azure Boards…",
                                      "Through Your Agent…"])
        #expect(rows.first?.action == .use(.todoFolder))
        #expect(rows[1].action == .use(.reminders(listID: nil, listName: "Next Term")))
        #expect(rows[6].action == .setUp(.github) && rows[3].action == .setUp(.shortcut))
        #expect(rows[8].action == .use(.linear(team: nil)))
        let outside = DestinationChoices.rows(current: .todoFolder, default: nil, inProject: false, facts: Self.facts())
        #expect(outside.first?.title == "Todo Folder (default)")
    }

    @Test func detailsComeFromTheCurrentOrTheDefault() {
        let github = TaskDestination.github(owner: "o", repo: "r")
        let rows = DestinationChoices.rows(current: .linear(team: "ENG"), default: github, inProject: true, facts: Self.facts())
        #expect(rows.first?.title == "Linear ENG (this project’s)")
        #expect(rows.contains { $0.title == "GitHub o/r" && $0.action == .use(github) })
        #expect(!rows.dropFirst().contains { $0.action == .use(.linear(team: "ENG")) })
        #expect(rows.filter { $0.title.hasPrefix("Linear") }.count == 1)
        let shortcut = TaskDestination.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Add to Inbox")
        let named = DestinationChoices.rows(current: .todoFolder, default: shortcut, inProject: true, facts: Self.facts())
        #expect(named.contains { $0.title == "Run “Add to Inbox”" && $0.action == .use(shortcut) })
        let agent = DestinationChoices.rows(current: .throughAgent(tracker: "Jira"), default: nil, inProject: false,
                                            facts: Self.facts())
        #expect(agent.first?.title == "Through Your Agent (Jira) (default)")
    }

    @Test func appsAndPermissions() {
        let rows = DestinationChoices.rows(current: .todoFolder, default: nil, inProject: true, facts: Self.facts {
            $0.installed = [.todoist]
            $0.reminders = .blocked(RemindersAccess.deniedLine, settings: true)
        })
        let things = rows.first { $0.title.hasPrefix("Things") }
        #expect(things?.title == "Things · not installed" && things?.enabled == false)
        #expect(rows.first { $0.title.hasPrefix("OmniFocus") }?.enabled == false)
        #expect(rows.first { $0.title.hasPrefix("Todoist") }?.enabled == true)
        let reminders = rows.first { $0.title.hasPrefix("Reminders") }
        #expect(reminders?.title == "Reminders · not allowed in Privacy & Security" && reminders?.enabled == false)
        let current = DestinationChoices.rows(current: .things(list: nil), default: nil, inProject: true,
                                              facts: Self.facts { $0.installed = [] })
        #expect(current.first?.title == "Things (this project’s)" && current.first?.enabled == true)
    }

    @Test func namesAreMasked() {
        let mask = { (text: String) in text.replacingOccurrences(of: "sk-made-up", with: "•••") }
        let rows = DestinationChoices.rows(current: .throughAgent(tracker: "sk-made-up"), default: nil, inProject: true,
                                           facts: Self.facts(), mask: mask)
        #expect(rows.first?.title == "Through Your Agent (•••) (this project’s)")
    }

    // MARK: Send Tasks To ▸

    static let project = DestinationChoices.MenuScope.project(key: "/made/up/next-term", name: "next-term", worktree: false)

    static func settings(own: TaskDestination? = nil, fallback: TaskDestination? = nil) -> TaskSettings {
        var settings = TaskSettings()
        settings.defaultDestination = fallback
        if let own { settings.projects["/made/up/next-term"] = ProjectTasks(destination: own) }
        return settings
    }

    /// Every row after the one naming whose it is, separators left out.
    static func choices(_ rows: [DestinationChoices.MenuRow]) -> [DestinationChoices.MenuRow] {
        rows.dropFirst().filter { $0.action != .separator }
    }

    @Test func menuWithNoSettingsTicksTheTodoFolder() {
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(), facts: Self.facts())
        #expect(rows.first == DestinationChoices.MenuRow(title: "For “next-term”", action: .label))
        let ticked = rows.filter(\.ticked)
        #expect(ticked.map(\.title) == ["Todo Folder (the default)"])
        #expect(ticked.first?.action == .keep)
        #expect(Self.choices(rows).map(\.title) == ["Todo Folder (the default)", "Reminders", "Things", "Run a Shortcut…",
                                                    "Todoist", "OmniFocus",
                                                    "TickTick · held: not checked yet", "GitHub Issues…",
                                                    "GitLab Issues…", "Linear", "Trello", "Azure Boards…",
                                                    "Jira Page · held: Jira 9 and later turn off the prefilled page; "
                                                        + "use Through Your Agent",
                                                    "Through Your Agent…", "Set Up Destinations…"])
        #expect(rows.first { $0.title == "GitHub Issues…" }?.action == .setUp(.github))
        #expect(!rows.contains { $0.action == .useDefault })
        #expect(rows.last?.action == .setUpAll)
        #expect(rows[rows.count - 2].action == .separator)
    }

    @Test func theProjectsOwnOverTheDefault() {
        let github = TaskDestination.github(owner: "o", repo: "r")
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(own: github, fallback: .things(list: nil)),
                                               facts: Self.facts())
        #expect(rows.filter(\.ticked).map(\.title) == ["GitHub o/r"])
        #expect(rows.first { $0.title == "Things" }?.ticked == false)
        let back = rows.first { $0.action == .useDefault }
        #expect(back?.title == "Use the Default (Things)")
        let cleared = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(fallback: .things(list: nil)),
                                                  facts: Self.facts())
        #expect(cleared.filter(\.ticked).map(\.title) == ["Things (the default)"])
        #expect(!cleared.contains { $0.action == .useDefault })
        #expect(cleared.contains { $0.title == "GitHub o/r" && $0.action == .use(github) } == false)
    }

    @Test func theTickedRowSaysItsDetails() {
        let reminders = TaskDestination.reminders(listID: nil, listName: "Next Term")
        let shortcut = TaskDestination.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Add to Inbox")
        let cases: [(TaskDestination, String)] = [(reminders, "Reminders, list “Next Term”"),
                                                  (shortcut, "Run “Add to Inbox”"),
                                                  (.throughAgent(tracker: "Linear"), "Through Your Agent (Linear)")]
        for (own, title) in cases {
            let rows = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(own: own), facts: Self.facts())
            #expect(rows.filter(\.ticked).map(\.title) == [title])
            #expect(rows.filter(\.ticked).first?.action == .use(own))
        }
    }

    @Test func theScopeRow() {
        let worktree = DestinationChoices.MenuScope.project(key: "/made/up/next-term", name: "next-term", worktree: true)
        let rows = DestinationChoices.menuRows(scope: worktree, settings: Self.settings(), facts: Self.facts())
        #expect(rows.first?.title == "For “next-term” and its worktrees")
        let none = DestinationChoices.menuRows(scope: .noProject, settings: Self.settings(fallback: .things(list: nil)),
                                               facts: Self.facts())
        #expect(none.first?.title == "For windows with no project (the default)")
        #expect(none.filter(\.ticked).map(\.title) == ["Things"])
        #expect(!none.contains { $0.action == .useDefault })
    }

    @Test func unavailableAndHeldRowsSayWhy() {
        let facts = Self.facts {
            $0.installed = [.omnifocus]
            $0.reminders = .blocked(RemindersAccess.deniedLine, settings: true)
        }
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(), facts: facts)
        let things = rows.first { $0.title.hasPrefix("Things") }
        #expect(things?.title == "Things · not installed" && things?.enabled == false && things?.tip != nil)
        #expect(rows.first { $0.title.hasPrefix("Todoist") }?.title == "Todoist · not installed")
        let reminders = rows.first { $0.title.hasPrefix("Reminders") }
        #expect(reminders?.title == "Reminders · not allowed in Privacy & Security" && reminders?.enabled == false)
        #expect(rows.first { $0.title.hasPrefix("OmniFocus") }?.enabled == true)
        let held = rows.filter { $0.title.hasPrefix("Jira Page") || $0.title.hasPrefix("TickTick") }
        #expect(held.count == 2 && held.allSatisfy { !$0.enabled && $0.action == .label && $0.tip != nil })
    }

    @Test func aSavedValueThatCantBeUsed() throws {
        let json = #"{"destination":{"kind":"github","owner":"a/b","repo":"r"}}"#
        let own = try JSONDecoder().decode(ProjectTasks.self, from: Data(json.utf8))
        #expect(own.destination == nil && own.problem != nil)
        var settings = TaskSettings()
        settings.projects["/made/up/next-term"] = own
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: settings, facts: Self.facts())
        #expect(rows[1].title == "Saved destination can’t be used: " + (own.problem ?? ""))
        #expect(rows[1].action == .label && !rows[1].enabled)
        #expect(rows.filter(\.ticked).map(\.title) == ["Todo Folder (the default)"])
        var badDefault = TaskSettings()
        badDefault.defaultDestinationProblem = "The saved destination can’t be read."
        let none = DestinationChoices.menuRows(scope: .noProject, settings: badDefault, facts: Self.facts())
        #expect(none[1].title == "Saved destination can’t be used: The saved destination can’t be read.")
    }

    @Test func theTickedDefaultChangesNothing() {
        // Clicking the default's ticked row in a project keeps the project on the default, never pins it there.
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(fallback: .things(list: nil)),
                                               facts: Self.facts())
        let ticked = rows.filter(\.ticked)
        #expect(ticked.map(\.title) == ["Things (the default)"] && ticked.first?.action == .keep)
        #expect(ticked.first?.enabled == true)
        // The default, ticked, that can't be used now: greyed, with why.
        let missing = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(fallback: .things(list: nil)),
                                                  facts: Self.facts { $0.installed = [] })
        let row = missing.first(where: \.ticked)
        #expect(row?.title == "Things (the default) · not installed" && row?.enabled == false && row?.tip != nil)
        // Its own, ticked, saves the same value again; with no project the default's row does too.
        let own = DestinationChoices.menuRows(scope: Self.project, settings: Self.settings(own: .todoist), facts: Self.facts())
        #expect(own.first(where: \.ticked)?.action == .use(.todoist))
        let none = DestinationChoices.menuRows(scope: .noProject, settings: Self.settings(fallback: .todoist),
                                               facts: Self.facts())
        #expect(none.first(where: \.ticked)?.action == .use(.todoist))
    }

    @Test func theCantBeUsedRowIsMaskedOnOneLine() {
        let mask = { (text: String) in text.replacingOccurrences(of: "sk-made-up", with: "•••") }
        var own = ProjectTasks()
        own.problem = "Azure Boards can’t make a work item of type “sk-made-up\nBug\u{202E}x”"
        var settings = TaskSettings()
        settings.projects["/made/up/next-term"] = own
        let rows = DestinationChoices.menuRows(scope: Self.project, settings: settings, facts: Self.facts(), mask: mask)
        #expect(rows[1].title == "Saved destination can’t be used: Azure Boards can’t make a work item of type "
            + "“••• Bug\u{FFFD}x”")
    }

    @Test func menuNamesAreMasked() {
        let mask = { (text: String) in text.replacingOccurrences(of: "sk-made-up", with: "•••") }
        let scope = DestinationChoices.MenuScope.project(key: "/made/up/next-term", name: "sk-made-up", worktree: false)
        let rows = DestinationChoices.menuRows(scope: scope, settings: Self.settings(own: .throughAgent(tracker: "sk-made-up")),
                                               facts: Self.facts(), mask: mask)
        #expect(rows.first?.title == "For “•••”")
        #expect(rows.filter(\.ticked).map(\.title) == ["Through Your Agent (•••)"])
    }
}
