import AppKit
import NextTermCore
import SwiftTerm

/// Next Term's colours (plan 049). Each is the light or dark palette's, as the view it is drawn in looks: a colour
/// here resolves when it is drawn, so text, fills drawn in `draw(_:)` and `updateLayer()`, windows' and text views'
/// backgrounds all follow a change of appearance by themselves. A layer's colour set once is set with
/// `themedBackground(_:)` (ThemeLayers), which sets it again on a change.
enum Theme {
    /// The palettes for light and dark windows. More looks are more palettes, one chosen for each.
    nonisolated(unsafe) static var palettes: (light: ThemePalette, dark: ThemePalette) = (.nextLight, .nextDark) {
        didSet { MainActor.assumeIsolated { ThemeWatch.changed() } }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
    }

    /// The look `view` is drawn in, as it is now: the nearest appearance set on it, a view above it or its window, else
    /// the app's. AppKit updates a view's own `effectiveAppearance` only on its next layout or display, so read just
    /// after the app's look changed it is still the old one: what set a colour from it then stayed in the old look
    /// (a terminal, a layer's fill) while the rest of the window changed.
    @MainActor
    static func appearance(of view: NSView) -> NSAppearance {
        var next: NSView? = view
        while let current = next {
            if let set = current.appearance { return set }
            next = current.superview
        }
        return view.window?.appearance ?? NSApp.effectiveAppearance
    }

    /// The palette for `appearance` (the app's, when none is given).
    static func palette(for appearance: NSAppearance? = nil) -> ThemePalette {
        isDark(appearance ?? NSApp.effectiveAppearance) ? palettes.dark : palettes.light
    }

    /// Whether the app is drawn light now.
    static var isLight: Bool { !palette().isDark }

