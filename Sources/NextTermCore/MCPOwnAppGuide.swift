import Foundation

/// How to get a client ID for a server that doesn't let apps register themselves (no dynamic client registration):
/// the page that makes the OAuth app (filled in where the provider takes that), the few steps there, the callback it
/// holds the app to, whether it wants a secret, and what its client IDs look like, so one copied on that page is
/// recognised. One entry per provider (research_mcp-own-oauth-app-providers_2026-11-21); any other falls back to its
/// sign-in host.
public struct MCPOwnAppGuide: Equatable, Sendable {
    /// The provider's name, as the steps say it.
    public let provider: String
    /// The button's title: "Create a Slack App…".
    public let createTitle: String
    /// The page that makes the app; nil when the provider has none to link to (an admin console inside an org).
    public let createURL: URL?
    /// Whether that page already holds the callback (Slack's manifest): nothing to copy for it.
    public let createHoldsCallback: Bool
    /// The callback the provider holds the app to, filled in for the user; nil when any loopback port works.
    public let fixedCallback: String?
    /// The steps there, in order, one or two short sentences each.
    public let steps: [String]
    /// The client ID field's placeholder.
    public let clientIDExample: String
    /// A provider's client IDs, for recognising one on the clipboard; nil accepts any token-like text.
    let clientIDPattern: String?

    /// The one exact callback Next Term listens at for providers that match the port: a name, not an address, as
    /// Slack's, HubSpot's and Entra's redirect lists take it.
    public static let fixedPortCallback = "http://localhost:47819/callback"

    /// Whether `text` (from the clipboard) looks like a client ID of this provider: one token, no spaces, the provider's
    /// shape when it has one. URLs and sentences are refused.
    public func looksLikeClientID(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...128).contains(token.count), !token.contains("://"),
              token.range(of: #"^[A-Za-z0-9._\-]+$"#, options: .regularExpression) != nil else { return false }
        guard let clientIDPattern else { return true }
        return token.range(of: clientIDPattern, options: .regularExpression) != nil
    }

    /// The guide for a server at `server`, signing in at `issuer` (when discovery found it); `callback` is the one the
    /// user gave, else nil.
    public static func guide(server: String, issuer: String?, callback: String? = nil) -> MCPOwnAppGuide {
        let hosts = [URL(string: server)?.host, issuer.flatMap { URL(string: $0)?.host }].compactMap { $0?.lowercased() }
        func on(_ domains: String...) -> Bool { hosts.contains { host in domains.contains { host == $0 || host.hasSuffix("." + $0) } } }
        let fixed = callback ?? fixedPortCallback
        if on("slack.com") { return slack(callback: fixed) }
        if on("github.com", "githubcopilot.com", "ghe.com") { return github(callback: callback ?? MCPHubOAuthRegistration.redirect) }
        if on("googleapis.com", "accounts.google.com") { return google(callback: callback ?? MCPHubOAuthRegistration.redirect) }
        if on("microsoftonline.com", "dev.azure.com", "dynamics.com", "cloud.microsoft") { return microsoft(callback: fixed) }
        if on("hubspot.com") { return hubspot(callback: fixed) }
        if on("asana.com") { return asana(callback: fixed) }
        if on("box.com") { return box(callback: callback ?? MCPHubOAuthRegistration.redirect) }
        if on("zoom.us") { return zoom(callback: fixed) }
        if on("salesforce.com", "force.com") { return salesforce(callback: fixed) }
        return other(issuer: issuer, server: server, callback: callback ?? MCPHubOAuthRegistration.redirect)
    }

    // MARK: providers

    /// The user scopes Slack's MCP server asks for, tool by tool (docs.slack.dev/ai/slack-mcp-server, OAuth scopes).
    static let slackScopes = [
        "search:read.public", "search:read.private", "search:read.mpim", "search:read.im", "search:read.files",
        "search:read.users", "files:read", "files:write", "emoji:read", "chat:write",
        "channels:history", "groups:history", "mpim:history", "im:history",
        "channels:read", "groups:read", "im:read", "mpim:read", "channels:write", "groups:write", "im:write", "mpim:write",
        "reactions:read", "reactions:write", "canvases:read", "canvases:write", "users:read", "users:read.email",
        "lists:read", "lists:write",
    ]

