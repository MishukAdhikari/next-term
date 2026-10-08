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

    /// The terminal's own colours (nil: Next Term's). Checked as it is read, so a damaged value is ignored.
    static var terminalPalette: TerminalPalette? {
        get { UserDefaults.standard.data(forKey: "terminalPalette").flatMap(TerminalPalette.decode) }
        set { setPalette(newValue, forKey: "terminalPalette") }
    }

    /// The last custom colours set, kept while Next Term's are in use so Settings can offer them again.
    static var customTerminalPalette: TerminalPalette? {
        get { UserDefaults.standard.data(forKey: "customTerminalPalette").flatMap(TerminalPalette.decode) }
        set { setPalette(newValue, forKey: "customTerminalPalette") }
    }

    private static func setPalette(_ palette: TerminalPalette?, forKey key: String) {
        if let data = palette?.data { UserDefaults.standard.set(data, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
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

    /// Sets the terminal's colours (nil: Next Term's) in every open terminal. Custom colours are also kept
    /// for Settings to offer again after switching back to Next Term's.
    func setTerminalPalette(_ palette: TerminalPalette?) {
        Preferences.terminalPalette = palette
        if let palette { Preferences.customTerminalPalette = palette }
        for controller in controllers { for tab in controller.tabs { Theme.applyColours(to: tab.view) } }
    }
}

/// The terminal's colours at a glance: the background with text on it, the 16 ANSI colours (normal over
/// bright), then the cursor and the selection.
final class PaletteSwatches: NSView {
    var colours = Theme.defaultTerminal {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }

    static let cell: CGFloat = 11
    static let gap: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let grid = 10 * (Self.cell + Self.gap)
        return NSSize(width: 40 + 8 + grid, height: 2 * Self.cell + Self.gap)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = intrinsicContentSize.height
        let sample = NSRect(x: 0, y: 0, width: 40, height: height)
        NSColor(hex: colours.background).setFill()
        NSBezierPath(roundedRect: sample, xRadius: 3, yRadius: 3).fill()
        let text = NSAttributedString(string: "Aa", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(hex: colours.foreground),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: sample.midX - size.width / 2, y: sample.midY - size.height / 2))
        let step = Self.cell + Self.gap
        for (index, rgb) in colours.ansi.enumerated() {
            let column = CGFloat(index % 8), row: CGFloat = index < 8 ? 1 : 0 // normal on top (the view isn't flipped)
            square(NSRect(x: 48 + column * step, y: row * step, width: Self.cell, height: Self.cell), rgb)
        }
        square(NSRect(x: 48 + 8 * step, y: step, width: Self.cell, height: Self.cell), colours.cursor)
        square(NSRect(x: 48 + 8 * step, y: 0, width: Self.cell, height: Self.cell), colours.selection)
    }

    private func square(_ rect: NSRect, _ rgb: UInt32) {
        NSColor(hex: rgb).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func updateAccessibility() {
        let label = "Terminal colours: background \(TerminalPalette.display(colours.background)), text \(TerminalPalette.display(colours.foreground))"
        setAccessibilityLabel(label)
        toolTip = "Background, text, the 16 ANSI colours, cursor (top right) and selection (bottom right)"
    }
}

/// A font menu for Settings: Next Term's default face first, then every installed monospaced family. A
/// chosen family that is no longer installed stays listed, marked, so the menu says why the default shows.
final class FontFamilyPopup: NSPopUpButton {
    /// The families, listed once and off the main thread: listing them measures every installed font, which
    /// on a Mac with many fonts takes seconds. Until then the menu holds the default and the chosen family.
    nonisolated(unsafe) private static var families: [String]?
    nonisolated(unsafe) private static var listing = false
    nonisolated static let listed = Notification.Name("NextTermFontFamiliesListed")

    var onChange: ((String?) -> Void)?
    private var selected: String?

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(chosen)
        NotificationCenter.default.addObserver(self, selector: #selector(fill), name: Self.listed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ selected: String?) {
        self.selected = selected
        fill()
        Self.listFamilies()
    }

    @objc private func fill() {
        removeAllItems()
        addItem(withTitle: "Next Term default (\(Theme.defaultFontName))")
        menu?.addItem(.separator())
        for family in Self.families ?? [] {
            addItem(withTitle: family)
            lastItem?.representedObject = family
        }
        guard let selected else { return selectItem(at: 0) }
        if let item = itemArray.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(selected) == .orderedSame }) {
            select(item)
        } else {
            // Marked only once the list is in: before that, it isn't known.
            addItem(withTitle: Self.families == nil ? selected : "\(selected) (not installed)")
            lastItem?.representedObject = selected
            select(lastItem)
        }
    }

    private static func listFamilies() {
        guard families == nil, !listing else { return }
        listing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = FontCatalog.monospacedFamilies()
            DispatchQueue.main.async {
                families = found
                NotificationCenter.default.post(name: listed, object: nil)
            }
        }
    }

    @objc private func chosen() {
        selected = selectedItem?.representedObject as? String
        onChange?(selected)
    }
}

/// Settings › Terminal: the terminal's font and colours, its cursor, scrollback and where new tabs open.
/// Applied as they change.
final class TerminalSettingsView: NSView {
    /// Where LangGraph Studio's links open (WebLinks): the last row, before the note.
    let studioLinks = StudioLinksCheckbox.make()
    private let font = FontFamilyPopup()
    private let colours = NSPopUpButton()
    private let swatches = PaletteSwatches()
    let behaviour = TerminalBehaviourControls()

    override init(frame: NSRect) {
        super.init(frame: frame)
        font.onChange = { family in AppDelegate.shared.setTerminalFontFamily(family) }
        colours.target = self
        colours.action = #selector(coloursChanged)
        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 10
            return stack
        }
        let note = NSTextField(wrappingLabelWithString: "Monospaced fonts installed on this Mac. The size is shared with the editor (⌘+ and ⌘-). Colours brought over by an import are listed under Colours; Next Term default goes back to Next Term’s own, and they stay in the menu to choose again.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [row("Font:", [font]), row("Colours:", [colours]), row("", [swatches])] + behaviour.rows(row) + [note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.insertArrangedSubview(row("Links:", [studioLinks]), at: stack.arrangedSubviews.firstIndex(of: note) ?? 0)
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
        colours.removeAllItems()
        colours.addItem(withTitle: "Next Term default")
        let current = Preferences.terminalPalette
        if let custom = current ?? Preferences.customTerminalPalette {
            colours.addItem(withTitle: custom.name)
            colours.lastItem?.representedObject = custom
        }
        colours.selectItem(at: current == nil ? 0 : 1)
        swatches.colours = Theme.terminalColours(current)
        behaviour.refresh()
    }

    @objc private func coloursChanged() {
        AppDelegate.shared.setTerminalPalette(colours.selectedItem?.representedObject as? TerminalPalette)
        swatches.colours = Theme.terminalColours(Preferences.terminalPalette)
    }
}
