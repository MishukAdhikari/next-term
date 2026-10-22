import Foundation
import Testing
@testable import NextTermCore

/// Settings › Tasks' details for one destination: the fields as typed, the destination they build, why it can't be
/// saved, Revert, and the repository filled from the project's remote.
@Suite struct DestinationFormTests {
    @Test func gitHubWithOwnerAndRepoBuildsIt() {
        var form = DestinationForm(kind: .github, saved: nil)
        form.owner = "example-org"
        form.repo = " web "
        #expect(form.destination == .github(owner: "example-org", repo: "web"))
        #expect(form.problem == nil && form.canSave)
    }

    @Test func anEmptyOrSlashedOwnerKeepsSaveOff() {
        var form = DestinationForm(kind: .github, saved: nil)
        form.repo = "web"
        #expect(form.problem == TaskDestination.github(owner: "", repo: "web").problem)
        #expect(form.problem != nil && !form.canSave)
        form.owner = "a/b"
        #expect(form.problem != nil && !form.canSave)
    }

    @Test func gitLabLinearAndTeams() {
        var gitlab = DestinationForm(kind: .gitlab, saved: nil)
        gitlab.gitlabPath = "group/sub/proj"
        #expect(gitlab.destination == .gitlab(path: "group/sub/proj") && gitlab.canSave)
        var linear = DestinationForm(kind: .linear, saved: nil)
        #expect(linear.destination == .linear(team: nil) && linear.problem == nil)
        linear.team = "eng team"
        #expect(linear.problem != nil && !linear.canSave)
        linear.team = "ENG"
        #expect(linear.destination == .linear(team: "ENG"))
    }

    @Test func azureTakesTaskByDefaultAndATrackerIsOneLine() {
        var azure = DestinationForm(kind: .azureBoards, saved: nil)
        azure.org = "example-org"
        azure.project = "Web"
        #expect(azure.destination == .azureBoards(org: "example-org", project: "Web", type: "Task"))
        #expect(azure.canSave)
        var agent = DestinationForm(kind: .throughAgent, saved: nil)
        agent.tracker = "Jira\nrm -rf"
        #expect(agent.problem != nil && !agent.canSave)
        agent.tracker = "Jira"
        #expect(agent.destination == .throughAgent(tracker: "Jira") && agent.canSave)
    }

    @Test func revertGivesBackTheSavedFieldsAndNoChangeKeepsSaveOff() {
        let saved = TaskDestination.azureBoards(org: "example-org", project: "Web", type: "Bug")
        var form = DestinationForm(saved: saved)
        #expect(form.kind == .azureBoards && form.org == "example-org" && form.azureType == "Bug")
        #expect(form.problem == nil && !form.canSave)
        form.project = "Other"
        form.azureType = "Task"
        #expect(form.canSave)
        form.revert()
        #expect(form == DestinationForm(saved: saved) && !form.canSave)
        // Another kind chosen, then Revert: back on the saved kind.
        var other = DestinationForm(kind: .github, saved: saved)
        other.owner = "o"
        other.revert()
        #expect(other.kind == .azureBoards && other.destination == saved)
    }

    @Test func thingsRemindersAndShortcutsFromTheirFields() {
        var things = DestinationForm(kind: .things, saved: nil)
        #expect(things.destination == .things(list: nil))
        things.thingsList = "Work"
        #expect(things.destination == .things(list: "Work"))
        let reminders = DestinationForm(kind: .reminders, saved: nil)
        #expect(reminders.destination == .reminders(listID: nil, listName: "Next Term"))
        let id = "0F3C9A2E-1B7D-4E55-9C3A-2D8E6F1A4B70"
        let shortcut = DestinationForm(saved: .shortcut(id: id, name: "Add to Inbox"))
        #expect(shortcut.shortcutID == id && shortcut.shortcutName == "Add to Inbox" && !shortcut.canSave)
        #expect(DestinationForm(kind: .shortcut, saved: nil).problem != nil)
    }

    @Test func kindsWithNoDetailsSaveAtOnce() {
        #expect(DestinationForm.savesAtOnce(.trello) && DestinationForm.savesAtOnce(.todoFolder))
        #expect(DestinationForm.savesAtOnce(.linear) && !DestinationForm.savesAtOnce(.github))
        #expect(DestinationForm.atOnce(.linear, saved: .linear(team: "ENG")) == .linear(team: "ENG"))
        #expect(DestinationForm.atOnce(.linear, saved: .trello) == .linear(team: nil))
        #expect(DestinationForm.atOnce(.github, saved: nil) == nil)
    }

    @Test func theProjectsRemoteFillsTheRepository() {
        var form = DestinationForm(kind: .github, saved: nil)
        #expect(form.useRemote("git@github.com:o/r.git") == nil)
        #expect(form.owner == "o" && form.repo == "r")
        var tokened = DestinationForm(kind: .github, saved: nil)
        #expect(tokened.useRemote("https://user:tok@github.com/o/r.git") == nil)
        #expect(tokened.owner == "o" && tokened.repo == "r")
        #expect(!String(describing: tokened).contains("tok") && !String(describing: tokened).contains("user"))
        var selfManaged = DestinationForm(kind: .github, saved: nil)
        #expect(selfManaged.useRemote("git@git.example.com:o/r.git") == "This project’s remote isn’t on github.com.")
        #expect(selfManaged.owner.isEmpty && selfManaged.repo.isEmpty)
        var gitlab = DestinationForm(kind: .gitlab, saved: nil)
        #expect(gitlab.useRemote("git@github.com:o/r.git") == "This project’s remote isn’t on gitlab.com.")
        #expect(gitlab.useRemote("https://oauth2:glpat-EXAMPLE@gitlab.com/group/sub/proj.git") == nil)
        #expect(gitlab.gitlabPath == "group/sub/proj")
        var none = DestinationForm(kind: .github, saved: nil)
        #expect(none.useRemote(nil) == "This project has no remote named origin.")
    }

    @Test func eachKindHasANoteOrFields() {
        #expect(DestinationForm.note(.trello) == "Trello asks for the board on its own page; Next Term sends the card’s name.")
        #expect(DestinationForm.note(.things) == "Things gets the title, notes and the day.")
        for kind in [TaskDestination.Kind.todoFolder, .todoist, .omnifocus] {
            #expect(DestinationForm.note(kind) != nil)
        }
        #expect(DestinationForm.note(.github) == nil)
    }

    @Test func thePopupsListEveryKindInOrderWithTheHeldRowsGreyed() {
        var facts = DestinationFacts()
        facts.installed = [.todoist]
        let rows = DestinationForm.rows(facts: facts)
        let kinds = rows.compactMap(\.kind)
        #expect(kinds == DestinationChoices.order)
        let things = rows.first { $0.kind == .things }
        #expect(things?.title == "Things · not installed" && things?.enabled == false && things?.tip != nil)
        #expect(rows.first { $0.kind == .todoist }?.enabled == true)
        #expect(rows.first { $0.kind == .github }?.title == "GitHub" && rows.first { $0.kind == .github }?.enabled == true)
        let held = rows.filter { $0.kind == nil }
        #expect(held.count == 2 && held.allSatisfy { !$0.enabled && $0.tip != nil })
        let tickTick = rows.firstIndex { $0.title.hasPrefix("TickTick") }
        let omniFocus = rows.firstIndex { $0.kind == .omnifocus }
        #expect(tickTick != nil && tickTick == omniFocus.map { $0 + 1 })
    }
}
