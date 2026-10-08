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
            return write("{\n  \"ide\": {\n    \"enabled\": true\n  }\n}\n", to: settings, over: nil) ? .enabled : .skipped
        }
        guard isRegularFile(canonicalPath(settings.path)), let data = FileManager.default.contents(atPath: settings.path),
              let text = String(data: data, encoding: .utf8) else { return .skipped }
        // Plain JSON only: a file with comments (or trailing commas) is not ours to rewrite. Read as MCP registration
        // reads agents' files: without recursion, and no deeper than JSONC.maxDepth, so a file nested deeper is
        // skipped rather than a crash. Repeated keys are skipped too: Gemini reads the last, an edit would go to the first.
        guard let document = JSONC(text), !document.hasComments, !document.hasTrailingCommas,
              case .object(let root)? = document.root, !root.hasRepeatedKeys else { return .skipped }
        guard let ide = root.member("ide") else {
            // No "ide" yet: it goes first in the top-level object, leaving the rest byte for byte.
            let newline = document.lineEnding
            return insert(into: root, of: document, spread: true, over: data, to: settings) { indent in
                "\"ide\": {" + newline + indent + "  \"enabled\": true" + newline + indent + "}"
            }
        }
        guard case .object(let object) = ide.value, !object.hasRepeatedKeys else { return .skipped } // something unexpected: not ours
        guard let enabled = object.member("enabled") else {
            // "ide" is there without "enabled": it goes first inside, so nothing else moves.
            return insert(into: object, of: document, spread: false, over: data, to: settings) { _ in "\"enabled\": true" }
        }
        switch document.string(enabled.value.range) {
        case "true":
            return .alreadyOn
        case "false":
            guard overridingOff else { return .leftOff }
            // This "enabled" only: other settings have one too.
            var updated = text
            updated.unicodeScalars.replaceSubrange(enabled.value.range, with: "true".unicodeScalars)
            return verifiedWrite(updated, over: data, to: settings) ? .enabled : .skipped
        default:
            return .skipped
        }
    }

    /// The text with a member put first in `object` (`JSONC.insertion`), written if it checks out.
    private static func insert(into object: JSONC.Object, of document: JSONC, spread: Bool, over data: Data, to url: URL,
                               member: (_ indent: String) -> String) -> Result {
        let insertion = document.insertion(into: object, spread: spread, member: member)
        var updated = document.text
        updated.unicodeScalars.insert(contentsOf: insertion.text.unicodeScalars, at: insertion.at)
        return verifiedWrite(updated, over: data, to: url) ? .enabled : .skipped
    }

    /// Writes only if the result is plain JSON with the setting on (never leave a broken settings file), and only over
    /// the bytes it was made from.
    private static func verifiedWrite(_ text: String, over data: Data, to url: URL) -> Bool {
        guard let document = JSONC(text), !document.hasComments, !document.hasTrailingCommas,
              case .object(let root)? = document.root, case .object(let ide)? = root.member("ide")?.value,
              let enabled = ide.member("enabled"), document.string(enabled.value.range) == "true",
              (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return false }
        return write(text, to: url, over: data)
    }

    /// Through `SafeWrite`: the file's permissions kept (a new one is 0600), and a save by the agent since `data` was
    /// read (nil: there was no file) is kept instead. A UTF-8 byte order mark stays.
    private static func write(_ text: String, to url: URL, over data: Data?) -> Bool {
        let mark = Data([0xEF, 0xBB, 0xBF])
        var bytes = Data(text.utf8)
        if data?.starts(with: mark) == true, !bytes.starts(with: mark) { bytes = mark + bytes }
        return (try? SafeWrite.replace(url.path, with: bytes, expecting: data.map { .contents($0) } ?? .noFile)) != nil
    }
}
