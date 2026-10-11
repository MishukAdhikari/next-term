import Foundation

// Settings › Remote Access, its status item and its activity view (U11), as pure code: the guided mode's
// recommendation and steps (R49), the connections table's rows with the Control mark (R15, R22), the status item's
// words and its count of the last hour's calls (R37), the activity view's rows (R39), and the fixed texts. The app
// (RemoteAccessSettingsView, RemoteAccessStatusItem, RemoteAccessActivityView) shows them.

// MARK: - texts

/// The words Settings › Remote Access shows that no other part of Remote access owns.
public enum RemoteAccessSettingsText {
    public static let intro = "claude.ai and chatgpt.com, and the Claude phone app through claude.ai, can reach Next "
        + "Term's tools through a tunnel you own. Each connection is allowed here, on this Mac, and does only what "
        + "its options let it."
    /// The switch is disabled while agent control is off (R1).
    public static let agentControlOff = "Turn on “Let agents control Next Term” in Settings › Editor first. Remote "
        + "access can be on only while it is."
    /// Next to Connect a Client (U11, U13).
    public static let leakNotice = "A connected chat can read your open projects. Its options decide what else it "
        + "can do. With Control, anything it sends can run commands on this Mac with your permissions, without "
        + "asking. Text in a tab or a file can trick it into sending what it reads somewhere else."
    public static let keepAwakeLabel = "Keep awake on battery"
    /// R41's note.
    public static let lidNote = "While Remote access is on and this Mac is on power, it doesn't sleep by itself; "
        + "the display still can. Closing the lid sleeps the Mac unless it is on power with an external display."
    public static let leakedTokenTitle = "If the tunnel token leaked"
    /// What to do, in order, when the Cloudflare tunnel token leaked.
    public static let leakedTokenSteps = [
        "Rotate the tunnel's token in the Cloudflare dashboard (Networking › Tunnels, then your tunnel).",
        "Delete the tunnel's connections there, so a copy that runs elsewhere drops.",
        "Turn Remote access off, then paste the new token here.",
        "Click Revoke All, then connect your clients again.",
    ]
    /// The tunnel's settings apply at the next start, so they wait while it is on.
    public static let lockedWhileOn = "Turn Remote access off to change the tunnel."
    /// Beside a hostname field (KTD17).
    public static let hostChangeEnds = "A new hostname ends every connection."
    public static let noConnections = "No connections yet. Click Connect a Client, then add the connector in "
        + "claude.ai or chatgpt.com."
    public static let connectNeedsHost = "Connect a Client works once Remote access is on with a public hostname."
    public static let showAllOptions = "Show all options"
    public static let showGuided = "Show the recommended one"

    /// The connector URL a client adds.
    public static func connectorURL(host: String) -> String {
        "https://\(host)/mcp"
    }

    /// Touch ID's reason for Edit…'s Save, which macOS shows as "Next Term is trying to …" (R60).
    public static func editReason(name: String) -> String {
        "change what “\(name)” can do in Next Term"
    }

    /// The button when the tunnel served another hostname than the saved one (U10).
    public static func useOtherHost(_ host: String) -> String {
        "Use \(host) (ends every connection)"
    }

    /// Beside Connect a Client while pairing is open.
    public static func pairingCountdown(seconds: Int) -> String {
        let left = max(0, seconds)
        return String(format: "Pairing closes in %d:%02d", left / 60, left % 60)
    }

    /// What to check in the Cloudflare dashboard (R33). Next Term reads the route itself, but not the rest.
    public static func cloudflareChecklist(port: Int) -> [String] {
        let address = RemoteAccessTunnelConfig.doorAddress(port: port)
        return [
            "The public hostname is at the first level of your domain, such as mcp.example.com, so Cloudflare's "
                + "certificate covers it.",
            "Its service is \(address), not localhost: localhost can mean ::1, where Next Term doesn't listen.",
            "Bot Fight Mode is off for the domain (Security › Bots), so claude.ai and chatgpt.com get through.",
            "No Cloudflare Access application covers that hostname.",
            "The tunnel is made only for Next Term, with no private network routes.",
        ]
    }
}

// MARK: - the guided mode (R49)

