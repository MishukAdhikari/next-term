import Foundation

// "Coming from Warp?": `~/.warp/settings.toml` and a custom theme in `~/.warp/themes` (§3.4). Design:
// claudedocs/research_next-term-migration (§3.4 terminals, §6 safety). The settings file also holds agent
// profiles, API keys and the secret-redaction list, so it is scanned, not parsed: only the values of the
// allowlisted keys below are ever converted; every other value is skipped over unread. Nothing is written.

public enum ImportWarp {
    static func folder(home: String) -> String { (home as NSString).appendingPathComponent(".warp") }

    /// Warp, when it has a settings file. Last use is that file's date (detection opens nothing).
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        let settings = (folder(home: home) as NSString).appendingPathComponent("settings.toml")
        guard isRegularFile(settings) else { return [] }
        return [DetectedApp(kind: .warp, name: "Warp", configPath: folder(home: home), lastUsed: ImportFile.modificationDate(settings))]
    }

    /// The only values converted: table and key.
    static let font = Key(table: "appearance.text", key: "font_name")
    static let size = Key(table: "appearance.text", key: "font_size")
    static let theme = Key(table: "appearance.themes", key: "theme")
    static let meta = Key(table: "terminal.input", key: "extra_meta_keys")
    static let allowlist: Set<Key> = [font, size, theme, meta]

    struct Key: Hashable {
        let table: String
        let key: String
    }

    /// Tables whose names say they can hold secrets or configure agents: named in the preview, never read.
    static func isNeverRead(_ table: String) -> Bool {
        table.split(separator: ".").contains { SecretGuard.isSecretKey(String($0)) || $0 == "agents" || $0 == "mcp_servers" }
            || table.hasPrefix("privacy")
    }

    // MARK: plan

    /// The terminal font, its size, Option as Meta and a custom theme's colours. `fonts`: the fonts this Mac
    /// has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .warp else { return plan }
        let base = app.configPath.isEmpty ? folder(home: home) : app.configPath
        guard let text = ImportFile.text((base as NSString).appendingPathComponent("settings.toml")) else {
            plan.skipped.append(SkippedItem("settings.toml", "couldn't be read, so no settings came over"))
            return plan
        }
        let scan = Scan(text)
        if let name = scan.values[font].flatMap(TOML.string) {
            let row = ImportFonts.row(.terminal, list: name, source: "font_name", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        if let raw = scan.values[size] {
            if let value = TOML.number(raw), value > 0 {
                var notes = ["sets the editor too: Next Term has one size for both"]
                if value.rounded() < 8 || value.rounded() > 32 { notes.insert("Next Term's sizes go from 8 to 32", at: 0) }
                plan.settings.append(PlannedSetting(.fontSize(clamping: value), source: "font_size \(ImportITerm2.formatted(value))",
                                                    note: notes.joined(separator: "; ")))
            } else {
                plan.skipped.append(SkippedItem("font_size", "not a font size Next Term can use"))
            }
        }
        if let raw = scan.values[meta] { addMeta(raw, usKeyboard: usKeyboard, to: &plan) }
        if let raw = scan.values[theme] { addTheme(raw, folder: base, to: &plan) }
        for table in scan.neverRead where !SecretGuard.looksSecret(table) {
            plan.skipped.append(SkippedItem("[\(table)]", "never imported: can hold secrets or configures agents"))
        }
        if scan.others > 0 {
            plan.skipped.append(SkippedItem("\(scan.others) other setting\(scan.others == 1 ? "" : "s")", "no matching Next Term setting yet"))
        }
        if isRegularFile((base as NSString).appendingPathComponent("keybindings.yaml")) {
            plan.skipped.append(SkippedItem("keybindings.yaml", "Warp's own shortcuts aren't brought over yet"))
        }
        return plan
    }

    /// `extra_meta_keys`: both Option keys → on; one of them → offered unticked (Next Term can't set one side yet).
    static func addMeta(_ raw: String, usKeyboard: Bool, to plan: inout ImportPlan) {
        let keys = TOML.strings(raw) ?? TOML.string(raw).map { [$0] }
        guard let keys else { return plan.skipped.append(SkippedItem("extra_meta_keys", "value not recognised")) }
        let left = keys.contains("left_alt"), right = keys.contains("right_alt")
        guard left || right else { return }
        var notes: [String] = []
        if left != right { notes.append("on in Warp for \(left ? "Left" : "Right") Option only; Next Term can't set one side yet") }
        if !usKeyboard { notes.append("your keyboard layout may need Option to type @ [ ] { }") }
        let shown = [left ? "left_alt" : nil, right ? "right_alt" : nil].compactMap { $0 }.joined(separator: ", ")
        plan.settings.append(PlannedSetting(.optionAsMeta(true), source: "extra_meta_keys \(shown)", ticked: notes.isEmpty,
                                            note: notes.isEmpty ? nil : notes.joined(separator: "; ")))
    }

    // MARK: themes

    /// A custom theme's colours, from its YAML file in `~/.warp/themes`. Warp's built-in themes live inside
    /// Warp, so they can't be read.
    static func addTheme(_ raw: String, folder: String, to plan: inout ImportPlan) {
        let themes = (folder as NSString).appendingPathComponent("themes")
        guard let file = themeFile(raw, themes: themes) else {
            let name = TOML.string(raw).flatMap { SecretGuard.looksSecret($0) || $0.count > 80 ? nil : $0 }
            plan.skipped.append(SkippedItem(name.map { "theme \($0)" } ?? "theme", "Warp's built-in themes are inside Warp, so they can't be read"))
            return
        }
        let yaml = YAML(ImportFile.text(file) ?? "")
        var palette = TerminalPalette(name: "Warp colours")
        var unreadable: [String] = []
        func colour(_ path: String) -> UInt32? {
            guard let text = yaml.values[path] else { return nil }
            guard let colour = TerminalPalette.hex(text) else {
                unreadable.append(path)
                return nil
            }
            return colour.rgb
        }
        for (index, name) in TerminalPalette.ansiNames.enumerated() {
            palette.ansi[index] = colour("terminal_colors.normal.\(name)")
            palette.ansi[index + 8] = colour("terminal_colors.bright.\(name)")
        }
        palette.foreground = colour("foreground")
        palette.background = colour("background")
        palette.cursor = colour("cursor")
        let fileName = (file as NSString).lastPathComponent
        if let row = ImportColours.row(palette, source: "theme \(fileName)") { plan.settings.append(row) }
        for path in unreadable { plan.skipped.append(SkippedItem("theme \(path)", "only #rrggbb colours are read")) }
    }

    /// The theme's file: a name (`theme = "solarized_dark"`, or `name = …` in a table) matched to a file in
    /// the themes folder, or a `path` there. Nothing outside that folder is opened.
    static func themeFile(_ raw: String, themes: String) -> String? {
        var candidates: [String] = []
        if let name = TOML.string(raw) { candidates.append(name) }
        for key in ["name", "path"] { if let value = TOML.inlineString(raw, key: key) { candidates.append(value) } }
        let folder = canonicalPath(themes)
        for candidate in candidates where !candidate.isEmpty && candidate.count <= 200 && !candidate.contains("\0") {
            let base = ((candidate as NSString).lastPathComponent as NSString).deletingPathExtension
            let names = [base, base.lowercased().replacingOccurrences(of: " ", with: "_")]
            for name in names where !name.hasPrefix(".") {
                for suffix in [".yaml", ".yml"] {
                    let path = canonicalPath((folder as NSString).appendingPathComponent(name + suffix))
                    if path.hasPrefix(folder + "/"), isRegularFile(path) { return path }
                }
            }
        }
        return nil
    }

    // MARK: reading

    /// One pass over settings.toml: the raw text of the allowlisted values, the never-read tables seen, and
    /// how many other keys there are. Multi-line arrays and inline tables are skipped over whole.
    struct Scan {
        var values: [Key: String] = [:]
        var neverRead: [String] = []
        var others = 0

        init(_ text: String) {
            var table = ""
            var pending: (key: Key, text: String)?
            var depth = 0
            for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                if depth > 0 {
                    // Still inside a multi-line value: kept only when allowlisted.
                    depth += TOML.depthChange(line)
                    if var value = pending {
                        value.text += "\n" + line
                        pending = value
                        if depth <= 0 { values[value.key] = value.text }
                    }
                    if depth <= 0 { pending = nil }
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("[") {
                    table = TOML.tableName(trimmed)
                    if Self.isNeverReadTable(table), !neverRead.contains(where: { table.hasPrefix($0) }) { neverRead.append(table) }
                    continue
                }
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                var key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                if key.count >= 2, key.hasPrefix("\"") || key.hasPrefix("'") { key = String(key.dropFirst().dropLast()) }
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                depth = TOML.depthChange(value)
                let full = Key(table: table, key: key)
                if ImportWarp.allowlist.contains(full) {
                    if depth > 0 { pending = (full, value) } else { values[full] = value }
                } else if !Self.isNeverReadTable(table) {
                    others += 1
                }
            }
        }

        static func isNeverReadTable(_ table: String) -> Bool { ImportWarp.isNeverRead(table) }
    }
}

