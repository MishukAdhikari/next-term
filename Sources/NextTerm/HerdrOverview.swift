import AppKit
import NextTermCore

/// herdr's agents on a connected host where no tab shows herdr: a host kept with herdr whose tabs here are tmux or plain
/// ones. The connection's own status check asks herdr's default session (RemotePoller, only where herdr runs or a tab
/// once found it), and this follows the answer as a herdr tab would: its agents go in Go to Agent under "web-2 (no herdr
/// tab)", count in the Dock badge, and post their notices. Nothing more runs for it, and it ends with the connection, or
/// once a herdr tab on the host takes over.
final class HerdrOverview {
    let host: RemoteHost
    /// The connection it rides on.
    let path: String
    private(set) var watch = HerdrWatch()
    private(set) var tracker = HerdrAgents()
    /// The owner of its notices (AppDelegate.herdrDelivered).
    var owner: String { "host:" + host.id }

    init(host: RemoteHost, path: String) {
        self.host = host
        self.path = path
    }

    /// The id of one of its agents' notices, and of its Go to Agent item's target.
    func noticeID(_ pane: String) -> String { owner + "/" + pane }

    /// Where it is, for the badge and Go to Agent, which count an agent once: the host and herdr's default session, as a
    /// herdr tab of that session says it.
    var place: String { "\(host.id) " }

    /// One check's report: each agent followed, its decisions and finishes posted, and notices that are out of date
    /// withdrawn. No agent is on screen: there is no tab to see it in.
    func apply(_ report: HerdrReport) {
        guard let listed = watch.observe(report, showsHerdr: true) else {
            if watch.agents == nil, !tracker.agents.isEmpty {
                tracker = HerdrAgents()
                AppDelegate.shared.withdrawHerdrNotices(owner: owner)
            }
            return
        }
        let events = tracker.update(TerminalTab.masked(listed), focusedTab: nil, tabVisible: false, now: TerminalTab.now)
        for event in events {
            switch event {
            case .needsDecision(let pane):
                post(pane, decision: true, duration: nil)
            case .finished(let pane, let duration):
                post(pane, decision: false, duration: duration)
            case .needsRead, .resolved, .gone:
                break
            }
        }
        AppDelegate.shared.withdrawStaleHerdrNotices(owner: owner, tracker: tracker)
    }

    /// herdr's words for a decision (its pane is not read here: that needs a herdr tab), or a finish.
    private func post(_ pane: String, decision: Bool, duration: TimeInterval?) {
        guard let agent = tracker.agents.first(where: { $0.paneID == pane }) else { return }
        let question = decision ? "\(agent.name) (\(pane)) needs a decision" : nil
        AppDelegate.shared.post(overviewAgent: agent, question: question, duration: duration, overview: self)
    }

    /// It ends: the connection closed, or a herdr tab took over.
    func end() {
        AppDelegate.shared.withdrawHerdrNotices(owner: owner)
    }
}
