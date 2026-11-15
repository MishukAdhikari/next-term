import Foundation

/// What the connector bar says when an agent needed one of the user's MCP servers and something only the user can do
/// stands in the way: a sign-in, a reconnect, more access, a server out of reach, or one that didn't start.
///
/// The bar shows only in the window whose agent asked, only then (never at launch, never for a server no agent used),
/// with one primary action and a quiet Not Now that holds for the server until what it needs changes. Its words name
/// the server and the agent, never "error". Several servers share one bar. The pure part lives here: the needs, the
/// words, and which needs Not Now holds; the app (MCPConnectorBar) shows them and acts.
public enum MCPConnectorAttention {
    public enum Need: Equatable, Sendable {
        /// The server asked for a sign-in Next Term doesn't have.
        case signIn
        /// The sign-in lapsed, or was changed outside Next Term.
        case reconnect
        /// The server asked for more access than the sign-in has.
        case moreAccess([String])
        /// The server couldn't be reached: the reason, for the tooltip.
        case unreachable(String)
        /// A server the agent's session starts didn't start: its reason.
        case didntStart(String)

        /// Mended by a sign-in in the browser.
        public var signsIn: Bool {
            switch self {
            case .signIn, .reconnect, .moreAccess: return true
            case .unreachable, .didntStart: return false
            }
        }

        /// The kind alone, for Not Now: a reason that changes words doesn't bring a held bar back; another need does.
        var kind: Int {
            switch self {
            case .signIn: return 0
            case .reconnect: return 1
            case .moreAccess: return 2
            case .unreachable: return 3
            case .didntStart: return 4
            }
        }
    }

    public struct Item: Equatable, Sendable {
        /// The server's name, and the list it is in (the user's, or a project's).
        public var server: String
        public var list: String
        public var url: String?
        public var need: Need
        /// The agent that needed it, as the user knows it ("Claude Code"), and its tab's name when that tab isn't the one
        /// in front.
        public var agent: String?
        public var tab: String?

        public init(server: String, list: String, url: String? = nil, need: Need, agent: String? = nil, tab: String? = nil) {
            self.server = server
            self.list = list
            self.url = url
            self.need = need
            self.agent = agent
            self.tab = tab
        }

        /// One item per server of a list.
        public var key: String { list + "\u{0}" + server }
    }

    /// What the primary button does.
    public enum Action: Equatable, Sendable {
        /// Sign in, one server after another ("1 of 2").
        case signIn
        /// Check the server again now.
        case retry
        /// Settings › MCP Servers, with the server selected.
        case openSettings
    }

    public enum Glyph: Equatable, Sendable { case needsYou, offline, working, done, failed }

    public struct Words: Equatable, Sendable {
        public var message: String
        /// The primary button's title; nil for none (the browser is out, or it's done).
        public var primary: String?
        public var action: Action?
        public var glyph: Glyph
        /// The longer reason, for the message's tooltip.
        public var detail: String?

        public init(message: String, primary: String? = nil, action: Action? = nil, glyph: Glyph, detail: String? = nil) {
            self.message = message
            self.primary = primary
            self.action = action
            self.glyph = glyph
            self.detail = detail
        }
    }

