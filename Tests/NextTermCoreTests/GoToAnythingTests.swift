import Foundation
import Testing
@testable import NextTermCore

/// Go to Anything (plan 034): this window's tabs first, then the others', then closed projects; Clear Terminal leads;
/// a search matches a tab's name, its window, folder and program.
@Suite struct GoToAnythingTests {
    private let here = GoToAnything.Window(id: 1, name: "xcloud-sessions", tabs: [
        .init(id: "a", title: "claude", folder: "xcloud-sessions", program: "claude", state: "working"),
        .init(id: "b", title: "Coding Sessions connectors", folder: "xcloud-sessions", program: nil, state: nil),
    ])
    private let other = GoToAnything.Window(id: 2, name: "Agents", tabs: [
        .init(id: "c", title: "npm run dev", folder: "Agents/web", program: "npm run dev", state: "done"),
    ])
    private let closed = [GoToAnything.Project(path: "/Users/me/Code/next-term", name: "next-term"),
                          GoToAnything.Project(path: "/Users/me/Code/Agents", name: "Agents")]

    @Test func thisWindowsTabsComeFirstThenTheOthersThenClosedProjects() {
        let items = GoToAnything.items(current: here, others: [other], closed: closed, clearsTerminal: true)
        #expect(items.map(\.title) == ["Clear Terminal", "claude", "Coding Sessions connectors", "npm run dev", "next-term"])
        #expect(items[1].target == .tab(window: 1, tab: "a") && items[1].state == "working")
        // A tab named for its program doesn't repeat it; a folder other than the window's shows.
        #expect(items[1].detail == "xcloud-sessions")
        #expect(items[3].detail == "Agents \u{00B7} Agents/web")
        // An open project isn't listed again as closed.
        #expect(!items.contains { $0.target == .project("/Users/me/Code/Agents") })
        #expect(GoToAnything.initialSelection(items) == 0)
    }

    @Test func clearTerminalOnlyWhereThereIsATerminal() {
        let noClear = GoToAnything.items(current: here, others: [], closed: [], clearsTerminal: false)
        #expect(noClear.first?.title == "claude")
        let empty = GoToAnything.Window(id: 3, name: "notes", tabs: [])
        #expect(GoToAnything.items(current: empty, others: [], closed: [], clearsTerminal: true).isEmpty)
        #expect(GoToAnything.initialSelection([]) == nil)
    }

    @Test func aSearchFindsATabByItsNameWindowOrProgram() {
        let items = GoToAnything.items(current: here, others: [other], closed: closed, clearsTerminal: true)
        #expect(GoToAnything.filter(items, query: "connectors").first?.title == "Coding Sessions connectors")
        #expect(GoToAnything.filter(items, query: "csc").first?.title == "Coding Sessions connectors")
        #expect(GoToAnything.filter(items, query: "dev").first?.title == "npm run dev")
        #expect(GoToAnything.filter(items, query: "nxt").first?.title == "next-term")
        #expect(GoToAnything.filter(items, query: "clear").first?.title == "Clear Terminal")
        #expect(GoToAnything.filter(items, query: "zzqq").isEmpty)
        #expect(GoToAnything.filter(items, query: "  ") == items)
    }
}
