import AppKit
import NextTermCore

/// Tasks › Connect a Tracker to Your Agents…: per tracker, each agent's own line to add the tracker's MCP server, as
/// that agent's or that tracker's own page prints it (TrackerLines). Open in a New Tab types the line into a new tab in
/// the home folder with no Return; the user reads it and presses Return, and signing in happens in the agent after.
/// Next Term runs no agent, reads and writes no agent's config, and makes no request: a page opens in the browser only
/// on a click. Pairs with no such line are shown with why, never with a guessed line.
///
/// From the moment the line is typed until the tab closes, agents can't type into that tab, press its keys, answer in
/// it or close it (`MCPInputLine`): an agent could otherwise change the line before the Return, or press it.
@MainActor
final class ConnectTrackerSheet: NSWindowController, NSWindowDelegate {
    static let title = "Connect a Tracker to Your Agents"
    static let intro = "Each line is your agent\u{2019}s own command. Next Term types it into a new tab and doesn\u{2019}t "
        + "run it; you read it and press Return. Signing in happens in the agent afterwards."
    static let openTitle = "Open in a New Tab"
    static let notFound = "Not found on this Mac"
    static let notListed = "Not listed yet:"
    static let typedLine = "The line is in a new tab, not run. Read it there, then press Return."
    static let notTyped = "Next Term couldn\u{2019}t type the line in the new tab. Copy it instead."
    static let notAtPrompt = "The new tab\u{2019}s shell didn\u{2019}t reach its prompt, so Next Term didn\u{2019}t type "
        + "the line. Copy it instead."
    static let lock = "That tab is Connect a Tracker: the user runs their agent\u{2019}s add command there, so agents "
        + "can\u{2019}t act on it."

    /// The sheet while it is open.
    private(set) static var current: ConnectTrackerSheet?
    /// The tabs a line was typed into, by id: refused to agents until they close.
    private(set) static var tabs: Set<UUID> = []

    let trackers: [TrackerLines.Tracker] = TrackerLines.shown
    private(set) var tracker: TrackerLines.Tracker
    /// The agents whose program is on the login shell's PATH; nil until the look is done.
    var found: Set<AgentKind>?
    let trackerPopup = NSPopUpButton()
    let rows = NSStackView()
    let status = NSTextField(wrappingLabelWithString: "")
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// Each row's controls, by agent, as the last build made them.
    var rowViews: [AgentKind: RowViews] = [:]
    /// The rows under "Not listed yet:", one per tracker with no line.
    var heldLabels: [NSTextField] = []

    struct RowViews {
        let line: NSTextField
        let copy: NSButton?
        let open: NSButton?
        let notFound: NSTextField?
        let link: NSButton?
        /// The sentences under the line: its sign-in step and the tracker's note.
        let notes: [NSTextField]
    }

    init() {
        tracker = TrackerLines.shown[0]
        let frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = Self.title
        super.init(window: window)
        window.delegate = self
        build()
        lookForAgents()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The sheet over `parent`, on top of any sheet already there (Add Task's), or on its own when there is no parent;
    /// one at a time. A sheet whose window went away with its parent's is forgotten and a fresh one shown.
    static func present(over parent: NSWindow?) {
        if let current, let window = current.window {
            if window.isVisible || window.sheetParent != nil { return window.makeKeyAndOrderFront(nil) }
            Self.current = nil
        }
        let sheet = ConnectTrackerSheet()
        current = sheet
        guard let window = sheet.window else { return }
        var host: NSWindow? = parent
        while let above = host?.attachedSheet { host = above }
        if let host {
            host.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: the tabs

    /// Why agents can't act on a tab a line was typed into, or nil for any other tab.
    static func inputRefusal(_ tab: TerminalTab) -> String? {
        tabs.contains(tab.id) ? lock : nil
    }

    /// From now until the tab closes, agents can't act on it. Tabs closed since are let go. The rule goes into
    /// MCPInputLine's whenever it isn't there, so a list put back from an earlier copy doesn't drop it for good.
    static func register(_ tab: TerminalTab) {
        let open: Set<UUID> = Set(AppDelegate.shared.controllers.flatMap(\.tabs).map(\.id))
        tabs = tabs.intersection(open)
        tabs.insert(tab.id)
        let held: Bool = MCPInputLine.rules.contains { (rule: (TerminalTab) -> String?) -> Bool in rule(tab) == lock }
        if !held { MCPInputLine.rules.append { (tab: TerminalTab) -> String? in ConnectTrackerSheet.inputRefusal(tab) } }
    }

    // MARK: choosing

    @objc func trackerChanged() {
        let index: Int = trackerPopup.indexOfSelectedItem
        guard trackers.indices.contains(index) else { return }
        tracker = trackers[index]
        status.stringValue = ""
        fillRows()
    }

    /// Picks the tracker by name, as the popup would.
    func choose(_ name: String) {
        guard let index = trackers.firstIndex(where: { $0.name == name }) else { return }
        trackerPopup.selectItem(at: index)
        trackerChanged()
    }

    func say(_ text: String) { status.stringValue = text }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }

    @objc func done() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        if Self.current === self { Self.current = nil }
    }
}
