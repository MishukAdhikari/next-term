import Foundation
import Testing
@testable import NextTermCore

@Suite struct MCPOwnAppGuideTests {
    let slackCallback = "http://localhost:47819/callback"

    @Test func slacksPageArrivesWithTheCallbackAndScopes() throws {
        let guide = MCPOwnAppGuide.guide(server: "https://mcp.slack.com/mcp", issuer: "https://slack.com", callback: slackCallback)
        #expect(guide.provider == "Slack" && guide.createHoldsCallback)
        let url = try #require(guide.createURL)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "api.slack.com" && parts.path == "/apps")
        #expect(parts.queryItems?.first { $0.name == "new_app" }?.value == "1")
        let json = try #require(parts.queryItems?.first { $0.name == "manifest_json" }?.value)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let oauth = try #require(manifest["oauth_config"] as? [String: Any])
        #expect(oauth["redirect_urls"] as? [String] == [slackCallback])
        let scopes = try #require((oauth["scopes"] as? [String: Any])?["user"] as? [String])
        #expect(scopes.contains("search:read.public") && scopes.contains("chat:write") && Set(scopes).count == scopes.count)
        // The query is encoded: its JSON's quotes and braces never reach the URL as they are.
        #expect(!url.absoluteString.contains("\"") && !url.absoluteString.contains("{"))
    }

    @Test func slacksClientIDsAreTwoNumbers() {
        let guide = MCPOwnAppGuide.guide(server: "https://mcp.slack.com/mcp", issuer: nil, callback: slackCallback)
        #expect(guide.looksLikeClientID("3660753192626.8903469228982"))
        #expect(guide.looksLikeClientID("  3660753192626.8903469228982\n"))
        for not in ["3660753192626", "abcdef.123456", "xoxb-123-456", slackCallback, "a secret with spaces"] {
            #expect(!guide.looksLikeClientID(not), "\(not)")
        }
    }

    @Test func githubOpensItsNewOAuthAppPage() {
        let guide = MCPOwnAppGuide.guide(server: "https://api.githubcopilot.com/mcp/", issuer: "https://github.com/login/oauth", callback: "http://127.0.0.1/callback")
        #expect(guide.provider == "GitHub" && !guide.createHoldsCallback)
        #expect(guide.createURL?.absoluteString == "https://github.com/settings/applications/new")
        #expect(guide.looksLikeClientID("Ov23liAbCdEf0123456789"))
        #expect(guide.looksLikeClientID("Iv1.0123456789abcdef"))
        #expect(guide.looksLikeClientID("0123456789abcdef0123"))
        #expect(!guide.looksLikeClientID("ghp_0123456789abcdefABCDEF0123456789"))
        #expect(!guide.looksLikeClientID("1234567890.1234567890"))
    }

    @Test func providersThatHoldThePortGetNextTermsFixedCallback() {
        let fixed = MCPOwnAppGuide.fixedPortCallback
        for (server, issuer, provider) in [("https://mcp.slack.com/mcp", nil, "Slack"),
                                           ("https://mcp.hubspot.com/", nil, "HubSpot"),
                                           ("https://mcp.asana.com/v2/mcp", nil, "Asana"),
                                           ("https://mcp.zoom.us/mcp/zoom/streamable", nil, "Zoom"),
                                           ("https://api.salesforce.com/platform/mcp/v1/x", "https://login.salesforce.com", "Salesforce"),
                                           ("https://mcp.dev.azure.com/org", "https://login.microsoftonline.com/common/v2.0", "Microsoft Entra")] as [(String, String?, String)] {
            let guide = MCPOwnAppGuide.guide(server: server, issuer: issuer)
            #expect(guide.provider == provider && guide.fixedCallback == fixed, "\(server)")
            #expect(guide.steps.count == 3 && guide.steps.joined().contains(fixed) || guide.createHoldsCallback, "\(server)")
        }
        // A callback the user typed is the one the steps and the manifest say.
        #expect(MCPOwnAppGuide.guide(server: "https://mcp.hubspot.com/", issuer: nil, callback: "http://localhost:5000/cb").fixedCallback == "http://localhost:5000/cb")
        // Any port: no fixed callback, Next Term's own in the steps (Google's Desktop app client has no callback to give).
        #expect(MCPOwnAppGuide.guide(server: "https://gmailmcp.googleapis.com/mcp/v1", issuer: nil).fixedCallback == nil)
        for server in ["https://api.githubcopilot.com/mcp/", "https://mcp.box.com"] {
            let guide = MCPOwnAppGuide.guide(server: server, issuer: nil)
            #expect(guide.fixedCallback == nil && guide.steps.joined().contains(MCPHubOAuthRegistration.redirect), "\(server)")
        }
    }

    @Test func googleAndMicrosoftIDsAreRecognised() {
        let google = MCPOwnAppGuide.guide(server: "https://bigquery.googleapis.com/mcp", issuer: "https://accounts.google.com")
        #expect(google.provider == "Google" && google.createURL?.host == "console.cloud.google.com")
        #expect(google.looksLikeClientID("123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"))
        #expect(!google.looksLikeClientID("GOCSPX-abcdefghijklmnop"))
        let entra = MCPOwnAppGuide.guide(server: "https://contoso.crm.dynamics.com/api/mcp", issuer: nil)
        #expect(entra.provider == "Microsoft Entra" && entra.looksLikeClientID("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"))
        #expect(!entra.looksLikeClientID("0f1e2d3c4b5a69788796a5b4c3d2e1f0"))
        let asana = MCPOwnAppGuide.guide(server: "https://mcp.asana.com/v2/mcp", issuer: nil)
        #expect(asana.looksLikeClientID("1209876543210987") && !asana.looksLikeClientID("abc123def456"))
        // Admin-console providers have no page to link to.
        #expect(MCPOwnAppGuide.guide(server: "https://mcp.box.com", issuer: nil).createURL == nil)
    }

    @Test func anyOtherOpensItsSignInHostAndTakesATokenLikeID() {
        let guide = MCPOwnAppGuide.guide(server: "https://mcp.example.com/mcp", issuer: "https://auth.example.com/oauth", callback: "http://127.0.0.1/callback")
        #expect(guide.createURL?.absoluteString == "https://auth.example.com" && guide.createTitle == "Open auth.example.com\u{2026}")
        #expect(guide.looksLikeClientID("my-client_ID.42"))
        #expect(!guide.looksLikeClientID("two words") && !guide.looksLikeClientID("https://auth.example.com") && !guide.looksLikeClientID("abc"))
        // No https anywhere: no page to open.
        #expect(MCPOwnAppGuide.guide(server: "http://localhost:8080/mcp", issuer: nil, callback: "x").createURL == nil)
    }
}
