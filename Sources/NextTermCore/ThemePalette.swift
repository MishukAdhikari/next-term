import Foundation

/// The colours of one look of Next Term (plan 049): the window's surfaces and text, the marks, git's colours, the
/// terminal's palette, and the code's colours as they map from the dark theme's. Values are sRGB as 0xRRGGBB. Theme
/// (in the app) picks the palette for the appearance a view is drawn in, so one palette serves light windows and
/// another dark ones; more palettes are more looks, chosen per appearance, as Ghostty's `light:X,dark:Y` does.
public struct ThemePalette: Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool

    // Surfaces and text.
    public var background: UInt32
    public var bar: UInt32
    public var tabHover: UInt32
    public var border: UInt32
    public var text: UInt32
    public var textDim: UInt32
    public var accent: UInt32

    // Marks.
    public var working: UInt32
    public var done: UInt32
    public var doneQuiet: UInt32
    public var failed: UInt32
    public var attention: UInt32

    // Git.
    public var gitModified: UInt32
    public var gitAdded: UInt32
    public var gitUntracked: UInt32
    public var gitConflicted: UInt32
    public var gitIgnored: UInt32
    public var linesAdded: UInt32
    public var linesRemoved: UInt32
    public var blameText: UInt32
    public var blameHash: UInt32
    public var blameRecent: UInt32
    public var blameNote: UInt32

    // The editor's own.
    public var currentLine: UInt32
    public var gutterAdded: UInt32
    public var gutterModified: UInt32
    public var gutterDeleted: UInt32
    public var lineNumber: UInt32
    public var lineNumberCurrent: UInt32

    // The terminal.
    public var terminal: Terminal

    /// The code's colours: the dark syntax theme's colour (upper-case "#RRGGBB") to this palette's. A colour not here is
    /// drawn as `derivedCode` makes it.
    public var code: [String: UInt32]

    /// A line between panes and around popups, always seen (`border` may be the background itself, as dark's is).
    public var divider: UInt32 = 0
    /// A row under the pointer, in lists and the tab list.
    public var hoverFill: UInt32 = 0

    public struct Terminal: Equatable, Sendable {
        /// ANSI colours, normal then bright.
        public var ansi: [UInt32]
        public var foreground: UInt32
        public var background: UInt32
        public var cursor: UInt32
        public var selection: UInt32

        public init(ansi: [UInt32], foreground: UInt32, background: UInt32, cursor: UInt32, selection: UInt32) {
            self.ansi = ansi
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.selection = selection
        }
    }

    /// A code colour as this palette draws it: its own for a colour of the dark theme it maps, the colour itself in a
    /// dark palette, else the colour darkened until it reads on a light background (4.5:1 at the least).
    public func code(_ darkHex: String) -> UInt32? {
        let key = darkHex.uppercased()
        if let mapped = code[key] { return mapped }
        guard let value = Self.parse(key) else { return nil }
        return isDark ? value : Self.readable(value, on: background)
    }

    /// "#RRGGBB" (or "RRGGBB") as a value.
    public static func parse(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return value
    }

    // MARK: contrast

    /// WCAG 2's relative luminance.
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG 2's contrast ratio, 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `rgb` moved towards black (on a light background) or white (on a dark one), in small steps, until it reaches
    /// `ratio` against `background`; its hue stays.
    public static func readable(_ rgb: UInt32, on background: UInt32, ratio: Double = 4.5) -> UInt32 {
        guard contrast(rgb, background) < ratio else { return rgb }
        let towardsBlack = luminance(background) > 0.5
        var colour = rgb
        for step in 1...20 {
            let keep = 1 - Double(step) * 0.05
            func mix(_ shift: UInt32) -> UInt32 {
                let c = Double((rgb >> shift) & 0xFF)
                return UInt32((towardsBlack ? c * keep : c + (255 - c) * (1 - keep)).rounded()) << shift
            }
            colour = mix(16) | mix(8) | mix(0)
            if contrast(colour, background) >= ratio { break }
        }
        return colour
    }
}

extension ThemePalette {
    /// Next Term's dark look, as it has always been.
    public static let nextDark = ThemePalette(
        id: "next-term-dark", name: "Next Term Dark", isDark: true,
        background: 0x1E1F22, bar: 0x2B2D30, tabHover: 0x393B40, border: 0x1E1F22,
        text: 0xDFE1E5, textDim: 0x9DA0A8, accent: 0x3574F0,
        working: 0x3574F0, done: 0x5FB865, doneQuiet: 0x529558, failed: 0xE55765, attention: 0xF2C55C,
        gitModified: 0x6EA4F7, gitAdded: 0x73C27A, gitUntracked: 0xD9876C, gitConflicted: 0xF0706E, gitIgnored: 0x86876A,
        linesAdded: 0x73C27A, linesRemoved: 0xE5736F,
        blameText: 0x8C8F96, blameHash: 0x62666E, blameRecent: 0x5C86D1, blameNote: 0x5F636B,
        currentLine: 0x26282E, gutterAdded: 0x549159, gutterModified: 0x375FAD, gutterDeleted: 0xC75450,
        lineNumber: 0x4B5059, lineNumberCurrent: 0xA1A3AB,
        terminal: Terminal(ansi: [
            0x000000, 0xF0524F, 0x5C962C, 0xA68A0D, 0x3993D4, 0xA771BF, 0x00A3A3, 0x808080,
            0x595959, 0xFF4050, 0x4FC414, 0xE5BF00, 0x1FB0FF, 0xED7EED, 0x00E5E5, 0xFFFFFF,
        ], foreground: 0xBCBEC4, background: 0x1E1F22, cursor: 0xCED0D6, selection: 0x214283),
        code: [:],
        divider: 0x393B40, hoverFill: 0x35373B)

