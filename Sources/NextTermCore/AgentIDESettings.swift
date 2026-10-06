import Foundation

/// Gemini CLI and Qwen Code connect to an editor only with `"ide": {"enabled": true}` in their user
/// settings (what their `/ide enable` writes). Next Term turns it on for you, so there is nothing to run:
/// only that setting changes, the rest of the file stays exactly as it was. Next Term's own Settings is
/// where you turn the link off. A settings file with comments is never rewritten (they would be lost).
public enum AgentIDESettings {
    public enum Result: Equatable, Sendable {
        /// Turned on now.
        case enabled
        case alreadyOn
        /// Set to false by the user: left alone.
        case leftOff
        /// The agent is not installed (no settings folder): nothing written.
        case notInstalled
        /// Not plain JSON (comments, or broken): not touched.
        case skipped
    }

    /// `~/.gemini/settings.json` and `~/.qwen/settings.json`.
    public static func settingsFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".gemini/settings.json"), home.appendingPathComponent(".qwen/settings.json")]
    }

    /// `overridingOff`: also turn on a `false` (Next Term's Settings is the switch; on by default).
    @discardableResult
    public static func ensureEnabled(_ settings: URL, overridingOff: Bool = false) -> Result {
        let folder = settings.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notInstalled
        }
        guard FileManager.default.fileExists(atPath: settings.path) else {
            return write(Data("{\n  \"ide\": {\n    \"enabled\": true\n  }\n}\n".utf8), to: settings) ? .enabled : .skipped
        }
        guard isRegularFile(canonicalPath(settings.path)), let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else { return .skipped }
        // Plain JSON only: a file with comments fails to parse, and is then not ours to rewrite.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .skipped }
        if let ide = json["ide"] as? [String: Any] {
            if let enabled = ide["enabled"] as? Bool {
                if enabled { return .alreadyOn }
                guard overridingOff else { return .leftOff }
                // "enabled": false → true inside "ide" (other settings have "enabled" too), by text.
                guard let ide = text.range(of: #""ide"\s*:\s*\{"#, options: .regularExpression),
                      let close = text[ide.upperBound...].firstIndex(of: "}"),
                      let range = text.range(of: #""enabled"\s*:\s*false"#, options: .regularExpression, range: ide.upperBound..<close)
                else { return .skipped }
                let updated = text.replacingCharacters(in: range, with: "\"enabled\": true")
                return verifiedWrite(updated, to: settings) ? .enabled : .skipped
            }
            // "ide" is there without "enabled": add it inside, by text, so nothing else moves.
            guard let range = text.range(of: #""ide"\s*:\s*\{"#, options: .regularExpression),
                  text.range(of: #""ide"\s*:"#, options: .regularExpression, range: range.upperBound..<text.endIndex) == nil else {
                return .skipped
            }
            let inside = text[range.upperBound...].drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
            let addition = inside.first == "}" ? "\"enabled\": true" : "\"enabled\": true, "
            let updated = text.replacingCharacters(in: range, with: text[range] + addition)
            return verifiedWrite(updated, to: settings) ? .enabled : .skipped
        }
        if json["ide"] != nil { return .skipped } // something unexpected: not ours
        // No "ide" yet: insert it first in the top-level object, leaving the rest byte for byte.
        guard let brace = text.firstIndex(of: "{") else { return .skipped }
        let afterBrace = text[text.index(after: brace)...]
        let isEmpty = afterBrace.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }.first == "}"
        let insertion = isEmpty ? "\n  \"ide\": {\n    \"enabled\": true\n  }\n" : "\n  \"ide\": {\n    \"enabled\": true\n  },"
        var updated = text
        updated.insert(contentsOf: insertion, at: text.index(after: brace))
        return verifiedWrite(updated, to: settings) ? .enabled : .skipped
    }

    /// Writes only if the result is valid JSON with the setting on (never leave a broken settings file).
    private static func verifiedWrite(_ text: String, to url: URL) -> Bool {
        let data = Data(text.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["ide"] as? [String: Any])?["enabled"] as? Bool == true else { return false }
        return write(data, to: url)
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        (try? TextFile.write(data, to: url)) != nil
    }
}
