import Foundation
import Testing
@testable import NextTermCore

/// The MCP hub in an agent's bridge: the plan the app gives, the catalog's three tools only once a server applies (R17),
/// and local servers started on first need, in the agent's folder with the plan's PATH and the list's variables (R16),
/// against a fake stdio server: a shell script with fixed answers. Every way a server can fail ends in a sentence.
@Suite struct MCPHubSessionTests {
    let folder: String
    let script: String

    /// A fake MCP server: fixed answers by method and tool name. `where` says its folder and HUB_TEST; `big` answers
    /// 300,000 characters; `slow` never answers; `die` exits 3 after a line on stderr; `noise` writes a line that isn't
    /// JSON and nothing else.
    static let fake = #"""
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Says hello back","inputSchema":{"type":"object"}},{"name":"where","description":"Its folder and variable","inputSchema":{"type":"object"}},{"name":"big","description":"A long answer","inputSchema":{"type":"object"}},{"name":"slow","description":"Never answers","inputSchema":{"type":"object"}},{"name":"die","description":"Exits","inputSchema":{"type":"object"}},{"name":"noise","description":"Writes what is not MCP","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        *'"method":"tools/call"'*)
          case "$line" in
            *'"name":"echo"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"hello from fake"}],"structuredContent":{"said":"hello"}}}\n' "$id" ;;
            *'"name":"where"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s|%s"}]}}\n' "$id" "$(pwd -P)" "$HUB_TEST" ;;
            *'"name":"big"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$id"; head -c 300000 /dev/zero | tr '\0' a; printf '"}]}}\n' ;;
            *'"name":"slow"'*) sleep 5 ;;
            *'"name":"die"'*) echo "fake: dying on purpose" >&2; exit 3 ;;
            *'"name":"noise"'*) echo "this is not json" ;;
          esac ;;
      esac
    done
    """#

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-session-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made + "/work", withIntermediateDirectories: true)
        folder = canonicalPath(made + "/work")
        script = made + "/fake-server.sh"
        try Self.fake.write(toFile: script, atomically: true, encoding: .utf8)
    }

    func plan(_ servers: [MCPHubPlan.Server]) -> MCPHubPlan {
        MCPHubPlan(folder: folder, path: ["/usr/bin", "/bin"], servers: servers)
    }

    func fakeServer(_ name: String = "fake", script: String? = nil) -> MCPHubPlan.Server {
        MCPHubPlan.Server(name: name, state: .ready, command: "/bin/sh", args: [script ?? self.script], env: ["HUB_TEST": "from-the-list"],
                          list: "/u/mcp.json")
    }

    func session(_ plan: MCPHubPlan?, limits: MCPHubUpstream.Limits = .standard, refresh: MCPHubSession.Refresh? = nil) -> MCPHubSession {
        MCPHubSession(plan: plan, refresh: refresh ?? { plan }, nxtrm: ["/usr/bin/true"], environment: ["HOME": NSHomeDirectory()],
                      limits: limits, version: "0.0.0")
    }

    /// A tool result's first text, and whether it is an error.
    func text(_ result: [String: Any]) -> (String, Bool) {
        let content = result["content"] as? [[String: Any]] ?? []
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func json(_ result: [String: Any]) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text(result).0.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: R17

    /// With no server, the bridge's answers are the pinned ones, byte for byte: the catalog adds nothing. The pin holds
    /// Next Term's own tools whole, add_mcp_server and list_mcp_servers among them (R17, by the owner's decision).
    @Test func withNoServerTheBridgeAnswersAsBefore() throws {
        for hub in [session(nil), session(plan([])),
                    session(plan([MCPHubPlan.Server(name: "x", state: .off, command: "a", list: "/u")])),
                    session(plan([MCPHubPlan.Server(name: "x", state: .needsApproval, command: "a", list: "/p")]))] {
            #expect(!hub.isActive && hub.tools.isEmpty)
            func answer(_ method: String, instructions: String = MCPServer.instructions) -> [String: Any] {
                MCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": method, "params": ["protocolVersion": "2025-06-18"]],
                                  version: "0.0.0", instructions: instructions, extra: hub.tools, callExtra: hub.call) { _, _ in
                    MCPServer.CallResult(text: "")
                } ?? [:]
            }
            let answers: [[String: Any]] = [
                answer("initialize"),
                answer("initialize", instructions: MCPServer.instructions(inTab: true, offeringTabs: true)),
                answer("initialize", instructions: MCPServer.instructions(inTab: true, offeringTabs: false)),
                answer("tools/list"),
                answer("prompts/list"),
            ]
            let data = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(SecretRun.digest(data) == "7aa81652fec91a3ffe6643e6bb3059b28d4a180462410537e5a8f05b279d02b4")
            // A catalog tool is unknown, as it was.
            let called = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "mcp_servers"]],
                                           version: "0", extra: hub.tools, callExtra: hub.call) { _, _ in MCPServer.CallResult(text: "") }
            #expect((called?["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
    }

    @Test func aServerAddsTheCatalogAfterNextTermsOwnTools() {
        let hub = session(plan([fakeServer()]))
        #expect(hub.isActive)
        let listed = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], version: "0", extra: hub.tools) { _, _ in
            MCPServer.CallResult(text: "")
        }
        let names = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names == MCPServer.tools.map(\.name) + ["mcp_servers", "mcp_tools", "mcp_call"])
        // Deferred, and tagged for the remote door's cross-check.
        #expect(MCPHubCatalog.tools.allSatisfy { !$0.alwaysLoad && $0.scope != nil })
        #expect(MCPHubCatalog.tools.allSatisfy { MCPServer.tool(named: $0.name) == nil })
    }

    // MARK: the plan

    @Test func thePlanSaysWhichServersCanStart() throws {
        let home = canonicalPath(FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-plan-\(UUID().uuidString)").path)
        let repo = home + "/app"
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.next-term", withIntermediateDirectories: true)
        let userFile = home + "/user.json"
        try #"{"mcpServers": {"local": {"command": "npx"}, "web": {"url": "https://example.com/mcp"}, "older": {"type": "sse", "url": "https://example.com/sse"}, "quiet": {"command": "a", "nextTerm": {"enabled": false}}, "bad": {"command": 3}}}"#
            .write(toFile: userFile, atomically: true, encoding: .utf8)
        try #"{"mcpServers": {"team": {"command": "make", "args": ["mcp"]}}}"#
            .write(toFile: repo + "/" + MCPHubScope.projectFile, atomically: true, encoding: .utf8)
        let resolution = MCPHubScope.servers(folder: repo, home: home, userFile: userFile)
        let made = MCPHubPlan.make(resolution, folder: repo, path: ["/bin"])
        #expect(made.servers.map(\.name) == ["local", "older", "team", "web", "quiet"])
        // A server at a URL is ready, for the app to reach; an older HTTP+SSE one isn't reached at all.
        #expect(made.servers.map(\.state) == [.ready, .remote, .needsApproval, .ready, .off])
        #expect(made.problems.count == 1 && made.problems[0].hasPrefix("bad in \(userFile)"))
        #expect(made.isActive)
        // Approved as it is now, a project's server can start; a changed list waits again.
        let team = try #require(resolution.servers.first { $0.name == "team" })
        let approved = MCPHubPlan.make(resolution, folder: repo, path: [], approved: [team.source.file + "\u{0}" + team.source.digest])
        #expect(approved.server(named: "team")?.state == .ready)
        #expect(MCPHubPlan.make(resolution, folder: repo, path: [], approved: [team.source.file + "\u{0}" + "old"]).server(named: "team")?.state
            == .needsApproval)
        // Only a team's list: nothing the user added, so no catalog.
        try FileManager.default.removeItem(atPath: userFile)
        #expect(!MCPHubPlan.make(MCPHubScope.servers(folder: repo, home: home, userFile: userFile), folder: repo, path: []).isActive)
        // Over the socket and back.
        #expect(MCPHubPlan.decode(made.text) == made)
        #expect(MCPHubPlan.decode("") == nil && MCPHubPlan.decode("not json") == nil)
    }

    // MARK: the catalog

    @Test func aLocalServerStartsOnFirstNeedInTheFolderWithItsVariables() {
        let hub = session(plan([fakeServer()]))
        defer { hub.stop() }
        let before = json(hub.call("mcp_servers", [:]))
        #expect((before["servers"] as? [[String: Any]])?.first?["state"] as? String == "ready")
        let echoed = hub.call("mcp_call", ["server": "fake", "tool": "echo", "arguments": [String: Any]()])
        #expect(text(echoed) == ("hello from fake", false))
        #expect((echoed["structuredContent"] as? [String: Any])?["said"] as? String == "hello")
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "where"])) == (folder + "|from-the-list", false))
        let after = json(hub.call("mcp_servers", [:]))
        let row = (after["servers"] as? [[String: Any]])?.first
        #expect(row?["state"] as? String == "running" && row?["tools"] as? Int == 6)
        #expect(row?["command"] as? String == "/bin/sh " + ShellQuote.quote(script))
    }

    @Test func mcpToolsListsDescribesAndFinds() {
        let hub = session(plan([fakeServer()]))
        defer { hub.stop() }
        let listed = json(hub.call("mcp_tools", ["server": "fake"]))
        #expect((listed["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["echo", "where", "big", "slow", "die", "noise"])
        let described = json(hub.call("mcp_tools", ["server": "fake", "tool": "echo"]))
        #expect(((described["tool"] as? [String: Any])?["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        let found = json(hub.call("mcp_tools", ["query": "HELLO back"]))
        let servers = found["servers"] as? [[String: Any]] ?? []
        #expect(servers.count == 1 && (servers[0]["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["echo"])
        let (missing, isError) = text(hub.call("mcp_tools", ["server": "fake", "tool": "nope"]))
        #expect(isError && missing.contains("fake has no tool named nope") && missing.contains("echo"))
    }

    @Test func callsThatCantBeMadeSaySo() {
        let off = MCPHubPlan.Server(name: "quiet", state: .off, command: "a", list: "/u")
        let waiting = MCPHubPlan.Server(name: "team", state: .needsApproval, command: "a", list: "/p/.next-term/mcp.json")
        let remote = MCPHubPlan.Server(name: "web", state: .remote, url: "https://example.com/mcp", list: "/u")
        let hub = session(plan([fakeServer(), off, waiting, remote]))
        defer { hub.stop() }
        func refused(_ arguments: [String: Any]) -> String {
            let (said, isError) = text(hub.call("mcp_call", arguments))
            return isError ? said : "not an error: " + said
        }
        #expect(refused(["server": "quiet", "tool": "x"]).contains("turned off"))
        #expect(refused(["server": "team", "tool": "x"]).contains("hasn't approved"))
        #expect(refused(["server": "web", "tool": "x"]).contains("older HTTP+SSE transport"))
        #expect(refused(["server": "nobody", "tool": "x"]).contains("No MCP server named nobody"))
        #expect(refused(["server": "fake"]).contains("takes a server and a tool"))
        #expect(refused(["server": "fake", "tool": "echo", "arguments": "text"]).contains("arguments is an object"))
        #expect(refused(["server": "fake", "tool": "nope"]).contains("has no tool named nope"))
    }

    @Test func aProgramNotOnThePathIsNamed() {
        let missing = MCPHubPlan.Server(name: "gone", state: .ready, command: "no-such-program-nt", list: "/u")
        let hub = session(plan([missing]))
        let (said, isError) = text(hub.call("mcp_call", ["server": "gone", "tool": "x"]))
        #expect(isError && said.contains("no-such-program-nt was not found on the login shell's PATH (/usr/bin:/bin)"))
        let row = (json(hub.call("mcp_servers", [:]))["servers"] as? [[String: Any]])?.first
        #expect(row?["state"] as? String == "failed" && (row?["error"] as? String ?? "").contains("was not found"))
    }

    /// How a start ended goes to the app (Settings › MCP Servers' state): once when it changes, never for each call.
    @Test func aStartsEndIsReportedWhenItChanges() {
        final class Reports: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        }
        let reports = Reports()
        let plan = plan([fakeServer()])
        let hub = MCPHubSession(plan: plan, refresh: { plan }, nxtrm: ["/usr/bin/true"], environment: ["HOME": NSHomeDirectory()],
                                version: "0.0.0", report: { server, list, failure, tools in
                                    reports.add("\(server) \(list) \(failure ?? "ok") \(tools)")
                                })
        _ = hub.call("mcp_call", ["server": "fake", "tool": "echo"])
        _ = hub.call("mcp_call", ["server": "fake", "tool": "echo"])
        hub.stop()
        #expect(reports.all == ["fake /u/mcp.json ok 6"])
    }

    @Test func nxtrmIsTheBridgesOwnProgram() throws {
        let hub = session(plan([]))
        let wrapped = MCPHubPlan.Server(name: "gh", state: .ready, command: "nxtrm", args: ["secret", "run", "GH_TOKEN", "--", "npx", "x"], list: "/u")
        let launch = try hub.launch(wrapped, in: MCPHubPlan(folder: folder, path: ["/nowhere"])).get()
        #expect(launch.executable == "/usr/bin/true" && launch.arguments == ["secret", "run", "GH_TOKEN", "--", "npx", "x"])
        #expect(launch.environment["PATH"] == "/nowhere" && launch.directory == folder)
        // A relative path is the folder's.
        let relative = MCPHubPlan.Server(name: "r", state: .ready, command: "bin/server", list: "/u")
        #expect(try hub.launch(relative, in: MCPHubPlan(folder: folder)).get().executable == folder + "/bin/server")
    }

    // MARK: failing calmly

    @Test func aHugeResultIsCutAndSaysSo() {
        let hub = session(plan([fakeServer()]))
        defer { hub.stop() }
        let result = hub.call("mcp_call", ["server": "fake", "tool": "big"])
        let content = result["content"] as? [[String: Any]] ?? []
        #expect(content.count == 2)
        #expect((content.first?["text"] as? String)?.count == MCPHubCatalog.resultLimit)
        #expect((content.last?["text"] as? String ?? "").contains("Next Term cut this result"))
        #expect(result["isError"] as? Bool != true)
    }

    @Test func fittingKeepsWhatFits() {
        let small: [String: Any] = ["content": [["type": "text", "text": "abc"]], "structuredContent": ["a": 1], "isError": true]
        let kept = MCPHubCatalog.fit(small, limit: 100)
        #expect((kept["content"] as? [[String: Any]])?.count == 1 && kept["structuredContent"] != nil && kept["isError"] as? Bool == true)
        let image: [String: Any] = ["content": [["type": "text", "text": "abc"], ["type": "image", "data": String(repeating: "A", count: 500), "mimeType": "image/png"]]]
        let cut = MCPHubCatalog.fit(image, limit: 100)["content"] as? [[String: Any]] ?? []
        #expect(cut.count == 2 && cut[0]["text"] as? String == "abc" && (cut[1]["text"] as? String ?? "").contains("cut this result"))
    }

    @Test func aMessageOverTheLimitStopsTheServer() {
        let hub = session(plan([fakeServer()]), limits: MCPHubUpstream.Limits(message: 100_000))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_call", ["server": "fake", "tool": "big"]))
        #expect(isError && said.contains("sent a message over"))
        // The next need starts it again.
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])) == ("hello from fake", false))
    }

    @Test func aCallWithNoAnswerTimesOut() {
        let hub = session(plan([fakeServer()]), limits: MCPHubUpstream.Limits(start: 5, call: 1.5))
        defer { hub.stop() }
        let started = Date()
        let (said, isError) = text(hub.call("mcp_call", ["server": "fake", "tool": "slow"]))
        #expect(isError && said.contains("fake didn't answer Next Term's call in time"))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func aServerThatExitsIsNamedWithWhatItSaid() {
        let hub = session(plan([fakeServer()]))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_call", ["server": "fake", "tool": "die"]))
        #expect(isError && said.contains("fake stopped (exit status 3)") && said.contains("fake: dying on purpose"))
        let row = (json(hub.call("mcp_servers", [:]))["servers"] as? [[String: Any]])?.first
        #expect(row?["state"] as? String == "failed")
        // And it starts again when next needed.
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])) == ("hello from fake", false))
    }

    @Test func outputThatIsntMCPIsQuotedWhenTheWaitRunsOut() throws {
        let noisy = (script as NSString).deletingLastPathComponent + "/noisy.sh"
        try "#!/bin/sh\necho 'Server listening on stdio'\ncat >/dev/null\n".write(toFile: noisy, atomically: true, encoding: .utf8)
        let hub = session(plan([fakeServer("noisy", script: noisy)]), limits: MCPHubUpstream.Limits(start: 1, call: 5))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_tools", ["server": "noisy"]))
        #expect(isError && said.contains("noisy didn't answer Next Term's start in time"))
        #expect(said.contains("a line to its output that isn't MCP, the first: Server listening on stdio"))
        // A line of noise from a running server is passed over; the call itself still times out calmly.
        let fake = session(plan([fakeServer()]), limits: MCPHubUpstream.Limits(start: 5, call: 1.5))
        defer { fake.stop() }
        let (noise, noiseIsError) = text(fake.call("mcp_call", ["server": "fake", "tool": "noise"]))
        #expect(noiseIsError && noise.contains("this is not json"))
    }

    @Test func aServerThatNeverStartsIsNamed() throws {
        let broken = (script as NSString).deletingLastPathComponent + "/broken.sh"
        try "#!/bin/sh\necho 'missing module' >&2\nexit 1\n".write(toFile: broken, atomically: true, encoding: .utf8)
        let hub = session(plan([fakeServer("broken", script: broken)]))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_call", ["server": "broken", "tool": "x"]))
        #expect(isError && said.contains("broken stopped (exit status 1)") && said.contains("missing module"))
    }

    /// A server that answers its start with `version`, lists one tool, then does `then` (a shell line) and reads nothing more.
    func oneShot(_ name: String, version: String = "2025-06-18", then: String) throws -> String {
        let file = (script as NSString).deletingLastPathComponent + "/\(name).sh"
        let id = #"id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"#
        try ("#!/bin/sh\nread -r line; \(id)\n"
            + #"printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"\#(version)","capabilities":{}}}\n' "$id""# + "\n"
            + "read -r line\nread -r line; \(id)\n"
            + #"printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"take","inputSchema":{"type":"object"}}]}}\n' "$id""# + "\n"
            + then + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func aServerThatStopsReadingCantHoldACallPastItsLimit() throws {
        let deaf = try oneShot("deaf", then: "exec sleep 30")
        let hub = session(plan([fakeServer("deaf", script: deaf)]), limits: MCPHubUpstream.Limits(start: 5, call: 1.5))
        defer { hub.stop() }
        // More than a pipe holds, to a server that never reads it: the write waits for room only until the deadline.
        let started = Date()
        let (said, isError) = text(hub.call("mcp_call", ["server": "deaf", "tool": "take", "arguments": ["text": String(repeating: "a", count: 1 << 20)]]))
        #expect(isError && said.contains("deaf stopped reading what Next Term sends it"))
        #expect(Date().timeIntervalSince(started) < 4)
        // Half a message garbles the next: the server was stopped, and says so until it starts again.
        let row = (json(hub.call("mcp_servers", [:]))["servers"] as? [[String: Any]])?.first
        #expect(row?["state"] as? String == "failed")
    }

    @Test func aServerOnAnMCPVersionNextTermDoesntSpeakIsRefused() throws {
        let future = try oneShot("future", version: "1999-01-01", then: "cat >/dev/null")
        let hub = session(plan([fakeServer("future", script: future)]))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_tools", ["server": "future"]))
        #expect(isError && said.contains("future answered with MCP version 1999-01-01, and Next Term speaks 2025-11-25"))
    }

    @Test func aKeyAServerWritesToStderrIsMasked() throws {
        let leaky = (script as NSString).deletingLastPathComponent + "/leaky.sh"
        try "#!/bin/sh\necho 'auth failed for sk-ant-api03-abcdefghijklmnopqrstuvwxyz' >&2\nexit 1\n"
            .write(toFile: leaky, atomically: true, encoding: .utf8)
        let hub = session(plan([fakeServer("leaky", script: leaky)]))
        defer { hub.stop() }
        let (said, isError) = text(hub.call("mcp_call", ["server": "leaky", "tool": "x"]))
        #expect(isError && said.contains("auth failed for •••") && !said.contains("sk-ant-api03"))
    }

    @Test func aStoppedSessionStartsNothing() {
        let hub = session(plan([fakeServer()]))
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])) == ("hello from fake", false))
        hub.stop()
        let (said, isError) = text(hub.call("mcp_call", ["server": "fake", "tool": "echo"]))
        #expect(isError && said.contains("its session is ending"))
    }

    // MARK: mid-session

    @Test func aServerConnectedMidSessionIsReachedThroughTheCatalog() {
        let box = Box(plan([fakeServer()]))
        let hub = session(box.plan, refresh: { box.plan })
        defer { hub.stop() }
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])).1 == false)
        box.plan = plan([fakeServer(), fakeServer("later")])
        #expect(text(hub.call("mcp_call", ["server": "later", "tool": "echo"])) == ("hello from fake", false))
        // One removed is stopped and gone.
        box.plan = plan([fakeServer("later")])
        #expect(((json(hub.call("mcp_servers", [:]))["servers"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } == ["later"])
        #expect(text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])).0.contains("No MCP server named fake"))
    }

    @Test func manyCallsAtOnceShareOneStart() {
        let hub = session(plan([fakeServer()]))
        defer { hub.stop() }
        let answers = NSLock()
        var said: [String] = []
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            let answer = text(hub.call("mcp_call", ["server": "fake", "tool": "echo"])).0
            answers.lock()
            said.append(answer)
            answers.unlock()
        }
        #expect(said == Array(repeating: "hello from fake", count: 6))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MCPHubPlan
        init(_ plan: MCPHubPlan) { value = plan }
        var plan: MCPHubPlan {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
}
