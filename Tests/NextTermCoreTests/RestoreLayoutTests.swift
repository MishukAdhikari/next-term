import Foundation
import Testing
@testable import NextTermCore

/// What the restore decides as it builds and applies (KTD6, KTD10): where a window goes, when a pane's action runs, the
/// order automatic resumes start in, and the words of the safe-mode and set-aside alerts. Made-up screens and times.
@Suite struct RestoreLayoutTests {
    typealias Frame = SessionSnapshot.Frame
    let built = RestoreLayout.Screen(name: "Built-in Retina Display", frame: Frame(x: 0, y: 0, width: 1512, height: 982))
    let studio = RestoreLayout.Screen(name: "Studio Display", frame: Frame(x: 1512, y: -200, width: 2560, height: 1440))

    @Test func aFrameIsKeptOnlyOnTheScreenItWasOnWhileThatScreenIsThere() {
        let frame = Frame(x: 1700, y: 100, width: 1100, height: 720)
        #expect(RestoreLayout.frame(frame, on: "Studio Display", screens: [built, studio]) == frame)
        // The screen is gone: the window opens where a new one would.
        #expect(RestoreLayout.frame(frame, on: "Studio Display", screens: [built]) == nil)
        // Not said which screen, or no frame saved.
        #expect(RestoreLayout.frame(frame, on: nil, screens: [built, studio]) == nil)
        #expect(RestoreLayout.frame(nil, on: "Studio Display", screens: [built, studio]) == nil)
        // The screen is there, but arranged elsewhere now: a frame left off it is not kept.
        let moved = RestoreLayout.Screen(name: "Studio Display", frame: Frame(x: -2560, y: 0, width: 2560, height: 1440))
        #expect(RestoreLayout.frame(frame, on: "Studio Display", screens: [built, moved]) == nil)
        // Half on it is enough.
        let edge = Frame(x: 1000, y: 100, width: 1100, height: 720)
        #expect(RestoreLayout.frame(edge, on: "Studio Display", screens: [built, studio]) == edge)
        // A frame no window could have.
        for bad in [Frame(x: 1700, y: 100, width: 0, height: 720), Frame(x: 1700, y: 100, width: 1100, height: -5),
                    Frame(x: .nan, y: 100, width: 1100, height: 720), Frame(x: 1700, y: 100, width: .infinity, height: 720),
                    Frame(x: 1700, y: 100, width: 100_000, height: 720)] {
            #expect(RestoreLayout.frame(bad, on: "Studio Display", screens: [built, studio]) == nil, "\(bad)")
        }
    }

    @Test func windowsAreListedInTheOrderTheyOpenedWhicheverWasUsedLast() {
        func window(_ opened: Int?) -> SessionSnapshot.Window {
            let pane = SessionSnapshot.Pane(id: UUID())
            return SessionSnapshot.Window(groups: [SessionSnapshot.Group(root: .pane(pane), focused: pane.id)], opened: opened)
        }
        // Opened A, B, C, D; D used, then B: saved front to back as B, D, C, A. Listed A, B, C, D again.
        let saved = [window(1), window(3), window(2), window(0)]
        #expect(RestoreLayout.openingOrder(saved) == [3, 0, 2, 1])
        // A file written before the order was kept: back to front, as before.
        #expect(RestoreLayout.openingOrder([window(nil), window(nil), window(nil)]) == [2, 1, 0])
        // Some with it and some without: those with it first, in their order, then the rest back to front.
        #expect(RestoreLayout.openingOrder([window(nil), window(1), window(nil), window(0)]) == [3, 1, 2, 0])
        // Places with gaps (a window not saved) and none at all.
        #expect(RestoreLayout.openingOrder([window(7), window(2)]) == [1, 0])
        #expect(RestoreLayout.openingOrder([]).isEmpty)
    }

