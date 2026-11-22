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

    /// Next Term's light look, made easy on the eyes: a soft paper white for what you read and write (the terminal, the
    /// editor), never a glaring pure white, a quiet warm grey for the bars around them, and soft near-black text rather
    /// than black, so the contrast is plenty (about 13:1) without glare. Every colour is checked against its
    /// background: text 4.5:1 at the least, marks 3:1. The code's colours are IntelliJ Light's for the roles the dark
    /// theme gives JetBrains' dark ones.
    public static let nextLight = ThemePalette(
        id: "next-term-light", name: "Next Term Light", isDark: false,
        background: 0xF7F7F4, bar: 0xE6E6E1, tabHover: 0xD7D7D0, border: 0xCFCFC8,
        text: 0x2B2D31, textDim: 0x5A5D63, accent: 0x2459C2,
        working: 0x2459C2, done: 0x2E8540, doneQuiet: 0x3F8A4B, failed: 0xC02A37, attention: 0xA86A00,
        gitModified: 0x2F6AD0, gitAdded: 0x2E8540, gitUntracked: 0xB0532A, gitConflicted: 0xC02A37, gitIgnored: 0x8A8A70,
        linesAdded: 0x2E8540, linesRemoved: 0xC02A37,
        blameText: 0x6C707E, blameHash: 0x8A8D96, blameRecent: 0x2F6AD0, blameNote: 0x8A8D96,
        currentLine: 0xECECE6, gutterAdded: 0x55A562, gutterModified: 0x5F8BDB, gutterDeleted: 0xD2625D,
        lineNumber: 0x8E9198, lineNumberCurrent: 0x5A5D63,
        // GitHub's light terminal colours (Primer), with those that fade on light made darker: every colour 4.5:1 on the
        // paper at the least, yellow included, and white and bright white readable greys (4.5:1 too), as VS Code's light
        // terminal has them: a program that writes in white for a dark terminal stays readable.
        terminal: Terminal(ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x666E78,
            0x57606A, 0xA40E26, 0x1A7F37, 0x7D4E00, 0x1A65D8, 0xA142C7, 0x137A8A, 0x646B75,
        ], foreground: 0x2B2D31, background: 0xF7F7F4, cursor: 0x3A6FC4, selection: 0xC9DDF2),
        code: [
            "#BCBEC4": 0x2B2D31, // text, operators, types
            "#7A7E85": 0x6E7176, // comments: 4.5:1, never faint
            "#5F826B": 0x557560, // doc comments
            "#67A37C": 0x3D7A4E, // doc tags
            "#6AAB73": 0x067D17, // strings
            "#CF8E6D": 0x0033B3, // keywords
            "#2AACB8": 0x1750EB, // numbers
            "#56A8F5": 0x00627A, // functions
            "#C77DBB": 0x871094, // properties, constants
            "#B3AE60": 0x7D6A00, // decorators
            "#D5B778": 0x0033B3, // tags
            "#BABABA": 0x174AD4, // attributes
            "#548AF7": 0x1F5BD6, // links
            "#73C27A": 0x067D17, // inserted
            "#E5736F": 0xC42B1C, // deleted
            "#6EA4F7": 0x1750EB, // changed
            "#F75464": 0xD01C2E, // invalid
            "#9876AA": 0x6F42C1,
            "#6897BB": 0x1750EB,
        ],
        divider: 0xCFCFC8, hoverFill: 0xD7D7D0)

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