    /// Next Term's light look, made easy on the eyes. The paper you read and write on (the terminal, the editor) is a
    /// soft cool grey at about the lightness of the Mac's own window grey (L* 93), not near-white: on light the glare
    /// comes from the area at full brightness, and the terminal and editor are almost all of the window. The bars sit a
    /// clear step darker (they are Dark's text colour, so the two looks mirror each other), and both take Dark's faint
    /// blue-grey, so Light and Dark look like one product. Text stays near 12:1: comfort comes from lowering the paper,
    /// not greying the words. Every colour is checked against the paper and the bars: text 4.5:1 at the least, marks
    /// 3:1. The code's colours are IntelliJ Light's for the roles the dark theme gives JetBrains' dark ones, each made
    /// darker where the grey paper needs it.
    public static let nextLight = ThemePalette(
        id: "next-term-light", name: "Next Term Light", isDark: false,
        background: 0xEBECEF, bar: 0xDFE1E5, tabHover: 0xD2D5DA, border: 0xC6C9D0,
        text: 0x2A2C31, textDim: 0x575B63, accent: 0x2557C0,
        working: 0x2557C0, done: 0x277237, doneQuiet: 0x3A7F47, failed: 0xB8283A, attention: 0x8C5800,
        gitModified: 0x285FBC, gitAdded: 0x277237, gitUntracked: 0x9E4A25, gitConflicted: 0xB8283A, gitIgnored: 0x7A7A62,
        linesAdded: 0x277237, linesRemoved: 0xB8283A,
        blameText: 0x5E6270, blameHash: 0x7A7E88, blameRecent: 0x285FBC, blameNote: 0x7A7E88,
        currentLine: 0xE2E4E8, gutterAdded: 0x458F52, gutterModified: 0x4F7BCB, gutterDeleted: 0xC85A55,
        lineNumber: 0x838790, lineNumberCurrent: 0x4F535B,
        // Every colour 4.5:1 on the paper at the least, yellow included, and white and bright white readable greys, as
        // VS Code's light terminal has them: a program that writes in white for a dark terminal stays readable.
        terminal: Terminal(ansi: [
            0x2A2C31, 0xC4283A, 0x2A7A3B, 0x8A6200, 0x2557C0, 0x7E3FBF, 0x16757A, 0x5F646D,
            0x4F535B, 0xA61E2E, 0x1F6B30, 0x744F00, 0x1D49A6, 0x6A2FA6, 0x0E6870, 0x646973,
        ], foreground: 0x2A2C31, background: 0xEBECEF, cursor: 0x2557C0, selection: 0xC3D3EE),
        code: [
            "#BCBEC4": 0x2A2C31, // text, operators, types
            "#7A7E85": 0x666A72, // comments: 4.5:1, never faint
            "#5F826B": 0x4F6E59, // doc comments
            "#67A37C": 0x346B44, // doc tags
            "#6AAB73": 0x0B6B1A, // strings
            "#CF8E6D": 0x0030A8, // keywords
            "#2AACB8": 0x1748D4, // numbers
            "#56A8F5": 0x005A70, // functions
            "#C77DBB": 0x7A0E87, // properties, constants
            "#B3AE60": 0x6E5C00, // decorators
            "#D5B778": 0x0030A8, // tags
            "#BABABA": 0x1745C4, // attributes
            "#548AF7": 0x1F55C8, // links
            "#73C27A": 0x0B6B1A, // inserted
            "#E5736F": 0xB8283A, // deleted
            "#6EA4F7": 0x1748D4, // changed
            "#F75464": 0xBE1A2B, // invalid
            "#9876AA": 0x6239B0,
            "#6897BB": 0x1748D4,
        ],
        divider: 0xC6C9D0, hoverFill: 0xD5D8DD)

    /// The themes Next Term ships, each by its own name: more come as more palettes, light or dark.
    public static let builtIn: [ThemePalette] = [nextDark, nextLight]

    /// The light themes and the dark ones, for Settings' two pickers.
    public static var lightThemes: [ThemePalette] { builtIn.filter { !$0.isDark } }
    public static var darkThemes: [ThemePalette] { builtIn.filter(\.isDark) }

    /// The theme with `id` for that side, else Next Term's own for it.
    public static func theme(_ id: String?, dark: Bool) -> ThemePalette {
        let side = dark ? darkThemes : lightThemes
        return side.first { $0.id == id } ?? (dark ? nextDark : nextLight)
    }
}

/// Which look the app takes (Settings › General › Appearance): the Mac's own, or always light or dark.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    /// What the user chose, or dark: Next Term's look before there was a choice, kept for everyone who had it.
    public init(stored: String?) {
        self = stored.flatMap(AppAppearance.init(rawValue:)) ?? .dark
    }

    public var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
