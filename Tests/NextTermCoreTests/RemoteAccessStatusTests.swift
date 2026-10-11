import Foundation
import Testing
@testable import NextTermCore

/// Remote access's lifecycle (U9): the status reducer from events to a phase and effects, the port picked at first
/// turn-on, the pid record a leftover tunnel is matched with at launch, and what keeps the Mac awake.
@Suite struct RemoteAccessStatusTests {
    typealias Status = RemoteAccessStatus
    typealias Event = RemoteAccessStatus.Event
    typealias Effect = RemoteAccessStatus.Effect
    typealias Kind = RemoteAccessTunnelConfig.Kind

    static let port: UInt16 = 41234
    static let host = "mcp.example.com"

    // MARK: helpers

    static func start(_ tunnel: Kind? = .cloudflare, host: String? = host,
                      port: RemoteAccessPort.Choice? = .saved(port), agentControl: Bool = true,
                      scopeCheck: String? = nil, launch: Bool = false) -> Status.Start {
        Status.Start(tunnel: tunnel, host: host, port: port, agentControl: agentControl, scopeCheck: scopeCheck,
                     launch: launch)
    }

    /// A status run through `events`, with every effect they gave, in order.
    static func run(_ events: [Event], from status: Status = Status()) -> (Status, [Effect]) {
        var status = status
        var effects: [Effect] = []
        for event in events { effects += status.handle(event) }
        return (status, effects)
    }

    /// Cloudflare with a saved host, on.
    static func on(_ tunnel: Kind = .cloudflare, host: String? = host) -> Status {
        var events: [Event] = [.turnOn(start(tunnel, host: host))]
        if tunnel == .cloudflare { events.append(.token(.found)) }
        events.append(.bound)
        if tunnel.runsTunnel { events.append(.ready(host: host)) }
        let (status, _) = run(events)
        return status
    }

    static let closing: [Effect] = [.closeDoor, .dropTokens(revokeAll: false), .stopTunnel]

    // MARK: happy

    @Test func switchOnBoundStartedReadyGivesOn() {
        var status = Status()
        #expect(status.phase == .off)
        #expect(status.handle(.turnOn(Self.start())) == [.saveOn, .readToken(interactive: false)])
        #expect(status.phase == .starting)
        #expect(status.handle(.token(.found)) == [.bindDoor(Self.port)])
        #expect(status.phase == .starting)
        #expect(status.handle(.bound) == [.audit(tunnel: "started", detail: nil), .startTunnel])
        #expect(status.phase == .connecting)
        #expect(status.handle(.ready(host: Self.host)) == [.audit(tunnel: "ready", detail: nil)])
        #expect(status.phase == .on)
        #expect(status.isOn)
        #expect(status.doorOpen)
    }

    @Test func turnOffFromOnClosesTheDoorStopsTheTunnelAndDropsTokens() {
        var status = Self.on()
        let effects = status.handle(.turnOff(revokeAll: false))
        #expect(status.phase == .off)
        #expect(!status.isOn)
        #expect(effects == Self.closing + [.saveOff])
        #expect(status.problem == nil)
    }

    @Test func turnOffAndRevokeAllEndsEveryGrant() {
        var status = Self.on()
        let effects = status.handle(.turnOff(revokeAll: true))
        #expect(effects == [.closeDoor, .dropTokens(revokeAll: true), .stopTunnel, .saveOff])
    }

    @Test func turningOffAgainDoesNothing() {
        var status = Self.on()
        _ = status.handle(.turnOff(revokeAll: false))
        #expect(status.handle(.turnOff(revokeAll: false)) == [])
        #expect(status.phase == .off)
    }

    @Test func funnelNeedsNoTokenAndSavesItsHostWithoutAsking() {
        var status = Status()
        #expect(status.handle(.turnOn(Self.start(.funnel, host: nil))) == [.saveOn, .bindDoor(Self.port)])
        _ = status.handle(.bound)
        #expect(status.phase == .connecting)
        let tailnet = "mac.tailnet-0000.ts.net"
        #expect(status.handle(.ready(host: tailnet)) == [.saveHost(tailnet), .audit(tunnel: "ready", detail: nil)])
        #expect(status.phase == .on)
        #expect(status.host == tailnet)
    }

