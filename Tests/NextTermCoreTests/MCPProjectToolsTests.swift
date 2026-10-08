import Foundation
import Testing
@testable import NextTermCore

/// Two projects and a folder outside them, with the files the path rules are about.
final class ProjectFixture {
    let base: String
    var a: String { base + "/api" }
    var b: String { base + "/web" }
    var outside: String { base + "/outside" }

    init() throws {
        base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-mcp-files-\(UUID().uuidString)"
        try write("api/src/app.txt", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try write("api/src/needle.swift", "let a = 1\nlet needle = \"found\"\n")
        try write("api/.env", "NEEDLE_TOKEN=abc\n")
        try write("api/keys/server.pem", "pem\n")
        try write("api/id_ed25519", "key\n")
        try write("api/id_rsa.pub", "ssh-ed25519 AAAA me\n")
        try write("api/config.json", #"{"api_key": "sk-abcdefghijklmnop1234", "name": "api"}"# + "\n")
        try write("web/index.html", "<p>needle</p>\n")
        try write("outside/secret.txt", "needle outside\n")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: a + "/link-out.txt", withDestinationPath: outside + "/secret.txt")
        try fm.createSymbolicLink(atPath: a + "/notes.txt", withDestinationPath: a + "/.env")
        try fm.createSymbolicLink(atPath: a + "/link-in.txt", withDestinationPath: a + "/src/app.txt")
        try Data([0x50, 0x4B, 0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: a + "/blob.bin"))
    }

    deinit { try? FileManager.default.removeItem(atPath: base) }

    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: base).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var both: MCPProjects { MCPProjects(open: [a, b], preferred: nil) }
}

func json(_ result: MCPServer.CallResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
}

@Suite struct MCPProjectRulesTests {
    @Test func projectsByFolderNameOrDefault() throws {
        let f = try ProjectFixture()
        #expect(f.both.project(nil).isFailure) // two open, none named
        #expect(MCPProjects(open: [f.a, f.b], preferred: f.b).project(nil) == .success(f.b)) // the caller's window
        #expect(MCPProjects(open: [f.a], preferred: nil).project("") == .success(f.a)) // the only one
        #expect(f.both.project("API") == .success(f.a))
        #expect(f.both.project(f.a) == .success(f.a))
        #expect(f.both.project(f.a + "/src") == .success(f.a + "/src")) // a folder inside one
        #expect(f.both.project(f.outside).isFailure)
        #expect(f.both.project("nope").isFailure)
        #expect(f.both.project(5).isFailure)
        #expect(MCPProjects(open: [], preferred: nil).project(nil).failureText?.contains("open_project") == true)
    }

    @Test func filesStayInsideOpenProjects() throws {
        let f = try ProjectFixture()
        let p = f.both
        // Relative, with no project named: the one project that has it.
        #expect(try p.file("src/app.txt", project: nil).get().relative == "src/app.txt")
        #expect(try p.file("index.html", project: nil).get().root == f.b)
        #expect(try p.file(f.a + "/src/app.txt", project: nil).get().root == f.a)
        // A link inside is read as its target; one leading outside is refused.
        #expect(try p.file("link-in.txt", project: "api").get().relative == "src/app.txt")
        #expect(p.file("link-out.txt", project: "api").failureText?.contains("outside") == true)
        #expect(p.file(f.outside + "/secret.txt", project: nil).failureText?.contains("outside") == true)
        #expect(p.file("../outside/secret.txt", project: "api").failureText?.contains("outside") == true)
        #expect(p.file("src", project: "api").failureText?.contains("folder") == true)
        #expect(p.file("missing.txt", project: "api").failureText?.contains("No such file") == true)
        #expect(p.file(nil, project: "api").isFailure)
        // Deleted files are allowed where asked (get_diff), never through "..".
        #expect(try p.file("gone.txt", project: "api", mustExist: false).get().relative == "gone.txt")
        #expect(p.file("nowhere/../../outside/x", project: "api", mustExist: false).isFailure)
    }