    /// Slack's create-app page takes a manifest in its URL (docs.slack.dev, Sharing manifests): the app arrives named,
    /// with the callback and the scopes, made in the workspace the user picks, so it is an internal app, which Slack's
    /// MCP server accepts.
    static func slackManifest(callback: String) -> String {
        let manifest: [String: Any] = [
            "display_information": ["name": "Next Term", "description": "Next Term\u{2019}s agents reach Slack through its MCP server."],
            "oauth_config": ["redirect_urls": [callback], "scopes": ["user": slackScopes]],
            "settings": ["org_deploy_enabled": false, "socket_mode_enabled": false, "token_rotation_enabled": false],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func slack(callback: String) -> MCPOwnAppGuide {
        var parts = URLComponents(string: "https://api.slack.com/apps")!
        parts.queryItems = [URLQueryItem(name: "new_app", value: "1"), URLQueryItem(name: "manifest_json", value: slackManifest(callback: callback))]
        return MCPOwnAppGuide(
            provider: "Slack", createTitle: "Create a Slack App\u{2026}", createURL: parts.url, createHoldsCallback: true,
            fixedCallback: callback,
            steps: ["Pick your workspace and create the app: its name, callback and permissions are filled in.",
                    "Under Agents & AI Apps, turn on Model Context Protocol.",
                    "In Basic Information \u{203A} App Credentials, copy the Client ID: it fills in here. Put the Client Secret in Secret."],
            clientIDExample: "1234567890.1234567890", clientIDPattern: #"^[0-9]{6,}\.[0-9]{6,}$"#)
    }

    /// GitHub's OAuth apps take a loopback callback on any port. GitHub Enterprise Cloud (ghe.com) works the same way,
    /// in the enterprise's own settings.
    static func github(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "GitHub", createTitle: "Create a GitHub OAuth App\u{2026}",
            createURL: URL(string: "https://github.com/settings/applications/new"), createHoldsCallback: false, fixedCallback: nil,
            steps: ["Name it Next Term, give any homepage, and paste \(callback) (it\u{2019}s on the clipboard) as its Authorization callback URL: GitHub takes it on any port.",
                    "Register it, then copy the Client ID: it fills in here.",
                    "To use a secret, generate one and put it in Secret."],
            // OAuth apps: Ov23li… now, 20 hex digits before; GitHub Apps: Iv1.… or Iv23li….
            clientIDExample: "Ov23li\u{2026}", clientIDPattern: #"^(Ov23[A-Za-z0-9]{12,}|Iv23[A-Za-z0-9]{12,}|Iv1\.[0-9a-f]{16}|[0-9a-f]{20})$"#)
    }

    /// Google's MCP servers (Cloud and Workspace) neither register clients nor read client metadata documents. A Desktop
    /// app client takes a loopback callback on any port.
    static func google(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Google", createTitle: "Create a Google OAuth Client\u{2026}",
            createURL: URL(string: "https://console.cloud.google.com/auth/clients/create"), createHoldsCallback: false, fixedCallback: nil,
            steps: ["Choose Desktop app and name it Next Term (if asked, set up Branding and Audience first, and add yourself as a test user).",
                    "For Gmail, Drive or Calendar, enable their MCP APIs in the project.",
                    "Copy the Client ID: it fills in here. Put the Client secret in Secret."],
            clientIDExample: "123456789012-abc\u{2026}.apps.googleusercontent.com",
            clientIDPattern: #"^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$"#)
    }

    /// Entra (Azure DevOps, Dataverse, Microsoft 365's MCP servers) has no client registration; a public client with
    /// PKCE needs no secret, and Entra ignores the port of a localhost callback.
    static func microsoft(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Microsoft Entra", createTitle: "Open Microsoft Entra\u{2026}",
            createURL: URL(string: "https://entra.microsoft.com"), createHoldsCallback: false, fixedCallback: callback,
            steps: ["In App registrations \u{203A} New registration, name it Next Term and add a Mobile and desktop applications redirect: \(callback) (it\u{2019}s on the clipboard).",
                    "Turn on Allow public client flows, and add the server\u{2019}s API permission (an admin may need to grant it).",
                    "Copy the Application (client) ID: it fills in here. No secret is needed."],
            clientIDExample: "00000000-0000-0000-0000-000000000000",
            clientIDPattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
    }

    static func hubspot(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "HubSpot", createTitle: "Create a HubSpot MCP Connector\u{2026}",
            createURL: URL(string: "https://app.hubspot.com/l/mcp-auth-apps/"), createHoldsCallback: false, fixedCallback: callback,
            steps: ["Create an MCP connector named Next Term with the redirect URL \(callback) (it\u{2019}s on the clipboard).",
                    "Copy its Client ID: it fills in here.",
                    "Put its Client secret in Secret: HubSpot needs one."],
            clientIDExample: "Client ID", clientIDPattern: nil)
    }

    static func asana(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Asana", createTitle: "Create an Asana MCP App\u{2026}",
            createURL: URL(string: "https://app.asana.com/0/my-apps"), createHoldsCallback: false, fixedCallback: callback,
            steps: ["Create an app of type MCP app named Next Term, with the redirect URL \(callback) (it\u{2019}s on the clipboard).",
                    "Copy its Client ID: it fills in here.",
                    "Put its Client secret in Secret: Asana needs one."],
            clientIDExample: "1234567890123456", clientIDPattern: #"^[0-9]{9,20}$"#)
    }

    /// Box's MCP server credentials are made by an admin in the Admin Console, which has no page to link to.
    static func box(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Box", createTitle: "Open Box\u{2026}", createURL: nil, createHoldsCallback: false, fixedCallback: nil,
            steps: ["A Box admin opens Admin Console \u{203A} Integrations \u{203A} Custom Box MCP Server \u{203A} Add Integration Credentials.",
                    "Give the redirect URL \(callback), with Manage AI selected.",
                    "Paste its Client ID here, and its Client secret in Secret."],
            clientIDExample: "Client ID", clientIDPattern: nil)
    }

    static func zoom(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Zoom", createTitle: "Open the Zoom App Marketplace\u{2026}",
            createURL: URL(string: "https://marketplace.zoom.us/"), createHoldsCallback: false, fixedCallback: callback,
            steps: ["In Develop \u{203A} Build App, make a General app named Next Term with the redirect URL \(callback) (it\u{2019}s on the clipboard), and add the scopes of the tools you use.",
                    "Copy its Client ID: it fills in here.",
                    "Put its Client secret in Secret."],
            clientIDExample: "Client ID", clientIDPattern: nil)
    }

