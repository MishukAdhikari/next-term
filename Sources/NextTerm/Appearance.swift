import AppKit
import NextTermCore

// The editor's and the terminal's font families: chosen in Settings (or by an import), applied at once
// to every open editor and terminal. Nothing chosen keeps Next Term's own face (Theme.monoFont).

extension Preferences {
    /// The editor's font family (nil: Next Term's default face).
    static var editorFontFamily: String? {
        get { family(forKey: "editorFontFamily") }
        set { setFamily(newValue, forKey: "editorFontFamily") }
    }

    /// The terminal's font family (nil: Next Term's default face).
    static var terminalFontFamily: String? {
        get { family(forKey: "terminalFontFamily") }
        set { setFamily(newValue, forKey: "terminalFontFamily") }
    }

    private static func family(forKey key: String) -> String? {
        guard let name = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    private static func setFamily(_ family: String?, forKey key: String) {
        if let family, !family.isEmpty { UserDefaults.standard.set(family, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

extension AppDelegate {
    /// Sets the editor's font family (nil: the default) and lays every editor out again.
    func setEditorFontFamily(_ family: String?) {
        Preferences.editorFontFamily = family
        controllers.forEach { $0.editorArea.applyFont() }
    }

    /// Sets the terminal's font family (nil: the default) in every open terminal.
    func setTerminalFontFamily(_ family: String?) {
        Preferences.terminalFontFamily = family
        let font = Theme.terminalFont(size: fontSize)
        for controller in controllers { for tab in controller.tabs { tab.view.font = font } }
    }
}

/// A font menu for Settings: Next Term's default face first, then every installed monospaced family. A
/// chosen family that is no longer installed stays listed, marked, so the menu says why the default shows.
final class FontFamilyPopup: NSPopUpButton {
    /// The families, read once: listing them measures every installed font.
    nonisolated(unsafe) private static var families: [String]?

    var onChange: ((String?) -> Void)?

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(chosen)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ selected: String?) {
        removeAllItems()
        addItem(withTitle: "Next Term default (\(Theme.defaultFontName))")
        menu?.addItem(.separator())
        let families = Self.families ?? FontCatalog.monospacedFamilies()
        Self.families = families
        for family in families {
            addItem(withTitle: family)
            lastItem?.representedObject = family
        }
        guard let selected else { return selectItem(at: 0) }
        if let item = itemArray.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(selected) == .orderedSame }) {
            select(item)
        } else {
            addItem(withTitle: "\(selected) (not installed)")
            lastItem?.representedObject = selected
            select(lastItem)
        }
    }

    @objc private func chosen() {
        onChange?(selectedItem?.representedObject as? String)
    }
}

/// Settings › Terminal: the terminal's font. Applied as it changes.
final class TerminalSettingsView: NSView {
    private let font = FontFamilyPopup()

    override init(frame: NSRect) {
        super.init(frame: frame)
        font.onChange = { family in AppDelegate.shared.setTerminalFontFamily(family) }
        let label = NSTextField(labelWithString: "Font:")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let fontRow = NSStackView(views: [label, font])
        fontRow.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "Monospaced fonts installed on this Mac. The size is shared with the editor (⌘+ and ⌘-).")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [fontRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ImportCoordinator.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc func refresh() {
        font.show(Preferences.terminalFontFamily)
    }
}
