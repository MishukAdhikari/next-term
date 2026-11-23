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
    /// The window's smaller parts (`UIToken`), each a value only where this palette sets one: the rest come from its
    /// own tokens (`ui(_:)`), so a new theme needs none of them to look whole.
    public var ui: [UIToken: UInt32] = [:]
    /// Next Term's own two looks: a part the Mac draws in its own colour (a selected row) keeps the Mac's, as it
    /// always has, with its Increase Contrast variant. A theme takes its own instead.
    public var usesSystemColours = false
    /// The agents' marks (UIToken.agentOrder), made for dark: `Theme.mark` darkens each on light paper.
    public var agentMarks: [UInt32] = [0xD97757, 0x6EA4F7, 0xB48EF0, 0x4CC2A8, 0xE07AB8, 0xE2C35C, 0xA3AAB8, 0x5FC8E8]
    /// Git Log's graph lanes, in turn, made for dark as the agents' marks are.
    public var graphLanes: [UInt32] = [0x6EA4F7, 0x73C27A, 0xE5A55C, 0xC28FE0, 0x5FC4C4, 0xE5736F, 0xD6C86A, 0x9AA3F5]

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
    /// `token`'s colour in this palette: the one set, else the Mac's own (nil) when this is one of Next Term's looks
    /// and the part is one the Mac draws, else one made from this palette's own tokens.
    public func ui(_ token: UIToken) -> UInt32? {
        if let set = ui[token] { return set }
        if usesSystemColours && token.isSystemDrawn { return nil }
        return derived(token)
    }

    /// A part's colour made from the palette's own tokens, for a theme that doesn't set it.
    func derived(_ token: UIToken) -> UInt32 {
        switch token {
        case .listSelection, .rowSelection: return terminal.selection
        case .listSelectionInactive: return hoverFill
        case .listChosenText: return text
        case .listChosenMark: return gitModified
        case .rule, .quote, .codeStroke, .guide: return divider
        case .link: return code("#548AF7") ?? accent
        case .stderrFill: return Self.mix(background, failed, 0.10)
        case .errorFill: return Self.mix(background, failed, 0.16)
        case .errorText: return Self.readable(failed, on: ui(.errorFill) ?? background)
        case .warningFill: return Self.mix(background, attention, 0.14)
        case .gitRemote: return terminal.ansi[isDark ? 13 : 5]
        case .selectedSecondary: return Self.mix(textDim, text, 0.5)
        case .restingDot: return lineNumber
        case .pickerWindow, .pickerEditor: return background
        case .pickerPanel, .pickerList: return bar
        case .pickerTerminal: return tabHover
        case .ink: return text
        case .toastFill, .scrim: return isDark ? Self.mix(background, 0x000000, 0.5) : text
        case .onToast: return isDark ? text : background
        case .shadow: return 0x000000
        case .onAccent: return Self.contrast(0xFFFFFF, accent) >= Self.contrast(background, accent) ? 0xFFFFFF : background
        case .onStatus: return 0xFFFFFF
        }
    }

    /// `a` taken `amount` of the way to `b`, channel by channel.
    public static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

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
        divider: 0x393B40, hoverFill: 0x35373B,
        ui: [
            .listSelection: 0x2E436E, .listSelectionInactive: 0x2E3138, .listChosenText: 0xFFFFFF, .listChosenMark: 0xFFFFFF,
            .rule: 0x43454A, .quote: 0x4E5157, .codeStroke: 0x35373B, .guide: 0x45474D, .link: 0x548AF7,
            .stderrFill: 0x33282A, .errorFill: 0x3A2527, .errorText: 0xF0928D, .warningFill: 0x3D3223, .gitRemote: 0xB792E6,
            .selectedSecondary: 0xB8BBC2, .restingDot: 0x6E7178,
            .pickerEditor: 0x26282B, .pickerTerminal: 0x17181A, .pickerList: 0x222326,
            .ink: 0xFFFFFF, .toastFill: 0x000000, .onToast: 0xFFFFFF, .scrim: 0x000000, .shadow: 0x000000, .onAccent: 0xFFFFFF, .onStatus: 0xFFFFFF,
        ],
        usesSystemColours: true)

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
        divider: 0xC6C9D0, hoverFill: 0xD5D8DD,
        ui: [
            // A database's selected rows in the terminal's selection tint, not the Mac's saturated accent, which wants
            // white text. Go to File's chosen row keeps its text's own colours (white was unreadable on its soft blue).
            .listSelection: 0xD6E4FF, .rowSelection: 0xC3D3EE,
            .quote: 0xC9CCD2, .link: 0x1F5BD6,
            .stderrFill: 0xFDF0F0, .errorFill: 0xFBE3E3, .errorText: 0xB42318, .warningFill: 0xFFF4E0, .gitRemote: 0x7A3FC2,
            .selectedSecondary: 0x4A4F5A, .restingDot: 0xA0A4AD,
            .pickerWindow: 0xF4F5F7, .pickerPanel: 0xE4E6EA, .pickerEditor: 0xFFFFFF, .pickerTerminal: 0xD8DBE0, .pickerList: 0xCDD0D6,
            .ink: 0x000000, .toastFill: 0x000000, .onToast: 0xFFFFFF, .scrim: 0x000000, .shadow: 0x000000, .onAccent: 0xFFFFFF, .onStatus: 0xFFFFFF,
        ],
        usesSystemColours: true)

    /// Copper: deep slate with a copper accent and cream text, the warm dark look. Checked as Dark's colours are.
    public static let copper = ThemePalette(
        id: "copper", name: "Copper", isDark: true,
        background: 0x172124, bar: 0x242F32, tabHover: 0x323D41, border: 0x172124,
        text: 0xE6E1D2, textDim: 0xA5A092, accent: 0xBF885C,
        working: 0x758DFE, done: 0x7DB261, doneQuiet: 0x689055, failed: 0xE76F6E, attention: 0xEFC572,
        gitModified: 0x86A0EC, gitAdded: 0x8CBC76, gitUntracked: 0xD18C72, gitConflicted: 0xE57A6F, gitIgnored: 0x88866D,
        linesAdded: 0x8CBC76, linesRemoved: 0xDB7B70,
        blameText: 0x999486, blameHash: 0x7A7668, blameRecent: 0x7E92D6, blameNote: 0x7A7669,
        currentLine: 0x1F2A2D, gutterAdded: 0x678D56, gutterModified: 0x6273BB, gutterDeleted: 0xBD5D52,
        lineNumber: 0x7B7769, lineNumberCurrent: 0xA8A395,
        terminal: Terminal(ansi: [
            0x000000, 0xE46152, 0x719131, 0xA68933, 0x5B8FCD, 0xAB73AE, 0x3DA196, 0x82888A,
            0x656B6D, 0xF15750, 0x7EBC19, 0xE5BE45, 0x5EAAF7, 0xEF84D4, 0x58E2D3, 0xFFFFFF,
        ], foreground: 0xC3BEB0, background: 0x172124, cursor: 0xC5D3D7, selection: 0x683702),
        code: [
            "#BCBEC4": 0xC3BEB0, "#7A7E85": 0x858F8C, "#5F826B": 0x7F9580, "#67A37C": 0x93AD8C,
            "#6AAB73": 0xA7BE8A, "#CF8E6D": 0xD49A6A, "#2AACB8": 0xE2C28A, "#56A8F5": 0x9DBBD0,
            "#C77DBB": 0xCFA0A0, "#B3AE60": 0xC7B36E, "#D5B778": 0xD49A6A, "#BABABA": 0xCFC6B4,
            "#548AF7": 0x8FB4D6, "#73C27A": 0xA7BE8A, "#E5736F": 0xE0877A, "#6EA4F7": 0x8FB4D6,
            "#F75464": 0xEE6E6E, "#9876AA": 0xB7A3C9, "#6897BB": 0xE2C28A,
        ],
        divider: 0x323D41, hoverFill: 0x2E393D)

    /// Harbor: deep navy with a steel-blue accent, a cool dark look. Checked as Dark's colours are.
    public static let harbor = ThemePalette(
        id: "harbor", name: "Harbor", isDark: true,
        background: 0x142128, bar: 0x222F36, tabHover: 0x303D45, border: 0x142128,
        text: 0xD5E4EC, textDim: 0x95A3AB, accent: 0x509CD1,
        working: 0x5093FE, done: 0x57B878, doneQuiet: 0x4D9566, failed: 0xEB6B84, attention: 0xE5CA6B,
        gitModified: 0x70A6EE, gitAdded: 0x6EC28A, gitUntracked: 0xD5887A, gitConflicted: 0xE87581, gitIgnored: 0x82886E,
        linesAdded: 0x6EC28A, linesRemoved: 0xDE7780,
        blameText: 0x88969D, blameHash: 0x6A7880, blameRecent: 0x6995D7, blameNote: 0x6B787F,
        currentLine: 0x1D2A31, gutterAdded: 0x509165, gutterModified: 0x4B76BC, gutterDeleted: 0xC05962,
        lineNumber: 0x6B7981, lineNumberCurrent: 0x98A6AE,
        terminal: Terminal(ansi: [
            0x000000, 0xE75A68, 0x4F9748, 0x9A8E2E, 0x4393CC, 0x9D77C0, 0x2CA1A4, 0x81888D,
            0x646B6F, 0xF44D6D, 0x31C552, 0xD5C53E, 0x39B0F6, 0xDE88F3, 0x41E2E7, 0xFFFFFF,
        ], foreground: 0xB2C1C9, background: 0x142128, cursor: 0xC3D3DC, selection: 0x044A72),
        code: [
            "#BCBEC4": 0xB2C1C9, "#7A7E85": 0x738B9A, "#5F826B": 0x6E9488, "#67A37C": 0x7FB09A,
            "#6AAB73": 0x8CCBA8, "#CF8E6D": 0x6FB5E8, "#2AACB8": 0xE3C27F, "#56A8F5": 0xEBA58C,
            "#C77DBB": 0xC3A2E0, "#B3AE60": 0xD8C37A, "#D5B778": 0x6FB5E8, "#BABABA": 0xBFD0DA,
            "#548AF7": 0x7FB8F0, "#73C27A": 0x8CCBA8, "#E5736F": 0xEE8C80, "#6EA4F7": 0x7FB8F0,
            "#F75464": 0xF27080, "#9876AA": 0xA9A6E2, "#6897BB": 0xE3C27F,
        ],
        divider: 0x303D45, hoverFill: 0x2C3941)

    /// Dusk: midnight indigo with a lavender accent, a dark look. Checked as Dark's colours are.
    public static let dusk = ThemePalette(
        id: "dusk", name: "Dusk", isDark: true,
        background: 0x1B1E2D, bar: 0x292C3C, tabHover: 0x373A4B, border: 0x1B1E2D,
        text: 0xDDE0F1, textDim: 0x9C9FB0, accent: 0x918ECB,
        working: 0x638FFD, done: 0x58B77E, doneQuiet: 0x4E946A, failed: 0xE56D88, attention: 0xF6C174,
        gitModified: 0x7CA3EB, gitAdded: 0x6EC18F, gitUntracked: 0xD3897E, gitConflicted: 0xE47786, gitIgnored: 0x8A856D,
        linesAdded: 0x6EC18F, linesRemoved: 0xDA7984,
        blameText: 0x9093A4, blameHash: 0x717584, blameRecent: 0x7393D5, blameNote: 0x727584,
        currentLine: 0x242737, gutterAdded: 0x50906A, gutterModified: 0x5774B9, gutterDeleted: 0xBD5B66,
        lineNumber: 0x737685, lineNumberCurrent: 0x9FA2B3,
        terminal: Terminal(ansi: [
            0x000000, 0xE35E6F, 0x4F974F, 0xAC8633, 0x5391CC, 0xA076BA, 0x379FA9, 0x858790,
            0x686A73, 0xEF5374, 0x32C55E, 0xEDBA45, 0x54ADF5, 0xE089EA, 0x51DFEE, 0xFFFFFF,
        ], foreground: 0xBABDCE, background: 0x1B1E2D, cursor: 0xCBCFE4, selection: 0x423880),
        code: [
            "#BCBEC4": 0xBABDCE, "#7A7E85": 0x8184A6, "#5F826B": 0x7E9690, "#67A37C": 0x8DB5A4,
            "#6AAB73": 0x92CFA9, "#CF8E6D": 0xADA8EE, "#2AACB8": 0xEBAF8C, "#56A8F5": 0x8FBDF5,
            "#C77DBB": 0xDB9CCB, "#B3AE60": 0xE0C783, "#D5B778": 0xADA8EE, "#BABABA": 0xC9CBE3,
            "#548AF7": 0x8FB4F5, "#73C27A": 0x92CFA9, "#E5736F": 0xEE8C93, "#6EA4F7": 0x8FB4F5,
            "#F75464": 0xF57285, "#9876AA": 0xC2A6E8, "#6897BB": 0xEBAF8C,
        ],
        divider: 0x373A4B, hoverFill: 0x333647)

    /// Linen: warm cream paper with a dusty slate-blue accent, the warm light look. Most of Color Hunt's best-liked light
    /// palettes are cream, where Next Term Light is cool grey. Paper at L* 94, as soft as Light's; checked as Light's colours are.
    public static let linen = ThemePalette(
        id: "linen", name: "Linen", isDark: false,
        background: 0xF2EBE1, bar: 0xE7E0D6, tabHover: 0xDBD4CA, border: 0xCFC8BE,
        text: 0x312B23, textDim: 0x605A51, accent: 0x39638B,
        working: 0x4453B6, done: 0x3F6F31, doneQuiet: 0x4E7C42, failed: 0xB4283C, attention: 0x7F5A00,
        gitModified: 0x465BB4, gitAdded: 0x3F6F31, gitUntracked: 0x984F2A, gitConflicted: 0xB4283C, gitIgnored: 0x7B7964,
        linesAdded: 0x3F6F31, linesRemoved: 0xB4283C,
        blameText: 0x686259, blameHash: 0x837D74, blameRecent: 0x465BB4, blameNote: 0x837D74,
        currentLine: 0xEAE3D9, gutterAdded: 0x5A8B4C, gutterModified: 0x6477C4, gutterDeleted: 0xC26052,
        lineNumber: 0x857F76, lineNumberCurrent: 0x585249,
        terminal: Terminal(ansi: [
            0x2E2C28, 0xBD3733, 0x447635, 0x88631B, 0x4453B6, 0x8840AC, 0x297571, 0x66635F,
            0x55524E, 0xA02C28, 0x38682A, 0x725014, 0x39469E, 0x733095, 0x206867, 0x6B6864,
        ], foreground: 0x312B23, background: 0xF2EBE1, cursor: 0x39638B, selection: 0xBED5ED),
        code: [
            "#BCBEC4": 0x312B23, "#7A7E85": 0x71695F, "#5F826B": 0x5E6E5A, "#67A37C": 0x4A6B45,
            "#6AAB73": 0x4F6B1E, "#CF8E6D": 0x9A4220, "#2AACB8": 0x1F6B6B, "#56A8F5": 0x2F5A8A,
            "#C77DBB": 0x7E3E78, "#B3AE60": 0x7A5E00, "#D5B778": 0x9A4220, "#BABABA": 0x5A4FA0,
            "#548AF7": 0x2F5A8A, "#73C27A": 0x4F6B1E, "#E5736F": 0xB4283C, "#6EA4F7": 0x2F5A8A,
            "#F75464": 0xB4283C, "#9876AA": 0x6A3FA0, "#6897BB": 0x1F6B6B,
        ],
        divider: 0xCFC8BE, hoverFill: 0xDED7CC)

    /// Sage: pale sage paper with a moss-green accent, a calm light look. Paper at L* 94; checked as Light's colours are.
    public static let sage = ThemePalette(
        id: "sage", name: "Sage", isDark: false,
        background: 0xECEEDF, bar: 0xE0E3D4, tabHover: 0xD4D7C8, border: 0xC9CBBC,
        text: 0x2C2D22, textDim: 0x5B5C50, accent: 0x3A6D40,
        working: 0x0260B0, done: 0x376F3C, doneQuiet: 0x477C4B, failed: 0xB4283C, attention: 0x7F5A00,
        gitModified: 0x1366AD, gitAdded: 0x376F3C, gitUntracked: 0x945326, gitConflicted: 0xB4283C, gitIgnored: 0x797A66,
        linesAdded: 0x376F3C, linesRemoved: 0xB4283C,
        blameText: 0x626457, blameHash: 0x7E8072, blameRecent: 0x1366AD, blameNote: 0x7E8072,
        currentLine: 0xE3E6D7, gutterAdded: 0x538C57, gutterModified: 0x4680BE, gutterDeleted: 0xBE644E,
        lineNumber: 0x808274, lineNumberCurrent: 0x535448,
        terminal: Terminal(ansi: [
            0x2C2D27, 0xB93E2D, 0x3B7740, 0x826621, 0x0260B0, 0x6D4EBA, 0x2E7472, 0x63645E,
            0x53544D, 0x9C3222, 0x306835, 0x6D5319, 0x045196, 0x5A3EA1, 0x256768, 0x696A63,
        ], foreground: 0x2C2D22, background: 0xECEEDF, cursor: 0x3A6D40, selection: 0xC1DAC3),
        code: [
            "#BCBEC4": 0x2C2D22, "#7A7E85": 0x686D61, "#5F826B": 0x5A6E55, "#67A37C": 0x3F6B45,
            "#6AAB73": 0x8A5418, "#CF8E6D": 0x2C7840, "#2AACB8": 0x1F6A86, "#56A8F5": 0x2F4F9A,
            "#C77DBB": 0x8A3E6E, "#B3AE60": 0x6B6510, "#D5B778": 0x2C7840, "#BABABA": 0x4F5A9A,
            "#548AF7": 0x1F5C9A, "#73C27A": 0x8A5418, "#E5736F": 0xB4283C, "#6EA4F7": 0x1F5C9A,
            "#F75464": 0xB4283C, "#9876AA": 0x6A40A0, "#6897BB": 0x1F6A86,
        ],
        divider: 0xC9CBBC, hoverFill: 0xD7DACB)

    /// The themes Next Term ships, each by its own name: more come as more palettes, light or dark.
    public static let builtIn: [ThemePalette] = [nextDark, copper, harbor, dusk, nextLight, linen, sage]

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

