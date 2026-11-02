import AppKit
import NextTermCore

extension NSWindow {
    /// What a system tab bar and the title row above it take off the window's top while one shows (TitleBarCover); 0
    /// without one.
    var tabBarCover: CGFloat {
        guard tabGroup?.isTabBarVisible == true, let content = contentView else { return 0 }
        let layout: NSRect = content.convert(contentLayoutRect, from: nil)
        return TitleBarCover.top(contentHeight: content.bounds.height, layoutMaxY: layout.maxY, tabBarShown: true)
    }

    /// Where the window's own top row starts, in screen coordinates: its top, or under a system tab bar while one shows.
    /// Panels placed a set distance below a window's top (Go to File, Agent Sessions, the update prompt) go from here.
    var contentTop: CGFloat { frame.maxY - tabBarCover }
}
