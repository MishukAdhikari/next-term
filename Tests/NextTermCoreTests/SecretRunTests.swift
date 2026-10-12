import Foundation
import Testing
@testable import NextTermCore

@Suite struct SecretRunParseTests {
    @Test func theSpellings() throws {
        let one = try SecretRun.parse(["A", "--", "cmd"]).get()
        #expect(one == SecretRun.Invocation(names: ["A"], map: ["A": "A"], argv: ["cmd"], ticket: nil))
        let two = try SecretRun.parse(["A=B", "C", "--", "cmd", "x"]).get()
        #expect(two.names == ["A", "C"] && two.map == ["A": "B", "C": "C"] && two.argv == ["cmd", "x"])
        let ticket = SecretRun.newTicket()
        #expect(SecretRun.isTicket(ticket))
        #expect(try SecretRun.parse(["--ticket", ticket]).get().ticket == ticket)
        // What comes after `--` is the command's own, `--` included.
        #expect(try SecretRun.parse(["A", "--", "cmd", "--", "--flag"]).get().argv == ["cmd", "--", "--flag"])
    }

    @Test func badArgumentsAreUsageErrors() {
        let bad: [[String]] = [
            ["A", "cmd"],                    // no --
            ["A", "--"],                     // nothing after --
            ["--", "cmd"],                   // no key
            ["github_token", "--", "cmd"],   // a bad name
            ["A=PATH", "--", "cmd"],         // a refused ENVNAME
            ["A=DYLD_X", "--", "cmd"],
            ["A=b", "--", "cmd"],            // an ENVNAME that is not a name
            ["A", "A", "--", "cmd"],         // a name twice
            ["A=X", "B=X", "--", "cmd"],     // an ENVNAME twice
            ["A", "B=A", "--", "cmd"],       // A is set as A and B is set as A
            ["--ticket", "short"],
            ["--ticket"],
        ]
        for arguments in bad {
            if case .success = SecretRun.parse(arguments) { Issue.record("accepted \(arguments)") }
        }
    }
}

@Suite struct SecretRunStatusTests {
    @Test func everyEndingHasItsLineAndExitCode() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_791_547_200) // 12:00 UTC
        func line(_ ending: SecretRun.Ending) -> (line: String, exit: Int32) {
            SecretRun.ending(ending, names: ["GITHUB_TOKEN"], program: "npx", now: now, timeZone: utc)
        }
        let expected: [(SecretRun.Ending, String, Int32)] = [
            (.noSocket, "nxtrm: Next Term is not running, or “Let agents control Next Term” is off in its Settings. Open Next Term, then restart this command.", 1),
            (.peerCheck, "nxtrm: the program at Next Term’s socket is not this copy of Next Term, so no key was asked for.", 1),
            (.timedOut, "nxtrm: GITHUB_TOKEN is waiting for your approval in Next Term. Allow it there, then restart this command.", 1),
            (.timedOutTicket, "nxtrm: no answer in Next Term within 10 minutes, so no key was given.", 1),
            (.closed, "nxtrm: Next Term quit before it answered, so no key was given. Restart this command once Next Term is open again.", 1),
            (.answer(.declined, name: nil, until: nil), "nxtrm: Next Term declined GITHUB_TOKEN for npx.", 1),
            (.answer(.paused, name: nil, until: now.addingTimeInterval(720)),
             "nxtrm: you declined this a few minutes ago, so Next Term won’t ask again until 12:12 PM.", 1),
            (.answer(.stopped, name: nil, until: nil),
             "nxtrm: you chose Decline and Stop Asking for this command, so Next Term won’t ask again until it quits. Resume it in Settings › Secrets.", 1),
            (.answer(.declining, name: nil, until: now.addingTimeInterval(37 * 60)), "nxtrm: Next Term is pausing key requests for the next 37 minutes.", 1),
            (.answer(.busy, name: nil, until: nil), "nxtrm: too many key requests are waiting in Next Term. Answer them, then restart this command.", 1),
            (.answer(.limited, name: nil, until: nil), "nxtrm: this command has asked too often. Resume it in Settings › Secrets, or restart Next Term.", 1),
            (.answer(.expired, name: nil, until: nil), "nxtrm: this run’s approval expired or was used already, so no key was given.", 1),
            (.answer(.cantOpen, name: nil, until: nil), "nxtrm: Next Term can’t open Secrets on this Mac. Open Settings › Secrets.", 1),
            (.answer(.refused, name: nil, until: nil), "nxtrm: Next Term refused this request.", 1),
            (.answer(.valueInCommand, name: nil, until: nil), "nxtrm: the command holds a stored key’s value. Use the key’s name instead.", 2),
            (.answer(.unknown, name: "GITHUB_TOKEN", until: nil), "nxtrm: no key named GITHUB_TOKEN in Next Term’s Secrets (Settings › Secrets).", 2),
            (.usage, "usage: nxtrm secret run NAME[=ENVNAME]... -- command [arguments...]", 2),
            (.notFound("npx"), "nxtrm: npx: command not found", 127),
            (.cantRun("npx"), "nxtrm: npx: can't run it", 126),
        ]
        for (ending, text, code) in expected {
            let got = line(ending)
            #expect(got.line == text && got.exit == code, "\(ending)")
            #expect(got.line.hasPrefix("nxtrm: ") || got.line.hasPrefix("usage: "))
            #expect(!got.line.contains("\n"))
        }
        #expect(SecretRun.ending(.timedOut, names: ["A", "B"], program: "x").line.contains("A and B is waiting") == true)
    }

    @Test func messagesRoundTripAndValuesOnlyInAllowed() throws {
        let request = SecretRun.Request(names: ["A"], map: ["A": "B"], argv: ["node", "x.js"], executable: "/usr/local/bin/node",
                                        directory: "/tmp", argvFull: ["/Applications/Next Term.app/Contents/MacOS/NextTerm", "--cli"],
                                        warn: ["NODE_OPTIONS": "ab"], ticket: nil)
        let line = try #require(request.line())
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(object["tool"] as? String == "secret_run")
        let arguments = try #require(object["arguments"] as? [String: Any])
        #expect(arguments["argv_full"] != nil)
        #expect(SecretRun.Request.decode(arguments) == request)
        let refused = SecretRun.Answer(status: .declined, note: "declined")
        let decoded = try #require(SecretRun.Answer.decode(refused.line().dropLast()))
        #expect(decoded.status == .declined && decoded.environment == nil)
    }
}

