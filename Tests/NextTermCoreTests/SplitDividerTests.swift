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

    private func pane(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, hidden: Bool = false) -> SplitDivider.Pane {
        SplitDivider.Pane(frame: CGRect(x: x, y: y, width: width, height: height), hidden: hidden)
    }

    @Test func aLineRunsBetweenTwoPanesThatShow() {
        // [ editor | terminal ] in a work area 1648 wide: the line in the point between them, all the way down.
        let sideBySide = SplitDivider.lines(between: [pane(0, 0, 525, 1050), pane(526, 0, 1122, 1050)], sideBySide: true, thickness: 1)
        #expect(sideBySide == [CGRect(x: 525, y: 0, width: 1, height: 1050)])
        // Editor over terminal (y down, as a split view counts): across, in the point between them.
        let stacked = SplitDivider.lines(between: [pane(0, 0, 1100, 224), pane(0, 225, 1100, 475)], sideBySide: false, thickness: 1)
        #expect(stacked == [CGRect(x: 0, y: 224, width: 1100, height: 1)])
        // The terminal first (on the left), and a terminal folded to its rail: still two panes, still a line.
        #expect(SplitDivider.lines(between: [pane(0, 0, 300, 700), pane(301, 0, 799, 700)], sideBySide: true, thickness: 1)
                    == [CGRect(x: 300, y: 0, width: 1, height: 700)])
        #expect(SplitDivider.lines(between: [pane(0, 0, 1069, 700), pane(1070, 0, 30, 700)], sideBySide: true, thickness: 1)
                    == [CGRect(x: 1069, y: 0, width: 1, height: 700)])
    }

    @Test func noLineBesideAHiddenPane() {
        // The reported line: the last file closed, the editor hidden. Before the split is laid out again the
        // panes are where they were, then the terminal has the whole area: no line either time.
        #expect(SplitDivider.lines(between: [pane(0, 0, 525, 1050, hidden: true), pane(526, 0, 1122, 1050)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 525, 1050, hidden: true), pane(0, 0, 1648, 1050)], sideBySide: true, thickness: 1).isEmpty)
        // The terminal at the bottom, on the left, on top: the same.
        #expect(SplitDivider.lines(between: [pane(0, 0, 1100, 224, hidden: true), pane(0, 225, 1100, 475)], sideBySide: false, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 1100, 700), pane(1101, 0, 500, 700, hidden: true)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 1100, 475), pane(0, 476, 1100, 224, hidden: true)], sideBySide: false, thickness: 1).isEmpty)
        // A hidden sidebar: no line at its old edge, across the work area's tab bar.
        #expect(SplitDivider.lines(between: [pane(0, 0, 263, 1080, hidden: true), pane(0, 0, 1912, 1080)], sideBySide: true, thickness: 1).isEmpty)
        // Shown again, before the split makes room for it: it still overlaps the other pane, so no line yet.
        #expect(SplitDivider.lines(between: [pane(0, 0, 525, 1050), pane(1, 0, 1647, 1050)], sideBySide: true, thickness: 1).isEmpty)
    }

    @Test func noLineBesideAPaneSqueezedToNothing() {
        #expect(SplitDivider.lines(between: [pane(0, 0, 0, 1050), pane(1, 0, 1647, 1050)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 1100, 0), pane(0, 1, 1100, 699)], sideBySide: false, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 1648, 1050)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [], sideBySide: true, thickness: 1).isEmpty)
    }

    @Test func aLineNeverCoversAPane() {
        // Touching, overlapping, or with more room between them than a divider's (a hidden pane's left-over
        // room): no line, rather than one over either pane or beside nothing.
        #expect(SplitDivider.lines(between: [pane(0, 0, 525, 700), pane(525, 0, 500, 700)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 525, 700), pane(400, 0, 600, 700)], sideBySide: true, thickness: 1).isEmpty)
        #expect(SplitDivider.lines(between: [pane(0, 0, 100, 700), pane(101, 0, 100, 700, hidden: true), pane(202, 0, 100, 700)],
                                   sideBySide: true, thickness: 1).isEmpty)
        // Only as far across as both panes reach.
        #expect(SplitDivider.lines(between: [pane(0, 0, 100, 700), pane(101, 20, 100, 600)], sideBySide: true, thickness: 1)
                    == [CGRect(x: 100, y: 20, width: 1, height: 600)])
        for line in SplitDivider.lines(between: [pane(0, 0, 525, 1050), pane(526, 0, 1122, 1050)], sideBySide: true, thickness: 1) {
            #expect(!line.intersects(CGRect(x: 0, y: 0, width: 525, height: 1050)) && !line.intersects(CGRect(x: 526, y: 0, width: 1122, height: 1050)))
        }
    }

    @Test func aTabsPanesHaveALineBetweenEachTwo() {
        // Three panes side by side, in any order the split lists them: two lines.
        let panes = [pane(0, 0, 300, 700), pane(602, 0, 298, 700), pane(301, 0, 300, 700)]
        #expect(SplitDivider.lines(between: panes, sideBySide: true, thickness: 1)
                    == [CGRect(x: 300, y: 0, width: 1, height: 700), CGRect(x: 601, y: 0, width: 1, height: 700)])
        // A thicker divider is filled the same way.
        #expect(SplitDivider.lines(between: [pane(0, 0, 300, 700), pane(302, 0, 300, 700)], sideBySide: true, thickness: 2)
                    == [CGRect(x: 300, y: 0, width: 2, height: 700)])
    }
}
