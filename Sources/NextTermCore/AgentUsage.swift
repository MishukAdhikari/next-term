import Foundation

/// How full an agent's context is, read from the tail of the transcript its own screen writes (the one
/// `AgentTranscript` finds): Claude Code's last main-chain assistant message, or Codex's last `token_count` event.
/// Nothing is sent anywhere; it is shown on the agent's tab.
public struct AgentUsage: Equatable, Sendable {
    /// Tokens the last request held in its context.
    public var used: Int
    /// The context window those tokens count against.
    public var window: Int
    /// The model, when the transcript names it.
    public var model: String?
    /// Codex's rate limits, as it reports them (Claude Code's transcript has none).
    public var limits: [Limit]

    public struct Limit: Equatable, Sendable {
        /// Minutes the limit spans (300 is the 5-hour one, 10,080 the weekly one).
        public var minutes: Int?
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(minutes: Int?, usedPercent: Double, resetsAt: Date?) {
            self.minutes = minutes
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }

        /// "5-hour limit", "weekly limit", or "limit".
        public var name: String {
            switch minutes {
            case 300?: return "5-hour limit"
            case 10_080?: return "weekly limit"
            case let minutes? where minutes % 1440 == 0: return "\(minutes / 1440)-day limit"
            case let minutes? where minutes % 60 == 0: return "\(minutes / 60)-hour limit"
            default: return "limit"
            }
        }
    }

    public init(used: Int, window: Int, model: String? = nil, limits: [Limit] = []) {
        self.used = used
        self.window = window
        self.model = model
        self.limits = limits
    }

    /// Whole percent of the window used, 0 to 100.
    public var percent: Int {
        guard window > 0 else { return 0 }
        return min(100, max(0, Int((Double(used) / Double(window) * 100).rounded())))
    }

    /// From this much on, the tab marks it.
    public static let warnPercent = 80

    /// "42%", for the pane header.
    public var short: String { "\(percent)%" }

    /// "Context 84k of 200k (42%)", then a line per rate limit, for the tab's hover tip.
    public var lines: [String] {
        var lines = ["Context \(Self.tokens(used)) of \(Self.tokens(window)) (\(percent)%)"]
        for limit in limits { lines.append("\(limit.name.prefix(1).uppercased() + String(limit.name.dropFirst())) \(Int(limit.usedPercent.rounded()))%") }
        return lines
    }

    /// For `list_tabs`: `used`, `window` and `percent`, with `model` and `limits` when known.
    public var fields: [String: Any] {
        var fields: [String: Any] = ["used": used, "window": window, "percent": percent]
        if let model { fields["model"] = model }
        if !limits.isEmpty {
            fields["limits"] = limits.map { limit -> [String: Any] in
                var item: [String: Any] = ["name": limit.name, "used_percent": Int(limit.usedPercent.rounded())]
                if let resets = limit.resetsAt { item["resets_at"] = ISO8601DateFormatter().string(from: resets) }
                return item
            }
        }
        return fields
    }

    /// 950, 84k, 1.2M.
    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        let millions = Double(count) / 1_000_000
        return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
    }

    // MARK: reading

    /// Claude Code's window: 1M for a model named with it (`[1m]`, `-1m`) or once a request held more than 200k,
    /// else 200k. Its transcript does not say which.
    public static func claudeWindow(model: String?, used: Int) -> Int {
        let name = model?.lowercased() ?? ""
        if name.contains("[1m]") || name.hasSuffix("-1m") || used > 200_000 { return 1_000_000 }
        return 200_000
    }

    /// The usage the tail's last record of it gives, or nil when there is none. A partial first or last line is skipped.
    public static func read(tail: Data, kind: AgentTranscript.Kind) -> AgentUsage? {
        guard let text = String(data: tail, encoding: .utf8) ?? String(data: tail, encoding: .isoLatin1) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            // Cheap check before parsing: only the lines that can carry it.
            switch kind {
            case .claude: guard line.contains("\"usage\"") else { continue }
            case .codex: guard line.contains("\"token_count\"") else { continue }
            }
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let usage = kind == .claude ? claude(record) : codex(record)
            if let usage { return usage }
        }
        return nil
    }

    static func claude(_ record: [String: Any]) -> AgentUsage? {
        guard record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return nil }
        let used = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["cache_read_input_tokens"])
        guard used > 0 else { return nil }
        let model = message["model"] as? String
        return AgentUsage(used: used, window: claudeWindow(model: model, used: used), model: model)
    }

    static func codex(_ record: [String: Any]) -> AgentUsage? {
        guard let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { return nil }
        let window = int(info["model_context_window"])
        let total = int(last["total_tokens"])
        let used = total > 0 ? total : int(last["input_tokens"]) + int(last["output_tokens"])
        guard used > 0, window > 0 else { return nil }
        var limits: [Limit] = []
        if let rates = payload["rate_limits"] as? [String: Any] {
            for key in ["primary", "secondary"] {
                guard let limit = rates[key] as? [String: Any], let percent = double(limit["used_percent"]) else { continue }
                let minutes = limit["window_minutes"].map(int)
                let resets = double(limit["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                limits.append(Limit(minutes: minutes, usedPercent: percent, resetsAt: resets))
            }
        }
        return AgentUsage(used: used, window: window, limits: limits)
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