@Suite struct SecretRunEnvironmentTests {
    @Test func approvedKeysInOtherStoredNamesOut() {
        let base = ["PATH": "/usr/bin", "OTHER": "stale", "HOME": "/Users/me", "A": "old"]
        let answer = SecretRun.Answer(status: .allowed, environment: ["B": "value-of-a"], remove: ["OTHER", "A"])
        let environment = SecretRun.environment(base: base, answer: answer)
        #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/me", "B": "value-of-a"])
        #expect(SecretRun.removed(stored: ["A", "B", "OTHER", "Z"], approved: ["B"]) == ["A", "OTHER", "Z"])
    }

    @Test func warnedVariablesAndTheirDigests() {
        let one = SecretRun.warnings(environment: ["NODE_OPTIONS": "--require x", "https_proxy": "http://p", "OPENAI_BASE_URL": "https://a",
                                                   "PATH": "/bin", "DYLD_INSERT_LIBRARIES": "/x.dylib", "HOME": "/h"])
        #expect(Set(one.keys) == ["NODE_OPTIONS", "https_proxy", "OPENAI_BASE_URL", "DYLD_INSERT_LIBRARIES"])
        let two = SecretRun.warnings(environment: ["NODE_OPTIONS": "--require y", "https_proxy": "http://p", "OPENAI_BASE_URL": "https://a"])
        #expect(one["NODE_OPTIONS"] != two["NODE_OPTIONS"] && one["https_proxy"] == two["https_proxy"])
        #expect(SecretRun.warningText(for: "NODE_OPTIONS") == "NODE_OPTIONS is set: it can change what this command runs.")
        #expect(SecretRun.warningText(for: "HTTPS_PROXY") == "HTTPS_PROXY is set. The key may pass through that proxy.")
    }

    @Test func shellsAndAgentsAreFlagged() {
        #expect(SecretRun.warnings(argv: ["bash", "-c", "x"]) == ["This command starts a shell (bash). Anything it runs gets the key."])
        #expect(SecretRun.warnings(argv: ["claude"]) == ["This command starts an agent (claude). The agent and its tools get the key."])
        #expect(SecretRun.warnings(argv: ["env", "FOO=1", "zsh"]).first?.contains("shell (zsh)") == true)
        #expect(SecretRun.warnings(argv: ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"]).contains { $0.contains("agent") })
        #expect(SecretRun.warnings(argv: ["node", "server.js"]).isEmpty)
        #expect(SecretRun.warnings(command: "npm test").isEmpty)
        #expect(SecretRun.warnings(command: "cd x && codex exec y").contains { $0.contains("agent (codex)") })
    }

