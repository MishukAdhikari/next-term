import Foundation

/// MCP's `remote_access_guide` (owner, 2026-11-23: "make Next Term's skills and MCP smart enough to suggest steps to
/// the users how to set up the tunnel"): what Settings › Remote Access's guided mode shows, read from this Mac, as an
/// answer an agent can walk the user through. It reads only: it turns nothing on, picks no tunnel and saves no port,
/// and it never holds a token, the master key or anything else the user types in Settings. The skill
/// next-term-remote-access says how to use it.
public enum RemoteAccessGuideAnswer {
    public typealias Kind = RemoteAccessTunnelConfig.Kind

    /// The names agents use for the tunnels (the tool's `tunnel` argument and its answer).
    public static func name(_ kind: Kind) -> String {
        switch kind {
        case .funnel: return "funnel"
        case .cloudflare: return "cloudflare"
        case .ownServer: return "own_server"
        case .advanced: return "advanced"
        }
    }

    public static func kind(named name: String) -> Kind? {
        Kind.allCases.first { self.name($0) == name.lowercased() }
    }

    /// What the answer is built from, besides the guide's facts.
    public struct Inputs: Equatable, Sendable {
        public var facts = RemoteAccessGuide.Facts()
        /// The saved tunnel, if one was chosen.
        public var saved: Kind?
        /// The status word ("On", "Off", "Connecting"…).
        public var status = "Off"
        /// The door's saved port, nil until one is picked.
        public var port: Int?
        public var security = RemoteAccessChecklist.Facts()
        public init() {}
    }

    /// The tunnel the steps are for: the one asked about, else the saved one, else the one ready now, else Cloudflare
    /// (a named tunnel on the user's own domain: the checklist's suggestion for every day).
    public static func guideKind(asked: Kind?, _ inputs: Inputs) -> Kind {
        asked ?? inputs.saved ?? RemoteAccessGuide.recommendation(inputs.facts) ?? .cloudflare
    }

    public static func answer(asked: Kind?, _ inputs: Inputs) -> [String: Any] {
        let facts = inputs.facts
        let kind = guideKind(asked: asked, inputs)
        let steps = RemoteAccessGuide.steps(kind, facts, port: inputs.port)
        var answer: [String: Any] = [
            "on": facts.on,
            "status": inputs.status,
            "guide_for": name(kind),
            "steps": steps.enumerated().map { index, step in
                ["step": index + 1, "title": step.title, "detail": step.detail, "done": step.done] as [String: Any]
            },
            "tunnels": RemoteAccessGuide.choices(facts).map { choice -> [String: Any] in
                var row: [String: Any] = ["tunnel": name(choice.kind), "label": choice.kind.label, "ready": choice.needs == nil,
                                          "traffic": choice.kind.traffic]
                if let needs = choice.needs { row["needs"] = needs }
                return row
            },
            "security": RemoteAccessChecklist.rows(inputs.security).map { row -> [String: Any] in
                let state: String = switch row.state {
                case .done: "done"
                case .suggested: "suggested"
                case .notChecked: "not_checked"
                }
                return ["id": row.id, "title": row.title, "detail": row.detail, "state": state, "required": row.required]
            },
            "can_turn_on": RemoteAccessChecklist.canTurnOn(inputs.security),
            "settings": "show_settings with tab remote_access opens Settings › Remote Access in front of the user.",
            "users_part": "Only the user turns Remote access on, sets or types the master key, answers Touch ID, pastes a "
                + "tunnel token and allows a connection, all in Next Term on the Mac. Never ask for the token or the "
                + "master key, and never read either.",
        ]
        if let current = RemoteAccessGuide.current(steps) { answer["current_step"] = current + 1 }
        if let saved = inputs.saved { answer["tunnel"] = name(saved) }
        if let recommended = RemoteAccessGuide.recommendation(facts) {
            answer["recommended"] = name(recommended)
            answer["why"] = RemoteAccessGuide.why(recommended)
        }
        if let host = facts.host {
            answer["host"] = host
            answer["connector_url"] = RemoteAccessSettingsText.connectorURL(host: host)
        }
        if kind == .cloudflare || kind == .advanced {
            if let port = inputs.port {
                answer["door_address"] = RemoteAccessTunnelConfig.doorAddress(port: port)
            } else {
                answer["door_address_note"] = "No port is picked yet. Open Settings › Remote Access with this tunnel "
                    + "chosen: it picks the door's port and keeps it. Then ask again for the address to point the tunnel at."
            }
        }
        if kind == .cloudflare {
            answer["cloudflare_checks"] = RemoteAccessSettingsText.cloudflareChecklist(port: inputs.port)
        }
        return answer
    }
}
