import Foundation

/// Whether a sidebar group (Services) shows open, project by project: closed where you closed it, open where its rows
/// first appear, and open with the project's folder when its rows came while the folder was closed. Apart from AppKit,
/// so it can be tested.
///
/// The outline keeps one group object for every project, and can show it open from the project before. So each time
/// the group's rows appear, it is set open or closed, and a wait for a folder to open belongs to one project.
public struct SidebarGroupExpansion: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case expand
        case collapse
        /// The project's folder is closed: open the group when it opens (`rootOpened`).
        case waitForRoot
    }

    /// Projects whose group you closed.
    private var collapsedRoots: Set<String> = []
    /// The project whose folder, once open, opens the group.
    private var waitingRoot: String?

    public init() {}

    public func isCollapsed(in root: String) -> Bool { collapsedRoots.contains(root) }

    /// The group's rows appear in `root`'s tree, where it had none: what the group does now. An earlier wait ends.
    public mutating func rowsAppeared(in root: String, rootIsOpen: Bool) -> Action {
        waitingRoot = nil
        if collapsedRoots.contains(root) { return .collapse }
        if rootIsOpen { return .expand }
        waitingRoot = root
        return .waitForRoot
    }

    /// `root`'s folder opened: true when the group waits for it, once.
    public mutating func rootOpened(_ root: String) -> Bool {
        guard waitingRoot == root else { return false }
        waitingRoot = nil
        return true
    }

    /// The group closed in `root`'s tree. One that closed with the folder is not remembered.
    public mutating func groupClosed(in root: String, rootIsOpen: Bool) {
        if rootIsOpen { collapsedRoots.insert(root) }
    }

    public mutating func groupOpened(in root: String) {
        collapsedRoots.remove(root)
    }
}