    @Test func unpinnedPackages() {
        let flagged: [[String]] = [["npx", "-y", "pkg"], ["bunx", "pkg@latest"], ["pnpm", "dlx", "pkg"], ["yarn", "dlx", "pkg@^1"],
                                   ["uvx", "pkg"], ["pipx", "run", "pkg"], ["pipx", "run", "--spec", "pkg", "tool"]]
        for words in flagged {
            #expect(SecretRun.warnings(argv: words).contains { $0.contains("runs the newest") }, "\(words)")
        }
        let pinned: [[String]] = [["npx", "-y", "pkg@1.2.3"], ["uvx", "pkg==1.2.3"], ["pipx", "run", "pkg==1.2.3"],
                                  ["pipx", "run", "--spec", "pkg==1.2.3", "tool"], ["npx", "./local"]]
        for words in pinned {
            #expect(!SecretRun.warnings(argv: words).contains { $0.contains("runs the newest") }, "\(words)")
        }
        #expect(SecretRun.warnings(argv: ["npx", "-y", "@x/y"]).first
                == "npx -y runs the newest @x/y each time, so code you haven't seen gets the key. Pin a version to avoid this.")
        #expect(SecretRun.warnings(command: "cd x && npx -y pkg").contains { $0.hasPrefix("npx -y runs the newest pkg") })
    }

    @Test func theFoldersEnvFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SecretRun.envFileDigest(directory: folder.path) == "none")
        #expect(SecretRun.envFileWarnings(directory: folder.path).isEmpty)
        let env = folder.appendingPathComponent(".env")
        try "DEBUG=1\nOPENAI_BASE_URL=https://example.invalid\n".write(to: env, atomically: true, encoding: .utf8)
        let first = SecretRun.envFileDigest(directory: folder.path)
        #expect(first != "none" && first.count == 64)
        #expect(SecretRun.envFileWarnings(directory: folder.path) == [".env in this folder sets OPENAI_BASE_URL. The key may go to that address."])
        try "DEBUG=2\nOPENAI_BASE_URL=https://example.invalid\n".write(to: env, atomically: true, encoding: .utf8)
        #expect(SecretRun.envFileDigest(directory: folder.path) != first)
    }

    /// The ticket line, quoted for each tab's shell.
    @Test func theTypedLineForEachShell() {
        let ticket = "abcdefghijklmnopqrstuvwxyz"
        let words = ["/Applications/Next Term.app/Contents/Resources/bin/nxtrm", "secret", "run", "--ticket", ticket]
        let tail = " secret run --ticket \(ticket)"
        for shell in ["zsh", "bash", "sh", "dash", "ksh", "mksh", "fish", "tcsh", "csh", "unknown"] {
            #expect(SecretRun.typedLine(words, shell: shell) == "'/Applications/Next Term.app/Contents/Resources/bin/nxtrm'" + tail, "\(shell)")
        }
        #expect(SecretRun.typedLine(words, shell: "nu") == "^'/Applications/Next Term.app/Contents/Resources/bin/nxtrm'" + tail)
        #expect(SecretRun.typedLine(words, shell: "pwsh") == "& '/Applications/Next Term.app/Contents/Resources/bin/nxtrm'" + tail)
        #expect(SecretRun.typedLine(words, shell: "xonsh") == nil && SecretRun.typedLine(words, shell: "elvish") == nil)
        // A plain path needs no quotes, but nu and pwsh still mark it as the program to run.
        #expect(SecretRun.typedLine(["/usr/local/bin/nxtrm", "secret"], shell: "zsh") == "/usr/local/bin/nxtrm secret")
        #expect(SecretRun.typedLine(["/usr/local/bin/nxtrm", "secret"], shell: "nu") == "^'/usr/local/bin/nxtrm' secret")
        #expect(SecretRun.typedLine(["/usr/local/bin/nxtrm", "secret"], shell: "pwsh") == "& '/usr/local/bin/nxtrm' secret")
        // Quotes and history marks inside a path.
        #expect(SecretRun.typedLine(["/a/it's/x"], shell: "zsh") == #"'/a/it'\''s/x'"#)
        #expect(SecretRun.typedLine(["/a/it's/x"], shell: "fish") == #"'/a/it\'s/x'"#)
        #expect(SecretRun.typedLine(["/a/b!c"], shell: "tcsh") == #"'/a/b\!c'"#)
        #expect(SecretRun.typedLine(["/a/it's/x"], shell: "pwsh") == "& '/a/it''s/x'")
        #expect(SecretRun.typedLine(["/a/it's/x"], shell: "nu") == nil)
        // A control character is never typed: it would act at once in the line editor.
        #expect(SecretRun.typedLine(["/a/b\u{15}c"], shell: "zsh") == nil)
    }

    /// run_with_secrets takes one line: a CRLF, a lone CR or LF, another control character or a line separator would
    /// let `/bin/sh -c` run a second command the panel never named.
    @Test func aCommandIsOneLine() {
        for command in ["npm test", "npm test\t--watch", "cd api && npm run e2e", "printf '%s' \"$K\" | wc -c"] {
            #expect(SecretRun.isOneLine(command), "\(command)")
        }
        for command in ["npm test\r\nnpx -y pkg", "npm test\nnpx -y pkg", "npm test\rnpx -y pkg", "a\u{0B}b", "a\u{0C}b", "a\u{85}b",
                        "a\u{1B}b", "a\u{7F}b", "a\u{2028}b", "a\u{2029}b"] {
            #expect(!SecretRun.isOneLine(command), "\(command.debugDescription)")
        }
    }

    @Test func theProgramForTheTitle() {
        #expect(SecretRun.programName(ofCommand: "npm test") == "npm")
        #expect(SecretRun.programName(ofCommand: "cd api && FOO=1 npm run e2e") == "npm")
        #expect(SecretRun.programName(ofCommand: "/usr/local/bin/node x.js") == "node")
    }

    @Test func aWrappersBinding() {
        let request = SecretRun.Request(names: ["GITHUB_TOKEN"], map: ["GITHUB_TOKEN": "GITHUB_TOKEN"], argv: ["/usr/bin/true"],
                                        executable: "/usr/bin/true", directory: "/tmp", argvFull: [], warn: [:], ticket: nil)
        let one = SecretRun.binding(request: request, agentPath: "/usr/bin/env", agentScript: nil, program: "codex", envDigest: "none")
        let two = SecretRun.binding(request: request, agentPath: "/usr/bin/env", agentScript: nil, program: "codex", envDigest: "none")
        #expect(one == two && one.executableIdentity != nil && one.agentIdentity != nil && one.asker.hasPrefix("wrapper:/usr/bin/env:"))
        var other = request
        other.argv = ["/usr/bin/false"]
        #expect(SecretRun.binding(request: other, agentPath: "/usr/bin/env", agentScript: nil, program: "codex", envDigest: "none").asker != one.asker)
    }
}

