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
