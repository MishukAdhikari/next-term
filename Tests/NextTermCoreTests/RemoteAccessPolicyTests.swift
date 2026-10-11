import Foundation
import Testing
@testable import NextTermCore

/// The remote door's policy: which calls a connection's options admit, the remote limits on their arguments, the
/// general rate limits, and the shaping of each result (masking, the selection cut and the 64,000-character cap).
@Suite struct RemoteAccessPolicyTests {
    typealias ID = RemoteAccessOption.ID
    typealias Policy = RemoteAccessPolicy
    typealias Text = RemoteAccessText

    // Secrets in their real shapes, built in pieces so no scanner takes the source for a leak.
    static let github = "ghp_" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7c"
    static let aws = "AKIA" + "IOSFODNN7EXAMPLE"
    static let openAI = "sk-" + "proj" + "Q1w2E3r4T5y6U7i8O9p0"
    static let longSecret = "Zx9Yw8Vu7Ts6" + "Rq5Po4Nm3Lk2Ji1Hg0FeDc"
    static let access = "ntat_" + "q8Zr0vYb3Kd7Wm1Xn5Tc9Hs2Jf6Lg4Pa0Ue8Ri3Ow7"
    static let lowerRefresh = "ntrt_" + "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopq"

    // MARK: helpers

    func allowed(_ decision: Policy.Decision) -> [String: Any]? {
        if case .allow(let arguments) = decision { return arguments }
        return nil
    }

    func refusal(_ decision: Policy.Decision) -> String? {
        if case .refuse(let text) = decision { return text }
        return nil
    }

    func invalid(_ decision: Policy.Decision) -> String? {
        if case .invalidParams(let text) = decision { return text }
        return nil
    }

    func unknown(_ decision: Policy.Decision) -> String? {
        if case .unknownTool(let text) = decision { return text }
        return nil
    }

    func decide(_ tool: String, _ arguments: [String: Any] = [:],
                options: RemoteAccessOptions = .readOnly) -> Policy.Decision {
        Policy.decide(tool: tool, arguments: arguments, options: options)
    }

    /// The option table as U14 fills it for typing: the three typing options name send_to_tab and press_keys.
    var typingRows: [RemoteAccessOption] {
        let typing: Set<ID> = [.typeAsking, .typeNeverAsking, .typeShells]
        return RemoteAccessOption.all.map { row in
            guard typing.contains(row.id) else { return row }
            return RemoteAccessOption(id: row.id, group: row.group, label: row.label, control: row.control,
                                      customStart: row.customStart, tools: ["send_to_tab", "press_keys"])
        }
    }

    func turnOn(_ labels: String...) -> String {
        let quoted = labels.map { "“\($0)”" }.joined(separator: " and ")
        return "Turn on \(quoted) for this connection in Settings › Remote Access on your Mac."
    }

    func object(_ text: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(parsed as? [String: Any])
    }

    func shaped(_ value: [String: Any], tool: String) -> MCPServer.CallResult {
        Policy.shape(MCPServer.CallResult(text: MCPServer.json(value)), tool: tool)
    }

    /// Lines such as "line 00042 xxx…", each 70 characters, with a line break after each but the last.
    func lines(_ count: Int) -> String {
        let filler = String(repeating: "x", count: 59)
        let all = (1...count).map { String(format: "line %05d ", $0) + filler }
        return all.joined(separator: "\n")
    }

    func scalars(_ text: String) -> Int { text.unicodeScalars.count }

    // MARK: remote limits

    @Test func readTabLinesAreAtMost400() throws {
        let many = try #require(allowed(decide("read_tab", ["tab_id": "a", "lines": 2000])))
        #expect(many["lines"] as? Int == 400)
        let some = try #require(allowed(decide("read_tab", ["tab_id": "a", "lines": 120])))
        #expect(some["lines"] as? Int == 120)
        let none = try #require(allowed(decide("read_tab", ["tab_id": "a", "lines": 0])))
        #expect(none["lines"] as? Int == 1)
        // Left out, it is the local default of 80, which is inside the remote limit.
        let missing = try #require(allowed(decide("read_tab", ["tab_id": "a"])))
        #expect(missing["lines"] == nil)
        #expect(missing["tab_id"] as? String == "a")
        // A fraction is read as a number too, so it can't slip past the limit.
        let fraction = try #require(allowed(decide("read_tab", ["tab_id": "a", "lines": 1999.5])))
        #expect(fraction["lines"] as? Int == 400)
    }

