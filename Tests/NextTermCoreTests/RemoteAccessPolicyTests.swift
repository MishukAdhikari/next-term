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

    /// Counts a call without a slot. Outside `#expect`, which can't call a mutating method.
    func counted(_ limiter: inout RemoteAccessRateLimiter, _ grant: String, _ now: Date) -> Bool {
        limiter.count(grant: grant, now: now)
    }

    /// A call the door answers without running it (the options leave its tool off, or its arguments don't fit)
    /// takes no slot but counts toward its grant's 120 a minute, so a token can't send refused calls without end.
    @Test func aCallAnsweredWithoutASlotStillCountsTowardTheMinute() throws {
        var limiter = RemoteAccessRateLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 15_000)
        for call in 0..<119 {
            let counts = counted(&limiter, "a", now)
            #expect(counts, "call \(call)")
        }
        #expect(limiter.runningCount == 0)
        // The 120th runs; then neither kind is let through until the minute has passed.
        let last = try #require(take(&limiter, "a", now))
        limiter.release(last)
        let over = counted(&limiter, "a", now.addingTimeInterval(59))
        #expect(!over)
        let noSlot = take(&limiter, "a", now.addingTimeInterval(59))
        #expect(noSlot == nil)
        // Another grant has its own minute, and a minute later the first counts again.
        let other = counted(&limiter, "b", now)
        #expect(other)
        let later = counted(&limiter, "a", now.addingTimeInterval(60))
        #expect(later)
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

    /// Commands and screens are terminal text: the shapes secrets take on a command line are masked there too
    /// (CommandSecrets), not only the key shapes, so a short password after a flag doesn't go out in clear.
    @Test func commandLineSecretsInCommandsAndScreensAreMasked() throws {
        let cases: [(String, String)] = [
            ("deploy --token=hunter2hunter2 --prod", "deploy --token=••• --prod"),
            ("mysql -u root -pS3cretPass1 app", "mysql -u root -p••• app"),
            ("curl -H 'Authorization: Bearer abc123def456ghi' https://api.example.com",
             "curl -H 'Authorization: •••' https://api.example.com"),
            ("psql --password=CorrectHorseBattery", "psql --password=•••"),
        ]
        for (command, wanted) in cases {
            let tab: [String: Any] = ["id": "t1", "title": "zsh", "command": command]
            let result = shaped(["windows": [["tabs": [tab]]]], tool: "list_tabs")
            let json = try object(result.text)
            let windows = try #require(json["windows"] as? [[String: Any]])
            let tabs = try #require(windows.first?["tabs"] as? [[String: Any]])
            #expect(tabs.first?["command"] as? String == wanted, "\(command)")
            #expect(json["redacted"] as? Int == 1, "\(command)")
        }
        // A secret typed after a prompt: the name is not at the start of its line, so only the command rules see it.
        let screen = "user@mac app % export DB_PASSWORD=correcthorse42\nuser@mac app % ls\nREADME.md"
        let json = try object(shaped(["id": "t1", "screen": screen], tool: "read_tab").text)
        let masked = "user@mac app % export DB_PASSWORD=•••\nuser@mac app % ls\nREADME.md"
        #expect(json["screen"] as? String == masked)
        #expect(json["redacted"] as? Int == 1)
    }

    /// A file's text is code, where `password=` is often an argument name: it keeps MCPRedaction's masking alone,
    /// as it has locally, while the same line on a screen is a command.
    @Test func aFileKeepsCodeThatOnlyLooksLikeACommand() throws {
        let code = "session.login(user=name, password=user_password)"
        for tool in ["read_file", "get_editor_selection"] {
            let json = try object(shaped(["text": code], tool: tool).text)
            #expect(json["text"] as? String == code, "\(tool)")
            #expect(json["redacted"] == nil, "\(tool)")
        }
        let screen = try object(shaped(["screen": code], tool: "read_tab").text)
        #expect(screen["screen"] as? String != code)
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

    // MARK: wrapped rows

    func screen(_ text: String) throws -> (screen: String, redacted: Int?) {
        let json = try object(shaped(["id": "t1", "screen": text], tool: "read_tab").text)
        return (try #require(json["screen"] as? String), json["redacted"] as? Int)
    }

    /// A narrow pane wraps a token onto the next row, and each half is too short for its pattern alone.
    @Test func aTokenWrappedOntoTheNextRowIsMaskedWhole() throws {
        // The name is masked on its row by the command rules; the rest of the token on the next row goes too, and
        // it is still one secret.
        let wrapped = try screen("$ export GITHUB_TOKEN=ghp_Ab3dEf6hIj\n9kLm2nOp5qRs8tUv1wXy4zAb7c\n$ ")
        #expect(wrapped.screen == "$ export GITHUB_TOKEN=•••\n•••\n$ ")
        #expect(wrapped.redacted == 1)
        // Neither half is masked alone: joined, they are one token, so both halves go.
        let bare = try screen("seen ghp_Ab3dEf6hIj9kLm\n2nOp5qRs8tUv1wXy4zAb7c\n$ ")
        #expect(bare.screen == "seen •••\n•••\n$ ")
        #expect(bare.redacted == 1)
        // A random key over two rows, 20 characters on each.
        let key = try screen("key: " + "Zx9Yw8Vu7Ts6Rq5Po4Nm" + "\n" + "3Lk2Ji1Hg0FeDcBa9Zy8\nok")
        #expect(key.screen == "key: •••\n•••\nok")
        #expect(key.redacted == 1)
    }

    @Test func aTokenWrappedOverManyRowsOfANarrowPaneIsMasked() throws {
        // 11 columns: no two rows together hold enough of the token to show its shape.
        let rows = "ghp_Ab3dEf6\nhIj9kLm2nOp\n5qRs8tUv1wX\ny4zAb7c\n$ "
        let narrow = try screen(rows)
        #expect(narrow.screen == "•••\n•••\n•••\n•••\n$ ")
        #expect(narrow.redacted == 1)
    }

    /// A row that ends with a whole secret, and a next row that starts with text, don't make one secret: the
    /// prompt after `export` keeps its name.
    @Test func aWholeSecretAtTheEndOfARowLeavesTheNextRowAlone() throws {
        let typed = "user@mac app % export GITHUB_TOKEN=\(Self.github)\nuser@mac app % "
        let shown = try screen(typed)
        #expect(shown.screen == "user@mac app % export GITHUB_TOKEN=•••\nuser@mac app % ")
        #expect(shown.redacted == 1)
        // A short secret after a name, then the prompt: joined, the name's value would take in the prompt's first
        // word, so names join rows only where the screen shows rows that wide wrap.
        let password = "user@mac app % export DB_PASSWORD=correcthorse42\nuser@mac app % "
        let prompt = try screen(password)
        #expect(prompt.screen == "user@mac app % export DB_PASSWORD=•••\nuser@mac app % ")
        #expect(prompt.redacted == 1)
        // A row shorter than the widest can't have wrapped: a row starting with text after it is a new line.
        let short = "$ echo done, and a longer line\nZx9Yw8Vu7Ts6Rq5Po4Nm\n3Lk2Ji1Hg0FeDcBa9Zy8\n$ "
        let kept = try screen(short)
        #expect(kept.screen == short)
        #expect(kept.redacted == nil)
    }

    /// A password after a flag, wrapped in a pane whose other rows show it is 40 columns wide.
    @Test func aPasswordWrappedAfterItsFlagIsMaskedWhereRowsThatWideWrap() throws {
        let log = "warning: NetworkingKit was built for new"
        let command = "$ deploy --region eu-west-1 --password=CorrectHorseBattery --verbose"
        #expect(scalars(log) == 40)
        let first = String(command.prefix(40)), rest = String(command.dropFirst(40))
        #expect(first.hasSuffix("--password=C"))
        let rows = ["$ cat build.log", log, "er macOS", first, rest, "$ "]
        let shown = try screen(rows.joined(separator: "\n"))
        let masked = ["$ deploy --region eu-west-1 --password=•••", "••• --verbose"]
        let wanted = ["$ cat build.log", log, "er macOS"] + masked + ["$ "]
        #expect(shown.screen == wanted.joined(separator: "\n"))
        #expect(shown.redacted == 1)
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
        // Every tool writes its result with MCPServer.json, so a result that needs nothing comes back as it went.
        let text = MCPServer.json(["b": 1, "a": "plain words", "list": ["x", "y"]] as [String: Any])
        #expect(Policy.shape(MCPServer.CallResult(text: text), tool: "list_projects").text == text)
        let words = "Nothing here to hide."
        #expect(Policy.shape(MCPServer.CallResult(text: words), tool: "read_tab").text == words)
    }

    /// The parse may not read every part of a text written another way: of a key given twice, JSONSerialization
    /// keeps one, and many clients keep the other. What goes out is always what was read and masked.
    @Test func aResultIsSentAsItWasReadNotAsItCame() throws {
        let twice = "{\"a\":\"b\", \"a\":\"\(Self.github)\"}"
        let result = Policy.shape(MCPServer.CallResult(text: twice), tool: "read_file")
        #expect(!result.text.contains(Self.github) && !result.text.contains("Ab3dEf"))
        let json = try object(result.text)
        #expect(json.count <= 2)
        // Written another way, but whole: it goes out as MCPServer.json writes it.
        let other = "{\"b\":1,\"a\":\"plain words\"}"
        let written = Policy.shape(MCPServer.CallResult(text: other), tool: "list_projects").text
        #expect(written == MCPServer.json(["a": "plain words", "b": 1] as [String: Any]))
    }

    /// Two keys that both mask to ••• keep both their values.
    @Test func keysThatMaskAlikeKeepEveryValue() throws {
        let value: [String: Any] = [Self.github: "first", Self.aws: "second", "plain": "third"]
        let json = try object(shaped(value, tool: "read_file").text)
        let values = Set(json.values.compactMap { $0 as? String })
        #expect(values == ["first", "second", "third"])
        #expect(json["•••"] != nil && json["••• (2)"] != nil)
        #expect(json["redacted"] as? Int == 2)
        #expect(!json.keys.contains { $0.contains("ghp_") || $0.contains("AKIA") })
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

    /// A random-looking base64 line of `length` characters, which masking takes as one long run.
    func blob(_ length: Int) -> String {
        let chunk = "Qm9vdHN0cmFwM2FsbFRoZVRoaW5nczEyMzQ1Njc4OTBhYmNkZWZnaGlqa2xtbm9w"
        let whole = String(repeating: chunk, count: length / chunk.count + 1)
        return String(whole.prefix(length))
    }

    /// Text is read only 68,000 characters in before it is masked. Masking can shrink what was read far below the
    /// cap, so the line the read stopped in is left out: a secret there is never sent in part.
    @Test func aSecretAtTheReadAheadEdgeIsNotShownInPart() throws {
        // The selection's start: a long blob, then a token whose first 23 characters are inside the read.
        let selection = blob(67_976) + "\n" + Self.github + "\nmore"
        let start = try object(shaped(["text": selection], tool: "get_editor_selection").text)
        let text = try #require(start["text"] as? String)
        #expect(!text.contains("ghp_") && !text.contains("Ab3dEf"))
        #expect(start["truncated"] as? Bool == true)
        // A screen's end: the read starts 31 characters before the end of the token's row.
        let rows = (0..<300).map { _ in blob(249) }.joined(separator: "\n")
        let tail = String(rows.suffix(67_968))
        let screen = "$ cat creds\n" + Self.github + "\n" + tail
        let end = try object(shaped(["id": "t1", "screen": screen], tool: "read_tab").text)
        let shown = try #require(end["screen"] as? String)
        #expect(!shown.contains("4zAb7c") && !shown.contains("f6hIj"))
        #expect(end["truncated"] as? Bool == true)
        #expect(try #require(end["truncated_note"] as? String).contains("fewer lines"))
        // Text that is not JSON says it was cut, however short masking made it.
        let plain = Policy.shape(MCPServer.CallResult(text: blob(80_000)), tool: "host_sessions")
        #expect(plain.text.hasSuffix("… (truncated: cut to fit 64,000 characters)"))
    }

    /// A row the read cut away may have wrapped into the first row kept, so that row's first word goes too.
    @Test func aRowAfterTheReadAheadEdgeIsMaskedWhereItCouldContinueASecret() throws {
        // The token's first row ends in its first 14 characters; the read starts in the last 10 of them. The rows
        // after are random lines, which masking shrinks, so the first rows read are inside the cap.
        let head = "$ cat creds\n" + String(repeating: "x", count: 234) + " ghp_Ab3dEf6hIj"
        let continued = "9kLm2nOp5qRs8tUv1wXy4zAb7c\n"
        let rows = (0..<300).map { _ in blob(249) }.joined(separator: "\n")
        let tail = continued + String(rows.suffix(68_000 - 11 - scalars(continued)))
        let screen = head + "\n" + tail
        let json = try object(shaped(["id": "t1", "screen": screen], tool: "read_tab").text)
        let shown = try #require(json["screen"] as? String)
        #expect(!shown.contains("9kLm2nOp5qRs8tUv1wXy4zAb7c") && !shown.contains("Ab3dEf"))
        #expect(shown.hasPrefix("•••\n"))
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
        results.append(("list_tabs", ["windows": [["tabs": [["command": "mysql -u root -pS3cretPass1 app"]]]]]))
        let wrapped = "$ export GITHUB_TOKEN=ghp_Ab3dEf6hIj\n9kLm2nOp5qRs8tUv1wXy4zAb7c\n$ "
        results.append(("read_tab", ["screen": wrapped]))
        results.append(("read_tab", ["screen": "ghp_Ab3dEf6\nhIj9kLm2nOp\n5qRs8tUv1wX\ny4zAb7c\n$ "]))
        results.append(("read_file", [Self.github: "first", Self.aws: "second"]))
        results.append(("get_editor_selection", ["text": blob(67_976) + "\n" + Self.github + "\nmore"]))
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
