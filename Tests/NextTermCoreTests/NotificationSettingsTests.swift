import Foundation
import Testing
@testable import NextTermCore

@Suite struct NotificationSettingsTests {
    let decision = TabNotice(state: .attention, command: "claude", program: "claude", kind: .agent, stillRunning: true,
                             question: "Do you want to make this edit to a.txt?")
    let bell = TabNotice(state: .attention, command: "make", program: "make", kind: .command, stillRunning: true,
                         duration: .infinity, fromProgram: true)
    let login = TabNotice(state: .attention, command: "ssh web-1", program: "ssh", kind: .interactive, stillRunning: true,
                          duration: .infinity)

    func agentDone(after seconds: TimeInterval) -> TabNotice {
        TabNotice(state: .done, command: "claude", program: "claude", kind: .agent, stillRunning: true, duration: seconds)
    }

    func command(_ state: TabState, after seconds: TimeInterval) -> TabNotice {
        TabNotice(state: state, command: "make test", program: "make", kind: .command, stillRunning: false, duration: seconds)
    }

    /// Whether `notice` notifies: in another app, and in Next Term with the tab out of sight.
    func outside(_ settings: NotificationSettings, _ notice: TabNotice) -> Bool {
        settings.shouldNotify(notice, appActive: false, tabVisible: false)
    }

    func inside(_ settings: NotificationSettings, _ notice: TabNotice) -> Bool {
        settings.shouldNotify(notice, appActive: true, tabVisible: false)
    }

    @Test func defaults() {
        let s = NotificationSettings()
        #expect(s.decisions && s.agentFinished && s.sound && s.programAlerts)
        #expect(s.commands == .inAnotherApp && s.threshold == .fiveSeconds)
        // The shortest choice is what TabStatus itself waits for: a notice shorter than that never comes.
        #expect(WorkThreshold.allCases.map(\.seconds).min() == TabStatus.notifyAfter)
        #expect(WorkThreshold.allCases.map(\.title) == ["5 seconds", "30 seconds", "1 minute", "5 minutes"])
        #expect(CommandNotifications.allCases.map(\.title) == ["Only when I’m in another app", "Always, for tabs I’m not looking at", "Never"])
    }

    @Test func topics() {
        #expect(decision.topic == .decision)
        #expect(agentDone(after: 10).topic == .agentFinished)
        // An agent that exited (claude -p) or failed is still the agent setting's.
        #expect(TabNotice(state: .failed, command: "claude -p x", program: "claude", kind: .agent, stillRunning: false).topic == .agentFinished)
        #expect(command(.done, after: 10).topic == .commandFinished)
        #expect(command(.failed, after: 10).topic == .commandFinished)
        #expect(bell.topic == .programAlert)
        #expect(login.topic == .otherAlert)
    }

    @Test func neverForTheTabOnScreen() {
        var s = NotificationSettings()
        s.commands = .always
        for notice in [decision, agentDone(after: 600), command(.failed, after: 600), bell, login] {
            #expect(!s.shouldNotify(notice, appActive: true, tabVisible: true))
        }
    }

    @Test func decisionsComeAnywhereUnlessTurnedOff() {
        var s = NotificationSettings()
        s.threshold = .fiveMinutes // a decision has no duration: the threshold is not for it
        #expect(inside(s, decision) && outside(s, decision))
        s.decisions = false
        #expect(!inside(s, decision) && !outside(s, decision))
        // Turning it off leaves finished agents alone.
        #expect(inside(s, agentDone(after: 600)))
    }

    @Test func agentsFinishingNotifyInNextTermToo() {
        var s = NotificationSettings()
        #expect(inside(s, agentDone(after: 10)) && outside(s, agentDone(after: 10)))
        #expect(!inside(s, agentDone(after: 4)) && !outside(s, agentDone(after: 4)))
        s.agentFinished = false
        #expect(!inside(s, agentDone(after: 600)) && !outside(s, agentDone(after: 600)))
        // Turning it off leaves decisions alone.
        #expect(inside(s, decision))
    }

