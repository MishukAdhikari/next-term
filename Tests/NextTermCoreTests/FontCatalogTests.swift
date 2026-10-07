import Foundation
import Testing
@testable import NextTermCore

/// The system catalog, against fonts every Mac has (Menlo, Monaco, Courier, Helvetica).
@Suite struct FontCatalogTests {
    @Test func familiesAndPostScriptNames() {
        let fonts = FontCatalog.system
        #expect(fonts.lookup("Menlo") == InstalledFont(family: "Menlo", monospaced: true))
        #expect(fonts.lookup("menlo")?.family == "Menlo")
        #expect(fonts.lookup("  Monaco ")?.monospaced == true)
        #expect(fonts.lookup("Helvetica") == InstalledFont(family: "Helvetica", monospaced: false))
        // iTerm2 and Terminal.app save PostScript names.
        #expect(fonts.lookup("Menlo-Regular") == InstalledFont(family: "Menlo", monospaced: true))
        #expect(fonts.lookup("Courier-Bold")?.family == "Courier")
        // A name CoreText doesn't know isn't swapped for a stand-in.
        #expect(fonts.lookup("No Such Font 1234") == nil)
        #expect(fonts.lookup("NoSuchFont-Regular") == nil)
        #expect(fonts.lookup("") == nil)
        // macOS's hidden system families aren't offered.
        #expect(fonts.lookup(".AppleSystemUIFont") == nil)
    }

    @Test func monospacedFamiliesForTheMenus() {
        let families = FontCatalog.monospacedFamilies()
        #expect(families.contains("Menlo") && families.contains("Monaco"))
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains { $0.hasPrefix(".") })
    }
}
