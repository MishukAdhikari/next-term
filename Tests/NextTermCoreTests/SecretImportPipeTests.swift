import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// `nxtrm secret import`: its arguments, the header line it sends before any key, the app's reply lines, and the only
/// lines it prints. Every value here is made up, from a provider's head and filler put together at run time.
@Suite struct SecretImportPipeParseTests {
    typealias P = SecretImportPipe

    private static func run(_ arguments: [String], terminal: Bool = false) -> P.Invocation? {
        if case .run(let invocation) = P.parse(arguments, standardInputIsTerminal: terminal) { return invocation }
        return nil
    }

    private static func isUsage(_ arguments: [String], terminal: Bool = false) -> Bool {
        if case .usage = P.parse(arguments, standardInputIsTerminal: terminal) { return true }
        return false
    }

    @Test func theSpellings() {
        #expect(Self.run(["-"]) == P.Invocation(format: nil, input: .standardInput))
        #expect(Self.run([]) == P.Invocation(format: nil, input: .standardInput))
        #expect(Self.run(["--from", "bws", "-"]) == P.Invocation(format: .bws, input: .standardInput))
        #expect(Self.run(["--from=1password", "-"]) == P.Invocation(format: .onePassword, input: .standardInput))
        #expect(Self.run(["--from", "bitwarden", "-"])?.format == .bitwarden)
        #expect(Self.run(["/tmp/made-up/.env"]) == P.Invocation(format: nil, input: .file("/tmp/made-up/.env")))
        #expect(Self.run(["--from", "env", "--", "-odd"]) == P.Invocation(format: .env, input: .file("-odd")))
        // A file needs no pipe: a terminal on standard input is fine.
        #expect(Self.run([".env.local"], terminal: true) == P.Invocation(format: nil, input: .file(".env.local")))
        for name in ["env", "json", "csv", "yaml", "toml"] {
            #expect(Self.run(["--from", name, "-"])?.format?.rawValue == name)
        }
    }

    @Test func aTerminalOnStandardInputIsNeverWaitedOn() {
        #expect(Self.isUsage([], terminal: true))
        #expect(Self.isUsage(["-"], terminal: true))
        #expect(Self.isUsage(["--from", "bws"], terminal: true))
        if case .usage(let reason) = P.parse([], standardInputIsTerminal: true) {
            #expect(P.text(.usage(reason)).exit == 2)
        }
    }

    @Test func badArgumentsAreUsageErrors() {
        let bad: [[String]] = [
            ["a.env", "-"],                       // a FILE and standard input
            ["a.env", "b.env"],                   // two files
            ["-", "-"],
            ["--from"],                           // no format
            ["--from", "xml", "-"],               // an unknown format
            ["--from=", "-"],
            ["--from", "bws", "--from", "env", "-"],
            ["--frm", "bws", "-"],                // an unknown option
            ["-x"],
        ]
        for arguments in bad where !Self.isUsage(arguments) { Issue.record("accepted \(arguments)") }
    }

    @Test func helpIsItsOwn() {
        for spelling in [["--help"], ["-h"], ["help"]] {
            guard case .help = P.parse(spelling, standardInputIsTerminal: true) else {
                Issue.record("not help: \(spelling)")
                continue
            }
        }
        let help = P.text(.help)
        #expect(help.exit == 0 && help.line.hasPrefix(P.usage))
        #expect(SecretRun.help.contains(P.usage) && SecretRun.help.contains(SecretRun.usage))
    }

    @Test func onlyNextTermsOwnImportFormIsAnImporter() {
        let app = "/Applications/Next Term.app/Contents/MacOS/NextTerm"
        #expect(P.isImporter([app, "--cli", "secret", "import", "-"]))
        #expect(P.isImporter([app, "--cli", "secret", "import", "--from", "bws", "-"]))
        #expect(!P.isImporter([app, "--cli", "secret", "run", "A", "--", "x"]))
        #expect(!P.isImporter(["/tmp/NextTermX", "--cli", "secret", "import", "-"]))
        #expect(!P.isImporter([app, "secret", "import", "-"]))
        #expect(!P.isImporter([app, "--cli", "secret"]))
    }
}

