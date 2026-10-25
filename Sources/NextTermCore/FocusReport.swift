import Foundation

/// What a program in a tab is told of the tab's focus (CSI I, CSI O), when it asked to hear (DECSET 1004, as herdr's
/// screen, vim, Neovim and tmux do). SwiftTerm tells it only when the terminal view gains or loses the keyboard; Next
/// Term also tells it when the user stops seeing the tab with the keyboard in it: another tab or window in front, the
/// window minimized, the terminal folded, Next Term in the background. Each change is told once: what SwiftTerm already
/// said when the keyboard moved counts as told. (SwiftTerm writes nothing to a program that did not ask.)
public struct FocusReport: Equatable, Sendable {
    /// What the program was last told; SwiftTerm starts at focused.
    public private(set) var told: Bool?
    /// Whether the view had its window's keyboard at the last look; nil before the first.
    private var keyboard: Bool?

    public init(told: Bool? = true) {
        self.told = told
    }

    /// What to tell the program now, given what it was told last: nil when nothing is due.
    public static func next(last: Bool?, now: Bool) -> Bool? {
        last == now ? nil : now
    }

    /// One look at the tab. `keyboard`: its terminal view has its window's keyboard (a change since the last look was
    /// told by SwiftTerm as it happened); `seen`: the user can see the tab (its window in front of the active app, the
    /// terminal not folded). The program is focused while both hold. Returns what to tell it now, nil for nothing.
    public mutating func look(keyboard: Bool, seen: Bool) -> Bool? {
        if let had = self.keyboard, had != keyboard { told = keyboard }
        self.keyboard = keyboard
        guard let send = Self.next(last: told, now: keyboard && seen) else { return nil }
        told = send
        return send
    }
}
