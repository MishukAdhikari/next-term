import AppKit
import NextTermCore

/// Go to Anything (plan 034): ⌘K wherever a terminal doesn't have the keyboard (a terminal keeps ⌘K for Clear). A panel
/// over the window that lists every terminal tab, this window's first, then projects used before (GoToAnything), with a
/// search field: Return goes there, Escape or a click elsewhere closes it. Its first row is Clear Terminal, so ⌘K and
/// Return, pressed with the editor in front, still clears.
final class GoToAnythingPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var shown: GoToAnythingPanel?

    private let search = NSTextField()
    private let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No tab or project matches.")
    private var all: [GoToAnything.Item] = []
    private var items: [GoToAnything.Item] = []
    private weak var origin: TerminalWindowController?

    /// Whether it is open now (a nextterm://goto link opens it only when it isn't).
    static var isOpen: Bool { shown != nil }

    /// Opens over `controller`'s window (or alone with none), or closes it when it is open already.
    static func toggle(from controller: TerminalWindowController?) {
        if let open = shown {
            open.close()
            return
        }
        let panel = GoToAnythingPanel(origin: controller)
        shown = panel
        panel.present()
    }

    private init(origin: TerminalWindowController?) {
        self.origin = origin
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        level = .floating
        title = "Go to Anything"
        setAccessibilityLabel("Go to Anything")
        build()
        all = Self.gather(from: origin)
        refilter()
    }

    // MARK: what it lists

    /// Every terminal window's tabs, the one ⌘K came from first, then the others front to back; then projects used
    /// before that no window shows.
    private static func gather(from origin: TerminalWindowController?) -> [GoToAnything.Item] {
        let app: AppDelegate = AppDelegate.shared
        let open: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        let front: [TerminalWindowController] = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
        let ordered: [TerminalWindowController] = front.filter { open.contains($0) } + open.filter { !front.contains($0) }
        func shown(_ path: String) -> String { GoToAnything.shown(path) }
        func window(_ c: TerminalWindowController) -> GoToAnything.Window {
            let name: String = c.project.map { ($0 as NSString).lastPathComponent } ?? "~"
            let tabs: [GoToAnything.Tab] = c.tabs.map { tab in
                let program: String? = tab.status.running && !tab.status.program.isEmpty ? tab.status.program : nil
                let state: String? = tab.status.state == .idle ? nil : tab.status.state.rawValue
                return GoToAnything.Tab(id: tab.id.uuidString, title: tab.title, folder: shown(tab.directory), program: program, state: state)
            }
            return GoToAnything.Window(id: c.indexID, name: name, tabs: tabs)
        }
        let current: GoToAnything.Window? = origin.map(window)
        let others: [GoToAnything.Window] = ordered.filter { $0 !== origin }.map(window)
        let openPaths: Set<String> = Set(open.compactMap(\.project))
        let closed: [GoToAnything.Project] = ProjectHistoryRecorder.shared.history.entries
            .filter { !openPaths.contains($0.path) }
            .prefix(30)
            .map { GoToAnything.Project(path: $0.path, name: ($0.path as NSString).lastPathComponent) }
        let clears: Bool = origin?.activeTab != nil
        return GoToAnything.items(current: current, others: others, closed: Array(closed), clearsTerminal: clears)
    }

    private func refilter() {
        items = GoToAnything.filter(all, query: search.stringValue)
        table.reloadData()
        empty.isHidden = !items.isEmpty
        let row: Int? = search.stringValue.isEmpty ? GoToAnything.initialSelection(items) : (items.isEmpty ? nil : 0)
        if let row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    // MARK: going there

    private func choose(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let target: GoToAnything.Item.Target = items[row].target
        let from: TerminalWindowController? = origin
        close()
        let app: AppDelegate = AppDelegate.shared
        switch target {
        case .clearTerminal:
            guard let from, let tab = from.activeTab else { return }
            from.clear(tab)
        case .tab(let windowID, let tabID):
            guard let controller = app.controllers.first(where: { $0.indexID == windowID && !$0.hasClosed }),
                  let tab = controller.tabs.first(where: { $0.id.uuidString == tabID }) else { return }
            app.bringForward(windowID)
            controller.show(tab)
            controller.window?.makeFirstResponder(tab.view)
        case .project(let path):
            app.openFolder(path, newWindow: false)
        }
    }

    #if DEBUG
    /// For the self-test: the panel open now, the rows it shows, a search typed, and Return.
    static var open: GoToAnythingPanel? { shown }
    var shownTitles: [String] { items.map(\.title) }
    var selectedRow: Int { table.selectedRow }
    func type(_ text: String) {
        search.stringValue = text
        refilter()
    }
    func pressReturn() { choose(table.selectedRow) }
    #endif

    // MARK: the panel

    private func build() {
        let content = NSView()
        contentView = content
        // One field, Spotlight's way: large type on the panel itself, a hairline under it, no box drawn inside the box.
        search.placeholderString = "Go to a tab or project"
        search.delegate = self
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 18)
        search.isBezeled = false
        search.isBordered = false
        search.drawsBackground = false
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        let rule = NSBox()
        rule.boxType = .separator
        search.setAccessibilityLabel("Go to a tab or project")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        // Inset: rounded selections that line up with the field above.
        table.style = .inset
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.setAccessibilityLabel("Tabs and projects")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true
        for view in [glass, search, rule, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 20),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            rule.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
        ])
    }

    private func present() {
        if let window = origin?.window {
            let frame: NSRect = window.frame
            let x: CGFloat = frame.midX - self.frame.width / 2
            let y: CGFloat = frame.maxY - self.frame.height - min(120, frame.height / 6)
            setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            center()
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if isVisible { close() } // a click elsewhere
    }

    override func close() {
        super.close()
        if Self.shown === self { Self.shown = nil }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func rowDoubleClicked() { choose(table.clickedRow) }

    // MARK: the search field's keys

    func controlTextDidChange(_ notification: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard !items.isEmpty else { return }
        let row: Int = min(max(table.selectedRow + step, 0), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: rows

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item: GoToAnything.Item = items[row]
        let cell = NSTableCellView()
        // What the row is, as a symbol in the gutter: a command, a shell, an agent or a project.
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(item.kind), accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        // On the right: the tab's state as a dot, or Clear Terminal's key.
        let trailing: NSView
        if item.kind == .command {
            let key = NSTextField(labelWithString: KeyboardShortcuts.shared.chord(for: "clearBuffer:")?.display ?? "")
            key.font = .systemFont(ofSize: 12)
            key.textColor = .tertiaryLabelColor
            trailing = key
        } else {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = Self.color(item.state).cgColor
            dot.isHidden = item.state == nil
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            trailing = dot
        }
        for view in [icon, lines, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            lines.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            lines.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(item.title + ", " + item.detail + (item.state.map { ", " + $0 } ?? ""))
        return cell
    }

    private static func symbol(_ kind: GoToAnything.Item.Kind) -> String {
        switch kind {
        case .command: return "eraser"
        case .shell: return "apple.terminal"
        case .agent: return "sparkles"
        case .project: return "folder"
        }
    }

    /// A tab's mark as its colour: amber for a decision, red for a failure, green done, blue working.
    private static func color(_ state: String?) -> NSColor {
        switch state {
        case "attention": return .systemOrange
        case "failed": return .systemRed
        case "done": return .systemGreen
        case "working": return .systemBlue
        default: return .clear
        }
    }
}

/// The once-only choice after a second ⌘K in a terminal (plan 034): keep ⌘K for Clear there, or give ⌘K to Go to
/// Anything everywhere, Clear moving to ⇧⌘K in a terminal. Asked after the clear, never before it; Settings › Keyboard
/// Shortcuts changes either key later.
enum ClearKeyChoice {
    static let countKey = "clearKeyPresses"
    static let askedKey = "clearKeyChoiceAsked"

    /// A clear in a terminal, by ⌘K: the second one asks, once.
    static func noteClear(in controller: TerminalWindowController) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey), !SelfTest.isRequested,
              KeyboardShortcuts.shared.chord(for: "clearBuffer:") == KeyChord(key: "k", command: true),
              KeyboardShortcuts.shared.chord(for: "goToAnything:") == KeyChord(key: "k", command: true) else { return }
        let count: Int = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        guard count >= 2, let window = controller.window else { return }
        defaults.set(true, forKey: askedKey)
        DispatchQueue.main.async { ask(over: window) }
    }

    private static func ask(over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "\u{2318}K cleared the terminal."
        alert.informativeText = "Outside a terminal, \u{2318}K opens Go to Anything: every tab and project by name. "
            + "It can open Go to Anything in a terminal too, with Clear Terminal on \u{21E7}\u{2318}K there. "
            + "Settings \u{203A} Keyboard Shortcuts changes either key later."
        alert.addButton(withTitle: "Keep \u{2318}K for Clear")
        alert.addButton(withTitle: "Use \u{2318}K for Go to Anything")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            KeyboardShortcuts.shared.set(KeyChord(key: "k", command: true, shift: true), for: "clearBuffer:")
        }
    }
}
