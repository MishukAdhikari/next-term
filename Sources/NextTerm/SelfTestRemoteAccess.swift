import AppKit
import CryptoKit
import Network
import NextTermCore
import UserNotifications

/// Remote access end to end (plan 004's U12), with the control options' checks (U14): the real door, the real pairing
/// window and real tabs, with no real tunnel, vendor or Touch ID. Requests go to 127.0.0.1 at the door's port with the
/// public hostname `mcp.example.test` in their Host header, as a tunnel forwards them. Under `--self-test` Remote access
/// keeps its settings in memory and its files in a temp folder of its own, so the user's setup is never read or
/// written; that folder goes at the end, and so does every connection the checks made.
///
/// - Pairing as claude.ai pairs: registration with its callback, `/oauth/authorize` with PKCE, the code typed in Connect
///   a Client, Allow with the Touch ID stand-in, the redirect and the token exchange.
/// - A Read only connection: its ten tools, its reads with a made-up token masked, the shortened wait, and the door's
///   refusals.
/// - A Custom connection: the control options' rules, against a stand-in `claude` that draws Claude Code's prompt box and
///   footer and writes down each line it gets, a plain shell and a busy tab.
/// - The tunnel: a stand-in `tailscale` child ended by a route change, by Turn Off and by the quit path, and the watchdog
///   with a stand-in parent.
extension SelfTest {
    static func remoteAccessChecks(_ c: TerminalWindowController, proj: URL) async {
        #if DEBUG
        await remoteAccessChecksWithStandIns(c, proj: proj)
        #else
        note("remote access: checks need a debug build (the Touch ID, timing and tunnel stand-ins are debug-only)")
        #endif
    }
}

#if DEBUG
extension SelfTest {
    /// The public hostname the checks set: a name no real tunnel serves.
    fileprivate static let remoteHost = "mcp.example.test"
    /// The stand-in Funnel's name for this Mac, as `tailscale status --json` gives it.
    fileprivate static let remoteFunnelName = "selftest-mac.tailnet-0000.ts.net"
    /// A made-up token shaped like no provider's key: a long run of letters and digits, which MCPRedaction masks. Printed
    /// in two halves, so the command that prints it never holds it whole.
    fileprivate static let remoteTokenHalves: (String, String) = ("SelfTestMadeUp7q3Lw9", "Kz2Rv8Np4Xc6Hb1Jd5Fm0")
    fileprivate static var remoteMadeUpToken: String { remoteTokenHalves.0 + remoteTokenHalves.1 }
    /// What Read only admits: the three See options' tools.
    fileprivate static let remoteReadOnlyTools: Set<String> = [
        "list_tabs", "read_tab", "wait_for_tab", "list_projects", "read_file", "find_in_files", "git_status", "get_diff",
        "get_editor_selection", "get_open_files", "list_agent_clis", "list_shortcuts",
    ]

    private static func remoteAccessChecksWithStandIns(_ c: TerminalWindowController, proj: URL) async {
        let remote = RemoteAccess.shared
        guard mode == .plain else {
            return note("remote access: its checks run in the plain self-test only, whose Remote access folder is a temp one")
        }
        // Under --self-test the controller keeps its files in a temp folder of its own, never the user's.
        let parent: String = canonicalPath(remote.folder.deletingLastPathComponent().path)
        let inTemp = parent == canonicalPath(NSTemporaryDirectory())
        let ownFolder = inTemp && remote.folder.lastPathComponent.hasPrefix("nextterm-remote-access-")
        guard ownFolder else {
            return check(false, "remote access: the self-test's Remote access folder is a temp one of its own", remote.folder.path)
        }
        guard !remote.isOn else { return check(false, "remote access: it is off when its checks begin", remote.status.text) }
        guard AppDelegate.shared.agentControl else {
            return note("remote access: “Let agents control Next Term” is off here, so the door can't start: its checks are skipped")
        }
        guard let run = RemoteAccessTestRun.make(c, proj: proj) else {
            return check(false, "remote access: the checks' own folder, zsh config and stand-ins are made")
        }
        // The door's wait held to 3 seconds and a keep-alive each second; Touch ID answered by a stand-in that allows.
        var shortened = RemoteAccessServer.Timings()
        shortened.keepAlive = 1
        shortened.wait = 3
        RemoteAccessServer.Timings.selfTest = shortened
        RemoteAccessConfirmation.standIn = { _ in true }
        MasterKeyGate.standIn = { _ in true }
        MasterKeyGate.reasons = []
        // A window nobody answers gives up sooner than 50 seconds, so a failed check doesn't hold the run.
        MCPWriteControl.answerWithin = 15
        await remoteAccessSteps(run)
        await remoteAccessCleanUp(run)
    }

    private static func remoteAccessSteps(_ run: RemoteAccessTestRun) async {
        guard let door = await remoteAccessTurnOn(run) else { return }
        guard await remoteAccessTabs(run) else { return }
        await remoteAccessRefusedRegistration(door)
        guard let readOnly = await remoteAccessPair(door, name: "Self-test, read only", preset: .readOnly) else { return }
        await remoteAccessReadOnlyChecks(run, door, readOnly)
        if let custom = await remoteAccessPair(door, name: "Self-test, custom", preset: .custom) {
            await remoteAccessControlChecks(run, door, custom)
            await remoteAccessRefreshReuseChecks(door, custom)
        }
        await remoteAccessRevokeDuringWait(run, door, readOnly)
        let left: [RemoteAccessConnectionRow] = RemoteAccess.shared.connectionRows()
        check(left.isEmpty, "remote access: no connection is left once both have ended", left.map(\.name).joined(separator: ", "))
        await remoteAccessTunnelChecks(run)
    }

    // MARK: on, and the tabs

    /// Advanced, the user's own tunnel, with `mcp.example.test` saved: the door alone is on, at a port it picked.
    private static func remoteAccessTurnOn(_ run: RemoteAccessTestRun) async -> RemoteAccessDoorClient? {
        let remote = RemoteAccess.shared
        remote.change { settings in
            settings.tunnel = .advanced
            settings.host = remoteHost
            settings.port = nil
        }
        remote.turnOn()
        let on = await wait(5) { remote.status.phase == .on && remote.door?.isRunning == true }
        let port: UInt16 = remote.door?.port ?? 0
        let picked = RemoteAccessPort.range.contains(port) && remote.settings.port == port
        check(on && picked, "remote access: Advanced with a public hostname turns on, its door on 127.0.0.1 at a port it picked and saved",
              remote.status.text)
        guard on, picked else { return nil }
        return RemoteAccessDoorClient(port: port, host: remoteHost)
    }

