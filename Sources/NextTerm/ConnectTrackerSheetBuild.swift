import AppKit
import NextTermCore

// Connect a Tracker's layout: the tracker popup, one row per agent, the trackers not listed yet, and the status line.

extension ConnectTrackerSheet {
    static let width: CGFloat = 640

    func build() {
        guard let view = window?.contentView else { return }
        let title = SecretApprovalPanel.label(Self.title, size: 14, weight: .semibold)
        let intro = SecretApprovalPanel.label(Self.intro, size: 12)
        for tracker in trackers { trackerPopup.addItem(withTitle: tracker.name) }
        trackerPopup.target = self
        trackerPopup.action = #selector(trackerChanged)
        trackerPopup.setAccessibilityLabel("Tracker")
        let trackerRow = NSStackView(views: [NSTextField(labelWithString: "Tracker:"), trackerPopup])
        trackerRow.spacing = 8
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        status.font = .systemFont(ofSize: 12)
        status.preferredMaxLayoutWidth = Self.width - 36
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), doneButton])
        let views: [NSView] = [title, intro, trackerRow, rows, heldList(), status, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
        ]
        let wide: [NSView] = [intro, rows, status, buttons]
        for item in wide { constraints.append(item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
        fillRows()
    }

    /// The rows for the tracker chosen, one per agent.
    func fillRows() {
        for old in rows.arrangedSubviews {
            rows.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        rowViews = [:]
        for agent in TrackerLines.agents { rows.addArrangedSubview(row(agent)) }
    }

    private func row(_ agent: AgentKind) -> NSView {
        let name = NSTextField(labelWithString: agent.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let cell: TrackerLines.Cell = tracker.cell(for: agent)
        let line = NSTextField(wrappingLabelWithString: "")
        line.preferredMaxLayoutWidth = Self.width - 36
        var parts: [NSView] = [name, line]
        var copy: NSButton?
        var open: NSButton?
        var missing: NSTextField?
        var link: NSButton?
        var noteLabels: [NSTextField] = []
        switch cell {
        case .line(let text, _):
            line.stringValue = text
            line.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            line.isSelectable = true
            line.setAccessibilityLabel("\(agent.name)\u{2019}s line for \(tracker.name)")
            noteLabels = tracker.notes(for: agent, line: text).map { (note: String) -> NSTextField in
                SecretManagerImportSheet.small(note)
            }
            parts.append(contentsOf: noteLabels)
            let copyButton = button("Copy", #selector(copyLine(_:)), agent)
            let openButton = button(Self.openTitle, #selector(openInNewTab(_:)), agent)
            let notFound = SecretManagerImportSheet.small(Self.notFound)
            let installed: Bool = found?.contains(agent) ?? false
            openButton.isHidden = !installed
            notFound.isHidden = installed || found == nil
            let actions = NSStackView(views: [copyButton, openButton, notFound])
            actions.spacing = 8
            parts.append(actions)
            copy = copyButton
            open = openButton
            missing = notFound
        case .held(let why, let page):
            line.stringValue = why
            line.font = .systemFont(ofSize: 12)
            line.textColor = .secondaryLabelColor
            let pageLink = pageButton(page, title: page.host ?? "Its page")
            link = pageLink
            parts.append(pageLink)
        case .showHow(let page):
            line.stringValue = "opencode adds a server by asking its questions one at a time, so there is no line to type."
            line.font = .systemFont(ofSize: 12)
            line.textColor = .secondaryLabelColor
            let howLink = pageButton(page, title: "Show how")
            link = howLink
            parts.append(howLink)
        }
        rowViews[agent] = RowViews(line: line, copy: copy, open: open, notFound: missing, link: link, notes: noteLabels)
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func button(_ title: String, _ action: Selector, _ agent: AgentKind) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(agent.rawValue)
        return button
    }

    /// A link to a page, opened in the browser on a click.
    func pageButton(_ page: URL, title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openPage(_:)))
        button.bezelStyle = .inline
        button.identifier = NSUserInterfaceItemIdentifier(page.absoluteString)
        button.toolTip = page.absoluteString
        return button
    }

    /// The trackers with no line yet, each with why and its page.
    private func heldList() -> NSView {
        var views: [NSView] = [SecretManagerImportSheet.small(Self.notListed)]
        heldLabels = []
        for (tracker, text) in zip(TrackerLines.held, TrackerLines.heldSummary) {
            let label = SecretManagerImportSheet.small(text)
            heldLabels.append(label)
            let row = NSStackView(views: [label, pageButton(tracker.page, title: tracker.page.host ?? "Its page")])
            row.spacing = 6
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }
}
