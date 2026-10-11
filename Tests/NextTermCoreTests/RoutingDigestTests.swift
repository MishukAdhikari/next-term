import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// KTD5's routing digests: only base URLs, config folders, and model and provider selectors are digested, never a key,
/// token, secret or password, nor a value the secret detector would mask. Each is an HMAC-SHA256 under a key made once
/// for this copy of the app, in its sessions folder.
@Suite struct RoutingDigestTests {
    let app = "/Users/x/Applications/Next Term.app"

    /// A parent folder for one test, as Application Support/Next Term is for the app. Remove it after.
    func makeParent() throws -> URL {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-routing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return URL(fileURLWithPath: path)
    }

    /// The sessions folder for the app at `app` in `parent`, with its lock taken.
    func owned(in parent: URL, app: String? = nil) throws -> SessionFiles {
        let files = try SessionFiles.open(in: parent, bundlePath: app ?? self.app)
        #expect(files.lock())
        return files
    }

    func keyFile(_ files: SessionFiles) -> String { files.url.appendingPathComponent(RoutingKey.fileName).path }

    func facts(_ path: String) -> Darwin.stat? {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    /// The kernel's KERN_PROCARGS2 layout: argc, the executable path and its padding, argv, then the environment.
    func procArgs(_ executable: String, _ argv: [String], environment: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(argv.count)) { bytes += $0 }
        bytes += Array(executable.utf8) + [0, 0, 0]
        for text in argv + environment { bytes += Array(text.utf8) + [0] }
        return bytes + [0]
    }

