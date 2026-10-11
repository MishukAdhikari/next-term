import AppKit
import NextTermCore

/// Settings › Remote Access › Activity (R39): the last 500 entries of the audit log, newest first, in words, with
/// Clear Log and Show in Finder. Each row's tooltip holds the line's masked details: what was typed or approved, the
/// arguments, or a summed refusal's first Host or path. Tokens and tool output are never in the log, so never here.
///
/// The log is read off the main thread, on the open door's audit queue after the lines it has queued, or on a queue
/// of its own while the door is closed. It is read again when the view shows, when Remote access changes, and every
/// 10 seconds while its window is visible.
@MainActor
final class RemoteAccessActivityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 548
    static let tableHeight: CGFloat = 220
    static let rereadEvery: TimeInterval = 10

    let table = NSTableView()
    let clearButton = NSButton(title: "Clear Log…", target: nil, action: nil)
    let finderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")
    /// The rows shown, newest first.
    private(set) var rows: [RemoteAccessActivityRow] = []
    private let scroll = NSScrollView()
    private let timeFormat: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("MMMd HH:mm:ss")
        return format
    }()
    /// Counts reads, so a slow one never shows over a newer one.
    private var generation = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(remoteAccessChanged), name: RemoteAccess.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let columns: [(String, String, CGFloat)] = [("time", "Time", 112), ("connection", "Connection", 116),
                                                    ("what", "What happened", 300)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            column.resizingMask = id == "what" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Remote access activity")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        finderButton.target = self
        finderButton.action = #selector(showInFinder)
        for button in [clearButton, finderButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [summaryLabel, NSView(), finderButton, clearButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.heightAnchor.constraint(equalToConstant: Self.tableHeight),
            buttons.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        reload()
        let timer = Timer(timeInterval: Self.rereadEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.reload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func remoteAccessChanged() {
        guard window != nil else { return }
        reload()
    }

    /// Reads the log again, and shows it once read.
    func reload(done: (@MainActor () -> Void)? = nil) {
        generation += 1
        let wanted = generation
        RemoteAccess.shared.readActivity { [weak self] entries in
            guard let self, self.generation == wanted else { return }
            self.show(entries)
            done?()
        }
    }

    private func show(_ entries: [RemoteAccessAuditEntry]) {
        rows = entries.reversed().map(RemoteAccessActivityRow.init)
        table.reloadData()
        clearButton.isEnabled = !rows.isEmpty
        switch rows.count {
        case 0: summaryLabel.stringValue = "Nothing logged in the last 30 days."
        case RemoteAccessAuditLog.tailCount: summaryLabel.stringValue = "The last \(rows.count) entries."
        default: summaryLabel.stringValue = rows.count == 1 ? "1 entry." : "\(rows.count) entries."
        }
    }

    // MARK: actions

    @objc private func clearClicked() {
        let alert = NSAlert()
        alert.messageText = "Clear the Remote access log?"
        alert.informativeText = "Every entry goes, from this file and the older ones. This can't be undone."
        alert.addButton(withTitle: "Clear Log")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.clear()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    /// Clear Log, once confirmed: every audit file goes.
    func clear(done: (@MainActor () -> Void)? = nil) {
        RemoteAccess.shared.clearActivity { [weak self] problem in
            if let problem { self?.summaryLabel.stringValue = problem }
            self?.reload(done: done)
        }
    }

    @objc private func showInFinder() {
        let file = RemoteAccess.shared.auditFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.deletingLastPathComponent()])
        } else {
            summaryLabel.stringValue = "Nothing is logged yet."
        }
    }

    // MARK: the table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let shown = rows[row]
        let text: String
        switch id {
        case "time": text = timeFormat.string(from: shown.time)
        case "connection": text = shown.connection
        default: text = shown.what
        }
        let label = NSTextField(labelWithString: text)
        label.font = id == "time" ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = id == "what" && shown.problem ? .systemRed : .labelColor
        label.toolTip = shown.detail.isEmpty ? shown.what : "\(shown.what)\n\(shown.detail)"
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
