import Foundation
import Testing
@testable import NextTermCore

@Suite struct SplitDividerTests {
    @Test func aDividerBesideAHiddenPaneIsHidden() {
        // [ editor | terminal ]: nothing open, the editor is hidden, and so is the line beside it.
        #expect(SplitDivider.isHidden(at: 0, panesHidden: [true, false]))
        // [ terminal | editor ] (terminal on the left or on top): the line at the far edge.
        #expect(SplitDivider.isHidden(at: 0, panesHidden: [false, true]))
        #expect(!SplitDivider.isHidden(at: 0, panesHidden: [false, false]))
        // Three panes: only the dividers touching the hidden one.
        #expect(SplitDivider.isHidden(at: 0, panesHidden: [false, true, false]))
        #expect(SplitDivider.isHidden(at: 1, panesHidden: [false, true, false]))
        #expect(!SplitDivider.isHidden(at: 1, panesHidden: [true, false, false]))
    }

    @Test func noPaneOnOneSideMeansNoDivider() {
        #expect(SplitDivider.isHidden(at: 1, panesHidden: [false, false]))
        #expect(SplitDivider.isHidden(at: -1, panesHidden: [false, false]))
        #expect(SplitDivider.isHidden(at: 0, panesHidden: [false]))
        #expect(SplitDivider.isHidden(at: 0, panesHidden: []))
    }

    @Test func aHiddenDividerCannotBeGrabbedAnywhere() {
        // The user's drag 3 points right of the sidebar landed in this area and opened an empty editor.
        let line = CGRect(x: 0, y: 0, width: 1, height: 720)
        #expect(SplitDivider.grabArea(drawn: line, sideBySide: true, hidden: true) == .zero)
        #expect(SplitDivider.grabArea(drawn: CGRect(x: 0, y: 0, width: 0, height: 720), sideBySide: true, hidden: true).isEmpty)
    }

    @Test func aShownDividerIsGrabbedThreePointsEitherSide() {
        // Side by side: a vertical line, widened left and right only.
        let vertical = SplitDivider.grabArea(drawn: CGRect(x: 500, y: 0, width: 1, height: 720), sideBySide: true, hidden: false)
        #expect(vertical == CGRect(x: 497, y: 0, width: 7, height: 720))
        // Stacked: a horizontal line, widened up and down only.
        let horizontal = SplitDivider.grabArea(drawn: CGRect(x: 0, y: 400, width: 1100, height: 1), sideBySide: false, hidden: false)
        #expect(horizontal == CGRect(x: 0, y: 397, width: 1100, height: 7))
        #expect(SplitDivider.slop == 3)
    }
}
