import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostColourTests {
    @Test func readsOnADarkTheme() {
        let colour = GhostColour.derive(foreground: 0xD4D4D4, background: 0x1E1E1E, increaseContrast: false)
        #expect(GhostColour.contrast(colour, 0x1E1E1E) >= 3 && colour != 0xD4D4D4)
        let stronger = GhostColour.derive(foreground: 0xD4D4D4, background: 0x1E1E1E, increaseContrast: true)
        #expect(GhostColour.contrast(stronger, 0x1E1E1E) >= 4.5 && stronger != 0xD4D4D4)
        // Muted: less contrast than the text itself.
        #expect(GhostColour.contrast(colour, 0x1E1E1E) < GhostColour.contrast(0xD4D4D4, 0x1E1E1E))
    }

    @Test func readsOnALightTheme() {
        let colour = GhostColour.derive(foreground: 0x000000, background: 0xFFFFFF, increaseContrast: false)
        #expect(GhostColour.contrast(colour, 0xFFFFFF) >= 3 && colour != 0x000000)
        let stronger = GhostColour.derive(foreground: 0x000000, background: 0xFFFFFF, increaseContrast: true)
        #expect(GhostColour.contrast(stronger, 0xFFFFFF) >= 4.5 && stronger != 0x000000)
    }

    /// Text as dim as the background, or the background itself: the floor is reached past it.
    @Test func aLowContrastThemeStillReads() {
        for (foreground, background) in [(0x1E1E1E, 0x1E1E1E), (0x303030, 0x202020), (0xF0F0F0, 0xFFFFFF)] as [(UInt32, UInt32)] {
            #expect(GhostColour.contrast(GhostColour.derive(foreground: foreground, background: background, increaseContrast: false), background) >= 3)
            #expect(GhostColour.contrast(GhostColour.derive(foreground: foreground, background: background, increaseContrast: true), background) >= 4.5)
        }
    }

    @Test func contrastIsWCAGs() {
        #expect(abs(GhostColour.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(GhostColour.contrast(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(GhostColour.contrast(0x123456, 0x123456) == 1)
    }
}
