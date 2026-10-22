import Foundation
import Testing
@testable import NextTermCore

/// The gate every task link passes before it opens: exactly the app links and tracker pages the renderers build, with
/// only their own parameters, each once; anything else is refused.
@Suite struct TaskLinkTests {
    func kind(_ text: String) -> TaskLink.Kind? {
        guard let url = URL(string: text) else { return nil }
        return TaskLink.check(url)
    }

    func link(_ destination: TaskDestination) throws -> URL {
        let payload = TaskPayload.render(TaskPayloadTests.draft, to: destination, project: "web",
                                         today: TaskPayloadTests.today, mask: { $0 })
        guard case .link(let url) = try #require(payload).form else { throw TaskPayloadTests.Unexpected() }
        return url
    }

    @Test func everyRenderedLinkPassesWithItsKind() throws {
        let expected: [(TaskDestination, TaskLink.Kind)] = [
            (.things(list: "Work"), .things), (.things(list: nil), .things), (.todoist, .todoist),
            (.omnifocus, .omnifocus), (.github(owner: "example-org", repo: "web.app"), .github),
            (.gitlab(path: "group/sub/project"), .gitlab), (.linear(team: "ENG"), .linear), (.linear(team: nil), .linear),
            (.trello, .trello), (.azureBoards(org: "Example Org", project: "Web App", type: "User Story"), .azureBoards),
        ]
        for (destination, kind) in expected {
            #expect(TaskLink.check(try link(destination)) == kind)
        }
        // A title full of link syntax still passes: every value is encoded.
        let tricky = TaskDraft(title: "a&title=b #c ?d=e /../f + g", steps: [])
        let payload = TaskPayload.render(tricky, to: .github(owner: "o", repo: "r"), project: nil,
                                         today: TaskPayloadTests.today, mask: { $0 })
        guard case .link(let url) = try #require(payload).form else { throw TaskPayloadTests.Unexpected() }
        #expect(TaskLink.check(url) == .github)
        #expect(kind("https://linear.new/?title=a") == .linear)
    }

    @Test func thingsTakesOnlyAddWithItsOwnParameters() {
        #expect(kind("things:///add?title=a&notes=b&when=today&list=Work&checklist-items=c") == .things)
        #expect(kind("things:///update?id=x") == nil)
        #expect(kind("things:///json?data=%5B%5D") == nil)
        #expect(kind("things:///add?title=a&auth-token=x") == nil)
        #expect(kind("things:///add?title=a&reveal=true") == nil)
        #expect(kind("things:///add?title=a&x-success=other%3A%2F%2F") == nil)
        #expect(kind("things:///add") == nil)
        #expect(kind("things://add?title=a") == nil)
        #expect(kind("todoist://openquickadd?content=a&description=b") == .todoist)
        #expect(kind("todoist://openquickadd?content=a&project_id=1") == nil)
        #expect(kind("todoist://addtask?content=a") == nil)
        #expect(kind("omnifocus:///add?name=a&note=b") == .omnifocus)
        #expect(kind("omnifocus:///add?name=a&autosave=true") == nil)
        #expect(kind("omnifocus:///paste?content=a") == nil)
    }

    @Test func pagesOnlyOnTheirOwnHostsWithNothingExtra() {
        #expect(kind("https://github.com.evil.example/o/r/issues/new?title=a") == nil)
        #expect(kind("https://evil.example/github.com/o/r/issues/new?title=a") == nil)
        #expect(kind("http://github.com/o/r/issues/new?title=a") == nil)
        #expect(kind("https://u:p@github.com/o/r/issues/new?title=a") == nil)
        #expect(kind("https://u@github.com/o/r/issues/new?title=a") == nil)
        #expect(kind("https://github.com:444/o/r/issues/new?title=a") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a#frag") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a#") == nil)
    }

    @Test func pagesOnlyAtTheirOwnPaths() {
        #expect(kind("https://github.com/o/r/settings?title=a") == nil)
        #expect(kind("https://github.com/o/r/issues/new/extra?title=a") == nil)
        #expect(kind("https://github.com/o/../issues/new?title=a") == nil)
        #expect(kind("https://github.com/o/%2E%2E/issues/new?title=a") == nil)
        #expect(kind("https://github.com//r/issues/new?title=a") == nil)
        #expect(kind("https://gitlab.com/g/p/-/issues/new?issue%5Btitle%5D=a") == nil)
        #expect(kind("https://gitlab.com/p/-/work_items/new?issue%5Btitle%5D=a") == nil)
        #expect(kind("https://gitlab.com/g/p/-/work_items/new?issue%5Btitle%5D=a&issue%5Bassignee_ids%5D=1") == nil)
        #expect(kind("https://linear.app/team/ENG/new?title=a&assignee=me") == nil)
        #expect(kind("https://linear.app/settings/new?title=a") == nil)
        #expect(kind("https://linear.new/x?title=a") == nil)
        #expect(kind("https://trello.com/add-card?name=a&idList=1") == nil)
        #expect(kind("https://dev.azure.com/o/p/_workItems/edit/1?%5BSystem.Title%5D=a") == nil)
    }

