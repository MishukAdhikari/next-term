import Foundation

// What the terminal importers of kitty, Alacritty, WezTerm, Kaku and cmux share: finding the app and its version,
// the rows every terminal has (its font size, the Option keys), colours as these apps write them, and their keys
// read into the VS Code form the shortcut rules take (ImportVSCode.parseKey). Only reads.

/// An app's bundle and the version its Info.plist gives (only `CFBundleShortVersionString` is read from it).
enum ImportAppBundles {
    /// The first of `names` (".app" bundle names) in `applications`, and its version.
    static func find(_ names: [String], applications: [String]) -> (path: String, version: String?)? {
        for folder in applications {
            for name in names {
                let bundle = (folder as NSString).appendingPathComponent(name)
                guard ImportVSCode.isDirectory(bundle) else { continue }
                return (bundle, version(bundle: bundle))
            }
        }
        return nil
    }

    /// The version a bundle gives ("0.65.0"), when its Info.plist is a plain file inside it.
    static func version(bundle: String) -> String? {
        guard let file = ImportVSCode.file("Contents/Info.plist", inside: bundle), let data = ImportFile.data(file),
              data.count <= 1 << 20,
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        return ImportVSCode.version(plist["CFBundleShortVersionString"] as? String)
    }
}

extension ImportFile {
    /// `path`'s real path when it is a plain file that is either not a link at all or inside one of `folders`
    /// (as their real paths): a link out of the app's folders is never followed. Nil otherwise.
    static func ownFile(_ path: String, folders: [String]) -> String? {
        let real = canonicalPath(path)
        guard isRegularFile(real) else { return nil }
        let parent = canonicalPath((path as NSString).deletingLastPathComponent)
        if real == (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent) { return real }
        return folders.map(canonicalPath).contains { real.hasPrefix($0 + "/") } ? real : nil
    }

    static let linkedOut = "it links to a file outside the app's own folder, which isn't read"
}

extension ImportRows {
    /// The terminal's own font size (`terminalFontSize`), with a note when Next Term's range changes it.
    static func terminalFontSize(_ size: Double, source: String) -> PlannedSetting {
        let note = size.rounded() < 8 || size.rounded() > 32 ? "Next Term's sizes go from 8 to 32" : nil
        return PlannedSetting(.terminalFontSize(clamping: size), source: source, note: note)
    }

    /// Option as Meta from what each Option key does in `app`: on for both, ticked on a U.S.-style layout; one
    /// side only, offered unticked (Next Term can't set one side yet); neither, off.
    static func optionAsMeta(left: Bool, right: Bool, app: String, source: String, usKeyboard: Bool,
                             note extra: String? = nil) -> PlannedSetting {
        guard left || right else { return PlannedSetting(.optionAsMeta(false), source: source, note: extra) }
        var notes: [String] = []
        if left != right { notes.append("on in \(app) for \(left ? "Left" : "Right") Option only; Next Term can't set one side yet") }
        if !usKeyboard { notes.append("your keyboard layout may need Option to type @ [ ] { }") }
        if let extra { notes.append(extra) }
        return PlannedSetting(.optionAsMeta(true), source: source, ticked: left == right && usKeyboard,
                              note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// "font_size 13", "font.size 12.5".
    static func number(_ value: Double) -> String { ImportITerm2.formatted(value) }
}

extension ImportColours {
    /// "#rrggbb", "#rgb", "rrggbb" or "0xrrggbb" (Alacritty's other spelling), opaque only; nil for anything else
    /// (colour names, `rgb(…)`, a colour with alpha).
    static func hex(_ text: String) -> UInt32? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("0x") { value = "#" + value.dropFirst(2) }
        guard let colour = TerminalPalette.hex(value), colour.alpha >= 1 else { return nil }
        return colour.rgb
    }
}

/// Keys as the terminals write them, read into the VS Code form (`cmd+shift+]`) and then by ImportVSCode.parseKey,
/// so they meet the same rules as every other import's keys.
enum ImportKeys {
    /// Modifier names the terminals use, as VS Code names them (nil: a modifier Next Term has no key for).
    static let modifiers: [String: String?] = [
        "cmd": "cmd", "command": "cmd", "super": "cmd", "⌘": "cmd",
        "ctrl": "ctrl", "control": "ctrl", "ctl": "ctrl", "⌃": "ctrl",
        "alt": "alt", "opt": "alt", "option": "alt", "⌥": "alt",
        "shift": "shift", "⇧": "shift",
        "hyper": nil, "meta": nil,
    ]

    /// Key names (lowercased, `_` and `-` dropped) as VS Code names them.
    static let names: [String: String] = {
        var names: [String: String] = [
            "left": "left", "arrowleft": "left", "leftarrow": "left",
            "right": "right", "arrowright": "right", "rightarrow": "right",
            "up": "up", "arrowup": "up", "uparrow": "up",
            "down": "down", "arrowdown": "down", "downarrow": "down",
            "enter": "enter", "return": "enter", "tab": "tab", "space": "space", "spc": "space",
            "backspace": "backspace", "back": "backspace", "delete": "delete", "del": "delete",
            "escape": "escape", "esc": "escape", "home": "home", "end": "end",
            "pageup": "pageup", "pgup": "pageup", "pagedown": "pagedown", "pgdn": "pagedown",
            "minus": "-", "hyphen": "-", "equal": "=", "equals": "=", "comma": ",", "period": ".", "dot": ".",
            "slash": "/", "backslash": "\\", "semicolon": ";", "apostrophe": "'", "quote": "'",
            "grave": "`", "graveaccent": "`", "backquote": "`", "backtick": "`",
            "leftbracket": "[", "lbracket": "[", "bracketleft": "[", "openbracket": "[",
            "rightbracket": "]", "rbracket": "]", "bracketright": "]", "closebracket": "]",
        ]
        for n in 1...35 { names["f\(n)"] = "f\(n)" }
        return names
    }()

    /// One key: a character as itself (a letter lowercased), else by its name; nil for one not known here.
    static func key(_ raw: String) -> String? {
        if raw.count == 1 { return raw.lowercased() }
        let name = raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if name.hasPrefix("numpad") || name.hasPrefix("kp") && name.count > 2 { return "numpad" }
        return names[name]
    }

    /// The key with its modifiers (any names in `modifiers`), read as an import's key.
    static func parse(modifiers given: [String], key raw: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        var mods: [String] = []
        for name in given {
            let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, trimmed != "none" else { continue }
            guard let known = modifiers[trimmed] else { return .notSupported(ImportShortcuts.notRecognised) }
            guard let vsCode = known else { return .notSupported("Next Term has no \(trimmed.capitalized) key") }
            if !mods.contains(vsCode) { mods.append(vsCode) }
        }
        guard let key = key(raw) else { return .notSupported(ImportShortcuts.notRecognised) }
        if key == "numpad" { return .notSupported(ImportShortcuts.numpad) }
        // VS Code's reader takes "+" only as the separator; a key of + isn't one any import maps.
        guard key != "+" else { return .notSupported(ImportShortcuts.notRecognised) }
        return ImportVSCode.parseKey((mods + [key]).joined(separator: "+"), usKeyboard: usKeyboard)
    }

    /// A label for a preview line, never showing what looks like a credential.
    static func label(_ text: String) -> String {
        SecretGuard.looksSecret(text) ? "a key binding" : text
    }
}
