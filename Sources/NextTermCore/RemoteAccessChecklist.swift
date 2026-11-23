import Foundation

/// The security steps Settings › Remote Access suggests (owner, 2026-11-23: "suggest the security steps from
/// settings"). Each row is done, suggested, or not checked, and has one action that opens where it is fixed. Only
/// the master key is required; the rest are suggestions. Next Term never changes a macOS security setting itself:
/// a row about one opens its pane in System Settings.
public enum RemoteAccessChecklist {
    public enum State: Equatable, Sendable {
        case done
        case suggested
        /// Next Term can't read it from here; the action still opens where to look.
        case notChecked
    }

    public enum Action: Equatable, Sendable {
        case setMasterKey
        case chooseTunnel
        case copyEdgeRule
        case reviewConnections
        case openSystemSettings(URL)
        case updateCloudflared
        case none
    }

    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let state: State
        public let required: Bool
        public let action: Action
        public let actionTitle: String
    }

    /// What the checklist is read from. A nil fact was not read.
    public struct Facts: Equatable, Sendable {
        public var masterKeySet = false
        public var tunnel: RemoteAccessTunnelConfig.Kind?
        public var host: String?
        public var controlWithoutAsking = 0
        public var fileVaultOn: Bool?
        public var firewallOn: Bool?
        public var cloudflaredCurrent: Bool?
        public init() {}
    }

    static func pane(_ path: String) -> URL { URL(string: "x-apple.systempreferences:" + path)! }

    /// The edge rule for a Cloudflare WAF custom rule on the tunnel's hostname, with the action Block: requests to the
    /// MCP endpoint and the token endpoint from anywhere but Anthropic's outbound ranges and the Cloudflare IP list
    /// `listName` are blocked. The sign-in pages, which a browser opens, stay reachable. OpenAI's ranges change, so
    /// they go in that list, filled from `openAIRangesURL`. Google publishes no ranges: a Gemini connection needs the
    /// rule off.
    public static func edgeRule(host: String) -> String {
        let anthropic = anthropicRanges.joined(separator: " ")
        return "(http.host eq \"\(host)\" and (starts_with(http.request.uri.path, \"/mcp\") or http.request.uri.path eq \"/token\"))"
            + " and not ip.src in {\(anthropic)} and not ip.src in $\(listName)"
    }

    /// Anthropic's outbound ranges, which MCP tool calls come from ("will not change without notice"),
    /// from docs.anthropic.com/en/api/ip-addresses as of 2026-11-23.
    public static let anthropicRanges = ["160.79.104.0/21", "153.61.208.0/20"]
    /// OpenAI's connector egress ranges, which OpenAI asks to be fetched regularly.
    public static let openAIRangesURL = URL(string: "https://openai.com/chatgpt-connectors.json")!
    /// The Cloudflare IP list the rule names for them.
    public static let listName = "chatgpt_connectors"

    /// The IPv4 and IPv6 prefixes in OpenAI's chatgpt-connectors.json, one per line, for the Cloudflare list.
    public static func openAIPrefixes(fromJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefixes = object["prefixes"] as? [[String: Any]] else { return [] }
        return prefixes.compactMap { ($0["ipv4Prefix"] ?? $0["ipv6Prefix"]) as? String }
    }

    public static func rows(_ facts: Facts) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(id: "master-key", title: "Master key set",
                        detail: "Needed to turn Remote access on and to give a connection more than reading.",
                        state: facts.masterKeySet ? .done : .suggested, required: true,
                        action: facts.masterKeySet ? .none : .setMasterKey, actionTitle: facts.masterKeySet ? "" : "Set Master Key…"))
        let ownDomain = facts.tunnel == .cloudflare || ((facts.tunnel == .ownServer || facts.tunnel == .advanced) && facts.host != nil)
        rows.append(Row(id: "own-domain", title: "A named tunnel on your own domain",
                        detail: "A Cloudflare tunnel or your own server keeps one address you control. Tailscale Funnel is fine for a quick try.",
                        state: facts.tunnel == nil ? .notChecked : (ownDomain ? .done : .suggested), required: false,
                        action: ownDomain ? .none : .chooseTunnel, actionTitle: ownDomain ? "" : "Choose…"))
        rows.append(Row(id: "edge-rule", title: "Only Claude and ChatGPT can reach the tool endpoint",
                        detail: "A Cloudflare WAF rule that blocks /mcp and /token from every other address. Turn it off to use Gemini, which publishes no addresses.",
                        state: .notChecked, required: false, action: facts.host == nil ? .none : .copyEdgeRule,
                        actionTitle: facts.host == nil ? "" : "Copy Rule"))
        rows.append(Row(id: "control-asks", title: "Every connection asks on this Mac before changes",
                        detail: facts.controlWithoutAsking == 0 ? "No connection runs changes without asking."
                            : "\(facts.controlWithoutAsking) connection\(facts.controlWithoutAsking == 1 ? "" : "s") can change things without asking.",
                        state: facts.controlWithoutAsking == 0 ? .done : .suggested, required: false,
                        action: facts.controlWithoutAsking == 0 ? .none : .reviewConnections,
                        actionTitle: facts.controlWithoutAsking == 0 ? "" : "Review…"))
        rows.append(Row(id: "filevault", title: "FileVault is on", detail: "Your disk is encrypted if the Mac is lost.",
                        state: state(facts.fileVaultOn), required: false,
                        action: facts.fileVaultOn == true ? .none : .openSystemSettings(pane("com.apple.settings.PrivacySecurity.extension")),
                        actionTitle: facts.fileVaultOn == true ? "" : "Open Settings…"))
        rows.append(Row(id: "firewall", title: "The macOS firewall is on", detail: "Next Term listens only on this Mac either way.",
                        state: state(facts.firewallOn), required: false,
                        action: facts.firewallOn == true ? .none : .openSystemSettings(pane("com.apple.Network-Settings.extension?Firewall")),
                        actionTitle: facts.firewallOn == true ? "" : "Open Settings…"))
        rows.append(Row(id: "screen-lock", title: "The screen locks soon after sleep",
                        detail: "So no one at the Mac can approve a remote change for you.",
                        state: .notChecked, required: false,
                        action: .openSystemSettings(pane("com.apple.Lock-Screen-Settings.extension")), actionTitle: "Open Settings…"))
        if facts.tunnel == .cloudflare {
            rows.append(Row(id: "cloudflared", title: "cloudflared is up to date", detail: "Tunnel fixes ship in its updates.",
                            state: state(facts.cloudflaredCurrent), required: false,
                            action: facts.cloudflaredCurrent == true ? .none : .updateCloudflared,
                            actionTitle: facts.cloudflaredCurrent == true ? "" : "Update…"))
        }
        return rows
    }

    private static func state(_ fact: Bool?) -> State {
        guard let fact else { return .notChecked }
        return fact ? .done : .suggested
    }

    /// Whether Remote access may turn on: every required row done.
    public static func canTurnOn(_ facts: Facts) -> Bool {
        rows(facts).allSatisfy { !$0.required || $0.state == .done }
    }

    /// `fdesetup status`'s answer read: true on, false off, nil unknown.
    public static func fileVault(fromStatus text: String) -> Bool? {
        if text.contains("FileVault is On") { return true }
        if text.contains("FileVault is Off") { return false }
        return nil
    }

    /// `socketfilterfw --getglobalstate`'s answer read.
    public static func firewall(fromState text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("enabled") || lower.contains("state = 1") || lower.contains("state = 2") { return true }
        if lower.contains("disabled") || lower.contains("state = 0") { return false }
        return nil
    }
}
