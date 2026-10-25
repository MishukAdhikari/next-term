import AppKit
import NextTermCore

/// One row of Import from a File: its tick, its name (editable, as agents will see it), "Never show", its kind, its last
/// four characters, where it was found, its page's host and its note. The value itself is never on screen.
@MainActor
final class FileImportRow {
    /// The columns' widths, the header's and every row's alike: tick, name, never show, kind, last 4, found at, page,
    /// note. They add up to what they did before "Never show" came.
    static let widths: [CGFloat] = [18, 150, 66, 96, 44, 76, 92, 114]
    static let headers: [String] = ["", SecretFileImportSheet.nameHeader, neverShowHeader, "Kind", "Last 4", "Found at", "Page",
                                    "Note"]

    /// The row's place in the report.
    let index: Int
    let box: NSButton
    let nameField: NSTextField
    /// "Never show": the key is saved write-only. Ticked as Settings › Secrets' New keys default says.
    let neverShowBox: NSButton
    let noteLabel: NSTextField
    let view: NSStackView
    /// Whether its name was a stored key's when last checked: typing a stored key's name unticks it, so a key is
    /// replaced only by a tick made by hand.
    var wasStored: Bool

    init(index: Int, box: NSButton, nameField: NSTextField, neverShowBox: NSButton, noteLabel: NSTextField, view: NSStackView,
         wasStored: Bool) {
        self.index = index
        self.box = box
        self.nameField = nameField
        self.neverShowBox = neverShowBox
        self.noteLabel = noteLabel
        self.view = view
        self.wasStored = wasStored
    }

    var name: String { SecretRequestWindow.normalized(nameField.stringValue.trimmingCharacters(in: .whitespaces)) }
    var isTicked: Bool { box.state == .on }
    var neverShow: Bool { neverShowBox.state == .on }

