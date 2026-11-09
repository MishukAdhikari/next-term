import CoreGraphics

/// A hint's room in a tab bar (TabBarView.hintRoom): the free strip between the last control after the tabs and the
/// buttons at the bar's end. The line takes none of the bar's room of its own: the tabs, the buttons and their keys are
/// laid out first, as if it were not there, and it goes in what is left, whole or not at all. So it gives way before a
/// key label or a tab would, and a window narrowed takes it away first.
public enum HintRoom {
    /// What stays clear at the strip's leading side, for the bar's own breathing room and, at the window's top, its drag.
    public static let keepClear: CGFloat = 24

    /// Where a line `width` wide goes in the strip from `start` to `end`: at the strip's trailing end, just before the
    /// buttons, with `keepClear` left before it. Nil when the words would not fit whole.
    public static func place(width: CGFloat, start: CGFloat, end: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard width > 0, end - start - keepClear >= width else { return nil }
        return (end - width, width)
    }
}