    /// The project's window and three tabs in it, each with the checks' own zsh config: the stand-in claude at its
    /// prompt box, a plain shell that printed the made-up token, and a busy one running sleep.
    private static func remoteAccessTabs(_ run: RemoteAccessTestRun) async -> Bool {
        let app: AppDelegate = AppDelegate.shared
        let path = run.proj.path
        func holders() -> [TerminalWindowController] {
            app.controllers.filter { (controller: TerminalWindowController) -> Bool in
                guard !controller.hasClosed, let project = controller.project else { return false }
                return path == project || path.hasPrefix(project + "/")
            }
        }
        let before: [TerminalWindowController] = app.controllers
        if holders().isEmpty { _ = app.openFolder(path, newWindow: false) }
        guard let pc = holders().max(by: { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }) else {
            check(false, "remote access: the self-test's project is open in a window")
            return false
        }
        run.pc = pc
        if !before.contains(where: { $0 === pc }) { run.openedWindow = pc }
        // Its PATH finds the stand-in claude first.
        func opened() async -> TerminalTab? {
            TerminalTab.testUserZDOTDIR = run.zdot.path
            let tab = pc.addTab(directory: path, select: false)
            TerminalTab.testUserZDOTDIR = nil
            run.tabs.append(tab)
            let ready = await wait(20) { tab.status.integrated }
            check(ready, "remote access: a tab with the checks' own zsh config reports in")
            return ready ? tab : nil
        }

        guard let agent = await opened() else { return false }
        let standIn: String = run.bin.appendingPathComponent("claude").path
        agent.view.send(txt: "command -v claude\r")
        let found = await wait(5) { agent.screenTail(6).contains { $0 == standIn } }
        guard found else {
            check(false, "remote access: the checks' tabs find the stand-in claude first, never another one",
                  agent.screenTail(4).joined(separator: " | "))
            return false
        }
        agent.view.send(txt: "claude\r")
        let drawn = await wait(10) {
            agent.status.running && agent.status.kind == .agent && agent.status.program == "claude"
                && agent.screenTail(12).contains { $0.contains("? for shortcuts") }
        }
        check(drawn, "remote access: a tab runs the stand-in claude, with Claude Code's prompt box and its default footer",
              agent.screenTail(6).joined(separator: " | "))
        guard drawn else { return false }
        run.agent = agent

        guard let shell = await opened() else { return false }
        shell.view.send(txt: "printf '%s%s\\n' \(remoteTokenHalves.0) \(remoteTokenHalves.1)\r")
        let printed = await wait(5) { shell.screenTail(6).contains { $0 == remoteMadeUpToken } }
        check(printed, "remote access: a plain shell tab prints the made-up token", shell.screenTail(3).joined(separator: " | "))
        run.shell = shell

        guard let busy = await opened() else { return false }
        busy.view.send(txt: "sleep 120\r")
        let running = await wait(10) { busy.status.running && busy.closeWarning != nil }
        check(running, "remote access: a tab runs sleep, so closing it warns", busy.closeWarning ?? "no warning")
        run.busy = busy
        return printed && running
    }

    // MARK: pairing

    /// A registration whose only callback is not claude.ai's or chatgpt.com's is refused (RFC 7591's error).
    private static func remoteAccessRefusedRegistration(_ door: RemoteAccessDoorClient) async {
        var registration: [String: Any] = [:]
        registration["client_name"] = "Self-test client"
        registration["redirect_uris"] = ["https://example.com/cb"]
        let refused = await door.postJSON("/oauth/register", registration)
        let named = refused?.json?["error"] as? String == "invalid_redirect_uri"
        check(refused?.status == 400 && named, "remote access: a registration with https://example.com/cb is refused",
              "\(refused?.status ?? 0) \(refused?.text ?? "no answer")")
    }

    /// One connection paired as claude.ai pairs it: registered with its callback, authorized with PKCE, its code typed in
    /// Connect a Client, allowed with `preset` after the Touch ID stand-in, the redirect read and the code exchanged. Nil,
    /// after a failed check, when a step fails.
    private static func remoteAccessPair(_ door: RemoteAccessDoorClient, name: String,
                                         preset: RemoteAccessPreset) async -> RemoteAccessPaired? {
        let label = "remote access pairing (\(preset.title))"
        guard let state = RemoteAccess.shared.doorState, let window = RemoteAccessPairingWindow.open(state: state) else {
            check(false, "\(label): Connect a Client opens the pairing window")
            return nil
        }
        defer { if window.window?.isVisible == true { window.close() } }
        let callback = RemoteAccessOAuth.claudeCallback
        let resource = "https://\(remoteHost)/mcp"
        var registration: [String: Any] = [:]
        registration["client_name"] = "Self-test client"
        registration["redirect_uris"] = [callback]
        registration["token_endpoint_auth_method"] = "none"
        registration["grant_types"] = ["authorization_code", "refresh_token"]
        registration["response_types"] = ["code"]
        let registered = await door.postJSON("/oauth/register", registration)
        guard registered?.status == 201, let client = registered?.json?["client_id"] as? String else {
            check(false, "\(label): a registration with claude.ai's callback is accepted", registered?.text ?? "no answer")
            return nil
        }

        // /oauth/authorize with an S256 challenge: the page shows the code and reloads to its wait URL.
        let verifier: String = remoteBase64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge: String = remoteBase64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let sent = "state-\(preset.rawValue)"
        var query: [(String, String)] = [("response_type", "code"), ("client_id", client), ("redirect_uri", callback)]
        query += [("state", sent), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("resource", resource)]
        let page = await door.request("GET", "/oauth/authorize?" + RemoteAccessDoorClient.form(query))
        let html = page?.text ?? ""
        let code = remoteFirstMatch(#"<p class="code">(\d{6})</p>"#, in: html)
        let waitPath = remoteFirstMatch(#"url=(/oauth/authorize/wait\?request=[^"]+)""#, in: html)
        guard page?.status == 200, let code, let waitPath else {
            check(false, "\(label): /oauth/authorize with PKCE shows a 6-digit code to type on the Mac",
                  "\(page?.status ?? 0) \(html.prefix(200))")
            return nil
        }

        // The code typed in Connect a Client, six digits as a hand types them.
        window.codeField.stringValue = code
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: window.codeField))
        let shown = await wait(5) { window.matched != nil && window.allowButton.isEnabled }
        check(shown && window.hostLabel.stringValue == "claude.ai",
              "\(label): the code typed in Connect a Client shows the request going back to claude.ai, and Allow comes on a moment later",
              window.statusLabel.stringValue)
        guard shown else { return nil }
        window.nameField.stringValue = name
        if preset != .readOnly { window.optionsView.pick(preset) }
        let options = window.optionsView.options
        let keyAsked = MasterKeyGate.reasons.count
        window.allowButton.performClick(nil)
        let allowed = await wait(5) { window.approved != nil }
        let askedForKey = MasterKeyGate.reasons.count > keyAsked
        check(askedForKey == (preset != .readOnly),
              "\(label): Allow asks for the master key only when the preset gives more than reading",
              "\(preset): " + (askedForKey ? "asked" : "not asked"))
        let reason = RemoteAccessConfirmation.lastReason == RemoteAccessPairingWindow.reason(name: name, options: preset.options)
        let kept = options == preset.options && window.approved?.options == preset.options && window.approved?.name == name
        check(allowed && reason && kept,
              "\(label): Allow asks the Touch ID stand-in, naming what the preset allows, and makes the connection",
              RemoteAccessConfirmation.lastReason ?? "not asked")
        guard let grant = window.approved else { return nil }

        // The browser's next reload: back to claude.ai with the code, its state and the issuer.
        let back = await door.request("GET", waitPath.replacingOccurrences(of: "&amp;", with: "&"))
        let location = URLComponents(string: back?.header("location") ?? "")
        let items: [URLQueryItem] = location?.queryItems ?? []
        func item(_ key: String) -> String? { items.first { $0.name == key }?.value }
        let home = location?.host == "claude.ai" && location?.path == "/api/mcp/auth_callback"
        let redirected = back?.status == 302 && home && item("state") == sent && item("iss") == "https://\(remoteHost)"
        guard redirected, let authorization = item("code") else {
            check(false, "\(label): the browser's reload goes back to claude.ai with the code, its state and the issuer",
                  back?.header("location") ?? "\(back?.status ?? 0)")
            return nil
        }

        // The code for tokens, with the verifier.
        var exchange: [(String, String)] = [("grant_type", "authorization_code"), ("code", authorization), ("code_verifier", verifier)]
        exchange += [("client_id", client), ("redirect_uri", callback), ("resource", resource)]
        let exchanged = await door.postForm("/oauth/token", exchange)
        let access = exchanged?.json?["access_token"] as? String ?? ""
        let refresh = exchanged?.json?["refresh_token"] as? String ?? ""
        let scope = exchanged?.json?["scope"] as? String
        let shaped = access.hasPrefix(RemoteAccessOAuth.accessPrefix) && refresh.hasPrefix(RemoteAccessOAuth.refreshPrefix)
        let scoped = scope == RemoteAccessOAuth.scope(for: preset.options)
        check(exchanged?.status == 200 && shaped && scoped,
              "\(label): the redirect carries the code back to claude.ai, and the code and its verifier get an access and a refresh token",
              "\(exchanged?.status ?? 0) scope \(scope ?? "none")")
        guard exchanged?.status == 200, shaped else { return nil }
        return RemoteAccessPaired(grant: grant.id, name: grant.name, client: client, access: access, refresh: refresh)
    }