    /// The header row: the column titles over the same widths.
    static func header() -> NSView {
        let labels: [NSView] = headers.map { (title: String) -> NSView in
            let label = SecretApprovalPanel.label(title, size: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        return line(labels)
    }

    /// `views` side by side, each at its column's width.
    static func line(_ views: [NSView]) -> NSStackView {
        for (view, width) in zip(views, widths) {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            if let label = view as? NSTextField, !label.isEditable { label.preferredMaxLayoutWidth = width }
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.alignment = .firstBaseline
        return stack
    }

    /// A small label for one cell, cut short with its whole text as its tooltip when `wraps` is off.
    static func cell(_ text: String, mono: Bool = false, wraps: Bool = true, color: NSColor = .labelColor) -> NSTextField {
        let label: NSTextField = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.textColor = color
        if !wraps {
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = text
        }
        return label
    }

    /// "…a1b2", or dots for a value under 12 characters, which shows nothing of itself.
    static func lastFourText(_ row: SourceRow) -> String {
        row.lastFour.map { (four: String) -> String in "\u{2026}" + four } ?? "\u{2022}\u{2022}\u{2022}\u{2022}"
    }

    /// "line 4", or "line 4 +2" when the same value is set in more places.
    static func placeText(_ row: SourceRow) -> String {
        row.alsoAt.isEmpty ? row.place : "\(row.place) +\(row.alsoAt.count)"
    }

    static let linkHoldsKeyHelp = "Left out: the link holds one of your keys."

    /// The page's host, and as its tooltip where it came from and the whole link. A link that holds a stored key
    /// (`holdsKey`, as masking finds them) shows none of itself: Import leaves it out.
    static func pageText(_ row: SourceRow, holdsKey: (String) -> Bool) -> (text: String, help: String?) {
        guard let hint = row.link else { return ("\u{2014}", nil) }
        guard !holdsKey(hint.url.absoluteString) else { return ("\u{2014}", linkHoldsKeyHelp) }
        let host: String = hint.url.host ?? hint.url.absoluteString
        switch hint {
        case .source(let url): return (host, "From the file: " + url.absoluteString)
        case .suggested(let page):
            return (host, "Suggested from its value or name: \(page.provider) \u{00B7} \(page.label)")
        }
    }
}

// MARK: rows and ticks

extension SecretFileImportSheet {
    /// A row for `row`: ticked as the report says, its tick off for a value that can't be stored.
    func addRow(_ row: SourceRow, index: Int) {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked))
        box.state = row.ticked ? .on : .off
        box.isEnabled = row.refusal == nil
        box.setAccessibilityLabel("Copy \(row.name)")
        let nameField = NSTextField(string: row.name)
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.isEnabled = row.refusal == nil
        nameField.setAccessibilityLabel("Name in Secrets")
        let holds: (String) -> Bool = { (text: String) -> Bool in SecretsStore.holdsStoredKey(text) }
        let page: (text: String, help: String?) = FileImportRow.pageText(row, holdsKey: holds)
        let pageCell: NSTextField = FileImportRow.cell(page.text, wraps: false)
        pageCell.toolTip = page.help
        let placeText: String = FileImportRow.placeText(row)
        let place: NSTextField = FileImportRow.cell(placeText, wraps: false, color: .secondaryLabelColor)
        if !row.alsoAt.isEmpty { place.toolTip = ([row.place] + row.alsoAt).joined(separator: ", ") }
        let noteLabel: NSTextField = FileImportRow.cell("", color: .secondaryLabelColor)
        let neverShowBox: NSButton = FileImportRow.neverShowBox(for: row)
        let cells: [NSView] = [box, nameField, neverShowBox, FileImportRow.cell(row.kind),
                               FileImportRow.cell(FileImportRow.lastFourText(row), mono: true), place, pageCell, noteLabel]
        let line: NSStackView = FileImportRow.line(cells)
        rowsStack.addArrangedSubview(line)
        let shown = FileImportRow(index: index, box: box, nameField: nameField, neverShowBox: neverShowBox, noteLabel: noteLabel,
                                  view: line, wasStored: stored.contains(row.name))
        rows.append(shown)
    }

    @objc func ticked() { refresh() }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { (row: FileImportRow) -> Bool in row.nameField === field }) else { return }
        let shown: String = SecretRequestWindow.normalized(field.stringValue)
        if shown != field.stringValue { field.stringValue = shown }
        // A name typed into a stored key's is unticked: replacing a key takes a tick by hand.
        let isStored: Bool = stored.contains(row.name)
        if isStored, !row.wasStored { row.box.state = .off }
        row.wasStored = isStored
        refresh()
    }

    /// Why a ticked row's name can't be saved: the name rule, or another ticked row with it (`repeated`, the names
    /// more than one ticked row has). A stored key's name is no problem: the row replaces that key.
    func nameProblem(_ name: String, repeated: Set<String>) -> String? {
        guard StoredSecretName.isValid(name) else { return StoredSecretName.rule }
        return repeated.contains(name) ? Self.sameNameNote : nil
    }

    /// Each row's note, the line above the rows, and whether Import… can go. Each row's name is read once, and the
    /// names ticked rows share are counted in one pass, so a refresh grows with the rows, not with their square.
    func refresh() {
        guard let report else { return }
        let names: [String] = rows.map { (row: FileImportRow) -> String in row.name }
        var tickedNames: [String] = []
        for (row, name) in zip(rows, names) where row.isTicked { tickedNames.append(name) }
        let repeated: Set<String> = SecretCopyIn.repeatedNames(tickedNames)
        var ok = true
        var ticked = 0
        for (row, name) in zip(rows, names) {
            let source: SourceRow = report.rows[row.index]
            let problem: String? = row.isTicked ? nameProblem(name, repeated: repeated) : nil
            if row.isTicked {
                ticked += 1
                if problem != nil { ok = false }
            }
            let note: (text: String, warns: Bool) = noteText(source, name: name, problem: problem,
                                                             fileNote: report.fileNote)
            row.noteLabel.stringValue = note.text
            row.noteLabel.textColor = note.warns ? .systemOrange : .secondaryLabelColor
            row.noteLabel.toolTip = note.text.isEmpty ? nil : note.text
            row.noteLabel.setAccessibilityLabel(note.warns ? "Warning: " + note.text : nil)
        }
        let found: Int = report.rows.count
        if record == nil {
            statusLabel.stringValue = "\(found) \(found == 1 ? "key" : "keys") found, \(ticked) ticked. " + Self.tickLine
        }
        importButton.isEnabled = !isBusy && record == nil && ticked > 0 && ok
    }

    /// A row's note: why it can't be stored, a problem with its name, that it replaces a key, or the report's note
    /// (unless the header says it for every row), a warning when it is one; after a note that its name came from an
    /// item's title.
    func noteText(_ row: SourceRow, name: String, problem: String?,
                  fileNote: SecretSources.Note?) -> (text: String, warns: Bool) {
        var lines: [String] = []
        if row.fromTitle { lines.append(Self.fromTitleNote) }
        var warns = false
        if let refusal = row.refusal {
            lines.append(refusal.sentence)
            warns = true
        } else if let problem {
            lines.append(problem)
            warns = true
        } else if stored.contains(name) {
            lines.append(Self.replacesNote)
            warns = true
        } else if let note = row.note, note != .replaces, note != fileNote {
            lines.append(note.sentence)
            warns = note.warns
        }
        return (lines.joined(separator: " "), warns)
    }

    /// Ticks or unticks the row named `name`, as a click would: for the self-test.
    func tick(_ name: String, _ on: Bool = true) {
        rows.first { (row: FileImportRow) -> Bool in row.name == name }?.box.state = on ? .on : .off
        refresh()
    }
}