    @Test func aNoteIsFedAsOneDimLineOfPlainText() {
        let hostile = "Last command: printf \u{1B}]52;c;aGk=\u{07}\u{9B}6n done.\nrm -rf ~\r\u{1B}[201~"
        let fed = RestoreLayout.noteLine(hostile)
        #expect(fed.hasPrefix("\u{1B}[2m") && fed.hasSuffix("\u{1B}[0m\r\n"))
        let inner = String(fed.dropFirst(4).dropLast(6))
        let control = inner.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
        #expect(!control, "\(inner.debugDescription)")
        #expect(inner.contains("Last command: printf") && inner.contains("rm -rf ~"))
    }

    @Test func anActionWaitsForTheLineEditorThenRunsOnceUnlessTheUserTypedFirst() {
        typealias Ready = RestoreLayout.Readiness
        func state(integrated: Bool = true, paste: Bool = true, typed: Bool = false, exited: Bool = false,
                   waited: TimeInterval = 1) -> Ready {
            RestoreLayout.readiness(integrated: integrated, bracketedPaste: paste, userTyped: typed, exited: exited, waited: waited)
        }
        // Ready: the shell's first prompt was reported and its line editor reads pasted text as text.
        #expect(state() == .ready)
        #expect(state(integrated: false) == .waiting)
        #expect(state(paste: false) == .waiting)
        // The user typed in the tab first: the action is the user's to drop.
        #expect(state(typed: true) == .cancelled)
        #expect(state(integrated: false, typed: true) == .cancelled)
        // Not ready in time, or the shell ended: a note in place of the action.
        #expect(state(integrated: false, waited: RestoreLayout.readyLimit) == .timedOut)
        #expect(state(exited: true) == .timedOut)
        #expect(state(waited: RestoreLayout.readyLimit + 5) == .ready)
    }

    /// The line is the restore's only while nothing else reached it: the user's flag covers what they do in the tab, and
    /// the count of writes into the shell covers every other way text gets there (Insert Path, a suggested command, Send
    /// to Agent), whether or not it said it was the user's. The terminal's own answers to a prompt's questions are not
    /// writes (`NextTermView.inputWrites`).
    @Test func aLineAnythingElseWroteToIsNoLongerTheRestores() {
        var line = RestoreLayout.LineWatch(writes: 3)
        #expect(!line.taken(userTyped: false, writes: 3))
        // Text typed into the tab without the user's flag: the line is not empty any more.
        #expect(line.taken(userTyped: false, writes: 4))
        // A key, a paste or a drop, even one a gate held back from the shell.
        #expect(line.taken(userTyped: true, writes: 3))
        // The restore typed its own line: that write is its own, and only a later one takes the line.
        line.typed(writes: 4)
        #expect(!line.taken(userTyped: false, writes: 4))
        #expect(line.taken(userTyped: false, writes: 5))
        #expect(line.taken(userTyped: true, writes: 4))
        // Ready, as the action reads it: a line taken before the shell is ready cancels the action.
        let ready = RestoreLayout.readiness(integrated: true, bracketedPaste: true, userTyped: line.taken(userTyped: false, writes: 5),
                                            exited: false, waited: 1)
        #expect(ready == .cancelled)
    }

    /// An automatic resume's Return goes only onto the line it typed: anything put there since (a key, Insert Path, any
    /// text typed into the tab) leaves the line as it is, the resume command and what came after it, unrun. That still
    /// counts as applied: the restore typed its line, as for a line put back, and nothing of its own ran (MCPRestored).
    @Test func aTypedResumeRunsOnReturnOnlyOnALineNothingElseReached() {
        typealias After = RestoreLayout.ResumeReturn
        #expect(RestoreLayout.afterResumeTyped(lineTaken: false, exited: false) == .press)
        #expect(RestoreLayout.afterResumeTyped(lineTaken: true, exited: false) == .withheld)
        // The shell ended: there is nothing to run.
        #expect(RestoreLayout.afterResumeTyped(lineTaken: false, exited: true) == .shellEnded)
        #expect(RestoreLayout.afterResumeTyped(lineTaken: true, exited: true) == .shellEnded)
        #expect(After.press.event == .applied && After.withheld.event == .applied && After.shellEnded.event == .dismissed)
        #expect(RestoreLayout.returnDelay == 0.25)
    }

