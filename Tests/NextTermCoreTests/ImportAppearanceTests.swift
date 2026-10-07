import Foundation
import Testing
@testable import NextTermCore

/// A pretend Mac with a few fonts, so font rows don't depend on what this machine has installed.
let testFonts = FontCatalog { name in
    let installed: [String: InstalledFont] = [
        "fira code": InstalledFont(family: "Fira Code", monospaced: true),
        "firacode-regular": InstalledFont(family: "Fira Code", monospaced: true),
        "jetbrains mono": InstalledFont(family: "JetBrains Mono", monospaced: true),
        "jetbrainsmono-regular": InstalledFont(family: "JetBrains Mono", monospaced: true),
        "menlo": InstalledFont(family: "Menlo", monospaced: true),
        "menlo-regular": InstalledFont(family: "Menlo", monospaced: true),
        "sfmono-regular": InstalledFont(family: "SF Mono", monospaced: true),
        "hack": InstalledFont(family: "Hack", monospaced: true),
        "helvetica": InstalledFont(family: "Helvetica", monospaced: false),
    ]
    return installed[name.trimmingCharacters(in: .whitespaces).lowercased()]
}

@Suite struct ImportAppearanceTests {
    @Test func cssFontLists() {
        #expect(ImportFonts.families("'Fira Code', Menlo, monospace") == ["Fira Code", "Menlo", "monospace"])
        #expect(ImportFonts.families("\"Odd, Name\",Menlo") == ["Odd, Name", "Menlo"])
        #expect(ImportFonts.families("  JetBrains Mono  ") == ["JetBrains Mono"])
        #expect(ImportFonts.families(" , ,") == [])
        #expect(ImportFonts.families(Array(repeating: "A", count: 30).joined(separator: ",")).count == 20)
    }

    @Test func theFirstInstalledMonospacedFontComesOver() {
        let first = ImportFonts.row(.editor, list: "'Fira Code', Menlo, monospace", source: "editor.fontFamily", fonts: testFonts)
        #expect(first.setting?.setting == .editorFontFamily("Fira Code"))
        #expect(first.setting?.source == "editor.fontFamily 'Fira Code', Menlo, monospace")
        #expect(first.setting?.note == nil && first.skipped.isEmpty)

        // Passed over: not installed, then not monospaced; the reasons are listed and the row says why.
        let later = ImportFonts.row(.terminal, list: "Operator Mono, Helvetica, menlo", source: "terminal.integrated.fontFamily", fonts: testFonts)
        #expect(later.setting?.setting == .terminalFontFamily("Menlo"))
        #expect(later.setting?.note == "the first font in the list that this Mac has")
        #expect(later.skipped == [SkippedItem("Terminal font “Operator Mono”", ImportFonts.notInstalled),
                                  SkippedItem("Terminal font “Helvetica”", ImportFonts.notMonospaced)])

        // A PostScript name comes over as its family.
        #expect(ImportFonts.row(.terminal, list: "JetBrainsMono-Regular", source: "Normal Font", fonts: testFonts).setting?.setting
                == .terminalFontFamily("JetBrains Mono"))

        // Generic names only: the app's default, nothing to bring.
        let generic = ImportFonts.row(.editor, list: "monospace, ui-monospace", source: "x", fonts: testFonts)
        #expect(generic.setting == nil && generic.skipped.isEmpty)

        // Nothing usable: each name reported.
        let none = ImportFonts.row(.editor, list: "Comic Code, Helvetica", source: "x", fonts: testFonts)
        #expect(none.setting == nil && none.skipped.count == 2)

        // A credential pasted in a font setting is never shown.
        let secret = ImportFonts.row(.editor, list: "ghp_abcdefghijklmnopqrstuvwxyz0123456789, Menlo", source: "x", fonts: testFonts)
        #expect(secret.setting?.setting == .editorFontFamily("Menlo"))
        #expect(!"\(secret)".contains("ghp_"))
        #expect(secret.skipped == [SkippedItem("Editor font", ImportFonts.credential)])
    }

    @Test func colourRows() {
        #expect(ImportColours.row(TerminalPalette(name: "x"), source: "s") == nil)
        let some = TerminalPalette(name: "VS Code", foreground: 0xFFFFFF)
        #expect(ImportColours.row(some, source: "s")?.note == "1 of 20 colours; the others stay Next Term's")
        let full = TerminalPalette(name: "Full", ansi: Array(repeating: 1, count: 16), foreground: 1, background: 2, cursor: 3, selection: 4)
        let row = ImportColours.row(full, source: "s", note: "n")
        #expect(row?.setting == .terminalPalette(full) && row?.note == "n" && row?.ticked == true)
        #expect(ImportColours.opaqueSelection(0xFFFFFF, alpha: 0.5, background: 0x000000) == 0x808080)
        #expect(ImportColours.opaqueSelection(0x123456, alpha: 1, background: nil) == 0x123456)
        #expect(ImportedSetting.terminalPalette(full).keys == ["terminalPalette", "customTerminalPalette"])
        #expect(ImportedSetting.editorFontFamily("Menlo").keys == ["editorFontFamily"])
    }
}
