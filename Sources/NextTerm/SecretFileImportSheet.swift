import AppKit
import NextTermCore

/// Import From › A File…: the keys a picked file holds, one row each, ticked where they look like keys. The user edits
/// names and ticks, then Import… asks once and one Touch ID copies the ticked keys in. The file is never written: the
/// done view says what still holds the keys, offers to move a password manager's export to the Trash, and, for a file
/// in git, Rotate… for each key. Core's `SecretSources` read the file and `SecretCopyIn` saves; this sheet only asks.
/// Closing it releases the report, which wipes every value it held.
@MainActor
final class SecretFileImportSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// How the sheet ended, for the list: what to say under it, and a key to open Rotate… for.
    struct Ending {
        var said: String?
        var rotate: String?
    }

    static let title = "Import from a File"
    static let nameHeader = "Name (agents see it)"
    static let fromTitleNote = "From the item\u{2019}s title; agents will see this name."
    static let replacesNote = "Replaces your key"
    static let sameNameNote = "Another ticked row has this name."
    static let tickLine = "Tick the ones to copy into Secrets."
    static let noKeysLine = "No keys were found in it."
    static let outsideServersLine = "The MCP-config import moves the keys in this file\u{2019}s MCP servers. These "
        + "are the keys outside them, to copy in."
    static let trashTitle = "Move Export to the Trash"
    static let trashLine = "Its keys are in Secrets now. Moving it to the Trash doesn\u{2019}t erase backups of it."
    static let touchIDLine = "Waiting for Touch ID or your password\u{2026}"
    /// The most Rotate… rows the done view lists; the rest are in the list.
    static let rotateRows = 8

    /// The file, as picked, with its links followed.
    let path: String
    /// The keys outside a move target's MCP servers, after its servers went to the MCP-config import.
    let outsideServers: Bool
    /// Whether the file is in a git work tree: its keys are in git's history too, so the done view offers Rotate….
    let inGit: Bool
    /// What the file holds. Released when the sheet closes, which wipes every value.
    var report: SourceReport?
    /// The keys stored when the sheet opened, read again at Import… (`checkStoredAgain`): a row of one replaces it.
    private(set) var stored: Set<String>
    let done: (Ending) -> Void
    var rows: [FileImportRow] = []
    let rowsStack = NSStackView()
    private(set) var headerLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var footerLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var notKeysButton = NSButton(title: "Show Them", target: nil, action: nil)
    private(set) var notKeysLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    let doneStack = NSStackView()
    private(set) var trashBox = NSButton(checkboxWithTitle: SecretFileImportSheet.trashTitle, target: nil, action: nil)
    var rotateButtons: [NSButton] = []
    private(set) var importButton = NSButton(title: "Import\u{2026}", target: nil, action: nil)
    private(set) var cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var doneButton = NSButton(title: "Done", target: nil, action: nil)
    var confirmAlert: NSAlert?
    /// The keys the open confirm names, and the file's names for them: held here, not by the alert's handler, so no
    /// value outlives the sheet in an alert AppKit keeps.
    var awaitingConfirm: (planned: [SecretCopyIn.Planned], readAs: [String: String])?
    /// What the copy-in saved, once it has.
    var record: SecretCopyIn.Record?
    var isBusy = false
    let scroll = NSScrollView()
    /// `nxtrm secret import`'s importer: where its keys came from, told when the sheet ends.
    let client: SecretImportClient?

    /// `report` is checked against the keys stored as the sheet opens, which may be more than when the file was read:
    /// the move import stores its keys before the keys outside its servers open here.
    init(path: String, report: SourceReport, outsideServers: Bool = false, inGit: Bool = false,
         client: SecretImportClient? = nil, done: @escaping (Ending) -> Void) {
        let stored: Set<String> = Set(SecretsStore.shared.index?.names ?? [])
        let checked: SourceReport = report.checked(against: stored)
        self.path = path
        self.report = checked
        self.stored = stored
        self.outsideServers = outsideServers
        self.inGit = inGit
        self.client = client
        self.done = done
        let frame = NSRect(x: 0, y: 0, width: 760, height: 580)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 380)
        super.init(window: window)
        window.delegate = self
        build()
        show(checked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The file's name, as the sheet and the Touch ID line name it; for piped keys, where they came from.
    var fileName: String { isPiped ? pipedSource : (path as NSString).lastPathComponent }

    /// The keys stored now, read again: a row named as a key stored since it was last checked is unticked, so
    /// replacing that key takes a tick by hand. Returns the names it unticked.
    @discardableResult
    func checkStoredAgain() -> [String] {
        stored = Set(SecretsStore.shared.index?.names ?? [])
        var unticked: [String] = []
        for row in rows {
            let isStored: Bool = stored.contains(row.name)
            if isStored, !row.wasStored, row.isTicked {
                row.box.state = .off
                unticked.append(row.name)
            }
            row.wasStored = isStored
        }
        refresh()
        return unticked
    }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }
}

