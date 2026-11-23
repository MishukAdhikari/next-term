import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Always approvals: who, which keys, what for and where a grant holds, which commands never get one, and the sealed
/// file that keeps them. Every value is made up; every folder is a fixture of the test's own.
@Suite struct SecretAlwaysTests {
    static func fixture(_ name: String = "always") throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return canonicalPath(url.path)
    }

    static func stamp(_ inode: UInt64 = 7, changed: Int64 = 1) -> SecretFileStamp {
        SecretFileStamp(device: 1, inode: inode, size: 100, modified: 5, changed: changed)
    }

    static let codex = SecretAgentIdentity(path: "/Applications/Codex/codex", stamp: stamp(), team: "TEAM123456")

    static func definition(_ words: [String] = ["/usr/bin/curl", "-sS", "https://api.example.com"], folder: String = "/a/app") -> SecretAlwaysDefinition {
        var definition = SecretAlwaysDefinition(door: .wrapper, keys: ["API_TOKEN": "API_TOKEN"])
        definition.words = words
        definition.executable = "/usr/bin/curl"
        definition.executableStamp = stamp(9)
        definition.folder = folder
        return definition
    }

    static func grant(scope: SecretAlwaysScope, identity: SecretAgentIdentity = codex,
                      definition: SecretAlwaysDefinition = definition()) -> SecretAlwaysGrant {
        SecretAlwaysGrant(agent: "Codex", identity: identity, door: .wrapper, keys: ["API_TOKEN": "API_TOKEN"], marks: ["API_TOKEN": "m1"],
                          definition: definition.digest, summary: "curl -sS https://api.example.com", scope: scope)
    }

    static func ask(folder: String = "/a/app", project: String? = nil, identity: SecretAgentIdentity = codex,
                    definition: SecretAlwaysDefinition = definition(), marks: [String: String] = ["API_TOKEN": "m1"]) -> SecretAlwaysAsk {
        SecretAlwaysAsk(identity: identity, door: .wrapper, keys: ["API_TOKEN": "API_TOKEN"], marks: marks, definition: definition.digest,
                        folder: folder, project: project)
    }

    /// Every folder is where it was.
    static let anyRoot: (String) -> (device: UInt64, inode: UInt64)? = { _ in (1, 42) }
    static func scope(_ kind: SecretAlwaysScope.Kind, _ path: String, caseSensitive: Bool = true) -> SecretAlwaysScope {
        SecretAlwaysScope(kind: kind, path: path, device: 1, inode: 42, caseSensitive: caseSensitive)
    }

    // MARK: identity

    @Test func theSameAgentAnswers() {
        let grant = Self.grant(scope: Self.scope(.folder, "/a/app"))
        #expect(grant.answers(Self.ask(), identify: Self.anyRoot))
    }

    /// A program by the same name is another identity: another file, the same file rewritten (its ctime), another
    /// signer, or another script under the same interpreter.
    @Test func anotherBinaryByTheSameNameAsks() {
        let grant = Self.grant(scope: Self.scope(.folder, "/a/app"))
        var moved = Self.codex
        moved.path = "/tmp/codex"
        var rewritten = Self.codex
        rewritten.stamp = Self.stamp(changed: 2)
        var unsigned = Self.codex
        unsigned.team = nil
        var scripted = Self.codex
        scripted.script = "/tmp/fake.js"
        for other in [moved, rewritten, unsigned, scripted] {
            #expect(!grant.answers(Self.ask(identity: other), identify: Self.anyRoot))
        }
    }

    @Test func theStampSeesARewriteThatKeptItsSizeAndTime() throws {
        let folder = try Self.fixture()
        let file = folder + "/agent"
        try Data("one".utf8).write(to: URL(fileURLWithPath: file))
        let before = try #require(SecretFileStamp.of(file))
        Thread.sleep(forTimeInterval: 0.02)
        try Data("two".utf8).write(to: URL(fileURLWithPath: file))
        // Its modification time set back as it was: the kernel's change time still moved.
        var times = [timespec(tv_sec: Int(before.modified / 1_000_000_000), tv_nsec: Int(before.modified % 1_000_000_000)),
                     timespec(tv_sec: Int(before.modified / 1_000_000_000), tv_nsec: Int(before.modified % 1_000_000_000))]
        #expect(utimensat(AT_FDCWD, file, &times, 0) == 0)
        let after = try #require(SecretFileStamp.of(file))
        #expect(after.size == before.size)
        #expect(after.modified == before.modified)
        #expect(after != before)
    }

    // MARK: definition

    /// Anything in the definition changed asks again: the words, the executable's file, the folder, a key's variable,
    /// a file that changes what it does, a hub server's URL or list.
    @Test func aChangedDefinitionAsks() {
        let base = Self.definition()
        let grant = Self.grant(scope: Self.scope(.folder, "/a/app"), definition: base)
        var changes: [SecretAlwaysDefinition] = []
        var words = base
        words.words.append("--data")
        changes.append(words)
        var file = base
        file.executableStamp = Self.stamp(9, changed: 3)
        changes.append(file)
        var env = base
        env.keys = ["API_TOKEN": "OTHER_NAME"]
        changes.append(env)
        var npmrc = base
        npmrc.files = [".npmrc": "abc"]
        changes.append(npmrc)
        var path = base
        path.pathDigest = "other"
        changes.append(path)
        for changed in changes {
            #expect(changed.digest != base.digest)
            #expect(!grant.answers(Self.ask(definition: changed), identify: Self.anyRoot))
        }
        var hub = SecretAlwaysDefinition(door: .hub, keys: ["API_TOKEN": "API_TOKEN"])
        hub.url = "https://mcp.example.com/mcp"
        hub.headers = ["Authorization": "Bearer ${secret:API_TOKEN}"]
        hub.list = "/a/app/.next-term/mcp.json"
        hub.listDigest = "d1"
        var swapped = hub
        swapped.url = "https://evil.example.com/mcp"
        var relisted = hub
        relisted.listDigest = "d2"
        #expect(Set([hub.digest, swapped.digest, relisted.digest]).count == 3)
    }

    /// A key given a new value, renamed or deleted and added again has another sealed box: its grant can't answer.
    @Test func aChangedKeyAsks() throws {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "API_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-value-0123456789"))
        let mark = try #require(vault.index.entry(named: "API_TOKEN")?.valueMark)
        let grant = SecretAlwaysGrant(agent: "Codex", identity: Self.codex, door: .wrapper, keys: ["API_TOKEN": "API_TOKEN"],
                                      marks: ["API_TOKEN": mark], everyUse: ["API_TOKEN"], definition: "d", summary: "s",
                                      scope: Self.scope(.folder, "/a/app"))
        #expect(SecretAlwaysGrants.kept([grant], in: vault.index).count == 1)
        _ = try vault.edit("API_TOKEN", newName: nil, purpose: "now with a note", purposeBy: .user)
        #expect(SecretAlwaysGrants.kept([grant], in: vault.index).count == 1, "a note alone keeps it")
        _ = try vault.replace("API_TOKEN", value: SecretBytes(utf8: "made-up-other-value-012345"), writeOnly: false, origin: .settings)
        #expect(SecretAlwaysGrants.kept([grant], in: vault.index).isEmpty)
        #expect(!grant.answers(Self.ask(marks: ["API_TOKEN": vault.index.entry(named: "API_TOKEN")!.valueMark]), identify: Self.anyRoot))
    }

    /// A key set to ask for Touch ID every time after its grant was made, while it allowed lasting approvals, is the user
    /// asking for more: the grant no longer answers for it. One made while it asked every time (once per launch) still
    /// does, and a key eased to lasting approvals since keeps its grants.
    @Test func aKeySetToAskEveryTimeSinceAsks() throws {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "API_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-value-0123456789"), asksEveryUse: false)
        let mark = try #require(vault.index.entry(named: "API_TOKEN")?.valueMark)
        func grant(everyUse: [String]) -> SecretAlwaysGrant {
            SecretAlwaysGrant(agent: "Codex", identity: Self.codex, door: .wrapper, keys: ["API_TOKEN": "API_TOKEN"], marks: ["API_TOKEN": mark],
                              everyUse: everyUse, definition: Self.definition().digest, summary: "s", scope: Self.scope(.folder, "/a/app"))
        }
        let lasting = grant(everyUse: [])
        let onceALaunch = grant(everyUse: ["API_TOKEN"])
        #expect(SecretAlwaysGrants.kept([lasting, onceALaunch], in: vault.index).count == 2)
        _ = try vault.edit("API_TOKEN", newName: nil, purpose: nil, purposeBy: nil, asksEveryUse: true)
        #expect(vault.index.entry(named: "API_TOKEN")?.valueMark == mark, "the box is the same: the setting is checked on its own")
        #expect(SecretAlwaysGrants.kept([lasting, onceALaunch], in: vault.index) == [onceALaunch])
        var ask = Self.ask(marks: ["API_TOKEN": mark])
        ask.everyUse = SecretAlwaysGrants.everyUse(["API_TOKEN"], in: vault.index)
        #expect(!lasting.answers(ask, identify: Self.anyRoot))
        #expect(onceALaunch.answers(ask, identify: Self.anyRoot))
    }

    // MARK: refused

    static func refusal(_ words: [String], executable: String? = "/usr/bin/curl", script: String? = nil, warnings: [String] = [],
                        shell: Bool = false, hooks: Bool = false, scopes: [String] = ["/a/app"],
                        writable: @escaping (String) -> Bool = { _ in false }) -> String? {
        SecretAlwaysRules.refusal(SecretAlwaysRules.Command(words: words, usesShellSyntax: shell, warnings: warnings, executable: executable,
                                                            script: script, hasHooks: hooks), scopes: scopes, writable: writable)
    }

    @Test func aFixedPinnedCommandIsOffered() {
        #expect(Self.refusal(["curl", "-sS", "https://api.example.com"]) == nil)
    }

    @Test func npxDashYIsRefusedWithItsReason() {
        let words = ["npx", "-y", "@acme/mcp-server"]
        let warnings = SecretRun.warnings(argv: words)
        let reason = Self.refusal(words, executable: "/usr/local/bin/npx", warnings: warnings)
        #expect(reason == "Always isn\u{2019}t offered: npx -y fetches new code each time.")
    }

    @Test func indirectRunnersAreRefused() {
        #expect(Self.refusal(["npm", "run", "dev"], executable: "/usr/bin/npm")?.contains("package.json") == true)
        #expect(Self.refusal(["pnpm", "start"], executable: "/usr/bin/pnpm")?.contains("package.json") == true)
        #expect(Self.refusal(["make", "deploy"], executable: "/usr/bin/make")?.contains("Makefile") == true)
        #expect(Self.refusal(["just", "x"], executable: "/usr/bin/just")?.contains("justfile") == true)
        #expect(Self.refusal(["git", "push"], executable: "/usr/bin/git", hooks: true)?.contains("hooks") == true)
        // Without hooks too: its config (core.fsmonitor, core.sshCommand, a credential helper) names programs to run.
        #expect(Self.refusal(["git", "push"], executable: "/usr/bin/git", hooks: false)?.contains("config") == true)
    }

    /// Every package manager's verb may run what package.json says: install, ci, publish and pack run its lifecycle
    /// scripts, and pnpm runs a script by its bare name.
    @Test func everyPackageManagerVerbIsRefused() {
        for words in [["npm", "install"], ["npm", "ci"], ["npm", "publish"], ["npm", "pack"], ["pnpm", "build"], ["yarn", "add", "x"],
                      ["bun", "install"]] {
            #expect(Self.refusal(words, executable: "/usr/local/lib/node_modules/npm/bin/npm-cli.js")?.contains("package.json") == true,
                    "\(words)")
        }
        for words in [["go", "run", "."], ["swift", "run"], ["pytest"], ["bundle", "exec", "rake"], ["uv", "run", "x.py"]] {
            #expect(Self.refusal(words, executable: "/usr/local/bin/\(words[0])")?.contains("own code") == true, "\(words)")
        }
    }

    /// `env`, `sudo`, `nice` and the like start a program by its name, and their options take values: `env -u ls python3
    /// evil.py` reads as `ls` to a word-by-word look, so it would bind /bin/ls and never the script that runs.
    @Test func aWrapperInFrontIsRefused() {
        let evasion = ["env", "-u", "ls", "python3", "/Users/me/evil.py"]
        #expect(Self.refusal(evasion, executable: "/bin/ls")?.contains("by its name") == true)
        for words in [["env", "curl", "x"], ["sudo", "curl", "x"], ["nice", "-n", "5", "curl"], ["timeout", "9", "curl"], ["FOO=1", "curl"]] {
            #expect(Self.refusal(words) != nil, "\(words)")
        }
        #expect(Self.refusal(["/usr/bin/curl", "-sS", "https://api.example.com"]) == nil)
    }

    /// An interpreter's options can load other code (`node --require=…`, `perl -M…`); Python loads `.pth` files from the
    /// user's own site-packages unless isolated; and an interpreter named with its version is one too.
    @Test func interpreterOptionsAndVersionsAreChecked() {
        let script = "/usr/local/lib/tool/main.js"
        #expect(Self.refusal(["node", script], executable: "/usr/bin/node", script: script) == nil)
        #expect(Self.refusal(["node", "--require=/Users/me/evil.js", script], executable: "/usr/bin/node", script: script)?
            .contains("--require=/Users/me/evil.js") == true)
        #expect(Self.refusal(["perl", "-MEvil", "/usr/local/lib/t.pl"], executable: "/usr/bin/perl", script: "/usr/local/lib/t.pl") != nil)
        let py = "/usr/local/lib/tool/main.py"
        #expect(Self.refusal(["python3", py], executable: "/usr/bin/python3", script: py)?.contains("-I") == true)
        #expect(Self.refusal(["python3", "-I", "-u", py], executable: "/usr/bin/python3", script: py) == nil)
        #expect(Self.refusal(["python3", "-I", "-X", "importtime", py], executable: "/usr/bin/python3", script: py) != nil)
        // python3.12 is python's: its script is checked, not skipped.
        #expect(Self.refusal(["python3.12", "-I", "/a/app/x.py"], executable: "/usr/local/bin/python3.12", script: "/a/app/x.py")?
            .contains("your agents can change") == true)
        #expect(SecretAlwaysRules.isInterpreter("python3.12") && SecretAlwaysRules.isInterpreter("node22"))
        #expect(!SecretAlwaysRules.isInterpreter("nodemon") && !SecretAlwaysRules.isInterpreter("perlbrew"))
    }

    /// A folder the user can write anywhere above the executable can be renamed and made again with another file at
    /// that path between the check and the run.
    @Test func aWritableFolderAboveIsChangeable() {
        let writable: (String) -> Bool = { $0 == "/opt/tools" }
        #expect(Self.refusal(["tool"], executable: "/opt/tools/bin/sub/tool", writable: writable)?.contains("folder your agents") == true)
        #expect(Self.refusal(["tool"], executable: "/usr/local/bin/tool", writable: writable) == nil)
    }

    /// The agent's own launcher (Codex's node starting its binary) stands for it; a same-named program the agent's Bash
    /// `exec`s, so its parent is the agent, does not.
    @Test func onlyAnAgentsOwnPackageLaunchesIt() {
        let npm = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
        #expect(SecretAgentLaunch.isLaunched("/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex",
                                             byScript: npm, isPackage: { _ in false }))
        let pnpm = "/Users/me/Library/pnpm/global/5/.pnpm/@openai+codex@1/node_modules/@openai/codex/bin/codex.js"
        #expect(SecretAgentLaunch.isLaunched("/Users/me/Library/pnpm/global/5/.pnpm/@openai+codex-darwin-arm64@1/node_modules/x/codex",
                                             byScript: pnpm, isPackage: { _ in false }))
        #expect(!SecretAgentLaunch.isLaunched("/tmp/evil/codex", byScript: npm, isPackage: { _ in false }))
        #expect(!SecretAgentLaunch.isLaunched("/opt/homebrew/lib/evil", byScript: npm, isPackage: { _ in false }))
        // A checkout of its own, by its package.json.
        let dev = "/Users/me/src/codex/codex-cli/bin/codex.js"
        let isPackage: (String) -> Bool = { $0 == "/Users/me/src/codex/codex-cli" }
        #expect(SecretAgentLaunch.isLaunched("/Users/me/src/codex/codex-cli/vendor/codex", byScript: dev, isPackage: isPackage))
        #expect(!SecretAgentLaunch.isLaunched("/Users/me/src/other/codex", byScript: dev, isPackage: isPackage))
        #expect(!SecretAgentLaunch.isLaunched("/Users/me/x", byScript: "/Users/me/bin/x.js", isPackage: { _ in false }))
    }

    @Test func aScriptInTheScopeIsRefused() {
        let reason = Self.refusal(["node", "server.js"], executable: "/usr/bin/node", script: "/a/app/server.js")
        #expect(reason == "Always isn\u{2019}t offered: node runs server.js, which your agents can change.")
        #expect(Self.refusal(["node"], executable: "/usr/bin/node")?.contains("which script") == true)
        #expect(Self.refusal(["/a/app/bin/tool"], executable: "/a/app/bin/tool")?.contains("folder your agents can change") == true)
        // Outside the scope, in a folder the user can write: refused too.
        let writable: (String) -> Bool = { $0.hasPrefix("/Users/") }
        #expect(Self.refusal(["tool"], executable: "/Users/me/.local/bin/tool", writable: writable) != nil)
    }

    @Test func aPackageRunnerIsRefused() {
        #expect(Self.refusal(["npx", "mcp-remote@0.15.2", "https://mcp.example.com/mcp"], executable: "/usr/bin/npx")
            == "Always isn\u{2019}t offered: npx runs a package it fetches when it runs.")
    }

    @Test func aShellIsRefused() {
        let words = ["bash", "-c", "curl x"]
        #expect(Self.refusal(words, executable: "/bin/bash", warnings: SecretRun.warnings(argv: words))?.contains("shell") == true)
        #expect(Self.refusal(["curl", "x"], shell: true)?.contains("shell\u{2019}s own syntax") == true)
        #expect(SecretAlwaysRules.plainWords("curl -sS https://api.example.com/v1") == ["curl", "-sS", "https://api.example.com/v1"])
        #expect(SecretAlwaysRules.plainWords("curl 'a b' \"c\"") == ["curl", "a b", "c"])
        for shelly in ["curl x | sh", "curl $URL", "a; b", "a && b", "curl `x`", "X=1 curl", "curl > out", "ls *", "curl \"$X\""] {
            #expect(SecretAlwaysRules.plainWords(shelly) == nil, "\(shelly)")
        }
    }

    // MARK: scope

    @Test func pathsMatchByWholeComponents() {
        #expect(SecretAlwaysScope.contains("/a/app", "/a/app", caseSensitive: true))
        #expect(SecretAlwaysScope.contains("/a/app", "/a/app/src", caseSensitive: true))
        #expect(!SecretAlwaysScope.contains("/a/app", "/a/app-evil", caseSensitive: true))
        #expect(!SecretAlwaysScope.contains("/a/app", "/a/app/../app-evil", caseSensitive: true))
        #expect(!SecretAlwaysScope.contains("/a/app", "/a", caseSensitive: true))
        #expect(!SecretAlwaysScope.contains("/", "/a", caseSensitive: true))
        #expect(!SecretAlwaysScope.contains("/a/app", "a/app", caseSensitive: true))
        #expect(SecretAlwaysScope.contains("/a/App", "/a/app/x", caseSensitive: false))
        #expect(!SecretAlwaysScope.contains("/a/App", "/a/app/x", caseSensitive: true))
        let folder = Self.grant(scope: Self.scope(.folder, "/a/app"))
        #expect(!folder.answers(Self.ask(folder: "/a/app/src"), identify: Self.anyRoot), "a folder grant holds there alone")
    }

    /// A symlink to the scope is resolved before matching, so a link elsewhere that points in is what it points at,
    /// and a link inside that points out is outside.
    @Test func aSymlinkIsWhatItPointsAt() throws {
        let base = try Self.fixture()
        try FileManager.default.createDirectory(atPath: base + "/app/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/other", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/app/out", withDestinationPath: base + "/other")
        let scope = try #require(SecretAlwaysScope.at(base + "/app", kind: .project))
        #expect(scope.covers(folder: canonicalPath(base + "/app/src"), project: nil, identify: SecretAlwaysScope.identify))
        #expect(!scope.covers(folder: canonicalPath(base + "/app/out"), project: nil, identify: SecretAlwaysScope.identify))
    }

    /// The root deleted and made again under its path (another inode), or moved away, asks again.
    @Test func anInodeChangeAsks() throws {
        let base = try Self.fixture()
        let app = base + "/app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let scope = try #require(SecretAlwaysScope.at(app, kind: .project))
        #expect(scope.covers(folder: app, project: nil, identify: SecretAlwaysScope.identify))
        try FileManager.default.removeItem(atPath: app)
        try FileManager.default.createDirectory(atPath: base + "/filler", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let now = try #require(SecretAlwaysScope.identify(app))
        if now.inode != scope.inode {
            #expect(!scope.covers(folder: app, project: nil, identify: SecretAlwaysScope.identify))
        }
        try FileManager.default.moveItem(atPath: app, toPath: base + "/moved")
        #expect(!scope.covers(folder: app, project: nil, identify: SecretAlwaysScope.identify))
    }

    // MARK: worktrees

    static func git(_ arguments: [String], in folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        process.environment = ["HOME": folder, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
                               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }

    /// git says where the main checkout and a linked worktree are; a `.git` file someone wrote doesn't make a root.
    @Test func worktreesAreFoundByGit() throws {
        let base = try Self.fixture()
        let main = base + "/repo"
        try FileManager.default.createDirectory(atPath: main + "/src", withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: main)
        try Data("x".utf8).write(to: URL(fileURLWithPath: main + "/src/a.txt"))
        try Self.git(["add", "."], in: main)
        try Self.git(["commit", "-q", "-m", "one"], in: main)
        try Self.git(["worktree", "add", "-q", base + "/wt", "-b", "side"], in: main)
        let places = SecretPlaces.of(canonicalPath(base + "/wt"), git: "/usr/bin/git", home: base + "/home")
        #expect(places.project == canonicalPath(main))
        #expect(places.worktree == canonicalPath(base + "/wt"))
        #expect(places.scopes == [.project, .worktree])
        let inMain = SecretPlaces.of(canonicalPath(main + "/src"), git: "/usr/bin/git", home: base + "/home")
        #expect(inMain.project == canonicalPath(main))
        #expect(inMain.worktree == nil)
        #expect(inMain.scopes == [.project, .folder])
        // "Always in repo" holds in its linked worktree, by git's word for the asking folder.
        let scope = try #require(SecretAlwaysScope.at(canonicalPath(main), kind: .project))
        #expect(scope.covers(folder: canonicalPath(base + "/wt"), project: places.project, identify: SecretAlwaysScope.identify))
        // A `.git` file made by hand, naming nothing: no root there.
        let fake = base + "/fake/deep"
        try FileManager.default.createDirectory(atPath: fake, withIntermediateDirectories: true)
        try Data("gitdir: \(main)/.git".utf8).write(to: URL(fileURLWithPath: base + "/fake/.git"))
        let faked = SecretPlaces.of(canonicalPath(fake), git: "/usr/bin/git", home: base + "/home")
        #expect(faked.project != canonicalPath(base + "/fake"))
        #expect(faked.worktree == nil)
    }

    // MARK: choices

    @Test func alwaysChoicesComeLastAndOnlyLocally() {
        let offered = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: false, always: [.project, .folder])
        #expect(offered == [.once, .fifteenMinutes, .untilLock, .alwaysProject, .alwaysFolder])
        #expect(SecretApprovalChoices.offered(isWrapper: true, isRemote: true, asksEveryUse: false, always: [.project]) == [.once])
        // A key that asks every time keeps Always, alone beside Allow once.
        #expect(SecretApprovalChoices.offered(isWrapper: false, isRemote: false, asksEveryUse: true, always: [.folder]) == [.once, .alwaysFolder])
        #expect(SecretApprovalChoices.offered(isWrapper: false, isRemote: false, asksEveryUse: true) == [.once])
    }

    // MARK: the sealed file

    static func store(_ folder: SecretFolder, key: SymmetricKey, floor: Int = 0) -> SecretAlwaysStore {
        SecretAlwaysStore(folder: folder, key: key, floor: floor)
    }

    static func secrets() throws -> SecretFolder {
        SecretFolder(url: URL(fileURLWithPath: try fixture("always-file")).appendingPathComponent("Secrets.noindex", isDirectory: true))
    }

    @Test func aGrantReadsBackSealed() throws {
        let folder = try Self.secrets()
        let key = SymmetricKey(size: .bits256)
        let grant = Self.grant(scope: Self.scope(.folder, "/a/app"))
        let made = try Self.store(folder, key: key).update(startsOver: true) { body in
            body.grants = SecretAlwaysGrants.adding(grant, to: body.grants)
            return (true, ())
        }
        #expect(made.sequence == 1)
        guard case .success(let body) = Self.store(folder, key: key, floor: 1).read() else { Issue.record("not read"); return }
        #expect(body.grants == [grant])
        // Another key opens nothing.
        #expect(Self.store(folder, key: SymmetricKey(size: .bits256)).read() == .failure(.tampered))
    }

    /// A program that writes the file can't add a grant: it has no key, so its MAC fails.
    @Test func anAgentCantAddAGrantByWritingTheFile() throws {
        let folder = try Self.secrets()
        let key = SymmetricKey(size: .bits256)
        try Self.store(folder, key: key).update(startsOver: true) { _ in (true, ()) }
        let data = try #require(try folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize))
        // The body rewritten with a grant, the old MAC kept.
        var outer = try JSONDecoder().decode(SecretAlwaysFile.Outer.self, from: data)
        let forged = SecretAlwaysFile.Body(grants: [Self.grant(scope: Self.scope(.project, "/a"))], sequence: 5)
        outer.body = try SecretAlwaysFile.encoder.encode(forged)
        try folder.write(SecretAlwaysFile.name, data: try JSONEncoder().encode(outer))
        #expect(Self.store(folder, key: key).read() == .failure(.tampered))
        // And a whole file made with a key of its own.
        try folder.write(SecretAlwaysFile.name, data: try SecretAlwaysFile.encode(forged, key: SymmetricKey(size: .bits256)))
        #expect(Self.store(folder, key: key).read() == .failure(.tampered))
        // Settings may list what is there, unchecked; nothing answers from it.
        #expect(SecretAlwaysFile.peek(try folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize))?.grants.count == 1)
    }

    /// An older copy put back, its MAC still good, reads as tampered once the vault's floor passed it: a removed grant
    /// never comes back, after a relaunch too.
    @Test func aRollbackIsRefused() throws {
        let folder = try Self.secrets()
        let key = SymmetricKey(size: .bits256)
        let grant = Self.grant(scope: Self.scope(.folder, "/a/app"))
        let added = try Self.store(folder, key: key).update(startsOver: true) { body in
            body.grants = [grant]
            return (true, ())
        }
        let withGrant = try #require(try folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize))
        let removed = try Self.store(folder, key: key, floor: added.sequence).update { body in
            body.grants = []
            return (true, ())
        }
        // The vault keeps the floor the removal raised it to.
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.raiseFloor(of: SecretAlwaysFile.name, to: removed.sequence)
        #expect(vault.index.floor(of: SecretAlwaysFile.name) == removed.sequence)
        _ = try vault.raiseFloor(of: SecretAlwaysFile.name, to: 1)
        #expect(vault.index.floor(of: SecretAlwaysFile.name) == removed.sequence, "a floor never goes down")
        try folder.write(SecretAlwaysFile.name, data: withGrant)
        let relaunched = Self.store(folder, key: key, floor: vault.index.floor(of: SecretAlwaysFile.name))
        #expect(relaunched.read() == .failure(.tampered))
        // Without the floor (a vault from before it), the copy would read: the floor is what refuses it.
        #expect((try? Self.store(folder, key: key).read().get())?.grants == [grant])
    }

    @Test func theSignInsFileTakesTheVaultsFloorToo() throws {
        let folder = try Self.secrets()
        let key = SymmetricKey(size: .bits256)
        let signIns = SignInStore(folder: folder, key: key)
        try signIns.update(startsOver: true) { _ in (true, ()) }
        let old = try #require(try folder.read(SignInFile.name, cap: SignInFile.maxSize))
        try signIns.update { _ in (true, ()) }
        let now = try #require(try folder.read(SignInFile.name, cap: SignInFile.maxSize))
        let sequence = try #require(SignInFile.sequence(of: now, key: key))
        try folder.write(SignInFile.name, data: old)
        // A new launch's store, which keeps no memory of this one, with the vault's floor.
        let next = SignInStore(folder: folder, key: key, floor: sequence)
        #expect(next.read() == .failure(.tampered))
    }

    /// A key changed, renamed or deleted takes its grants with it; one made again replaces the same one.
    @Test func revocationAndReplacement() {
        let one = Self.grant(scope: Self.scope(.folder, "/a/app"))
        let again = Self.grant(scope: Self.scope(.folder, "/a/app"))
        let list = SecretAlwaysGrants.adding(again, to: [one])
        #expect(list.map(\.id) == [again.id])
        let other = SecretAlwaysGrant(agent: "Codex", identity: Self.codex, door: .wrapper, keys: ["OTHER": "OTHER"], marks: ["OTHER": "m"],
                                      definition: "d", summary: "s", scope: Self.scope(.folder, "/a/app"))
        let both = SecretAlwaysGrants.adding(other, to: list)
        #expect(SecretAlwaysGrants.holding("API_TOKEN", in: both).map(\.id) == [again.id])
    }
}
