import AppKit
import NextTermCore

/// Closes a pane or tab Next Term opened to run one command for an agent once that command has finished well: the
/// pane run_command opens below the agent's tab, the new tab run_with_secrets opens, and the tab the password
/// manager's import types its line in. Never the user's own tabs.
///
/// When the command ends with exit code 0, a small bar at the pane's top says "Closes in 3 s" with a Keep Open button,
/// and the pane closes when the count ends (CommandPaneClose has the rule). A failure, or a shell that reports no exit
/// code, leaves it open for the user to read. Keep Open in the bar, Keep Open in the pane's or tab's right-click menu,
/// or a key pressed in the pane once the command has ended keeps it. Keys pressed while the command runs, such as a
/// password for sudo, are part of running it and keep nothing.
///
/// Before it closes, its exit code and last lines are kept for half an hour, so an agent's later read_tab or
/// wait_for_tab on its id answers that it closed after finishing, with what it showed, instead of "no tab".
@MainActor
enum CommandPaneAutoClose {
    /// A pane being followed.
    final class Entry {
        weak var pane: TerminalTab?
        /// Commands its shell had run at its prompt before the one followed.
        let before: Int
        /// When following it ends, whatever happened.
        let until: TimeInterval
        var kept = false
        var ended = false
        var typedAfterEnd = false
        var bar: NSView?
        var label: NSTextField?
        var closesAt: TimeInterval?

        init(pane: TerminalTab, before: Int, until: TimeInterval) {
            self.pane = pane
            self.before = before
            self.until = until
        }
    }

    /// How a pane that closed by itself had ended, for an agent that asks about it later.
    struct Closed {
        let exitCode: Int32
        let output: String
        let at: TimeInterval
    }

    private(set) static var entries: [UUID: Entry] = [:]
    private(set) static var closed: [String: Closed] = [:]

    /// Follows `pane` from now: the next command started at its prompt (after `before`) is the one whose end counts.
    /// `for seconds`: how long to keep following it before giving up, the command still running or never started.
    static func watch(_ pane: TerminalTab, before: Int, for seconds: TimeInterval = 3600) {
        let entry = Entry(pane: pane, before: before, until: TerminalTab.now + seconds)
        entries[pane.id] = entry
        poll(entry, id: pane.id)
    }

    /// Whether `pane` is followed and may still close by itself: its menus offer Keep Open.
    static func mayClose(_ pane: TerminalTab) -> Bool {
        guard let entry = entries[pane.id] else { return false }
        return !entry.kept && !entry.typedAfterEnd
    }

    /// Keep Open: the pane stays, now and when its command ends.
    static func keep(_ pane: TerminalTab) {
        guard let entry = entries[pane.id] else { return }
        entry.kept = true
        stop(entry, id: pane.id)
    }

    /// A key, paste or drop of the user's in `pane`: after its command has ended, the pane is theirs and stays.
    static func typedByUser(_ pane: TerminalTab) {
        guard let entry = entries[pane.id], entry.ended else { return }
        entry.typedAfterEnd = true
        stop(entry, id: pane.id)
    }

    /// What read_tab and wait_for_tab answer for the id of a pane that closed by itself, or nil for any other id.
    static func closedAnswer(_ id: Any?) -> MCPServer.CallResult? {
        guard let text = (id as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), let gone = closed[text] else { return nil }
        return MCPControl.ok(["id": text, "state": "closed", "closed": true, "exit_code": Int(gone.exitCode), "output": gone.output,
                              "note": "The pane closed by itself after its command finished with exit code 0; output is what it showed last."])
    }

    /// How the pane with this id ended, when it closed by itself.
    static func closedRecord(_ id: String) -> Closed? { closed[id.lowercased()] }

    // MARK: following

    private static func poll(_ entry: Entry, id: UUID) {
        guard entries[id] === entry else { return }
        guard let pane = entry.pane, !pane.exited, MCPControl.controller(of: pane) != nil else { return forget(id) }
        if entry.kept || entry.typedAfterEnd { return stop(entry, id: id) }
        if let closesAt = entry.closesAt {
            if TerminalTab.now >= closesAt { return close(entry, id: id) }
            entry.label?.stringValue = CommandPaneClose.countdown(closesAt - TerminalTab.now)
        } else if !entry.ended {
            if TerminalTab.now > entry.until { return forget(id) }
            if pane.status.commandsAtPrompt > entry.before && !pane.status.running {
                entry.ended = true
                guard decide(entry, pane) else { return stop(entry, id: id) }
                entry.closesAt = TerminalTab.now + CommandPaneClose.delay
                showBar(entry, pane)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { poll(entry, id: id) } }
    }

    private static func decide(_ entry: Entry, _ pane: TerminalTab) -> Bool {
        let last = (MCPControl.controller(of: pane)?.tabs.count ?? 0) <= 1
        return CommandPaneClose.closes(exitCode: pane.status.exitCode, kept: entry.kept, userTyped: entry.typedAfterEnd,
                                       lastInWindow: last)
    }

    /// The count has ended: looked at once more (nothing new started in it, still not kept), then the end recorded and
    /// the pane closed.
    private static func close(_ entry: Entry, id: UUID) {
        guard let pane = entry.pane, let controller = MCPControl.controller(of: pane), !pane.status.running,
              let code = pane.status.exitCode, decide(entry, pane) else { return stop(entry, id: id) }
        let screen = MCPControl.screenFields(pane, lines: 40)["screen"] as? String ?? ""
        let output = screen.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        prune()
        closed[pane.id.uuidString.lowercased()] = Closed(exitCode: code, output: output, at: TerminalTab.now)
        forget(id)
        controller.remove(pane)
    }

    /// No more closing: the bar goes, and the pane is no longer followed.
    private static func stop(_ entry: Entry, id: UUID) {
        entry.closesAt = nil
        entry.bar?.removeFromSuperview()
        entry.bar = nil
        if entries[id] === entry { entries[id] = nil }
    }

    private static func forget(_ id: UUID) {
        if let entry = entries[id] {
            entry.bar?.removeFromSuperview()
            entry.bar = nil
        }
        entries[id] = nil
    }

    private static func prune() {
        let now = TerminalTab.now
        closed = closed.filter { now - $0.value.at < 1800 }
    }

    // MARK: the bar

    /// "Closes in 3 s" and Keep Open, at the pane's top right, in the style of the pane's other hints.
    private static func showBar(_ entry: Entry, _ pane: TerminalTab) {
        let label = NSTextField(labelWithString: CommandPaneClose.countdown(CommandPaneClose.delay))
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .white
        let button = KeepButton(title: "Keep Open", target: nil, action: nil)
        button.controlSize = .small
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.refusesFirstResponder = true
        button.onPress = { [weak pane] in if let pane { keep(pane) } }
        button.target = button
        button.action = #selector(KeepButton.pressed)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 4)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        stack.layer?.cornerRadius = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityLabel("This pane closes by itself")
        pane.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.view.topAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: pane.view.trailingAnchor, constant: -20),
        ])
        entry.bar = stack
        entry.label = label
        NSAccessibility.post(element: stack, notification: .announcementRequested,
                             userInfo: [.announcement: "The command finished. The pane closes in 3 seconds unless you keep it open.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The bar's button, holding what it does.
    private final class KeepButton: NSButton {
        var onPress: (() -> Void)?
        @objc func pressed() { onPress?() }
    }

    #if DEBUG
    /// The bar's Keep Open button, for the self-test.
    static func keepButton(_ pane: TerminalTab) -> NSButton? {
        entries[pane.id]?.bar?.subviews.compactMap { $0 as? NSButton }.first
    }
    #endif
}
