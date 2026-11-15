#if DEBUG
import AppKit
import NextTermCore

/// The MCP hub's sign-ins (OAuth, R14 and R15), run only when asked for (NEXTTERM_SELFTEST_ONLY=mcpHubOAuth): a fake
/// authorization server and resource server on this Mac (MCPHubFakeAuth, MCPHubFakeRemote), the self-test's own vault
/// (a software keyring in a temporary folder) and its stand-in presence check, and the self-test's own list. The
/// "browser" is the self-test fetching the authorization URL, as a browser would, with no UI. Never the user's
/// ~/.claude, ~/.codex, prefs, Application Support or Keychain.
///
/// Add by URL offers Sign In… as its one primary; the sign-in completes; a Claude Code tab and a Codex tab each get one
/// consent panel, then call `echo`; with tokens living two seconds, two tabs calling at once make one refresh; revoked
/// at the server, the row reads Signed out, with Reconnect…, one notice is recorded, and the agent's text says to
/// reconnect; Remove revokes once. Then the user's own OAuth app at a server set up as GitHub's (ownAppChecks).
/// Screenshots: the Add sheet's Sign In…, the consent panel, each state in Settings, Settings opened from the Reconnect
/// notice, and the Add sheet's own-app rows.
extension SelfTest {
    static func mcpHubOAuthChecks(_ c: TerminalWindowController) async {
        let manager = FileManager.default
        let dir = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-mcphub-oauth-\(getpid())")
        let folder = dir.appendingPathComponent("app")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let userFile = dir.appendingPathComponent("hub/mcp.json").path
        guard let auth = try? MCPHubFakeAuth(), let remote = try? MCPHubFakeRemote() else {
            return check(false, "MCP OAuth: the fake authorization and resource servers listen on this Mac")
        }
        remote.auth = auth
        auth.resource = remote.url.absoluteString
        auth.accessLife = 2 // the access tokens expire at once, so the needs below refresh
        let savedFile = MCPHubControl.userFile, savedProjects = MCPServersSettingsView.projectsForTest
        MCPHubControl.userFile = userFile
        MCPServersSettingsView.projectsForTest = [folder.path]
        var agent = "claude"
        MCPHubSignIns.agentForTest = { _ in agent }
        MCPHubSignIns.openForTest = { url in
            MCPHubFakeAuth.signInSoon(url)
            return true
        }
        let view = MCPServersSettingsView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentView = view
        window.center()
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            auth.stop()
            remote.stop()
            MCPHubControl.userFile = savedFile
            MCPServersSettingsView.projectsForTest = savedProjects
            MCPHubSignIns.agentForTest = nil
            MCPHubSignIns.openForTest = nil
            try? manager.removeItem(at: dir)
        }
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                    "clientInfo": ["name": "self-test", "version": "1"]]]
        let echo: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": "mcp_call", "arguments": ["server": "linear", "tool": "echo"]]]
        func call(_ name: String) async -> String {
            resultText(await bridgeInTab(c, folder: folder, requests: [initialize, echo], name: name, userFile: userFile)[2])
        }
        func state() -> MCPHubOverview.State? { view.rows.first { $0.name == "linear" }?.state }

        // Add Server… by URL: the server asks for a sign-in, so Sign In… is the one primary, and "Use a key instead" is there.
        view.show(0)
        view.add()
        guard let add = view.sheet as? MCPServerSheet, let addWindow = add.window else { return check(false, "MCP OAuth: Add opens its sheet") }
        add.nameField.stringValue = "linear"
        add.kind.selectedSegment = 1
        add.runsField.stringValue = remote.url.absoluteString
        add.refresh()
        _ = await wait(10) { add.offersSignIn }
        check(add.offersSignIn && add.addButton.title == "Sign In\u{2026}" && add.addButton.keyEquivalent == "\r" && !add.keyInsteadButton.isHidden,
              "MCP OAuth: a URL that asks for a sign-in makes Sign In\u{2026} the Add sheet\u{2019}s one primary", add.signInLine.stringValue)
        await screenshot(addWindow, suffix: "-mcp-oauth-add-sign-in")
        add.confirm()
        _ = await wait(20) { view.sheet == nil && view.rows.contains { $0.name == "linear" } }
        view.reload()
        check(state() == .signedIn(tools: nil) && auth.count("/register") == 1 && auth.count("/authorize") == 1,
              "MCP OAuth: the sign-in completes in the browser, and the server is added signed in", "\(String(describing: state()))")
        if let row = view.rows.firstIndex(where: { $0.name == "linear" }) {
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        check(view.signInButton.title == "Sign Out" && !view.signInButton.isHidden, "MCP OAuth: a signed-in server offers Sign Out")
        await screenshot(window, suffix: "-mcp-oauth-signed-in")

        // R15: a Claude Code tab and a Codex tab each get one panel, Allow its one primary; then each calls echo.
        for kind in ["claude", "codex"] {
            agent = kind
            let approver = Task { @MainActor in
                guard await wait(20, { !MCPHubSignIns.panels.isEmpty }), let panel = MCPHubSignIns.panels.values.first, let panelWindow = panel.window else { return }
                if kind == "codex" { await screenshot(panelWindow, suffix: "-mcp-oauth-consent") }
                panel.approveButton.performClick(nil)
            }
            let said = await call("oauth-\(kind)")
            await approver.value
            check(said == "hello from remote", "MCP OAuth: \(MCPHubSignInWords.agentTitle(kind)) asks once, then reaches the server signed in", said)
        }
        let consents = MCPHubSignIns.record(for: remote.url.absoluteString)?.consents ?? []
        check(consents == ["claude", "codex"], "MCP OAuth: each agent\u{2019}s consent is kept in the sealed sign-ins", "\(consents)")
        let asked = auth.count("/authorize")
        _ = await call("oauth-again")
        check(MCPHubSignIns.panels.isEmpty && auth.count("/authorize") == asked, "MCP OAuth: an agent allowed once isn\u{2019}t asked again")

        // The access token has expired (two seconds): two tabs calling at once share one refresh, whose token lasts.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        auth.accessLife = 3600
        let before = auth.count("/token")
        let first = Task { @MainActor in await call("oauth-a") }
        let second = Task { @MainActor in await call("oauth-b") }
        let both = [await first.value, await second.value]
        check(both.allSatisfy { $0 == "hello from remote" } && auth.count("/token") == before + 1,
              "MCP OAuth: two agents calling at once make one refresh", "\(auth.count("/token") - before) refreshes")

        // Revoked at the server: Signed out, one notice, and the agent is told to have the user reconnect.
        auth.revokeAll()
        let notices = AppDelegate.shared.testNotifications.count
        let lapsed = await call("oauth-lapsed")
        _ = await call("oauth-lapsed-again")
        view.reload()
        let signInNotices = AppDelegate.shared.testNotifications.dropFirst(notices).filter { $0.identifier.hasPrefix("mcp-sign-in-") }
        // The bar in the agent's window says it; a notice only when no window in front shows that bar.
        let barInFront = MCPConnectorPrompts.showing(url: remote.url.absoluteString)
        let expected = NotificationSettings(defaults: .standard).programAlerts && !barInFront ? 1 : 0
        check(c.connector.isShowing && c.connector.bar.shown?.message.hasPrefix("linear signed out") == true
              && c.connector.bar.shown?.primary == "Reconnect",
              "MCP connector: a lapse an agent met puts Reconnect in a bar at the foot of its window", c.connector.bar.shown?.message ?? "no bar")
        if let barWindow = c.window { await screenshot(barWindow, suffix: "-mcp-connector-reconnect") }
        check(lapsed == MCPHubSignInWords.lapsed("linear") && state() == .signedOut && signInNotices.count == expected
              && (signInNotices.first.map { $0.content.title == MCPHubSignInWords.notice("linear").title } ?? true),
              "MCP OAuth: a revoked sign-in reads Signed out, with one notice, and the agent is told to reconnect",
              "\(lapsed) | \(String(describing: state())) | \(signInNotices.count) notices")
        if let row = view.rows.firstIndex(where: { $0.name == "linear" }) {
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        check(view.signInButton.title == "Reconnect\u{2026}" && !view.signInButton.isHidden && view.agentsButton.isHidden,
              "MCP OAuth: a lapsed sign-in offers Reconnect\u{2026} alone, with no Change\u{2026} beside the lapse")
        await screenshot(window, suffix: "-mcp-oauth-signed-out")
        // The notice, clicked: Settings › MCP Servers with the server selected, Reconnect… beside it.
        MCPHubSignIns.openReconnect(remote.url.absoluteString)
        let settings = AppDelegate.shared.showsMCPServersForTest
        check(settings?.selected?.name == "linear" && settings?.signInButton.title == "Reconnect\u{2026}",
              "MCP OAuth: the Reconnect notice opens Settings on the server, with Reconnect\u{2026}")
        if let settingsWindow = settings?.window { await screenshot(settingsWindow, suffix: "-mcp-oauth-reconnect-notice") }
        settings?.window?.orderOut(nil)

        // Reconnect…, then Remove: the sign-in is revoked at the server once.
        if let row = view.rows.firstIndex(where: { $0.name == "linear" }) {
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            view.signInOrOut()
            _ = await wait(20) { state() == .signedIn(tools: nil) || { view.reload(); return state() == .signedIn(tools: nil) }() }
            check(state() == .signedIn(tools: nil), "MCP OAuth: Reconnect\u{2026} signs in again", "\(String(describing: state()))")
            await connectorChecks(c, auth: auth, url: remote.url.absoluteString, call: call)
            view.reload()
            let revoked = auth.count("/revoke")
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            view.remove()
            _ = await wait(15) { auth.count("/revoke") > revoked }
            check(auth.count("/revoke") == revoked + 1 && MCPHubSignIns.record(for: remote.url.absoluteString) == nil
                  && SecretsStore.shared.held?.signIns == nil,
                  "MCP OAuth: Remove revokes the sign-in once, and the last one takes the vault\u{2019}s key with it")
        }
        check((SecretsStore.shared.index?.names ?? []).allSatisfy { $0 != SecretVault.signInsName },
              "MCP OAuth: the sign-ins\u{2019} key is never listed in Secrets")

        await ownAppChecks(view: view, window: window, userFile: userFile)
    }

    /// The connector bar (MCPConnectorPrompt): mended in Settings, it says "connected" and goes; its own Reconnect signs
    /// in from the window, the browser's progress in it; Not Now holds it while the agent keeps meeting the lapse; it
    /// never takes the keyboard. Screenshots: connected, and the browser's progress.
    @MainActor
    static func connectorChecks(_ c: TerminalWindowController, auth: MCPHubFakeAuth, url: String, call: (String) async -> String) async {
        let saved = MCPConnectorPrompt.connectedFor
        MCPConnectorPrompt.connectedFor = 1.5
        defer { MCPConnectorPrompt.connectedFor = saved }
        let bar = c.connector.bar
        // Settings' Reconnect… mended it: "connected", then gone.
        _ = await wait(5) { bar.shown?.glyph == .done }
        check(bar.shown?.message == "linear is connected. Your agents can use it now." && c.connector.items.isEmpty,
              "MCP connector: a reconnect in Settings turns the bar to \u{201C}connected\u{201D}", bar.shown?.message ?? "no bar")
        if let window = c.window { await screenshot(window, suffix: "-mcp-connector-connected") }
        check(await wait(5) { bar.isHidden && bar.shown == nil }, "MCP connector: \u{201C}connected\u{201D} goes by itself")

        // Its own Reconnect: the sign-in from the bar, and the agent's next call goes through.
        auth.revokeAll()
        _ = await call("connector-lapse")
        check(bar.shown?.primary == "Reconnect" && bar.buttonsForTest == ["MCP Servers\u{2026}", "Not Now", "Reconnect"],
              "MCP connector: the bar offers Reconnect as its one primary, with MCP Servers\u{2026} and Not Now", "\(bar.buttonsForTest)")
        let responder = c.window?.firstResponder as? NSView
        check(bar.primaryKeyForTest.isEmpty && !(responder.map { $0.isDescendant(of: bar) } ?? false),
              "MCP connector: the bar takes no keyboard; Return stays the terminal\u{2019}s")
        let authorized = auth.count("/authorize")
        bar.pressForTest("Reconnect")
        check(bar.shown?.glyph == .working || bar.shown?.glyph == .done || auth.count("/authorize") > authorized,
              "MCP connector: Reconnect shows the browser\u{2019}s progress in the bar", bar.shown?.message ?? "")
        if bar.shown?.glyph == .working, let window = c.window { await screenshot(window, suffix: "-mcp-connector-browser") }
        _ = await wait(20) { bar.shown?.glyph == .done }
        let said = await call("connector-after")
        check(bar.shown?.glyph == .done && said == "hello from remote" && auth.count("/authorize") == authorized + 1,
              "MCP connector: the bar\u{2019}s Reconnect signs in, and the agent\u{2019}s same call works with no restart", said)
        _ = await wait(5) { bar.isHidden }

        // Not Now holds it, however often the agent meets the lapse.
        auth.revokeAll()
        _ = await call("connector-held")
        check(c.connector.isShowing, "MCP connector: a new lapse shows the bar again")
        bar.pressForTest("Not Now")
        _ = await call("connector-held-again")
        check(await wait(2) { bar.isHidden } && !c.connector.isShowing, "MCP connector: Not Now holds the bar while the server needs the same")
        // Signed in again for what follows.
        let back = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            guard let server = MCPHubSignIns.record(for: url).flatMap({ _ in hubServer(named: "linear") }) else { return done.resume(returning: false) }
            MCPHubSignIns.signIn(server, progress: { _ in }, done: { done.resume(returning: $0 == nil) })
        }
        check(back, "MCP connector: signed in again after Not Now")
    }

    /// The self-test list's server by name.
    @MainActor
    static func hubServer(named name: String) -> MCPHubServer? {
        let file = MCPHubControl.userFile ?? MCPHubScope.userPath()
        return MCPHubScope.servers(folder: NSHomeDirectory(), userFile: file).servers.first { $0.name == name }?.server
    }

    /// The user's own OAuth app, for a server set up as GitHub's is: no registration, no client metadata documents, and
    /// a token endpoint that refuses a code without the app's secret. The Add sheet opens the own-app rows by itself;
    /// the secret given there goes into Secrets, the list names it, and Sign In… reads it once, when the code is
    /// exchanged, sending it to the token endpoint alone. Screenshot: the sheet's own-app rows.
    @MainActor
    static func ownAppChecks(view: MCPServersSettingsView, window: NSWindow, userFile: String) async {
        let secretValue = "selftest-client-secret-\(UUID().uuidString.prefix(8))"
        guard let auth = try? MCPHubFakeAuth(), let remote = try? MCPHubFakeRemote() else {
            return check(false, "MCP OAuth, own app: the fake servers listen on this Mac")
        }
        defer {
            auth.stop()
            remote.stop()
        }
        auth.dcr = false
        auth.cimd = false
        auth.pathIssuer = true
        auth.ownApp = ("Ov23liSELFTEST", secretValue)
        remote.auth = auth
        auth.resource = remote.url.absoluteString
        func state() -> MCPHubOverview.State? { view.rows.first { $0.name == "github" }?.state }

        view.add()
        guard let add = view.sheet as? MCPServerSheet, let addWindow = add.window else { return check(false, "MCP OAuth, own app: Add opens its sheet") }
        add.nameField.stringValue = "github"
        add.kind.selectedSegment = 1
        add.runsField.stringValue = remote.url.absoluteString
        add.refresh()
        _ = await wait(15) { add.cantRegister }
        check(add.cantRegister && add.usesOwnApp && add.offersSignIn && !add.clientIDField.isHidden && !add.addButton.isEnabled,
              "MCP OAuth, own app: a server that can\u{2019}t register Next Term opens the own-app rows, and Sign In\u{2026} waits for a client ID",
              add.signInLine.stringValue)
        add.clientIDField.stringValue = "Ov23liSELFTEST"
        add.secretPopUp.selectItem(withTitle: MCPServerSheet.newKey)
        add.newSecretName.stringValue = "SELFTEST_OAUTH_CLIENT_SECRET"
        add.newSecretValue.stringValue = secretValue
        add.refresh()
        check(add.addButton.isEnabled && add.addButton.title == "Sign In\u{2026}" && add.ownAppHelp.stringValue.contains(MCPHubOAuthRegistration.redirect),
              "MCP OAuth, own app: with a client ID and a secret, Sign In\u{2026} is the one primary, and the callback URL is said",
              add.ownAppHelp.stringValue)
        await screenshot(addWindow, suffix: "-mcp-oauth-own-app")
        add.confirm()
        _ = await wait(30) { view.sheet == nil && view.rows.contains { $0.name == "github" } }
        view.reload()
        let list = (try? String(contentsOfFile: userFile, encoding: .utf8)) ?? ""
        check(state() == .signedIn(tools: nil) && auth.count("/register") == 0 && auth.secretSeen == ["/token"],
              "MCP OAuth, own app: the sign-in completes as the user\u{2019}s app, the secret sent to the token endpoint alone",
              "\(String(describing: state())) | \(auth.secretSeen)")
        check(list.contains("\"clientID\": \"Ov23liSELFTEST\"") && list.contains("${secret:SELFTEST_OAUTH_CLIENT_SECRET}") && !list.contains(secretValue),
              "MCP OAuth, own app: the list keeps the client ID and names the secret, never its value")
        let sealed = (try? MCPHubSignIns.folder.read(SignInFile.name, cap: SignInFile.maxSize)).map { String(decoding: $0 ?? Data(), as: UTF8.self) } ?? ""
        check(!sealed.contains(secretValue), "MCP OAuth, own app: the sign-ins file holds the secret sealed, never in the clear")
        if let row = view.rows.firstIndex(where: { $0.name == "github" }) {
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await screenshot(window, suffix: "-mcp-oauth-own-app-signed-in")
            view.remove()
            _ = await wait(15) { MCPHubSignIns.record(for: remote.url.absoluteString) == nil }
        }
    }
}
#endif