    @Test func waitForTabWaitsOneToFiftySecondsAndFiftyByDefault() throws {
        let cases: [(Any?, Int)] = [(300, 50), (0, 1), (nil, 50), (-7, 1), (12, 12), (2.9, 2), ("300", 50), (true, 50)]
        for (given, wanted) in cases {
            var arguments: [String: Any] = ["tab_id": "a"]
            if let given { arguments["timeout_seconds"] = given }
            let decided = try #require(allowed(decide("wait_for_tab", arguments)), "\(String(describing: given))")
            #expect(decided["timeout_seconds"] as? Int == wanted, "\(String(describing: given))")
        }
    }

    @Test func everyRemoteLimitHolds() throws {
        let file = try #require(allowed(decide("read_file", ["path": "a.txt", "limit": 2000])))
        #expect(file["limit"] as? Int == 500)
        let diff = try #require(allowed(decide("get_diff", ["max_chars": 200_000])))
        #expect(diff["max_chars"] as? Int == 60_000)
        let small = try #require(allowed(decide("get_diff", ["max_chars": 10])))
        #expect(small["max_chars"] as? Int == 1000)
        let found = try #require(allowed(decide("find_in_files", ["query": "a", "max_results": 900])))
        #expect(found["max_results"] as? Int == 200)
        // Locally host_changes gives 200,000 by default; remotely 60,000, given or not.
        let changes = try #require(allowed(decide("host_changes", ["host": "h", "max_bytes": 2_000_000], options: .control)))
        #expect(changes["max_bytes"] as? Int == 60_000)
        let changesDefault = try #require(allowed(decide("host_changes", ["host": "h"], options: .control)))
        #expect(changesDefault["max_bytes"] as? Int == 60_000)
    }

    @Test func sendToTabTextIsAtMost8000Characters() {
        let full = String(repeating: "a", count: 8000)
        #expect(Policy.overLimit("send_to_tab", ["tab_id": "a", "text": full]) == nil)
        let over = full + "a"
        #expect(Policy.overLimit("send_to_tab", ["tab_id": "a", "text": over]) == Text.textTooLong)
        #expect(Text.textTooLong == "Text is limited to 8,000 characters remotely.")
        // Counted as JSON Schema counts a string: one per Unicode scalar.
        let faces = String(repeating: "😀", count: 8000)
        #expect(Policy.overLimit("send_to_tab", ["text": faces]) == nil)
        #expect(Policy.overLimit("read_tab", ["text": over]) == nil)
    }

    // MARK: what the options admit

    @Test func aToolTheOptionsLeaveOutNamesTheOptionThatAdmitsIt() throws {
        let hosts = try #require(refusal(decide("list_hosts", ["x": 1])))
        let wanted = "This connection can't use list_hosts. " + turnOn("Servers: list, check and read changes")
        #expect(hosts == wanted)
        var noTabs = RemoteAccessOptions.customStart
        noTabs[.tabs] = false
        let tab = try #require(refusal(decide("read_tab", ["tab_id": "a"], options: noTabs)))
        #expect(tab == "This connection can't use read_tab. " + turnOn("Tabs and their output"))
        #expect(allowed(decide("list_hosts", options: .control)) != nil)
    }

