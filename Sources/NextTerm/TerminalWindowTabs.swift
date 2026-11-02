import AppKit
import NextTermCore

/// Project windows merged as macOS's own window tabs (plan 032): which tab is in front, what each tab shows, and closing
/// a merged window.
extension TerminalWindowController {
    /// Watches the system tab group the window is in, for which tab is in front and who is in it. A window moved to
    /// another group gets that group, so this is asked again whenever the title bar changes (a merge or a split moves the
    /// tab bar) and when the window becomes key.
    func watchTabGroup() {
        guard let window else { return }
        let group: NSWindowTabGroup? = window.tabGroup
        guard group !== watchedTabGroup else { return }
        watchedTabGroup = group
        tabGroupWatches = [
            group?.observe(\.selectedWindow, options: [.new]) { [weak self] (_, _) in
                DispatchQueue.main.async { self?.tabSelectionChanged() }
            },
            group?.observe(\.windows, options: [.new]) { [weak self] (_, _) in
                DispatchQueue.main.async { self?.tabSelectionChanged() }
            },
        ].compactMap { $0 }
        tabSelectionChanged()
    }

    /// Its tab came to the front, went behind another, or the tabs beside it changed: what is seen follows at once (its
    /// terminals, the sidebar's refresh), the hover list closes behind, and a question held for its tab is asked now.
    func tabSelectionChanged() {
        guard let window, !hasClosed else { return }
        NotificationCenter.default.post(name: NSWindow.tabSelectionDidChange, object: window)
        if window.isBackgroundTab {
            columnHost.windowClosing() // the list, a pending open and its Escape monitor go; nothing reopens it behind
        } else if let held = heldQuestion {
            heldQuestion = nil
            DispatchQueue.main.async { held() }
        }
        refreshVisibility()
        updateProjectTab()
        columnHost.column.setMerged(mergedIDs)
        columnHost.list?.setMerged(mergedIDs)
    }

    /// The windows merged with this one, by their ids in the index, this one among them; empty for a window of its own.
    var mergedIDs: Set<Int> {
        guard let window else { return [] }
        let windows: [NSWindow] = window.mergedWindows
        guard windows.count > 1 else { return [] }
        return Set(windows.compactMap { ($0.windowController as? TerminalWindowController)?.indexID })
    }

    /// What the project's tab in the system tab bar shows: its colour's dot and its name, a worktree's own part after
    /// its repository's, dimmer (as the window column names it), and a mark while an agent in it needs you or failed, or
    /// a question waits for its tab. Only while a tab bar shows, and only what changed.
    func updateProjectTab() {
        guard let window, window.tabGroup?.isTabBarVisible == true else { return }
        let entry: WindowIndex.Window = indexEntry
        let shown = WindowColumnName.shown(entry, depth: 0)
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let dot: NSColor = projectColor?.swatchColor ?? Theme.textDim
        title.append(NSAttributedString(string: "\u{25CF}\u{2009}", attributes: [.foregroundColor: dot, .font: font]))
        if let prefix = shown.prefix {
            title.append(NSAttributedString(string: prefix + " ", attributes: [.foregroundColor: Theme.textDim, .font: font]))
        }
        title.append(NSAttributedString(string: shown.name, attributes: [.font: font]))
        if window.tab.attributedTitle != title { window.tab.attributedTitle = title }
        let marks: AgentMarks = entry.marks
        let mark: TabState? = heldQuestion != nil || marks.attention > 0 ? .attention : marks.failed > 0 ? .failed : nil
        guard mark != projectTabMark else { return }
        projectTabMark = mark
        window.tab.accessoryView = mark.map(ProjectTabMark.init(state:))
    }

    /// File › Close Window (⇧⌘W): the whole window, every project merged into it (MergedWindowClose); a window of its
    /// own closes as it always has.
    @objc func closeWindow(_ sender: Any?) {
        guard let window else { return }
        let members: [TerminalWindowController] = window.mergedWindows.compactMap { $0.windowController as? TerminalWindowController }
        guard members.count > 1 else { return window.performClose(sender) }
        MergedWindowClose.start(members, over: window.shownWindow)
    }
}

/// The mark on a project's tab in the system tab bar: the needs-you or failed dot the window column shows, at the tab's
/// trailing edge.
final class ProjectTabMark: NSView {
    private let state: TabState

    init(state: TabState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(state == .failed ? "Failed" : "Needs you")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 14), heightAnchor.constraint(equalToConstant: 14)])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 6
        let dot = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        (state == .failed ? Theme.failed : Theme.attention).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

/// Closing a window of merged projects (plan 032 R8): one question for what closing stops in all of them, then each
/// project closes, the ones behind first. A project with unsaved files or database values asks about them itself, in
/// front, one at a time; a Cancel there keeps it and every project not closed yet.
@MainActor
final class MergedWindowClose {
    private static var current: MergedWindowClose?
    private var left: [TerminalWindowController]
    private var observers: [NSObjectProtocol] = []

    private init(_ members: [TerminalWindowController]) {
        left = members
    }

    static func start(_ members: [TerminalWindowController], over shown: NSWindow) {
        guard current == nil, shown.attachedSheet == nil else { return NSSound.beep() }
        let behind: [TerminalWindowController] = members.filter { $0.window?.isBackgroundTab == true }
        let close = MergedWindowClose(behind + members.filter { member in !behind.contains { $0 === member } })
        current = close
        let busy: [TerminalTab] = members.flatMap(\.busyTabs)
        let kept: [String] = members.map { TerminalWindowController.keptList($0.tabs) }.filter { !$0.isEmpty }
        guard !busy.isEmpty || !kept.isEmpty else { return close.run() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        let names: String = ListFormatter.localizedString(byJoining: members.map { "“\($0.windowName)”" })
        let projects = "Its \(members.count) projects close: \(names)."
        alert.informativeText = ([projects, busy.isEmpty ? "" : TerminalWindowController.stopText("Closing it stops", busy)] + kept)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close Window").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: shown) { response in
            guard response == .alertFirstButtonReturn else { return close.stop() }
            close.run()
        }
    }

    private func run() {
        for member in left { member.stopConfirmed = true }
        next()
    }

    private func next() {
        left.removeAll { $0.hasClosed }
        guard let member = left.first, let window = member.window else { return stop() }
        guard member.closeAsks else {
            left.removeFirst()
            window.performClose(nil) // nothing to ask: it goes now (or once its database saves end)
            return next()
        }
        // Its own question, about its files or values, in front.
        watch(member, window)
        window.makeKeyAndOrderFront(nil)
        window.performClose(nil)
    }

    /// Goes on once `window` has closed; stops when its question ended with the window still open and nothing more to
    /// come (Cancel, or a file that could not be saved).
    private func watch(_ member: TerminalWindowController, _ window: NSWindow) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unwatch()
                    self.left.removeAll { $0 === member }
                    DispatchQueue.main.async { self.next() }
                }
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                // Another question may follow (the values after the files), or a save may still be under way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self, !member.hasClosed, window.attachedSheet == nil, member.editorArea.savingDatabases.isEmpty else { return }
                    self.stop()
                }
            },
        ]
    }

    private func unwatch() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func stop() {
        unwatch()
        for member in left { member.stopConfirmed = false }
        left = []
        Self.current = nil
    }
}

/// Waits for a window's question to be answered.
enum WindowSheets {
    /// `then` once the sheet on `window` ends, a turn later.
    static func afterSheet(on window: NSWindow, then: @escaping () -> Void) {
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            DispatchQueue.main.async(execute: then)
        }
    }
}