/// Settings › Remote Access opens in a guided mode: it recommends the first tunnel that is ready on this Mac
/// (Tailscale logged in with Funnel allowed, then `cloudflared` with a saved token, then a saved server), and walks
/// through the chosen one's setup a step at a time. With none ready, it lists all four with what each needs.
/// Advanced is never recommended; "Show all options" offers it.
public enum RemoteAccessGuide {
    public typealias Kind = RemoteAccessTunnelConfig.Kind
    public typealias Config = RemoteAccessTunnelConfig

    /// What Settings found of a tool.
    public enum Tool: Equatable, Sendable {
        case missing
        /// `cloudflared` older than 2025.4.0, or one whose version can't be read (R30).
        case tooOld
        case installed
    }

    /// What Settings found on this Mac and in the saved settings.
    public struct Facts: Equatable, Sendable {
        public var tailscale: Tool = .missing
        /// Tailscale's status: the Mac's name when it is logged in with Funnel allowed, or why not; nil until read.
        public var tailscaleStatus: Result<String, Config.TailscaleProblem>?
        public var cloudflared: Tool = .missing
        /// A tunnel token is in the Keychain.
        public var tokenSaved = false
        /// Remote hosts the user saved (R46).
        public var servers = 0
        /// One of them is chosen for "Your own server".
        public var serverChosen = false
        /// The saved public hostname.
        public var host: String?
        /// "Set up Caddy on <server>" typed its commands since Settings opened.
        public var caddyTyped = false
        /// Remote access is on and ready.
        public var on = false

        public init() {}
    }

    /// A choice as the guided list shows it: what it still needs, or nil when it is ready.
    public struct Choice: Equatable, Sendable {
        public var kind: Kind
        public var needs: String?
    }