    @Test func secretsAreRefusedWithTheReason() throws {
        let f = try ProjectFixture()
        let p = f.both
        #expect(p.file(".env", project: "api").failureText?.contains("environment file") == true)
        // A harmless name that links to one is refused as well.
        #expect(p.file("notes.txt", project: "api").failureText?.contains("environment file") == true)
        #expect(p.file("keys/server.pem", project: "api").failureText?.contains(".pem") == true)
        #expect(p.file("id_ed25519", project: "api").failureText?.contains("ssh") == true)
        #expect(p.file("id_rsa.pub", project: "api").isSuccess) // a public key is fine
        for path in [".env.local", "app/.env.production", "deploy/prod.env", "app/.flaskenv", "certs/tls.key", "a/.ssh/config", ".git/config",
                     "config/credentials.yml.enc", ".npmrc", ".netrc", "infra/terraform.tfstate", "secrets.json", "id_rsa"] {
            #expect(MCPProjects.secretReason(path) != nil, "\(path)")
        }
        for path in ["README.md", "src/id_utils.py", "src/env.ts", "environment.yml", "docs/keys.md", "token.swift", "id_rsa.pub", ".env.example"] {
            #expect(MCPProjects.secretReason(path) == nil, "\(path)")
        }
    }
}

@Suite struct MCPReadFileTests {
    @Test func linesFromAnOffset() throws {
        let f = try ProjectFixture()
        let page = json(MCPProjectTools.readFile(["path": "src/app.txt", "project": "api", "offset": 4, "limit": 3], in: f.both))
        #expect(page["text"] as? String == "line 4\nline 5\nline 6")
        #expect(page["start_line"] as? Int == 4 && page["end_line"] as? Int == 6)
        #expect(page["total_lines"] as? Int == 10 && page["next_offset"] as? Int == 7)
        let all = json(MCPProjectTools.readFile(["path": f.a + "/src/app.txt"], in: f.both))
        #expect(all["end_line"] as? Int == 10 && all["next_offset"] == nil)
    }

    @Test func badArgumentsAreToolErrors() throws {
        let f = try ProjectFixture()
        func error(_ arguments: [String: Any]) -> String? {
            let result = MCPProjectTools.readFile(arguments, in: f.both)
            return result.isError ? result.text : nil
        }
        #expect(error(["path": "src/app.txt", "project": "api", "offset": 11])?.contains("past the end") == true)
        #expect(error(["path": "src/app.txt", "project": "api", "limit": 0])?.contains("1 to 2000") == true)
        #expect(error(["path": "src/app.txt", "project": "api", "limit": "all"])?.contains("whole number") == true)
        #expect(error(["path": "src/app.txt", "project": "api", "offset": 1.5])?.contains("whole number") == true)
        #expect(error(["path": "blob.bin", "project": "api"])?.contains("binary") == true)
        #expect(error(["path": ".env", "project": "api"])?.contains("Not read") == true)
        #expect(error(["project": "api"])?.contains("path") == true)
    }

    @Test func argumentsAsTheSocketDecodesThem() throws {
        // JSONSerialization's 1 also casts to Bool, and its true to Int: the types must still be told apart.
        let f = try ProjectFixture()
        func call(_ text: String) throws -> MCPServer.CallResult {
            let arguments = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return MCPProjectTools.readFile(arguments, in: f.both)
        }
        let one = try call(#"{"path": "src/app.txt", "project": "api", "offset": 1, "limit": 1}"#)
        #expect(!one.isError && json(one)["text"] as? String == "line 1", "\(one.text)")
        #expect(try call(#"{"path": "src/app.txt", "project": "api", "limit": true}"#).text.contains("whole number"))
        let regex = try #require(try JSONSerialization.jsonObject(with: Data(#"{"query": "x", "project": "api", "regex": 1}"#.utf8)) as? [String: Any])
        #expect(MCPProjectTools.findInFiles(regex, in: f.both, git: nil).text.contains("true or false"))
        #expect(MCPServer.isBoolean(true) && !MCPServer.isBoolean(1) && !MCPServer.isBoolean("true"))
    }

    @Test func secretValuesAreMasked() throws {
        let f = try ProjectFixture()
        let result = json(MCPProjectTools.readFile(["path": "config.json", "project": "api"], in: f.both))
        let text = try #require(result["text"] as? String)
        #expect(!text.contains("sk-abcdef") && text.contains(MCPRedaction.mask) && text.contains("\"name\": \"api\""))
        #expect((result["redacted"] as? Int ?? 0) >= 1)
    }
}

@Suite struct MCPFindInFilesTests {
    @Test func findsWithLinesAndSkipsSecretsAndLinksOut() throws {
        let f = try ProjectFixture()
        let result = MCPProjectTools.findInFiles(["query": "needle", "project": "api"], in: f.both, git: nil)
        #expect(!result.isError, "\(result.text)")
        let found = json(result)
        let matches = try #require(found["matches"] as? [[String: Any]])
        #expect(matches.count == 1)
        #expect(matches.first?["path"] as? String == "src/needle.swift" && matches.first?["line"] as? Int == 2)
        #expect(matches.first?["column"] as? Int == 5 && matches.first?["text"] as? String == "let needle = \"found\"")
        #expect((found["secret_files_skipped"] as? Int ?? 0) >= 1) // .env holds NEEDLE too; link-out.txt points outside
    }