/// The window's smaller parts that take a colour of their own: a theme sets the ones it wants, and the rest are made
/// from its tokens (`ThemePalette.derived`). Next Term's own looks set each to the colour it has always had.
public enum UIToken: String, CaseIterable, Sendable {
    /// A chosen row in Go to File and the popups like it; a selected row in a list that isn't focused (Git Log).
    case listSelection, listSelectionInactive
    /// A selected row in a themed list or grid (a database's): the Mac's accent in Next Term Dark.
    case rowSelection
    /// The name and its matched letters on a chosen row in Go to File and the popups like it.
    case listChosenText, listChosenMark
    /// Lines: a markdown rule, a quote's bar, a notebook cell's edge, the window column's guide.
    case rule, quote, codeStroke, guide
    case link
    /// A notebook's stderr and error output, and a notice's wash (an editor banner).
    case stderrFill, errorFill, errorText, warningFill
    /// A remote branch in Git Log.
    case gitRemote
    /// A chosen row's second line in the window switcher; a window's resting dot in the window column.
    case selectedSecondary, restingDot
    /// The layout picker's small windows.
    case pickerWindow, pickerPanel, pickerEditor, pickerTerminal, pickerList
    /// The colour of a wash over a surface (white on dark, black on light), at the alpha its view chooses.
    case ink
    /// A small notice over the terminal, and its text; the veil over a pane; a shadow.
    case toastFill, onToast, scrim, shadow
    /// Text or a symbol drawn on the accent (a filled button, a pill).
    case onAccent
    /// A state's mark drawn on its coloured dot (✓ ✕ ! on green, red, orange), in the tab bar and the menus.
    case onStatus

    /// Drawn by the Mac in Next Term's own looks (`ThemePalette.usesSystemColours`).
    public var isSystemDrawn: Bool { self == .rowSelection }

    /// The agents whose marks `ThemePalette.agentMarks` holds, in its order.
    public static let agentOrder = ["claude", "codex", "commandCode", "gemini", "qwen", "opencode", "cursor", "copilot"]
}
