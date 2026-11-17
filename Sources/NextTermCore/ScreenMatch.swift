import Foundation

/// wait_for_tab's `match` for a tab on this Mac (plan 040 U2): the same rule herdr's `pane wait-output` has, so one
/// call waits for text in a tab or a herdr pane alike. A literal substring, or with `regex` a regular expression.
public enum ScreenMatch {
    /// Why the pattern can't be waited for, or nil: empty, over 1,000 characters, or not a regular expression.
    public static func refusal(_ pattern: String, regex: Bool) -> String? {
        if pattern.isEmpty { return "Give match: the text to wait for." }
        if pattern.count > 1000 { return "match is longer than 1,000 characters." }
        if regex, (try? NSRegularExpression(pattern: pattern)) == nil { return "“\(pattern.prefix(60))” is not a regular expression." }
        return nil
    }

    /// Whether `text` shows the pattern.
    public static func matches(_ text: String, pattern: String, regex: Bool) -> Bool {
        guard regex else { return text.contains(pattern) }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