    @Test func otherSchemesAreRefused() {
        #expect(kind("x-apple-reminderkit://x") == nil)
        #expect(kind("shortcuts://run-shortcut?name=a") == nil)
        #expect(kind("file:///tmp/a") == nil)
        #expect(kind("javascript:alert(1)") == nil)
        #expect(kind("THINGS:///add?title=a") == nil)
    }

    @Test func aNameRepeatedOrBentIsRefused() {
        #expect(kind("https://github.com/o/r/issues/new?title=a&title=b") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a&%74itle=b") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a=b") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a;body=b") == nil)
        #expect(kind("https://github.com/o/r/issues/new?title=a&&body=b") == nil)
        // URL(string:) encodes a stray `%` itself, so a broken escape is tried on the query as written.
        #expect(!TaskLink.takes("title=%ZZ", ["title"]) && !TaskLink.takes("%ZZ=a", ["title"]))
        #expect(TaskLink.takes("title=%25ZZ", ["title"]))
        #expect(kind("https://github.com/o/r/issues/new?body=b") == nil)
    }

    @Test func vendorPrefixesMatchOnlyTheVendor() {
        #expect(TaskLink.vendorPrefix(for: .things) == "com.culturedcode.")
        #expect(TaskLink.vendorPrefix(for: .todoist) == "com.todoist.")
        #expect(TaskLink.vendorPrefix(for: .omnifocus) == "com.omnigroup.OmniFocus")
        #expect(TaskLink.vendorPrefix(for: .github) == nil)
        #expect(TaskLink.isVendor("com.culturedcode.ThingsMac", for: .things))
        #expect(!TaskLink.isVendor("com.example.culturedcode", for: .things))
        #expect(!TaskLink.isVendor("com.culturedcode", for: .things))
        #expect(TaskLink.isVendor("com.omnigroup.OmniFocus4", for: .omnifocus))
        #expect(!TaskLink.isVendor("com.todoist.mac", for: .things))
        #expect(!TaskLink.isVendor("com.apple.Safari", for: .github))
    }

    @Test func eachAppHasItsProbeAndWindow() {
        #expect(TaskLink.Kind.things.probe?.absoluteString == "things:///")
        #expect(TaskLink.Kind.todoist.probe?.absoluteString == "todoist://")
        #expect(TaskLink.Kind.omnifocus.probe?.absoluteString == "omnifocus:///")
        #expect(TaskLink.Kind.github.probe == nil)
        #expect(TaskLink.Kind.things.isApp && !TaskLink.Kind.trello.isApp)
        // Things saves without a window; a Quick Add waits for the user's own Add, so it comes to the front.
        #expect(!TaskLink.Kind.things.activates && TaskLink.Kind.todoist.activates && TaskLink.Kind.omnifocus.activates)
        #expect(TaskLink.Kind.things.name == "Things" && TaskLink.Kind.azureBoards.name == "Azure Boards")
    }

    @Test func theNotesShownAreRemembered() throws {
        let (defaults, name) = try TestDefaults.make("tasks-notes")
        defer { TestDefaults.remove(defaults, name) }
        #expect(TaskSettings(defaults: defaults).notesShown.isEmpty)
        #expect(TaskSettings.Key.all.contains(TaskSettings.Key.notesShown))
        defaults.set([TaskSettings.Note.thingsOpened.rawValue, "unknown"], forKey: TaskSettings.Key.notesShown)
        #expect(TaskSettings(defaults: defaults).notesShown == [.thingsOpened])
        TaskSettings.markShown(.thingsEnable, in: defaults)
        TaskSettings.markShown(.thingsEnable, in: defaults)
        #expect(defaults.stringArray(forKey: TaskSettings.Key.notesShown) == ["things-opened", "unknown", "things-enable"])
        #expect(TaskSettings(defaults: defaults).notesShown == [.thingsOpened, .thingsEnable])
    }
}
