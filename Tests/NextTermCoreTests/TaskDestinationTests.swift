import Foundation
import Testing
@testable import NextTermCore

/// Where a task goes: one value per destination, saved as JSON in Next Term's settings (never in the repository), as
/// the default and per project, read back only when every field is valid, and resolved project, then default, then
/// the todo folder.
@Suite struct TaskDestinationTests {
    static let every: [TaskDestination] = [
        .todoFolder,
        .reminders(listID: "x-apple-reminder-list-1", listName: "Next Term"),
        .reminders(listID: nil, listName: "Next Term"),
        .things(list: "Work"), .things(list: nil),
        .shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Add to Notes"),
        .todoist, .omnifocus,
        .github(owner: "example-org", repo: "web.app"),
        .gitlab(path: "group/sub/project"),
        .linear(team: "ENG"), .linear(team: nil),
        .trello,
        .azureBoards(org: "Example Org", project: "Web App", type: "User Story"),
        .throughAgent(tracker: "Linear"),
    ]

    /// A fresh defaults domain of the test's own, removed after.
    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "nt-task-destination-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func everyKindRoundTripsThroughJSON() throws {
        for destination in Self.every {
            let json = try #require(TaskDestination.json(destination))
            let read = TaskDestination.read(json)
            #expect(read.destination == destination && read.problem == nil, "\(json)")
            #expect(json.contains("\"kind\":\"\(destination.kind.rawValue)\""), "\(json)")
        }
        // The kind strings are the ones add_task answers with and the posted record keeps.
        let kinds = TaskDestination.Kind.allCases.map(\.rawValue)
        #expect(kinds == ["todo_folder", "reminders", "things", "shortcut", "todoist", "omnifocus", "github", "gitlab",
                          "linear", "trello", "azure_boards", "through_agent"])
        #expect(Set(Self.every.map(\.kind)).count == kinds.count)
    }

    @Test func anUnknownKindIsAProblemNeverAnotherPlace() {
        for json in [#"{"kind":"jira"}"#, #"{"kind":"github"}"#, "not json", #"{"owner":"a"}"#, ""] {
            let read = TaskDestination.read(json)
            #expect(read.destination == nil && read.problem != nil, "\(json)")
        }
        withDefaults { defaults in
            defaults.set(#"{"kind":"things"}"#, forKey: TaskSettings.Key.defaultDestination)
            defaults.set(#"{"/p":{"destination":{"kind":"jira"}}}"#, forKey: TaskSettings.Key.projects)
            let settings = TaskSettings(defaults: defaults)
            #expect(settings.projects["/p"]?.destination == nil && settings.projects["/p"]?.problem != nil)
            #expect(settings.destination(for: "/p") == .things(list: nil))
        }
    }

    @Test func gitHubNamesOutsideTheSetAreRefused() {
        let long = String(repeating: "a", count: 101)
        for (owner, repo) in [("a/b", "r"), ("o", "x?y"), (long, "r"), ("o", long), ("", "r"), ("o", ".."), (".", "r")] {
            #expect(TaskDestination.github(owner: owner, repo: repo).problem != nil, "\(owner) \(repo)")
            let json = #"{"kind":"github","owner":"\#(owner)","repo":"\#(repo)"}"#
            #expect(TaskDestination.read(json).destination == nil, "\(json)")
        }
        #expect(TaskDestination.github(owner: String(repeating: "a", count: 100), repo: "a.b_c-d").problem == nil)
        #expect(TaskDestination.gitlab(path: "a/b/../c").problem != nil)
        #expect(TaskDestination.gitlab(path: Array(repeating: "g", count: 21).joined(separator: "/")).problem != nil)
        #expect(TaskDestination.gitlab(path: Array(repeating: "g", count: 20).joined(separator: "/")).problem == nil)
        #expect(TaskDestination.gitlab(path: "group").problem != nil)
    }

    @Test func aLinearTeamKeyIsLettersAndDigits() {
        #expect(TaskDestination.linear(team: "ENG").problem == nil)
        #expect(TaskDestination.linear(team: "eng2").problem == nil)
        for team in ["eng team", "", "ABCDEFGHIJK", "EN-G"] {
            #expect(TaskDestination.linear(team: team).problem != nil, "\(team)")
        }
    }

    @Test func aTrackerNameIsOneLineOfAtMostFortyCharacters() {
        #expect(TaskDestination.throughAgent(tracker: "Line\nar").problem != nil)
        #expect(TaskDestination.throughAgent(tracker: "Line\rar").problem != nil)
        #expect(TaskDestination.throughAgent(tracker: "").problem != nil)
        #expect(TaskDestination.throughAgent(tracker: String(repeating: "x", count: 41)).problem != nil)
        #expect(TaskDestination.throughAgent(tracker: String(repeating: "x", count: 40)).problem == nil)
        #expect(TaskDestination.read(#"{"kind":"through_agent","tracker":"a\nb"}"#).destination == nil)
        #expect(TaskDestination.azureBoards(org: "o", project: "p", type: "Epic").problem != nil)
        for type in ["Task", "Bug", "User Story", "Issue", "Product Backlog Item"] {
            #expect(TaskDestination.azureBoards(org: "o", project: "p", type: type).problem == nil, "\(type)")
        }
        #expect(TaskDestination.azureBoards(org: "", project: "p", type: "Task").problem != nil)
    }

    @Test func noKeysAtAllMeansTheTodoFolderEverywhere() {
        withDefaults { defaults in
            let settings = TaskSettings(defaults: defaults)
            #expect(settings.defaultDestination == nil && settings.projects.isEmpty)
            #expect(settings.destination(for: "/p") == .todoFolder && settings.destination(for: nil) == .todoFolder)
            #expect(settings.remindersAlarm == false && settings.destinationOffer == .pending)
        }
        #expect(TaskSettings().destination(for: "/p") == .todoFolder)
    }

    @Test func theProjectWinsThenTheDefault() throws {
        try withDefaults { defaults in
            let ownProject = ProjectTasks(destination: .github(owner: "o", repo: "r"), handoffFolder: "notes/handoffs")
            let projects: [String: ProjectTasks] = ["/p": ownProject, "/q": ProjectTasks(handoffFolder: "docs/h")]
            let defaultJSON: String = try #require(TaskDestination.json(.things(list: nil)))
            let projectsJSON: String = try #require(TaskSettings.json(projects: projects))
            defaults.set(defaultJSON, forKey: TaskSettings.Key.defaultDestination)
            defaults.set(projectsJSON, forKey: TaskSettings.Key.projects)
            defaults.set(true, forKey: TaskSettings.Key.remindersAlarm)
            defaults.set(TaskSettings.DestinationOffer.done.rawValue, forKey: TaskSettings.Key.destinationOffer)
            let settings = TaskSettings(defaults: defaults)
            #expect(settings.projects == projects)
            #expect(settings.destination(for: "/p") == .github(owner: "o", repo: "r"))
            #expect(settings.destination(for: "/q") == .things(list: nil))
            #expect(settings.destination(for: "/elsewhere") == .things(list: nil))
            #expect(settings.destination(for: nil) == .things(list: nil))
            #expect(settings.remindersAlarm && settings.destinationOffer == .done)
            // A default that fails its check is a problem shown in Settings; the todo folder is used.
            defaults.set(#"{"kind":"linear","team":"eng team"}"#, forKey: TaskSettings.Key.defaultDestination)
            let bad = TaskSettings(defaults: defaults)
            #expect(bad.defaultDestination == nil && bad.defaultDestinationProblem != nil)
            #expect(bad.destination(for: "/q") == .todoFolder)
            #expect(bad.destination(for: "/p") == .github(owner: "o", repo: "r"))
        }
    }

    @Test func theFourNewKeysAreSavedAndRestoredWithTheRest() {
        for key in ["tasks.defaultDestination", "tasks.projects", "tasks.remindersAlarm", "tasks.destinationOffer"] {
            #expect(TaskSettings.Key.all.contains(key), "\(key)")
        }
        #expect(TaskSettings.Key.all.count == 7)
    }

    @Test func everyWorktreeOfARepositoryHasOneKey() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let linked = repo.base + "/web-wt-login"
        repo.run(["worktree", "add", "-q", "-b", "fix/login", linked])
        let main = canonicalPath(repo.path)
        #expect(TaskSettings.projectKey(linked) == main && TaskSettings.projectKey(main) == main)
        // A bare repository has no main checkout: its worktree keys by its own path.
        let bare = repo.base + "/proj/.bare", worktree = repo.base + "/proj/main"
        #expect(repo.run(["clone", "--bare", "-q", repo.path, bare]) == 0)
        #expect(repo.run(["-C", bare, "worktree", "add", "-q", worktree]) == 0)
        #expect(TaskSettings.projectKey(worktree) == canonicalPath(worktree))
    }
}