    /// A colour that is `key` of the palette its view is drawn in.
    static func dynamic(_ key: KeyPath<ThemePalette, UInt32>) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(hex: palette(for: appearance)[keyPath: key]) }
    }

    /// A part's colour (`UIToken`) in the palette its view is drawn in. A part the Mac draws in Next Term's own looks
    /// (a selected row) is the Mac's colour there, `system`.
    static func ui(_ token: UIToken, system: NSColor = .selectedContentBackgroundColor) -> NSColor {
        NSColor(name: nil) { appearance in palette(for: appearance).ui(token).map(colour) ?? system }
    }

    /// A token's value as a colour. Pure white and pure black are the Mac's own `white` and `black`, as the literals
    /// they replaced were: at an alpha, an sRGB white blends a step apart from the Mac's white on screen, and Next
    /// Term Dark must not move by one pixel.
    static func colour(_ rgb: UInt32) -> NSColor {
        switch rgb {
        case 0xFFFFFF: .white
        case 0x000000: .black
        default: NSColor(hex: rgb)
        }
    }

    /// A colour the Mac names by its purpose (a label, a separator, red for a failure), on the window's own paper: in
    /// Next Term's own looks the Mac's colour, exactly as it was, with its Increase Contrast variant; in a theme, the
    /// theme's token for that purpose, so a label reads on Linen's cream or Copper's slate as the theme meant.
    static func system(_ role: SystemRole) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette = palette(for: appearance)
            return palette.usesSystemColours ? role.mac : NSColor(hex: role.value(in: palette))
        }
    }

    /// A purpose the Mac has a colour for, and the palette's token for the same purpose.
    enum SystemRole {
        case label, secondaryLabel, tertiaryLabel, quaternaryLabel, placeholder, separator, windowBackground
        case accent, focusRing, red, green, orange, blue
        /// Text a person types or reads in a text view: opaque, where `label` is a little translucent.
        case text
        case link

        var mac: NSColor {
            switch self {
            case .label: .labelColor
            case .secondaryLabel: .secondaryLabelColor
            case .tertiaryLabel: .tertiaryLabelColor
            case .quaternaryLabel: .quaternaryLabelColor
            case .placeholder: .placeholderTextColor
            case .separator: .separatorColor
            case .windowBackground: .windowBackgroundColor
            case .accent: .controlAccentColor
            case .focusRing: .keyboardFocusIndicatorColor
            case .red: .systemRed
            case .green: .systemGreen
            case .orange: .systemOrange
            case .blue: .systemBlue
            case .text: .textColor
            case .link: .linkColor
            }
        }

        /// The theme's colour for the same purpose.
        func value(in palette: ThemePalette) -> UInt32 {
            switch self {
            case .label, .text: palette.text
            case .secondaryLabel, .placeholder: palette.textDim
            case .tertiaryLabel: palette.lineNumber
            case .quaternaryLabel: palette.hoverFill
            case .separator: palette.divider
            case .windowBackground: palette.bar
            case .accent, .focusRing, .blue: palette.accent
            case .red: palette.failed
            case .green: palette.done
            case .orange: palette.attention
            case .link: palette.ui(.link) ?? palette.accent
            }
        }
    }

    /// An agent's mark (UIToken.agentOrder), from the palette, darkened on light paper as `mark` does.
    static func agentMark(_ agent: String) -> NSColor {
        let index = UIToken.agentOrder.firstIndex(of: agent) ?? 0
        return NSColor(name: nil) { appearance in
            let palette = palette(for: appearance)
            return markColour(palette.agentMarks[index % palette.agentMarks.count], in: palette)
        }
    }

    /// Git Log's lane colour for `index`, from the palette, darkened on light paper as `mark` does.
    static func graphLane(_ index: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette = palette(for: appearance), lanes = palette.graphLanes
            return markColour(lanes[((index % lanes.count) + lanes.count) % lanes.count], in: palette)
        }
    }

    private static func markColour(_ rgb: UInt32, in palette: ThemePalette) -> NSColor {
        palette.isDark ? NSColor(hex: rgb) : NSColor(hex: ThemePalette.readable(rgb, on: palette.bar, ratio: 3))
    }

    /// One colour for light windows and another for dark, each a token's (at its own alpha): never a literal.
    static func pair(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in isDark(appearance) ? dark : light }
    }

    /// A mark's colour made for dark (an agent's, a graph lane's): as it is on dark, and on light darkened until it stands
    /// 3:1 on the bars, so a pale yellow or a sky blue never fades into the paper.
    static func mark(_ rgb: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(hex: rgb) : NSColor(hex: ThemePalette.readable(rgb, on: palette(for: appearance).bar, ratio: 3))
        }
    }

    /// A wash over a surface, as the dark look had it in white: in white on dark, in black on light at four fifths, so a
    /// hover or a selection shows on paper as plainly as it does on dark.
    static func overlay(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette = palette(for: appearance)
            return colour(palette.ui(.ink) ?? 0).withAlphaComponent(palette.isDark ? alpha : alpha * 0.8)
        }
    }

    static let background = dynamic(\.background)
    static let bar = dynamic(\.bar)
    static let tabHover = dynamic(\.tabHover)
    static let border = dynamic(\.border)
    /// A line that is always seen: between panes, around popups (`border` may be the background itself).
    static let divider = dynamic(\.divider)
    /// A row under the pointer.
    static let hoverFill = dynamic(\.hoverFill)
    static let text = dynamic(\.text)
    static let textDim = dynamic(\.textDim)
    static let accent = dynamic(\.accent)

    static let working = dynamic(\.working)
    static let done = dynamic(\.done)
    /// Done, quietly: the green three-quarters over the bar. Nothing needs you yet, so the mark doesn't pull the eye, and
    /// it stays 3:1 against the bar, the selected tab and a hovered one. Increase Contrast keeps `done`.
    static let doneQuiet = dynamic(\.doneQuiet)
    /// The small counts beside marks ("+3", the window column's count): tabular figures, so they never shift.
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let failed = dynamic(\.failed)
    static let attention = dynamic(\.attention)

    // Git status in the project tree.
    static let gitModified = dynamic(\.gitModified)
    static let gitAdded = dynamic(\.gitAdded)
    static let gitUntracked = dynamic(\.gitUntracked)
    static let gitConflicted = dynamic(\.gitConflicted)
    static let gitIgnored = dynamic(\.gitIgnored)
    static let linesAdded = dynamic(\.linesAdded)
    static let linesRemoved = dynamic(\.linesRemoved)

    // Git blame in the editor: the column's text, and the shade of the newest lines (older ones fade
    // towards the background).
    static let blameText = dynamic(\.blameText)
    static let blameHash = dynamic(\.blameHash)
    static let blameRecent = dynamic(\.blameRecent)
    static let blameNote = dynamic(\.blameNote)

    // The editor's own.
    static let currentLine = dynamic(\.currentLine)
    static let gutterAdded = dynamic(\.gutterAdded)
    static let gutterModified = dynamic(\.gutterModified)
    static let gutterDeleted = dynamic(\.gutterDeleted)
    static let lineNumber = dynamic(\.lineNumber)
    static let lineNumberCurrent = dynamic(\.lineNumberCurrent)

    static func color(for change: GitChange?) -> NSColor {
        switch change {
        case .modified?, .renamed?: return gitModified
        case .added?: return gitAdded
        case .untracked?: return gitUntracked
        case .conflicted?: return gitConflicted
        case .ignored?: return gitIgnored
        case .deleted?: return gitModified // a folder that lost a file has changed
        case nil: return text
        }
    }

    static let terminalForeground = dynamic(\.terminal.foreground)
    static let caret = dynamic(\.terminal.cursor)
    static let selection = dynamic(\.terminal.selection)

    /// The dark look's ANSI colours, normal then bright.
    static let ansi: [UInt32] = ThemePalette.nextDark.terminal.ansi

    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 8...32

    /// The one monospaced face for code: the terminal, and the Find fields and results. JetBrains Mono
    /// (an open-source font) when installed, otherwise the system's SF Mono.
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if weight == .regular, let font = NSFont(name: "JetBrainsMono-Regular", size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The editor's face: the family chosen in Settings › Editor, else the one above.
    static func editorFont(size: CGFloat) -> NSFont { font(family: Preferences.editorFontFamily, size: size) }

    /// The terminal's face: the family chosen in Settings › Terminal, else the one above.
    static func terminalFont(size: CGFloat) -> NSFont { font(family: Preferences.terminalFontFamily, size: size) }

    /// A chosen family's regular face (its nearest one when it has no regular weight), or the default face
    /// when none is chosen or the family is no longer installed. Safe off the main thread (notebooks lay out
    /// there).
    static func font(family: String?, size: CGFloat) -> NSFont {
        guard let family, !family.isEmpty else { return monoFont(size: size) }
        // SF Mono is the system's own face: not an installed family, so it is asked for as the system's.
        if family.caseInsensitiveCompare(FontCatalog.systemMonospacedFamily) == .orderedSame {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: NSFont.Weight.regular]
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        guard let font = NSFont(descriptor: descriptor, size: size),
              font.familyName?.caseInsensitiveCompare(family) == .orderedSame else { return monoFont(size: size) }
        return font
    }

    /// What the default face is called, for the font menus.
    static var defaultFontName: String { NSFont(name: "JetBrainsMono-Regular", size: 12) != nil ? "JetBrains Mono" : "SF Mono" }

    static func apply(to view: TerminalView, fontSize: CGFloat) {
        view.font = terminalFont(size: fontSize)
        applyColours(to: view)
    }

    /// The terminal's colours: the user's own (Settings › Terminal › Colours) over Next Term's for the view's look.
    /// ThemeWatch applies them again when the look changes.
    static func applyColours(to view: TerminalView) {
        let colours = terminalColours(Preferences.terminalPalette, base: terminalDefaults(for: MainActor.assumeIsolated { appearance(of: view) }))
        view.nativeForegroundColor = NSColor(hex: colours.foreground)
        view.nativeBackgroundColor = NSColor(hex: colours.background)
        view.caretColor = NSColor(hex: colours.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: colours.selection)
        view.installColors(colours.ansi.map { rgb in
            SwiftTerm.Color(red8: UInt16((rgb >> 16) & 0xFF), green8: UInt16((rgb >> 8) & 0xFF), blue8: UInt16(rgb & 0xFF))
        })
    }

    struct TerminalColours: Equatable {
        var ansi: [UInt32]
        var foreground, background, cursor, selection: UInt32
    }

    /// Next Term's own dark terminal colours (the background is the window's).
    static let defaultTerminal = terminalDefaults(ThemePalette.nextDark)

    static func terminalDefaults(_ palette: ThemePalette) -> TerminalColours {
        let t = palette.terminal
        return TerminalColours(ansi: t.ansi, foreground: t.foreground, background: t.background, cursor: t.cursor, selection: t.selection)
    }

    /// Next Term's terminal colours for a view that looks like `appearance`.
    static func terminalDefaults(for appearance: NSAppearance) -> TerminalColours { terminalDefaults(palette(for: appearance)) }

    /// Every terminal colour, each from `palette` when it sets it, else Next Term's own (`base`: the dark look's).
    static func terminalColours(_ palette: TerminalPalette?, base: TerminalColours = Theme.defaultTerminal) -> TerminalColours {
        var colours = base
        guard let palette else { return colours }
        for (index, colour) in palette.ansi.enumerated() where index < colours.ansi.count {
            if let colour { colours.ansi[index] = colour }
        }
        colours.foreground = palette.foreground ?? colours.foreground
        colours.background = palette.background ?? colours.background
        colours.cursor = palette.cursor ?? colours.cursor
        colours.selection = palette.selection ?? colours.selection
        return colours
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Single-line labels that truncate instead of wrapping.
///
/// Attributed text without a paragraph style falls back to word wrapping and ignores the label's own
/// line-break mode, so every attributed label gets an explicit style from here.
enum Typography {
    /// Capitals (or figures) set apart by `tracking`, as short capitals read best, and none after the last character, so
    /// the word centres as it would without it.
    static func capitals(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat) -> NSAttributedString {
        let set = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard tracking != 0, !text.isEmpty else { return set }
        let whole = text as NSString
        let last: NSRange = whole.rangeOfComposedCharacterSequence(at: whole.length - 1)
        if last.location > 0 { set.addAttribute(.tracking, value: tracking, range: NSRange(location: 0, length: last.location)) }
        return set
    }

    static func paragraph(_ mode: NSLineBreakMode, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = mode
        style.alignment = alignment
        return style
    }

    /// One line, never wrapping; overflow is truncated with `mode` (Finder truncates names in the middle).
    static func singleLine(_ field: NSTextField, truncation mode: NSLineBreakMode) {
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.cell?.truncatesLastVisibleLine = true
        field.lineBreakMode = mode
    }

    /// One word space widened to `width` points: the gap between two runs on one line, instead of
    /// several typed spaces.
    static func gap(_ width: CGFloat, font: NSFont) -> NSAttributedString {
        let space = NSAttributedString(string: " ", attributes: [.font: font])
        return NSAttributedString(string: " ", attributes: [.font: font, .kern: max(0, width - space.size().width)])
    }

    /// Shortens plain text the system lays out itself (notification titles, menu items): one ellipsis
    /// character, never a silent cut, no space left before the ellipsis.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Applies a truncation style to a whole attributed string.
    static func truncating(_ text: NSAttributedString, _ mode: NSLineBreakMode, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.paragraphStyle, value: paragraph(mode, alignment: alignment), range: NSRange(location: 0, length: copy.length))
        return copy
    }
}

/// The display options a mark follows: Increase Contrast (System Settings › Accessibility › Display) makes the marks
/// that are quiet on purpose plain again. Read as each is drawn; a change is passed on as AgentSpinner.changed.
enum DisplayOptions {
    static var increasesContrast: Bool {
        increasesContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The self-test's setting, nil for the system's.
    static var increasesContrastOverride: Bool? {
        didSet { NotificationCenter.default.post(name: AgentSpinner.changed, object: nil) }
    }
}

/// A row of a list or grid drawn in the window's own colours: selected, the theme's soft selection tint (the
/// editor's and the terminal's), so the row's text keeps its colour and reads on it in every theme. AppKit's
/// default, a saturated accent fill that expects white text, made themed text (dark on light) unreadable.
/// When the list isn’t focused, the quieter hover fill.
class ThemedRowView: NSTableRowView {
    /// The palette leaves the selected row to the Mac (Next Term Dark): AppKit draws it, as it always has.
    private var macDraws: Bool { Theme.palette(for: Theme.appearance(of: self)).ui(.rowSelection) == nil }

    override func drawSelection(in dirtyRect: NSRect) {
        if macDraws { return super.drawSelection(in: dirtyRect) }
        (isEmphasized ? Theme.ui(.rowSelection) : Theme.hoverFill).setFill()
        bounds.fill()
    }

    /// The text on a selected row stays as it is: it is drawn for the tint, not for an accent fill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { macDraws ? super.interiorBackgroundStyle : .normal }
}

/// Git Log's rows (and its diffs' and Branch Compare's): full width, so the graph's lines stay unbroken across the
/// selected row; the editor's selection when focused, `listSelectionInactive` when not.
final class GitLogRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.selection : Theme.ui(.listSelectionInactive)).setFill()
        bounds.fill()
    }
}
