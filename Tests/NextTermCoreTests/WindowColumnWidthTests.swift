import Foundation
import Testing
@testable import NextTermCore

/// The room a window needs for its column, and the two settings every window shares.
@Suite struct WindowColumnWidthTests {
    /// `minimal`: the minimal sidebar the folded column is measured beside; the sidebar as it is unless said.
    private func shown(_ content: CGFloat, sidebar: CGFloat, minimal: CGFloat? = nil, expanded: Bool = false) -> WindowColumnShown {
        WindowColumnWidth.shown(contentWidth: content, sidebarWidth: sidebar, minimalSidebar: minimal ?? sidebar, expanded: expanded)
    }

    @Test func foldedItShowsWhileTheWorkAreaKeeps240() {
        // A 160-point sidebar and its divider, 161: folded needs 161 + 28 + 1 + 240 = 430.
        #expect(shown(430, sidebar: 161) == WindowColumnShown(form: .folded, width: 29, byRoom: false))
        #expect(shown(429, sidebar: 161) == WindowColumnShown(form: .hidden, width: 0, byRoom: true))
        // The window's own minimum, 420, is too narrow beside that sidebar.
        #expect(shown(420, sidebar: 161).form == .hidden)
        // A 300-point sidebar: 570.
        #expect(shown(570, sidebar: 301).form == .folded)
        #expect(shown(569, sidebar: 301).form == .hidden)
    }

    @Test func unfoldedItShowsWhileTheWorkAreaKeeps240AndFoldsFirst() {
        // 161 + 180 + 1 + 240 = 582.
        #expect(shown(582, sidebar: 161, expanded: true) == WindowColumnShown(form: .expanded, width: 181, byRoom: false))
        // Narrower: folded for want of room, the user's choice kept to come back with the room.
        #expect(shown(581, sidebar: 161, expanded: true) == WindowColumnShown(form: .folded, width: 29, byRoom: true))
        #expect(shown(430, sidebar: 161, expanded: true) == WindowColumnShown(form: .folded, width: 29, byRoom: true))
        #expect(shown(429, sidebar: 161, expanded: true) == WindowColumnShown(form: .hidden, width: 0, byRoom: true))
        // A 300-point sidebar: 722.
        #expect(shown(722, sidebar: 301, expanded: true).form == .expanded)
        #expect(shown(721, sidebar: 301, expanded: true).form == .folded)
    }

    @Test func unfoldedItIsMeasuredBesideTheSidebarAsItIsFoldedBesideAMinimalOne() {
        // A 280-point sidebar in a 680-point window: unfolded, the work area would keep 218, so the column stays folded
        // for want of room, and the sidebar keeps its width.
        #expect(shown(680, sidebar: 281, minimal: 161, expanded: true) == WindowColumnShown(form: .folded, width: 29, byRoom: true))
        // 281 + 181 + 240 = 702.
        #expect(shown(702, sidebar: 281, minimal: 161, expanded: true).form == .expanded)
        #expect(shown(701, sidebar: 281, minimal: 161, expanded: true).form == .folded)
        // Folded, beside a minimal sidebar: a narrowing window narrows the sidebar toward it.
        #expect(shown(430, sidebar: 281, minimal: 161).form == .folded)
        #expect(shown(429, sidebar: 281, minimal: 161).form == .hidden)
        // A sidebar a window's resize narrowed below its minimum: unfolded beside it as it is, 108 + 181 + 240 = 529.
        #expect(shown(529, sidebar: 108, minimal: 161, expanded: true).form == .expanded)
        #expect(shown(528, sidebar: 108, minimal: 161, expanded: true).form == .folded)
    }

    @Test func withTheSidebarHiddenOnlyTheWorkAreaCounts() {
        #expect(shown(269, sidebar: 0).form == .folded)
        #expect(shown(268, sidebar: 0).form == .hidden)
        #expect(shown(421, sidebar: 0, expanded: true).form == .expanded)
        #expect(shown(420, sidebar: 0, expanded: true).form == .folded)
        // A width that is not one counts as none.
        #expect(shown(269, sidebar: -50).form == .folded)
    }

    @Test func aWidthNotMeasuredYetDecidesNothing() {
        #expect(shown(0, sidebar: 161) == WindowColumnShown(form: .folded, width: 29, byRoom: false))
        #expect(shown(0, sidebar: 161, expanded: true) == WindowColumnShown(form: .expanded, width: 181, byRoom: false))
    }

    @Test func theSettingsReadOnAndFoldedUntilTheUserChanges() {
        // New installs and existing ones that never wrote the keys: shown, and folded.
        #expect(WindowColumnSettings.shown(nil))
        #expect(!WindowColumnSettings.expanded(nil))
        #expect(!WindowColumnSettings.shown(false))
        #expect(WindowColumnSettings.shown(true))
        #expect(WindowColumnSettings.expanded(true))
        // Something that is not a choice reads as none.
        #expect(WindowColumnSettings.shown("no"))
        #expect(!WindowColumnSettings.expanded(1.5))
        #expect(WindowColumnSettings.shownKey == "showWindowColumn")
        #expect(WindowColumnSettings.expandedKey == "windowColumnExpanded")
    }

    @Test func itShowsWithTwoWindowsOrMoreAndTheSettingOn() {
        #expect(!WindowColumnSettings.visible(shown: true, windows: 0))
        #expect(!WindowColumnSettings.visible(shown: true, windows: 1))
        #expect(WindowColumnSettings.visible(shown: true, windows: 2))
        #expect(WindowColumnSettings.visible(shown: true, windows: 5))
        #expect(!WindowColumnSettings.visible(shown: false, windows: 3))
        // A restore opening three windows: the first has it from its first frame.
        #expect(WindowColumnSettings.visible(shown: true, windows: 1, expecting: 2))
        #expect(!WindowColumnSettings.visible(shown: true, windows: 1, expecting: 0))
        #expect(!WindowColumnSettings.visible(shown: false, windows: 1, expecting: 2))
    }
}
