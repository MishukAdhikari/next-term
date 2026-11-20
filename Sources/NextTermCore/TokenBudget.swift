import Foundation

/// A session's token budget (the owner: "if they ask budget, a very light budget indicator may stay in bottom"): set when
/// the user asks (an agent's `set_token_budget`, or the chat's usage line), shown under the composer only while set,
/// never enforced. What it counts is what the agent itself recorded for the whole session, never an estimate.
public enum TokenBudget {
    /// From this much of the budget on, the indicator is amber.
    public static let warnFraction = 0.9

    /// "2M", "500k", "1.5m", "2000000", or a number: the tokens, or nil for anything else (0 is a valid "clear").
    public static func parse(_ raw: Any) -> Int? {
        if MCPServer.isBoolean(raw) { return nil }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return value >= 0 && value <= 1e12 && value == value.rounded() ? Int(value) : nil
        }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ""),
              !text.isEmpty else { return nil }
        var digits = text
        var scale = 1.0
        if digits.hasSuffix("k") { scale = 1_000; digits.removeLast() }
        else if digits.hasSuffix("m") { scale = 1_000_000; digits.removeLast() }
        guard let value = Double(digits.trimmingCharacters(in: .whitespaces)), value >= 0, value * scale <= 1e12 else { return nil }
        return Int((value * scale).rounded())
    }

    /// "1.2M of 2M budget", and how far along (0 up; past 1 over budget).
    public static func words(spent: Int, budget: Int) -> (text: String, fraction: Double) {
        let fraction = budget > 0 ? Double(spent) / Double(budget) : 0
        return ("\(AgentUsage.tokens(spent)) of \(AgentUsage.tokens(budget)) budget", fraction)
    }
}

/// A session's tokens so far, read from its transcript as it grows: Claude Code's each message's fresh input, cache
/// writes and output (cache reads apart, as a budget counts them), each message once though its usage repeats on every
/// record of it; Codex's own running total (total_token_usage), its cached input apart. Feed it what was appended.
public struct TokenSpend: Sendable {
    public let kind: AgentTranscript.Kind
    /// Claude: each message's tokens by id (the last record of it wins).
    private var messages: [String: Int] = [:]
    private var unnamed = 0
    /// Codex: the last running total read.
    private var codexTotal = 0
    private var rest = Data()

    public init(kind: AgentTranscript.Kind) { self.kind = kind }

    /// The session's tokens so far.
    public var total: Int {
        switch kind {
        case .claude: return messages.values.reduce(unnamed, +)
        case .codex: return codexTotal
        }
    }

    public mutating func feed(_ data: Data) {
        rest.append(data)
        while let end = rest.firstIndex(of: 0x0A) {
            let line = rest[rest.startIndex..<end]
            rest = Data(rest[rest.index(after: end)...])
            take(line)
        }
    }

    private mutating func take(_ line: Data) {
        // Cheap check before parsing: only the lines that can carry it.
        let marker = kind == .claude ? Data("\"usage\"".utf8) : Data("\"token_count\"".utf8)
        guard line.range(of: marker) != nil,
              let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return }
        switch kind {
        case .claude:
            guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let tokens = Self.int(usage["input_tokens"]) + Self.int(usage["cache_creation_input_tokens"]) + Self.int(usage["output_tokens"])
            if let id = message["id"] as? String { messages[id] = tokens } else { unnamed += tokens }
        case .codex:
            guard let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { return }
            codexTotal = max(0, Self.int(total["input_tokens"]) - Self.int(total["cached_input_tokens"])) + Self.int(total["output_tokens"])
        }
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}