    @Test func advancedIsOnOnceTheDoorIsBound() {
        var status = Status()
        #expect(status.handle(.turnOn(Self.start(.advanced))) == [.saveOn, .bindDoor(Self.port)])
        let detail = "not managed by Next Term"
        #expect(status.handle(.bound) == [.audit(tunnel: "ready", detail: detail)])
        #expect(status.phase == .on)
        #expect(status.text == RemoteAccessTunnelConfig.advancedStatus(port: Int(Self.port)))
    }

    @Test func aRelaunchWithItSavedOnTellsTheMacOnceItIsOn() {
        let (status, effects) = Self.run([.turnOn(Self.start(launch: true)), .token(.found), .bound,
                                          .ready(host: Self.host)])
        #expect(status.phase == .on)
        #expect(effects.last == .notify(.on(host: Self.host)))
        let notices = effects.filter { if case .notify = $0 { return true } else { return false } }
        #expect(notices.count == 1)
        // Ready again after a drop tells nobody.
        let (_, later) = Self.run([.notReady, .ready(host: Self.host)], from: status)
        #expect(later == [.audit(tunnel: "reconnecting", detail: nil), .audit(tunnel: "ready", detail: nil)])
    }

    @Test func aSwitchTurnedOnTellsNobody() {
        let (_, effects) = Self.run([.turnOn(Self.start()), .token(.found), .bound, .ready(host: Self.host)])
        #expect(!effects.contains { if case .notify = $0 { return true } else { return false } })
    }

    @Test func onDropsToReconnectingAndBack() {
        var status = Self.on()
        #expect(status.handle(.notReady) == [.audit(tunnel: "reconnecting", detail: nil)])
        #expect(status.phase == .reconnecting)
        #expect(status.isOn)
        #expect(status.handle(.notReady) == [])
        #expect(status.handle(.ready(host: Self.host)) == [.audit(tunnel: "ready", detail: nil)])
        #expect(status.phase == .on)
    }

    // MARK: edge

    @Test func aBindFailureGivesPortBusyAndStartsNoTunnel() {
        let (status, effects) = Self.run([.turnOn(Self.start(.funnel)), .bindFailed(portInUse: true, reason: "busy")])
        #expect(status.phase == .portBusy(Self.port))
        #expect(status.text == "Port 41234 is in use")
        #expect(!effects.contains(.startTunnel))
        #expect(!status.isOn)
        #expect(!status.doorOpen)
    }

    @Test func portBusyIsDismissedToOff() {
        var status = Self.run([.turnOn(Self.start(.funnel)), .bindFailed(portInUse: true, reason: "busy")]).0
        #expect(status.handle(.dismiss) == [.saveOff])
        #expect(status.phase == .off)
    }

    @Test func anotherBindFailureIsOffWithItsReason() {
        let reason = "The door could not start: no port"
        let (status, effects) = Self.run([.turnOn(Self.start(.funnel)), .bindFailed(portInUse: false, reason: reason)])
        #expect(status.phase == .off)
        #expect(status.problem == reason)
        #expect(status.text == reason)
        #expect(effects.last == .saveOff)
        #expect(!effects.contains(.startTunnel))
    }

    @Test func aRouteChangeFromReconnectingGivesStopped() {
        var status = Self.on()
        _ = status.handle(.notReady)
        let reason = "The tunnel no longer sends mcp.example.com to http://127.0.0.1:41234."
        let effects = status.handle(.routeChanged(reason))
        #expect(status.phase == .stopped(reason))
        #expect(status.text == reason)
        #expect(!status.isOn)
        let expected: [Effect] = [.audit(tunnel: "stopped", detail: reason)] + Self.closing
            + [.saveOff, .notify(.stopped(reason))]
        #expect(effects == expected)
        #expect(status.handle(.dismiss) == [.saveOff])
        #expect(status.phase == .off)
    }

    @Test func aRouteChangeFromOnGivesStopped() {
        var status = Self.on()
        _ = status.handle(.routeChanged("route"))
        #expect(status.phase == .stopped("route"))
    }

    @Test func theDoorFailingStopsLikeARouteChange() {
        var status = Self.on()
        let effects = status.handle(.doorFailed("The door stopped."))
        #expect(status.phase == .stopped("The door stopped."))
        #expect(effects.contains(.closeDoor))
        #expect(effects.contains(.stopTunnel))
        #expect(effects.contains(.saveOff))
    }