    /// One step of a choice's setup.
    public struct Step: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var done: Bool
    }

    /// The order recommendations are tried in.
    public static let order: [Kind] = [.funnel, .cloudflare, .ownServer]

    /// The first choice that is ready, or nil.
    public static func recommendation(_ facts: Facts) -> Kind? {
        order.first { needs($0, facts) == nil }
    }

    /// All four, each with what it needs.
    public static func choices(_ facts: Facts) -> [Choice] {
        Kind.allCases.map { Choice(kind: $0, needs: needs($0, facts)) }
    }

    /// What a choice still needs before it can be turned on, or nil when it is ready. Advanced always needs the
    /// user's own tunnel, which Next Term can't see.
    public static func needs(_ kind: Kind, _ facts: Facts) -> String? {
        switch kind {
        case .funnel:
            guard facts.tailscale != .missing else { return Config.Tool.tailscale.installHint }
            switch facts.tailscaleStatus {
            case .success?: return nil
            case .failure(let problem)?: return problem.message
            case nil: return Config.TailscaleProblem.unreadable.message
            }
        case .cloudflare:
            switch facts.cloudflared {
            case .missing: return Config.Tool.cloudflared.missing
            case .tooOld: return Config.updateCloudflared
            case .installed:
                return facts.tokenSaved ? nil : "A tunnel token from the Cloudflare dashboard (Networking › Tunnels)."
            }
        case .ownServer:
            guard facts.servers == 0 else { return nil }
            return "A server you added with File › New Remote Tab…, whose host key this Mac knows, and a public "
                + "hostname whose DNS points to it."
        case .advanced:
            return "A tunnel you run yourself that serves https://your-hostname and forwards it to this Mac."
        }
    }

    /// Why a ready choice is recommended.
    public static func why(_ kind: Kind) -> String {
        switch kind {
        case .funnel: return "Tailscale is logged in, and Funnel is allowed for this Mac."
        case .cloudflare: return "cloudflared is installed, and your tunnel token is saved."
        case .ownServer: return "You have a saved server."
        case .advanced: return "You run your own tunnel."
        }
    }

    /// The index of the step to do now, or nil when every step is done.
    public static func current(_ steps: [Step]) -> Int? {
        steps.firstIndex { !$0.done }
    }

    /// A choice's setup, in order. `port` is the door's port, when one is saved.
    public static func steps(_ kind: Kind, _ facts: Facts, port: Int?) -> [Step] {
        switch kind {
        case .funnel: return funnelSteps(facts)
        case .cloudflare: return cloudflareSteps(facts, port: port)
        case .ownServer: return ownServerSteps(facts)
        case .advanced: return advancedSteps(facts, port: port)
        }
    }

    /// The door's address for a step, or what stands in for it before a port is saved.
    private static func address(_ port: Int?) -> String {
        port.map { Config.doorAddress(port: $0) } ?? "http://127.0.0.1 at the port Settings shows"
    }

    /// Tailscale's problems that come before Funnel: the Mac is not logged in or Tailscale doesn't run.
    private static let loginProblems: Set<Config.TailscaleProblem> = [
        .unreadable, .notLoggedIn, .needsApproval, .stopped, .notRunning,
    ]

    private static func funnelSteps(_ facts: Facts) -> [Step] {
        let installed = facts.tailscale != .missing
        var loginProblem: Config.TailscaleProblem? = installed ? .unreadable : nil
        var funnelProblem: Config.TailscaleProblem?
        switch facts.tailscaleStatus {
        case .success?:
            loginProblem = nil
        case .failure(let problem)?:
            if loginProblems.contains(problem) {
                loginProblem = problem
            } else {
                loginProblem = nil
                funnelProblem = problem
            }
        case nil:
            break
        }
        let loggedIn = installed && loginProblem == nil
        let allowed = loggedIn && funnelProblem == nil
        let login = loginProblem.map { "\($0.message) " } ?? ""
        let funnel = funnelProblem.map { "\($0.message) " } ?? ""
        return [
            Step(title: "Install Tailscale", detail: Config.Tool.tailscale.installHint, done: installed),
            Step(title: "Log in to Tailscale", detail: login + "Log in from the Tailscale menu, then come back here.",
                 done: loggedIn),
            Step(title: "Allow Funnel for this Mac",
                 detail: funnel + "In Tailscale's admin console, turn on HTTPS and Funnel for your tailnet, and let "
                    + "this Mac use Funnel on port 443.",
                 done: allowed),
            Step(title: "Turn on Remote access",
                 detail: "Next Term starts Funnel for its door, and Funnel stops when Remote access turns off.",
                 done: facts.on),
        ]
    }

    private static func cloudflareSteps(_ facts: Facts, port: Int?) -> [Step] {
        let installHint = facts.cloudflared == .tooOld
            ? Config.updateCloudflared : "In Terminal: \(Config.Tool.cloudflared.installHint)"
        return [
            Step(title: "Install cloudflared", detail: installHint, done: facts.cloudflared == .installed),
            Step(title: "Create a tunnel in the Cloudflare dashboard",
                 detail: "In Networking › Tunnels, create a tunnel just for Next Term and give it a public hostname "
                    + "whose service is \(address(port)). Check the list below.",
                 done: facts.tokenSaved),
            Step(title: "Paste the tunnel's token",
                 detail: "Copy it from the tunnel's install command. Next Term keeps it in your Keychain and shows "
                    + "only the tunnel id.",
                 done: facts.tokenSaved),
            Step(title: "Turn on Remote access, then confirm the hostname",
                 detail: "The first time, Next Term shows the hostname the tunnel serves for you to confirm.",
                 done: facts.on && facts.host != nil),
        ]
    }

    private static func ownServerSteps(_ facts: Facts) -> [Step] {
        let chosen = facts.serverChosen && facts.host != nil
        return [
            Step(title: "Add your server",
                 detail: "Add it with File › New Remote Tab…, and connect once in a tab, so this Mac knows its host "
                    + "key.",
                 done: facts.servers > 0),
            Step(title: "Choose the server and type its public hostname",
                 detail: "A hostname whose DNS points to the server, such as mcp.example.com.", done: chosen),
            Step(title: "Set up Caddy on the server",
                 detail: "Caddy serves https for the hostname and passes requests to Next Term's forward. Next Term "
                    + "shows the commands first, and types them in a tab only when you say so.",
                 done: facts.caddyTyped || facts.on),
            Step(title: "Turn on Remote access",
                 detail: "Next Term starts ssh with one forward from the server to this Mac.", done: facts.on),
        ]
    }

    private static func advancedSteps(_ facts: Facts, port: Int?) -> [Step] {
        let served = facts.host.map { "https://\($0)" } ?? "your hostname"
        return [
            Step(title: "Type your tunnel's public hostname",
                 detail: "The hostname your tunnel serves with https, such as mcp.example.com.",
                 done: facts.host != nil),
            Step(title: "Point your tunnel at this Mac",
                 detail: "Send \(served) to \(address(port)) on this Mac. " + Config.advancedWarning,
                 done: facts.on),
            Step(title: "Turn on Remote access",
                 detail: "Next Term opens its door on that port. It doesn't start or stop your tunnel.",
                 done: facts.on),
        ]
    }
}