    // MARK: Read only

    private static func remoteAccessReadOnlyChecks(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                                   _ paired: RemoteAccessPaired) async {
        guard let agent = run.agent, let shell = run.shell, let busy = run.busy else { return }
        let token = paired.access
        let label = "remote access (Read only)"

        // initialize, with the MCP-Protocol-Version a vendor sends; a version the door doesn't speak gets 400.
        var hello: [String: Any] = [:]
        hello["protocolVersion"] = "2025-06-18"
        hello["capabilities"] = [String: Any]()
        hello["clientInfo"] = ["name": "selftest", "version": "1"]
        let initialized = await door.mcp("initialize", hello, token: token)
        let result = initialized?.message?["result"] as? [String: Any]
        let instructions = result?["instructions"] as? String ?? ""
        let capabilities = result?["capabilities"] as? [String: Any]
        let listChanged = (capabilities?["tools"] as? [String: Any])?["listChanged"] as? Bool
        let spoken = result?["protocolVersion"] as? String == "2025-06-18"
        check(spoken && !instructions.isEmpty && listChanged == true,
              "\(label): initialize with MCP-Protocol-Version 2025-06-18 is answered, with the remote instructions and listChanged",
              initialized?.text.prefix(200).description ?? "no answer")
        let unspoken = await door.mcp("ping", nil, token: token, version: "1999-01-01")
        check(unspoken?.status == 400, "\(label): an MCP-Protocol-Version the door doesn't speak gets 400", "\(unspoken?.status ?? 0)")

        // tools/list: the tools the See options admit, and nothing else.
        let listed = await door.mcp("tools/list", [:], token: token)
        let tools = ((listed?.message?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names: [String] = tools.compactMap { $0["name"] as? String }
        check(names.count == remoteReadOnlyTools.count && Set(names) == remoteReadOnlyTools, "\(label): tools/list has the Read only tools",
              names.joined(separator: ", "))

        // list_tabs shows the stand-in claude's tab, its agent and its state.
        let tabs = await door.call("list_tabs", [:], token: token)
        let windows = (tabs.json?["windows"] as? [[String: Any]]) ?? []
        let rows: [[String: Any]] = windows.flatMap { ($0["tabs"] as? [[String: Any]]) ?? [] }
        let row = rows.first { $0["id"] as? String == remoteID(agent) }
        let described = row?["agent"] as? Bool == true && row?["program"] as? String == "claude" && row?["state"] is String
        check(!tabs.isError && described, "\(label): list_tabs shows the test tab, its agent and its state",
              tabs.text.prefix(300).description)

        // read_tab: the made-up token on the shell's screen is masked.
        let read = await door.call("read_tab", ["tab_id": remoteID(shell), "lines": 20], token: token)
        let screen = read.json?["screen"] as? String ?? ""
        let masked = !read.text.contains(remoteMadeUpToken) && screen.contains(MCPRedaction.mask) && screen.contains("printf")
        check(!read.isError && masked, "\(label): read_tab masks a made-up token printed in a tab", screen.suffix(200).description)

        // wait_for_tab on the busy tab: held to the shortened 3 seconds, as a stream with keep-alives, then timed_out.
        let started = Date()
        let waited = await door.call("wait_for_tab", ["tab_id": remoteID(busy), "timeout_seconds": 50], token: token, stream: true,
                                     within: 20)
        let took = Date().timeIntervalSince(started)
        let streamed = waited.answer?.header("content-type")?.hasPrefix("text/event-stream") == true
        let keepAlives = (waited.answer?.text.components(separatedBy: ": keep-alive").count ?? 1) - 1
        let timedOut = waited.json?["timed_out"] as? Bool == true
        let waitedFor: String = String(format: "%.1f s, ", took) + "\(keepAlives) keep-alives: " + String(waited.text.prefix(200))
        check(timedOut && streamed && keepAlives >= 1 && took >= 2.5 && took < 10,
              "\(label): wait_for_tab is held to the debug 3 seconds and answered as a stream with keep-alives, timed_out", waitedFor)

        // Two waits at once and a list_tabs beside them: each is answered, the list at once.
        let busyID = remoteID(busy)
        let first = Task {
            await door.call("wait_for_tab", ["tab_id": busyID, "timeout_seconds": 50], token: token, stream: true, within: 20)
        }
        let second = Task {
            await door.call("wait_for_tab", ["tab_id": busyID, "timeout_seconds": 50], token: token, stream: true, within: 20)
        }
        await pause(0.4)
        let listStarted = Date()
        let during = await door.call("list_tabs", [:], token: token)
        let listTook = Date().timeIntervalSince(listStarted)
        let one = await first.value
        let two = await second.value
        let bothTimedOut = one.json?["timed_out"] as? Bool == true && two.json?["timed_out"] as? Bool == true
        let waits: String = String(one.text.prefix(80)) + " / " + String(two.text.prefix(80))
        let answers: String = String(format: "list_tabs in %.1f s; ", listTook) + waits
        check(!during.isError && listTook < 2 && bothTimedOut, "\(label): two waits at once and a list_tabs beside them are each answered",
              answers)

        // The door's refusals: a page's Origin, the loopback Host, a path it doesn't serve, and no token.
        let body = RemoteAccessDoorClient.json(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": hello])
        let jsonType: (String, String) = ("Content-Type", "application/json")
        let bearer: (String, String) = ("Authorization", "Bearer \(token)")
        let fromPage = await door.request("POST", "/mcp", headers: [jsonType, bearer, ("Origin", "https://page.example")], body: body)
        check(fromPage?.status == 403, "\(label): a request with an Origin gets 403", "\(fromPage?.status ?? 0)")
        let loopback = await door.request("POST", "/mcp", host: "127.0.0.1:\(door.port)", headers: [jsonType, bearer], body: body)
        check(loopback?.status == 421, "\(label): Host 127.0.0.1:<port> gets 421", "\(loopback?.status ?? 0)")
        let slash = await door.request("GET", "/")
        check(slash?.status == 404, "\(label): / gets 404", "\(slash?.status ?? 0)")
        let anonymous = await door.request("POST", "/mcp", headers: [jsonType], body: body)
        let challenge = anonymous?.header("www-authenticate") ?? ""
        let metadataURL = "https://\(remoteHost)/.well-known/oauth-protected-resource/mcp"
        check(anonymous?.status == 401 && challenge.contains("resource_metadata=\"\(metadataURL)\""),
              "\(label): no token gets 401 with resource_metadata", challenge)
        let metadata = await door.request("GET", "/.well-known/oauth-protected-resource/mcp")
        check(metadata?.status == 200 && metadata?.json?["resource"] as? String == "https://\(remoteHost)/mcp",
              "\(label): the resource metadata names the public hostname", metadata?.text.prefix(200).description ?? "no answer")

        // send_to_tab is a control tool: the can't-use text names the option, and nothing is typed.
        let lines = remoteAgentLines(run)
        let typing = await door.call("send_to_tab", ["tab_id": remoteID(agent), "text": "fix the login"], token: token)
        await pause(0.6)
        let cantType = RemoteAccessText.cantUse("send_to_tab", needing: [.typeAsking])
        check(typing.isError && typing.text == cantType && remoteAgentLines(run) == lines,
              "\(label): send_to_tab gets the can't-use text naming “Type into agents that ask before acting”, and nothing is typed",
              typing.text)
    }

    // MARK: Custom: the control options (U14)

    private static func remoteAccessControlChecks(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                                  _ paired: RemoteAccessPaired) async {
        guard let agent = run.agent, let shell = run.shell, let busy = run.busy, let pc = run.pc else { return }
        let remote = RemoteAccess.shared
        let app: AppDelegate = AppDelegate.shared
        let token = paired.access
        let label = "remote access (Custom)"

        // At most 10 control calls a minute: set_layout with what is so already changes nothing and asks nothing, and
        // counts as a control call all the same.
        let layout: [String: Any] = ["terminal_position": app.terminalPosition.rawValue, "project": pc.project ?? run.proj.path]
        var ran = 0
        var last = RemoteAccessDoorCall(nil)
        // One that asked or failed would make each of the rest wait for the window: they stop there.
        while ran < 11 {
            last = await door.call("set_layout", layout, token: token)
            guard !last.isError else { break }
            ran += 1
        }
        check(ran == 10 && last.text == RemoteAccessText.controlRate && MCPWriteControl.pending == nil,
              "\(label): ten control calls run, and the 11th in the minute gets the control rate text", "\(ran) ran; " + last.text)

        // Edit…: the rate limit off, saved after the Touch ID stand-in; the next control call runs.
        guard let row = remote.connectionRows().first(where: { $0.id == paired.grant }) else {
            return check(false, "\(label): Settings lists the connection")
        }
        let sheet = RemoteAccessEditSheet(row: row)
        run.windows.append(sheet)
        sheet.present(on: nil)
        let opened = RemoteAccessEditSheet.shown === sheet && sheet.optionsView.options == RemoteAccessOptions.customStart
        sheet.optionsView.set(.rateLimit, false)
        let keyAsked = MasterKeyGate.reasons.count
        sheet.saveButton.performClick(nil)
        _ = await wait(5) { MasterKeyGate.reasons.count > keyAsked }
        check(MasterKeyGate.reasons.count > keyAsked, "\(label): Edit… that widens a connection asks for the master key first")
        let saved = await wait(5) { remote.connectionOptions(paired.grant)?[.rateLimit] == false }
        let reason = RemoteAccessConfirmation.lastReason == RemoteAccessSettingsText.editReason(name: paired.name)
        let twelfth = await door.call("set_layout", layout, token: token)
        check(opened && saved && reason && sheet.window?.isVisible != true && !twelfth.isError,
              "\(label): Edit… turns “At most 10 control calls a minute” off after the Touch ID stand-in, and the next control call runs",
              twelfth.text)

        await remoteAccessAskChecks(run, door, paired, agent: agent)
        await remoteAccessRefusalChecks(run, door, paired, agent: agent, shell: shell, busy: busy)
        await remoteAccessNewTabChecks(run, door, paired)
    }

    /// "Ask on this Mac before changes", on as Custom starts: a call the options let through waits for the window, named
    /// for the connection, with Allow. Decline gives the declined text; Allow runs it, and "Notify on this Mac" posts the
    /// notice, masked and cut at 80 characters.
    private static func remoteAccessAskChecks(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                              _ paired: RemoteAccessPaired, agent: TerminalTab) async {
        let app: AppDelegate = AppDelegate.shared
        let token = paired.access
        let label = "remote access (Custom)"
        let agentID = remoteID(agent)

        let before = remoteAgentLines(run)
        let declining = Task { await door.call("send_to_tab", ["tab_id": agentID, "text": "fix the login"], token: token) }
        let asked = await wait(10) { MCPWriteControl.pending?.window != nil }
        let window = MCPWriteControl.pending?.window
        let said = texts(window?.window?.contentView)
        let allowTitled = window?.approveButton.title == "Allow"
        window?.declineButton.performClick(nil)
        let declined = await declining.value
        await pause(0.6)
        let named = said.contains("the connection “\(paired.name)”") && said.contains("send_to_tab") && said.contains("fix the login")
        check(asked && allowTitled && named,
              "\(label): “Ask on this Mac before changes” shows the approval window, named for the connection, with the tool, the text and Allow",
              said)
        check(declined.isError && declined.text == RemoteAccessText.declined && remoteAgentLines(run) == before,
              "\(label): Decline gets “Declined on your Mac.”, and nothing is typed", declined.text)

        // Allow: with “? for shortcuts” on the agent's footer, the text goes in with Return.
        let notices = app.testNotifications.count
        let allowing = Task { await door.call("send_to_tab", ["tab_id": agentID, "text": "fix the login"], token: token) }
        _ = await wait(10) { MCPWriteControl.pending?.window != nil }
        MCPWriteControl.pending?.window?.approveButton.performClick(nil)
        let allowed = await allowing.value
        let typed = await wait(5) { remoteAgentLines(run) == before + ["fix the login"] }
        check(!allowed.isError && typed, "\(label): Allow runs it: “fix the login” goes into the agent's empty input line, with Return",
              allowed.text)
        let title = "Remote: \(paired.name)"
        let notice = app.testNotifications.dropFirst(notices).last { $0.content.title == title }
        let tabLine = "send_to_tab in “\(RemoteAccessServer.shown(agent.title))”"
        check(notice?.content.body == tabLine + "\nfix the login",
              "\(label): “Notify on this Mac” posts a notice naming the connection, the tool, the tab and the text",
              notice?.content.body ?? "no notice")

        // A first line with the made-up token, longer than 80 characters: masked and cut, in the window and the notice.
        let long = "fix the login, the key \(remoteMadeUpToken) is set now, so run the whole suite again and tell me what changed"
        let longNotices = app.testNotifications.count
        let sending = Task { await door.call("send_to_tab", ["tab_id": agentID, "text": long], token: token) }
        _ = await wait(10) { MCPWriteControl.pending?.window != nil }
        let longSaid = texts(MCPWriteControl.pending?.window?.window?.contentView)
        MCPWriteControl.pending?.window?.approveButton.performClick(nil)
        let sentLong = await sending.value
        _ = await wait(5) { remoteAgentLines(run).last == long }
        let longNotice = app.testNotifications.dropFirst(longNotices).last { $0.content.title == title }
        let body = longNotice?.content.body ?? ""
        let sentLine: String = body.components(separatedBy: "\n").last ?? ""
        let cut = sentLine.count == 80 && sentLine.hasSuffix("…") && sentLine.contains(MCPRedaction.mask)
        let hidden = !body.contains(remoteMadeUpToken) && !longSaid.contains(remoteMadeUpToken) && longSaid.contains(MCPRedaction.mask)
        check(!sentLong.isError && cut && hidden,
              "\(label): what was sent shows masked and cut at 80 characters, in the notice and in the window", sentLine)
    }

    /// The control options' refusals, each naming its option: none asks on the Mac, and nothing reaches the tab.
    private static func remoteAccessRefusalChecks(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                                  _ paired: RemoteAccessPaired, agent: TerminalTab, shell: TerminalTab,
                                                  busy: TerminalTab) async {
        let token = paired.access
        let label = "remote access (Custom)"
        let agentID = remoteID(agent)
        func refused(_ tool: String, _ arguments: [String: Any], _ text: String, _ name: String) async {
            let lines = remoteAgentLines(run)
            let call = await door.call(tool, arguments, token: token)
            await pause(0.5)
            let nothing = remoteAgentLines(run) == lines && MCPWriteControl.pending == nil
            check(call.isError && call.text == text && nothing, "\(label): \(name)", call.text)
        }
        await refused("send_to_tab", ["tab_id": agentID, "text": "!ls"], RemoteAccessText.shellAndMemoryOff,
                      "`!ls` gets the text naming “! shell lines and # memory lines”, and nothing is typed")
        await refused("send_to_tab", ["tab_id": agentID, "text": "/model opus"], RemoteAccessText.slashOff(.anySlash),
                      "`/model opus` gets the text naming “Any / command”, and nothing is typed")
        await refused("send_to_tab", ["tab_id": agentID, "text": "fix the login", "submit": false], RemoteAccessText.alwaysReturn,
                      "submit false gets the text naming “Every key”, and nothing is typed")
        await refused("press_keys", ["tab_id": agentID, "keys": ["tab"]], RemoteAccessText.keyOff,
                      "press_keys tab gets the key text, and nothing is pressed")

        // The footer turns to bypass: the agent never asks now, so typing needs the other Agents option.
        FileManager.default.createFile(atPath: run.flag, contents: nil)
        let bypass = await wait(5) { agent.screenTail(12).contains { $0.contains("bypass permissions on") } }
        check(bypass, "\(label): the stand-in claude's footer turns to “bypass permissions on”",
              agent.screenTail(3).joined(separator: " | "))
        await refused("send_to_tab", ["tab_id": agentID, "text": "fix the login"], RemoteAccessText.neverAsks,
                      "with the bypass footer, typing gets the never-asks text, and nothing is typed")
        try? FileManager.default.removeItem(atPath: run.flag)
        _ = await wait(5) { agent.screenTail(12).contains { $0.contains("? for shortcuts") } }

        // A plain shell needs "Type into shell tabs".
        let shellCall = await door.call("send_to_tab", ["tab_id": remoteID(shell), "text": "echo remote-was-here"], token: token)
        await pause(0.5)
        let untouched = !shell.screenTail(6).contains { $0.contains("remote-was-here") }
        check(shellCall.isError && shellCall.text == RemoteAccessText.shellTab && untouched,
              "\(label): send_to_tab into a plain shell gets the shell tab text, and nothing is typed", shellCall.text)

        // close_tab on a busy tab: the busy-tab text; with force, invalid params naming "Close busy tabs".
        let closing = await door.call("close_tab", ["tab_id": remoteID(busy)], token: token)
        let forced = await door.call("close_tab", ["tab_id": remoteID(busy), "force": true], token: token)
        let stillOpen = MCPControl.tab(withID: remoteID(busy)) != nil
        check(closing.isError && closing.text == RemoteAccessText.busyTab && stillOpen,
              "\(label): close_tab on a busy tab gets the busy-tab text, and the tab stays", closing.text)
        check(forced.code == -32602 && forced.text.contains("“Close busy tabs”") && stillOpen,
              "\(label): close_tab with force gets JSON-RPC error -32602 naming “Close busy tabs”, and the tab stays",
              "\(forced.code ?? 0) \(forced.text)")
    }

    /// new_tab: one listed agent's name, in an open project; any other command, or a folder outside the open projects,
    /// is refused and opens nothing. The one that passes asks on the Mac, then opens a tab running the stand-in claude.
    private static func remoteAccessNewTabChecks(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                                 _ paired: RemoteAccessPaired) async {
        let app: AppDelegate = AppDelegate.shared
        let token = paired.access
        let label = "remote access (Custom)"
        func tabCount() -> Int { app.controllers.reduce(0) { $0 + $1.tabs.count } }

        let before = tabCount()
        let bash = await door.call("new_tab", ["directory": run.proj.path, "command": "bash"], token: token)
        await pause(0.5)
        check(bash.isError && bash.text == RemoteAccessText.commandOff && tabCount() == before,
              "\(label): new_tab with bash gets the command text naming “Open a tab with any command, or a plain shell”, and no tab opens",
              bash.text)
        let outside = canonicalPath(run.outside.path)
        let projects: [String] = app.controllers.compactMap(\.project)
        if projects.contains(where: { outside == $0 || outside.hasPrefix($0 + "/") }) {
            note("remote access: an open project holds the temp folder, so the folder outside every open project is not checked")
        } else {
            let elsewhere = await door.call("new_tab", ["directory": outside, "command": "claude"], token: token)
            await pause(0.5)
            check(elsewhere.isError && elsewhere.text == RemoteAccessText.folderOff && tabCount() == before,
                  "\(label): new_tab outside every open project gets the folder text naming “Open projects and show things on the Mac”, and no tab opens",
                  elsewhere.text)
        }

        // claude in the project: asked on the Mac, then a tab that runs it, which finds the stand-in on its PATH.
        TerminalTab.testUserZDOTDIR = run.zdot.path
        let project = run.proj.path
        let opening = Task { await door.call("new_tab", ["directory": project, "command": "claude"], token: token) }
        let asked = await wait(10) { MCPWriteControl.pending?.window != nil }
        MCPWriteControl.pending?.window?.approveButton.performClick(nil)
        let opened = await opening.value
        TerminalTab.testUserZDOTDIR = nil
        let tab = MCPControl.tab(withID: opened.json?["id"] as? String ?? "")
        if let tab { run.tabs.append(tab) }
        let runs = await wait(15) {
            guard let tab else { return false }
            let drawn = tab.screenTail(12).contains { $0.contains("⏺ Done. The tests pass.") }
            return tab.status.running && tab.status.kind == .agent && drawn
        }
        check(asked && !opened.isError && runs,
              "\(label): new_tab with claude in an open project asks on the Mac, and after Allow opens a tab running claude",
              opened.text)
    }

    // MARK: ending connections

    /// A refresh token used again after its one grace reuse ends the connection (R16): the Mac is told, and its keys no
    /// longer open the door.
    private static func remoteAccessRefreshReuseChecks(_ door: RemoteAccessDoorClient, _ paired: RemoteAccessPaired) async {
        let remote = RemoteAccess.shared
        let app: AppDelegate = AppDelegate.shared
        func refresh(_ token: String) async -> RemoteAccessDoorAnswer? {
            var form: [(String, String)] = [("grant_type", "refresh_token"), ("refresh_token", token)]
            form += [("client_id", paired.client), ("resource", "https://\(remoteHost)/mcp")]
            return await door.postForm("/oauth/token", form)
        }
        let renewed = await refresh(paired.refresh)
        let access = renewed?.json?["access_token"] as? String ?? ""
        let next = renewed?.json?["refresh_token"] as? String
        // Within 60 seconds, the old one once more gets the same new pair: a reply that was lost.
        let again = await refresh(paired.refresh)
        let samePair = next != nil && again?.json?["refresh_token"] as? String == next
        let notices = app.testNotifications.count
        let reused = await refresh(paired.refresh)
        let refused = reused?.status == 400 && reused?.json?["error"] as? String == "invalid_grant"
        let ended = await wait(3) { remote.connectionOptions(paired.grant) == nil }
        let notice = RemoteAccessOAuth.reuseNotice(grantName: paired.name)
        let told = await wait(3) { app.testNotifications.dropFirst(notices).contains { $0.content.body == notice } }
        let locked = await door.mcp("tools/list", [:], token: access)
        check(renewed?.status == 200 && samePair && refused && ended && told && locked?.status == 401,
              "remote access: a refresh token used again after its grace ends the connection, the Mac is told, and its keys no longer open the door",
              "\(renewed?.status ?? 0) / \(reused?.text ?? "no answer") / \(locked?.status ?? 0)")
    }

    /// Revoke on the Mac while a call waits: the wait is answered at once with the revoke text (R38).
    private static func remoteAccessRevokeDuringWait(_ run: RemoteAccessTestRun, _ door: RemoteAccessDoorClient,
                                                     _ paired: RemoteAccessPaired) async {
        guard let busy = run.busy else { return }
        let busyID = remoteID(busy)
        let token = paired.access
        let waiting = Task { await door.call("wait_for_tab", ["tab_id": busyID, "timeout_seconds": 50], token: token, within: 20) }
        await pause(0.8)
        let revoked = Date()
        let problem = RemoteAccess.shared.revoke(paired.grant)
        let answer = await waiting.value
        let took = Date().timeIntervalSince(revoked)
        let locked = await door.mcp("tools/list", [:], token: token)
        check(problem == nil && answer.isError && answer.text == RemoteAccessText.turnedOff && took < 1.5 && locked?.status == 401,
              "remote access: Revoke on the Mac answers a wait at once with the revoke text, and the key no longer opens the door",
              String(format: "%.1f s: ", took) + answer.text)
    }

    // MARK: the tunnel

    /// The stand-in Funnel (U10's debug hooks): a route change stops it, Turn Off ends it within 3 seconds with the door
    /// and its connections closed within one, and the quit path ends it in place. Then the watchdog with a stand-in
    /// parent, and agent control turned off.
    private static func remoteAccessTunnelChecks(_ run: RemoteAccessTestRun) async {
        let remote = RemoteAccess.shared
        let app: AppDelegate = AppDelegate.shared
        remote.turnOff()
        _ = await wait(3) { !remote.isOn && remote.door == nil }
        guard let port = remote.settings.port else { return check(false, "remote access: the door's port is saved") }
        let funnel = RemoteAccessFunnelStandIn(name: remoteFunnelName, port: Int(port), marker: run.marker)
        var standIn = RemoteAccessTunnel.StandIn()
        standIn.program = run.tailscale
        standIn.tailscaleStatus = { funnel.status() }
        standIn.funnelStatus = { funnel.share() }
        RemoteAccessTunnel.standIn = standIn
        let limits = RemoteAccessTunnelWatch.Limits(routingWait: 10, notifyAfter: 600, restartScale: 0.05)
        RemoteAccessTunnel.Timings.selfTest = RemoteAccessTunnel.Timings(check: 0.5, limits: limits)
        remote.change { settings in
            settings.tunnel = .funnel
            settings.host = nil
        }
        let tunnel = remote.tunnel as? RemoteAccessTunnel
        let label = "remote access (Funnel)"
        // One start: on once the stand-in's share shows the door; its child's pid and start time.
        func started(_ which: String) async -> (pid: pid_t, start: RemoteAccessPidRecord.Start)? {
            try? FileManager.default.removeItem(atPath: run.marker)
            funnel.elsewhere = false
            remote.turnOn()
            let on = await wait(20) { remote.status.phase == .on }
            guard on, let pid = tunnel?.childPid, let start = RemoteAccessProcesses.start(of: pid) else {
                check(false, "\(label): the \(which) start runs the stand-in tailscale, and its share shows the door", remote.status.text)
                remote.turnOff()
                remote.dismiss()
                return nil
            }
            return (pid, start)
        }
        func stopped() -> Bool {
            if case .stopped = remote.status.phase { return true }
            return false
        }

        if let child = await started("first") {
            let recorded = await wait(3) { RemoteAccessPidRecord.read(in: remote.folder)?.pid == child.pid }
            let watched = tunnel?.watchdogPid != nil
            check(remote.status.host == remoteFunnelName && recorded && watched,
                  "\(label): on through the stand-in tailscale, with the hostname its status names, a pid record and a watchdog",
                  remote.status.text)
            let notices = app.testNotifications.count
            funnel.elsewhere = true
            let stop = await wait(5) { stopped() }
            let ended = await wait(3) { RemoteAccessProcesses.hasEnded(child.pid, start: child.start) }
            let stoppedTitle = RemoteAccessStatus.Notice.stopped("").title
            let told = app.testNotifications.dropFirst(notices).contains { $0.content.title == stoppedTitle }
            check(stop && ended && told && remote.door == nil,
                  "\(label): the stand-in's share sent elsewhere stops Remote access and its tunnel, and the Mac is told", remote.status.text)
            remote.dismiss()
        }

        if let child = await started("second") {
            let idle = RemoteAccessDoorLink(port: port)
            idle.send("POST /mcp HTTP/1.1\r\nHost: \(remoteFunnelName)\r\n")
            await pause(0.3)
            let server = remote.door
            let began = Date()
            remote.turnOff()
            let closed = await wait(1) { idle.ended && server?.isRunning == false }
            let left = max(0.1, 3 - Date().timeIntervalSince(began))
            let ended = await wait(left) { RemoteAccessProcesses.hasEnded(child.pid, start: child.start) }
            let forgotten = await wait(3) { RemoteAccessPidRecord.read(in: remote.folder) == nil }
            idle.close()
            check(closed, "\(label): Turn Off closes the door and its open connections within a second")
            check(ended && forgotten, "\(label): and the stand-in tunnel is gone within 3 seconds, and its pid record with it")
        }

        if let child = await started("third") {
            remote.stopForQuit()
            let ended = RemoteAccessProcesses.hasEnded(child.pid, start: child.start)
            let forgotten = RemoteAccessPidRecord.read(in: remote.folder) == nil
            check(ended && forgotten && !remote.isOn && remote.door == nil,
                  "\(label): stop for quit, called directly, ends the stand-in tunnel in place and then deletes its pid record")
        }

        await remoteAccessWatchdogCheck()

        // Agent control turned off, as AppDelegate tells the controller: Remote access goes off and is saved off. The
        // user's own setting is not touched.
        remote.change { settings in
            settings.tunnel = .advanced
            settings.host = remoteHost
        }
        remote.turnOn()
        let back = await wait(5) { remote.status.phase == .on }
        remote.agentControlChanged(false)
        check(back && !remote.isOn && remote.door == nil && !remote.settings.on,
              "remote access: agent control turned off turns Remote access off, saved off", remote.status.text)
    }

    /// The watchdog (`nxtrm tunnel-guard`) given a stand-in parent: when that ends, the stand-in tunnel is ended within
    /// 5 seconds, and the watchdog exits.
    private static func remoteAccessWatchdogCheck() async {
        func sleeper() -> Process? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return (try? process.run()) == nil ? nil : process
        }
        guard let parent = sleeper(), let child = sleeper() else {
            return check(false, "remote access: the watchdog's stand-in parent and tunnel start")
        }
        defer {
            for process in [parent, child] where process.isRunning { process.terminate() }
        }
        let parentPid = parent.processIdentifier
        let childPid = child.processIdentifier
        guard let parentStart = RemoteAccessProcesses.start(of: parentPid),
              let childStart = RemoteAccessProcesses.start(of: childPid) else {
            return check(false, "remote access: the watchdog's stand-in parent and tunnel run")
        }
        let targets = RemoteAccessGuardTargets(owner: parentPid, ownerStart: parentStart, child: childPid, childStart: childStart)
        let watchdog = RemoteAccessTunnelGuard.launch(targets)
        await pause(1)
        let watching = watchdog?.isRunning == true && !RemoteAccessProcesses.hasEnded(childPid, start: childStart)
        parent.terminate()
        let ended = await wait(5) { RemoteAccessProcesses.hasEnded(childPid, start: childStart) }
        let exited = await wait(3) { watchdog?.isRunning == false }
        check(watching && ended && exited,
              "remote access: the watchdog ends the stand-in tunnel within 5 seconds after its stand-in parent ends, then exits",
              "watching \(watching), ended \(ended), exited \(exited)")
        if watchdog?.isRunning == true { watchdog?.terminate() }
    }

    // MARK: cleaning up

    /// Everything goes back as it was: the windows and tabs the checks opened, every connection, Remote access off with
    /// the settings it had, the stand-ins and timings unset, and the checks' files and Remote access's temp folder gone.
    private static func remoteAccessCleanUp(_ run: RemoteAccessTestRun) async {
        let remote = RemoteAccess.shared
        let manager = FileManager.default
        TerminalTab.testUserZDOTDIR = nil
        MasterKeyGate.standIn = nil
        if let asking = MCPWriteControl.pending, !asking.answered { asking.window?.close() }
        RemoteAccessPairingWindow.close()
        for window in run.windows { window.close() }
        if !remote.connectionRows().isEmpty { remote.revokeAll() }
        remote.turnOff()
        remote.dismiss()
        _ = await wait(3) { !remote.isOn && remote.door == nil }
        let rows: [RemoteAccessConnectionRow] = remote.connectionRows()
        RemoteAccessServer.Timings.selfTest = nil
        RemoteAccessTunnel.Timings.selfTest = nil
        RemoteAccessTunnel.standIn = nil
        RemoteAccessConfirmation.standIn = nil
        MCPWriteControl.answerWithin = run.answerWithin
        remote.change { settings in settings = run.settings }
        for tab in run.tabs {
            if let owner = MCPControl.controller(of: tab) { owner.remove(tab) }
        }
        if let window = run.openedWindow, !window.hasClosed { window.window?.close() }
        // The audit lines still queued are written before the folder goes.
        RemoteAccess.auditQueue.sync {}
        try? manager.removeItem(at: remote.folder)
        try? manager.removeItem(at: run.root)
        let gone = !manager.fileExists(atPath: remote.folder.path) && !manager.fileExists(atPath: run.root.path)
        check(rows.isEmpty && !remote.isOn && remote.settings == run.settings && gone,
              "remote access: at the end no connection is left, it is off with its settings as they were, and its temp folder and the checks' files are gone",
              "\(rows.count) connections, on \(remote.isOn)")
        run.c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: helpers

    fileprivate static func remoteID(_ tab: TerminalTab) -> String { tab.id.uuidString.lowercased() }

    /// The lines the stand-in claude got, in order.
    fileprivate static func remoteAgentLines(_ run: RemoteAccessTestRun) -> [String] {
        guard let text = try? String(contentsOfFile: run.log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Base64url without padding, as PKCE takes it.
    fileprivate static func remoteBase64URL(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        let dashed = base64.replacingOccurrences(of: "+", with: "-")
        return dashed.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func remoteFirstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole), match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    /// A stand-in `claude`: Claude Code's prompt box with an empty input line, and its footer, "? for shortcuts" in its
    /// default mode or "bypass permissions on" while `flag` exists, drawn again only when that changes. Each line it gets
    /// goes to `log`. It doesn't echo, so what it drew stays as it drew it.
    fileprivate static func remoteAgentScript(flag: String, log: String) -> String {
        let rule = String(repeating: "─", count: 44)
        let blank = String(repeating: " ", count: 42)
        let box = "╭\(rule)╮\\n│ >\(blank)│\\n╰\(rule)╯"
        return #"""
        #!/bin/sh
        \#(stopsOnCtrlC)
        stty -echo 2>/dev/null
        shown=''
        while :; do
          if [ -f \#(ShellQuote.quote(flag)) ]; then footer='⏵⏵ bypass permissions on (shift+tab to cycle)'; else footer='? for shortcuts'; fi
          if [ "$footer" != "$shown" ]; then
            printf '\033[2J\033[H⏺ Done. The tests pass.\n\n\#(box)\n  %s' "$footer"
            shown=$footer
          fi
          if IFS= read -r -t 1 line; then printf '%s\n' "$line" >> \#(ShellQuote.quote(log)); fi
        done

        """#
    }
}

/// What one run of the checks made and holds: its folder with the stand-ins and the zsh config, the project's window,
/// the tabs and windows it opened, and what to put back at the end.
@MainActor
private final class RemoteAccessTestRun {
    let c: TerminalWindowController
    let proj: URL
    /// The checks' own folder, removed at the end.
    let root: URL
    /// The stand-in claude's folder, first on the PATH of the checks' tabs.
    let bin: URL
    /// The checks' own zsh config.
    let zdot: URL
    /// A folder outside every open project.
    let outside: URL
    /// While it exists, the stand-in claude shows the bypass footer.
    let flag: String
    /// The lines the stand-in claude got.
    let log: String
    /// Written by the stand-in tailscale as it starts.
    let marker: String
    let tailscale: String
    let settings: RemoteAccess.Settings
    let answerWithin: TimeInterval
    var pc: TerminalWindowController?
    /// The project's window, when the checks opened it.
    var openedWindow: TerminalWindowController?
    var agent: TerminalTab?
    var shell: TerminalTab?
    var busy: TerminalTab?
    var tabs: [TerminalTab] = []
    var windows: [NSWindowController] = []

    private init(_ c: TerminalWindowController, proj: URL, root: URL) {
        self.c = c
        self.proj = proj
        self.root = root
        bin = root.appendingPathComponent("bin", isDirectory: true)
        zdot = root.appendingPathComponent("zdot", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        flag = root.appendingPathComponent("bypass").path
        log = root.appendingPathComponent("claude-got.txt").path
        marker = root.appendingPathComponent("tailscale-started").path
        tailscale = root.appendingPathComponent("tailscale").path
        settings = RemoteAccess.shared.settings
        answerWithin = MCPWriteControl.answerWithin
    }

    /// The run with its folder, its zsh config (whose PATH puts the stand-in claude first) and the stand-ins written; nil
    /// when they can't be.
    static func make(_ c: TerminalWindowController, proj: URL) -> RemoteAccessTestRun? {
        let manager = FileManager.default
        let temp = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory()), isDirectory: true)
        let root = temp.appendingPathComponent("nextterm-remote-checks-\(getpid())", isDirectory: true)
        let run = RemoteAccessTestRun(c, proj: proj, root: root)
        try? manager.removeItem(at: run.root)
        do {
            try manager.createDirectory(at: run.bin, withIntermediateDirectories: true)
            try manager.createDirectory(at: run.outside, withIntermediateDirectories: true)
            guard IsolatedShellConfig.prepare(run.zdot) else { throw CocoaError(.fileWriteUnknown) }
            let zshrc: String = IsolatedShellConfig.zshrc(in: run.zdot.path) + "PATH=" + ShellQuote.quote(run.bin.path) + ":$PATH\n"
            try zshrc.write(to: run.zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            let claude = run.bin.appendingPathComponent("claude").path
            try SelfTest.remoteAgentScript(flag: run.flag, log: run.log).write(toFile: claude, atomically: true, encoding: .utf8)
            let tailscale = "#!/bin/sh\n: > " + ShellQuote.quote(run.marker) + "\nexec /bin/sleep 600\n"
            try tailscale.write(toFile: run.tailscale, atomically: true, encoding: .utf8)
            guard chmod(claude, 0o755) == 0, chmod(run.tailscale, 0o755) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        } catch {
            try? manager.removeItem(at: run.root)
            return nil
        }
        return run
    }
}

/// A connection the checks paired: its grant, its name, its client and its tokens.
private struct RemoteAccessPaired {
    let grant: String
    let name: String
    let client: String
    let access: String
    let refresh: String
}

/// The door as a client reaches it through a tunnel: requests to 127.0.0.1 at its port with the public hostname in their
/// Host header, each on a connection of its own.
@MainActor
private final class RemoteAccessDoorClient {
    let port: UInt16
    let host: String
    private var lastID = 100

    init(port: UInt16, host: String) {
        self.port = port
        self.host = host
    }

    /// One request, with this client's Host unless `host` gives another: the door's whole answer, or nil when none came
    /// within `seconds`.
    func request(_ method: String, _ target: String, host: String? = nil, headers: [(String, String)] = [], body: String = "",
                 within seconds: Double = 15) async -> RemoteAccessDoorAnswer? {
        var text = "\(method) \(target) HTTP/1.1\r\nHost: \(host ?? self.host)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if method == "POST" { text += "Content-Length: \(Data(body.utf8).count)\r\n" }
        text += "\r\n" + body
        let link = RemoteAccessDoorLink(port: port)
        defer { link.close() }
        link.send(text)
        _ = await SelfTest.wait(seconds) { RemoteAccessDoorAnswer.read(link.received, ended: link.ended) != nil }
        return RemoteAccessDoorAnswer.read(link.received, ended: link.ended)
    }

    func postJSON(_ target: String, _ object: [String: Any]) async -> RemoteAccessDoorAnswer? {
        await request("POST", target, headers: [("Content-Type", "application/json")], body: Self.json(object))
    }

    func postForm(_ target: String, _ items: [(String, String)]) async -> RemoteAccessDoorAnswer? {
        await request("POST", target, headers: [("Content-Type", "application/x-www-form-urlencoded")], body: Self.form(items))
    }

    /// A JSON-RPC request to /mcp as a vendor's client sends it: with its token, the protocol version and, for `stream`,
    /// an Accept that takes an event stream.
    func mcp(_ method: String, _ params: [String: Any]?, token: String?, version: String = "2025-06-18", stream: Bool = false,
             within seconds: Double = 15) async -> RemoteAccessDoorAnswer? {
        lastID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": lastID, "method": method]
        if let params { message["params"] = params }
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        headers.append(("Accept", stream ? "application/json, text/event-stream" : "application/json"))
        headers.append(("MCP-Protocol-Version", version))
        if let token { headers.append(("Authorization", "Bearer \(token)")) }
        return await request("POST", "/mcp", headers: headers, body: Self.json(message), within: seconds)
    }

    func call(_ tool: String, _ arguments: [String: Any], token: String, stream: Bool = false,
              within seconds: Double = 30) async -> RemoteAccessDoorCall {
        let answer = await mcp("tools/call", ["name": tool, "arguments": arguments], token: token, stream: stream, within: seconds)
        return RemoteAccessDoorCall(answer)
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A query or a form body, every character but the unreserved ones escaped.
    static func form(_ items: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs: [String] = items.map { (name: String, value: String) -> String in
            let key = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return key + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }
        return pairs.joined(separator: "&")
    }
}

/// One answer from the door: its status, its headers by lowercased name, and its body.
private struct RemoteAccessDoorAnswer {
    let status: Int
    let headers: [String: String]
    let body: Data

    var text: String { String(decoding: body, as: UTF8.self) }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }

    /// The JSON-RPC message: the body's, or for a stream its last event's that carries an id.
    var message: [String: Any]? {
        guard header("content-type")?.hasPrefix("text/event-stream") == true else { return json }
        let lines: [String] = text.components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }
        for line in lines.reversed() {
            let parsed = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
            if let object = parsed as? [String: Any], object["id"] != nil { return object }
        }
        return nil
    }

    /// The whole answer in `data`, or nil while some of it is still to come: as much body as its length says, or for an
    /// answer without one (a stream, a refusal) everything until the door closed the connection.
    static func read(_ data: Data, ended: Bool) -> RemoteAccessDoorAnswer? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        let lines: [String] = head.components(separatedBy: "\r\n")
        let words: [Substring] = lines.first?.split(separator: " ") ?? []
        guard words.count >= 2, let status = Int(words[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[split.upperBound...])
        if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard body.count >= length else { return nil }
            body = body.prefix(length)
        } else if !ended {
            return nil
        }
        return RemoteAccessDoorAnswer(status: status, headers: headers, body: body)
    }
}

/// A tool call's answer: the result's text and whether it is an error, or a JSON-RPC error's code and message.
private struct RemoteAccessDoorCall {
    var text = ""
    var isError = true
    var code: Int?
    var answer: RemoteAccessDoorAnswer?

    init(_ answer: RemoteAccessDoorAnswer?) {
        self.answer = answer
        guard let message = answer?.message else {
            text = "(no answer: \(answer.map { "status \($0.status)" } ?? "nothing in time"))"
            return
        }
        if let error = message["error"] as? [String: Any] {
            code = error["code"] as? Int
            text = error["message"] as? String ?? ""
            return
        }
        let result = message["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        text = content?.first?["text"] as? String ?? ""
        isError = result?["isError"] as? Bool ?? true
    }

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }
}

/// One connection to the door: what it sends, everything that comes back, and whether the door closed it.
private final class RemoteAccessDoorLink: @unchecked Sendable { // `data` and `closed` live on `queue`
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "selftest.remote-access.link")
    private var data = Data()
    private var closed = false

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed = true
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, error in
            guard let self else { return }
            if let chunk { self.data.append(chunk) }
            if done || error != nil {
                self.closed = true
                return
            }
            self.receive()
        }
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    var received: Data { queue.sync { data } }
    var ended: Bool { queue.sync { closed } }

    func close() { connection.cancel() }
}

/// The stand-in Funnel's answers: `tailscale status --json` for a Mac named `name` that may use Funnel on port 443, and
/// `tailscale funnel status --json` with the door's share once the stand-in child has started (its marker file), or a
/// share sent to another service while `elsewhere` is set. Read on the tunnel's own queues.
private final class RemoteAccessFunnelStandIn: @unchecked Sendable { // `routed` lives under `lock`
    let name: String
    let port: Int
    let marker: String
    private let lock = NSLock()
    private var routed = false

    init(name: String, port: Int, marker: String) {
        self.name = name
        self.port = port
        self.marker = marker
    }

    var elsewhere: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return routed
        }
        set {
            lock.lock()
            routed = newValue
            lock.unlock()
        }
    }

    func status() -> Data? {
        let names: [String] = ["https", "funnel", "https://tailscale.com/cap/funnel-ports?ports=443"]
        var capabilities: [String: Any] = [:]
        for capability in names { capabilities[capability] = NSNull() }
        let me: [String: Any] = ["DNSName": name + ".", "CapMap": capabilities]
        let root: [String: Any] = ["BackendState": "Running", "Self": me]
        return try? JSONSerialization.data(withJSONObject: root)
    }

    func share() -> Data? {
        guard FileManager.default.fileExists(atPath: marker) else { return Data("{}".utf8) }
        let key = "\(name):443"
        let service = elsewhere ? "http://127.0.0.1:3000" : RemoteAccessTunnelConfig.doorAddress(port: port)
        var config: [String: Any] = [:]
        config["TCP"] = ["443": ["HTTPS": true]]
        config["Web"] = [key: ["Handlers": ["/": ["Proxy": service]]]]
        config["AllowFunnel"] = [key: true]
        let root: [String: Any] = ["Foreground": ["selftest": config]]
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
#endif
