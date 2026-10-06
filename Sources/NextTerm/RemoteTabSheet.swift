import AppKit
import NextTermCore

/// "New Remote Tab…" (⌥⌘T): pick a saved host or describe a new one, then open a tab on it. Hosts are
/// saved here (and through MCP); there is nothing to set up in Settings. ssh does the rest as the user
/// has it configured: keys, agent, ~/.ssh/config. A password or a new host key is asked for by ssh
/// itself, in the tab, where the user sees it.
final class RemoteTabSheet: NSObject, NSTextFieldDelegate {
    private static var current: RemoteTabSheet?

    static func show(over window: NSWindow, open: @escaping (RemoteTab) -> Void) {
        guard current == nil else { return }
        let sheet = RemoteTabSheet(open: open)
        current = sheet
        window.beginSheet(sheet.panel) { _ in current = nil }
    }

    private let open: (RemoteTab) -> Void
    private let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    private let hostPopup = NSPopUpButton()
    private let removeButton = NSButton(title: "Remove Host", target: nil, action: nil)
    private let nameField = NSTextField()
    private let destinationField = NSTextField()
    private let portField = NSTextField()
    private let folderField = NSTextField()
    private let keepControl = NSSegmentedControl(labels: KeepMode.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let keepNote = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private var hosts = RemoteHosts.all

    private init(open: @escaping (RemoteTab) -> Void) {
        self.open = open
        super.init()
        build()
        let last = UserDefaults.standard.string(forKey: "lastRemoteHost")
        select(hosts.firstIndex { $0.id == last } ?? (hosts.isEmpty ? nil : 0))
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func build() {
        panel.title = "New Remote Tab"
        hostPopup.target = self
        hostPopup.action = #selector(hostChosen(_:))
        removeButton.target = self
        removeButton.action = #selector(removeHost(_:))
        removeButton.bezelStyle = .rounded
        keepControl.target = self
        keepControl.action = #selector(keepChanged(_:))

        nameField.placeholderString = "web-1"
        destinationField.placeholderString = "user@203.0.113.5, or a Host from ~/.ssh/config"
        portField.placeholderString = "22"
        folderField.placeholderString = "~"
        destinationField.delegate = self
        for field in [nameField, destinationField, portField, folderField] {
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
        }
        keepNote.textColor = .secondaryLabelColor
        keepNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.textColor = .systemRed
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.isHidden = true

        let hostRow = NSStackView(views: [hostPopup, removeButton])
        hostRow.spacing = 8
        let grid = NSGridView(views: [
            [label("Host:"), hostRow],
            [label("Name:"), nameField],
            [label("SSH destination:"), destinationField],
            [label("Port:"), portField],
            [label("Folder on host:"), folderField],
            [label("Keep agents running:"), keepControl],
            [NSGridCell.emptyContentView, keepNote],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        destinationField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let connect = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        connect.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, connect])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, problemLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
            problemLabel.widthAnchor.constraint(equalTo: grid.widthAnchor),
            keepNote.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        panel.contentView = content
        rebuildPopup()
    }

    private func rebuildPopup() {
        hostPopup.removeAllItems()
        for host in hosts { hostPopup.addItem(withTitle: "\(host.name) — \(host.destination)") }
        if !hosts.isEmpty { hostPopup.menu?.addItem(.separator()) }
        hostPopup.addItem(withTitle: "New Host…")
    }

    /// Shows a saved host (index), or empty fields for a new one (nil).
    private func select(_ index: Int?) {
        if let index, hosts.indices.contains(index) {
            hostPopup.selectItem(at: index)
            let host = hosts[index]
            nameField.stringValue = host.name
            destinationField.stringValue = host.destination
            portField.stringValue = host.port.map(String.init) ?? ""
            folderField.stringValue = host.directory
            keepControl.selectedSegment = KeepMode.allCases.firstIndex(of: host.keep) ?? 1
            removeButton.isEnabled = true
        } else {
            hostPopup.selectItem(at: hostPopup.numberOfItems - 1)
            for field in [nameField, destinationField, portField, folderField] { field.stringValue = "" }
            keepControl.selectedSegment = KeepMode.allCases.firstIndex(of: .tmux) ?? 1
            removeButton.isEnabled = false
        }
        keepChanged(nil)
        problemLabel.isHidden = true
        panel.makeFirstResponder(destinationField.stringValue.isEmpty ? destinationField : folderField)
    }

    private var selectedHost: RemoteHost? {
        let index = hostPopup.indexOfSelectedItem
        return hosts.indices.contains(index) ? hosts[index] : nil
    }

    @objc private func hostChosen(_ sender: Any?) {
        let index = hostPopup.indexOfSelectedItem
        select(hosts.indices.contains(index) ? index : nil)
    }

    @objc private func keepChanged(_ sender: Any?) {
        let keep = KeepMode.allCases[max(0, keepControl.selectedSegment)]
        keepNote.stringValue = keep.summary
    }

    /// A new host gets its destination as its name until the user gives one.
    func controlTextDidChange(_ notification: Notification) {
        guard selectedHost == nil, notification.object as? NSTextField === destinationField else { return }
        let destination = destinationField.stringValue
        nameField.placeholderString = destination.isEmpty ? "web-1" : String(destination.split(separator: "@").last ?? Substring(destination))
    }

    @objc private func removeHost(_ sender: Any?) {
        guard let host = selectedHost else { return }
        RemoteHosts.remove(id: host.id)
        hosts = RemoteHosts.all
        rebuildPopup()
        select(hosts.isEmpty ? nil : 0)
    }

    @objc private func cancel(_ sender: Any?) {
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func connect(_ sender: Any?) {
        let destination = destinationField.stringValue.trimmingCharacters(in: .whitespaces)
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = nameField.placeholderString == "web-1" ? destination : nameField.placeholderString ?? destination }
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        let folderText = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        var host = selectedHost ?? RemoteHost(name: name, destination: destination)
        host.name = name
        host.destination = destination
        host.port = portText.isEmpty ? nil : Int(portText) ?? -1
        host.directory = folderText.isEmpty ? "~" : folderText
        host.keep = KeepMode.allCases[max(0, keepControl.selectedSegment)]
        if let problem = host.problem {
            problemLabel.stringValue = problem
            problemLabel.isHidden = false
            NSSound.beep()
            return
        }
        RemoteHosts.save(host)
        UserDefaults.standard.set(host.id, forKey: "lastRemoteHost")
        panel.sheetParent?.endSheet(panel)
        open(RemoteTab(host: host))
    }
}