// MARK: - times

/// How the connections table and the status item say when.
public enum RemoteAccessTimeText {
    /// "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 2 * 86_400 { return "Yesterday" }
        return "\(Int(seconds / 86_400)) days ago"
    }

    /// "In 5 min", "In 3 h", "In 14 days", or "Ended".
    public static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Ended" }
        if seconds < 3600 { return "In \(max(1, Int((seconds / 60).rounded(.up)))) min" }
        if seconds < 86_400 { return "In \(Int((seconds / 3600).rounded(.up))) h" }
        let days = max(1, Int((seconds / 86_400).rounded()))
        return days == 1 ? "In 1 day" : "In \(days) days"
    }
}

// MARK: - the connections table (R15, R22)

/// One connection as Settings lists it: its name, the client (where it goes back to, claude.ai or chatgpt.com,
/// never the client's own words, which anyone can set), its preset's name, the Control mark, and when it was last
/// used and ends.
public struct RemoteAccessConnectionRow: Equatable, Sendable {
    public var id: String
    public var name: String
    /// claude.ai or chatgpt.com.
    public var client: String
    /// The name the client gave itself, its own words: for a tooltip, labelled as such.
    public var clientWords: String?
    public var preset: RemoteAccessPreset
    public var presetTitle: String
    /// Control's name, "Notify on this Mac" off included: the row carries the Control mark (R22).
    public var isControl: Bool
    public var lastUsed: String
    public var expires: String
    public var options: RemoteAccessOptions

    public init(_ grant: RemoteAccessOAuth.Grant, now: Date) {
        id = grant.id
        name = grant.name
        client = grant.redirectHost
        clientWords = grant.clientName
        preset = grant.preset
        presetTitle = grant.preset.title
        isControl = grant.preset == .control
        lastUsed = grant.lastUsed > grant.created ? RemoteAccessTimeText.ago(grant.lastUsed, now: now) : "Not yet"
        expires = RemoteAccessTimeText.until(grant.endsAt, now: now)
        options = grant.options
    }

    /// The rows Settings lists: the grants that are still active under the saved hostname, the newest first. With
    /// no hostname saved, none: a grant works only under the hostname it was issued for (KTD17).
    public static func rows(_ grants: [RemoteAccessOAuth.Grant], host: String?, now: Date) -> [RemoteAccessConnectionRow] {
        guard let host = host?.lowercased() else { return [] }
        let shown = grants.filter { $0.host.lowercased() == host && $0.isActive(at: now) }
        let newest = shown.sorted { $0.created > $1.created }
        return newest.map { RemoteAccessConnectionRow($0, now: now) }
    }
}

// MARK: - the status item (R37)

/// Where Remote access stands, in the status item's words.
public enum RemoteAccessIndicator: Equatable, Sendable {
    case on
    /// Starting, or the tunnel not ready yet.
    case connecting
    /// Was on; the tunnel is not ready, and restarts.
    case reconnecting
    /// Waiting for the user: the Keychain, or the hostname to confirm.
    case waiting
    case off

    public init(_ phase: RemoteAccessStatus.Phase) {
        switch phase {
        case .on: self = .on
        case .starting, .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .waitingForKeychain, .confirmHost: self = .waiting
        case .off, .portBusy, .stopped: self = .off
        }
    }

    public var word: String {
        switch self {
        case .on: return "On"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .waiting: return "Waiting for you"
        case .off: return "Off"
        }
    }
}

/// What the status item shows: only while Remote access is on, its state, the calls in the last hour, and the
/// Control mark with each Control connection while one exists (R37).
public struct RemoteAccessStatusItemModel: Equatable, Sendable {
    public var visible: Bool
    public var indicator: RemoteAccessIndicator
    /// The status line, as Settings shows it.
    public var detail: String
    public var calls: Int
    /// The Control connections, each with Revoke in the menu.
    public var controls: [RemoteAccessConnectionRow]

