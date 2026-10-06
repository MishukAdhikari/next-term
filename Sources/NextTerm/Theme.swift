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

    static let terminalForeground = NSColor(hex: 0xBCBEC4)
    static let caret = NSColor(hex: 0xCED0D6)
    static let selection = NSColor(hex: 0x214283)

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

    static func terminalFont(size: CGFloat) -> NSFont { monoFont(size: size) }

    static func apply(to view: TerminalView, fontSize: CGFloat) {
        view.font = terminalFont(size: fontSize)
        view.nativeForegroundColor = terminalForeground
        view.nativeBackgroundColor = background
        view.caretColor = caret
        view.selectedTextBackgroundColor = selection
        view.installColors(ansi.map { rgb in
            SwiftTerm.Color(red8: UInt16((rgb >> 16) & 0xFF), green8: UInt16((rgb >> 8) & 0xFF), blue8: UInt16(rgb & 0xFF))
        })
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