    /// The bar's words for the servers that need the user, in the order they came.
    public static func words(_ items: [Item]) -> Words? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return words(first) }
        let names = items.map(\.server)
        if items.count == 2, items.allSatisfy({ $0.need.signsIn }) {
            let both = names[0] + " and " + names[1]
            if items.allSatisfy({ $0.need == .reconnect }) {
                return Words(message: both + " signed out, so your agents can\u{2019}t use them.", primary: "Reconnect",
                             action: .signIn, glyph: .needsYou)
            }
            return Words(message: both + " need you to sign in before your agents can use them.", primary: "Sign In",
                         action: .signIn, glyph: .needsYou)
        }
        return Words(message: "\(items.count) MCP servers need you before your agents can use them.", primary: "Review\u{2026}",
                     action: .openSettings, glyph: .needsYou, detail: names.joined(separator: ", "))
    }

    static func words(_ item: Item) -> Words {
        let server = item.server
        let who = agentPhrase(item)
        switch item.need {
        case .signIn:
            return Words(message: "\(server) needs you to sign in before \(who ?? "your agents") can use it.", primary: "Sign In",
                         action: .signIn, glyph: .needsYou)
        case .reconnect:
            let message = who.map { "\(server) signed out. \($0) is waiting to use it." }
                ?? "\(server) signed out, so your agents can\u{2019}t use it."
            return Words(message: message, primary: "Reconnect", action: .signIn, glyph: .needsYou)
        case .moreAccess(let scopes):
            let named = scopes.isEmpty ? "" : " (\(scopes.joined(separator: " ")))"
            return Words(message: "\(server) needs more access for \(who ?? "your agents")\(named).", primary: "Allow More Access",
                         action: .signIn, glyph: .needsYou)
        case .unreachable(let why):
            let message = who.map { "Next Term can\u{2019}t reach \(server) for \($0)." } ?? "Next Term can\u{2019}t reach \(server)."
            return Words(message: message, primary: "Retry Now", action: .retry, glyph: .offline, detail: line(why))
        case .didntStart(let why):
            let reason = line(why)
            let message = reason.isEmpty ? "\(server) didn\u{2019}t start." : "\(server) didn\u{2019}t start: \(sentence(reason))"
            return Words(message: message, primary: "Open MCP Servers\u{2026}", action: .openSettings, glyph: .failed, detail: reason)
        }
    }

    /// While the browser is out: "Finish signing in to Linear in your browser." and, walking several, "(1 of 2)".
    public static func browser(_ server: String, step: Int = 1, of steps: Int = 1) -> Words {
        Words(message: "Finish signing in to \(server) in your browser." + (steps > 1 ? " (\(step) of \(steps))" : ""),
              primary: nil, action: nil, glyph: .working)
    }

    /// After the user's own sign-in or retry worked: the agent can call again, with no restart.
    public static func connected(_ items: [Item]) -> Words {
        let names = items.map(\.server)
        let named = names.count == 2 ? names[0] + " and " + names[1] : names.first ?? "The server"
        let agent = items.compactMap(\.agent).first
        let message = names.count > 2 ? "Your MCP servers are connected." : "\(named) \(names.count == 2 ? "are" : "is") connected."
        let them = names.count == 1 ? "it" : "them"
        return Words(message: message + " " + (agent.map { "\($0) can use \(them) now, with no restart." } ?? "Your agents can use \(them) now."),
                     primary: nil, action: nil, glyph: .done)
    }

    /// A sign-in or a retry that didn't work: why, with the same action offered again.
    public static func failed(_ why: String, retry action: Action) -> Words {
        Words(message: sentence(line(why)), primary: "Try Again", action: action, glyph: .failed, detail: why)
    }

    /// "Claude Code", or "Codex in “api-tests”" when its tab isn't the one in front.
    static func agentPhrase(_ item: Item) -> String? {
        guard let agent = item.agent else { return nil }
        guard let tab = item.tab?.trimmingCharacters(in: .whitespacesAndNewlines), !tab.isEmpty else { return agent }
        return agent + " in \u{201C}" + String(tab.prefix(40)) + "\u{201D}"
    }

    /// A reason's first line, 160 characters at most.
    static func line(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(159)) + "\u{2026}" : trimmed
    }

    /// Ends with a full stop unless it ends in punctuation already.
    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?\u{2026}".contains(last) ? text : text + "."
    }

    /// Not Now: holds a server's bar, everywhere, until it needs something else or is mended. In memory, for the app's
    /// run: a new launch starts clean, and nothing shows at launch anyway.
    public struct Held: Equatable, Sendable {
        private var held: [String: Int] = [:]

        public init() {}

        public mutating func hold(_ item: Item) { held[item.key] = item.need.kind }
        /// Mended (signed in, reached): the next need shows again.
        public mutating func release(_ key: String) { held[key] = nil }
        public func holds(_ item: Item) -> Bool { held[item.key] == item.need.kind }
    }
}