    @Test func typingToolsNameTheirOptionsOnceTheTableNamesThem() throws {
        let rows = typingRows
        func refused(_ tool: String, _ options: RemoteAccessOptions) -> String? {
            refusal(Policy.decide(tool: tool, arguments: ["tab_id": "a"], options: options, rows: rows))
        }
        let send = try #require(refused("send_to_tab", .readOnly))
        #expect(send == "This connection can't use send_to_tab. " + turnOn("Type into agents that ask before acting"))
        // press_keys needs a typing option and a Keys option, and names the first of each half that has none on.
        let keys = try #require(refused("press_keys", .readOnly))
        let both = turnOn("Type into agents that ask before acting", "Arrows, Return and Escape")
        #expect(keys == "This connection can't use press_keys. " + both)
        var typing = RemoteAccessOptions.readOnly
        typing[.typeNeverAsking] = true
        let half = try #require(refused("press_keys", typing))
        #expect(half == "This connection can't use press_keys. " + turnOn("Arrows, Return and Escape"))
        var everyKey = RemoteAccessOptions.readOnly
        everyKey[.everyKey] = true
        let other = try #require(refused("press_keys", everyKey))
        #expect(other == "This connection can't use press_keys. " + turnOn("Type into agents that ask before acting"))
        #expect(Policy.needs("press_keys", rows: rows) == [[.typeAsking, .typeNeverAsking, .typeShells], [.safeKeys, .everyKey]])
        #expect(Policy.needs("send_to_tab", rows: rows) == [[.typeAsking, .typeNeverAsking, .typeShells]])
    }

    @Test func aToolNoOptionNamesIsNotAvailableRemotely() throws {
        // The import tools stay local: no option names them (allow by name).
        for tool in MCPServer.importTools {
            let text = try #require(refusal(decide(tool.name, options: .control)), "\(tool.name)")
            #expect(text == "This tool is not available remotely.")
        }
        #expect(Policy.needs("apply_import", rows: RemoteAccessOption.all).isEmpty)
    }

    @Test func aNameNextTermDoesNotKnowIsAnUnknownTool() throws {
        let made = try #require(unknown(decide("made_up_tool", options: .control)))
        #expect(made == "Unknown tool: made_up_tool")
        #expect(refusal(decide("made_up_tool")) == nil)
    }

    @Test func theDoorsOwnTextsReadAsThePlanWritesThem() {
        #expect(Text.turnedOff == "Access was turned off on the Mac.")
        #expect(Text.declined == "Declined on your Mac.")
        #expect(Text.deadline == "Next Term on the Mac did not answer in time. A dialog may be open there. Try again.")
        #expect(Text.oldTab == "That tab is gone, maybe because Next Term restarted. Call list_tabs.")
        #expect(Text.notAvailable == "This tool is not available remotely.")
        let two = Text.turnOn([.anySlash, .shellAndMemory])
        #expect(two == turnOn("Any / command", "! shell lines and # memory lines"))
    }

    @Test func anArgumentTheRemoteSchemaDoesNotListIsInvalidParams() throws {
        let text = try #require(invalid(decide("read_tab", ["tab_id": "a", "foo": 1])))
        #expect(text == "Invalid params: foo is not an argument of read_tab.")
        // A tool the options leave out gets the can't-use text first, whatever its arguments.
        #expect(refusal(decide("list_hosts", ["foo": 1])) != nil)
        // force on close_tab, once a connection's schema leaves it out, names the option that adds it.
        let force = Text.notAnArgument("force", of: "close_tab")
        #expect(force == "Invalid params: force is not an argument of close_tab. " + turnOn("Close busy tabs"))
    }

    /// The argument check says what each remote schema says: no argument it does not list.
    @Test func everyRemoteSchemaRefusesArgumentsItDoesNotList() throws {
        for tool in RemoteAccessTools.tools(for: .control) {
            let schema = try object(tool.inputSchema)
            #expect(schema["additionalProperties"] as? Bool == false, "\(tool.name)")
        }
    }

    /// The door's tool check and the catalogue agree: a call is allowed exactly when tools/list offers the tool.
    @Test func thePolicyAdmitsExactlyWhatTheCatalogueOffers() {
        var sets: [RemoteAccessOptions] = [.readOnly, .control, .customStart, RemoteAccessOptions(on: [])]
        for id in ID.allCases {
            var flipped = RemoteAccessOptions.customStart
            flipped[id].toggle()
            sets.append(flipped)
        }
        for options in sets {
            let offered = Set(RemoteAccessTools.tools(for: options).map(\.name))
            for tool in MCPServer.tools {
                let decision = decide(tool.name, options: options)
                #expect((allowed(decision) != nil) == offered.contains(tool.name), "\(tool.name) \(options.on)")
                let halves = Policy.needs(tool.name, rows: RemoteAccessOption.all)
                let admitted = !halves.isEmpty && halves.allSatisfy { half in half.contains { options[$0] } }
                #expect(admitted == offered.contains(tool.name), "\(tool.name) \(options.on)")
            }
        }
    }