    @Test func aShellNotReadyInTimeSaysNothingWasTyped() {
        #expect(RestoreLayout.timedOutNote == "The shell was not ready in time, so nothing was typed.")
        let fed = RestoreLayout.noteLine(RestoreLayout.timedOutNote)
        #expect(fed == "\u{1B}[2m" + RestoreLayout.timedOutNote + "\u{1B}[0m\r\n")
    }

    @Test func automaticResumesStartAPartTheTabsInViewFirst() {
        var queue = RestoreLayout.ResumeQueue()
        let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!
        let c = UUID(uuidString: "00000000-0000-4000-8000-00000000000c")!
        // Three ready at once: the one in view goes first, then the rest in the order given, 400 ms apart.
        #expect(queue.next(ready: [a, b, c], visible: [c], now: 10) == c)
        #expect(queue.next(ready: [a, b], visible: [], now: 10.1) == nil)
        #expect(queue.next(ready: [a, b], visible: [], now: 10 + RestoreLayout.resumeGap) == a)
        #expect(queue.next(ready: [b], visible: [b], now: 10.5) == nil)
        #expect(queue.next(ready: [b], visible: [], now: 11) == b)
        #expect(queue.next(ready: [], visible: [], now: 20) == nil)
        #expect(RestoreLayout.resumeGap == 0.4)
    }

    @Test func aSplitKeepsItsDividersAndAPaneLeftOutGivesItsRoomToItsNeighbour() {
        // Every pane built: the dividers where the user left them.
        #expect(RestoreLayout.dividers([0.3], children: 2, dropped: []) == [0.3])
        #expect(RestoreLayout.dividers([0.2, 0.7], children: 3, dropped: []) == [0.2, 0.7])
        // A tab on a host removed since leaves its split: as when the app closes a pane, its neighbour takes its room.
        #expect(RestoreLayout.dividers([0.2, 0.7], children: 3, dropped: [1]) == [0.2])
        #expect(RestoreLayout.dividers([0.2, 0.7], children: 3, dropped: [2]) == [0.2])
        #expect(RestoreLayout.dividers([0.2, 0.7], children: 3, dropped: [0]) == [0.7])
        #expect(RestoreLayout.dividers([0.1, 0.4, 0.8], children: 4, dropped: [0, 3]) == [0.4])
        // Dividers that do not fit the panes give equal shares; none for a pane alone.
        #expect(RestoreLayout.dividers([0.3, 0.6], children: 2, dropped: []) == [0.5])
        #expect(RestoreLayout.dividers([.nan], children: 2, dropped: []) == [0.5])
        #expect(RestoreLayout.dividers([0.3], children: 2, dropped: [1]).isEmpty)
    }

    @Test func theAlertsSayWhatHappenedAndNameTheFolder() {
        #expect(RestoreAlertText.safeModeTitle
            == "Next Term restored your windows but ran nothing, because the last two restores did not finish.")
        #expect(RestoreAlertText.keepAsIs == "Keep As Is" && RestoreAlertText.tryAgain == "Try Again")
        let folder = "/Users/x/Library/Application Support/Next Term/sessions-0123.noindex"
        let text = RestoreAlertText.setAsideText(folder: folder, name: SessionLaunch.setAsideName)
        #expect(RestoreAlertText.setAsideTitle == "The previous session could not be restored")
        #expect(text.contains(folder + "/" + SessionLaunch.setAsideName))
        // Without a name, it was not moved, and the alert does not say it was.
        let kept = RestoreAlertText.setAsideText(folder: folder, name: nil)
        #expect(!kept.contains(SessionLaunch.setAsideName) && kept.contains(folder))
    }

    /// Try Again resumes nothing (R21): the alert promises only what it puts back, and says nothing runs by itself.
    @Test func safeModePromisesNoResume() {
        let text = RestoreAlertText.safeModeText
        #expect(text == "Each tab says what it held. Keep As Is leaves them as they are. Try Again puts back what each tab held, once, "
            + "and runs nothing: an agent's resume command waits on the line for you.")
        #expect(!text.contains("resumes"))
        // A try the sessions folder refuses to count runs nothing, and says so.
        #expect(RestoreAlertText.notCountedTitle == "Try Again ran nothing")
        #expect(RestoreAlertText.notCountedText.contains("could not record") && RestoreAlertText.notCountedText.contains("as they are"))
    }
}

