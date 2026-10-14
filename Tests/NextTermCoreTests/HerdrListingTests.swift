import Foundation
import Testing
@testable import NextTermCore

/// herdr's list of agents, in every shape herdr has printed it: fixtures in Fixtures/herdr, written by hand from
/// herdr's schema at each version (0.4.0's pane list to 0.9.4's agent list), never copied from a real host.
@Suite struct HerdrListingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/herdr")

    func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    func agents(_ listing: HerdrListing) -> [HerdrAgent]? {
        guard case .agents(let agents) = listing else { return nil }
        return agents
    }

    @Test func herdr094ListsEveryAgentWithItsTitleAndForegroundFolder() throws {
        let listed = try #require(agents(HerdrAgent.listing(output: try fixture("agent-list-0.9.4.json"), exit: 0)))
        #expect(listed.map(\.paneID) == ["w1:p1", "w1:p2", "w2:p1"])
        #expect(listed.map(\.status) == [.working, .blocked, .done])
        // The name it was given, else the agent's; the title without its spinner; the folder in front.
        #expect(listed.map(\.name) == ["api", "codex", "gemini"])
        #expect(listed[0].title == "Fix the login" && listed[0].directory == "/home/me/api/src")
        #expect(listed[1].directory == "/home/me/web" && listed[2].directory == nil)
    }

    @Test func herdr070AndItsCustomStatusRead() throws {
        let listed = try #require(agents(HerdrAgent.listing(output: try fixture("agent-list-0.7.0.json"))))
        #expect(listed == [HerdrAgent(paneID: "w1:p1", name: "Claude Code", status: .idle, title: "Refactor the poller",
                                      directory: "/srv/app/api")])
    }

    @Test func herdr0510sMinimalShapeAndOldPaneIDsRead() throws {
        let listed = try #require(agents(HerdrAgent.listing(output: try fixture("agent-list-0.5.10.json"))))
        #expect(listed == [HerdrAgent(paneID: "1-1", name: "claude", status: .working, directory: "/home/me/app")])
    }

    @Test func anEmptyListIsAnAnswer() throws {
        let empty = try fixture("agent-list-empty.json")
        #expect(HerdrAgent.listing(output: empty, exit: 0) == .agents([]))
        // Empty output is not: herdr always prints JSON when it answers.
        #expect(HerdrAgent.listing(output: "", exit: 0) == .failed("herdr printed nothing"))
        #expect(HerdrAgent.listing(output: "   ", exit: 1) == .failed("herdr printed nothing (exit 1)"))
    }

    @Test func noServerAndAProtocolMismatchAreSaidInHerdrsWords() throws {
        let gone = HerdrAgent.listing(output: try fixture("server-not-running.json"), exit: 1)
        guard case .notRunning(let said) = gone else { Issue.record("\(gone)"); return }
        #expect(said.contains("/home/me/.config/herdr/herdr.sock"))
        let upgraded = HerdrAgent.listing(output: try fixture("protocol-mismatch.json"), exit: 1)
        guard case .needsRestart(let why) = upgraded else { Issue.record("\(upgraded)"); return }
        #expect(why.contains("restart the Herdr server"))
        // Another code, a bare string, no message.
        #expect(HerdrAgent.listing(output: #"{"error":{"code":"bad_request","message":"no such pane"}}"#) == .failed("bad_request: no such pane"))
        #expect(HerdrAgent.listing(output: #"{"error":"boom"}"#) == .failed("boom"))
        #expect(HerdrAgent.listing(output: #"{"error":{"code":"server_not_running"}}"#) == .notRunning("no herdr server is running"))
    }

    @Test func herdrBefore080SaidNoServerAsAnIOError() throws {
        let said = HerdrAgent.listing(output: try fixture("io-error-0.7.txt"), exit: 1)
        guard case .notRunning(let text) = said else { Issue.record("\(said)"); return }
        #expect(text.hasPrefix("Error: Os"))
        let refused = HerdrAgent.listing(output: #"Error: Os { code: 111, kind: ConnectionRefused, message: "Connection refused" }"#, exit: 1)
        guard case .notRunning = refused else { Issue.record("\(refused)"); return }
        let displayed = HerdrAgent.listing(output: "Error: No such file or directory (os error 2)", exit: 1)
        guard case .notRunning = displayed else { Issue.record("\(displayed)"); return }
        // A broken shim's shell saying a file is missing is herdr failing, never "no server".
        let shim = HerdrAgent.listing(output: "/home/me/.asdf/shims/herdr: line 4: /home/me/.asdf/bin/asdf: No such file or directory", exit: 127)
        guard case .failed = shim else { Issue.record("\(shim)"); return }
    }

    @Test func herdrBefore0510HasNoAgentCommandAndItsPaneListIsRead() throws {
        let old = HerdrAgent.listing(output: try fixture("unknown-command-0.4.txt"), exit: 1, command: "agent")
        guard case .failed(let why) = old else { Issue.record("\(old)"); return }
        #expect(why.contains("older than 0.5.10"))
        // The check then asks `pane list`: only the panes with an agent are agents. 0.4.5 says agent_status…
        let v045 = try #require(agents(HerdrAgent.listing(output: try fixture("pane-list-0.4.5.json"), exit: 0, command: "pane")))
        #expect(v045 == [HerdrAgent(paneID: "w64e95948145ed1-1", name: "claude", status: .done, directory: "/home/me/app")])
        // …and 0.4.0 agent_state, with no `done` yet.
        let v040 = try #require(agents(HerdrAgent.listing(output: try fixture("pane-list-0.4.0.json"), exit: 0, command: "pane")))
        #expect(v040 == [HerdrAgent(paneID: "1-1", name: "codex", status: .blocked, directory: "/home/me/app")])
    }

    @Test func noiseAroundTheJSONIsReadPast() throws {
        let json = try fixture("agent-list-0.5.10.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = try #require(agents(HerdrAgent.listing(output: json)))
        let noisy = [
            // A version manager's warning first, in colour, with a byte order mark and CRLF.
            "\u{FEFF}\u{1b}[33mmise WARN\u{1b}[0m  herdr@0.9.4 is outdated\r\n" + json + "\r\n",
            // A log line that is JSON too, but not herdr's, and a title sequence.
            #"{"level":"warn","msg":"slow"} "# + "\u{1b}]0;herdr\u{07}" + json,
            // Noise after it, with braces of its own.
            json + " done } ] {",
            // A wrapper's echo glued on, the way the old check's `tr` left it.
            "loading herdr…" + json,
        ]
        for output in noisy {
            #expect(agents(HerdrAgent.listing(output: output, exit: 0)) == expected, "\(output.debugDescription)")
        }
    }

    @Test func prettyPrintedJSONReads() throws {
        let listed = try #require(agents(HerdrAgent.listing(output: try fixture("agent-list-pretty.json"))))
        #expect(listed == [HerdrAgent(paneID: "w1:p1", name: "claude", status: .blocked, directory: "/home/me/api")])
    }

    @Test func aCutAnswerIsNeverAPartialList() throws {
        let json = try fixture("agent-list-0.9.4.json")
        let half = String(json.prefix(json.count / 2))
        let cut = HerdrAgent.listing(output: half, exit: 0)
        guard case .failed = cut else { Issue.record("a cut list read as \(cut)"); return }
        // In the check's section: 1 MB (head -c's cap) is a cut answer, and so is a section with no end marker.
        let long = "out\t" + json + String(repeating: " ", count: HerdrReport.outputCap)
        let capped = HerdrReport.parse(section: ["where\t/x/herdr\tknown", "exit\t0\tagent", Substring(long), Substring(RemoteShell.herdrEndMarker)])
        #expect(capped.report.listing == .cut)
        let unended = HerdrReport.parse(section: ["where\t/x/herdr\tknown", "exit\t0\tagent", Substring("out\t" + json)])
        #expect(unended.report.listing == .cut && unended.consumed == 3 && unended.report.path == "/x/herdr")
    }

    @Test func garbageThatExitedZeroIsAFailureMaskedAndCut() {
        #expect(HerdrAgent.listing(output: "Segmentation fault", exit: 0) == .failed("Segmentation fault"))
        guard case .failed(let long) = HerdrAgent.listing(output: String(repeating: "x", count: 5000), exit: 0) else {
            Issue.record("not a failure")
            return
        }
        #expect(long.count == 201 && long.hasSuffix("…"))
    }

    @Test func statusesAreReadInAnyCaseAndUnknownOnesSaySo() {
        let output = #"{"agents":[{"pane_id":"a","agent":"claude","agent_status":"Working"},{"pane_id":"b","agent":"codex","agent_status":"waiting"},{"pane_id":"c","agent":"x","status":" IDLE "},{"pane_id":"d","agent":"y","state":"done"}]}"#
        #expect(agents(HerdrAgent.listing(output: output))?.map(\.status) == [.working, .unknown, .idle, .done])
    }

    @Test func numericIDsReadAndItemsThatAreNotObjectsAreSkipped() {
        let output = #"{"result":{"agents":[{"pane_id":7,"agent":"claude","agent_status":"idle"},"junk",3,null,{"pane_id":true,"terminal_id":"t9","agent_status":"working","label":"build"},{"agent_status":"done"}]}}"#
        let listed = agents(HerdrAgent.listing(output: output))
        #expect(listed?.map(\.paneID) == ["7", "t9", ""])
        #expect(listed?.map(\.name) == ["claude", "build", "agent"])
        // A bare array is a list too.
        #expect(agents(HerdrAgent.listing(output: #"[{"pane_id":"p","agent":"a","agent_status":"idle"}]"#))?.count == 1)
    }

    @Test func fieldsAreCutAndControlCharactersDropped() {
        let long = String(repeating: "n", count: 300)
        let output = #"{"agents":[{"pane_id":"p\u001b[2J","name":""# + long + #"","agent_status":"idle","title":"a\nb"}]}"#
        let agent = agents(HerdrAgent.listing(output: output))?.first
        #expect(agent?.paneID == "p[2J" && agent?.name.count == 80 && agent?.title == "ab")
        // At most 500 agents from one list.
        let many = "{\"agents\":[" + Array(repeating: #"{"pane_id":"p","agent":"a","agent_status":"idle"}"#, count: 600).joined(separator: ",") + "]}"
        #expect(agents(HerdrAgent.listing(output: many))?.count == 500)
    }

    @Test func theSectionsLinesBecomeAReport() throws {
        let json = try fixture("agent-list-0.5.10.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [Substring] = ["where\t/home/me/.local/bin/herdr\tlogin", "exit\t0\tagent", Substring("out\t" + json),
                                  Substring(RemoteShell.herdrEndMarker), "after"]
        let (report, consumed) = HerdrReport.parse(section: lines[...])
        #expect(consumed == 4)
        #expect(report.path == "/home/me/.local/bin/herdr" && report.how == "login")
        #expect(report.listing == .agents([HerdrAgent(paneID: "1-1", name: "claude", status: .working, directory: "/home/me/app")]))
        // The check found no herdr.
        let missing = HerdrReport.parse(section: ["missing\tpath,local-bin", Substring(RemoteShell.herdrEndMarker)])
        #expect(missing.report.listing == .missing && missing.report.path == nil && missing.consumed == 2)
        #expect(missing.report.problem == "herdr was not found on the host")
        // herdr before 0.5.10, asked `pane list` instead.
        let panes = HerdrReport.parse(section: ["where\t/usr/local/bin/herdr\tpath", "exit\t0\tpane",
                                                Substring("out\t" + (try fixture("pane-list-0.4.0.json"))), Substring(RemoteShell.herdrEndMarker)])
        #expect(agents(panes.report.listing)?.first?.status == .blocked)
    }

    @Test func aPollAndASessionsListCarryTheReport() throws {
        let json = try fixture("agent-list-0.9.4.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let section = "\(RemoteShell.herdrMarker)\nwhere\t/opt/herdr\trunning\nexit\t0\tagent\nout\t\(json)\n\(RemoteShell.herdrEndMarker)\n"
        let poll = try #require(RemotePoll.parse("motd\n\(RemoteShell.marker)\na1\tshell\na1\tplain\therdr at /x did not run (herdr --version said: no)\n" + section))
        #expect(poll.tabs["a1"]?.plain == true && poll.tabs["a1"]?.plainReason == "herdr at /x did not run (herdr --version said: no)")
        #expect(poll.herdr?.path == "/opt/herdr" && poll.herdr?.how == "running")
        #expect(agents(poll.herdr?.listing ?? .missing)?.count == 3)
        let listed = try #require(RemoteSession.parseList("\(RemoteShell.marker)\nsession\tnt-x-1\t0\t/srv\tzsh\n" + section))
        #expect(listed.sessions.map(\.name) == ["nt-x-1"])
        #expect(listed.herdr == poll.herdr)
        // A poll whose herdr section never ended (the check's time limit): its tabs still read, herdr's list is cut.
        let timedOut = try #require(RemotePoll.parse("\(RemoteShell.marker)\na1\tshell\n\(RemoteShell.herdrMarker)\nwhere\t/opt/herdr\trunning\n"))
        #expect(timedOut.tabs["a1"]?.foreground?.isShell == true && timedOut.herdr?.listing == .cut)
        // An older check's section (one JSON line, no end) is cut too, never misread.
        let old = try #require(RemoteSession.parseList("\(RemoteShell.marker)\n\(RemoteShell.herdrMarker)\n{\"agents\":[]}\n"))
        #expect(old.herdr?.listing == .cut)
    }
}

/// What a herdr tab makes of each status check.
@Suite struct HerdrWatchTests {
    let agent = HerdrAgent(paneID: "w1:p1", name: "claude", status: .working)

    @Test func herdrsAgentsAreShownWhileItAnswers() {
        var watch = HerdrWatch()
        #expect(watch.observe(HerdrReport(listing: .agents([agent])), showsHerdr: true) == [agent])
        #expect(watch.agents == [agent] && watch.note == nil)
    }

    @Test func threeFailedChecksInARowSayHerdrIsNotAnswering() {
        var watch = HerdrWatch()
        _ = watch.observe(HerdrReport(listing: .agents([agent])), showsHerdr: true)
        // One slow answer (herdr starting, a cut connection) says nothing, and keeps the agents.
        #expect(watch.observe(HerdrReport(listing: .cut), showsHerdr: true) == nil)
        #expect(watch.observe(HerdrReport(listing: .failed("x")), showsHerdr: true) == nil)
        #expect(watch.note == nil && watch.agents == [agent])
        _ = watch.observe(HerdrReport(listing: .failed("herdr printed nothing")), showsHerdr: true)
        #expect(watch.note == "herdr not answering: herdr printed nothing" && watch.agents == nil)
        // It answers again: the note goes.
        _ = watch.observe(HerdrReport(listing: .agents([])), showsHerdr: true)
        #expect(watch.note == nil && watch.failures == 0 && watch.agents == [])
    }

    @Test func aSessionThatIsNotRunningIsNamed() {
        var watch = HerdrWatch()
        for _ in 0..<HerdrWatch.failuresBeforeNote { _ = watch.observe(HerdrReport(listing: .notRunning("no server at /s.sock")), showsHerdr: true) }
        #expect(watch.note == "herdr’s list came from a session that isn’t running (no server at /s.sock)")
    }

    @Test func aNeededRestartIsSaidAtOnceAndNeverDone() {
        var watch = HerdrWatch()
        _ = watch.observe(HerdrReport(listing: .agents([agent])), showsHerdr: true)
        #expect(watch.observe(HerdrReport(listing: .needsRestart("client protocol 7 is newer")), showsHerdr: true) == nil)
        #expect(watch.note == "herdr needs a restart before it can report its agents: client protocol 7 is newer")
        #expect(watch.agents == nil)
    }

    @Test func aTabThatFellBackLearnsWhenHerdrIsThere() {
        var watch = HerdrWatch()
        #expect(watch.observe(HerdrReport(listing: .missing), showsHerdr: false) == nil)
        #expect(watch.note == nil)
        // A copy that doesn't run is not herdr being there.
        _ = watch.observe(HerdrReport(path: "/x/herdr", listing: .failed("boom")), showsHerdr: false)
        #expect(watch.note == nil)
        // It answers (even with no server yet): the user installed it.
        #expect(watch.observe(HerdrReport(path: "/x/herdr", listing: .notRunning("no server")), showsHerdr: false) == nil)
        #expect(watch.note == "herdr is now on the host: open a new herdr tab to use it" && watch.agents == nil)
    }
}
