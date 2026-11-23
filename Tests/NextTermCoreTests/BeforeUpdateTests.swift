import Foundation
import Testing
@testable import NextTermCore

/// The windows open before an update, kept until the relaunch shows them all back: which did not come back.
@Suite struct BeforeUpdateTests {
    typealias Window = SessionSnapshot.Window
    func window(_ project: String?, folders: [String]) -> Window {
        let groups = folders.map { (folder: String) -> SessionSnapshot.Group in
            var pane = SessionSnapshot.Pane(id: UUID())
            pane.folder = folder
            return SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        }
        return Window(project: project, groups: groups)
    }

    @Test func aWindowIsBackWhenItsProjectOrItsFolderIsOpen() {
        let saved = [window("/Code/xCloud", folders: ["/Code/xCloud"]), window("/Code/xCloud/.claude/worktrees/cc-9021", folders: ["/Code/xCloud/.claude/worktrees/cc-9021"]),
                     window(nil, folders: ["/Users/me"]), window("/Code/agents", folders: ["/Code/agents"])]
        let open = [BeforeUpdate.Open(project: "/Code/xCloud", folders: ["/Code/xCloud"]), BeforeUpdate.Open(project: nil, folders: ["/Users/me", "/tmp"])]
        #expect(BeforeUpdate.missing(saved: saved, open: open) == [1, 3])
        // Everything open: nothing missing.
        let all = open + [BeforeUpdate.Open(project: "/Code/xCloud/.claude/worktrees/cc-9021", folders: []), BeforeUpdate.Open(project: "/Code/agents", folders: [])]
        #expect(BeforeUpdate.missing(saved: saved, open: all).isEmpty)
    }

    @Test func oneOpenWindowStandsForOneSavedWindow() {
        // Two home-folder windows saved, one open: one is missing.
        let saved = [window(nil, folders: ["/Users/me"]), window(nil, folders: ["/Users/me"])]
        #expect(BeforeUpdate.missing(saved: saved, open: [BeforeUpdate.Open(project: nil, folders: ["/Users/me"])]) == [1])
    }

    @Test func aCopyGoesAfterADay() {
        let now = Date()
        #expect(!BeforeUpdate.isStale(savedAt: now.addingTimeInterval(-3600), now: now))
        #expect(BeforeUpdate.isStale(savedAt: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(BeforeUpdate.isStale(savedAt: now.addingTimeInterval(3600), now: now)) // a clock moved back
    }
}
