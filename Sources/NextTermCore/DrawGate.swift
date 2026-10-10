/// Whether a terminal draws what its program prints: not while nobody can see its window (the app hidden, the window
/// minimized, covered by others, on another Space, the screen locked or asleep), nor before it is in a window. A busy
/// program in such a tab (an agent's spinner, a log) cost a few percent of a core day and night, and drawing was 40% of
/// the main thread. The output is still parsed; only the drawing waits. While the terminal cannot be seen, a change
/// to draw is dropped and remembered, and the whole terminal is drawn once when it can be seen again.
public struct DrawGate: Sendable {
    public private(set) var visible: Bool
    /// A change was dropped while the terminal could not be seen: what was drawn last is out of date.
    public private(set) var stale = false
    /// Changes dropped so far, for the self-test and the performance check.
    public private(set) var dropped = 0

    public init(visible: Bool) {
        self.visible = visible
    }

    /// A change to draw: true, draw it; false, nobody can see it (it is remembered).
    public mutating func invalidate() -> Bool {
        if visible { return true }
        stale = true
        dropped += 1
        return false
    }

    /// Whether the terminal can be seen now. True: draw all of it now, as it changed while it could not be.
    public mutating func setVisible(_ visible: Bool) -> Bool {
        self.visible = visible
        guard visible, stale else { return false }
        stale = false
        return true
    }
}
