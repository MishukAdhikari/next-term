import Foundation
import Testing
@testable import NextTermCore

/// The room the system tab bar takes at a window's top, as macOS 26.5 reports it for a 400-point window: the title row
/// (32) alone without a tab bar, the title row and the tab bar (68) with one.
@Suite struct TitleBarCoverTests {
    @Test func noTabBarTakesNothingAsOurBarsShareTheTitleRow() {
        #expect(TitleBarCover.top(contentHeight: 400, layoutMaxY: 368, tabBarShown: false) == 0)
    }

    @Test func aTabBarTakesTheTitleRowAndItselfInWholePoints() {
        #expect(TitleBarCover.top(contentHeight: 400, layoutMaxY: 332, tabBarShown: true) == 68)
        #expect(TitleBarCover.top(contentHeight: 400, layoutMaxY: 331.5, tabBarShown: true) == 69)
        // In full screen, or a window not laid out yet, it never goes below 0.
        #expect(TitleBarCover.top(contentHeight: 400, layoutMaxY: 420, tabBarShown: true) == 0)
        #expect(TitleBarCover.top(contentHeight: 0, layoutMaxY: 0, tabBarShown: true) == 0)
    }
}
