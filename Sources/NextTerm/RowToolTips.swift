import AppKit

/// Row tooltips for a list, the way the project sidebar has them: one tooltip area over the rows in view,
/// owned by this, which asks for the text of the row under the pointer when the tooltip shows. Tooltips
/// set on the row views themselves stay live for rows scrolled out of sight, so hovering the search field
/// above a list could show some hidden row's text.
final class RowToolTips: NSObject {
    private weak var table: NSTableView?
    private let text: (Int) -> String

    /// `text`: a row's tooltip ("" for none). The area follows scrolling and resizing by itself; call
    /// `update()` after the rows change.
    init(_ table: NSTableView, in scroll: NSScrollView, text: @escaping (Int) -> String) {
        self.table = table
        self.text = text
        super.init()
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: table)
    }

    @objc func update() {
        guard let table else { return }
        table.removeAllToolTips()
        table.addToolTip(table.visibleRect, owner: self, userData: nil)
    }

    /// The tooltip for the row under the pointer (NSViewToolTipOwner).
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let table else { return "" }
        let row = table.row(at: point)
        guard row >= 0, table.visibleRect.contains(point) else { return "" }
        return text(row)
    }
}
