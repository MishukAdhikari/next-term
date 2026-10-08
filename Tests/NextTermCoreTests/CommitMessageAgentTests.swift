import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommitMessageAgentTests {
    @Test func whichAgentAndHowItIsAsked() {
        let installed: Set<String> = ["/b/codex", "/a/claude", "/a/gemini"]
        let found = { (preferring: [String]) in CommitMessageAgent.find(preferring: preferring, in: ["/a", "/b"], isExecutable: installed.contains) }
        #expect(found([])?.agent == .claude && found([])?.path == "/a/claude")
        #expect(found(["codex"])?.agent == .codex && found(["codex"])?.path == "/b/codex") // the one working here
        #expect(found(["aider", "gemini"])?.agent == .gemini) // one the sheet doesn't know is passed over
        #expect(CommitMessageAgent.find(in: ["/a"], isExecutable: { _ in false }) == nil)

        let claude = CommitMessageAgent.claude.arguments(prompt: "P", answerFile: "/t/a")
        #expect(claude == ["-p", "--output-format", "text", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "user", "--tools", ""])
        #expect(CommitMessageAgent.claude.input(prompt: "P", changes: "C") == "P\n\nC")
        let codex = CommitMessageAgent.codex.arguments(prompt: "P", answerFile: "/t/a")
        #expect(codex.first == "exec" && codex.contains("read-only") && codex.contains("--ephemeral") && codex.suffix(3) == ["--output-last-message", "/t/a", "-"])
        #expect(CommitMessageAgent.gemini.arguments(prompt: "P", answerFile: "/t/a") == ["-p", "P"])
        #expect(CommitMessageAgent.gemini.input(prompt: "P", changes: "C") == "C")

        let prompt = CommitMessageAgent.prompt(recentSubjects: ["Git Log: a match-case toggle"])
        #expect(prompt.contains("72 characters") && prompt.contains("- Git Log: a match-case toggle") && prompt.hasSuffix("The changes:"))
        #expect(!CommitMessageAgent.prompt(recentSubjects: []).contains("recent commits"))
    }

    @Test func theAnswerCleaned() {
        #expect(CommitMessageAgent.message(from: "```\nFix the login\n\nBecause.\n```\n") == "Fix the login\n\nBecause.")
        #expect(CommitMessageAgent.message(from: "\u{1B}[1m\"Fix it\"\u{1B}[0m\n") == "Fix it")
        #expect(CommitMessageAgent.message(from: "Fix it\n\n\n\nBody\r\n") == "Fix it\n\nBody")
        #expect(CommitMessageAgent.message(from: "  \n") == "")
    }

    /// What the agent reads: the staged diff, or every change with the new files' text; cut when long.
    @Test func theChangesItReads() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("new.txt", "brand new\n")
        // No commit yet: nothing to compare with, the new file is all there is.
        let first = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: false, newFiles: ["new.txt", "assets/"])
        #expect(first.contains("New file: new.txt\nbrand new") && first.contains("New folder: assets/"))
        repo.commit("One")
        try repo.write("new.txt", "changed\n")
        try repo.write("other.txt", "other\n")
        let all = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: false, newFiles: ["other.txt"])
        #expect(all.contains("-brand new") && all.contains("+changed") && all.contains("New file: other.txt\nother"))
        repo.sh(["add", "other.txt"])
        let staged = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: true)
        #expect(staged.contains("+other") && !staged.contains("changed"))
        let cut = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: false, newFiles: [], limit: 40)
        #expect(cut.hasPrefix("diff --git") && cut.contains("[The rest of the changes is cut here:"))
        #expect(CommitMessageAgent.recentSubjects(at: repo.work, git: repo.git) == ["One"])
    }

    /// What goes to the agent goes on to its vendor: files that usually hold secrets are named, not sent,
    /// and secret-looking values are masked, as get_diff gives changes to agents.
    @Test func secretsStayOut() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("config.yml", "name: app\n")
        repo.commit("One")
        let key = "sk-ant-api03-" + String(repeating: "Ab3x", count: 12)
        try repo.write(".env", "API_KEY=\(key)\n")
        try repo.write("config.yml", "name: app\n  password: hunter2-hunter2\n")
        try repo.write("id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n")
        try repo.write("notes.txt", "client_token = \"\(key)\"\n")
        repo.sh(["add", ".env", "config.yml"])
        let staged = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: true)
        #expect(!staged.contains(key) && !staged.contains("hunter2"), "\(staged)")
        #expect(staged.contains("Left out: .env (it is an environment file") && staged.contains("+  password: •••"), "\(staged)")
        #expect(staged.contains("diff --git a/config.yml b/config.yml") && staged.contains(" name: app"))

        repo.sh(["reset", "-q"])
        let all = CommitMessageAgent.changes(at: repo.work, git: repo.git, staged: false, newFiles: [".env", "id_ed25519", "notes.txt"])
        #expect(!all.contains(key) && !all.contains("b3BlbnNz") && !all.contains("hunter2"), "\(all)")
        #expect(all.contains("New file: .env (left out: it is an environment file") && all.contains("New file: id_ed25519 (left out: it looks like an ssh private key)"), "\(all)")
        #expect(all.contains("New file: notes.txt\nclient_token = \"•••\""), "\(all)")
    }

    /// A stand-in agent: what it is given on standard input, and its answer; an error, a hang, a stop.
    @Test func runningAnAgent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func agent(_ name: String, _ script: String) throws -> String {
            let path = folder.appendingPathComponent(name).path
            try ("#!/bin/sh\n" + script).write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        let environment = ["PATH": "/usr/bin:/bin"]
        let seenFile = folder.appendingPathComponent("seen").path, whereFile = folder.appendingPathComponent("where").path
        let echo = try agent("claude", "cat > '\(seenFile)'; pwd -P > '\(whereFile)'; ls -A >> '\(whereFile)'; printf '```\\nFix the login (%s)\\n```\\n' \"$1\"")
        let outcome = CommitMessageRun().run(.claude, path: echo, prompt: "Write it.", changes: "diff --git a/x b/x", environment: environment)
        #expect(outcome == .message("Fix the login (-p)"))
        let seen = (try? String(contentsOf: folder.appendingPathComponent("seen"), encoding: .utf8)) ?? ""
        #expect(seen == "Write it.\n\ndiff --git a/x b/x")
        // It runs in a folder of its own, never where Next Term (or the repository) is: a folder's settings
        // could run hooks. The folder holds only the run's own files, and is gone once the run ends.
        let ranIn = ((try? String(contentsOfFile: whereFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(ranIn.first?.contains("next-term-message-") == true, "\(ranIn)")
        #expect(Set(ranIn.dropFirst()).isSubset(of: ["input", "output", "errors", "answer"]), "\(ranIn)")
        #expect(ranIn.first.map { !FileManager.default.fileExists(atPath: $0) } == true)

        // Codex writes its answer to the file named after --output-last-message.
        let codex = try agent("codex", "while [ \"$1\" != --output-last-message ]; do shift; done; echo 'From the file' > \"$2\"; echo 'progress'")
        #expect(CommitMessageRun().run(.codex, path: codex, prompt: "P", changes: "C", environment: environment) == .message("From the file"))

        let failing = try agent("failing", "echo 'Error: not logged in' >&2; exit 1")
        #expect(CommitMessageRun().run(.claude, path: failing, prompt: "P", changes: "C", environment: environment) == .failed("Error: not logged in"))
        let silent = try agent("silent", "exit 0")
        #expect(CommitMessageRun().run(.claude, path: silent, prompt: "P", changes: "C", environment: environment) == .failed("It answered with nothing."))

        let slow = try agent("slow", "exec sleep 30")
        let started = Date()
        #expect(CommitMessageRun().run(.claude, path: slow, prompt: "P", changes: "C", environment: environment, timeout: 0.5) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        let run = CommitMessageRun()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { run.stop() }
        #expect(run.run(.claude, path: slow, prompt: "P", changes: "C", environment: environment) == .stopped)
    }
}
