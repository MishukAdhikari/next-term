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
    }

    /// One catalog reads the installed families once, so a long font list in a settings file stays quick
    /// however many fonts the Mac has.
    @Test func manyLookupsStayQuick() {
        // Against one read of the list on this machine, not the clock alone: a catalog's first lookup reads it (about
        // 10 ms here), and 200 lookups on a new catalog, that read included, take about 1.2 times one. Reading the
        // list again on each lookup would take about 200 times.
        let lookups = Timing.ratio({
            let fonts = FontCatalog.system
            for index in 0..<200 { _ = fonts.lookup(index.isMultiple(of: 2) ? "Menlo" : "No Such Font \(index)") }
        }, to: { _ = FontCatalog.system.lookup("Menlo") })
        #expect(lookups < 20, "\(lookups) reads of the font list")
    }

    @Test func monospacedFamiliesForTheMenus() {
        let families = FontCatalog.monospacedFamilies()
        #expect(families.contains("Menlo") && families.contains("Monaco"))
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains { $0.hasPrefix(".") })
        #expect(families.filter { $0 == "SF Mono" }.count == 1, "the system's own monospaced face, once")
    }
}
