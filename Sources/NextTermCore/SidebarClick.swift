import Foundation

/// "Open files and folders with a single click" (Settings › Editor): which clicks in the project sidebar open a
/// file, in a preview tab, which open or close a folder, and which only select their row. Apart from AppKit, so it
/// can be tested.
public enum SidebarClick {
    /// Text files over this only select on a click: the editor reads a file whole, on the main thread, and
    /// a click is easy to make by accident. A double-click or ⌘↓ still opens them.
    public static let singleClickMaxSize = 4 << 20

    /// `open`: the file opens in the preview tab. `toggle`: the folder opens, or closes if it is open.
    public enum Outcome: Equatable, Sendable { case open, toggle, selectOnly }

    /// What the clicked row is. `deleted` is a deleted file, whose double-click shows what was removed, and
    /// `deletedFolder` a deleted folder, which opens and closes as a folder does. A Services row (`service`) opens
    /// its page from its badge, a double-click or ⌘↓.
    public enum Row: Equatable, Sendable { case file, folder, root, deleted, deletedFolder, database, service, other }

    /// A click as the outline reports it when it sends its action, on mouse-up.
    public struct Click: Equatable, Sendable {
        public var isMouseUp: Bool
        public var clickCount: Int
        public var command: Bool
        public var shift: Bool
        public var option: Bool
        public var control: Bool
        /// The row under the mouse-up (-1: the empty space below the rows).
        public var row: Int
        /// The row the mouse went down on: a different one means the click dragged across rows.
        public var mouseDownRow: Int
        public var selection: IndexSet
        /// A file drag started from the row.
        public var dragBegan: Bool
        /// A rename was going on when the mouse went down: the click only ends it.
        public var wasRenaming: Bool
        public var kind: Row

        public init(isMouseUp: Bool = true, clickCount: Int = 1, command: Bool = false, shift: Bool = false, option: Bool = false,
                    control: Bool = false, row: Int, mouseDownRow: Int, selection: IndexSet, dragBegan: Bool = false,
                    wasRenaming: Bool = false, kind: Row) {
            self.isMouseUp = isMouseUp
            self.clickCount = clickCount
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
            self.row = row
            self.mouseDownRow = mouseDownRow
            self.selection = selection
            self.dragBegan = dragBegan
            self.wasRenaming = wasRenaming
            self.kind = kind
        }
    }

    /// Whether the click opens its file, or opens or closes its folder (a deleted one too). The second click of a
    /// double-click, a click with a modifier (⌘ and ⇧ select several, ⌥ copies when dragging, ⌃ is the
    /// right-click), a drag across rows or out of the tree, a click that ends a rename, a click on several selected
    /// rows, and every other row (the project's own, which would hide the whole tree, a deleted file, Databases,
    /// Services and the group headers) only select.
    public static func outcome(of click: Click) -> Outcome {
        guard click.isMouseUp, click.clickCount == 1 else { return .selectOnly }
        guard !click.command, !click.shift, !click.option, !click.control else { return .selectOnly }
        guard !click.dragBegan, !click.wasRenaming else { return .selectOnly }
        guard click.row >= 0, click.row == click.mouseDownRow else { return .selectOnly }
        guard click.selection == IndexSet(integer: click.row) else { return .selectOnly }
        switch click.kind {
        case .file: return .open
        case .folder, .deletedFolder: return .toggle
        case .root, .deleted, .database, .service, .other: return .selectOnly
        }
    }

    /// Whether a single click may open the file: one the editor shows itself, up to 4 MB, or one that
    /// opens in a read-only viewer at any size (a SQLite file, a large data file in the head view).
    /// Anything else (images, binaries, bigger files) would mean reading it all or handing it to another
    /// app, which a stray click must never do. A link is judged by the file it points to, which is what
    /// the editor opens: the size of the link itself says nothing.
    public static func opensOnSingleClick(_ path: String) -> Bool {
        let path = canonicalPath(path)
        guard isRegularFile(path) else { return false }
        if Databases.opensInViewer(path) || DataHead.opensInView(path) { return true }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max
        guard size <= singleClickMaxSize else { return false }
        return Notebook.isNotebook(path) || DataHead.isText(path)
    }
}
