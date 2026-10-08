import AppKit
import NextTermCore

/// Where the app reads agent sessions from, and how it resumes one. The self-test points these at its
/// own sessions and makes the command harmless.
enum SessionStore {
    nonisolated(unsafe) static var home = NSHomeDirectory()
    /// Put before every resume command (the self-test's "echo ").
    nonisolated(unsafe) static var commandPrefix = ""
    private static let queue = DispatchQueue(label: "nextterm.sessions", qos: .userInitiated)

    /// The sessions for a project (its subfolders included), and the tabs any of them are open in, off the
    /// main thread.
    static func load(_ project: String, done: @escaping (AgentSessions.Listing, SessionTabs) -> Void) {
        let home = self.home
        let running = runningAgents()
        queue.async {
            let listing = AgentSessions.list(project: project, home: home, subfolders: true)
            let open = AgentSessions.openSessions(running, home: home)
            DispatchQueue.main.async { done(listing, SessionTabs(open: open)) }
        }
    }

    /// The agents running in this Mac's tabs, each with when it started and the command that started it.
    static func runningAgents() -> [RunningAgent] {
        guard let app = AppDelegate.shared else { return [] }
        return app.controllers.flatMap(\.tabs).compactMap { tab -> RunningAgent? in
            let status = tab.status
            guard tab.remote == nil, status.running, status.kind == .agent, let since = status.runningSince,
                  let agent = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
            else { return nil }
            let line = status.expandedCommand.isEmpty ? status.command : status.command + " ; " + status.expandedCommand
            // The agent leads the pty's foreground group: its folder is its own (`cd web && codex` runs in
            // web), and by its process Claude Code and Copilot CLI say which session it has open.
            let pgid = tcgetpgrp(tab.view.process.childfd)
            let folder = (pgid > 0 ? ProcessInspector.currentDirectory(of: pgid) : nil) ?? tab.currentDirectory()
            return RunningAgent(key: tab.id.uuidString, agent: agent, directory: folder, commandLine: line,
                                startedAt: startDate(of: tab, since: since), pid: pgid > 0 ? pgid : nil)
        }
    }

    /// When the agents in tabs started, by the wall clock.
    nonisolated(unsafe) static var agentStarts = AgentStarts()

    /// When `tab`'s agent, which the tab saw start at `since` on its uptime clock, started by the wall clock:
    /// worked out the first time it is asked (on the refresh right after the start) and kept, so a sleep
    /// after that does not move it on.
    static func startDate(of tab: TerminalTab, since: TimeInterval) -> Date {
        agentStarts.date(of: tab.id.uuidString, since: since, uptime: TerminalTab.now)
    }

    /// "main", from .git/HEAD (a worktree's .git file points to its own HEAD). No git process.
    static func branch(of folder: String) -> String? {
        let git = (folder as NSString).appendingPathComponent(".git")
        var headPath = (git as NSString).appendingPathComponent("HEAD")
        if isRegularFile(git), let text = try? String(contentsOfFile: git, encoding: .utf8), text.hasPrefix("gitdir: ") {
            var dir = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            if !dir.hasPrefix("/") { dir = (folder as NSString).appendingPathComponent(dir) }
            headPath = (dir as NSString).appendingPathComponent("HEAD")
        }
        guard isRegularFile(headPath), let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst(16)) }
        return line.count >= 7 ? String(line.prefix(7)) : nil // detached: the commit
    }

    /// "just now", "12 min ago", "3 h ago", "yesterday", "Tue", "Sep 14".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600)) h ago" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(seconds < 6 * 86400 ? "EEE" : calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }

    static func color(_ agent: AgentKind) -> NSColor {
        switch agent {
        case .claude: return NSColor(hex: 0xD97757)
        case .codex: return NSColor(hex: 0x6EA4F7)
        case .commandCode: return NSColor(hex: 0xB48EF0)
        case .gemini: return NSColor(hex: 0x4CC2A8)
        case .qwen: return NSColor(hex: 0xE07AB8)
        case .opencode: return NSColor(hex: 0xE2C35C)
        case .cursor: return NSColor(hex: 0xA3AAB8)
        case .copilot: return NSColor(hex: 0x5FC8E8)
        }
    }
}