/// Just enough TOML for Warp's settings: strings, numbers, arrays of strings, and a string inside an
/// inline table. Anything else reads as nil.
enum TOML {
    /// `[appearance.text]` → "appearance.text" (`[[array]]` tables too).
    static func tableName(_ line: String) -> String {
        var name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        if let comment = name.firstIndex(of: "#") { name = String(name[..<comment]).trimmingCharacters(in: CharacterSet(charactersIn: "[] \t")) }
        return name.replacingOccurrences(of: "\"", with: "")
    }

    /// How many brackets and braces a line opens minus closes, outside strings.
    static func depthChange(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case "#": return depth // a comment to the end of the line
            default: break
            }
        }
        return depth
    }

    /// A quoted string ("…" with \" \\ escapes, or '…' as is), with an optional comment after it.
    static func string(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.first, open == "\"" || open == "'" else { return nil }
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                result.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                escaped = false
            } else if character == "\\" && open == "\"" {
                escaped = true
            } else if character == open {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    static func number(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let comment = text.firstIndex(of: "#") { text = String(text[..<comment]).trimmingCharacters(in: .whitespaces) }
        guard let value = Double(text.replacingOccurrences(of: "_", with: "")), value.isFinite else { return nil }
        return value
    }

    /// `["left_alt", "right_alt"]`; nil unless every element is a string.
    static func strings(_ raw: String) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["), let close = text.lastIndex(of: "]") else { return nil }
        text = String(text[text.index(after: text.startIndex)..<close])
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let strings = parts.compactMap(string)
        return strings.count == parts.count ? strings : nil
    }

    /// `key = "…"` anywhere inside an inline table (`{ Custom = { name = "…", path = "…" } }`).
    static func inlineString(_ raw: String, key: String) -> String? {
        guard raw.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
              let range = raw.range(of: #"\b\#(key)\s*=\s*"#, options: .regularExpression) else { return nil }
        return string(String(raw[range.upperBound...]))
    }
}

/// Just enough YAML for a Warp theme: nested `key: value` maps by indentation, values plain or quoted.
/// Paths join keys with dots ("terminal_colors.normal.red").
struct YAML {
    var values: [String: String] = [:]

    init(_ text: String) {
        var stack: [(indent: Int, key: String)] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if value.isEmpty {
                stack.append((indent, key))
                continue
            }
            if let open = value.first, open == "'" || open == "\"", let close = value.dropFirst().firstIndex(of: open) {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            values[path] = value
        }
    }
}
