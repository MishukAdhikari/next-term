import AppKit
import NextTermCore
import SwiftTerm

/// Dark palette.
enum Theme {
    static let background = NSColor(hex: 0x1E1F22)
    static let bar = NSColor(hex: 0x2B2D30)
    static let tabHover = NSColor(hex: 0x393B40)
    static let border = NSColor(hex: 0x1E1F22)
    static let text = NSColor(hex: 0xDFE1E5)
    static let textDim = NSColor(hex: 0x9DA0A8)
    static let accent = NSColor(hex: 0x3574F0)

    static let working = NSColor(hex: 0x3574F0)
    static let done = NSColor(hex: 0x5FB865)
    static let failed = NSColor(hex: 0xE55765)
    static let attention = NSColor(hex: 0xF2C55C)

    // Git status in the project tree.
    static let gitModified = NSColor(hex: 0x6EA4F7)
    static let gitAdded = NSColor(hex: 0x73C27A)
    static let gitUntracked = NSColor(hex: 0xD9876C)
    static let gitConflicted = NSColor(hex: 0xF0706E)
    static let gitIgnored = NSColor(hex: 0x86876A)
    static let linesAdded = NSColor(hex: 0x73C27A)
    static let linesRemoved = NSColor(hex: 0xE5736F)

    // Git blame in the editor: the column's text, and the shade of the newest lines (older ones fade
    // towards the background).
    static let blameText = NSColor(hex: 0x8C8F96)
    static let blameHash = NSColor(hex: 0x62666E)
    static let blameRecent = NSColor(hex: 0x5C86D1)
    static let blameNote = NSColor(hex: 0x5F636B)

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

    static let terminalForeground = NSColor(hex: defaultTerminal.foreground)
    static let caret = NSColor(hex: defaultTerminal.cursor)
    static let selection = NSColor(hex: defaultTerminal.selection)

    /// ANSI colours, normal then bright.
    static let ansi: [UInt32] = [
        0x000000, 0xF0524F, 0x5C962C, 0xA68A0D, 0x3993D4, 0xA771BF, 0x00A3A3, 0x808080,
        0x595959, 0xFF4050, 0x4FC414, 0xE5BF00, 0x1FB0FF, 0xED7EED, 0x00E5E5, 0xFFFFFF,
    ]

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

    /// The terminal's colours: the user's own (Settings › Terminal › Colours) over Next Term's.
    static func applyColours(to view: TerminalView) {
        let colours = terminalColours(Preferences.terminalPalette)
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

    /// Next Term's own terminal colours (the background is the window's).
    static let defaultTerminal = TerminalColours(ansi: ansi, foreground: 0xBCBEC4, background: 0x1E1F22, cursor: 0xCED0D6, selection: 0x214283)

    /// Every terminal colour, each from `palette` when it sets it, else Next Term's own.
    static func terminalColours(_ palette: TerminalPalette?) -> TerminalColours {
        var colours = defaultTerminal
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
