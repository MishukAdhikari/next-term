import Testing
@testable import NextTermCore

/// The path over the home folder's tree while a window with no project browses it: Home, then each folder down to the
/// selected row's, from the strings the tree holds. Too little room folds the folders after Home into "…", the oldest
/// first, then takes Home's name; the last folder always shows, cut in the middle by the bar when it must be.
@Suite struct BreadcrumbsTests {
    let home = "/Users/ada"

    func titles(_ folder: String) -> [String] { Breadcrumbs.segments(to: folder, home: home).map(\.title) }

    @Test func segmentsRunFromHomeToTheFolder() {
        #expect(Breadcrumbs.segments(to: "/Users/ada/Code/app", home: home) == [
            Breadcrumbs.Segment(title: "ada", path: "/Users/ada"),
            Breadcrumbs.Segment(title: "Code", path: "/Users/ada/Code"),
            Breadcrumbs.Segment(title: "app", path: "/Users/ada/Code/app"),
        ])
    }

    @Test func theHomeFolderIsOneSegment() {
        let alone = [Breadcrumbs.Segment(title: "ada", path: "/Users/ada")]
        #expect(Breadcrumbs.segments(to: home, home: home) == alone)
        #expect(Breadcrumbs.segments(to: home + "/", home: home) == alone)
        #expect(Breadcrumbs.segments(to: home, home: home + "/") == alone)
        #expect(Breadcrumbs.segments(to: "/Users/ada/Code/", home: home + "/").map(\.path) == ["/Users/ada", "/Users/ada/Code"])
    }

    @Test func aFolderOutsideHomeGivesHomeAlone() {
        // A name that only starts with the home folder's is not inside it.
        #expect(titles("/Users/adam/x") == ["ada"])
        #expect(titles("/Users/adam") == ["ada"])
        #expect(titles("/tmp") == ["ada"])
        #expect(titles("/") == ["ada"])
    }

    @Test func namesKeepTheirSpellings() {
        #expect(titles("/Users/ada/My Projects/.config/Résumé/notes…old") == ["ada", "My Projects", ".config", "Résumé", "notes…old"])
        #expect(Breadcrumbs.segments(to: "/Users/ada/My Projects/.config", home: home).last?.path == "/Users/ada/My Projects/.config")
    }

    /// Home 60 with its name and 20 with its symbol alone, folders of 40, a separator of 10 and a "…" of 20.
    func fit(_ count: Int, room: Double) -> Breadcrumbs.Fit {
        Breadcrumbs.fit(widths: [60] + Array(repeating: 40, count: count - 1), homeSymbolWidth: 20, separator: 10, more: 20, room: room)
    }

    @Test func everythingFitsWithRoom() {
        // 60 + 4 × 40 + 4 separators = 260.
        #expect(fit(5, room: 300) == Breadcrumbs.Fit(folded: 1..<1, homeSymbolOnly: false))
        #expect(fit(5, room: 260).folded.isEmpty && !fit(5, room: 260).homeSymbolOnly)
    }

    @Test func theOldestMiddleFoldersFoldFirst() {
        // Folding one folder into "…" saves 20: 240. Two: 190. Three: 140, and Home keeps its name throughout.
        #expect(fit(5, room: 259) == Breadcrumbs.Fit(folded: 1..<2, homeSymbolOnly: false))
        #expect(fit(5, room: 240) == Breadcrumbs.Fit(folded: 1..<2, homeSymbolOnly: false))
        #expect(fit(5, room: 239) == Breadcrumbs.Fit(folded: 1..<3, homeSymbolOnly: false))
        #expect(fit(5, room: 190) == Breadcrumbs.Fit(folded: 1..<3, homeSymbolOnly: false))
        #expect(fit(5, room: 140) == Breadcrumbs.Fit(folded: 1..<4, homeSymbolOnly: false))
        // The last never folds, however little room there is.
        for room in stride(from: 0.0, through: 300, by: 10) { #expect(!fit(5, room: room).folded.contains(4)) }
    }

    @Test func twoSegmentsNeverFold() {
        #expect(fit(2, room: 1000).folded.isEmpty)
        #expect(fit(2, room: 50).folded.isEmpty)
        #expect(fit(1, room: 1000).folded.isEmpty)
        #expect(fit(1, room: 10).folded.isEmpty)
    }

    @Test func homeLosesItsNameOnlyOnceEverythingIsFolded() {
        // Everything folded: 60 + 20 + 40 + 2 separators = 140. Below that Home gives up its name, the folders staying folded.
        #expect(fit(5, room: 139) == Breadcrumbs.Fit(folded: 1..<4, homeSymbolOnly: true))
        #expect(fit(5, room: 0) == Breadcrumbs.Fit(folded: 1..<4, homeSymbolOnly: true))
        // With nothing between Home and the last, Home's name goes as soon as both do not fit: 60 + 40 + 10.
        #expect(fit(2, room: 110) == Breadcrumbs.Fit(folded: 1..<1, homeSymbolOnly: false))
        #expect(fit(2, room: 109) == Breadcrumbs.Fit(folded: 1..<1, homeSymbolOnly: true))
        #expect(fit(1, room: 59) == Breadcrumbs.Fit(folded: 1..<1, homeSymbolOnly: true))
    }
}