    public init(status: RemoteAccessStatus, rows: [RemoteAccessConnectionRow], calls: Int) {
        visible = status.isOn
        indicator = RemoteAccessIndicator(status.phase)
        detail = status.text
        self.calls = calls
        controls = rows.filter(\.isControl)
    }

    public var hasControlMark: Bool { !controls.isEmpty }

    public var title: String { "Remote access: \(indicator.word)" }

    public var callsText: String { Self.callsText(calls) }

    public static func callsText(_ calls: Int) -> String {
        switch calls {
        case 0: return "No calls in the last hour"
        case 1: return "1 call in the last hour"
        default: return "\(calls) calls in the last hour"
        }
    }

    /// The icon's tooltip: the state, the calls, and the Control connections by name.
    public var toolTip: String {
        var lines = [title, callsText]
        if !controls.isEmpty {
            let names = controls.map { "“\($0.name)”" }.joined(separator: ", ")
            let noun = controls.count == 1 ? "Control connection" : "Control connections"
            lines.append("\(noun): \(names)")
        }
        return lines.joined(separator: "\n")
    }

    public static func revokeTitle(_ name: String) -> String {
        "Revoke “\(name)”"
    }
}

/// The calls of the last hour, counted a minute at a time, so a busy connection costs at most 61 numbers.
public struct RemoteAccessCallCount: Sendable {
    public static let window: TimeInterval = 3600
    private static let minutes = Int(window / 60)
    private var counts: [Int: Int] = [:]

    public init() {}

    /// Counts one call at `time`, and drops the minutes that are out of the window.
    public mutating func note(at time: Date) {
        let minute = Self.minute(time)
        counts[minute, default: 0] += 1
        counts = counts.filter { $0.key > minute - Self.minutes }
    }

    /// The calls in the hour up to `now`, to the minute.
    public func count(at now: Date) -> Int {
        let minute = Self.minute(now)
        return counts.filter { $0.key > minute - Self.minutes && $0.key <= minute }.values.reduce(0, +)
    }

    /// How many minutes it holds.
    public var buckets: Int { counts.count }

    private static func minute(_ time: Date) -> Int {
        Int((time.timeIntervalSince1970 / 60).rounded(.down))
    }
}

// MARK: - the activity view (R39)

extension RemoteAccessAuditEntry {
    /// A tool call's line (`call(time:grant:…)`).
    public static let callEvent = "tool.call"
}

/// One audit line as the activity view shows it: when, which connection, what happened in words, and the masked
/// details the line holds. Problems (refusals, declines, failures, a key used twice) show as such.
public struct RemoteAccessActivityRow: Equatable, Sendable {
    public var time: Date
    public var connection: String
    public var what: String
    public var detail: String
    public var problem: Bool

    public init(_ entry: RemoteAccessAuditEntry) {
        time = entry.time
        connection = entry.grantName ?? ""
        let said = Self.words(entry)
        what = said.what
        problem = said.problem
        detail = Self.detail(entry)
    }

    private static func words(_ entry: RemoteAccessAuditEntry) -> (what: String, problem: Bool) {
        switch entry.event {
        case RemoteAccessAuditEntry.callEvent: return call(entry)
        case "requests.refused":
            let count = entry.count ?? 1
            let noun = count == 1 ? "request" : "requests"
            return ("\(count) \(noun) refused: \(kind(entry.kind))", true)
        case "remote.turned_off":
            let all = entry.reason == "revoke_all"
            return (all ? "Turned off, and every connection revoked" : "Turned off", false)
        case "tunnel.changed":
            let state = entry.reason ?? ""
            return ("Tunnel: \(state)", state.hasPrefix("stopped") || state == "down")
        default:
            return oauth(entry)
        }
    }

    private static func call(_ entry: RemoteAccessAuditEntry) -> (what: String, problem: Bool) {
        let tool = entry.tool ?? "a tool"
        let reason = entry.reason.map { ": \($0)" } ?? ""
        switch entry.decision {
        case .allowed?: return ("Ran \(tool)", false)
        case .refused?: return ("Refused \(tool)\(reason)", true)
        case .declined?: return ("Declined \(tool) on this Mac", true)
        case .failed?: return ("\(tool) failed\(reason)", true)
        case nil: return (tool, false)
        }
    }