    // MARK: rate limits

    /// A slot, or nil. Outside `#expect` and `#require`, which can't call a mutating method.
    func take(_ limiter: inout RemoteAccessRateLimiter, _ grant: String, _ now: Date) -> RemoteAccessRateLimiter.Slot? {
        limiter.acquire(grant: grant, now: now)
    }

    @Test func theHundredAndTwentyFirstCallInAMinuteIsRefused() throws {
        var limiter = RemoteAccessRateLimiter()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        for call in 0..<120 {
            let at = start.addingTimeInterval(Double(call) * 0.4)
            let slot = try #require(take(&limiter, "g1", at), "call \(call)")
            limiter.release(slot)
        }
        let late = start.addingTimeInterval(59.9)
        let refused = take(&limiter, "g1", late)
        #expect(refused == nil)
        // Another grant has its own minute.
        let other = take(&limiter, "g2", late)
        #expect(other != nil)
        // Sixty seconds after the first call, it no longer counts.
        let next = take(&limiter, "g1", start.addingTimeInterval(60))
        #expect(next != nil)
        #expect(Text.tooManyCalls == "Too many calls; try again in a few seconds.")
    }

    @Test func aGrantRunsThreeCallsAtOnceAndAllGrantsSix() throws {
        var limiter = RemoteAccessRateLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 5000)
        var first: [RemoteAccessRateLimiter.Slot] = []
        for _ in 0..<3 { first.append(try #require(take(&limiter, "a", now))) }
        let fourth = take(&limiter, "a", now)
        #expect(fourth == nil)
        for _ in 0..<3 { _ = try #require(take(&limiter, "b", now)) }
        // Six run: a seventh waits for a slot, from any grant.
        let seventh = take(&limiter, "c", now)
        #expect(seventh == nil)
        #expect(limiter.runningCount == 6)
        limiter.release(first[0])
        let freed = try #require(take(&limiter, "c", now))
        let stillFull = take(&limiter, "a", now)
        #expect(stillFull == nil)
        // A slot frees once: releasing it again frees no other.
        limiter.release(freed)
        limiter.release(freed)
        _ = try #require(take(&limiter, "c", now))
        let again = take(&limiter, "c", now)
        #expect(again == nil)
    }

    @Test func aRefusedCallTakesNoSlotAndCountsNothing() throws {
        var limiter = RemoteAccessRateLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 9000)
        var slots: [RemoteAccessRateLimiter.Slot] = []
        for _ in 0..<3 { slots.append(try #require(take(&limiter, "a", now))) }
        for _ in 0..<200 {
            let refused = take(&limiter, "a", now)
            #expect(refused == nil)
        }
        for slot in slots { limiter.release(slot) }
        // Three ran; the refused ones never counted toward the 120.
        for _ in 0..<117 {
            let slot = try #require(take(&limiter, "a", now))
            limiter.release(slot)
        }
        let over = take(&limiter, "a", now)
        #expect(over == nil)
    }

    @Test func aClockSetBackDoesNotKeepOldCallsCounting() throws {
        var limiter = RemoteAccessRateLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        for _ in 0..<120 {
            let slot = try #require(take(&limiter, "a", now))
            limiter.release(slot)
        }
        let full = take(&limiter, "a", now.addingTimeInterval(30))
        #expect(full == nil)
        // Starts after "now" no longer count, so a clock set back an hour doesn't lock the grant out for an hour.
        let earlier = take(&limiter, "a", now.addingTimeInterval(-3600))
        #expect(earlier != nil)
    }

    // MARK: masking

    @Test func aScreenIsMaskedAndCounted() throws {
        let screen = "export GITHUB_TOKEN=\(Self.github)\naws key \(Self.aws) in use\n$ "
        let result = shaped(["id": "t1", "state": "idle", "screen": screen], tool: "read_tab")
        let json = try object(result.text)
        let masked = try #require(json["screen"] as? String)
        #expect(!masked.contains(Self.github) && !masked.contains(Self.aws))
        #expect(masked == "export GITHUB_TOKEN=•••\naws key ••• in use\n$ ")
        #expect(json["redacted"] as? Int == 2)
        #expect(json["truncated"] == nil)
        #expect(!result.isError)
    }

    @Test func aCommandWithATokenFlagIsMasked() throws {
        let tab: [String: Any] = ["id": "t1", "title": "deploy", "command": "deploy --token=\(Self.longSecret) --prod"]
        let windows: [[String: Any]] = [["project": "/work/app", "tabs": [tab]]]
        let result = shaped(["windows": windows], tool: "list_tabs")
        #expect(!result.text.contains(Self.longSecret))
        #expect(result.text.contains("deploy --token=••• --prod"))
        #expect(try object(result.text)["redacted"] as? Int == 1)
    }

    @Test func theDoorsOwnTokensAreMasked() throws {
        let screen = "Bearer \(Self.access)\nrefresh \(Self.lowerRefresh) and \(Self.lowerRefresh.uppercased())"
        let result = shaped(["screen": screen], tool: "read_tab")
        let lowered = result.text.lowercased()
        #expect(!lowered.contains("ntat_") && !lowered.contains("ntrt_"))
        #expect(try object(result.text)["redacted"] as? Int == 3)
    }

    @Test func aMaskMadeBeforeIsNotCountedAgain() throws {
        // A screen can show a result masked before, as an agent prints what read_file gave it. Its masks hide
        // nothing new, so only the new key counts.
        let raw = "postgres://admin:hunter2pass@db.example.com/app\n" +
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\nqwerty\n-----END RSA PRIVATE KEY-----"
        let earlier = MCPRedaction.redact(raw).text
        #expect(!earlier.contains("hunter2") && earlier.contains("admin:•••@"))
        let screen = earlier + "\nexport GITHUB_TOKEN=\(Self.github)"
        let json = try object(shaped(["screen": screen], tool: "read_tab").text)
        #expect(json["screen"] as? String == earlier + "\nexport GITHUB_TOKEN=•••")
        #expect(json["redacted"] as? Int == 1)
        // With nothing new, nothing changes.
        let old = shaped(["screen": earlier], tool: "read_tab")
        #expect(try object(old.text)["redacted"] == nil)
        // A key's first line left showing over masked lines is new: it counts once, not again for the block.
        let header = "-----BEGIN RSA PRIVATE KEY-----\n•••\n•••\n-----END RSA PRIVATE KEY-----"
        let key = try object(shaped(["screen": header], tool: "read_tab").text)
        #expect(key["screen"] as? String == "•••\n•••\n•••\n-----END RSA PRIVATE KEY-----")
        #expect(key["redacted"] as? Int == 1)
    }

    @Test func errorsAndTextThatIsNotJSONAreMaskedToo() {
        let failed = Policy.shape(MCPServer.CallResult(text: "git said: bad key \(Self.openAI)", isError: true), tool: "commit")
        #expect(failed.isError)
        #expect(failed.text == "git said: bad key •••")
        let plain = Policy.shape(MCPServer.CallResult(text: "token \(Self.access) here"), tool: "read_tab")
        #expect(plain.text == "token ••• here")
    }

    @Test func anOldTabIDGetsTheRemoteText() {
        let gone = MCPServer.CallResult(text: "No tab with that id; list_tabs shows them.", isError: true)
        let result = Policy.shape(gone, tool: "read_tab")
        #expect(result.text == "That tab is gone, maybe because Next Term restarted. Call list_tabs.")
        #expect(result.isError)
        // Only an error says so; a result that quotes it is left as it is.
        let quoted = MCPServer.CallResult(text: "No tab with that id; list_tabs shows them.")
        #expect(Policy.shape(quoted, tool: "read_tab").text == quoted.text)
    }

    @Test func aResultWithNothingToChangeKeepsItsText() {
        let text = "{\n  \"b\" : 1,\n  \"a\" : \"plain words\"\n}"
        #expect(Policy.shape(MCPServer.CallResult(text: text), tool: "list_projects").text == text)
        let words = "Nothing here to hide."
        #expect(Policy.shape(MCPServer.CallResult(text: words), tool: "read_tab").text == words)
    }

    // MARK: cuts

    @Test func aLongScreenIsCutAtALineBreakAndKeepsItsEnd() throws {
        let screen = lines(1000)
        #expect(scalars(screen) > 70_000)
        let result = shaped(["id": "t1", "state": "working", "screen": screen], tool: "read_tab")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["truncated"] as? Bool == true)
        let note = try #require(json["truncated_note"] as? String)
        #expect(note.contains("fewer lines"))
        let kept = try #require(json["screen"] as? String)
        #expect(kept.hasSuffix(String(format: "line %05d ", 1000) + String(repeating: "x", count: 59)))
        #expect(kept.hasPrefix("line "))
        #expect(screen.hasSuffix("\n" + kept))
        #expect(!kept.contains("line 00001 "))
        #expect(json["state"] as? String == "working")
    }

    @Test func aLongFileIsCutAtALineBreakAndKeepsItsStart() throws {
        let text = lines(1000)
        let file: [String: Any] = ["path": "a.txt", "start_line": 1, "end_line": 1000, "total_lines": 1000, "text": text]
        let result = shaped(file, tool: "read_file")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["truncated"] as? Bool == true)
        let kept = try #require(json["text"] as? String)
        #expect(kept.hasPrefix("line 00001 "))
        #expect(text.hasPrefix(kept + "\n"))
        #expect(!kept.contains("line 01000 "))
        #expect(try #require(json["truncated_note"] as? String).contains("limit"))
    }

    @Test func escapedCharactersCountTowardTheCap() throws {
        // Each quote and backslash takes two characters in JSON, so 40,800 of them encode to more than 64,000.
        let line = String(repeating: "\"\\", count: 25)
        let screen = Array(repeating: line, count: 800).joined(separator: "\n")
        let result = shaped(["screen": screen], tool: "read_tab")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["truncated"] as? Bool == true)
        let kept = try #require(json["screen"] as? String)
        #expect(kept.hasPrefix(line) && screen.hasSuffix(kept))
    }

