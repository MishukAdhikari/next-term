import Foundation
import Testing
@testable import NextTermCore

@Suite struct RemoteAccessGuideAnswerTests {
    @Test func namesGoBothWays() {
        for kind in RemoteAccessTunnelConfig.Kind.allCases {
            #expect(RemoteAccessGuideAnswer.kind(named: RemoteAccessGuideAnswer.name(kind)) == kind)
        }
        #expect(RemoteAccessGuideAnswer.kind(named: "ownServer") == nil)
    }

    @Test func nothingReadyGuidesCloudflareAndAsksForAPort() {
        let answer = RemoteAccessGuideAnswer.answer(asked: nil, .init())
        #expect(answer["guide_for"] as? String == "cloudflare")
        #expect(answer["recommended"] == nil)
        #expect(answer["current_step"] as? Int == 1)
        #expect(answer["door_address"] == nil)
        #expect(answer["door_address_note"] is String)
        #expect((answer["cloudflare_checks"] as? [String])?.isEmpty == false)
        #expect(answer["can_turn_on"] as? Bool == false)
        let security = answer["security"] as? [[String: Any]] ?? []
        #expect(security.first?["id"] as? String == "master-key")
        #expect(security.first?["state"] as? String == "suggested")
        #expect(answer["users_part"] is String)
    }

    @Test func aReadyFunnelIsRecommendedAndGuided() {
        var inputs = RemoteAccessGuideAnswer.Inputs()
        inputs.facts.tailscale = .installed
        inputs.facts.tailscaleStatus = .success("mac")
        let answer = RemoteAccessGuideAnswer.answer(asked: nil, inputs)
        #expect(answer["recommended"] as? String == "funnel")
        #expect(answer["guide_for"] as? String == "funnel")
        #expect(answer["current_step"] as? Int == 4)
        #expect(answer["cloudflare_checks"] == nil)
        let tunnels = answer["tunnels"] as? [[String: Any]] ?? []
        #expect(tunnels.count == 4)
        #expect(tunnels.first { $0["tunnel"] as? String == "funnel" }?["ready"] as? Bool == true)
    }

    @Test func theAskedTunnelWinsAndAPortGivesTheAddress() {
        var inputs = RemoteAccessGuideAnswer.Inputs()
        inputs.saved = .funnel
        inputs.port = 41873
        inputs.facts.host = "mcp.example.com"
        inputs.security.masterKeySet = true
        let answer = RemoteAccessGuideAnswer.answer(asked: .cloudflare, inputs)
        #expect(answer["guide_for"] as? String == "cloudflare")
        #expect(answer["tunnel"] as? String == "funnel")
        #expect(answer["door_address"] as? String == "http://127.0.0.1:41873")
        #expect(answer["connector_url"] as? String == "https://mcp.example.com/mcp")
        #expect(answer["can_turn_on"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(answer))
    }
}