/// Kept remote tabs (tmux, herdr) waiting to reattach: each in its own project's window, once that window is open, and
/// one with no project in the first window. A record still waiting is saved again, so its session is never forgotten.
@Suite struct KeptRemoteQueueTests {
    func record(_ session: String, project: String?, keep: KeepMode = .tmux) -> RemoteTabRecord {
        RemoteTabRecord(hostID: "h1", destination: "sam@web-1.example", directory: "~/app", session: session, keep: keep, project: project)
    }

    let app = "/Users/x/Code/app"
    let api = "/Users/x/Code/api"

    func sessions(_ taken: [(record: RemoteTabRecord, project: String?)]) -> [String] {
        taken.map { (entry: (record: RemoteTabRecord, project: String?)) -> String in entry.record.session }
    }

    @Test func aRecordWaitsForItsOwnProjectsWindow() {
        var queue = KeptRemoteQueue([record("nt-1", project: api), record("nt-2", project: nil), record("nt-3", project: app)])
        // No window yet: everything waits.
        #expect(queue.take(openProjects: []).isEmpty)
        // `app` opens first: its record and the one with no project come in, `api`'s waits.
        let first = queue.take(openProjects: [app])
        let firstSessions: [String] = sessions(first)
        #expect(firstSessions == ["nt-2", "nt-3"])
        #expect(first.first?.project == nil && first.last?.project == app)
        #expect(queue.waiting == [record("nt-1", project: api)])
        // A plain window opening changes nothing for it.
        #expect(queue.take(openProjects: [app, nil]).isEmpty)
        // `api` opens: it lands there.
        let second = queue.take(openProjects: [app, nil, api])
        #expect(sessions(second) == ["nt-1"] && second.first?.project == api)
        #expect(queue.waiting.isEmpty)
    }

    @Test func aWaitingRecordIsSavedAgainUntilItReattaches() {
        var queue = KeptRemoteQueue([record("nt-1", project: api)])
        _ = queue.take(openProjects: [app])
        let open = [record("nt-9", project: app)]
        let saved: [RemoteTabRecord] = queue.saved(with: open)
        #expect(saved == open + [record("nt-1", project: api)])
        // Once open, it is saved as the open tab it is, once.
        _ = queue.take(openProjects: [api])
        let reopened = open + [record("nt-1", project: api)]
        #expect(queue.saved(with: reopened) == reopened)
    }

    @Test func theRecordsARestoreBroughtBackDoNotWait() {
        var queue = KeptRemoteQueue([record("nt-1", project: api), record("nt-2", project: app), record("nt-2", project: app, keep: .herdr)])
        queue.remove(restored: [record("nt-2", project: "/Users/x/elsewhere")])
        #expect(queue.waiting == [record("nt-1", project: api), record("nt-2", project: app, keep: .herdr)])
        // A plain connection is never kept, so never waits.
        var plain = KeptRemoteQueue([record("nt-5", project: nil, keep: .off), record("nt-6", project: nil)])
        #expect(plain.waiting == [record("nt-6", project: nil)])
        #expect(sessions(plain.take(openProjects: [nil])) == ["nt-6"])
    }
}
