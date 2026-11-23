import AppKit
import NextTermCore

/// Each agent tab's token budget (the owner: "if they ask budget, a very light budget indicator may stay in bottom"):
/// set when the user asks, through an agent (set_token_budget) or the chat's usage line, kept while the tab is open,
/// shown under the chat's composer, never enforced. What it counts is the session's running total as its agent
/// recorded it (TokenSpend), read from the transcript the chat follows, only what was appended since the last read.
@MainActor
enum TokenBudgets {
    /// By tab id.
    private(set) static var budgets: [UUID: Int] = [:]
    private static var reads: [UUID: (path: String, offset: Int, spend: TokenSpend)] = [:]
    private static var reading: Set<UUID> = []
    private static let queue = DispatchQueue(label: "nt.token-budget", qos: .utility)

    /// The transcript a tab's running total is read from: a live Claude Code or Codex tab's (plan 041), once its chat
    /// has found it. Command Code and agent sessions record no running total Next Term reads.
    static func source(_ tab: TerminalTab) -> (path: String?, kind: AgentTranscript.Kind)? {
        guard let agent = tab.localAgent.flatMap(LiveChat.Agent.init) else { return nil }
        let kind: AgentTranscript.Kind
        switch agent {
        case .claude: kind = .claude
        case .codex: kind = .codex
        case .commandCode: return nil
        }
        return (LiveChatWatch.existingFeed(tab.id)?.path, kind)
    }

    /// Sets `tab`'s budget, or clears it with nil or 0.
    static func set(_ tokens: Int?, for tab: TerminalTab) {
        if let tokens, tokens > 0 { budgets[tab.id] = tokens } else { budgets.removeValue(forKey: tab.id) }
        if budgets[tab.id] == nil { reads.removeValue(forKey: tab.id) }
    }

    /// The tokens counted so far, when known.
    static func spent(_ tab: TerminalTab) -> Int? {
        guard let read = reads[tab.id], read.path == source(tab)?.path else { return nil }
        return read.spend.total
    }

    /// Reads what the tab's transcript gained since the last read, off the main thread; `done` when the total changed.
    static func refresh(_ tab: TerminalTab, done: @escaping () -> Void) {
        let id = tab.id
        guard budgets[id] != nil, !reading.contains(id), let source = source(tab), let path = source.path else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        var current: (path: String, offset: Int, spend: TokenSpend) = reads[id].flatMap { $0.path == path ? $0 : nil }
            ?? (path: path, offset: 0, spend: TokenSpend(kind: source.kind))
        guard size > current.offset else { return }
        reading.insert(id)
        queue.async {
            var data = Data()
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.seek(toOffset: UInt64(current.offset))
                data = (try? handle.read(upToCount: size - current.offset)) ?? Data()
                try? handle.close()
            }
            let before = current.spend.total
            current.spend.feed(data)
            current.offset += data.count
            let result = current
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    reading.remove(id)
                    guard budgets[id] != nil else { return }
                    reads[id] = result
                    if result.spend.total != before { done() }
                }
            }
        }
    }

    /// The tab closed.
    static func forget(_ tabID: UUID) {
        budgets.removeValue(forKey: tabID)
        reads.removeValue(forKey: tabID)
    }

    /// list_tabs: `budget` with its `tokens`, and `spent` once counted.
    static func fields(_ tab: TerminalTab) -> [String: Any] {
        guard let tokens = budgets[tab.id] else { return [:] }
        var budget: [String: Any] = ["tokens": tokens]
        if let spent = spent(tab) { budget["spent"] = spent }
        return ["budget": budget]
    }

    /// set_token_budget: a tab's budget, or none. Refused, with why, where nothing would count it.
    static func setFromMCP(_ tab: TerminalTab, _ arguments: [String: Any]) -> MCPServer.CallResult {
        guard let raw = arguments["tokens"], let tokens = TokenBudget.parse(raw) else {
            return MCPControl.fail("tokens takes a number of tokens, or words such as \"2M\" or \"500k\"; 0 clears the budget.")
        }
        if tokens > 0, source(tab) == nil {
            return MCPControl.fail("That tab's agent records no running total of its tokens that Next Term reads (only local Claude Code and Codex tabs do), so a budget there would count nothing.")
        }
        set(tokens, for: tab)
        LiveChatMCP.pane(of: tab)?.liveChat?.refresh()
        var answer: [String: Any] = ["id": tab.id.uuidString.lowercased()]
        answer["budget"] = tokens > 0 ? (fields(tab)["budget"] ?? NSNull()) : NSNull()
        return MCPControl.ok(answer)
    }
}

/// The budget's hairline: a quiet track the column's width, filled as far as the session has spent, amber from
/// `TokenBudget.warnFraction`, full and amber past it.
final class BudgetBar: NSView {
    static let height: CGFloat = 2
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var fraction: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        track.cornerRadius = Self.height / 2
        fill.cornerRadius = Self.height / 2
        setAccessibilityElement(false) // the usage line says it in words
        // A theme chosen in Settings keeps the look light or dark, so no appearance change reaches this view: its
        // layers take the new theme's colours here.
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeWatch.didChange, object: nil)
    }

    @objc private func themeChanged() { updateColours() }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(fraction: Double) {
        self.fraction = max(0, fraction)
        needsLayout = true
        updateColours()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, fraction)), height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }

    private func updateColours() {
        Theme.appearance(of: self).performAsCurrentDrawingAppearance {
            track.backgroundColor = Theme.system(.separator).withAlphaComponent(0.5).cgColor
            fill.backgroundColor = (fraction >= TokenBudget.warnFraction ? Theme.system(.orange) : Theme.textDim).cgColor
        }
    }
}