    @Test func optionsAndErrors() throws {
        let f = try ProjectFixture()
        let p = f.both
        let regex = json(MCPProjectTools.findInFiles(["query": #"line \d+$"#, "regex": true, "project": "api", "max_results": 3], in: p, git: nil))
        #expect((regex["matches"] as? [[String: Any]])?.count == 3 && regex["total"] as? Int == 10 && regex["more"] != nil)
        let globbed = json(MCPProjectTools.findInFiles(["query": "let", "glob": "*.txt", "project": "api"], in: p, git: nil))
        #expect(globbed["total"] as? Int == 0)
        let cased = json(MCPProjectTools.findInFiles(["query": "NEEDLE", "case_sensitive": true, "project": "api"], in: p, git: nil))
        #expect(cased["total"] as? Int == 0)
        #expect(MCPProjectTools.findInFiles(["query": "(", "regex": true, "project": "api"], in: p, git: nil).text.contains("regular expression"))
        #expect(MCPProjectTools.findInFiles(["query": "", "project": "api"], in: p, git: nil).isError)
        #expect(MCPProjectTools.findInFiles(["query": "x", "max_results": 500, "project": "api"], in: p, git: nil).isError)
        #expect(MCPProjectTools.findInFiles(["query": "x", "regex": "yes", "project": "api"], in: p, git: nil).isError)
        #expect(MCPProjectTools.findInFiles(["query": "needle"], in: p, git: nil).text.contains("Give project"))
    }
}

@Suite struct MCPRedactionTests {
    @Test func credentialsAreMasked() {
        let cases = [
            "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv",
            "DB_PASSWORD=s3cr3t-passw0rd",
            "  password: hunter2x",
            "+  password: hunter2x", // a line a diff adds
            "-DB_PASSWORD=s3cr3t-passw0rd",
            #"{"client_secret": "Zq8pL2vX9mN4"}"#,
            "git clone https://me:pa55word@github.com/me/repo.git",
            "auth: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmn",
            "AWS: AKIAIOSFODNN7EXAMPLE",
            "blob 4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu",
        ]
        for line in cases {
            let (text, count) = MCPRedaction.redact(line)
            #expect(count >= 1 && text.contains(MCPRedaction.mask), "\(line) -> \(text)")
        }
        #expect(!MCPRedaction.redact(cases[7]).text.contains("pa55word") && cases[7].contains("pa55word"))
    }

    @Test func codeStaysReadable() {
        let lines = [
            "let token = try await session.getToken()",
            "tokenizer = \"bert-base\"",
            "password: String",
            "+  password: String",
            "let secret = config.secret",
            "commit 3f786850e387550fdab836ed7e6dc881de23001b",
            "id: 123e4567-e89b-12d3-a456-426614174000",
            "import Foo from \"@/components/dashboard/settings/notifications/panel\"",
            "API_KEY=${API_KEY}",
            "func handleRequestWithAVeryLongDescriptiveNameForTesting()",
        ]
        for line in lines {
            #expect(MCPRedaction.redact(line).text == line, "\(line)")
        }
    }

    @Test func aPrivateKeyKeepsItsLines() {
        let key = "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nQyNTUxOQAAACD\n-----END OPENSSH PRIVATE KEY-----\nz"
        let (text, _) = MCPRedaction.redact(key)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 6)
        #expect(!text.contains("b3BlbnNz") && !text.contains("QyNTUxOQ") && text.hasPrefix("a\n") && text.hasSuffix("\nz"))
    }
}

@Suite struct MCPGitToolsTests {
    /// A repository as project "repo": one commit, then a staged edit, an unstaged edit, a new file and
    /// a tracked .env that changed.
    func repository() throws -> (ProjectFixture, MCPProjects, String)? {
        guard let git = GitRunner.locateGit() else { return nil } // no git on this machine
        let f = try ProjectFixture()
        let repo = f.base + "/repo"
        func sh(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }
        try f.write("repo/staged.txt", "one\n")
        try f.write("repo/edited.txt", "a\nb\n")
        try f.write("repo/.env", "TOKEN=old\n")
        try sh("init")
        try sh("add", "-A")
        try sh("commit", "-m", "first")
        try f.write("repo/staged.txt", "one\ntwo\n")
        try sh("add", "staged.txt")
        try f.write("repo/edited.txt", "a\nB\n")
        try f.write("repo/new.txt", "fresh\n")
        try f.write("repo/.env", "TOKEN=sk-abcdefghijklmnopqrstuvwx\n")
        return (f, MCPProjects(open: [repo], preferred: nil), git)
    }

    @Test func statusListsEachChange() throws {
        guard let (fixture, projects, git) = try repository() else { return }
        defer { withExtendedLifetime(fixture) {} } // it deletes the folders when it goes
        let result = MCPProjectTools.gitStatus([:], in: projects, git: git)
        #expect(!result.isError, "\(result.text)")
        let status = json(result)
        #expect(status["branch"] as? String == "main" && status["upstream"] is NSNull)
        let files = try #require(status["files"] as? [[String: Any]])
        func file(_ path: String) -> [String: Any]? { files.first { $0["path"] as? String == path } }
        #expect(file("staged.txt")?["staged"] as? Bool == true && file("staged.txt")?["unstaged"] as? Bool == false)
        #expect(file("staged.txt")?["added"] as? Int == 1)
        #expect(file("edited.txt")?["state"] as? String == "modified" && file("edited.txt")?["unstaged"] as? Bool == true)
        #expect(file("new.txt")?["state"] as? String == "untracked")
        #expect(MCPProjectTools.gitStatus([:], in: projects, git: nil).text.contains("git is not installed"))
    }

    @Test func diffsAgainstHeadStagedOrUnstaged() throws {
        guard let (fixture, projects, git) = try repository() else { return }
        defer { withExtendedLifetime(fixture) {} } // it deletes the folders when it goes
        let head = json(MCPProjectTools.getDiff(["path": "edited.txt"], in: projects, git: git))
        let text = try #require(head["diff"] as? String)
        #expect(text.contains("-b\n+B\n") && text.contains("--- a/edited.txt") && !text.contains("index "))
        let staged = json(MCPProjectTools.getDiff(["which": "staged"], in: projects, git: git))
        #expect((staged["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["staged.txt"])
        let unstaged = json(MCPProjectTools.getDiff(["which": "unstaged"], in: projects, git: git))
        let paths = (unstaged["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        #expect(paths.contains("edited.txt") && paths.contains("new.txt") && !paths.contains("staged.txt"))
        // The .env changed too, but it is left out, and asking for it is refused.
        let all = json(MCPProjectTools.getDiff([:], in: projects, git: git))
        #expect(!(all["diff"] as? String ?? "").contains("sk-abc") && (all["left_out"] as? [[String: Any]])?.first?["path"] as? String == ".env")
        #expect(MCPProjectTools.getDiff(["path": ".env"], in: projects, git: git).text.contains("Not read"))
        // Cut at max_chars, and bad arguments.
        #expect(MCPProjectTools.getDiff(["which": "both"], in: projects, git: git).isError)
        #expect(MCPProjectTools.getDiff(["max_chars": 10], in: projects, git: git).isError)
        let clean = json(MCPProjectTools.getDiff(["path": "staged.txt", "which": "unstaged"], in: projects, git: git))
        #expect(clean["note"] as? String != nil && (clean["diff"] as? String)?.isEmpty == true)
    }

    @Test func notARepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let f = try ProjectFixture()
        #expect(MCPProjectTools.gitStatus(["project": "web"], in: f.both, git: git).text.contains("not in a git repository"))
    }
}

extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
    var isSuccess: Bool { !isFailure }
}

extension Result where Failure == MCPToolError {
    var failureText: String? { if case .failure(let error) = self { return error.text } else { return nil } }
}