    /// The allowlist: base URLs, config folders, and model and provider selectors. No key, token or header is on it,
    /// and nothing off it is digested, from the login shell's listing or from an agent's environment.
    @Test func onlyTheAllowlistIsDigested() throws {
        let listed = Set(RestoreAgent.allCases.flatMap(\.routingVariables))
        #expect(AgentEvidence.routingKeys == listed)
        for name in listed { #expect(AgentEvidence.mayDigest(name: name), "\(name)") }
        let expected: Set<String> = ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "ANTHROPIC_MODEL",
                                     "OPENAI_MODEL", "CLAUDE_CODE_USE_BEDROCK", "AWS_PROFILE", "HTTPS_PROXY"]
        #expect(listed.isSuperset(of: expected))
        let secrets = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "OPENAI_API_KEY", "AZURE_OPENAI_API_KEY",
                       "DASHSCOPE_API_KEY"]
        for name in secrets { #expect(!listed.contains(name), "\(name)") }
        #expect(AgentEvidence.routingDigest(of: "PATH", "/usr/bin") == nil)
        #expect(AgentEvidence.routingDigest(of: "OPENAI_API_KEY", "sk-proj-abc") == nil)
        let listing = "PATH=/usr/bin\nHOME=/Users/x\nANTHROPIC_BASE_URL=https://a.example.com\nOPENAI_API_KEY=sk-proj-abc\n"
            + "ANTHROPIC_AUTH_TOKEN=abc\nGITHUB_TOKEN=ghp_abc\n"
        #expect(Set(AgentEvidence.routingDigests(environmentListing: listing).keys) == ["ANTHROPIC_BASE_URL"])
        // Asked for by name, a secret is still never digested.
        let environment = ["PATH=/usr/bin", "OPENAI_API_KEY=sk-proj-abcdef123456", "ANTHROPIC_AUTH_TOKEN=abc",
                           "OPENAI_BASE_URL=https://b.example.com"]
        let bytes = procArgs("/opt/homebrew/bin/codex", ["codex"], environment: environment)
        let asked = AgentEvidence.routingKeys.union(["PATH", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        let parsed = try #require(ProcessArguments.parse(bytes, keeping: [], digesting: asked))
        #expect(Set(parsed.routing.keys) == ["OPENAI_BASE_URL"])
    }

    /// A name that looks like a secret's is refused whatever its value. A value the secret detector would mask (a
    /// password or token in a URL, a key-shaped or long random run) is not digested: it reads as `refusedDigest`, which
    /// matches nothing, not even itself, so the agent's resume goes on the line.
    @Test func secretLookingNamesAndValuesAreRefused() throws {
        let names = ["ANTHROPIC_API_KEY", "CACHE_KEY", "MY_TOKEN", "AWS_SESSION_TOKEN", "CLIENT_SECRET", "AWS_SECRET_ACCESS_KEY",
                     "DB_PASSWORD", "PGPASSWORD", "MYSQL_PWD", "SMTP_PASS", "GOOGLE_APPLICATION_CREDENTIALS", "api-key", "x_auth_token"]
        for name in names { #expect(!AgentEvidence.mayDigest(name: name), "\(name)") }
        let refused: [(String, String)] = [
            ("HTTPS_PROXY", "http://me:hunter2@proxy.example.com:8080"),
            ("OPENAI_BASE_URL", "https://glpat-abcdef1234567890xyz@gitlab.example.com/v1"),
            ("ANTHROPIC_MODEL", "Zx9Kq2Lm8Np4Rt6Vw1Yb3Cd5Fg7Hj0Ks"),
            ("ANTHROPIC_BASE_URL", "https://a.example.com/?api_key=Zx9Kq2Lm8Np4Rt6V"),
        ]
        for (name, value) in refused {
            #expect(AgentEvidence.routingDigest(of: name, value) == AgentEvidence.refusedDigest, "\(name)")
        }
        let proxy = "HTTPS_PROXY=http://me:hunter2@proxy.example.com:8080\n"
        #expect(AgentEvidence.routingDigests(environmentListing: proxy) == ["HTTPS_PROXY": AgentEvidence.refusedDigest])
        #expect(!AgentEvidence.routingMatches(AgentEvidence.refusedDigest, AgentEvidence.refusedDigest))
        #expect(!AgentEvidence.routingMatches(AgentEvidence.refusedDigest, nil))
        #expect(AgentEvidence.routingMatches(nil, nil))
        // A plain value is digested, and its digest holds nothing of it.
        let url = try #require(AgentEvidence.routingDigest(of: "ANTHROPIC_BASE_URL", "https://a.example.com"))
        #expect(url != AgentEvidence.refusedDigest && !url.contains("example"))
        #expect(AgentEvidence.routingMatches(url, AgentEvidence.routingDigest(of: "ANTHROPIC_BASE_URL", "https://a.example.com")))
        let plainProxy = AgentEvidence.routingDigest(of: "HTTPS_PROXY", "http://proxy.example.com:8080")
        #expect(plainProxy != nil && plainProxy != AgentEvidence.refusedDigest)
        // A variable listed twice is refused too: which one the shell keeps is not known.
        let twice = AgentEvidence.routingDigests(environmentListing: "AWS_PROFILE=a\nAWS_PROFILE=b\n")
        #expect(twice == ["AWS_PROFILE": AgentEvidence.refusedDigest])
    }

    /// The key is made in the sessions folder on first use, 32 random bytes in a 0600 file, and reads the same at each
    /// load after: from the same folder, and once its lock passes to another opening of it, as at the next launch.
    @Test func theKeyIsMadeOnceAndStaysTheSameAcrossLoads() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        #expect(facts(keyFile(files)) == nil)
        let first = try #require(RoutingKey.load(from: files))
        let info = try #require(facts(keyFile(files)))
        #expect(info.st_mode & 0o7777 == 0o600 && info.st_size == 32 && info.st_mode & S_IFMT == S_IFREG)
        let made = info.st_ino
        let again = try #require(RoutingKey.load(from: files))
        #expect(again.digest("https://a.example.com") == first.digest("https://a.example.com"))
        #expect(facts(keyFile(files))?.st_ino == made)
        files.unlock()
        let next = try SessionFiles.open(in: parent, bundlePath: app)
        var locked = next.lock()
        for _ in 0..<100 where !locked {
            usleep(10_000)
            locked = next.lock()
        }
        #expect(locked)
        let reloaded = try #require(RoutingKey.load(from: next))
        #expect(reloaded.digest("https://a.example.com") == first.digest("https://a.example.com"))
        // It never shows: not in what describes it, nor in a dump of it.
        let bytes = try #require(try next.read(RoutingKey.fileName, maxSize: 64))
        var dumped = ""
        dump(reloaded, to: &dumped)
        for shown in [String(describing: reloaded), String(reflecting: reloaded), dumped] {
            #expect(!shown.contains(bytes.base64EncodedString()) && !shown.contains(bytes.map { String(format: "%02x", $0) }.joined()))
        }
    }

    /// Another key gives other digests: another copy of the app's folder, a key made in memory, and the new key that
    /// replaces a file that is not one. A folder this process does not hold gives none.
    @Test func anotherKeyGivesOtherDigests() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let other = try owned(in: parent, app: "/Applications/Next Term.app")
        let ours = try #require(RoutingKey.load(from: files))
        let theirs = try #require(RoutingKey.load(from: other))
        let value = "https://a.example.com"
        #expect(ours.digest(value) != theirs.digest(value))
        #expect(RoutingKey.random().digest(value) != RoutingKey.random().digest(value))
        #expect(RoutingKey.random().digest(value) != ours.digest(value))
        // A file cut short, or opened to others, is not a key: a new one takes its place.
        try files.replace(RoutingKey.fileName, with: Data(repeating: 7, count: 12))
        let replaced = try #require(RoutingKey.load(from: files))
        #expect(replaced.digest(value) != ours.digest(value))
        #expect(facts(keyFile(files))?.st_size == 32)
        chmod(keyFile(files), 0o644)
        let reopened = try #require(RoutingKey.load(from: files))
        #expect(reopened.digest(value) != replaced.digest(value))
        #expect(facts(keyFile(files)).map { $0.st_mode & 0o7777 } == 0o600)
        // Without the folder's lock nothing is read or made.
        let unheld = try SessionFiles.open(in: parent, bundlePath: "/Users/y/Next Term.app")
        #expect(RoutingKey.load(from: unheld) == nil)
        #expect(facts(keyFile(unheld)) == nil)
    }

    /// The key a process digests with is the sessions folder's once the app names it, read or made there at the first
    /// digest, never before. It is fixed from then on: digested first without a folder, it is a key for this process
    /// only, kept when a folder is named later, which then gets no file.
    @Test func theProcessKeyIsTheFoldersAndFixedAtItsFirstUse() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let current = RoutingKey.Current()
        current.keep(in: files)
        #expect(facts(keyFile(files)) == nil)
        let first = current.key.digest("v")
        #expect(facts(keyFile(files)) != nil)
        #expect(first == RoutingKey.load(from: files)?.digest("v"))
        #expect(current.key.digest("v") == first)
        let early = RoutingKey.Current()
        let before = early.key.digest("v")
        let later = try owned(in: parent, app: "/Applications/Next Term.app")
        early.keep(in: later)
        #expect(early.key.digest("v") == before)
        #expect(facts(keyFile(later)) == nil)
    }
}
