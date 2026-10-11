import Foundation
import Testing
@testable import NextTermCore

/// Settings › Remote Access and its status item (U11), as pure code: the guided mode's recommendation and steps,
/// the connections table's rows with the Control mark, the status item's words and its count of the last hour's
/// calls, the activity view's rows, and the fixed texts.
@Suite struct RemoteAccessSettingsModelTests {
    typealias Guide = RemoteAccessGuide
    typealias Facts = RemoteAccessGuide.Facts
    typealias Kind = RemoteAccessTunnelConfig.Kind
    typealias Problem = RemoteAccessTunnelConfig.TailscaleProblem
    typealias Grant = RemoteAccessOAuth.Grant
    typealias Row = RemoteAccessConnectionRow
    typealias Entry = RemoteAccessAuditEntry

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let host = "mcp.example.com"

    /// A Mac with nothing set up.
    static let bare = Facts()

    /// A value another thread sets.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Value?

        var value: Value? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return held
            }
            set {
                lock.lock()
                held = newValue
                lock.unlock()
            }
        }
    }

    static func grant(_ id: String, name: String = "Claude, phone", options: RemoteAccessOptions = .readOnly,
                      host: String = host, created: Date = now.addingTimeInterval(-3600),
                      lastUsed: Date? = nil) -> Grant {
        Grant(id: id, name: name, clientID: "client-\(id)", clientName: "Claude", redirectHost: "claude.ai",
              options: options, host: host, created: created, lastUsed: lastUsed ?? created)
    }

    // MARK: guided mode (R49)

    @Test func loggedInTailscaleWithFunnelIsRecommendedFirst() {
        var facts = Self.bare
        facts.tailscale = .installed
        facts.tailscaleStatus = .success("mac.tail1234.ts.net")
        facts.cloudflared = .installed
        facts.tokenSaved = true
        facts.servers = 1
        #expect(Guide.recommendation(facts) == .funnel)
        #expect(Guide.needs(.funnel, facts) == nil)
    }

    @Test func cloudflaredWithASavedTokenComesNext() {
        var facts = Self.bare
        facts.tailscale = .installed
        facts.tailscaleStatus = .failure(.notLoggedIn)
        facts.cloudflared = .installed
        facts.tokenSaved = true
        facts.servers = 1
        #expect(Guide.recommendation(facts) == .cloudflare)
        #expect(Guide.needs(.funnel, facts) == Problem.notLoggedIn.message)
    }

    @Test func aSavedServerAloneIsYourOwnServer() {
        var facts = Self.bare
        facts.servers = 1
        #expect(Guide.recommendation(facts) == .ownServer)
        // cloudflared without a token is not ready.
        facts.servers = 0
        facts.cloudflared = .installed
        #expect(Guide.recommendation(facts) == nil)
    }

    @Test func advancedIsNeverRecommended() {
        var facts = Self.bare
        facts.host = Self.host
        #expect(Guide.recommendation(facts) == nil)
        #expect(Guide.needs(.advanced, facts) != nil)
    }

    @Test func nothingReadyListsAllFourWithWhatEachNeeds() {
        let choices = Guide.choices(Self.bare)
        #expect(choices.map(\.kind) == [.funnel, .cloudflare, .ownServer, .advanced])
        #expect(choices.allSatisfy { $0.needs != nil })
        #expect(choices[0].needs == RemoteAccessTunnelConfig.Tool.tailscale.installHint)
        #expect(choices[1].needs == RemoteAccessTunnelConfig.Tool.cloudflared.missing)
        #expect(choices[2].needs?.contains("File › New Remote Tab…") == true)
        #expect(Kind.allCases.count == 4)
    }

    @Test func anOldCloudflaredNeedsAnUpdateAndATokenComesAfter() {
        var facts = Self.bare
        facts.cloudflared = .tooOld
        facts.tokenSaved = true
        #expect(Guide.needs(.cloudflare, facts) == RemoteAccessTunnelConfig.updateCloudflared)
        facts.cloudflared = .installed
        facts.tokenSaved = false
        #expect(Guide.needs(.cloudflare, facts)?.contains("token") == true)
    }

    @Test func tailscaleNotReadYetSaysItCantBeRead() {
        var facts = Self.bare
        facts.tailscale = .installed
        #expect(Guide.needs(.funnel, facts) == Problem.unreadable.message)
    }

    @Test func eachChoiceSaysWhyItIsRecommended() {
        for kind in [Kind.funnel, .cloudflare, .ownServer] {
            #expect(!Guide.why(kind).isEmpty)
        }
    }

    @Test func funnelStepsGoOneAtATime() {
        var facts = Self.bare
        var steps = Guide.steps(.funnel, facts, port: 41000)
        #expect(steps.count == 4)
        #expect(Guide.current(steps) == 0)
        facts.tailscale = .installed
        facts.tailscaleStatus = .failure(.notLoggedIn)
        steps = Guide.steps(.funnel, facts, port: 41000)
        #expect(Guide.current(steps) == 1)
        #expect(steps[1].detail.contains(Problem.notLoggedIn.message))
        facts.tailscaleStatus = .failure(.funnelOff)
        steps = Guide.steps(.funnel, facts, port: 41000)
        #expect(Guide.current(steps) == 2)
        #expect(steps[2].detail.contains(Problem.funnelOff.message))
        facts.tailscaleStatus = .success("mac.tail1234.ts.net")
        steps = Guide.steps(.funnel, facts, port: 41000)
        #expect(Guide.current(steps) == 3)
        facts.on = true
        #expect(Guide.current(Guide.steps(.funnel, facts, port: 41000)) == nil)
    }

    @Test func cloudflareStepsNameTheLoopbackServiceAndTheToken() {
        var facts = Self.bare
        facts.cloudflared = .installed
        let steps = Guide.steps(.cloudflare, facts, port: 41234)
        #expect(Guide.current(steps) == 1)
        #expect(steps[1].detail.contains("http://127.0.0.1:41234"))
        #expect(!steps[1].detail.contains("localhost:"))
        facts.tokenSaved = true
        #expect(Guide.current(Guide.steps(.cloudflare, facts, port: 41234)) == 3)
        facts.on = true
        // On, with no host confirmed yet, the last step still waits.
        #expect(Guide.current(Guide.steps(.cloudflare, facts, port: 41234)) == 3)
        facts.host = Self.host
        #expect(Guide.current(Guide.steps(.cloudflare, facts, port: 41234)) == nil)
    }

    @Test func ownServerStepsWaitForTheServerTheHostnameAndCaddy() {
        var facts = Self.bare
        #expect(Guide.current(Guide.steps(.ownServer, facts, port: nil)) == 0)
        facts.servers = 2
        #expect(Guide.current(Guide.steps(.ownServer, facts, port: nil)) == 1)
        facts.serverChosen = true
        facts.host = Self.host
        #expect(Guide.current(Guide.steps(.ownServer, facts, port: nil)) == 2)
        facts.caddyTyped = true
        #expect(Guide.current(Guide.steps(.ownServer, facts, port: nil)) == 3)
    }

    @Test func advancedStepsShowTheLocalAddress() {
        var facts = Self.bare
        facts.host = Self.host
        let steps = Guide.steps(.advanced, facts, port: 41234)
        #expect(Guide.current(steps) == 1)
        #expect(steps[1].detail.contains("https://mcp.example.com"))
        #expect(steps[1].detail.contains("http://127.0.0.1:41234"))
    }

    // MARK: the connections table (R15, R22)

    @Test func rowsShowNameClientPresetAndTimes() {
        let used = Self.now.addingTimeInterval(-300)
        let rows = Row.rows([Self.grant("a", lastUsed: used)], host: Self.host, now: Self.now)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.name == "Claude, phone")
        #expect(row.client == "claude.ai")
        #expect(row.clientWords == "Claude")
        #expect(row.presetTitle == "Read only")
        #expect(!row.isControl)
        #expect(row.lastUsed == "5 min ago")
        #expect(row.expires == "In 14 days")
    }

    @Test func aControlRowCarriesTheMarkWithNotificationsOffToo() {
        var quiet = RemoteAccessOptions.control
        quiet[.notify] = false
        let rows = Row.rows([Self.grant("a", options: .control), Self.grant("b", options: quiet)], host: Self.host,
                            now: Self.now)
        #expect(rows.allSatisfy { $0.isControl && $0.presetTitle == "Control" })
        var asking = RemoteAccessOptions.control
        asking[.askOnMac] = true
        let custom = Row(Self.grant("c", options: asking), now: Self.now)
        #expect(custom.presetTitle == "Custom")
        #expect(!custom.isControl)
    }

    @Test func oneBoxOutsideChecksChangedIsCustom() {
        var options = RemoteAccessOptions.readOnly
        options[.everyKey] = true
        #expect(Row(Self.grant("a", options: options), now: Self.now).presetTitle == "Custom")
    }

    @Test func rowsLeaveOutOtherHostsAndEndedGrantsNewestFirst() {
        let old = Self.grant("old", created: Self.now.addingTimeInterval(-7200))
        let new = Self.grant("new", created: Self.now.addingTimeInterval(-60))
        let elsewhere = Self.grant("elsewhere", host: "other.example.com")
        let ended = Self.grant("ended", created: Self.now.addingTimeInterval(-91 * 86_400),
                               lastUsed: Self.now.addingTimeInterval(-86_400))
        let rows = Row.rows([old, elsewhere, new, ended], host: Self.host, now: Self.now)
        #expect(rows.map(\.id) == ["new", "old"])
        #expect(Row.rows([old], host: nil, now: Self.now).isEmpty)
        #expect(Row.rows([old], host: "MCP.Example.com", now: Self.now).map(\.id) == ["old"])
    }

    @Test func aGrantNeverUsedSaysNotYet() {
        #expect(Row(Self.grant("a"), now: Self.now).lastUsed == "Not yet")
    }

    // MARK: times

    @Test func agoTexts() {
        typealias Time = RemoteAccessTimeText
        #expect(Time.ago(Self.now.addingTimeInterval(-20), now: Self.now) == "Just now")
        #expect(Time.ago(Self.now.addingTimeInterval(-60), now: Self.now) == "1 min ago")
        #expect(Time.ago(Self.now.addingTimeInterval(-3 * 3600 - 10), now: Self.now) == "3 h ago")
        #expect(Time.ago(Self.now.addingTimeInterval(-30 * 3600), now: Self.now) == "Yesterday")
        #expect(Time.ago(Self.now.addingTimeInterval(-5 * 86_400), now: Self.now) == "5 days ago")
        // A clock that went back reads as now.
        #expect(Time.ago(Self.now.addingTimeInterval(30), now: Self.now) == "Just now")
    }

    @Test func untilTexts() {
        typealias Time = RemoteAccessTimeText
        #expect(Time.until(Self.now.addingTimeInterval(-1), now: Self.now) == "Ended")
        #expect(Time.until(Self.now.addingTimeInterval(20), now: Self.now) == "In 1 min")
        #expect(Time.until(Self.now.addingTimeInterval(90 * 60), now: Self.now) == "In 2 h")
        #expect(Time.until(Self.now.addingTimeInterval(86_400 + 60), now: Self.now) == "In 1 day")
        #expect(Time.until(Self.now.addingTimeInterval(14 * 86_400 - 5), now: Self.now) == "In 14 days")
    }

    @Test func countdownText() {
        #expect(RemoteAccessSettingsText.pairingCountdown(seconds: 599) == "Pairing closes in 9:59")
        #expect(RemoteAccessSettingsText.pairingCountdown(seconds: 5) == "Pairing closes in 0:05")
        #expect(RemoteAccessSettingsText.pairingCountdown(seconds: -3) == "Pairing closes in 0:00")
    }

    // MARK: the status item (R37)

    @Test func indicatorWords() {
        typealias Indicator = RemoteAccessIndicator
        #expect(Indicator(.on) == .on)
        #expect(Indicator(.on).word == "On")
        #expect(Indicator(.reconnecting).word == "Reconnecting")
        #expect(Indicator(.connecting) == .connecting)
        #expect(Indicator(.starting) == .connecting)
        #expect(Indicator(.waitingForKeychain) == .waiting)
        #expect(Indicator(.confirmHost(Self.host)) == .waiting)
        #expect(Indicator(.off).word == "Off")
        #expect(Indicator(.stopped("x")) == .off)
        #expect(Indicator(.portBusy(41000)) == .off)
    }

    @Test func statusItemListsControlConnectionsAndTheCount() {
        let rows = Row.rows([Self.grant("a", name: "Phone", options: .control), Self.grant("b")], host: Self.host,
                            now: Self.now)
        var status = RemoteAccessStatus()
        _ = status.handle(.turnOn(RemoteAccessStatus.Start(tunnel: .advanced, host: Self.host, port: .saved(41000),
                                                           agentControl: true, scopeCheck: nil, launch: false)))
        _ = status.handle(.bound)
        let model = RemoteAccessStatusItemModel(status: status, rows: rows, calls: 12)
        #expect(model.visible)
        #expect(model.indicator == .on)
        #expect(model.controls.map(\.name) == ["Phone"])
        #expect(model.hasControlMark)
        #expect(model.title == "Remote access: On")
        #expect(model.callsText == "12 calls in the last hour")
        #expect(model.toolTip.contains("12 calls in the last hour"))
        #expect(model.toolTip.contains("Control"))
        #expect(RemoteAccessStatusItemModel.revokeTitle("Phone") == "Revoke “Phone”")
    }

    @Test func statusItemHidesWhileOffAndCountsInWords() {
        let model = RemoteAccessStatusItemModel(status: RemoteAccessStatus(), rows: [], calls: 0)
        #expect(!model.visible)
        #expect(!model.hasControlMark)
        #expect(model.callsText == "No calls in the last hour")
        #expect(RemoteAccessStatusItemModel(status: RemoteAccessStatus(), rows: [], calls: 1).callsText
            == "1 call in the last hour")
    }

    @Test func callCountKeepsTheLastHour() {
        var count = RemoteAccessCallCount()
        for second in stride(from: 0, to: 600, by: 10) { count.note(at: Self.now.addingTimeInterval(TimeInterval(second))) }
        #expect(count.count(at: Self.now.addingTimeInterval(600)) == 60)
        #expect(count.count(at: Self.now.addingTimeInterval(1800)) == 60)
        #expect(count.count(at: Self.now.addingTimeInterval(3600 + 700)) == 0)
        count.note(at: Self.now.addingTimeInterval(5000))
        #expect(count.count(at: Self.now.addingTimeInterval(5000)) == 1)
        #expect(count.buckets <= 61)
    }

    // MARK: the activity view (R39)

    @Test func callRowsSayWhatHappened() {
        let grant = Self.grant("a")
        let allowed = Entry.call(time: Self.now, grant: grant, tool: "list_tabs", arguments: [:], decision: .allowed)
        #expect(Entry.callEvent == allowed.event)
        let row = RemoteAccessActivityRow(allowed)
        #expect(row.connection == "Claude, phone")
        #expect(row.what == "Ran list_tabs")
        #expect(!row.problem)
        let refused = Entry.call(time: Self.now, grant: grant, tool: "send_to_tab", arguments: ["text": "ls"],
                                 decision: .refused, reason: "This connection can't use send_to_tab.")
        let refusedRow = RemoteAccessActivityRow(refused)
        #expect(refusedRow.what == "Refused send_to_tab: This connection can't use send_to_tab.")
        #expect(refusedRow.problem)
        #expect(refusedRow.detail.contains("ls"))
        let declined = Entry.call(time: Self.now, grant: grant, tool: "close_tab", arguments: nil, decision: .declined)
        #expect(RemoteAccessActivityRow(declined).what == "Declined close_tab on this Mac")
    }

    @Test func eventRowsUseWords() {
        let changed = Entry.event(.optionsChanged(grantID: "a", name: "Phone", old: .readOnly, new: .control),
                                  time: Self.now)
        #expect(RemoteAccessActivityRow(changed).what == "Options changed: Read only to Control")
        let revoked = Entry.event(.revoked(grantID: "a", name: "Phone", reason: .onMac), time: Self.now)
        #expect(RemoteAccessActivityRow(revoked).what == "Revoked on this Mac")
        let reused = Entry.event(.revoked(grantID: "a", name: "Phone", reason: .refreshReuse), time: Self.now)
        #expect(RemoteAccessActivityRow(reused).problem)
        let approved = Entry.event(.pairingApproved(request: "r", grantID: "a", name: "Phone", options: .control),
                                   time: Self.now)
        #expect(RemoteAccessActivityRow(approved).what == "Allowed as Control")
        #expect(RemoteAccessActivityRow(Entry.turnedOff(revokeAll: true, time: Self.now)).what
            == "Turned off, and every connection revoked")
        let tunnel = Entry.tunnel("ready", detail: "not managed by Next Term", time: Self.now)
        #expect(RemoteAccessActivityRow(tunnel).what == "Tunnel: ready")
        #expect(RemoteAccessActivityRow(tunnel).detail == "not managed by Next Term")
        var summed = Entry(time: Self.now, event: "requests.refused")
        summed.kind = "wrong_host"
        summed.count = 7
        summed.first = "evil.example"
        #expect(RemoteAccessActivityRow(summed).what == "7 requests refused: wrong host")
        #expect(RemoteAccessActivityRow(summed).detail == "evil.example")
        #expect(RemoteAccessActivityRow(Entry(time: Self.now, event: "something.new")).what == "something.new")
    }

    // MARK: the door's state, as Settings reads it

    @Test func theDoorListsItsActiveGrants() throws {
        let door = RemoteAccessDoorStateTests.Door()
        #expect(door.state.grants.isEmpty)
        let paired = try RemoteAccessDoorStateTests.pair(door, options: .control)
        #expect(door.state.grants.map(\.id) == [paired.grant.id])
        #expect(door.state.grants.first?.options == .control)
        try door.state.revoke(grant: paired.grant.id)
        #expect(door.state.grants.isEmpty)
        #expect(RemoteAccessDoorStateTests.Door(host: nil).state.grants.isEmpty)
    }

    @Test func theDoorCountsTheLastHoursCalls() throws {
        let door = RemoteAccessDoorStateTests.Door()
        let grant = Self.grant("a")
        let time = door.clock.now
        let calls = (0..<3).map { _ in
            Entry.call(time: time, grant: grant, tool: "list_tabs", arguments: nil, decision: .allowed)
        }
        door.state.audit(calls)
        door.state.audit([Entry.tunnel("ready", time: time)])
        door.state.countRefusal(.wrongHost, request: nil)
        #expect(door.state.callsInLastHour == 3)
        door.clock.advance(3700)
        #expect(door.state.callsInLastHour == 0)
    }

    @Test func theActivityReadsAndClearsTheLogOnTheDoorsQueue() throws {
        let door = RemoteAccessDoorStateTests.Door()
        door.state.audit([Entry.tunnel("started", time: door.clock.now), Entry.tunnel("ready", time: door.clock.now)])
        let read = Box<[Entry]>()
        let done = DispatchSemaphore(value: 0)
        door.state.readAudit { entries in
            read.value = entries
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(read.value?.compactMap(\.reason) == ["started", "ready"])
        let cleared = Box<Bool>()
        door.state.clearAudit { error in
            cleared.value = error == nil
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(cleared.value == true)
        #expect(door.lines().isEmpty)
    }

    // MARK: texts

    @Test func leakNoticeIsThePlansWords() {
        let notice = "A connected chat can read your open projects. Its options decide what else it can do. With "
            + "Control, anything it sends can run commands on this Mac with your permissions, without asking. Text "
            + "in a tab or a file can trick it into sending what it reads somewhere else."
        #expect(RemoteAccessSettingsText.leakNotice == notice)
    }

    @Test func editReasonNamesTheConnection() {
        #expect(RemoteAccessSettingsText.editReason(name: "Claude") == "change what “Claude” can do in Next Term")
    }

    @Test func cloudflareChecklistNamesTheFourChecks() {
        let list = RemoteAccessSettingsText.cloudflareChecklist(port: 41234).joined(separator: "\n")
        #expect(list.contains("http://127.0.0.1:41234"))
        #expect(list.contains("not localhost"))
        #expect(list.contains("Bot Fight Mode"))
        #expect(list.contains("Access"))
        #expect(list.contains("first level"))
    }

    @Test func otherTexts() {
        #expect(RemoteAccessSettingsText.connectorURL(host: Self.host) == "https://mcp.example.com/mcp")
        #expect(RemoteAccessSettingsText.useOtherHost("x.ts.net") == "Use x.ts.net (ends every connection)")
        #expect(RemoteAccessSettingsText.leakedTokenSteps.count == 4)
        #expect(RemoteAccessSettingsText.leakedTokenSteps.last?.contains("Revoke All") == true)
        #expect(RemoteAccessSettingsText.lidNote.contains("external display"))
    }
}