    /// Salesforce wants an External Client App made in the org's Setup; PKCE, no secret. It can take a while to work.
    static func salesforce(callback: String) -> MCPOwnAppGuide {
        MCPOwnAppGuide(
            provider: "Salesforce", createTitle: "Open Salesforce\u{2026}", createURL: nil, createHoldsCallback: false, fixedCallback: callback,
            steps: ["In Setup \u{203A} External Client App Manager, make a new app with the callback \(callback), the mcp_api and refresh_token scopes, PKCE, and JWT-based access tokens for named users.",
                    "Turn the servers on in Setup \u{203A} MCP Servers. A new app can take up to 30 minutes to work.",
                    "Paste its Consumer Key here. No secret is needed."],
            clientIDExample: "3MVG\u{2026}", clientIDPattern: nil)
    }

    static func other(issuer: String?, server: String, callback: String) -> MCPOwnAppGuide {
        let site = [issuer, server].lazy.compactMap { $0.flatMap(URL.init(string:)) }
            .first { $0.scheme == "https" && $0.host != nil }
            .flatMap { url -> URL? in
                var parts = URLComponents()
                parts.scheme = "https"
                parts.host = url.host
                return parts.url
            }
        let name = site?.host ?? "the provider"
        return MCPOwnAppGuide(
            provider: name, createTitle: "Open \(name)\u{2026}", createURL: site, createHoldsCallback: false, fixedCallback: nil,
            steps: ["Create an OAuth app in its developer settings.",
                    "Paste \(callback) (it\u{2019}s on the clipboard) as its redirect URL. If it holds the callback to one port, give that exact URL in Callback here.",
                    "Copy its Client ID: it fills in here. A client secret, if it has one, goes in Secret."],
            clientIDExample: "Client ID", clientIDPattern: nil)
    }
}