@Suite struct SecretRunReadTests {
    /// A connected pair: the wrapper's end and the app's.
    func pair() throws -> (wrapper: Int32, app: Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[0], fds[1])
    }

    func put(_ text: String, on fd: Int32) {
        _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The app's answer comes as one line, maybe in parts; what follows its newline is not read as part of it.
    @Test func theAnswersLine() throws {
        let ends = try pair()
        defer { [ends.wrapper, ends.app].forEach { close($0) } }
        put(#"{"status""#, on: ends.app)
        put(#": "declined"}"# + "\nmore", on: ends.app)
        #expect(SecretRun.readAnswer(from: ends.wrapper, within: 2) == .line(Data(#"{"status": "declined"}"#.utf8)))
    }

    /// No answer within the wait: the request still waits in Next Term, as a pending card.
    @Test func noAnswerWithinTheWaitTimesOut() throws {
        let ends = try pair()
        defer { [ends.wrapper, ends.app].forEach { close($0) } }
        put(#"{"sta"#, on: ends.app)
        let started = Date()
        #expect(SecretRun.readAnswer(from: ends.wrapper, within: 0.3) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// The app closed the connection without an answer: it quit, or restarted for an update, while the request waited,
    /// so the request and its card are gone. Told at once, apart from a timeout, whatever came of a line before.
    @Test func aConnectionClosedUnansweredIsNotATimeout() throws {
        for partial in ["", #"{"status": "allo"#] {
            let ends = try pair()
            defer { close(ends.wrapper) }
            put(partial, on: ends.app)
            close(ends.app)
            let started = Date()
            #expect(SecretRun.readAnswer(from: ends.wrapper, within: 10) == .closed, "\(partial)")
            #expect(Date().timeIntervalSince(started) < 2, "\(partial)")
        }
    }

    /// The app sees a wrapper that left the moment it asks, reading nothing and never waiting: "Allow once" then passes
    /// to an identical wrapper still waiting, not to one whose end is closed.
    @Test func aWrapperThatLeftIsSeenAtOnce() throws {
        let ends = try pair()
        defer { close(ends.app) }
        #expect(!SecretRun.peerLeft(ends.app))
        close(ends.wrapper)
        let started = Date()
        #expect(SecretRun.peerLeft(ends.app))
        #expect(Date().timeIntervalSince(started) < 1)
    }

    /// More than the limit and no newline is no answer the app writes.
    @Test func aLineOverTheLimitIsTooLong() throws {
        let ends = try pair()
        defer { [ends.wrapper, ends.app].forEach { close($0) } }
        put(String(repeating: "x", count: 64), on: ends.app)
        #expect(SecretRun.readAnswer(from: ends.wrapper, within: 2, limit: 32) == .tooLong)
    }
}