// MARK: building

extension SecretFileImportSheet {
    private func build() {
        guard let view = window?.contentView else { return }
        let title = SecretApprovalPanel.label(Self.title, size: 14, weight: .semibold)
        for label in [headerLabel, statusLabel, footerLabel, summaryLabel] { label.font = .systemFont(ofSize: 12) }
        statusLabel.textColor = .secondaryLabelColor
        notKeysLabel.font = .systemFont(ofSize: 11)
        notKeysLabel.textColor = .secondaryLabelColor
        notKeysLabel.isHidden = true
        summaryLabel.isHidden = true
        notKeysButton.bezelStyle = .inline
        notKeysButton.target = self
        notKeysButton.action = #selector(toggleNotKeys)
        let footer = NSStackView(views: [footerLabel, notKeysButton, NSView()])
        footer.spacing = 6
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FileImportFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        doneStack.orientation = .vertical
        doneStack.alignment = .leading
        doneStack.spacing = 6
        doneStack.isHidden = true
        buildButtons()
        let buttons = NSStackView(views: [NSView(), cancelButton, importButton, doneButton])
        buttons.spacing = 8
        let views: [NSView] = [title, headerLabel, statusLabel, scroll, footer, notKeysLabel, summaryLabel, doneStack,
                               buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -8),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ]
        let wide: [NSView] = [headerLabel, statusLabel, scroll, footer, notKeysLabel, summaryLabel, doneStack, buttons]
        for row in wide { constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
    }

    private func buildButtons() {
        importButton.target = self
        importButton.action = #selector(importTicked)
        importButton.keyEquivalent = "\r"
        importButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(closeSheet)
        cancelButton.keyEquivalent = "\u{1b}"
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.isHidden = true
        trashBox.state = .on
        trashBox.setAccessibilityLabel(Self.trashTitle)
        for button in [importButton, cancelButton, doneButton] { button.bezelStyle = .rounded }
    }

    /// The header (the file, how it was read, what to know about it), the line above the rows, the rows, and the
    /// footer's count of values that aren't keys.
    func show(_ report: SourceReport) {
        let fileHeader: String = "\(SecretImportSheet.file(path)), read as \(Self.formatText(report))."
        var header: String = isPiped ? pipedHeader(report) : fileHeader
        if !isPiped, let place = client?.origin.place { header += " Given by nxtrm secret import in \(place)." }
        if outsideServers { header += " " + Self.outsideServersLine }
        if let note = report.fileNote { header += "\n" + note.sentence + "." }
        headerLabel.stringValue = header
        if let warning = client?.origin.warning { addOriginWarning(warning) }
        footerLabel.stringValue = report.footer ?? ""
        notKeysButton.isHidden = report.notKeys.isEmpty
        footerLabel.isHidden = report.notKeys.isEmpty
        notKeysLabel.stringValue = report.notKeys.map { (item: SecretSources.NotKey) -> String in
            "\(item.name), \(item.place): \(item.reason.sentence)"
        }.joined(separator: "\n")
        if report.unreadable != nil || report.rows.isEmpty {
            importButton.isHidden = true
            cancelButton.title = "Close"
            cancelButton.keyEquivalent = "\r"
        }
        if let unreadable = report.unreadable {
            statusLabel.stringValue = unreadable.sentence
            statusLabel.textColor = .systemOrange
            statusLabel.setAccessibilityLabel("Warning: \(unreadable.sentence)")
            scroll.isHidden = true
            return
        }
        guard !report.rows.isEmpty else {
            statusLabel.stringValue = Self.noKeysLine
            scroll.isHidden = true
            return
        }
        rowsStack.addArrangedSubview(FileImportRow.header())
        for (index, row) in report.rows.enumerated() { addRow(row, index: index) }
        refresh()
    }

    /// "a .env file", "Bitwarden\u{2019}s export (CSV)".
    static func formatText(_ report: SourceReport) -> String {
        let noun: String = SecretCopyIn.formatNoun(report.format)
        guard let app = report.exportedBy, report.format == .csv else { return noun }
        return "\(app)\u{2019}s export (CSV)"
    }

    @objc func toggleNotKeys() {
        notKeysLabel.isHidden.toggle()
        notKeysButton.title = notKeysLabel.isHidden ? "Show Them" : "Hide Them"
    }
}

/// A document view whose rows start at the top.
private final class FileImportFlippedView: NSView {
    override var isFlipped: Bool { true }
}
