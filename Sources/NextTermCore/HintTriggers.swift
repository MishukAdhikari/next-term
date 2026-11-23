import CoreGraphics

/// When a hint's pull trigger fires, where that is more than one fact (plan 035).
public enum HintTriggers {
    /// H7: the terminal's share of the work area at a divider drag's release, below or above which the user is fighting
    /// for room along the split.
    public static let extremeShare: CGFloat = 0.15
    /// The work area's least width for the terminal to go beside the editor with room on both sides: about 480 pt each,
    /// twice the side-by-side minimum.
    public static let besideWidth: CGFloat = 960

    /// H7: a drag of the divider between the editor and the terminal ended with the terminal above or below the editor,
    /// open, at under 15% or over 85% of the work area, in a work area wide enough to hold the two side by side.
    public static func terminalBeside(position: TerminalPosition, collapsed: Bool, editorShown: Bool, terminalShare: CGFloat,
                                      workWidth: CGFloat) -> Bool {
        guard !position.sideBySide, !collapsed, editorShown, workWidth >= besideWidth else { return false }
        return terminalShare < extremeShare || terminalShare > 1 - extremeShare
    }

    /// H4: how long the editor's selection must stay the same before the hint may show.
    public static let selectionDwell: Double = 1

    /// H4: the editor has the keyboard and lines `first` to `last` (zero-based, as the selection spans them) are
    /// selected, two or more; a local agent runs in a tab of the window and is not working or waiting on a decision;
    /// the file is not one that usually holds secrets.
    public static func sendSelection(editorFocused: Bool, first: Int, last: Int, agentRuns: Bool, agentBusy: Bool, holdsSecrets: Bool) -> Bool {
        editorFocused && last > first && agentRuns && !agentBusy && !holdsSecrets
    }
}
