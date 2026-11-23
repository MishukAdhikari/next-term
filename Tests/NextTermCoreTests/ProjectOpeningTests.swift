import Foundation
import Testing
@testable import NextTermCore

/// Where a folder opens as a project (⌘O, Open Recent, a folder dropped on the Dock icon once the launch is done), and when
/// what a launch names opens (R32). Made-up windows and paths.
@Suite struct ProjectOpeningTests {
    typealias Target = ProjectOpening.Target
    let fresh = Target(pristine: true, holdsRestore: false)
    let used = Target(pristine: false, holdsRestore: false)
    let restored = Target(pristine: false, holdsRestore: true)

    @Test func openProjectTakesOverAnUnusedWindowElseFollowsTheSetting() {
        for setting in ProjectOpening.Setting.allCases {
            #expect(ProjectOpening.placement(from: fresh, setting: setting) == .adopt, "\(setting)")
            // No terminal window to open it from: a window of its own.
            #expect(ProjectOpening.placement(from: nil, setting: setting) == .newWindow, "\(setting)")
        }
        #expect(ProjectOpening.placement(from: used, setting: .ask) == .ask)
        #expect(ProjectOpening.placement(from: used, setting: .thisWindow) == .replace)
        #expect(ProjectOpening.placement(from: used, setting: .newWindow) == .newWindow)
        // Settings › "Open Projects In" keeps the words it always saved, the new choices after them.
        #expect(ProjectOpening.Setting.allCases.map(\.rawValue) == ["ask", "thisWindow", "newWindow", "newTab", "asMacOS"])
    }

    /// New Tab in This Window merges the project into the window it was opened from; As macOS Prefers does when System
    /// Settings' "Prefer tabs" says so for that window, else opens a window of its own (plan 032).
    @Test func newTabMergesIntoThisWindowAndAsMacOSPrefersFollowsTheSystem() {
        #expect(ProjectOpening.placement(from: used, setting: .newTab) == .newTab)
        #expect(ProjectOpening.placement(from: used, setting: .asMacOS, systemPrefersTabs: true) == .newTab)
        #expect(ProjectOpening.placement(from: used, setting: .asMacOS, systemPrefersTabs: false) == .newWindow)
        // An unused window is still taken over, and a restored one still never merged into.
        #expect(ProjectOpening.placement(from: fresh, setting: .newTab) == .adopt)
        #expect(ProjectOpening.placement(from: restored, setting: .newTab, systemPrefersTabs: true) == .newWindow)
        // As MCP names them, both ways.
        for setting in ProjectOpening.Setting.allCases { #expect(ProjectOpening.Setting(mcpName: setting.mcpName) == setting) }
        #expect(ProjectOpening.Setting(mcpName: "newTab") == nil)
    }

    /// A window the restore brought back, with tabs the user has not put anything in yet, is never taken over or replaced:
    /// its put-back lines, notes and scrollback would go before the user saw them. The folder opens in a window of its own,
    /// in front, and nothing asks, whatever "Open Projects In" says.
    @Test func aWindowTheRestoreBroughtBackIsNeverTakenOverOrReplaced() {
        for setting in ProjectOpening.Setting.allCases {
            #expect(ProjectOpening.placement(from: restored, setting: setting) == .newWindow, "\(setting)")
            let unusedLooking = Target(pristine: true, holdsRestore: true)
            #expect(ProjectOpening.placement(from: unusedLooking, setting: setting) == .newWindow, "\(setting)")
        }
    }

    /// AE21 and Finder's Open With at launch: what `application(_:open:)` names before the launch hook waits until the
    /// restore has built its windows, so it never makes a window of its own for a project the restore brings back, nor a
    /// second one for a file in it. It then opens as `nxtrm` opens it, in front; so does what comes before the launch has
    /// shown what it shows. After that, a folder opens as Open Project does.
    @Test func whatALaunchNamesWaitsForTheRestoreThenOpensInFrontOfIt() {
        var requests = ProjectOpening.LaunchRequests()
        let readme = URL(fileURLWithPath: "/Users/u/Code/app/README.md")
        let api = URL(fileURLWithPath: "/Users/u/Code/api", isDirectory: true)
        #expect(requests.arrive([readme]) == .held)
        #expect(requests.arrive([api]) == .held)
        #expect(requests.restored() == [readme, api])
        // Between the hook and what the launch shows: still the launch's request.
        #expect(requests.arrive([api]) == .asRequest)
        // Nothing is held twice.
        #expect(requests.restored().isEmpty)
        requests.shown()
        #expect(requests.arrive([api]) == .asProject)
        #expect(requests.arrive([readme]) == .asProject)
    }

    /// A launch that shows what it shows without running the hook's restore first (the plain self-test) still opens what
    /// comes after as Open Project does.
    @Test func whatComesOnceTheLaunchHasShownOpensAsOpenProjectDoes() {
        var requests = ProjectOpening.LaunchRequests()
        _ = requests.restored()
        requests.shown()
        #expect(requests.arrive([URL(fileURLWithPath: "/Users/u/Code/api", isDirectory: true)]) == .asProject)
    }
}
