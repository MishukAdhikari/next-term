import Foundation
import Testing
@testable import NextTermCore

@Suite struct TerminalPaletteTests {
    @Test func hexColours() {
        #expect(TerminalPalette.hex("#1e1f22")?.rgb == 0x1E1F22)
        #expect(TerminalPalette.hex("1E1F22")?.alpha == 1)
        #expect(TerminalPalette.hex(" #abc ")?.rgb == 0xAABBCC)
        let alpha = TerminalPalette.hex("#21428380")
        #expect(alpha?.rgb == 0x214283 && abs((alpha?.alpha ?? 0) - 128.0 / 255) < 0.0001)
        #expect(TerminalPalette.hex("#abcd")?.rgb == 0xAABBCC && TerminalPalette.hex("#abcd")?.alpha == 13.0 / 15)
        for bad in ["", "#", "#12", "#12345", "#1234567", "red", "#ggg", "0x123456", "+12345", "#123456789"] {
            #expect(TerminalPalette.hex(bad) == nil, "\(bad)")
        }
    }

    @Test func componentsAndBlending() {
        #expect(TerminalPalette.rgb(1, 0.5, 0) == 0xFF8000)
        #expect(TerminalPalette.rgb(0, 0, 0) == 0)
        #expect(TerminalPalette.rgb(1.2, 0, 0) == nil)
        #expect(TerminalPalette.rgb(.nan, 0, 0) == nil)
        #expect(TerminalPalette.rgb(nil, 0, 0) == nil)
        #expect(TerminalPalette.blend(0xFFFFFF, alpha: 0.5, over: 0x000000) == 0x808080)
        #expect(TerminalPalette.blend(0x214283, alpha: 1, over: 0x000000) == 0x214283)
        #expect(TerminalPalette.blend(0x214283, alpha: 0, over: 0x1E1F22) == 0x1E1F22)
        #expect(TerminalPalette.display(0x1E1F22) == "#1E1F22")
    }

    @Test func storedPalettesAreChecked() throws {
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[1] = 0xFF0000
        let palette = TerminalPalette(name: "iTerm2", ansi: ansi, foreground: 0xEEEEEE, background: 0x101010)
        #expect(palette.count == 3 && !palette.isEmpty)
        #expect(TerminalPalette(name: "none").isEmpty)
        let data = try #require(palette.data)
        #expect(TerminalPalette.decode(data) == palette)

        // Short or long lists are padded or cut to 16; colours keep to 24 bits.
        #expect(TerminalPalette(name: "x", ansi: [0x123456]).ansi.count == 16)
        #expect(TerminalPalette(name: "x", ansi: Array(repeating: 1, count: 20)).ansi.count == 16)
        #expect(TerminalPalette(name: "x", foreground: 0xFF123456).foreground == 0x123456)

        // A damaged value is ignored rather than trusted.
        let fifteen = #"{"name":"x","ansi":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]}"#
        #expect(TerminalPalette.decode(Data(fifteen.utf8)) == nil)
        let tooBig = #"{"name":"x","foreground":16777216,"ansi":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]}"#
        #expect(TerminalPalette.decode(Data(tooBig.utf8)) == nil)
        #expect(TerminalPalette.decode(Data("not json".utf8)) == nil)
    }
}
