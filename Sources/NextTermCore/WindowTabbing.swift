import Foundation

/// Project windows that macOS groups as tabs of one window (plan 032): what the system's tab bar takes off the top of a
/// window, so everything Next Term draws in its top row sits below it.
public enum TitleBarCover {
    /// How far down from the top of a window's content Next Term's own top row starts: 0 while no system tab bar shows
    /// (our bars share the title row with the traffic lights, as they always have); with one, the title row and the tab
    /// bar together, as the window's unobscured area (`contentLayoutRect`) says, in whole points. `contentHeight` and
    /// `layoutMaxY` are in the content view's coordinates, y up.
    public static func top(contentHeight: CGFloat, layoutMaxY: CGFloat, tabBarShown: Bool) -> CGFloat {
        guard tabBarShown, contentHeight > 0 else { return 0 }
        return max(0, ceil(contentHeight - layoutMaxY))
    }
}
