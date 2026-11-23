import AppKit
import NextTermCore

/// MCP's `remote_access_guide`: Settings › Remote Access's guide read from this Mac (RemoteAccessGuideAnswer). The
/// tools are looked for off the main thread, as Settings does; the rest is read on it. Nothing is saved or turned on.
@MainActor
enum RemoteAccessGuideMCP {
    static func call(_ arguments: [String: Any], reply: @escaping @Sendable (MCPServer.CallResult) -> Void) {
        var asked: RemoteAccessGuideAnswer.Kind?
        if let name = arguments["tunnel"] as? String {
            guard let kind = RemoteAccessGuideAnswer.kind(named: name) else {
                reply(MCPControl.fail("tunnel is one of funnel, cloudflare, own_server or advanced."))
                return
            }
            asked = kind
        }
        RemoteAccessTunnel.detect { detection in
            reply(MCPControl.ok(RemoteAccessGuideAnswer.answer(asked: asked, inputs(detection))))
        }
    }

    static func inputs(_ detection: RemoteAccessTunnel.Detection) -> RemoteAccessGuideAnswer.Inputs {
        let access = RemoteAccess.shared
        var inputs = RemoteAccessGuideAnswer.Inputs()
        var facts = RemoteAccessGuide.Facts()
        facts.tailscale = detection.tailscale == nil ? .missing : .installed
        facts.tailscaleStatus = detection.tailscaleStatus
        if let found = detection.cloudflared { facts.cloudflared = found.tooOld ? .tooOld : .installed }
        facts.tokenSaved = access.savedTunnelID != nil
        let hosts = RemoteHosts.all
        facts.servers = hosts.count
        facts.serverChosen = hosts.contains { $0.id == access.settings.server }
        facts.host = access.settings.host
        facts.on = access.status.phase == .on
        inputs.facts = facts
        inputs.saved = access.settings.tunnel
        inputs.status = RemoteAccessIndicator(access.status.phase).word
        inputs.port = access.settings.port.map(Int.init)
        var security = RemoteAccessChecklist.Facts()
        security.masterKeySet = MasterKeyGate.isSet
        security.tunnel = access.settings.tunnel
        security.host = access.settings.host
        security.controlWithoutAsking = access.connectionRows().filter { !$0.options[.askOnMac] }.count
        security.fileVaultOn = RemoteAccessSecuritySection.lastSystemFacts?.fileVault
        security.firewallOn = RemoteAccessSecuritySection.lastSystemFacts?.firewall
        inputs.security = security
        return inputs
    }
}
