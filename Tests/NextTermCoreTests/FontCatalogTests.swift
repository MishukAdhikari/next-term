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

    /// SF Mono, the font of most of Terminal's own profiles, isn't an installed family, but every Mac has it.
    @Test func theSystemMonospacedFace() {
        let fonts = FontCatalog.system
        let sfMono = InstalledFont(family: "SF Mono", monospaced: true)
        for name in ["SFMono-Regular", "SFMono-Bold", "SFMonoTerminal-Regular", "SF Mono", "sf mono"] {
            #expect(fonts.lookup(name) == sfMono, "\(name)")
        }
        #expect(fonts.lookup("SFMonoX") == nil)
        #expect(FontCatalog.monospacedFamilies().filter { $0 == "SF Mono" }.count == 1)
    }

    /// One catalog reads the installed families once, so a long font list in a settings file stays quick
    /// however many fonts the Mac has.
    @Test func manyLookupsStayQuick() {
        let fonts = FontCatalog.system
        let started = Date()
        for index in 0..<200 { _ = fonts.lookup(index.isMultiple(of: 2) ? "Menlo" : "No Such Font \(index)") }
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func monospacedFamiliesForTheMenus() {
        let families = FontCatalog.monospacedFamilies()
        #expect(families.contains("Menlo") && families.contains("Monaco"))
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains { $0.hasPrefix(".") })
    }
}
