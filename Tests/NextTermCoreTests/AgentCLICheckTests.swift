import Foundation
import Testing
@testable import NextTermCore

/// `scripts/agent-cli-check.sh`, run for real (U14): it reads the table as Core has it, and with made-up agents on a
/// temporary PATH it passes, fails on a missing resume word, looks for those words in the resume path's own help,
/// skips an agent that is not installed, and lets no agent write outside its own temporary folder.
@Suite struct AgentCLICheckTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var script: String { root.appendingPathComponent("scripts/agent-cli-check.sh").path }

    struct Run {
        var status: Int32
        var output: String
    }

    /// A made-up machine: `bin` for the agents, `answers` for what each one prints, a home and a temporary folder.
    func makeFolder() throws -> String {
        let name = "nt-cli-check-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        for part in ["bin", "answers", "home", "tmp"] {
            try FileManager.default.createDirectory(atPath: folder + "/" + part, withIntermediateDirectories: true)
        }
        return folder
    }

    /// The script with `arguments`, the made-up agents first on PATH and the system's tools after them.
    func run(_ arguments: [String], in folder: String) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script] + arguments
        process.environment = [
            "PATH": folder + "/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": folder + "/home",
            "TMPDIR": folder + "/tmp",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// A made-up agent named `program`: for its arguments joined by spaces (`--version`, `resume --help`) it prints
    /// that answer, and for any others it fails. `first` runs before it answers.
    func addAgent(_ program: String, answers: [String: String], first: String = "", in folder: String) throws {
        let answersFolder = folder + "/answers/" + program
        try FileManager.default.createDirectory(atPath: answersFolder, withIntermediateDirectories: true)
        for (arguments, answer) in answers {
            try answer.write(toFile: answersFolder + "/" + arguments, atomically: true, encoding: .utf8)
        }
        let body = """
            #!/bin/sh
            \(first)
            answer='\(answersFolder)'/"$*"
            [ -f "$answer" ] || { echo "made-up: no answer for $*" >&2; exit 2; }
            exec /bin/cat "$answer"

            """
        let path = folder + "/bin/" + program
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Help that names every word the check looks for: each option the table does not mark hidden, the subcommand, and
    /// each word of the resume form, less `leaving`.
    static func help(_ agent: RestoreAgent, leaving: Set<String> = []) -> String {
        let cli = agent.cli
        var words: [String] = cli.groups.flatMap(\.names).filter { !cli.hidden.contains($0) }
        words += cli.subcommand
        for word in cli.resume ?? [] {
            switch word {
            case .text(let text): words.append(text)
            case .joinedID(let option): words.append(option)
            case .id, .folder: break
            }
        }
        let lines: [String] = words.filter { !leaving.contains($0) }.map { "  " + $0 + "  does something\n" }
        return "Usage: made-up [options]\n\nOptions:\n" + lines.joined()
    }

    /// The versions line the script prints for `agent` installed at `version`.
    static func versions(_ agent: RestoreAgent, installed version: String) -> String {
        let checked = agent.cli.checked
        let checkedVersion = checked.version ?? "against its documentation"
        return "installed " + version + ", checked " + checkedVersion + " on " + checked.date
    }

    // MARK: the table

    /// An agent's entry as `--list` prints it: name, programs, subcommand, resume form, options, hidden options,
    /// checked version and date. The hidden options are a set, so they are compared sorted.
    static func listed(_ agent: RestoreAgent) -> [String] {
        let cli = agent.cli
        let resume: [String]? = cli.resume?.map { word in
            switch word {
            case .text(let text): return text
            case .id: return "<id>"
            case .joinedID(let option): return option + "=<id>"
            case .folder: return "<folder>"
            }
        }
        let options = cli.groups.flatMap(\.names).joined(separator: " ")
        let hidden = cli.hidden.sorted().joined(separator: " ")
        return ["\(agent)", cli.programs.joined(separator: " "), cli.subcommand.joined(separator: " "),
                resume?.joined(separator: " ") ?? "", options, hidden, cli.checked.version ?? "", cli.checked.date]
    }

    /// The script takes the table's words from Core's source, never from a copy, and reads every entry as Core has it.
    @Test func theScriptReadsEachEntryAsCoreHasIt() throws {
        let folder = try makeFolder()
        let result = try run(["--list"], in: folder)
        #expect(result.status == 0, "\(result.output)")
        let lines = result.output.split(separator: "\n").map(String.init)
        var read: [String: [String]] = [:]
        for line in lines {
            var fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            #expect(fields.count == 8, "\(line)")
            guard fields.count == 8 else { continue }
            fields[5] = fields[5].split(separator: " ").map(String.init).sorted().joined(separator: " ")
            read[fields[0]] = fields
        }
        #expect(read.count == RestoreAgent.allCases.count)
        for agent in RestoreAgent.allCases {
            #expect(read["\(agent)"] == Self.listed(agent), "\(agent)")
        }
    }

    // MARK: made-up agents

    /// Every word in its help: the check passes, prints the installed and the checked version, gives the `checked`
    /// line to record, and skips each agent not on PATH.
    @Test func anAgentWithEveryWordPassesAndPrintsBothVersions() throws {
        let folder = try makeFolder()
        let answers = ["--version": "9.9.9 (Claude Code)\n", "--help": Self.help(.claude)]
        try addAgent("claude", answers: answers, in: folder)
        let result = try run([], in: folder)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("claude (" + folder + "/bin/claude)\n"))
        #expect(result.output.contains("  " + Self.versions(.claude, installed: "9.9.9") + "\n"))
        #expect(result.output.contains("  help: claude --help\n"))
        #expect(!result.output.contains("missing"))
        #expect(result.output.contains("  passed\n"))
        #expect(result.output.contains("  record: checked: Checked(version: \"9.9.9\", date: \""))
        #expect(result.output.contains("codex: not on PATH\n"))
        #expect(result.output.contains("aider: not on PATH\n"))
        #expect(!result.output.contains("unknown"))
    }

    /// A word of the resume form missing from the help fails the check and is named.
    @Test func aMissingResumeWordFailsAndIsNamed() throws {
        let folder = try makeFolder()
        let help = Self.help(.claude, leaving: ["--resume"])
        try addAgent("claude", answers: ["--version": "9.9.9 (Claude Code)\n", "--help": help], in: folder)
        let result = try run(["claude"], in: folder)
        #expect(result.status == 1, "\(result.output)")
        #expect(result.output.contains("  missing resume word: --resume\n"))
        #expect(!result.output.contains("missing option: --resume"))
        #expect(result.output.contains("  FAILED\n"))
        #expect(!result.output.contains("record:"))
        #expect(result.output.contains("Failed: claude."))
    }

    /// A missing option is named, and fails the check only with `--strict`.
    @Test func aMissingOptionFailsOnlyWhenStrict() throws {
        let folder = try makeFolder()
        let help = Self.help(.claude, leaving: ["--verbose"])
        try addAgent("claude", answers: ["--version": "9.9.9\n", "--help": help], in: folder)
        let plain = try run(["claude"], in: folder)
        #expect(plain.status == 0, "\(plain.output)")
        #expect(plain.output.contains("  missing option: --verbose\n"))
        #expect(plain.output.contains("  passed\n"))
        let strict = try run(["--strict", "claude"], in: folder)
        #expect(strict.status == 1, "\(strict.output)")
        #expect(strict.output.contains("  missing option: --verbose\n"))
    }

    /// Codex's resume words are looked for in `codex resume --help`, the help of the command they go to: the folder
    /// option its top help names is not enough.
    @Test func resumeWordsAreLookedForInTheResumePathsHelp() throws {
        let folder = try makeFolder()
        let usage = "Usage: codex resume [OPTIONS] [SESSION_ID] [PROMPT]\n"
        let answers = ["--version": "codex-cli 0.200.1\n", "--help": Self.help(.codex), "resume --help": usage]
        try addAgent("codex", answers: answers, in: folder)
        let without = try run(["codex"], in: folder)
        #expect(without.status == 1, "\(without.output)")
        #expect(without.output.contains("  help: codex --help, codex resume --help\n"))
        #expect(without.output.contains("  missing resume word: -C\n"))
        #expect(!without.output.contains("missing resume word: resume"))

        var withFolder = answers
        withFolder["resume --help"] = usage + "  -C, --cd <DIR>  The folder\n"
        try addAgent("codex", answers: withFolder, in: folder)
        let with = try run(["codex"], in: folder)
        #expect(with.status == 0, "\(with.output)")
        #expect(with.output.contains("  " + Self.versions(.codex, installed: "0.200.1") + "\n"))
    }

    /// A help that fails is a failure, quoting the agent's own error; a version it cannot read is only noted.
    @Test func aHelpThatFailsIsAFailure() throws {
        let folder = try makeFolder()
        try addAgent("junie", answers: [:], in: folder)
        let result = try run(["junie"], in: folder)
        #expect(result.status == 1, "\(result.output)")
        let unknown = "unknown (junie --version exited with status 2: made-up: no answer for --version)"
        #expect(result.output.contains("  " + Self.versions(.junie, installed: unknown) + "\n"))
        #expect(result.output.contains("  junie --help exited with status 2: made-up: no answer for --help\n"))
        #expect(result.output.contains("  FAILED\n"))
    }

    /// An agent runs with no network and no writes outside the script's own temporary folder, which is removed.
    @Test func anAgentWritesNothingOutsideItsTemporaryFolder() throws {
        let folder = try makeFolder()
        let first = "echo leaked > '\(folder)/leaked' 2>/dev/null; echo leaked > \"$HOME/leaked\" 2>/dev/null"
        let answers = ["--version": "9.9.9\n", "--help": Self.help(.claude)]
        try addAgent("claude", answers: answers, first: first, in: folder)
        let result = try run(["claude"], in: folder)
        #expect(result.status == 0, "\(result.output)")
        #expect(!FileManager.default.fileExists(atPath: folder + "/leaked"))
        #expect(!FileManager.default.fileExists(atPath: folder + "/home/leaked"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder + "/tmp").isEmpty)
    }

    /// An agent the table does not know is a usage error.
    @Test func anUnknownAgentNameIsAUsageError() throws {
        let folder = try makeFolder()
        let result = try run(["clawd"], in: folder)
        #expect(result.status == 2, "\(result.output)")
        #expect(result.output.contains("no agent named clawd"))
    }
}
