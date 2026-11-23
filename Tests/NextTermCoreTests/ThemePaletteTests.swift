import Testing
@testable import NextTermCore

/// The looks' palettes (plan 049): the light one easy on the eyes and readable, the code's colours mapped, and the
/// Appearance setting's default.
@Suite struct ThemePaletteTests {
    let light = ThemePalette.nextLight

    @Test func theLightLookIsSoftPaperNotGlaringWhite() {
        #expect(light.background != 0xFFFFFF && light.terminal.background != 0xFFFFFF)
        #expect(ThemePalette.contrast(light.text, light.background) < 16) // soft near-black, not pure black on white
        #expect(ThemePalette.contrast(light.text, light.background) >= 7)
    }

    @Test func itsTextAndTerminalColoursRead() {
        for colour in [light.text, light.textDim, light.accent, light.failed] {
            #expect(ThemePalette.contrast(colour, light.bar) >= 4.5)
        }
        for slot in Array(1...6) + Array(9...14) {
            #expect(ThemePalette.contrast(light.terminal.ansi[slot], light.terminal.background) >= 4.5, "slot \(slot)")
        }
    }

    @Test func codeColoursMapAndUnknownOnesAreMadeReadable() {
        #expect(light.code("#cf8e6d") == 0x0030A8) // keywords, whatever the case
        let unknown = light.code("#F0E68C")! // a pale yellow the map doesn't name
        #expect(ThemePalette.contrast(unknown, light.background) >= 4.5)
        #expect(ThemePalette.nextDark.code("#F0E68C") == 0xF0E68C) // the dark look draws the theme as it is
    }

    @Test func contrastIsWCAGs() {
        #expect(abs(ThemePalette.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(ThemePalette.contrast(0x777777, 0xFFFFFF) - 4.48) < 0.02)
    }

    @Test func appearanceKeepsDarkForEveryoneWhoHadIt() {
        #expect(AppAppearance(stored: nil) == .dark)
        #expect(AppAppearance(stored: "system") == .system)
        #expect(AppAppearance(stored: "nonsense") == .dark)
    }
}