    /// The OAuth authority's events.
    private static func oauth(_ entry: RemoteAccessAuditEntry) -> (what: String, problem: Bool) {
        switch entry.event {
        case "client.registered": return ("A client registered", false)
        case "client.dropped_values": return ("A client's registration was trimmed", false)
        case "pairing.opened": return ("Pairing opened", false)
        case "pairing.closed": return (pairingClosed(entry.reason), false)
        case "pairing.asked": return ("A browser asked to pair", false)
        case "pairing.approved":
            return ("Allowed as \(presetTitle(entry.detail?["preset"]))", false)
        case "pairing.declined": return ("Pairing declined on this Mac", false)
        case "pairing.expired": return ("A pairing request expired", false)
        case "grant.options_changed":
            let old = presetTitle(entry.detail?["old_preset"])
            let new = presetTitle(entry.detail?["new_preset"])
            return ("Options changed: \(old) to \(new)", false)
        case "grant.refresh_reused", "grant.code_reused": return ("A key was used twice, so access was cut", true)
        case "grant.revoked": return revoked(entry.reason)
        case "tokens.dropped": return ("Access keys dropped", false)
        default: return (entry.event, false)
        }
    }

    private static func revoked(_ reason: String?) -> (what: String, problem: Bool) {
        switch reason.flatMap(RemoteAccessOAuth.RevokeReason.init(rawValue:)) {
        case .onMac?: return ("Revoked on this Mac", false)
        case .revokeAll?: return ("Revoked with Revoke All", false)
        case .refreshReuse?, .codeReuse?: return ("Revoked: a key was used twice", true)
        case .client?: return ("Revoked by the client", false)
        case .expired?: return ("Ended: unused too long, or too old", false)
        case .hostChanged?: return ("Ended: the hostname changed", false)
        case nil: return ("Revoked", false)
        }
    }

    private static func pairingClosed(_ reason: String?) -> String {
        switch reason.flatMap(RemoteAccessOAuth.PairingClosed.init(rawValue:)) {
        case .approved?: return "Pairing closed: a connection was allowed"
        case .onMac?: return "Pairing closed on this Mac"
        case .timedOut?: return "Pairing closed after 10 minutes"
        case .wrongCodes?: return "Pairing closed after five wrong codes"
        case .hostChanged?: return "Pairing closed: the hostname changed"
        case nil: return "Pairing closed"
        }
    }

    private static func presetTitle(_ raw: String?) -> String {
        raw.flatMap(RemoteAccessPreset.init(rawValue:))?.title ?? "Custom"
    }

    private static func kind(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        if raw == RemoteAccessRefusals.tooManyCalls { return "over the limits" }
        switch RemoteAccessRefusals.Kind(rawValue: raw) {
        case .wrongHost?: return "wrong host"
        case .badRequest?: return "unreadable"
        case .noToken?: return "no valid key"
        case .origin?: return "sent from a web page"
        case .notFound?: return "unknown path"
        case .badMethod?: return "wrong method"
        case .bodyTooLarge?: return "body too large"
        case .headersTooLarge?: return "headers too large"
        case .badOAuth?: return "bad sign-in request"
        case nil: return raw
        }
    }

    /// The line's masked details, on one line: what was typed or approved, the arguments, the first Host or path
    /// of a summed refusal, the tunnel's detail, or the hosts a client named.
    private static func detail(_ entry: RemoteAccessAuditEntry) -> String {
        var parts: [String] = []
        if let text = entry.text { parts.append("text: \(text)") }
        if let approved = entry.approved { parts.append("approved: \(approved)") }
        if let arguments = entry.arguments, !arguments.isEmpty {
            let shown = arguments.keys.sorted().map { "\($0): \(arguments[$0] ?? "")" }
            parts.append(shown.joined(separator: ", "))
        }
        if let first = entry.first { parts.append(first) }
        if entry.event == "tunnel.changed", let said = entry.detail?["detail"] { parts.append(said) }
        if entry.event == "client.registered" {
            if let name = entry.clientName { parts.append("calls itself “\(name)”") }
            if let hosts = entry.values, !hosts.isEmpty { parts.append(hosts.joined(separator: ", ")) }
        }
        if entry.event == "pairing.asked", let host = entry.detail?["redirect_host"] { parts.append(host) }
        let joined = parts.joined(separator: " · ")
        return joined.replacingOccurrences(of: "\n", with: " ")
    }
}
