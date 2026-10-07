import AppKit

/// A "⋯" button that opens a small menu, for the layout choices where they apply: on the terminal's tab
/// bar and in the project sidebar's header. The same choices are in the View menu.
final class MoreButton: NSButton {
    private let makeMenu: () -> NSMenu

    init(toolTip: String, menu: @escaping () -> NSMenu) {
        makeMenu = menu
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = Theme.textDim
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        target = self
        action = #selector(open)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func open() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

enum LayoutMenu {
    /// The terminal's ⋯: split the terminal, where the terminal goes, and the sidebar's side.
    static func terminal() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        for (title, action, id) in [("Split Right", #selector(TerminalWindowController.splitRight(_:)), "splitRight:"),
                                    ("Split Down", #selector(TerminalWindowController.splitDown(_:)), "splitDown:")] {
            let split = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            KeyboardShortcuts.set(KeyboardShortcuts.shared.chord(for: id), on: split)
        }
        menu.addItem(.separator())
        let heading = menu.addItem(withTitle: "Move Terminal To", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        for position in AppDelegate.TerminalPosition.allCases {
            let item = menu.addItem(withTitle: position.title, action: #selector(AppDelegate.setTerminalPosition(_:)), keyEquivalent: "")
            item.target = AppDelegate.shared
            item.representedObject = position.rawValue
            item.indentationLevel = 1
        }
        menu.addItem(.separator())
        sidebarItems(into: menu)
        return menu
    }

    /// The sidebar's ⋯: its side, how a click opens files, and hiding it.
    static func sidebar() -> NSMenu {
        let menu = NSMenu(title: "Project")
        sidebarItems(into: menu)
        let singleClick = menu.addItem(withTitle: "Open Files with a Single Click", action: #selector(AppDelegate.toggleSidebarSingleClick(_:)),
                                       keyEquivalent: "")
        singleClick.target = AppDelegate.shared
        singleClick.state = AppDelegate.shared.sidebarSingleClickOpens ? .on : .off // and AppDelegate.validateMenuItem keeps it so
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide Project Sidebar", action: #selector(TerminalWindowController.toggleProjectSidebar(_:)), keyEquivalent: "")
        // Shows the user's shortcut for it, whatever it is now.
        KeyboardShortcuts.set(KeyboardShortcuts.shared.chord(for: "toggleProjectSidebar:"), on: hide)
        return menu
    }

    private static func sidebarItems(into menu: NSMenu) {
        let right = AppDelegate.shared.sidebarSide == .right
        let item = menu.addItem(withTitle: right ? "Move Project Sidebar to the Left" : "Move Project Sidebar to the Right",
                                action: #selector(AppDelegate.toggleSidebarSide(_:)), keyEquivalent: "")
        item.target = AppDelegate.shared
    }
}
