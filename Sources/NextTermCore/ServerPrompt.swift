import Foundation

/// Whether a server tab's shell waits at its prompt: the one rule for what Next Term types into a server tab by itself,
/// Suggest a Command's line and the keys Tab completion reads off the screen. On a server the status checks are all
/// there is to go on, two seconds apart, so a report taken before the last Return can still say "shell" while the
/// command that Return started (a password prompt) is in front: the prompt is trusted again only from the second
/// report after it. Pure: the app hands it what it knows of the tab.
public struct ServerPrompt: Equatable, Sendable {
    public var keep: KeepMode
    /// tmux or herdr was missing on the host: the tab is a plain shell.
    public var fellBack: Bool
    /// The tab's own login got through, and it is neither disconnected nor ended.
    public var connected: Bool
    /// The status checks have said the tab's shell is at its prompt at least once on this connection.
    public var shellReported: Bool
    /// The status checks say something runs in front of the shell.
    public var running: Bool
    /// tmux's pane is in one of its modes (copy mode, which the mouse wheel enters): keys there are tmux's.
    public var inMode: Bool
    /// The terminal shows its alternate screen.
    public var alternateScreen: Bool
    /// Status reports since the last Return, ^C or ^D (and since the connection came back).
    public var reportsSinceReturn: Int

    public init(keep: KeepMode, fellBack: Bool = false, connected: Bool, shellReported: Bool, running: Bool = false,
                inMode: Bool = false, alternateScreen: Bool = false, reportsSinceReturn: Int) {
        self.keep = keep
        self.fellBack = fellBack
        self.connected = connected
        self.shellReported = shellReported
        self.running = running
        self.inMode = inMode
        self.alternateScreen = alternateScreen
        self.reportsSinceReturn = reportsSinceReturn
    }

    /// The report since the last Return from which the prompt is trusted: the first may come from a check that
    /// started before it.
    public static let freshReports = 2

    /// tmux draws a tab it keeps on the alternate screen, with its pane's cursor where the shell's is: there the
    /// alternate screen is the shell's. Anywhere else (herdr's own screen, a tab that fell back, a plain shell) it is a
    /// full-screen program's.
    public static func shellOnAlternateScreen(keep: KeepMode, fellBack: Bool) -> Bool {
        keep == .tmux && !fellBack
    }

    /// The tab shows herdr itself: which of its panes has the keys, and what runs there, is out of sight.
    public var showsHerdr: Bool { keep == .herdr && !fellBack }

    /// What the status checks said last: the shell is at its prompt with nothing in front of it, on its own screen.
    /// Never in a tab that shows herdr.
    public var shellInFront: Bool {
        guard connected, !showsHerdr, shellReported, !running, !inMode else { return false }
        return !alternateScreen || Self.shellOnAlternateScreen(keep: keep, fellBack: fellBack)
    }

    /// Something may be typed in now: the shell is in front, by reports taken since the last Return.
    public var atPrompt: Bool { shellInFront && reportsSinceReturn >= Self.freshReports }

    /// All that keeps the prompt from being trusted is reports since the last Return, which come within seconds.
    public var awaitsReports: Bool { shellInFront && !atPrompt }

    /// Suggest a Command may be asked here: once connected, a tab that shows herdr (its answer is copied into a pane by
    /// the user); any other with its shell in front, fresh reports or not, since nothing is typed in until they come.
    public var mayAsk: Bool { showsHerdr ? connected : shellInFront }
}
