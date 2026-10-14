import Foundation
import Testing
@testable import NextTermCore

/// The one rule for what Next Term types into a server tab by itself (Suggest a Command's line, Tab completion's keys
/// from the screen): what the status checks say, and how fresh it is.
@Suite struct ServerPromptTests {
    /// A tab at its prompt by two reports since the last Return, on the normal screen.
    func ready(_ keep: KeepMode = .off, fellBack: Bool = false) -> ServerPrompt {
        ServerPrompt(keep: keep, fellBack: fellBack, connected: true, shellReported: true, reportsSinceReturn: 2)
    }

    @Test func aShellReportedAtItsPromptTwiceSinceReturnTakesWhatIsTyped() {
        let plain = ready()
        #expect(plain.atPrompt && plain.mayAsk && !plain.awaitsReports && !plain.showsHerdr)
        var more = plain
        more.reportsSinceReturn = 7
        #expect(more.atPrompt)
    }

    @Test func reportsFromBeforeReturnAreNotTrusted() {
        // The first report after Return may come from a check that started before it, when the command it started (a
        // password prompt) was not in front yet.
        for reports in [0, 1] {
            var stale = ready()
            stale.reportsSinceReturn = reports
            #expect(!stale.atPrompt, "\(reports) reports")
            #expect(stale.awaitsReports && stale.mayAsk, "\(reports) reports: asked, put on the line once fresh")
        }
        #expect(ServerPrompt.freshReports == 2)
    }

    @Test func nothingIsTypedInWhileUnconnectedUnreportedOrBusy() {
        var notConnected = ready()
        notConnected.connected = false
        var unreported = ready()
        unreported.shellReported = false
        var running = ready()
        running.running = true
        for prompt in [notConnected, unreported, running] {
            #expect(!prompt.atPrompt && !prompt.mayAsk && !prompt.awaitsReports)
        }
    }

    @Test func theAlternateScreenIsTheShellsOnlyInTmuxThatDidNotFallBack() {
        for keep in KeepMode.allCases {
            for fellBack in [false, true] {
                #expect(ServerPrompt.shellOnAlternateScreen(keep: keep, fellBack: fellBack) == (keep == .tmux && !fellBack), "\(keep) \(fellBack)")
            }
        }
        var tmux = ready(.tmux)
        tmux.alternateScreen = true
        #expect(tmux.atPrompt)
        // vim or less on a plain shell, or in a tab whose tmux was missing.
        var plain = ready()
        plain.alternateScreen = true
        var fellBack = ready(.tmux, fellBack: true)
        fellBack.alternateScreen = true
        #expect(!plain.atPrompt && !plain.mayAsk)
        #expect(!fellBack.atPrompt && !fellBack.mayAsk)
    }

    @Test func aTmuxPaneInCopyModeTakesNothing() {
        var copying = ready(.tmux)
        copying.alternateScreen = true
        copying.inMode = true
        #expect(!copying.atPrompt && !copying.mayAsk && !copying.awaitsReports)
    }

    @Test func aTabThatShowsHerdrIsAskedOnceConnectedButTypesNothingIn() {
        // herdr's own screen, its agents' run as the tab's, and no report of a shell: the panel opens, to copy.
        var herdr = ServerPrompt(keep: .herdr, connected: true, shellReported: false, running: true, alternateScreen: true,
                                 reportsSinceReturn: 5)
        #expect(herdr.showsHerdr && herdr.mayAsk)
        #expect(!herdr.atPrompt && !herdr.awaitsReports && !herdr.shellInFront)
        // Even with every report a shell would have.
        herdr.shellReported = true
        herdr.running = false
        herdr.alternateScreen = false
        #expect(!herdr.atPrompt)
        herdr.connected = false
        #expect(!herdr.mayAsk)
    }

    @Test func aHerdrTabThatFellBackIsAPlainShell() {
        let fellBack = ready(.herdr, fellBack: true)
        #expect(!fellBack.showsHerdr && fellBack.atPrompt && fellBack.mayAsk)
        var busy = fellBack
        busy.running = true
        #expect(!busy.mayAsk)
    }

    @Test func aFellBackTabIsShownAndKeptAsOff() {
        #expect(KeepMode.herdr.shown(fellBack: true) == .off)
        #expect(KeepMode.tmux.shown(fellBack: true) == .off)
        #expect(KeepMode.herdr.shown(fellBack: false) == .herdr)
        #expect(KeepMode.off.shown(fellBack: false) == .off)
        #expect(KeepMode.herdr.keptLine(fellBack: true) == "Sessions kept: Off (herdr isn’t on the host)")
        #expect(KeepMode.tmux.keptLine(fellBack: false) == "Sessions kept: tmux")
        #expect(KeepMode.off.keptLine(fellBack: false) == "Sessions kept: Off")
    }
}