    @Test func agentControlOffFromAnyStateGivesOffAndSavesOff() {
        let open: [Status] = [Self.on(), Self.run([.notReady], from: Self.on()).0,
                              Self.run([.turnOn(Self.start()), .token(.found), .bound]).0,
                              Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound,
                                        .ready(host: Self.host)]).0]
        for var status in open {
            #expect(status.doorOpen)
            #expect(status.handle(.agentControlOff) == Self.closing + [.saveOff])
            #expect(status.phase == .off)
        }
        let closed: [Status] = [Status(), Self.run([.turnOn(Self.start())]).0,
                                Self.run([.turnOn(Self.start()), .token(.needsPermission)]).0,
                                Self.run([.turnOn(Self.start(.funnel)), .bindFailed(portInUse: true, reason: "")]).0,
                                Self.run([.routeChanged("route")], from: Self.on()).0]
        for var status in closed {
            #expect(status.handle(.agentControlOff) == [.saveOff])
            #expect(status.phase == .off)
        }
    }

    @Test func itCanStartOnlyWhileAgentControlIsOn() {
        var status = Status()
        let effects = status.handle(.turnOn(Self.start(agentControl: false)))
        #expect(status.phase == .off)
        #expect(status.problem == Status.agentControlNeeded)
        #expect(effects == [.saveOff])
    }

    @Test func aFailedScopeCheckKeepsItOffWithTheReason() {
        var status = Status()
        let reason = "Remote access can't start: this version of Next Term tags read_tab as acting on the Mac."
        let effects = status.handle(.turnOn(Self.start(scopeCheck: reason)))
        #expect(status.phase == .off)
        #expect(status.problem == reason)
        #expect(!effects.contains(.bindDoor(Self.port)))
        #expect(!effects.contains(.readToken(interactive: false)))
    }

    @Test func aStartWithNoTunnelHostOrPortIsRefused() {
        var status = Status()
        _ = status.handle(.turnOn(Self.start(nil)))
        #expect(status.problem == Status.tunnelNeeded)
        _ = status.handle(.turnOn(Self.start(.advanced, host: nil)))
        #expect(status.problem == Status.hostNeeded)
        _ = status.handle(.turnOn(Self.start(.ownServer, host: nil)))
        #expect(status.problem == Status.hostNeeded)
        _ = status.handle(.turnOn(Self.start(port: nil)))
        #expect(status.problem == Status.noFreePort)
        #expect(status.phase == .off)
    }

    @Test func aRefusedLaunchSaysSoOnTheMac() {
        var status = Status()
        let effects = status.handle(.turnOn(Self.start(nil, launch: true)))
        #expect(effects == [.saveOff, .notify(.didNotStart(Status.tunnelNeeded))])
    }

    @Test func aProblemClearsOnTheNextStart() {
        var status = Status()
        _ = status.handle(.turnOn(Self.start(nil)))
        #expect(status.problem != nil)
        _ = status.handle(.turnOn(Self.start()))
        #expect(status.problem == nil)
        #expect(status.phase == .starting)
    }

    @Test func turningOnWhileOnDoesNothing() {
        var status = Self.on()
        #expect(status.handle(.turnOn(Self.start())) == [])
        #expect(status.phase == .on)
    }

    @Test func turningOnFromPortBusyOrStoppedStartsAgain() {
        var busy = Self.run([.turnOn(Self.start(.funnel)), .bindFailed(portInUse: true, reason: "")]).0
        #expect(busy.handle(.turnOn(Self.start(.funnel))) == [.saveOn, .bindDoor(Self.port)])
        var stopped = Self.run([.routeChanged("route")], from: Self.on()).0
        _ = stopped.handle(.turnOn(Self.start()))
        #expect(stopped.phase == .starting)
    }

    @Test func eventsOutOfTurnChangeNothing() {
        var status = Status()
        for event: Event in [.bound, .ready(host: Self.host), .notReady, .token(.found), .allowKeychainAccess,
                             .confirmHost, .declineHost, .routeChanged("x"), .doorFailed("x"), .dismiss,
                             .tunnelFailed("x"), .bindFailed(portInUse: true, reason: "")] {
            #expect(status.handle(event) == [])
            #expect(status.phase == .off)
        }
        var on = Self.on()
        for event: Event in [.bound, .token(.found), .allowKeychainAccess, .confirmHost, .declineHost, .dismiss,
                             .bindFailed(portInUse: true, reason: "")] {
            #expect(on.handle(event) == [])
            #expect(on.phase == .on)
        }
    }

    @Test func aTunnelThatCantRunTurnsItOffWithTheReason() {
        var status = Self.run([.turnOn(Self.start()), .token(.found), .bound]).0
        let reason = "Update cloudflared to 2025.4.0 or later."
        let effects = status.handle(.tunnelFailed(reason))
        #expect(status.phase == .off)
        #expect(status.problem == reason)
        #expect(effects == [.audit(tunnel: "stopped", detail: reason)] + Self.closing + [.saveOff])
        let launched = Self.run([.turnOn(Self.start(launch: true)), .token(.found), .bound, .tunnelFailed(reason)])
        #expect(launched.1.last == .notify(.didNotStart(reason)))
        let busy = Self.run([.turnOn(Self.start(.funnel, launch: true)), .bindFailed(portInUse: true, reason: "")])
        #expect(busy.1.last == .notify(.didNotStart("Port 41234 is in use")))
    }

    // MARK: Confirm Host

    @Test func cloudflareReadyWithNoSavedHostAsksToConfirmIt() {
        var status = Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound]).0
        #expect(status.handle(.ready(host: Self.host)) == [])
        #expect(status.phase == .confirmHost(Self.host))
        #expect(status.doorOpen)
        #expect(status.isOn)
        #expect(status.handle(.confirmHost) == [.saveHost(Self.host), .audit(tunnel: "ready", detail: nil)])
        #expect(status.phase == .on)
        #expect(status.host == Self.host)
    }

    @Test func cloudflareReadyWithNoHostYetKeepsConnecting() {
        var status = Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound]).0
        #expect(status.handle(.ready(host: nil)) == [])
        #expect(status.phase == .connecting)
    }

    @Test func turningOffFromConfirmHostGivesOff() {
        var status = Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound, .ready(host: Self.host)]).0
        #expect(status.handle(.turnOff(revokeAll: false)) == Self.closing + [.saveOff])
        #expect(status.phase == .off)
    }

    @Test func decliningTheHostGivesOff() {
        var status = Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound, .ready(host: Self.host)]).0
        #expect(status.handle(.declineHost) == Self.closing + [.saveOff])
        #expect(status.phase == .off)
        #expect(status.host == nil)
    }

    @Test func aSavedHostNeedsNoConfirming() {
        let status = Self.run([.turnOn(Self.start()), .token(.found), .bound, .ready(host: "other.example.com")]).0
        #expect(status.phase == .on)
        #expect(status.host == Self.host)
    }

    // MARK: the Keychain

    @Test func aSilentReadThatWouldAskGivesWaitingForKeychain() {
        var status = Self.run([.turnOn(Self.start())]).0
        #expect(status.handle(.token(.needsPermission)) == [])
        #expect(status.phase == .waitingForKeychain)
        #expect(status.text == Status.keychainNeeded)
        #expect(status.isOn)
        #expect(!status.doorOpen)
    }

    @Test func allowKeychainAccessReadsAgainWithThePromptAndStartsAgain() {
        var status = Self.run([.turnOn(Self.start()), .token(.needsPermission)]).0
        #expect(status.handle(.allowKeychainAccess) == [.readToken(interactive: true)])
        #expect(status.phase == .waitingForKeychain)
        #expect(status.handle(.token(.found)) == [.bindDoor(Self.port)])
        #expect(status.phase == .starting)
    }

    @Test func aCanceledPromptKeepsWaiting() {
        var status = Self.run([.turnOn(Self.start()), .token(.needsPermission), .allowKeychainAccess]).0
        #expect(status.handle(.token(.canceled)) == [])
        #expect(status.phase == .waitingForKeychain)
    }

    @Test func turningOffFromWaitingForKeychainGivesOff() {
        var status = Self.run([.turnOn(Self.start()), .token(.needsPermission)]).0
        #expect(status.handle(.turnOff(revokeAll: false)) == [.saveOff])
        #expect(status.phase == .off)
    }

    @Test func turnOffAndRevokeAllBeforeTheDoorOpensStillEndsEveryGrant() {
        var status = Self.run([.turnOn(Self.start()), .token(.needsPermission)]).0
        #expect(status.handle(.turnOff(revokeAll: true)) == [.saveOff, .dropTokens(revokeAll: true)])
        var off = Status()
        #expect(off.handle(.turnOff(revokeAll: true)) == [.dropTokens(revokeAll: true)])
    }

    @Test func aMissingOrUnreadableTokenIsOffWithWhy() {
        var status = Self.run([.turnOn(Self.start())]).0
        #expect(status.handle(.token(.missing)) == [.saveOff])
        #expect(status.phase == .off)
        #expect(status.problem == Status.tokenNeeded)
        _ = status.handle(.turnOn(Self.start()))
        _ = status.handle(.token(.failed("The Keychain could not read the tunnel token.")))
        #expect(status.problem == "The Keychain could not read the tunnel token.")
    }

    // MARK: quit

    @Test func quitClosesTheDoorAndWaitsForTheTunnelWithoutSavingOff() {
        var status = Self.on()
        let effects = status.handle(.quit)
        #expect(effects == [.closeDoor, .dropTokens(revokeAll: false), .stopTunnelNow])
        #expect(!effects.contains(.saveOff))
        #expect(status.phase == .off)
    }

    @Test func quitWhileOffStillEndsATunnelStoppingOnItsTimers() {
        var status = Self.run([.turnOff(revokeAll: false)], from: Self.on()).0
        #expect(status.handle(.quit) == [.stopTunnelNow])
        var waiting = Self.run([.turnOn(Self.start()), .token(.needsPermission)]).0
        #expect(waiting.handle(.quit) == [.stopTunnelNow])
        #expect(waiting.phase == .off)
    }

    // MARK: texts

    @Test func eachPhaseSaysWhereItIs() {
        #expect(Status().text == "Off")
        #expect(Self.run([.turnOn(Self.start())]).0.text == "Starting…")
        #expect(Self.run([.turnOn(Self.start()), .token(.found), .bound]).0.text == "Connecting…")
        #expect(Self.on().text == "On at mcp.example.com")
        #expect(Self.run([.notReady], from: Self.on()).0.text == "Reconnecting…")
        let confirm = Self.run([.turnOn(Self.start(host: nil)), .token(.found), .bound, .ready(host: Self.host)]).0
        #expect(confirm.text == "Confirm mcp.example.com as the public hostname.")
        #expect(Status.keychainNeeded == "Allow Keychain access to turn Remote access on")
        #expect(Status.updateNote == "Remote access stops until Next Term reopens.")
    }

    @Test func noticesHaveATitleAndABody() {
        let on = Status.Notice.on(host: Self.host)
        #expect(on.title == "Remote access is on")
        #expect(on.body.contains(Self.host))
        #expect(Status.Notice.stopped("route").title == "Remote access stopped")
        #expect(Status.Notice.stopped("route").body == "route")
        #expect(Status.Notice.didNotStart("why").title == "Remote access didn't start")
    }

    // MARK: the port (R2)

    @Test func theFirstTurnOnPicksAFreePortInRangeAndSavesIt() {
        let busy: Set<UInt16> = [44000, 44001, 44002]
        let choice = RemoteAccessPort.choose(saved: nil, isFree: { !busy.contains($0) }, random: { _ in 4000 })
        #expect(choice == .picked(44003))
        var status = Status()
        let effects = status.handle(.turnOn(Self.start(.funnel, port: choice)))
        #expect(effects == [.savePort(44003), .saveOn, .bindDoor(44003)])
        #expect(status.port == 44003)
    }

    @Test func aLaterStartReusesTheSavedPortEvenWhenBusyAndNeverPicksAgain() {
        var asked: [UInt16] = []
        let choice = RemoteAccessPort.choose(saved: 41234, isFree: { asked.append($0); return false },
                                             random: { _ in 0 })
        #expect(choice == .saved(41234))
        #expect(asked.isEmpty)
        var status = Status()
        #expect(status.handle(.turnOn(Self.start(.funnel, port: choice))) == [.saveOn, .bindDoor(41234)])
    }

    @Test func thePickWrapsAroundTheRangeAndNeverLeavesIt() {
        var asked: [UInt16] = []
        let last = RemoteAccessPort.range.upperBound
        let choice = RemoteAccessPort.choose(saved: nil, isFree: { asked.append($0); return $0 == 40000 },
                                             random: { $0 - 1 })
        #expect(choice == .picked(40000))
        #expect(asked == [last, 40000])
        var everyPort: [UInt16] = []
        let none = RemoteAccessPort.choose(saved: nil, isFree: { everyPort.append($0); return false },
                                           random: { _ in 123 })
        #expect(none == nil)
        #expect(everyPort.count == 9000)
        #expect(Set(everyPort).count == 9000)
        #expect(everyPort.allSatisfy { RemoteAccessPort.range.contains($0) })
    }

    @Test func aRandomValueOutOfBoundsStillPicksInRange() {
        for value in [-5, 9000, 1_000_000] {
            let choice = RemoteAccessPort.choose(saved: nil, isFree: { _ in true }, random: { _ in value })
            #expect(choice.map { RemoteAccessPort.range.contains($0.port) } == true)
        }
        let zero = RemoteAccessPort.choose(saved: 0, isFree: { _ in true }, random: { _ in 0 })
        #expect(zero == .picked(40000))
    }

    @Test func picksSpreadOverTheRange() {
        var seen = Set<UInt16>()
        for _ in 0..<50 {
            if let choice = RemoteAccessPort.choose(saved: nil, isFree: { _ in true }) { seen.insert(choice.port) }
        }
        #expect(seen.count > 1)
        #expect(seen.allSatisfy { RemoteAccessPort.range.contains($0) })
    }

    // MARK: the pid record (R42)

    typealias Record = RemoteAccessPidRecord
    static let childStart = Record.Start(seconds: 1_800_000_000, microseconds: 123_456)
    static let ownerStart = Record.Start(seconds: 1_799_999_000, microseconds: 7)
    static let record = Record(pid: 4321, start: childStart, path: "/opt/homebrew/Cellar/cloudflared/bin/cloudflared",
                               owner: 1234, ownerStart: ownerStart)

    @Test func theRecordIsWrittenOwnerOnlyAndReadBack() throws {
        let folder = RemoteAccessStoreTests.Folder()
        #expect(Record.read(in: folder.url) == nil)
        try Self.record.write(in: folder.url)
        #expect(Record.read(in: folder.url) == Self.record)
        #expect(RemoteAccessStoreTests.mode(folder.file(Record.fileName)) == 0o600)
        #expect(RemoteAccessStoreTests.mode(folder.url) == 0o700)
        Record.delete(in: folder.url)
        #expect(Record.read(in: folder.url) == nil)
        #expect(folder.names().isEmpty)
    }

    @Test func anUnreadableRecordReadsAsNone() throws {
        let folder = RemoteAccessStoreTests.Folder()
        try folder.make()
        try Data("{\"pid\": \"x\"".utf8).write(to: folder.file(Record.fileName))
        #expect(Record.read(in: folder.url) == nil)
    }

    @Test func aLeftoverIsEndedOnlyWhenItsPidStartAndPathMatchAndItsNextTermIsGone() {
        let same = Record.Seen(start: Self.childStart, path: Self.record.path)
        #expect(Self.record.cleanup(seen: same, ownerRunning: false) == .end)
        // Another Next Term that still runs keeps its tunnel and its record.
        #expect(Self.record.cleanup(seen: same, ownerRunning: true) == .keep)
        // The process is gone: only the record goes.
        #expect(Self.record.cleanup(seen: nil, ownerRunning: false) == .forget)
        // The pid is another process now: it is left alone.
        let later = Record.Start(seconds: Self.childStart.seconds + 1, microseconds: Self.childStart.microseconds)
        #expect(Self.record.cleanup(seen: Record.Seen(start: later, path: Self.record.path), ownerRunning: false)
                == .forget)
        let micro = Record.Start(seconds: Self.childStart.seconds, microseconds: 0)
        #expect(Self.record.cleanup(seen: Record.Seen(start: micro, path: Self.record.path), ownerRunning: false)
                == .forget)
        #expect(Self.record.cleanup(seen: Record.Seen(start: Self.childStart, path: "/bin/sleep"), ownerRunning: false)
                == .forget)
        #expect(Self.record.cleanup(seen: Record.Seen(start: Self.childStart, path: nil), ownerRunning: false)
                == .forget)
    }

    // MARK: sleep (R41)

    @Test func onPowerTheMacStaysAwakeAndOnBatteryOnlyAppNapIsAvoided() {
        #expect(RemoteAccessAwake.activity(onPower: true, keepAwakeOnBattery: false) == .noIdleSleep)
        #expect(RemoteAccessAwake.activity(onPower: true, keepAwakeOnBattery: true) == .noIdleSleep)
        #expect(RemoteAccessAwake.activity(onPower: false, keepAwakeOnBattery: false) == .noAppNap)
        #expect(RemoteAccessAwake.activity(onPower: false, keepAwakeOnBattery: true) == .noIdleSleep)
    }
}
