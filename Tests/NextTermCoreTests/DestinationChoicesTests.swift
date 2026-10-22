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
}