/// Which sessions are open in which of this Mac's tabs (from `AgentSessions.openSessions`).
struct SessionTabs {
    var open: [String: String] = [:]

    /// The tab `session` is open in, while that tab still runs an agent.
    func tab(of session: AgentSession) -> (controller: TerminalWindowController, tab: TerminalTab)? {
        guard let key = AgentSessions.tab(of: session, in: open), let app = AppDelegate.shared else { return nil }
        for controller in app.controllers {
            if let tab = controller.tabs.first(where: { $0.id.uuidString == key }), tab.status.running, tab.status.kind == .agent {
                return (controller, tab)
            }
        }
        return nil
    }
}

/// One session in a list: its title on the first line; the agent (with its colour), when, the branch and
/// the model on the second. A session open in a tab, or in an agent running elsewhere, says so.
final class SessionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SessionCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(title, truncation: .byTruncatingTail)
        Typography.singleLine(detail, truncation: .byTruncatingTail)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        for view in [dot, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ session: AgentSession, project: String?, inTab: Bool = false) {
        // A name you gave it reads a little stronger than one the agent made up.
        title.attributedStringValue = NSAttributedString(string: session.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: session.named ? .semibold : .regular), .foregroundColor: Theme.text,
        ])
        dot.layer?.backgroundColor = SessionStore.color(session.agent).cgColor
        var parts = [session.agent.name, SessionStore.when(session.updatedAt)]
        if let project, session.cwd != project, session.cwd.hasPrefix(project + "/") {
            parts.append(String(session.cwd.dropFirst(project.count + 1))) // started in a subfolder
        }
        if let branch = session.gitBranch { parts.append("⎇ " + branch) }
        if let model = session.model { parts.append(model) }
        let text = NSMutableAttributedString()
        if inTab || session.isRunning {
            text.append(NSAttributedString(string: inTab ? "● open in a tab   " : "● open in a running agent   ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.done,
            ]))
        }
        text.append(NSAttributedString(string: parts.joined(separator: "  ·  "), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim,
        ]))
        detail.attributedStringValue = text
        let command = SessionStore.commandPrefix + session.resumeCommand()
        toolTip = session.title + "\n" + session.cwd + "\n" + (inTab ? "Open in a tab now" : command)
        let state = inTab ? ", open in a tab" : session.isRunning ? ", open in a running agent" : ""
        setAccessibilityLabel("\(session.title), \(session.agent.name), \(SessionStore.when(session.updatedAt))" + state)
    }
}

