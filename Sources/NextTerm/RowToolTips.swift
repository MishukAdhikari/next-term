import AppKit

/// Row tooltips for a list, the way the project sidebar has them: one tooltip area over the rows in view,
/// which asks for the text of the row under the pointer when the tooltip shows. Tooltips set on the row
/// views themselves stay live for rows scrolled out of sight, so hovering the search field above a list
/// could show some hidden row's text.
final class RowToolTips: NSObject {
    private weak var table: NSTableView?
    private let text: (Int) -> String
    private var scheduled = false

    /// `text`: a row's tooltip ("" for none). The area follows scrolling and resizing by itself; call
    /// `update()` after the rows change.
    init(_ table: NSTableView, in scroll: NSScrollView, text: @escaping (Int) -> String) {
        self.table = table
        self.text = text
        super.init()
        RowToolTipOwner.shared.lists.setObject(self, forKey: table)
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: table)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// What AppKit would be told for `view`'s tooltip at `point`, through the app-long owner (the self-test).
    static func toolTip(for view: NSView, at point: NSPoint) -> String {
        RowToolTipOwner.shared.view(view, stringForToolTip: 0, point: point, userData: nil)
    }

    /// On the next turn of the run loop, never at once: frames change during AppKit's display pass, and
    /// replacing a view's tooltips while that pass reads them frees the tooltip it is reading (a crash).
    @objc func update() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            guard let table else { return }
            table.removeAllToolTips()
            table.addToolTip(table.visibleRect, owner: RowToolTipOwner.shared, userData: nil)
        }
    }

    /// The tooltip for the row under the pointer (what AppKit is given; the self-test asks it too).
    func string(at point: NSPoint) -> String {
        guard let table else { return "" }
        let row = table.row(at: point)
        guard row >= 0, table.visibleRect.contains(point) else { return "" }
        return text(row)
    }
}

/// The owner AppKit asks for a list's tooltip. AppKit doesn't keep a tooltip's owner alive, so it is one
/// object for the app's life, never freed; it finds the list's RowToolTips, and a list that has gone has
/// none to show.
private final class RowToolTipOwner: NSObject {
    static let shared = RowToolTipOwner()
    let lists = NSMapTable<NSView, RowToolTips>.weakToWeakObjects()

    /// NSViewToolTipOwner.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        lists.object(forKey: view)?.string(at: point) ?? ""
    }
}
