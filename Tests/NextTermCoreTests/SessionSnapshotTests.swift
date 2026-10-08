import Foundation
import Testing
@testable import NextTermCore

@Suite struct SessionSnapshotTests {
    typealias Snapshot = SessionSnapshot
    typealias Pane = SessionSnapshot.Pane
    typealias Node = SessionSnapshot.Node
    typealias Split = SessionSnapshot.Split
    typealias Group = SessionSnapshot.Group
    typealias Window = SessionSnapshot.Window

    /// A made-up id that reads as its number.
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// Made-up ids for several numbers, typed, so comparisons stay cheap to type-check.
    private func ids(_ numbers: Int...) -> [UUID] { numbers.map(id) }

    private func paneIDs(_ panes: [Pane]) -> [UUID] { panes.map { (pane: Pane) -> UUID in pane.id } }

    private func header(clean: Bool = false) -> Snapshot.Header {
        Snapshot.Header(launchID: id(900), generation: 7, clean: clean, bootSession: "2F6C1D0A-5B4E-4C3D-9A8B-7E6F5D4C3B2A",
                        awaitingMarker: id(901), pendingToVersion: "0.11.0", savedAt: Date(timeIntervalSince1970: 1_790_000_000.25))
    }

    private func pane(_ n: Int, folder: String = "/Users/sam/Projects/garden") -> Pane {
        Pane(id: id(n), folder: folder, lastSelected: Date(timeIntervalSince1970: 1_789_999_000 + Double(n)))
    }

    /// Ids handed out in order, for re-minted panes.
    private final class Minter {
        private var next = 500
        func make() -> UUID {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
        }
    }

    private func decode(_ json: String, limits: Snapshot.Limits = .standard) throws -> Snapshot {
        let minter = Minter()
        return try Snapshot.decode(Data(json.utf8), limits: limits, makeID: minter.make)
    }