    @Test func commandsByDefaultOnlyFromAnotherApp() {
        var s = NotificationSettings()
        for state in [TabState.done, .failed] {
            #expect(!inside(s, command(state, after: 10)) && outside(s, command(state, after: 10)))
        }
        s.commands = .always
        #expect(inside(s, command(.done, after: 10)) && outside(s, command(.failed, after: 10)))
        s.commands = .never
        #expect(!inside(s, command(.done, after: 600)) && !outside(s, command(.failed, after: 600)))
        // The command setting is not the agents'.
        #expect(inside(s, agentDone(after: 10)))
    }

    @Test func thresholdAppliesToFinishedWorkOnly() {
        var s = NotificationSettings()
        s.commands = .always
        s.threshold = .thirtySeconds
        #expect(!inside(s, agentDone(after: 29)) && inside(s, agentDone(after: 30)))
        #expect(!outside(s, command(.failed, after: 29)) && outside(s, command(.failed, after: 30)))
        s.threshold = .oneMinute
        #expect(!inside(s, agentDone(after: 59)) && inside(s, agentDone(after: 60)))
        s.threshold = .fiveMinutes
        #expect(!outside(s, command(.done, after: 299)) && outside(s, command(.done, after: 300)))
        #expect(inside(s, decision) && outside(s, bell))
    }

    @Test func programAlertsFromAnotherAppUnlessTurnedOff() {
        var s = NotificationSettings()
        #expect(outside(s, bell) && !inside(s, bell)) // in Next Term, the amber mark says it
        s.programAlerts = false
        #expect(!outside(s, bell))
        // ssh asking for a password is Next Term's own call, not the program's bell.
        #expect(outside(s, login) && !inside(s, login))
    }

    @Test func soundIsOnlyASetting() {
        var s = NotificationSettings()
        s.sound = false
        #expect(inside(s, decision) && inside(s, agentDone(after: 10)))
    }

    @Test func readFromTheDefaults() throws {
        let name = "nextterm-notification-tests-\(getpid())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(NotificationSettings(defaults: defaults) == NotificationSettings())
        // As Settings › Notifications saves them.
        defaults.set(false, forKey: NotificationSettings.Key.decisions)
        defaults.set(false, forKey: NotificationSettings.Key.agentFinished)
        defaults.set(CommandNotifications.always.rawValue, forKey: NotificationSettings.Key.commands)
        defaults.set(WorkThreshold.oneMinute.rawValue, forKey: NotificationSettings.Key.threshold)
        defaults.set(false, forKey: NotificationSettings.Key.sound)
        defaults.set(false, forKey: NotificationSettings.Key.programAlerts)
        var expected = NotificationSettings()
        expected.decisions = false
        expected.agentFinished = false
        expected.commands = .always
        expected.threshold = .oneMinute
        expected.sound = false
        expected.programAlerts = false
        #expect(NotificationSettings(defaults: defaults) == expected)
        // Something that is not one of the choices reads as the default.
        defaults.set("sometimes", forKey: NotificationSettings.Key.commands)
        defaults.set(42, forKey: NotificationSettings.Key.threshold)
        let read = NotificationSettings(defaults: defaults)
        #expect(read.commands == .inAnotherApp && read.threshold == .fiveSeconds)
        #expect(Set(NotificationSettings.Key.all).count == 6)
    }
}

@Suite struct TabNoticeTopicTests {
    @Test func statusSaysWhereANoticeCameFrom() {
        var s = TabStatus()
        s.commandStarted("make", at: 0)
        s.commandFinished(exitCode: 2, at: 40)
        let failed = s.takeNotice()
        #expect(failed?.topic == .commandFinished && failed?.duration == 40)

        var agent = TabStatus()
        agent.commandStarted("claude", at: 0)
        agent.observe(agentScreen: .working, at: 1)
        agent.observe(agentScreen: .asking("Which approach should I take?"), at: 3)
        #expect(agent.takeNotice()?.topic == .decision)
        agent.observe(agentScreen: .working, at: 4)
        agent.observe(agentScreen: .idle, at: 64)
        agent.tick(at: 65)
        let done = agent.takeNotice()
        #expect(done?.topic == .agentFinished && done?.duration == 60)

        var ssh = TabStatus()
        ssh.needsAttention()
        let login = ssh.takeNotice()
        #expect(login?.state == .attention && login?.topic == .otherAlert)
        ssh.bell()
        #expect(ssh.takeNotice() == nil) // already amber: one notice until it is seen
    }
}
