import Foundation

/// What one herdr command said (HerdrCommand: its script on a host, or its argument lists on this Mac), read the one way
/// for both. herdr prints JSON for what it lists and does, plain text for a pane it reads, and its errors as JSON on
/// stderr with exit 1; a usage error (a verb or an option this herdr lacks) exits 2.
public enum HerdrResult: Equatable, Sendable {
    /// herdr answered with JSON (a list, a focus, a prompt sent): its text as `HerdrAgent.plain` reads it, or "" when it
    /// printed nothing.
    case json(String)
    /// herdr answered with a pane's text, its line breaks kept (escape sequences, carriage returns and other control
    /// characters out, each line's trailing spaces too).
    case text(String)
    /// herdr refused: its code ("agent_blocked", "agent_not_found"…, "" when it gave none) and its message, stored keys
    /// masked, cut at 200 characters.
    case error(code: String, message: String)
    /// Each verb the command tries said this herdr lacks it: the first one ("agent read").
    case unsupported(String)
    /// The answer was cut: its cap, the time limit, a dropped connection.
    case cut
    /// herdr could not be asked: why, in a sentence.
    case unreachable(String)

    /// The most of a command's output the script keeps (`head -c`), and of its errors: more was cut.
    public static let outputCap = 2_000_000
    public static let errorCap = 65_536

    /// What herdr said when a verb or one of its options is not in this herdr: then the next verb is tried. Only for a
    /// command that failed: a pane's text may say "unknown command" too.
    public static func saysUnsupported(exit: Int32, said: String) -> Bool {
        guard exit != 0 else { return false }
        if exit == 2 { return true }
        let lower = said.lowercased()
        return ["unknown command", "unrecognized subcommand", "unexpected argument"].contains { lower.contains($0) }
    }

    /// One command's answer as its script printed it, after `RemoteShell.marker`: `missing<TAB>…`, or `where<TAB>path<TAB>how`,
    /// then `exit<TAB>status<TAB>verb` for each herdr call it made, and for the last one `bytes<TAB>its output's size`,
    /// `out<TAB>` and `err<TAB>` with its output and errors in base64 (so nothing in them can forge a line), then the end
    /// marker. `text`: herdr answers this command with a pane's text, not JSON.
    public static func parse(_ output: String, text: Bool, mask: SecretMask = .current) -> HerdrResult {
        guard let lines = RemoteShell.payload(output) else { return .cut }
        var exits: [(code: Int32, verb: String)] = []
        var bytes: Int?
        var out = Data(), err = Data()
        var ended = false
        for line in lines {
            if line == RemoteShell.herdrEndMarker {
                ended = true
                break
            }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch fields[0] {
            case "missing":
                return .unreachable("herdr was not found on the host")
            case "exit" where fields.count >= 3:
                exits.append((Int32(fields[1]) ?? -1, fields[2]))
            case "bytes" where fields.count >= 2:
                bytes = Int(fields[1].trimmingCharacters(in: .whitespaces))
            case "out" where fields.count >= 2:
                out = Data(base64Encoded: fields[1]) ?? Data()
            case "err" where fields.count >= 2:
                err = Data(base64Encoded: fields[1]) ?? Data()
            default:
                break
            }
        }
        guard ended, let last = exits.last else { return .cut }
        if let bytes, bytes > outputCap { return .cut }
        return make(exit: last.code, out: out, err: err, firstVerb: exits[0].verb, text: text, mask: mask)
    }

    /// One herdr call's answer (the last a command made): its exit status, stdout and stderr. `firstVerb` names the
    /// command when every verb it tried was missing.
    public static func make(exit: Int32, out: Data, err: Data, firstVerb: String, text: Bool, mask: SecretMask = .current) -> HerdrResult {
        let output = String(decoding: out.prefix(outputCap), as: UTF8.self)
        let errors = String(decoding: err.prefix(errorCap), as: UTF8.self)
        // A pane's text is never read for herdr's words: it may hold anything.
        if exit == 0, text { return .text(readable(output)) }
        let said = HerdrAgent.plain(errors + " " + output)
        if saysUnsupported(exit: exit, said: said) { return .unsupported(firstVerb) }
        if let refusal = refusal(said, mask: mask) { return refusal }
        guard exit == 0 else {
            let words = said.trimmingCharacters(in: .whitespaces)
            return .error(code: "", message: words.isEmpty ? "herdr printed nothing (exit \(exit))" : HerdrAgent.shown(words, mask: mask))
        }
        return .json(HerdrAgent.plain(output).trimmingCharacters(in: .whitespaces))
    }

    /// herdr's JSON error in what it said (`{"error": {"code", "message"}}`, or a bare string), nil without one.
    private static func refusal(_ said: String, mask: SecretMask) -> HerdrResult? {
        HerdrAgent.scan(said) { value, _ -> HerdrResult? in
            guard let object = value as? [String: Any], let error = object["error"] else { return nil }
            let fields = error as? [String: Any]
            let code = fields.flatMap { HerdrAgent.string($0["code"], max: 80) } ?? ""
            let message = fields.flatMap { HerdrAgent.string($0["message"], max: 400) } ?? HerdrAgent.string(error, max: 400) ?? ""
            let shown = message.isEmpty ? "herdr answered with an error" : HerdrAgent.shown(message, mask: mask)
            return .error(code: code, message: shown)
        }
    }

    /// A pane's text as lines: line breaks kept, each line as `HerdrAgent.plain` reads it, its trailing spaces out. Split
    /// on "\n" alone, as `RemoteShell.payload` splits: a Character split keeps "\r\n" whole.
    static func readable(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                let kept = HerdrAgent.plain(line)
                var end = kept.endIndex
                while end > kept.startIndex, kept[kept.index(before: end)] == " " { end = kept.index(before: end) }
                return String(kept[..<end])
            }
            .joined(separator: "\n")
    }
}
