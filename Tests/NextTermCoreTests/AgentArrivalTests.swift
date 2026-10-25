import Foundation
import Testing
@testable import NextTermCore

/// What an agent's tab or window does as it opens over MCP: forward, never over what the user is doing.
@Suite struct AgentArrivalTests {
    func plan(_ mode: AgentArrival.Mode = .focus, explicit: Bool = false, login: Bool = false, hasTab: Bool = true,
              usersWindow: Bool = false, appActive: Bool = true, onActiveSpace: Bool = true, sheetUp: Bool = false,
              modalUp: Bool = false, sinceKey: TimeInterval = 60, waited: TimeInterval = 0) -> AgentArrival.Plan {
        AgentArrival.plan(mode: mode, explicit: explicit, login: login, hasTab: hasTab, usersWindow: usersWindow, appActive: appActive,
                          onActiveSpace: onActiveSpace, sheetUp: sheetUp, modalUp: modalUp, sinceKey: sinceKey, waited: waited)
    }

    @Test func anotherWindowComesForwardAsTheModeSays() {
        #expect(plan(.focus) == .init(select: true, raise: .makeKey))
        #expect(plan(.show) == .init(select: true, raise: .orderFront))
        #expect(plan(.off) == .init(select: false, raise: .none))
        // An agent asking to show it, or ssh asking for a password: forward even when off.
        #expect(plan(.off, explicit: true) == .init(select: true, raise: .orderFront))
        #expect(plan(.off, login: true).raise == .orderFront)
        #expect(plan(hasTab: false) == .init(select: false, raise: .makeKey)) // open_project, a pane beside the user's
    }

    @Test func theUsersOwnWindowKeepsTheirTabInFront() {
        let own = plan(usersWindow: true)
        #expect(!own.select && own.raise == .none && own.note?.contains("behind their tab") == true)
        // ssh asking for a password is the one tab they must see.
        let login = plan(login: true, usersWindow: true)
        #expect(login.select && login.raise == .none && login.note == nil)
    }

    @Test func typingHoldsTheWindowBackThenItComesWithoutTheKeyboard() {
        let typing = plan(sinceKey: 0.2)
        #expect(typing.select && typing.raise == .none && typing.again == AgentArrival.typingQuiet - 0.2)
        #expect(plan(sinceKey: 1.4).again == AgentArrival.tick) // never sooner than a tick
        #expect(plan(sinceKey: 0.2, waited: AgentArrival.typingPatience) == .init(select: true, raise: .orderFront))
        #expect(plan(sinceKey: AgentArrival.typingQuiet).raise == .makeKey)
    }

    @Test func neverOverAnotherAppASpaceAnAlertOrASheet() {
        #expect(plan(appActive: false) == .init(select: true, raise: .attention))
        let space = plan(onActiveSpace: false)
        #expect(space.raise == .none && space.note?.contains("another Space") == true)
        #expect(plan(appActive: false, onActiveSpace: false).raise == .attention)
        #expect(plan(modalUp: true) == .init(select: false, raise: .none, again: AgentArrival.tick))
        #expect(plan(sheetUp: true) == .init(select: false, raise: .makeKey))
    }
}
