import Foundation
import Testing
@testable import NextTermCore

@Suite struct TerminalTabsSettingTests {
    @Test func aStoredChoiceReadsBackAndAnythingElseIsTheTop() {
        #expect(TerminalTabsSetting(stored: "top") == .top)
        #expect(TerminalTabsSetting(stored: "left") == .left)
        #expect(TerminalTabsSetting(stored: "right") == .right)
        // Nothing stored, or a value no version wrote: the tabs stay in the bar.
        for stored in [nil, "", "LEFT", "Right", "side", "bottom", " left"] as [String?] {
            #expect(TerminalTabsSetting(stored: stored) == .top, "\(String(describing: stored))")
        }
        #expect(TerminalTabsSetting.key == "terminalTabs")
    }

    @Test func theMenusAndSettingsListTopLeftRight() {
        #expect(TerminalTabsSetting.allCases.map(\.title) == ["Top", "Left", "Right"])
        #expect(TerminalTabsSetting.allCases.map(\.rawValue) == ["top", "left", "right"])
    }

    @Test func leftAndRightAreAListOnThatSide() {
        #expect(TerminalTabsSetting.top.listSide == nil)
        #expect(TerminalTabsSetting.left.listSide == .left)
        #expect(TerminalTabsSetting.right.listSide == .right)
        // Each side of the list is one of the setting's choices, by the same name.
        for side in TabListSide.allCases { #expect(TerminalTabsSetting(stored: side.rawValue).listSide == side) }
    }

    @Test func theApprovalSaysWhereTheTabsGo() {
        #expect(TerminalTabsSetting.left.approvalLine == "Terminal tabs move to a list on the left, in every window.")
        #expect(TerminalTabsSetting.right.approvalLine == "Terminal tabs move to a list on the right, in every window.")
        #expect(TerminalTabsSetting.top.approvalLine == "Terminal tabs move back to the top, in every window.")
    }
}
