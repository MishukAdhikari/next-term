import Foundation

/// The chat's token usage line (0.11.69): one quiet line under the composer, "190k tokens · 95% of context", from what
/// the agent itself records (its transcript, or an agent session's usage_update), never an estimate. The figures are
/// tabular in the view; the percent is tinted only from `AgentUsage.warnPercent`. Its tooltip breaks the last request
/// down by kind when the agent gives that.
public enum ChatUsageLine {
    /// "190k tokens", "95% of context", and whether the percent is near the limit.
    public static func parts(_ usage: AgentUsage) -> (tokens: String, percent: String, nearLimit: Bool) {
        ("\(AgentUsage.tokens(usage.used)) tokens", "\(usage.percent)% of context", usage.percent >= AgentUsage.warnPercent)
    }

    /// The line as one string: "190k tokens · 95% of context".
    public static func text(_ usage: AgentUsage) -> String {
        let parts = parts(usage)
        return parts.tokens + " \u{00B7} " + parts.percent
    }

    /// The tooltip: the context in full figures, the last request by kind, and the model.
    public static func tooltip(_ usage: AgentUsage, locale: Locale = .current) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.locale = locale
        func n(_ value: Int) -> String { number.string(from: NSNumber(value: value)) ?? String(value) }
        var lines = ["Context: \(n(usage.used)) of \(n(usage.window)) tokens (\(usage.percent)%)"]
        if let parts = usage.breakdown {
            var kinds = ["input \(n(parts.input))"]
            if parts.cacheRead > 0 { kinds.append("cache read \(n(parts.cacheRead))") }
            if parts.cacheWritten > 0 { kinds.append("cache written \(n(parts.cacheWritten))") }
            kinds.append("output \(n(parts.output))")
            lines.append("Last request: " + kinds.joined(separator: ", "))
        }
        if let model = usage.model { lines.append("Model: \(model)") }
        return lines.joined(separator: "\n")
    }
}
