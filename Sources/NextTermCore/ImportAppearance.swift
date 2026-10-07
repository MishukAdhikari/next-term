import Foundation

// Fonts and terminal colours in an import, shared by every importer. A font comes over only when this
// Mac has it and it is monospaced; colours come over as a palette whose unset colours stay Next Term's.
// Font names are the only free text an import keeps (§6.2), and each is checked by SecretGuard first.

/// Which font setting a family is for.
public enum FontTarget: Sendable {
    case editor, terminal

    var label: String { self == .editor ? "Editor font" : "Terminal font" }

    func setting(_ family: String) -> ImportedSetting {
        self == .editor ? .editorFontFamily(family) : .terminalFontFamily(family)
    }
}

public enum ImportFonts {
    /// CSS generic names and keywords: they mean the app's own default, so there is nothing to bring over.
    static let generic: Set<String> = [
        "monospace", "ui-monospace", "sans-serif", "serif", "system-ui", "ui-sans-serif", "ui-serif", "ui-rounded",
        "-apple-system", "blinkmacsystemfont", "cursive", "fantasy", "emoji", "math", "fangsong", "inherit", "initial", "default",
    ]

    static let notInstalled = "not installed on this Mac"
    static let notMonospaced = "not a monospaced font, which code and the terminal need"
    static let credential = "looked like a credential"

    /// "'Fira Code', Menlo, monospace" → ["Fira Code", "Menlo", "monospace"]: a CSS font list (VS Code's), or
    /// a single family. Commas inside quotes stay; at most 20 names.
    static func families(_ list: String) -> [String] {
        var names: [String] = []
        var current = ""
        var quote: Character?
        for character in list {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "," {
                names.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        names.append(current)
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Array(trimmed.filter { !$0.isEmpty }.prefix(20))
    }

    /// The first family in `list` that this Mac has and is monospaced, as a preview row; the names before it
    /// are reported with why they were passed over. A list of generic names only (the app's default) gives
    /// nothing. `source`: where the list came from ("editor.fontFamily").
    public static func row(_ target: FontTarget, list: String, source: String, fonts: FontCatalog,
                           note: String? = nil) -> (setting: PlannedSetting?, skipped: [SkippedItem]) {
        var skipped: [SkippedItem] = []
        let names = families(list)
        for (index, name) in names.enumerated() {
            if generic.contains(name.lowercased()) { continue }
            guard !SecretGuard.looksSecret(name) else {
                skipped.append(SkippedItem(target.label, credential))
                continue
            }
            guard let font = fonts.lookup(name) else {
                skipped.append(SkippedItem("\(target.label) “\(name)”", notInstalled))
                continue
            }
            guard font.monospaced else {
                skipped.append(SkippedItem("\(target.label) “\(name)”", notMonospaced))
                continue
            }
            let shown = SecretGuard.looksSecret(list) ? name : list
            var notes: [String] = []
            if index > 0, !skipped.isEmpty { notes.append("the first font in the list that this Mac has") }
            if let note { notes.append(note) }
            let row = PlannedSetting(target.setting(font.family), source: "\(source) \(shown)",
                                     note: notes.isEmpty ? nil : notes.joined(separator: "; "))
            return (row, skipped)
        }
        return (nil, skipped)
    }
}

public enum ImportColours {
    /// A preview row for the colours a source sets (nil when it sets none). The note says when only some
    /// are set, since the rest stay Next Term's.
    public static func row(_ palette: TerminalPalette, source: String, note: String? = nil) -> PlannedSetting? {
        guard !palette.isEmpty else { return nil }
        var notes: [String] = []
        if palette.count < 20 { notes.append("\(palette.count) of 20 colours; the others stay Next Term's") }
        if let note { notes.append(note) }
        return PlannedSetting(.terminalPalette(palette), source: source, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// A see-through selection laid over the background it is drawn on (the palette's, else Next Term's).
    static func opaqueSelection(_ rgb: UInt32, alpha: Double, background: UInt32?) -> UInt32 {
        alpha >= 1 ? rgb : TerminalPalette.blend(rgb, alpha: alpha, over: background ?? nextTermBackground)
    }

    /// Next Term's terminal background (Theme.swift), for blending a see-through selection when a source
    /// doesn't set a background.
    static let nextTermBackground: UInt32 = 0x1E1F22
}
