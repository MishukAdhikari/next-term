import Foundation
import Testing
@testable import NextTermCore

/// Each test has a defaults domain of its own, removed after: never the app's.
@Suite struct LayoutPickerTests {
    static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "NextTermCoreTests.layoutPicker.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("no defaults domain \(name)")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func theRule() {
        #expect(LayoutPicker.shouldShow(shown: false, usedBefore: false))
        #expect(!LayoutPicker.shouldShow(shown: false, usedBefore: true))
        #expect(!LayoutPicker.shouldShow(shown: true, usedBefore: false))
        #expect(!LayoutPicker.shouldShow(shown: true, usedBefore: true))
    }

    @Test func aNewInstallSeesIt() {
        Self.withDefaults { defaults in
            #expect(LayoutPicker.isDue(in: defaults))
        }
    }

    /// Any one sign of an install used before, an empty session list too, and it never shows: an update included.
    @Test func anInstallUsedBeforeNeverSeesIt() {
        let markers: [(String, Any)] = [("sessionProjects", [String]()), ("sessionProjects", ["/tmp/p"]), ("recentProjects", ["/tmp/p"]),
                                        ("lastUpdateCheck", 1_700_000_000.0), ("lastUpdateFailure", 1_700_000_000.0), ("importOffered", true)]
        for (key, value) in markers {
            Self.withDefaults { defaults in
                defaults.set(value, forKey: key)
                #expect(!LayoutPicker.isDue(in: defaults), "\(key)")
            }
        }
        // Every key the sidebar's first-launch rule reads, so a key added there is covered here too.
        for key in SidebarClick.usedInstallKeys {
            Self.withDefaults { defaults in
                defaults.set(true, forKey: key)
                #expect(!LayoutPicker.isDue(in: defaults), "\(key)")
            }
        }
    }

    /// Shown once, by a pick or Skip, never again.
    @Test func onceShownNeverAgain() {
        Self.withDefaults { defaults in
            #expect(LayoutPicker.isDue(in: defaults))
            LayoutPicker.markShown(in: defaults)
            #expect(defaults.bool(forKey: LayoutPicker.shownKey))
            #expect(!LayoutPicker.isDue(in: defaults))
        }
    }

    /// Each layout's values are ones set_layout takes, and set the arrangement its line describes.
    @Test func thePresets() {
        #expect(LayoutPreset.allCases.map(\.name) == ["IDE", "Terminal", "Agents"])
        for preset in LayoutPreset.allCases {
            #expect(MCPLayoutChange.parse(preset.arguments).isSuccess, "\(preset)")
            let change = preset.change
            #expect(change.sidebarSide == "left", "\(preset)")
            #expect(change.windowColumnShown == true, "\(preset)")
            // Nothing per window: the layout is every window's.
            #expect(change.sidebarShown == nil && change.terminalFolded == nil && change.windowColumnFolded == nil, "\(preset)")
            #expect(preset.accessibilityLabel == "\(preset.name) layout: \(preset.line)")
        }
        #expect(LayoutPreset.ide.change == MCPLayoutChange(terminalPosition: "bottom", sidebarSide: "left", terminalTabs: "top",
                                                           windowColumnShown: true, windowColumnSide: "right"))
        #expect(LayoutPreset.terminal.change == MCPLayoutChange(terminalPosition: "right", sidebarSide: "left", terminalTabs: "top",
                                                                windowColumnShown: true, windowColumnSide: "left"))
        #expect(LayoutPreset.agents.change == MCPLayoutChange(terminalPosition: "bottom", sidebarSide: "left", terminalTabs: "left",
                                                              windowColumnShown: true, windowColumnSide: "right"))
    }

    /// Curly quotes and the ellipsis, as the rest of Next Term writes them.
    @Test func theWords() {
        #expect(LayoutPicker.title == "How do you like to work?")
        #expect(LayoutPicker.settingsButtonTitle.hasSuffix("…"))
        let all = [LayoutPicker.title, LayoutPicker.footer, LayoutPicker.settingsButtonTitle] + LayoutPreset.allCases.map(\.line)
        for text in all { #expect(!text.contains("'") && !text.contains("\"") && !text.contains("..."), "\(text)") }
    }
}
