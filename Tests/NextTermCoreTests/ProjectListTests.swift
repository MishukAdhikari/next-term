import Foundation
import Testing
@testable import NextTermCore

struct ProjectListTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func theProjectUsedLastComesFirstWhetherOpenOrNot() {
        let items = ProjectList.build(
            open: [("/a", at(100)), ("/b", at(300))],
            history: [.init(path: "/c", lastUsed: at(400)), .init(path: "/a", lastUsed: at(50)),
                      .init(path: "/d", lastUsed: at(200))],
            recents: ["/e", "/c"])
        #expect(items.map(\.path) == ["/c", "/b", "/d", "/a", "/e"])
        #expect(items.map(\.open) == [false, true, false, true, false])
        #expect(items.last?.lastUsed == nil)
    }

    @Test func anOpenProjectTakesItsNewestWindowOrItsHistory() {
        let items = ProjectList.build(
            open: [("/a", at(100)), ("/a", at(250))],
            history: [.init(path: "/a", lastUsed: at(500))], recents: [])
        #expect(items == [ProjectList.Item(path: "/a", open: true, lastUsed: at(500))])
        let windows = ProjectList.build(open: [("/a", at(100)), ("/a", at(250))], history: [], recents: [])
        #expect(windows.first?.lastUsed == at(250))
    }

    @Test func equalTimesKeepOpenFirstThenTheOrderGiven() {
        let items = ProjectList.build(
            open: [("/b", at(10))], history: [.init(path: "/a", lastUsed: at(10))], recents: [])
        #expect(items.map(\.path) == ["/b", "/a"])
    }
}