    /// A snapshot JSON with one window holding one tab whose tree is `root`.
    private func oneTab(_ root: String, focused: Int = 1, zoomed: Int? = nil, extra: String = "") -> String {
        let zoom = zoomed.map { #","zoomed":"\#(id($0).uuidString)""# } ?? ""
        return """
        {"header":{"schema":1,"launchID":"\(id(900).uuidString)","generation":1,"clean":false,"savedAt":1790000000000},
         "windows":[{"groups":[{"root":\(root),"focused":"\(id(focused).uuidString)"\(zoom)}]\(extra)}]}
        """
    }

    private func paneJSON(_ n: Int) -> String {
        #"{"pane":{"id":"\#(id(n).uuidString)","folder":"/Users/sam/Projects/garden"}}"#
    }

    // MARK: round trips

    @Test func nestedSplitsInBothDirectionsRoundTripExactly() throws {
        var agentPane = pane(2)
        agentPane.userTitle = "reviewer"
        agentPane.command = Snapshot.Command(line: "claude --model opus", check: .kept, source: .integration, running: true)
        agentPane.stateBefore = .working
        agentPane.interrupted = true
        agentPane.agent = Snapshot.Evidence(agent: .claude, sessionID: "0d9c8b7a-6f5e-4d3c-8b2a-1f0e9d8c7b6a", source: .sessionFile,
                                            sessionFolder: "/Users/sam/Projects/garden", executable: "/opt/agents/bin/claude",
                                            interpreter: "/opt/agents/bin/node", script: "/opt/agents/lib/claude/cli.js",
                                            startedAt: Date(timeIntervalSince1970: 1_789_980_000.5),
                                            sessionDate: Date(timeIntervalSince1970: 1_789_990_000), routingMatchesShell: true,
                                            autoContinueOff: true, ranAsTyped: true)
        agentPane.systemZsh = true
        agentPane.scrollback = id(700)
        agentPane.pending = Snapshot.PendingAction(action: .resume, state: .pending, reason: .update)
        var idlePane = pane(3)
        idlePane.command = Snapshot.Command(line: "npm test", check: .kept, source: .integration, running: false, exitCode: 1)
        idlePane.note = Snapshot.Note(reason: .lastCommand, command: idlePane.command, exitCode: 1)
        var remotePane = Pane(id: id(4))
        remotePane.remote = RemoteTabRecord(hostID: "host-1", destination: "deploy@build.example.com", port: 2222,
                                            directory: "/srv/app", session: "nt-4", keep: .tmux, project: "/Users/sam/Projects/garden")
        let inner = Node.split(Split(vertical: false, children: [.pane(idlePane), .pane(pane(5))], dividers: [0.3]))
        let root = Node.split(Split(vertical: true, children: [.pane(agentPane), inner], dividers: [0.62]))
        let window = Window(frame: Snapshot.Frame(x: 120, y: 80.5, width: 1280, height: 800), screen: "display-1",
                            project: "/Users/sam/Projects/garden",
                            groups: [Group(root: .pane(pane(1)), focused: id(1)), Group(root: root, focused: id(3), zoomed: id(2)),
                                     Group(root: .pane(remotePane), focused: id(4))],
                            selected: 1, minimized: false, fullScreen: true)
        let second = Window(groups: [Group(root: .pane(pane(6, folder: "/Users/sam/notes")), focused: id(6))], minimized: true)
        let snapshot = Snapshot(header: header(), windows: [window, second])

        let data = try snapshot.encoded()
        let back = try Snapshot.decode(data)
        #expect(back == snapshot)
        #expect(try back.encoded() == data)
        #expect(paneIDs(back.panes) == ids(1, 2, 3, 5, 4, 6))
    }

    @Test func theFileNameCarriesTheMajorVersion() {
        #expect(Snapshot.fileName() == "state-v\(Snapshot.schema).json")
        #expect(Snapshot.fileName(schema: 2) == "state-v2.json")
        #expect(Snapshot.schema == 1)
    }

    @Test func aTombstoneHoldsOnlyTheHeaderMarkedClean() throws {
        let snapshot = Snapshot(header: header(), windows: [Window(groups: [Group(root: .pane(pane(1)), focused: id(1))])])
        let tombstone = snapshot.tombstone
        #expect(tombstone.header.clean)
        #expect(tombstone.windows.isEmpty)
        #expect(tombstone.header.launchID == snapshot.header.launchID)
        let text = String(decoding: try tombstone.encoded(), as: UTF8.self)
        #expect(!text.contains("windows"))
        #expect(try Snapshot.decode(Data(text.utf8)) == tombstone)
    }

    @Test func theRemoteRecordIsTheOneRemoteConnectionSaves() throws {
        let record = RemoteTabRecord(hostID: "host-9", destination: "me@box.example.net", port: 22, directory: "~/work",
                                     session: "nt-9", keep: .herdr, project: "/Users/sam/Projects/garden", title: "box")
        let saved = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let back = try decode(oneTab(#"{"pane":{"id":"\#(id(1).uuidString)","remote":\#(saved)}}"#))
        let decoded = try #require(back.panes.first)
        #expect(decoded.remote == record)
        #expect(decoded.keep == .herdr)

        // And the snapshot writes it with the same keys.
        let written = try JSONSerialization.jsonObject(with: back.encoded()) as? [String: Any]
        let windows = try #require(written?["windows"] as? [[String: Any]])
        let groups = try #require(windows.first?["groups"] as? [[String: Any]])
        let rootNode = try #require(groups.first?["root"] as? [String: Any])
        let paneObject = try #require(rootNode["pane"] as? [String: Any])
        let remote = try #require(paneObject["remote"] as? [String: Any])
        let original = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(Set(remote.keys) == Set(original.keys))
    }

    // MARK: the frozen v1 file

    /// Written by schema 1. Never edit it: a later version must still read it.
    private let frozenV1 = """
    {
      "header": {
        "schema": 1,
        "launchID": "3b0f8a52-6d1e-4c7a-9f20-5a1d2c3e4f50",
        "generation": 42,
        "clean": false,
        "bootSession": "8E1F3B2A-0C4D-4E5F-8A9B-1C2D3E4F5A6B",
        "awaitingMarker": "c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
        "pendingToVersion": "0.11.0",
        "savedAt": 1790000000000
      },
      "windows": [
        {
          "frame": {"x": 120, "y": 80, "width": 1280, "height": 800},
          "screen": "display-1",
          "project": "/Users/sam/Projects/garden",
          "selected": 1,
          "minimized": false,
          "fullScreen": false,
          "groups": [
            {
              "root": {"pane": {
                "id": "a1000000-0000-4000-8000-000000000001",
                "folder": "/Users/sam/Projects/garden",
                "systemZsh": true,
                "stateBefore": "idle",
                "lastSelected": 1789999990000,
                "command": {"line": "npm test", "check": "kept", "source": "integration", "running": false, "exitCode": 1},
                "note": {"reason": "lastCommand", "command": "npm test", "exitCode": 1}
              }},
              "focused": "a1000000-0000-4000-8000-000000000001"
            },
            {
              "root": {"split": {"vertical": true, "dividers": [0.4], "children": [
                {"pane": {
                  "id": "a1000000-0000-4000-8000-000000000002",
                  "folder": "/Users/sam/Projects/garden/web",
                  "userTitle": "agent",
                  "stateBefore": "working",
                  "interrupted": true,
                  "lastSelected": 1789999999000,
                  "command": {"line": "claude", "check": "kept", "source": "integration", "running": true},
                  "agent": {
                    "agent": "claude",
                    "sessionID": "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c",
                    "source": "sessionFile",
                    "sessionFolder": "/Users/sam/Projects/garden/web",
                    "executable": "/opt/agents/bin/claude",
                    "interpreter": "/opt/agents/bin/node",
                    "script": "/opt/agents/lib/claude/cli.js",
                    "startedAt": 1789980000000,
                    "sessionDate": 1789990000000,
                    "routingMatchesShell": true,
                    "autoContinueOff": true,
                    "ranAsTyped": true
                  },
                  "scrollback": "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",
                  "pending": {"action": "resume", "state": "pending", "reason": "update"}
                }},
                {"split": {"vertical": false, "dividers": [0.5], "children": [
                  {"pane": {
                    "id": "a1000000-0000-4000-8000-000000000003",
                    "remote": {"hostID": "host-1", "destination": "deploy@build.example.com", "port": 2222,
                               "directory": "/srv/app", "session": "nt-3", "keep": "tmux", "project": "/Users/sam/Projects/garden"},
                    "stateBefore": "running",
                    "lastSelected": 1789999980000
                  }},
                  {"pane": {
                    "id": "a1000000-0000-4000-8000-000000000004",
                    "folder": "/Users/sam/Projects/garden",
                    "stateBefore": "running",
                    "lastSelected": 1789999970000,
                    "command": {"check": "secret", "source": "integration", "running": true},
                    "note": {"reason": "notKept"}
                  }}
                ]}}
              ]}},
              "focused": "a1000000-0000-4000-8000-000000000002",
              "zoomed": "a1000000-0000-4000-8000-000000000003"
            }
          ]
        }
      ]
    }
    """

    @Test func aFrozenV1FileStillDecodes() throws {
        let snapshot = try decode(frozenV1)
        #expect(snapshot.header.schema == 1)
        #expect(snapshot.header.launchID == UUID(uuidString: "3b0f8a52-6d1e-4c7a-9f20-5a1d2c3e4f50"))
        #expect(snapshot.header.generation == 42)
        #expect(!snapshot.header.clean)
        #expect(snapshot.header.bootSession == "8E1F3B2A-0C4D-4E5F-8A9B-1C2D3E4F5A6B")
        #expect(snapshot.header.awaitingMarker == UUID(uuidString: "c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f"))
        #expect(snapshot.header.pendingToVersion == "0.11.0")
        #expect(snapshot.header.savedAt == Date(timeIntervalSince1970: 1_790_000_000))

        let window = try #require(snapshot.windows.first)
        #expect(window.frame == Snapshot.Frame(x: 120, y: 80, width: 1280, height: 800))
        #expect(window.screen == "display-1")
        #expect(window.project == "/Users/sam/Projects/garden")
        #expect(window.selected == 1)
        #expect(window.groups.count == 2)

        let idle = try #require(window.groups[0].panes.first)
        #expect(idle.command?.line == "npm test")
        #expect(idle.command?.exitCode == 1)
        #expect(idle.note == Snapshot.Note(reason: .lastCommand, command: idle.command, exitCode: 1))
        #expect(idle.note?.command == "npm test")
        #expect(idle.systemZsh)

        let tab = window.groups[1]
        guard case .split(let outer) = tab.root else { Issue.record("not a split"); return }
        #expect(outer.vertical)
        let outerDividers: [Double] = [0.4]
        #expect(outer.dividers == outerDividers)
        #expect(tab.panes.count == 3)
        #expect(tab.focused == tab.panes[0].id)
        #expect(tab.zoomed == tab.panes[1].id)

        let agent = tab.panes[0]
        #expect(agent.userTitle == "agent")
        #expect(agent.stateBefore == .working)
        #expect(agent.interrupted)
        #expect(agent.agent?.agent == .claude)
        #expect(agent.agent?.isExact == true)
        #expect(agent.agent?.executable == "/opt/agents/bin/claude")
        #expect(agent.agent?.interpreter == "/opt/agents/bin/node")
        #expect(agent.agent?.script == "/opt/agents/lib/claude/cli.js")
        #expect(agent.agent?.startedAt == Date(timeIntervalSince1970: 1_789_980_000))
        #expect(agent.agent?.ranAsTyped == true)
        #expect(!agent.systemZsh) // not in the file: not known
        #expect(agent.scrollback == UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"))
        #expect(agent.pending == Snapshot.PendingAction(action: .resume, state: .pending, reason: .update))

        let remote = tab.panes[1]
        #expect(remote.keep == .tmux)
        #expect(remote.remote?.session == "nt-3")
        #expect(remote.stateBefore == .running)

        let secret = tab.panes[2]
        #expect(secret.command?.check == .secret)
        #expect(secret.command?.line == nil)
        #expect(secret.note?.reason == .notKept)
    }

    // MARK: tolerant decoding

    @Test func unknownAgentAndKeepModeValuesDecodeToUnknown() throws {
        let remote = #""remote":{"hostID":"h","directory":"/srv","session":"s","keep":"zellij"}"#
        let agent = #""agent":{"agent":"zed-agent","sessionID":"abc","source":"telepathy"}"#
        let enums = #""stateBefore":"dreaming","pending":{"action":"teleport","state":"maybe","reason":"eclipse"}"#
        let notes = #""note":{"reason":"poetry"},"command":{"line":"ls","check":"vibes","source":"psychic"}"#
        let json = oneTab(#"{"pane":{"id":"\#(id(1).uuidString)",\#(remote),\#(agent),\#(enums),\#(notes)}}"#)
        let pane = try #require(try decode(json).panes.first)
        #expect(pane.keep == .unknown)
        #expect(pane.remote?.keep == .off) // so it can only come back as a fresh connection
        #expect(pane.agent?.agent == .unknown)
        #expect(pane.agent?.source == .unknown)
        #expect(pane.agent?.isExact == false)
        #expect(pane.stateBefore == .unknown)
        #expect(pane.pending == Snapshot.PendingAction(action: .unknown, state: .unknown, reason: .unknown))
        #expect(pane.note?.reason == .unknown)
        #expect(pane.command?.check == .unknown)
        #expect(pane.command?.source == .unknown)
        #expect(pane.command?.line == nil) // only a line that passed its checks is kept
    }

    @Test func oneCorruptPaneDropsOnlyThatPaneAndTheTreeIsRepaired() throws {
        let corrupt = #"{"pane":{"id":"not-an-id","folder":"/Users/sam"}}"#
        // Three side by side, the middle one unreadable: its room goes to its neighbour, like closing it.
        let three = #"{"split":{"vertical":true,"dividers":[0.3,0.6],"children":[\#(paneJSON(1)),\#(corrupt),\#(paneJSON(3))]}}"#
        let tab = try #require(try decode(oneTab(three, focused: 2)).windows.first?.groups.first)
        guard case .split(let split) = tab.root else { Issue.record("not a split"); return }
        #expect(split.children.count == 2)
        let leftDividers: [Double] = [0.3]
        #expect(split.dividers == leftDividers)
        #expect(tab.focused == id(1)) // it had the keyboard; the first pane takes it

        // Two stacked, one unreadable: the split of one is just that one.
        let two = #"{"split":{"vertical":false,"dividers":[0.5],"children":[\#(corrupt),\#(paneJSON(4))]}}"#
        let single = try #require(try decode(oneTab(two, focused: 4)).windows.first?.groups.first)
        #expect(single.root == .pane(Pane(id: id(4), folder: "/Users/sam/Projects/garden")))

        // A tab with nothing readable is dropped, the window keeps the rest.
        let json = """
        {"header":{"schema":1,"launchID":"\(id(900).uuidString)","generation":1,"clean":false,"savedAt":1790000000000},
         "windows":[{"selected":2,"groups":[{"root":\(paneJSON(1)),"focused":"\(id(1).uuidString)"},
                                 {"root":\(corrupt)},
                                 {"root":\(paneJSON(3)),"focused":"\(id(3).uuidString)"}]},
                    {"groups":"not a list"},
                    17]}
        """
        let snapshot = try decode(json)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        let focused: [UUID] = window.groups.map { (group: Group) -> UUID in group.focused }
        #expect(focused == ids(1, 3))
        #expect(window.selected == 1) // still the same tab, one place earlier
    }

    @Test func aWrongHeaderOrSchemaRefusesTheFile() {
        #expect(throws: Snapshot.DecodeError.badHeader) { try decode(#"{"windows":[]}"#) }
        #expect(throws: Snapshot.DecodeError.badHeader) {
            try decode(#"{"header":{"schema":1,"launchID":"nope","generation":1,"clean":false,"savedAt":0}}"#)
        }
        #expect(throws: Snapshot.DecodeError.badHeader) {
            try decode(#"{"header":{"schema":1,"launchID":"\#(id(1).uuidString)","generation":-1,"clean":false,"savedAt":0}}"#)
        }
        #expect(throws: Snapshot.DecodeError.otherSchema(2)) {
            try decode(#"{"header":{"schema":2,"launchID":"\#(id(1).uuidString)","generation":1,"clean":false,"savedAt":0}}"#)
        }
        #expect(throws: Snapshot.DecodeError.unreadable) { try decode("{\"header\": ") }
    }

    // MARK: caps

    @Test func aFiftyMegabyteFileIsRefusedBeforeItIsRead() {
        let huge = Data(count: 50 << 20)
        #expect(throws: Snapshot.DecodeError.tooLarge) { try Snapshot.decode(huge) }
        let justOver = Data(count: Snapshot.Limits.standard.bytes + 1)
        #expect(throws: Snapshot.DecodeError.tooLarge) { try Snapshot.decode(justOver) }
    }

    @Test func aDepthOfTenThousandIsRefusedWithinItsCap() {
        let open = String(repeating: #"{"split":{"vertical":true,"children":["#, count: 10_000)
        let close = String(repeating: "]}}", count: 10_000)
        let json = oneTab(open + paneJSON(1) + close)
        #expect(throws: Snapshot.DecodeError.tooDeep) { try decode(json) }
        // Brackets inside strings are text, not nesting.
        let quoted = oneTab(#"{"pane":{"id":"\#(id(1).uuidString)","userTitle":"\#(String(repeating: "[{", count: 5_000))"}}"#)
        #expect(throws: Never.self) { try decode(quoted) }
    }

    @Test func aTreeDeeperThanTheCapLosesOnlyWhatIsBelowIt() throws {
        var limits = Snapshot.Limits.standard
        limits.depth = 2
        // Three splits deep: the third is refused, and the split left with one child collapses.
        let third = #"{"split":{"vertical":true,"children":[\#(paneJSON(3)),\#(paneJSON(4))]}}"#
        let second = #"{"split":{"vertical":false,"children":[\#(paneJSON(2)),\#(third)]}}"#
        let first = #"{"split":{"vertical":true,"children":[\#(paneJSON(1)),\#(second)]}}"#
        let tab = try #require(try decode(oneTab(first), limits: limits).windows.first?.groups.first)
        #expect(paneIDs(tab.panes) == ids(1, 2))
        guard case .split(let split) = tab.root else { Issue.record("not a split"); return }
        let expected: [Node] = [.pane(Pane(id: id(1), folder: "/Users/sam/Projects/garden")),
                                .pane(Pane(id: id(2), folder: "/Users/sam/Projects/garden"))]
        #expect(split.children == expected)
    }

    @Test func windowTabAndPaneCountsAreCapped() throws {
        var limits = Snapshot.Limits.standard
        limits.windows = 2
        limits.groups = 3
        limits.panes = 5
        let tab: (Int) -> String = { n in #"{"root":\#(self.paneJSON(n)),"focused":"\#(self.id(n).uuidString)"}"# }
        let window: ([Int]) -> String = { ns in #"{"groups":[\#(ns.map(tab).joined(separator: ","))]}"# }
        let json = """
        {"header":{"schema":1,"launchID":"\(id(900).uuidString)","generation":1,"clean":false,"savedAt":1790000000000},
         "windows":[\(window([1, 2, 3, 4])),\(window([5, 6, 7])),\(window([8]))]}
        """
        let snapshot = try decode(json, limits: limits)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].groups.count == 3)
        #expect(paneIDs(snapshot.panes) == ids(1, 2, 3, 5, 6))

        // The same caps hold for what is written.
        let built = Snapshot(header: header(), windows: (0..<4).map { w in
            Window(groups: (0..<5).map { g in Group(root: .pane(pane(w * 10 + g)), focused: id(w * 10 + g)) })
        })
        let capped = built.repaired(limits: limits)
        #expect(capped.windows.count == 2)
        #expect(capped.panes.count == 5)
    }

    @Test func overlongAndMalformedStringsAreDropped() throws {
        let long = String(repeating: "a", count: Snapshot.Limits.standard.text + 1)
        let longPath = "/" + String(repeating: "p", count: Snapshot.Limits.standard.path)
        let fields = #""userTitle":"\#(long)","folder":"\#(longPath)","scrollback":"../../etc/passwd""#
        let agent = #""agent":{"agent":"codex","sessionID":"abc; rm -rf ~","source":"openRollout","executable":"codex"}"#
        let json = oneTab(#"{"pane":{"id":"\#(id(1).uuidString)",\#(fields),\#(agent)}}"#,
                          extra: #","project":"relative/path","screen":"\#(long)""#)
        let snapshot = try decode(json)
        let pane = try #require(snapshot.panes.first)
        #expect(pane.userTitle == nil)
        #expect(pane.folder == nil)
        #expect(pane.scrollback == nil)
        #expect(pane.agent?.agent == .codex)
        #expect(pane.agent?.sessionID == nil)
        #expect(pane.agent?.isExact == false)
        #expect(pane.agent?.executable == nil) // not an absolute path
        #expect(snapshot.windows.first?.project == nil)
        #expect(snapshot.windows.first?.screen == nil)

        // A remote record whose required fields are too long makes the pane unreadable, not a local one.
        let badRemote = #"{"pane":{"id":"\#(id(2).uuidString)","remote":{"hostID":"\#(long)","directory":"/","session":"s","keep":"tmux"}}}"#
        let two = #"{"split":{"vertical":true,"children":[\#(paneJSON(1)),\#(badRemote)]}}"#
        let tab = try #require(try decode(oneTab(two)).windows.first?.groups.first)
        #expect(paneIDs(tab.panes) == ids(1))
    }

    // MARK: command lines

    @Test func aLineThatFailedItsChecksIsNeverWritten() throws {
        let secret = Snapshot.Command(line: "DB_PASSWORD=hunter2 npm start", check: .secret, source: .integration, running: true)
        #expect(secret.line == nil)
        #expect(secret.check == .secret)
        var held = pane(1)
        held.command = secret
        held.note = Snapshot.Note(reason: .notKept, command: secret)
        #expect(held.note?.command == nil) // a note on a dropped line repeats none of it

        // Nor does a note of any other kind: an idle tab's last command, a remote tab's.
        var idle = pane(2)
        idle.command = Snapshot.Command(line: "DB_PASSWORD=hunter4 npm start", check: .secret, source: .integration, running: false)
        idle.note = Snapshot.Note(reason: .lastCommand, command: idle.command, exitCode: 0)
        #expect(idle.note?.command == nil)
        var remote = Pane(id: id(3))
        remote.remote = RemoteTabRecord(hostID: "host-1", directory: "/srv/app", session: "nt-3", keep: .off)
        remote.command = Snapshot.Command(line: "curl -u me:hunter3 https://example.com", check: .secret, source: .integration, running: false)
        remote.note = Snapshot.Note(reason: .remote, command: remote.command)
        #expect(remote.note?.command == nil)

        // And a pane writes a note's command only when it is the pane's own kept line.
        var stray = pane(4)
        stray.command = Snapshot.Command(line: "DB_PASSWORD=hunter5 make", check: .secret, source: .integration, running: false)
        let other = Snapshot.Command(line: "make TOKEN=hunter5", check: .kept, source: .integration, running: false)
        stray.note = Snapshot.Note(reason: .lastCommand, command: other)
        let children: [Node] = [.pane(held), .pane(idle), .pane(remote), .pane(stray)]
        let tab = Group(root: .split(Split(vertical: true, children: children)), focused: id(1))
        let text = String(decoding: try Snapshot(header: header(), windows: [Window(groups: [tab])]).encoded(), as: UTF8.self)
        for secretWord in ["hunter2", "hunter3", "hunter4", "hunter5"] {
            #expect(!text.contains(secretWord), "\(secretWord)")
        }

        // A planted file cannot slip one in either.
        let planted = #""command":{"line":"curl -u me:hunter2 https://example.com","check":"secret","running":true}"#
        let json = oneTab(#"{"pane":{"id":"\#(id(1).uuidString)",\#(planted),"note":{"reason":"notKept","command":"hunter2"}}}"#)
        let pane = try #require(try decode(json).panes.first)
        #expect(pane.command?.line == nil)
        #expect(pane.note?.command == nil)
        let lastCommand = #""command":{"check":"secret","running":false},"note":{"reason":"lastCommand","command":"curl -u me:hunter3 h"}"#
        let plantedNote = try #require(try decode(oneTab(#"{"pane":{"id":"\#(id(1).uuidString)",\#(lastCommand)}}"#)).panes.first)
        #expect(plantedNote.note?.reason == .lastCommand)
        #expect(plantedNote.note?.command == nil)
    }

    @Test func aKeptLineMustBeOneShortLineOfPlainText() {
        let cases: [(String, Snapshot.LineCheck)] = [
            ("npm run dev\nrm -rf ~", .multiline),
            ("npm run dev\r", .multiline),
            ("echo a\u{2028}b", .multiline),
            (String(repeating: "x", count: 4096), .tooLong),
            ("echo \u{1B}[31mred", .unsafeCharacters),
            ("echo a\tb", .unsafeCharacters),
            ("echo \u{9B}31m", .unsafeCharacters),
            ("ls \u{202E}txt.sh", .unsafeCharacters),
            ("ls a\u{200B}b", .unsafeCharacters),
            ("rm\u{7F}", .unsafeCharacters),
            ("ls \u{E0001}\u{E0072}\u{E006D}\u{E007F}", .unsafeCharacters), // tag characters
            ("rm -rf a\u{00AD}b", .unsafeCharacters), // soft hyphen
            ("ls a\u{180E}b", .unsafeCharacters),
            ("ls \u{FFF9}a\u{FFFA}b\u{FFFB}", .unsafeCharacters), // interlinear annotation
            ("ls a\u{034F}b", .unsafeCharacters),
            ("ls a\u{FE0F}", .unsafeCharacters), // variation selector
            ("ls \u{115F}", .unsafeCharacters),
            ("ls \u{3164}", .unsafeCharacters), // Hangul fillers
            ("ls \u{1D173}", .unsafeCharacters),
            ("ls \u{13430}", .unsafeCharacters),
            ("ls \u{0600}1", .unsafeCharacters),
        ]
        // Noncharacters cannot be written in a literal.
        let noncharacters: [String] = [0xFDD0, 0xFFFE, 0x10FFFF].map { (value: UInt32) -> String in
            "ls " + String(Character(Unicode.Scalar(value)!))
        }
        let all: [(String, Snapshot.LineCheck)] = cases + noncharacters.map { (line: String) -> (String, Snapshot.LineCheck) in
            (line, .unsafeCharacters)
        }
        for (line, problem) in all {
            let command = Snapshot.Command(line: line, check: .kept, source: .integration, running: true)
            #expect(command.line == nil, "\(problem)")
            #expect(command.check == problem)
        }
        let fine = Snapshot.Command(line: String(repeating: "x", count: 4095), check: .kept, source: .integration, running: true)
        let length = fine.line?.count ?? 0
        #expect(length == 4095)
        let unicode = Snapshot.Command(line: "echo 'héllo ✓'", check: .kept, source: .integration, running: false)
        #expect(unicode.line == "echo 'héllo ✓'")
    }

    @Test func encodingWritesNoEnvironmentValuesAndNoExpandedLine() throws {
        var status = TabStatus()
        status.commandStarted("gl", expanded: "git pull --rebase canary-expanded-line", at: 1)
        var agentPane = pane(1)
        agentPane.command = Snapshot.Command(status: status, check: .kept)
        agentPane.agent = Snapshot.Evidence(agent: .copilot, sessionID: "a1b2c3", source: .childEnvironment,
                                            routingMatchesShell: true, autoContinueOff: true)
        let data = try Snapshot(header: header(), windows: [Window(groups: [Group(root: .pane(agentPane), focused: id(1))])]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(agentPane.command?.line == "gl")
        #expect(agentPane.command?.source == .integration)
        #expect(text.contains(#""gl""#))
        #expect(!text.contains("canary-expanded-line"))

        // No key in the file holds an environment or an expanded line.
        var keys: Set<String> = []
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                keys.formUnion(object.keys)
                object.values.forEach(collect)
            } else if let list = value as? [Any] {
                list.forEach(collect)
            }
        }
        collect(try JSONSerialization.jsonObject(with: data))
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { !$0.lowercased().contains("env") && !$0.lowercased().contains("expand") }, "\(keys.sorted())")
    }

    // MARK: repairs

    @Test func badFractionsAreClampedAndRenormalized() {
        let fractions: ([Double], Int) -> [Double] = { Snapshot.Split.repairedDividers($0, count: $1) }
        let thirds: [Double] = [Double(1) / Double(3), Double(2) / Double(3)]
        let good: [Double] = [0.3, 0.7]
        let half: [Double] = [0.5]
        let notNumbers: [Double] = [.infinity, 0.2]
        #expect(fractions(good, 3) == good) // good ones stay exactly as they were
        #expect(fractions(half, 3) == thirds) // wrong count: equal shares
        #expect(fractions([Double.nan], 2) == half)
        #expect(fractions(notNumbers, 3) == thirds)
        let brokenSets: [[Double]] = [[1.5], [-2.0], [0.0], [1.0]]
        for broken in brokenSets {
            let fixed = fractions(broken, 2)
            #expect(fixed.count == 1)
            let inside = fixed.first.map { (0..<1.0).contains($0) && $0 > 0 } ?? false
            #expect(inside, "\(broken)")
        }
        let backwards = fractions([0.7, 0.3], 3)
        #expect(backwards.count == 2)
        let rising = backwards == backwards.sorted() && backwards.allSatisfy { (0..<1.0).contains($0) && $0 > 0 }
        #expect(rising)
        // A repaired set is left alone the next time.
        let again: [Double] = fractions(backwards, 3)
        #expect(again == backwards)
        let once: [Double] = fractions([1.5], 2)
        let twice: [Double] = fractions(once, 2)
        #expect(twice == once)
    }

    @Test func danglingFocusAndSelectionFallBackAndADanglingZoomIsCleared() throws {
        let split = Node.split(Split(vertical: true, children: [.pane(pane(1)), .pane(pane(2))]))
        let window = Window(groups: [Group(root: split, focused: id(99), zoomed: id(98)),
                                     Group(root: .pane(pane(3)), focused: id(3), zoomed: id(3))], selected: 5)
        let repaired = Snapshot(header: header(), windows: [window]).repaired()
        let fixed = try #require(repaired.windows.first)
        #expect(fixed.groups[0].focused == id(1))
        #expect(fixed.groups[0].zoomed == nil) // nothing to zoom: the tab shows all its panes
        #expect(fixed.groups[1].zoomed == nil) // one pane fills its tab anyway
        #expect(fixed.selected == 0)

        // A window with no tab left comes back only for its project.
        let empty = Window(project: "/Users/sam/Projects/garden", groups: [])
        let nothing = Window(groups: [])
        let left: [Window] = Snapshot(header: header(), windows: [empty, nothing]).repaired().windows
        let only: [Window] = [empty]
        #expect(left == only)
    }

    @Test func aOneChildSplitCollapses() {
        let lone = Node.split(Split(vertical: true, children: [.split(Split(vertical: false, children: [.pane(pane(1))]))]))
        let group = Group(root: lone, focused: id(1))
        let repaired = Snapshot(header: header(), windows: [Window(groups: [group])]).repaired()
        #expect(repaired.windows.first?.groups.first?.root == .pane(pane(1)))
    }

    @Test func duplicateTabIDsAreReminted() throws {
        // The same id twice in one tab, and again in another window.
        let split = Node.split(Split(vertical: true, children: [.pane(pane(1)), .pane(pane(1)), .pane(pane(2))]))
        let first = Window(groups: [Group(root: split, focused: id(2))])
        let second = Window(groups: [Group(root: .pane(pane(1)), focused: id(1))])
        let minter = Minter()
        let repaired = Snapshot(header: header(), windows: [first, second]).repaired(makeID: minter.make)
        let minted = paneIDs(repaired.panes)
        #expect(Set(minted).count == minted.count)
        #expect(minted[0] == id(1)) // the first keeps its id
        let reminted: [Bool] = repaired.panes.map { (pane: Pane) -> Bool in pane.reminted }
        let expected: [Bool] = [false, true, false, true]
        #expect(reminted == expected)
        #expect(repaired.windows[0].groups[0].focused == id(2))
        #expect(repaired.windows[1].groups[0].focused == minted[3]) // follows its pane to the new id

        // Through the file as well, and a re-minted pane says so after the next save.
        let back = try Snapshot.decode(repaired.encoded())
        #expect(back == repaired)
    }

    // MARK: agent evidence

    @Test func anIDFromAChildProcesssEnvironmentIsAGuess() {
        // Any command the tab runs can set COPILOT_AGENT_SESSION_ID (or CLAUDE_CODE_SESSION_ID) for its children.
        let child = Snapshot.Evidence(agent: .copilot, sessionID: "a1b2c3", source: .childEnvironment)
        #expect(!child.isExact)
        #expect(!Snapshot.IDSource.childEnvironment.isExact)
        let claude = Snapshot.Evidence(agent: .claude, sessionID: "a1b2c3", source: .childEnvironment)
        #expect(!claude.isExact)
        let file = Snapshot.Evidence(agent: .claude, sessionID: "a1b2c3", source: .sessionFile)
        #expect(file.isExact)
    }

    @Test func factsTheRestoreReadsBackDefaultToTheAnswerThatResumesNothing() throws {
        let agent = #""agent":{"agent":"claude","sessionID":"abc","source":"sessionFile"}"#
        let pane = try #require(try decode(oneTab(#"{"pane":{"id":"\#(id(1).uuidString)",\#(agent)}}"#)).panes.first)
        let evidence = try #require(pane.agent)
        #expect(evidence.interpreter == nil)
        #expect(evidence.script == nil)
        #expect(evidence.startedAt == nil)
        #expect(!evidence.ranAsTyped)
        #expect(!evidence.routingMatchesShell)
        #expect(!evidence.autoContinueOff)
        #expect(!pane.systemZsh)
    }

    @Test func pathsThatRunOrResumeHoldNoControlOrInvisibleCharacter() throws {
        let paths = #""executable":"/opt/bin/claude\u0000/../../tmp/evil","sessionFolder":"/p‮rev","#
            + #""interpreter":"/opt/bin/no\u001Bde","script":"/opt/lib/cli­.js""#
        let agent = #""agent":{"agent":"claude","source":"sessionFile",\#(paths)}"#
        let json = oneTab(#"{"pane":{"id":"\#(id(1).uuidString)","folder":"/Users/sam/Projects/odd\u001B[1mname",\#(agent)}}"#)
        let pane = try #require(try decode(json).panes.first)
        let evidence = try #require(pane.agent)
        #expect(evidence.executable == nil)
        #expect(evidence.sessionFolder == nil)
        #expect(evidence.interpreter == nil)
        #expect(evidence.script == nil)
        #expect(pane.folder == "/Users/sam/Projects/odd\u{1B}[1mname") // a tab's own folder keeps any name

        // Relative and over-long paths are dropped as for the executable; plain ones stay.
        let longPath = "/" + String(repeating: "p", count: Snapshot.Limits.standard.path)
        let plain = Snapshot.Evidence(agent: .claude, executable: "/opt/agents/bin/claude", interpreter: "node", script: longPath)
        let fixed = plain.repaired(limits: .standard)
        #expect(fixed.executable == "/opt/agents/bin/claude")
        #expect(fixed.interpreter == nil)
        #expect(fixed.script == nil)
    }

    // MARK: caps while reading

    /// The file as the decoder reads it, before repair puts any cap on it again.
    private func read(_ json: String, limits: Snapshot.Limits) throws -> (Snapshot, SnapshotBudget) {
        let budget = SnapshotBudget(limits)
        return (try Snapshot.read(Data(json.utf8), budget: budget), budget)
    }

    @Test func readingStopsWhenTheFilesEntryBudgetRunsOut() throws {
        var limits = Snapshot.Limits.standard
        limits.panes = 4 // 144 entries in all
        let bad = Array(repeating: "0", count: 200).joined(separator: ",")
        let good = #"{"root":\#(paneJSON(1)),"focused":"\#(id(1).uuidString)"}"#
        let json = """
        {"header":{"schema":1,"launchID":"\(id(900).uuidString)","generation":1,"clean":false,"savedAt":1790000000000},
         "windows":[{"project":"/Users/sam/Projects/garden","groups":[\(bad),\(good)]}]}
        """
        let (raw, budget) = try read(json, limits: limits)
        #expect(budget.entries == 0)
        #expect(raw.windows.first?.groups.isEmpty == true) // the good tab after the bad ones is never reached
        let window = try #require(try decode(json, limits: limits).windows.first)
        #expect(window.groups.isEmpty)
    }

    @Test func readingKeepsNoMorePanesThanTheCap() throws {
        var limits = Snapshot.Limits.standard
        limits.panes = 2
        let tab: (Int) -> String = { n in #"{"root":\#(self.paneJSON(n)),"focused":"\#(self.id(n).uuidString)"}"# }
        let json = """
        {"header":{"schema":1,"launchID":"\(id(900).uuidString)","generation":1,"clean":false,"savedAt":1790000000000},
         "windows":[{"groups":[\(tab(1)),\(tab(2)),\(tab(3))]}]}
        """
        let (raw, budget) = try read(json, limits: limits)
        #expect(paneIDs(raw.panes) == ids(1, 2))
        #expect(budget.panes == 0)
    }

    @Test func readingDropsASplitDeeperThanTheCapBeforeAnyRepair() throws {
        var limits = Snapshot.Limits.standard
        limits.depth = 2
        let third = #"{"split":{"vertical":true,"children":[\#(paneJSON(3)),\#(paneJSON(4))]}}"#
        let second = #"{"split":{"vertical":false,"children":[\#(paneJSON(2)),\#(third)]}}"#
        let first = #"{"split":{"vertical":true,"children":[\#(paneJSON(1)),\#(second)]}}"#
        let (raw, _) = try read(oneTab(first), limits: limits)
        #expect(paneIDs(raw.panes) == ids(1, 2))
    }

    @Test func aDividerListIsReadNoFurtherThanItsSplitNeeds() throws {
        let zeros = Array(repeating: "0", count: 5_000).joined(separator: ",")
        let long = #"{"split":{"vertical":true,"dividers":[\#(zeros)],"children":[\#(paneJSON(1)),\#(paneJSON(2))]}}"#
        let (_, budget) = try read(oneTab(long), limits: .standard)
        // The window, the tab, two children, and two dividers: one past what the split needs, and no more.
        #expect(Snapshot.Limits.standard.entries - budget.entries == 6)

        // What the dividers say is read as before: the wrong count or a word gives equal shares.
        let dividers: (String) throws -> [Double] = { list in
            let json = #"{"split":{"vertical":true,"dividers":[\#(list)],"children":[\#(self.paneJSON(1)),\#(self.paneJSON(2))]}}"#
            guard case .split(let split) = try self.decode(self.oneTab(json)).windows.first?.groups.first?.root else { return [] }
            return split.dividers
        }
        let even: [Double] = [0.5]
        let quarter: [Double] = [0.25]
        #expect(try dividers(zeros) == even)
        #expect(try dividers("0.25") == quarter)
        #expect(try dividers(#""a""#) == even)
        #expect(try dividers("0.25,0.5") == even)
    }

    @Test func aFrameNoScreenCouldShowIsDropped() throws {
        let frames: [String] = [#"{"x":0,"y":0,"width":-1280,"height":800}"#, #"{"x":0,"y":0,"width":1280,"height":0}"#,
                                #"{"x":1e300,"y":0,"width":1280,"height":800}"#, #"{"x":0,"y":0,"width":"wide","height":800}"#]
        for frame in frames {
            let window = try #require(try decode(oneTab(paneJSON(1), extra: #","frame":\#(frame)"#)).windows.first)
            #expect(window.frame == nil, "\(frame)")
        }
        let good = try #require(try decode(oneTab(paneJSON(1), extra: #","frame":{"x":-40,"y":20,"width":900,"height":600}"#)).windows.first)
        #expect(good.frame == Snapshot.Frame(x: -40, y: 20, width: 900, height: 600))
        // Not a number cannot be written in JSON, but a frame from the app can hold one.
        let notNumber = Snapshot.Frame(x: .nan, y: 0, width: 800, height: 600)
        #expect(notNumber.repaired() == nil)
    }

    @Test func headerTokensWithOtherCharactersAreDropped() throws {
        let header: (String, String) -> String = { boot, version in
            #"{"header":{"schema":1,"launchID":"\#(self.id(900).uuidString)","generation":1,"clean":false,"savedAt":0,"#
                + #""bootSession":"\#(boot)","pendingToVersion":"\#(version)"}}"#
        }
        let bad = try decode(header("8E1F3B2A;rm -rf ~", "0.11.0\\u001B[2J"))
        #expect(bad.header.bootSession == nil)
        #expect(bad.header.pendingToVersion == nil)
        let long = try decode(header(String(repeating: "A", count: 65), "0.11.0 beta"))
        #expect(long.header.bootSession == nil)
        #expect(long.header.pendingToVersion == nil)
        let good = try decode(header("8E1F3B2A-0C4D-4E5F-8A9B-1C2D3E4F5A6B", "0.11.0-beta.2+build.7"))
        #expect(good.header.bootSession == "8E1F3B2A-0C4D-4E5F-8A9B-1C2D3E4F5A6B")
        #expect(good.header.pendingToVersion == "0.11.0-beta.2+build.7")
    }

    @Test func aRemotePaneWithAPortNoHostCouldHaveIsDropped() throws {
        let remote: (Int) -> String = { port in
            #"{"pane":{"id":"\#(self.id(2).uuidString)","remote":{"hostID":"h","port":\#(port),"directory":"/srv","session":"s","keep":"tmux"}}}"#
        }
        for port in [0, 70_000, -22] {
            let two = #"{"split":{"vertical":true,"children":[\#(paneJSON(1)),\#(remote(port))]}}"#
            let snapshot = try decode(oneTab(two))
            #expect(paneIDs(snapshot.panes) == ids(1), "\(port)")
        }
        let fine = #"{"split":{"vertical":true,"children":[\#(paneJSON(1)),\#(remote(2222))]}}"#
        let kept = try decode(oneTab(fine))
        #expect(kept.panes.last?.remote?.port == 2222)
    }

    // MARK: caps while writing

    @Test func aTabSplitDeeperThanTheCapIsFlattenedWhenWrittenAndLosesNoPane() throws {
        // A staircase 13 splits deep, as split_beside can build: every pane comes back, focus too.
        var node = Node.pane(pane(13))
        for level in (0..<13).reversed() {
            node = .split(Split(vertical: level % 2 == 0, children: [.pane(pane(level)), node]))
        }
        let snapshot = Snapshot(header: header(), windows: [Window(groups: [Group(root: node, focused: id(13))])])
        #expect(snapshot.panesLeftOut().isEmpty)
        let back = try Snapshot.decode(snapshot.encoded())
        #expect(paneIDs(back.panes) == ids(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13))
        #expect(back.windows.first?.groups.first?.focused == id(13))

        // At the cap, the split below gives its panes to the one above, each an equal part of its room.
        var limits = Snapshot.Limits.standard
        limits.depth = 2
        let third = Node.split(Split(vertical: true, children: [.pane(pane(3)), .pane(pane(4))]))
        let second = Node.split(Split(vertical: false, children: [.pane(pane(2)), third], dividers: [0.4]))
        let first = Node.split(Split(vertical: true, children: [.pane(pane(1)), second], dividers: [0.3]))
        let small = Snapshot(header: header(), windows: [Window(groups: [Group(root: first, focused: id(4))])])
        let tab = try #require(small.repaired(limits: limits).windows.first?.groups.first)
        #expect(paneIDs(tab.panes) == ids(1, 2, 3, 4))
        #expect(tab.focused == id(4))
        guard case .split(let top) = tab.root, case .split(let flat) = top.children[1] else { Issue.record("not split"); return }
        let topDividers: [Double] = [0.3]
        #expect(top.dividers == topDividers)
        #expect(!flat.vertical)
        let flatDividers: [Double] = [0.4, 0.7]
        let near = zip(flat.dividers, flatDividers).allSatisfy { (pair: (Double, Double)) -> Bool in abs(pair.0 - pair.1) < 1e-9 }
        #expect(flat.dividers.count == 2 && near, "\(flat.dividers)")
    }

    @Test func panesPastTheCountCapsAreNamedWhenWritten() {
        var limits = Snapshot.Limits.standard
        limits.windows = 2
        limits.groups = 3
        limits.panes = 5
        let built = Snapshot(header: header(), windows: (0..<4).map { (w: Int) -> Window in
            Window(groups: (0..<5).map { (g: Int) -> Group in Group(root: .pane(pane(w * 10 + g)), focused: id(w * 10 + g)) })
        })
        let left: [UUID] = built.panesLeftOut(limits: limits)
        let expected: [UUID] = ids(3, 4, 12, 13, 14, 20, 21, 22, 23, 24, 30, 31, 32, 33, 34)
        #expect(left == expected)
        // A remote pane whose record cannot be trusted is named too.
        var remote = Pane(id: id(2))
        remote.remote = RemoteTabRecord(hostID: "h", port: 0, directory: "/srv", session: "s", keep: .tmux)
        let split = Node.split(Split(vertical: true, children: [.pane(pane(1)), .pane(remote)]))
        let one = Snapshot(header: header(), windows: [Window(groups: [Group(root: split, focused: id(1))])])
        #expect(one.panesLeftOut() == ids(2))
        // Duplicate ids are not left out: they get fresh ones.
        let twice = Node.split(Split(vertical: true, children: [.pane(pane(1)), .pane(pane(1))]))
        #expect(Snapshot(header: header(), windows: [Window(groups: [Group(root: twice, focused: id(1))])]).panesLeftOut().isEmpty)
    }
}
