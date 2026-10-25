import AppKit
import NextTermCore

// MARK: - the path over the home folder's tree

/// Over the tree while a window with no project browses the home folder (ProjectSidebarView.setRoot's `breadcrumbs`):
/// Back, which returns to "No project open", then the path from Home to the folder of the selected row, each folder a
/// button that selects its row. Made from the path strings the tree holds (Breadcrumbs.segments), so it reads nothing on
/// disk. Short of room, the folders after Home fold into "…", a menu of them, then Home shows its symbol alone, then the
/// last folder's name is cut in the middle (Breadcrumbs.fit). Drawn as the notes above it are.
final class BreadcrumbBar: NSView {
    static let height: CGFloat = 28
    /// A chevron between two buttons, with the room around it.
    private static let separatorWidth: CGFloat = 12

    let backButton = BreadcrumbButton(title: "Back", symbol: "chevron.left", showsTitle: false)
    private let moreButton = BreadcrumbButton(title: "…")
    private var buttons: [BreadcrumbButton] = []
    private var separators: [NSImageView] = []
    /// The path shown: Home first.
    private(set) var segments: [Breadcrumbs.Segment] = []
    private var fit = Breadcrumbs.Fit(folded: 1..<1, homeSymbolOnly: false)
    /// Back was clicked.
    var onBack: (() -> Void)?
    /// A folder was clicked, or chosen from "…": its path.
    var onSelect: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        backButton.toolTip = "Back to “No project open”"
        backButton.setAccessibilityHelp("Shows No project open and your recent projects again")
        backButton.target = self
        backButton.action = #selector(back)
        moreButton.setAccessibilityLabel("More folders")
        moreButton.target = self
        moreButton.action = #selector(showFolded)
        moreButton.isHidden = true
        addSubview(backButton)
        addSubview(moreButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Folder path")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The path to show, Home first. The same path again changes nothing. The buttons are kept and given the new path's
    /// names: one clicked may be what changes the path, and it is still in its click.
    func show(_ path: [Breadcrumbs.Segment]) {
        guard path != segments, let home = path.first?.path else { return }
        segments = path
        while buttons.count < path.count {
            let button = BreadcrumbButton(title: "", symbol: buttons.isEmpty ? "house" : nil)
            button.setAccessibilityHelp("Selects this folder in the tree")
            button.tag = buttons.count
            button.target = self
            button.action = #selector(select(_:))
            addSubview(button)
            buttons.append(button)
        }
        // One between each two shown: "…" shows only in place of at least one folder.
        while separators.count < path.count - 1 {
            let chevron = NSImageView()
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
            chevron.contentTintColor = Theme.textDim
            chevron.setAccessibilityElement(false)
            addSubview(chevron)
            separators.append(chevron)
        }
        for (index, segment) in path.enumerated() {
            let button = buttons[index]
            button.show(segment.title, isLast: index == path.count - 1)
            if index == 0 {
                button.toolTip = "\(segment.title), the home folder (~)"
                button.setAccessibilityLabel("Home folder, \(segment.title)")
            } else {
                button.toolTip = RecentProjects.abbreviate(segment.path, home: home)
                button.setAccessibilityLabel(segment.title)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 22
        let y: CGFloat = ((bounds.height - 1 - height) / 2).rounded(.down)
        backButton.frame = NSRect(x: 8, y: y, width: 22, height: height)
        let start: CGFloat = backButton.frame.maxX + 4, end: CGFloat = bounds.width - 8
        let path: [BreadcrumbButton] = Array(buttons.prefix(segments.count))
        guard let home = path.first else {
            (buttons + [moreButton]).forEach { $0.isHidden = true }
            separators.forEach { $0.isHidden = true }
            return
        }
        fit = Breadcrumbs.fit(widths: path.map { Double($0.wholeWidth) }, homeSymbolWidth: Double(home.symbolWidth),
                              separator: Double(Self.separatorWidth), more: Double(moreButton.wholeWidth), room: Double(max(0, end - start)))
        home.showsTitle = !fit.homeSymbolOnly
        for (index, button) in buttons.enumerated() { button.isHidden = index >= path.count || fit.folded.contains(index) }
        moreButton.isHidden = fit.folded.isEmpty
        if !fit.folded.isEmpty, segments.indices.contains(fit.folded.upperBound) {
            moreButton.setAccessibilityHelp("Lists the folders between the home folder and \(segments[fit.folded.upperBound].title)")
            moreButton.toolTip = fit.folded.map { segments[$0].title }.joined(separator: " › ")
        }
        // Home, "…" for the folded, then the rest; the last takes what room is left.
        var shown: [BreadcrumbButton] = [home]
        if !fit.folded.isEmpty { shown.append(moreButton) }
        shown += path.indices.dropFirst().filter { !fit.folded.contains($0) }.map { path[$0] }
        var x: CGFloat = start
        for (index, button) in shown.enumerated() {
            if index > 0 {
                separators[index - 1].frame = NSRect(x: x, y: y, width: Self.separatorWidth, height: height)
                x += Self.separatorWidth
            }
            let wanted: CGFloat = button === home && fit.homeSymbolOnly ? home.symbolWidth : button.wholeWidth
            let width: CGFloat = index == shown.count - 1 ? max(0, min(wanted, end - x)) : wanted
            button.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width
        }
        for (index, separator) in separators.enumerated() { separator.isHidden = index >= shown.count - 1 }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.tabHover.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func back() { onBack?() }

    @objc private func select(_ sender: BreadcrumbButton) {
        guard segments.indices.contains(sender.tag) else { return }
        onSelect?(segments[sender.tag].path)
    }

    /// "…": the folded folders, in the path's order, under it.
    @objc private func showFolded() {
        guard let home = segments.first?.path else { return }
        let menu = NSMenu()
        for index in fit.folded where segments.indices.contains(index) {
            let segment = segments[index]
            let item = menu.addItem(withTitle: segment.title, action: #selector(choseFolded(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = segment.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.toolTip = RecentProjects.abbreviate(segment.path, home: home)
        }
        let below: CGFloat = moreButton.isFlipped ? moreButton.bounds.maxY + 2 : -2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: moreButton)
    }

    @objc private func choseFolded(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { onSelect?(path) }
    }

    // MARK: for the self-test

    /// What the bar shows, in order: Home's name ("" while it shows its symbol alone), "…" where folders fold, the rest.
    var shownTitles: [String] {
        guard !segments.isEmpty, let home = buttons.first else { return [] }
        var titles: [String] = [fit.homeSymbolOnly ? "" : home.title]
        if !fit.folded.isEmpty { titles.append(moreButton.title) }
        return titles + buttons.prefix(segments.count).dropFirst().filter { !$0.isHidden }.map(\.title)
    }

    /// The button of `segments[index]`.
    func segmentButton(at index: Int) -> NSButton? { segments.indices.contains(index) ? buttons[index] : nil }
}

/// A button of the bar: a symbol, a name, or both, in a fill under the pointer as the No-project rows have. The last
/// folder of the path is in the text colour and medium weight, the others dimmed; a name cut short loses its middle.
final class BreadcrumbButton: FillButton {
    private static let padding: CGFloat = 6
    private static let gap: CGFloat = 4
    private let icon: NSImageView?
    private let label = NSTextField(labelWithString: "")
    /// The name shows beside the symbol (Home's goes when the bar is short of room).
    var showsTitle: Bool { didSet { if showsTitle != oldValue { label.isHidden = !showsTitle; needsLayout = true } } }

    init(title name: String, symbol: String? = nil, showsTitle: Bool = true) {
        self.showsTitle = showsTitle
        icon = symbol.map { (symbol: String) -> NSImageView in
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: showsTitle ? .regular : .medium))
            return view
        }
        super.init(title: name)
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        label.isHidden = !showsTitle
        show(name, isLast: false)
        // Laid out by frames, and silent to VoiceOver: the button is heard, by its own label.
        for view in [icon, label].compactMap({ $0 }) as [NSView] {
            view.setAccessibilityElement(false)
            (view as? NSControl)?.cell?.setAccessibilityElement(false)
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Its name, and whether it is the path's last folder.
    func show(_ name: String, isLast: Bool) {
        title = name
        setAccessibilityLabel(name)
        let color: NSColor = isLast ? Theme.text : Theme.textDim
        icon?.contentTintColor = color
        label.stringValue = name
        label.font = .systemFont(ofSize: 11.5, weight: isLast ? .medium : .regular)
        label.textColor = color
        needsLayout = true
    }

    private var iconWidth: CGFloat { icon.map { ceil($0.image?.size.width ?? 0) } ?? 0 }
    private var labelWidth: CGFloat { ceil(label.cell?.cellSize.width ?? 0) }

    /// Its width with its symbol and its name whole, shown or not.
    var wholeWidth: CGFloat {
        let symbol: CGFloat = icon == nil ? 0 : iconWidth + Self.gap
        return Self.padding + symbol + labelWidth + Self.padding
    }

    /// Its width with its symbol alone.
    var symbolWidth: CGFloat { Self.padding + iconWidth + Self.padding }

    override func layout() {
        super.layout()
        guard showsTitle else {
            icon?.frame = bounds
            return
        }
        var x: CGFloat = Self.padding
        if let icon {
            icon.frame = NSRect(x: x, y: 0, width: iconWidth, height: bounds.height)
            x += iconWidth + Self.gap
        }
        let height: CGFloat = ceil(label.cell?.cellSize.height ?? bounds.height)
        label.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(.down), width: max(0, bounds.width - x - Self.padding), height: height)
    }
}

// MARK: - the sidebar's side

extension ProjectSidebarView {
    /// Shows or hides the bar over the tree; `refreshBreadcrumbs` gives it its path.
    func showBreadcrumbs(_ shown: Bool) {
        guard breadcrumbs.isHidden == shown else { return }
        breadcrumbs.isHidden = !shown
        needsLayout = true
    }

    /// The bar follows the selection: the path from the root (the home folder) to the folder of the selected row.
    func refreshBreadcrumbs() {
        guard !breadcrumbs.isHidden, let root else { return }
        breadcrumbs.show(Breadcrumbs.segments(to: selectedFolder(in: root).path, home: root.path))
    }

    /// The folder of the row selected last: a folder itself, the folder a file or any other row is in, the root with none.
    private func selectedFolder(in root: FileNode) -> FileNode {
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return root }
        if let node = item as? FileNode, node.isDirectory { return node }
        return enclosingFolder(of: item) ?? root
    }

    /// The folder row a row is under: the nearest folder above it (a Databases or Agent Sessions row's is the root).
    private func enclosingFolder(of item: Any) -> FileNode? {
        var above: Any? = outline.parent(forItem: item)
        while let item = above, !(item is FileNode) { above = outline.parent(forItem: item) }
        return above as? FileNode
    }

    /// ⌘↑, Select Enclosing Folder: the row of the folder the selected row is in, among the rows the tree shows (the root's
    /// with none selected). From the root's row it goes back to "No project open" while the bar shows, and elsewhere does
    /// nothing. Nothing is opened, closed or read.
    func selectEnclosingFolder() {
        guard let root else { return }
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return selectRow(of: root) }
        guard item as AnyObject !== root else {
            if !breadcrumbs.isHidden { onLeaveBrowsing?() }
            return
        }
        selectRow(of: enclosingFolder(of: item) ?? root)
    }

    /// A folder of the bar, clicked: its row selected and scrolled into view, and the tree given the keyboard, so ⌘↑ goes on
    /// from there. Its row is always there, above the selected one; it is never opened, closed or read (reveal could).
    func selectFolder(_ path: String) {
        window?.makeFirstResponder(outline) // a name being edited is done first, as a click elsewhere would end it
        guard let node = root?.node(at: path) else { return }
        selectRow(of: node)
    }

    private func selectRow(of node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }
}
