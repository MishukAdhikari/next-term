import Foundation
import Testing
@testable import NextTermCore

struct RemoteAccessChecklistTests {
    @Test func onlyTheMasterKeyIsRequired() {
        var facts = RemoteAccessChecklist.Facts()
        #expect(!RemoteAccessChecklist.canTurnOn(facts))
        facts.masterKeySet = true
        #expect(RemoteAccessChecklist.canTurnOn(facts))
        let required = RemoteAccessChecklist.rows(facts).filter(\.required).map(\.id)
        #expect(required == ["master-key"])
    }

    @Test func rowsReadTheirFacts() {
        var facts = RemoteAccessChecklist.Facts()
        facts.masterKeySet = true
        facts.tunnel = .funnel
        facts.fileVaultOn = false
        facts.controlWithoutAsking = 2
        let rows = Dictionary(uniqueKeysWithValues: RemoteAccessChecklist.rows(facts).map { ($0.id, $0) })
        #expect(rows["own-domain"]?.state == .suggested && rows["own-domain"]?.action == .chooseTunnel)
        #expect(rows["filevault"]?.state == .suggested)
        #expect(rows["firewall"]?.state == .notChecked)
        #expect(rows["control-asks"]?.detail == "2 connections can change things without asking.")
        #expect(rows["edge-rule"]?.action == RemoteAccessChecklist.Action.none) // no hostname yet
        #expect(rows["cloudflared"] == nil)
        facts.tunnel = .cloudflare
        facts.host = "mac.example.com"
        facts.cloudflaredCurrent = true
        let named = Dictionary(uniqueKeysWithValues: RemoteAccessChecklist.rows(facts).map { ($0.id, $0) })
        #expect(named["own-domain"]?.state == .done && named["edge-rule"]?.action == .copyEdgeRule)
        #expect(named["cloudflared"]?.state == .done)
    }

    @Test func theEdgeRuleGuardsOnlyTheToolAndTokenEndpoints() {
        let rule = RemoteAccessChecklist.edgeRule(host: "mac.example.com")
        #expect(rule.contains("http.host eq \"mac.example.com\""))
        #expect(rule.contains("\"/mcp\"") && rule.contains("\"/token\"") && !rule.contains("/authorize"))
        #expect(rule.contains("160.79.104.0/21 153.61.208.0/20") && rule.contains("$chatgpt_connectors"))
    }

    @Test func systemAnswersAreRead() {
        #expect(RemoteAccessChecklist.fileVault(fromStatus: "FileVault is On.\n") == true)
        #expect(RemoteAccessChecklist.fileVault(fromStatus: "FileVault is Off.\n") == false)
        #expect(RemoteAccessChecklist.fileVault(fromStatus: "") == nil)
        #expect(RemoteAccessChecklist.firewall(fromState: "Firewall is enabled. (State = 1)") == true)
        #expect(RemoteAccessChecklist.firewall(fromState: "Firewall is disabled. (State = 0)") == false)
        let json = Data(#"{"prefixes": [{"ipv4Prefix": "1.2.3.0/24"}, {"ipv6Prefix": "2001:db8::/32"}]}"#.utf8)
        #expect(RemoteAccessChecklist.openAIPrefixes(fromJSON: json) == ["1.2.3.0/24", "2001:db8::/32"])
    }
}
