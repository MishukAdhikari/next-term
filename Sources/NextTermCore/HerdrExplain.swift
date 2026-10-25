import Foundation

/// Why herdr gives an agent its state (`herdr agent explain <pane> --json`, herdr 0.6.9 and later), as Peek shows it:
/// herdr's own reasoning, cut to what says why. The agent and its state, the manifest its detection used and that
/// manifest's version, the rule that matched (its id, region and priority), and any fallback, skip or warning herdr
/// gives; each rule it tried, with its evidence, stays out. Next Term reads herdr's words and adds none of its own.
public enum HerdrExplain {
    /// The most lines of an answer that is not herdr's JSON shown as it came.
    public static let shownLines = 20

    /// herdr's explanation in lines, in herdr's own order and words ("state: blocked"); nil when `text` holds no JSON
    /// object herdr gives for it (at the top, or under `result` and `explain`).
    public static func summary(json text: String) -> [String]? {
        guard let explain = object(text) else { return nil }
        func said(_ key: String) -> String? {
            guard let value = explain[key] as? String else { return nil }
            let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : String(words.prefix(300))
        }
        var lines: [String] = []
        if let agent = said("agent") { lines.append("agent: \(agent)") }
        lines.append("state: \(said("state") ?? "unknown")")
        lines.append("manifest: \(said("manifest_source") ?? "none") \(said("manifest_version") ?? "unknown")")
        if let rule = explain["matched_rule"] as? [String: Any] {
            let id = (rule["id"] as? String) ?? "-"
            let region = (rule["region"] as? String) ?? "-"
            let priority = (rule["priority"] as? NSNumber)?.intValue ?? 0
            lines.append("rule: \(id) (region \(region), priority \(priority))")
        } else {
            lines.append("rule: none")
        }
        let reasons = [("fallback_reason", "fallback"), ("screen_detection_skip_reason", "screen detection skipped"),
                       ("skipped_update_reason", "update skipped"), ("remote_update_error", "manifest update"), ("warning", "warning")]
        for (key, label) in reasons {
            if let reason = said(key) { lines.append("\(label): \(reason)") }
        }
        return lines
    }

    /// What Peek shows for herdr's answer: the summary, masked, or, for an answer that is not herdr's JSON, its first
    /// `shownLines` lines as they came, masked.
    public static func shown(_ text: String, mask: SecretMask = .current) -> String {
        if let lines = summary(json: text) { return lines.map { mask.mask($0) }.joined(separator: "\n") }
        let rows = text.components(separatedBy: "\n").prefix(shownLines)
        return mask.mask(rows: Array(rows)).joined(separator: "\n")
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let result = top["result"] as? [String: Any]
        let found = (result?["explain"] as? [String: Any]) ?? result ?? (top["explain"] as? [String: Any]) ?? top
        return found["state"] != nil || found["matched_rule"] != nil || found["manifest_source"] != nil ? found : nil
    }
}
