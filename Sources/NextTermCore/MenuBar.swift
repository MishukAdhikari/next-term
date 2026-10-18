import Foundation

/// The menu bar's menus after Next Term's own, in the order AppDelegate.buildMenu makes them. The self-tests check the
/// bar against this one list, so a menu added to the bar is added here, in its place, and nowhere else.
public enum MenuBar {
    public static let titles = ["File", "Edit", "View", "Agents", "Tasks", "Git", "Notifications", "Window"]

    /// The menus on either side of `title` in the bar, nil at an end or for a menu it doesn't have.
    public static func neighbours(of title: String) -> (before: String?, after: String?) {
        guard let index = titles.firstIndex(of: title) else { return (nil, nil) }
        return (index > 0 ? titles[index - 1] : nil, index + 1 < titles.count ? titles[index + 1] : nil)
    }
}