extension AppDelegate {
    /// Picks a session up again: the project's window (opened if needed), a new tab in the folder the
    /// agent worked in, and its resume command typed and run there. A session already open in a tab goes
    /// to that tab instead of starting a second copy of it (`tabs`); a fork always gets a tab of its own.
    func resume(_ session: AgentSession, fork: Bool, project: String, tabs: SessionTabs = SessionTabs()) {
        if !fork, let open = tabs.tab(of: session) { return goTo(open.tab, in: open.controller) }
        let controller = openFolder(project, newWindow: false)
        let exists = FileManager.default.fileExists(atPath: session.cwd)
        let command = SessionStore.commandPrefix + session.resumeCommand(fork: fork)
        controller.runInNewTab(directory: exists ? session.cwd : project, command: command, title: nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings a tab and its window to the front.
    func goTo(_ tab: TerminalTab, in controller: TerminalWindowController) {
        controller.show(tab)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// ⌥⌘O in a project window: the project's agent sessions, newest first; type to filter, ↩ resumes (or goes
/// to the tab the session is open in), ⌘↩ forks (a copy, leaving the original as it was).
final class SessionsPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onResume: ((AgentSession, _ fork: Bool) -> Void)?
    private let panel = GoToFilePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 100), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private let hints = NSTextField(labelWithString: "")
    private var all: [AgentSession] = []
    private var rows: [AgentSession] = []
    private var tabs = SessionTabs()
    private var project = ""

    override init() {
        super.init()
        build()
    }

    func show(project: String, over parent: NSWindow) {
        self.project = canonicalPath(project)
        field.stringValue = ""
        all = []
        rows = []
        tabs = SessionTabs()
        table.reloadData()
        updateHints()
        footer.stringValue = "Reading sessions…"
        let frame = parent.frame
        let width = min(640, frame.width - 40)
        let height: CGFloat = 52 + 46 * 9 + 30
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 72 - height, width: width, height: height), display: false)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        let requested = self.project
        SessionStore.load(requested) { [weak self] listing, tabs in
            guard let self, self.project == requested, self.panel.isVisible else { return }
            self.all = listing.sessions
            self.tabs = tabs
            self.filter()
            if !listing.problems.isEmpty {
                self.footer.stringValue += "   Could not read: " + listing.problems.keys.map(\.name).sorted().joined(separator: ", ")
            }
        }
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
    var shownTitles: [String] { rows.map(\.title) }
    var panelWindow: NSWindow { panel }
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; filter() }
    }

    private func filter() {
        let words = field.stringValue.lowercased().split(separator: " ")
        rows = words.isEmpty ? all : all.filter { session in
            let haystack = (session.title + " " + session.agent.name + " " + (session.gitBranch ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let name = (project as NSString).lastPathComponent
        footer.stringValue = all.isEmpty ? "No agent sessions in \(name) yet."
            : "\(rows.count) of \(all.count) sessions in \(name)"
        updateHints()
    }

    /// What ↩ and ⌘↩ do for the selected session: go to its tab when it is open in one, and no fork for
    /// an agent that cannot.
    private func updateHints() {
        let session = rows[safe: table.selectedRow]
        let inTab = session.map { tabs.tab(of: $0) != nil } ?? false
        var parts = [inTab ? "↩ go to tab" : "↩ resume"]
        if session?.agent.canFork != false { parts.append("⌘↩ fork") }
        parts.append("esc close")
        hints.stringValue = parts.joined(separator: "   ")
    }

    var hintText: String { hints.stringValue }

    func tableViewSelectionDidChange(_ notification: Notification) { updateHints() }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            resumeSelected(fork: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, max(0, table.selectedRow) + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() { resumeSelected(fork: false) }

    func resumeSelected(fork: Bool) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        let session = rows[row]
        if fork, !session.agent.canFork {
            footer.stringValue = "\(session.agent.name) cannot fork a session from the command line."
            return NSSound.beep()
        }
        close()
        if !fork, let open = tabs.tab(of: session) { return AppDelegate.shared.goTo(open.tab, in: open.controller) }
        onResume?(session, fork)
    }

    private func build() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.bar.cgColor
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = Theme.textDim
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: "Resume an agent session", attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor,
        ])
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = WorkSplitView.line
        table.addTableColumn(NSTableColumn(identifier: .init("session")))
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textDim
        footer.lineBreakMode = .byTruncatingTail
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = Theme.textDim
        for view in [glass, field, rule, scroll, footer, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 18),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            rule.topAnchor.constraint(equalTo: background.topAnchor, constant: 51),
            rule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -12),
            hints.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            hints.firstBaselineAnchor.constraint(equalTo: footer.firstBaselineAnchor),
        ])
        table.tableColumns.first?.width = 640
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SessionCell.identifier, owner: self) as? SessionCell ?? SessionCell()
        cell.show(rows[row], project: project, inTab: tabs.tab(of: rows[row]) != nil)
        return cell
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { close() }
    }
}
