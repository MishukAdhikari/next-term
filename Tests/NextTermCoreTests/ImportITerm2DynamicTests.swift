import Foundation
import Testing
@testable import NextTermCore

/// iTerm2's dynamic profiles, from the hand-written fixture home in Fixtures/Import/iTerm2 (never a real Mac's): the
/// default profile can be a dynamic one, merged over its parent.
@Suite struct ImportITerm2DynamicTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func plan(_ home: String) throws -> ImportPlan {
        let app = try #require(ImportITerm2.detect(home: home, applications: []).first)
        return ImportITerm2.plan(for: app, home: home, fonts: testFonts)
    }

    @Test func theDefaultIsADynamicProfileMergedOverItsParents() throws {
        let home = try ImportFixtures.copy("iTerm2")
        defer { remove(home) }
        let plan = try plan(home)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontSize(15)), "Base's font, not the escaped file's 29 or the regular profile's 12")
        #expect(settings.contains(.terminalFontFamily("JetBrains Mono")))
        #expect(plan.settings.contains { $0.setting == .optionAsMeta(true) && $0.ticked })
        #expect(settings.contains(.terminalCursorShape("bar")), "the default's own cursor")
        let row = try #require(plan.settings.first { if case .terminalPalette = $0.setting { return true } else { return false } })
        #expect(row.source == "the default profile's colours, from its dynamic profile")
        guard case .terminalPalette(let palette) = row.setting else { return }
        #expect(palette.ansi[0] == 0x000000 && palette.ansi[1] == 0xFF0000 && palette.background == 0x1A1A1A,
                "the regular profile's colours under Base, the default's red on top")
    }

    @Test func filesThatArentReadAndTheCustomFolder() throws {
        let home = try ImportFixtures.copy("iTerm2")
        defer { remove(home) }
        let plan = try plan(home)
        let reasons = Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(reasons["DynamicProfiles/05-escape.json"] == "it links outside iTerm2's DynamicProfiles folder, so it isn't read")
        #expect(reasons["DynamicProfiles/50-broken.json"] == "couldn't be read")
        #expect(reasons["Load settings from a custom folder or URL"]
            == "iTerm2 loads them from there when it starts; the copy on this Mac was read, which may be older")
        #expect(!plan.skipped.contains { $0.item.contains("hidden") })
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func parentsByGuidAndCollisions() throws {
        let home = try ImportFixtures.copy("iTerm2")
        defer { remove(home) }
        let dynamic = ImportITerm2.dynamicProfiles(home: home)
        #expect(dynamic.profiles.compactMap { $0["Guid"] as? String } == ["DYN-BASE", "DYN-WORK", "DYN-ORPHAN", "REG-1"])
        #expect(dynamic.profiles.allSatisfy { $0["Command"] == nil && $0["Triggers"] == nil && $0["Initial Text"] == nil },
                "only the keys the import uses are kept")
        let regular: [[String: Any]] = [["Guid": "REG-1", "Name": "Default", "Normal Font": "Monaco 12"],
                                        ["Guid": "REG-2", "Name": "Plain", "Normal Font": "Menlo 11"]]
        let merged = ImportITerm2.mergedDynamic(dynamic.profiles, regular: regular, defaultProfile: regular[0])
        #expect(merged["DYN-ORPHAN"]?["Normal Font"] as? String == "Menlo 11", "its parent named by Guid")
        #expect(merged["REG-1"] == nil, "a dynamic profile with a regular one's Guid is ignored")
        #expect(merged["DYN-WORK"]?["Normal Font"] as? String == "JetBrainsMono-Regular 15")
    }

    /// With a regular default, the dynamic profiles change nothing; a parent named before it loads, or a loop, falls
    /// back to the default profile.
    @Test func regularDefaultsAndLoops() throws {
        let regular: [[String: Any]] = [["Guid": "R", "Name": "Default", "Normal Font": "Monaco 12"]]
        let dynamic: [[String: Any]] = [
            ["Guid": "A", "Name": "A", "Dynamic Profile Parent Name": "B", "Cursor Type": 0],
            ["Guid": "B", "Name": "B", "Dynamic Profile Parent Name": "A"],
        ]
        let merged = ImportITerm2.mergedDynamic(dynamic, regular: regular, defaultProfile: regular[0])
        #expect(merged["A"]?["Normal Font"] as? String == "Monaco 12")
        #expect(merged["B"]?["Cursor Type"] as? Int == 0)
        let root: [String: Any] = ["New Bookmarks": regular, "Default Bookmark Guid": "R"]
        #expect(ImportITerm2.defaultProfile(root, dynamic: dynamic)?.dynamic == false)
        let dynamicDefault: [String: Any] = ["New Bookmarks": regular, "Default Bookmark Guid": "B"]
        #expect(ImportITerm2.defaultProfile(dynamicDefault, dynamic: dynamic)?.dynamic == true)
    }
}