    @Test func theLongestStringIsCutFirst() throws {
        let long = lines(700)
        let short = String(repeating: "short words\n", count: 2000)
        let result = shaped(["diff": long, "status": short], tool: "get_diff")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["status"] as? String == short)
        let kept = try #require(json["diff"] as? String)
        #expect(kept.count < long.count && long.hasPrefix(kept))
    }

    @Test func manyStringsAreCutToOneLength() throws {
        // 300 matches of 400 characters each: too long together, so the longest strings are cut down to one length
        // in one go, and the short ones keep theirs.
        let line = String(repeating: "m", count: 400)
        var matches: [[String: Any]] = []
        for index in 1...300 {
            matches.append(["path": String(format: "src/file-%04d.swift", index), "line": index, "text": line])
        }
        let result = shaped(["matches": matches, "total": 300], tool: "find_in_files")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["truncated"] as? Bool == true)
        let kept = try #require(json["matches"] as? [[String: Any]])
        #expect(kept.count == 300)
        let lengths = Set(kept.compactMap { ($0["text"] as? String)?.count })
        #expect(lengths.count == 1)
        let length = try #require(lengths.first)
        #expect(length > 0 && length < 400)
        #expect(kept.last?["path"] as? String == "src/file-0300.swift")
        #expect(json["total"] as? Int == 300)
    }

    @Test func aHugeScreenKeepsItsEndMasked() throws {
        let screen = lines(15_000) + "\nexport GITHUB_TOKEN=\(Self.github)\n$ "
        #expect(scalars(screen) > 1_000_000)
        let result = shaped(["id": "t1", "screen": screen], tool: "read_tab")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        let kept = try #require(json["screen"] as? String)
        #expect(kept.hasSuffix("\nexport GITHUB_TOKEN=•••\n$ "))
        #expect(kept.hasPrefix("line "))
        #expect(json["redacted"] as? Int == 1)
        #expect(json["truncated"] as? Bool == true)
    }

    @Test func aResultWhoseStringsCantShrinkEnoughSaysItIsTooLong() throws {
        // 9,000 numbers: no string to cut, so the result says what to do instead of going out too long.
        let numbers = Array(1...9000).map { $0 * 1_000_003 }
        let result = shaped(["numbers": numbers, "name": "x"], tool: "git_status")
        #expect(scalars(result.text) <= 64_000)
        let json = try object(result.text)
        #expect(json["truncated"] as? Bool == true)
        #expect(json["numbers"] == nil)
        #expect(try #require(json["truncated_note"] as? String).contains("Ask for less"))
    }

    @Test func aLongTextIsCutWithANote() {
        let result = Policy.shape(MCPServer.CallResult(text: lines(1000)), tool: "host_sessions")
        #expect(scalars(result.text) <= 64_000)
        #expect(result.text.hasPrefix("line 00001 "))
        #expect(result.text.hasSuffix("… (truncated: cut to fit 64,000 characters)"))
    }

    @Test func aLongSelectionIsCutTo16000Characters() throws {
        let selection = String(repeating: "abcd\n", count: 4000)
        #expect(selection.count == 20_000)
        let result = shaped(["file": "/work/a.swift", "text": selection], tool: "get_editor_selection")
        let json = try object(result.text)
        let kept = try #require(json["text"] as? String)
        #expect(kept.count == 16_000)
        #expect(selection.hasPrefix(kept))
        #expect(json["truncated"] as? Bool == true)
        // Another tool's text field is not a selection.
        let other = shaped(["text": selection], tool: "read_file")
        #expect(try object(other.text)["text"] as? String == selection)
    }

    @Test func aSecretAtACutIsMaskedNotHalfShown() throws {
        // The key starts before the 16,000th character and ends after it: it is masked before the cut.
        let head = String(repeating: "a", count: 15_990)
        let selection = head + " " + Self.github + " " + String(repeating: "x", count: 100)
        let result = shaped(["text": selection], tool: "get_editor_selection")
        let kept = try #require(try object(result.text)["text"] as? String)
        #expect(!kept.contains("ghp_") && !kept.contains("Ab3dEf"))
        #expect(kept.hasPrefix(head + " ••• x"))
        #expect(kept.count == 16_000)
    }

    // MARK: shaping twice

    @Test func shapingAShapedResultChangesNothing() {
        let key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\nqwerty\n-----END RSA PRIVATE KEY-----"
        var results: [(String, [String: Any])] = []
        results.append(("read_tab", ["screen": "export GITHUB_TOKEN=\(Self.github)\nok"]))
        results.append(("read_tab", ["screen": lines(1000)]))
        results.append(("read_file", ["text": "postgres://admin:hunter2pass@db.example.com/app\n" + key]))
        results.append(("get_editor_selection", ["text": String(repeating: "abcd\n", count: 4000)]))
        let tab: [String: Any] = ["command": "x --token=\(Self.longSecret)"]
        let window: [String: Any] = ["tabs": [tab]]
        results.append(("list_tabs", ["windows": [window]]))
        for (tool, value) in results {
            let once = shaped(value, tool: tool)
            let twice = Policy.shape(once, tool: tool)
            #expect(twice.text == once.text, "\(tool)")
        }
        let text = Policy.shape(MCPServer.CallResult(text: lines(1000) + " " + Self.access), tool: "x")
        #expect(Policy.shape(text, tool: "x").text == text.text)
    }

    @Test func aResultThatAlreadyCountsRedactionsKeepsACorrectTotal() throws {
        // read_file masks locally and says how many; the door counts only what it masks itself.
        let raw = "url = postgres://admin:hunter2pass@db.example.com/app\n" +
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
        let local = MCPRedaction.redact(raw)
        #expect(local.count >= 2)
        let file: [String: Any] = ["path": ".env.sample", "text": local.text, "redacted": local.count]
        let same = try object(shaped(file, tool: "read_file").text)
        #expect(same["redacted"] as? Int == local.count)
        var more = file
        more["text"] = local.text + "\nbearer \(Self.access)"
        let added = try object(shaped(more, tool: "read_file").text)
        #expect(added["redacted"] as? Int == local.count + 1)
        #expect(!(added["text"] as? String ?? "").contains("ntat_"))
    }
}
