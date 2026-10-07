import CoreText
import Foundation

/// A font family installed on this Mac, as the editor and terminal font settings and an import see it.
public struct InstalledFont: Equatable, Sendable {
    /// The family's own name ("JetBrains Mono"), whatever name it was looked up by.
    public let family: String
    /// Every character the same width, as code and a terminal need.
    public let monospaced: Bool

    public init(family: String, monospaced: Bool) {
        self.family = family
        self.monospaced = monospaced
    }
}

/// Looks a font up by family name ("Fira Code") or PostScript name ("FiraCode-Regular", as iTerm2 and
/// Terminal.app save it). Imports take a catalog, so tests can pass their own instead of this Mac's fonts.
public struct FontCatalog: Sendable {
    public let lookup: @Sendable (String) -> InstalledFont?

    public init(lookup: @escaping @Sendable (String) -> InstalledFont?) {
        self.lookup = lookup
    }

    /// The fonts installed on this Mac (CoreText; no AppKit, so Core stays platform-neutral). Each catalog
    /// reads the list of families once, at its first lookup: reading it takes longer the more fonts a Mac
    /// has, so an import uses one catalog for its whole plan.
    public static var system: FontCatalog {
        let families = SystemFamilies()
        return FontCatalog { SystemFonts.lookup($0, families: families.byName) }
    }

    /// The system's monospaced face, which Terminal's profiles use ("SFMono-Regular"). It isn't in the list
    /// of installed families, so it is known by name; the app draws it with the system's monospaced font.
    public static let systemMonospacedFamily = "SF Mono"

    /// Every installed monospaced family and the system's own, sorted by name, for the font menus in
    /// Settings. Families macOS keeps to itself (names starting with a dot) are left out. This measures
    /// every installed font, so the app calls it off the main thread.
    public static func monospacedFamilies() -> [String] {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let visible = families.filter { !$0.hasPrefix(".") }
        var monospaced = visible.filter { SystemFonts.font(family: $0).map(SystemFonts.isMonospaced) ?? false }
        if !monospaced.contains(systemMonospacedFamily) { monospaced.append(systemMonospacedFamily) }
        return monospaced.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// The installed families by lowercased name, read on first use and then kept.
final class SystemFamilies: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [String: String]?

    var byName: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let read { return read }
        let families = SystemFonts.families()
        read = families
        return families
    }
}

enum SystemFonts {
    /// Every installed family, by its lowercased name.
    static func families() -> [String: String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func lookup(_ name: String, families: [String: String]) -> InstalledFont? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !wanted.hasPrefix("."), wanted.count < 200 else { return nil }
        if let family = families[wanted.lowercased()], let font = font(family: family) {
            return InstalledFont(family: family, monospaced: isMonospaced(font))
        }
        if isSystemMonospaced(wanted) { return InstalledFont(family: FontCatalog.systemMonospacedFamily, monospaced: true) }
        // A PostScript name. CoreText hands back a stand-in for a name it doesn't know, so the name must match.
        let font = CTFontCreateWithName(wanted as CFString, 12, nil)
        let postScript = CTFontCopyPostScriptName(font) as String
        guard postScript.caseInsensitiveCompare(wanted) == .orderedSame else { return nil }
        let family = CTFontCopyFamilyName(font) as String
        guard !family.hasPrefix(".") else { return nil }
        return InstalledFont(family: family, monospaced: isMonospaced(font))
    }

    /// "SF Mono", or one of its PostScript names: "SFMono-Regular", and "SFMonoTerminal-Regular" (Terminal's
    /// Clear Dark and Clear Light).
    static func isSystemMonospaced(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "sf mono" || lowered.hasPrefix("sfmono-") || lowered.hasPrefix("sfmonoterminal-")
    }

    /// A face of `family` (its regular one when it has one), or nil when the family isn't installed.
    static func font(family: String) -> CTFont? {
        let attributes = [kCTFontFamilyNameAttribute: family] as CFDictionary
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes), 12, nil)
        let found = CTFontCopyFamilyName(font) as String
        return found.caseInsensitiveCompare(family) == .orderedSame ? font : nil
    }

    /// The font says it is monospaced, or its characters are all one width (some monospaced fonts don't
    /// set the flag).
    static func isMonospaced(_ font: CTFont) -> Bool {
        if CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) { return true }
        let characters = Array("il1MW_m0".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        guard let first = advances.first?.width, first > 0 else { return false }
        return advances.allSatisfy { abs($0.width - first) < 0.01 }
    }
}