@Suite struct SecretImportPipeLineTests {
    typealias P = SecretImportPipe

    @Test func theHeaderHoldsNoValueAndRoundTrips() throws {
        let argv = ["/Applications/Next Term.app/Contents/MacOS/NextTerm", "--cli", "secret", "import", "-"]
        let request = P.Request(format: "bws", bytes: 812, path: nil, directory: "/tmp/made-up/rag-api", argvFull: argv)
        let line = try #require(request.line())
        #expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["tool"] as? String == P.tool)
        let arguments = try #require(object["arguments"] as? [String: Any])
        #expect(arguments["argv_full"] as? [String] == argv)
        #expect(P.Request.decode(arguments) == request)
        #expect(request.isWellFormed)
    }

    @Test func aHeaderIsWellFormedOnlyWithAPathOrABody() {
        let argv = ["/x/NextTerm", "--cli", "secret", "import"]
        func make(_ format: String?, _ bytes: Int, _ path: String?) -> P.Request {
            P.Request(format: format, bytes: bytes, path: path, directory: "/", argvFull: argv)
        }
        #expect(make(nil, 0, "/tmp/a.env").isWellFormed)
        #expect(make("env", 1, nil).isWellFormed)
        #expect(make(nil, P.maxBytes, nil).isWellFormed)
        #expect(!make(nil, 0, nil).isWellFormed)              // neither
        #expect(!make(nil, 4, "/tmp/a.env").isWellFormed)     // both
        #expect(!make(nil, P.maxBytes + 1, nil).isWellFormed) // over the cap
        #expect(!make(nil, -1, nil).isWellFormed)
        #expect(!make(nil, 0, "a.env").isWellFormed)          // not absolute
        #expect(!make("xml", 3, nil).isWellFormed)            // an unknown format
        #expect(P.Request.decode(["bytes": "many"]) == nil)
    }

    /// The path is shown in the sheet's header: no control character, and at most 4096 bytes.
    @Test func aHeadersPathHasNoControlCharacterAndFitsTheCap() {
        let argv = ["/x/NextTerm", "--cli", "secret", "import"]
        func make(_ path: String) -> P.Request {
            P.Request(format: nil, bytes: 0, path: path, directory: "/", argvFull: argv)
        }
        for control in ["\u{0}", "\u{7}", "\n", "\r", "\u{1B}[2J", "\u{7F}", "\u{85}", "\u{9B}"] {
            #expect(!make("/tmp/made-up" + control + ".env").isWellFormed, "\(control.unicodeScalars.map(\.value))")
        }
        #expect(make("/tmp/made-up café/.env").isWellFormed)
        #expect(make("/" + String(repeating: "a", count: 4095)).isWellFormed)
        #expect(!make("/" + String(repeating: "a", count: 4096)).isWellFormed)
        // Bytes, not characters: 2,048 two-byte letters and the slash are 4,097 bytes.
        #expect(!make("/" + String(repeating: "\u{E9}", count: 2048)).isWellFormed)
    }

    @Test func repliesRoundTrip() throws {
        for reply in [P.Reply(status: .ready), P.Reply(status: .found, count: 7), P.Reply(status: .imported, count: 2)] {
            let line = reply.line()
            #expect(line.last == 0x0A)
            #expect(P.Reply.decode(line.dropLast()) == reply)
        }
        #expect(P.Reply.decode(Data("not json".utf8)) == nil)
        #expect(P.Reply.decode(Data(#"{"status":"sideways"}"#.utf8)) == nil)
    }

    @Test func eachReplyEndsAsItsLine() {
        #expect(P.ending(for: P.Reply(status: .imported, count: 3)) == .imported(3))
        #expect(P.ending(for: P.Reply(status: .imported)) == .imported(0))
        #expect(P.ending(for: P.Reply(status: .nothing)) == .nothing)
        #expect(P.ending(for: P.Reply(status: .busy)) == .busy)
        #expect(P.ending(for: P.Reply(status: .moved)) == .moved)
        #expect(P.ending(for: P.Reply(status: .refused)) == .refused)
        #expect(P.ending(for: P.Reply(status: .ready)) == .refused)
    }
}