@Suite struct NamedThemesTests {
    /// The code's colours are looked up by the dark syntax theme's "#RRGGBB": a key written any other way is never used.
    @Test func everyThemesCodeKeysAreTheDarkThemesHex() {
        for palette in ThemePalette.builtIn {
            for key in palette.code.keys {
                #expect(key.hasPrefix("#") && key.count == 7 && key == key.uppercased(), "\(palette.name): \(key)")
            }
            if palette.id != ThemePalette.nextDark.id { #expect(palette.code("#cf8e6d") == palette.code["#CF8E6D"], "\(palette.name)") }
        }
    }

    @Test func eachSideOffersItsOwnThemesAndFallsBackToNextTerms() {
        #expect(ThemePalette.lightThemes.map(\.id) == ["next-term-light", "linen", "sage"])
        #expect(ThemePalette.darkThemes.map(\.id) == ["next-term-dark", "copper", "harbor", "dusk"])
        #expect(ThemePalette.theme("linen", dark: false) == .linen)
        #expect(ThemePalette.theme("linen", dark: true) == .nextDark) // a light theme is never the dark side's
        #expect(ThemePalette.theme("gone", dark: false) == .nextLight)
    }

    @Test func newThemesReadOnTheirOwnPaper() {
        let ratio = ThemePalette.contrast
        for p in [ThemePalette.copper, .harbor, .dusk, .linen, .sage] {
            for (name, c) in [("text", p.text), ("textDim", p.textDim), ("accent", p.accent), ("working", p.working), ("failed", p.failed)] {
                #expect(ratio(c, p.background) >= 4.5 && ratio(c, p.bar) >= 4.5, "\(p.name) \(name)")
            }
            for value in p.code.values { #expect(ratio(value, p.background) >= 4.5, "\(p.name) code") }
            #expect(p.terminal.background == p.background)
        }
    }
}

/// The window's smaller parts (UIToken): Next Term's own looks keep exactly the colours they had before the parts were
/// tokens (this table is those colours, taken from the views), and every theme's parts read on what they sit on.
@Suite struct ThemeUITokenTests {
    /// Next Term Dark, frozen: a change here changes Dark, which must not change.
    static let dark: [UIToken: UInt32] = [
        .listSelection: 0x2E436E, .listSelectionInactive: 0x2E3138, .listChosenText: 0xFFFFFF, .listChosenMark: 0xFFFFFF,
        .rule: 0x43454A, .quote: 0x4E5157, .codeStroke: 0x35373B, .guide: 0x45474D, .link: 0x548AF7,
        .stderrFill: 0x33282A, .errorFill: 0x3A2527, .errorText: 0xF0928D, .warningFill: 0x3D3223, .gitRemote: 0xB792E6,
        .selectedSecondary: 0xB8BBC2, .restingDot: 0x6E7178,
        .pickerWindow: 0x1E1F22, .pickerPanel: 0x2B2D30, .pickerEditor: 0x26282B, .pickerTerminal: 0x17181A, .pickerList: 0x222326,
        .ink: 0xFFFFFF, .toastFill: 0x000000, .onToast: 0xFFFFFF, .scrim: 0x000000, .shadow: 0x000000, .onAccent: 0xFFFFFF, .onStatus: 0xFFFFFF,
    ]
    /// Next Term Light, frozen likewise; its chosen rows take their text's colours (white was unreadable on the soft blue).
    static let light: [UIToken: UInt32] = [
        .listSelection: 0xD6E4FF, .listSelectionInactive: 0xD5D8DD, .rowSelection: 0xC3D3EE, .listChosenText: 0x2A2C31,
        .rule: 0xC6C9D0, .quote: 0xC9CCD2, .codeStroke: 0xC6C9D0, .guide: 0xC6C9D0, .link: 0x1F5BD6,
        .stderrFill: 0xFDF0F0, .errorFill: 0xFBE3E3, .errorText: 0xB42318, .warningFill: 0xFFF4E0, .gitRemote: 0x7A3FC2,
        .selectedSecondary: 0x4A4F5A, .restingDot: 0xA0A4AD,
        .pickerWindow: 0xF4F5F7, .pickerPanel: 0xE4E6EA, .pickerEditor: 0xFFFFFF, .pickerTerminal: 0xD8DBE0, .pickerList: 0xCDD0D6,
        .ink: 0x000000, .toastFill: 0x000000, .onToast: 0xFFFFFF, .scrim: 0x000000, .shadow: 0x000000, .onAccent: 0xFFFFFF, .onStatus: 0xFFFFFF,
    ]

    @Test func nextTermDarkKeepsEveryColourItHad() {
        for token in UIToken.allCases where token != .rowSelection {
            #expect(ThemePalette.nextDark.ui(token) == Self.dark[token], "Next Term Dark's \(token)")
        }
        #expect(ThemePalette.nextDark.ui(.rowSelection) == nil, "Next Term Dark's selected rows stay the Mac's")
        #expect(ThemePalette.nextDark.usesSystemColours && ThemePalette.nextLight.usesSystemColours)
        #expect(ThemePalette.nextDark.agentMarks == [0xD97757, 0x6EA4F7, 0xB48EF0, 0x4CC2A8, 0xE07AB8, 0xE2C35C, 0xA3AAB8, 0x5FC8E8])
        #expect(ThemePalette.nextDark.graphLanes == [0x6EA4F7, 0x73C27A, 0xE5A55C, 0xC28FE0, 0x5FC4C4, 0xE5736F, 0xD6C86A, 0x9AA3F5])
    }

    @Test func nextTermLightKeepsItsColoursAndReadsOnItsChosenRows() {
        for (token, value) in Self.light { #expect(ThemePalette.nextLight.ui(token) == value, "Next Term Light's \(token)") }
        #expect(ThemePalette.nextLight.ui(.listChosenMark) == ThemePalette.nextLight.gitModified)
    }

    @Test func everyThemeHasEveryPartAndItReads() {
        for p in ThemePalette.builtIn where !p.usesSystemColours {
            for token in UIToken.allCases { #expect(p.ui(token) != nil, "\(p.name) \(token)") }
            func ui(_ t: UIToken) -> UInt32 { p.ui(t) ?? 0 }
            func reads(_ a: UInt32, _ b: UInt32, _ ratio: Double, _ what: String) {
                #expect(ThemePalette.contrast(a, b) >= ratio, "\(p.name): \(what) \(ThemePalette.contrast(a, b))")
            }
            reads(ui(.onAccent), p.accent, 3, "text on the accent")
            reads(ui(.listChosenText), ui(.listSelection), 4.5, "a chosen row's name")
            reads(ui(.listChosenMark), ui(.listSelection), 3, "a chosen row's matched letters")
            reads(p.text, ui(.rowSelection), 4.5, "text on a selected row")
            reads(ui(.errorText), ui(.errorFill), 4.5, "an error on its wash")
            reads(p.text, ui(.warningFill), 4.5, "text on a notice")
            reads(ui(.link), p.background, 4.5, "a link")
            reads(ui(.gitRemote), p.bar, 3, "a remote branch")
            reads(ui(.selectedSecondary), ui(.listSelection), 3, "a chosen row's second line")
        }
    }
}
