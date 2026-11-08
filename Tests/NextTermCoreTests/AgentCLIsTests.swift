import Foundation
import Testing
@testable import NextTermCore

/// Settings › Agents' model (plan 038): every install method told from made-up copies on a temporary PATH, versions read
/// from their files, the latest version from each source's answer, the exact update command, and when a scheduled update
/// runs or waits. Nothing real is run or read: each test has a home of its own.
@Suite struct AgentCLIsTests {
    /// A made-up home, with links and files laid out as each installer leaves them.
    final class Home {
        let path: String
        init() throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-agentclis-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            path = canonicalPath(made.path)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        /// An executable file at `relative`, with `text` in it.
        @discardableResult
        func program(_ relative: String, _ text: String = "#!/bin/sh\necho 1.0.0\n") throws -> String {
            let full = path + "/" + relative
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
            return full
        }

        func file(_ relative: String, _ text: String) throws {
            let full = path + "/" + relative
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }

        /// A link at `relative` to `target` (relative to the link's folder, or absolute).
        func link(_ relative: String, to target: String) throws {
            let full = path + "/" + relative
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: target)
        }

        func folder(_ relative: String) -> String { path + "/" + relative }

        /// An npm global prefix at `prefix` with `package` at `version`, its bin linked as `program`, and its npm.
        func npmInstall(prefix: String, package: String, version: String, program: String, script: String = "cli.js") throws {
            try file("\(prefix)/lib/node_modules/\(package)/package.json", #"{"name": "\#(package)", "version": "\#(version)"}"#)
            try self.program("\(prefix)/lib/node_modules/\(package)/\(script)", "#!/usr/bin/env node\n")
            try link("\(prefix)/bin/\(program)", to: "../lib/node_modules/\(package)/\(script)")
            try self.program("\(prefix)/bin/npm")
        }
    }

    static func agent(_ id: String) -> AgentCLIs.Agent { AgentCLIs.agent(id)! }

    func only(_ id: String, _ home: Home, _ folders: [String]) -> [AgentCLIs.Copy] {
        AgentCLIs.copies(of: Self.agent(id), path: folders.map(home.folder), home: home.path)
    }

    // MARK: Install methods

    @Test func claudeNativeInstallIsItsOwnWithTheVersionFolder() throws {
        let home = try Home()
        try home.program(".local/share/claude/versions/2.1.280", "binary")
        try home.link(".local/bin/claude", to: home.folder(".local/share/claude/versions/2.1.280"))
        let copies = only("claude", home, [".local/bin"])
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(copy.method == .own && copy.version == "2.1.280")
        #expect(AgentCLIs.updateCommand(Self.agent("claude"), copy, home: home.path) == "~/.local/bin/claude update")
        #expect(Self.agent("claude").selfUpdate(.own) != .no && AgentCLIs.offersSchedule(Self.agent("claude"), copy))
        #expect(Self.agent("claude").latest(method: .own, package: nil, cask: false) == .claude("latest"))
    }

    @Test func npmInstallUsesItsOwnPrefixNpmAndPackageVersion() throws {
        let home = try Home()
        try home.npmInstall(prefix: "nvm/versions/node/v24.19.0", package: "@anthropic-ai/claude-code", version: "2.1.211", program: "claude")
        let copy = try #require(only("claude", home, ["nvm/versions/node/v24.19.0/bin"]).first)
        #expect(copy.method == .npm && copy.package == "@anthropic-ai/claude-code" && copy.version == "2.1.211")
        #expect(AgentCLIs.updateCommand(Self.agent("claude"), copy, home: home.path)
            == "~/nvm/versions/node/v24.19.0/bin/npm install -g @anthropic-ai/claude-code@latest")
        #expect(Self.agent("claude").latest(method: .npm, package: copy.package, cask: false) == .npm("@anthropic-ai/claude-code"))
    }

    @Test func theFirstCopyOnPathWinsAndTheOthersAreListed() throws {
        let home = try Home()
        try home.npmInstall(prefix: "node", package: "@anthropic-ai/claude-code", version: "2.1.211", program: "claude")
        try home.program(".local/share/claude/versions/2.1.280", "binary")
        try home.link(".local/bin/claude", to: home.folder(".local/share/claude/versions/2.1.280"))
        let copies = only("claude", home, ["node/bin", ".local/bin", "node/bin"])
        #expect(copies.map(\.method) == [.npm, .own])
        let status = AgentCLIs.Status(agent: Self.agent("claude"), copies: copies, latest: "2.1.319")
        #expect(status.copy?.version == "2.1.211" && status.updateAvailable)
        let row = (AgentCLIs.answer([status])["agents"] as? [[String: Any]])?.first
        #expect((row?["other_copies"] as? [[String: Any]])?.first?["version"] as? String == "2.1.280")
    }

    @Test func homebrewCaskAndFormula() throws {
        let home = try Home()
        try home.program("brew/Caskroom/claude-code/2.1.311/claude", "binary")
        try home.link("brew/bin/claude", to: "../Caskroom/claude-code/2.1.311/claude")
        try home.program("brew/bin/brew")
        try home.program("brew/Cellar/gemini-cli/0.67.0_1/bin/gemini")
        try home.link("brew/bin/gemini", to: "../Cellar/gemini-cli/0.67.0_1/bin/gemini")
        let cask = try #require(only("claude", home, ["brew/bin"]).first)
        #expect(cask.method == .homebrew && cask.cask && cask.package == "claude-code" && cask.version == "2.1.311")
        #expect(AgentCLIs.updateCommand(Self.agent("claude"), cask, home: home.path) == "~/brew/bin/brew upgrade --cask claude-code")
        #expect(Self.agent("claude").latest(method: .homebrew, package: "claude-code", cask: true) == .cask("claude-code"))
        // Claude Code from Homebrew doesn't update itself: a schedule here is the way.
        #expect(Self.agent("claude").selfUpdate(.homebrew) == .no)
        let formula = try #require(only("gemini", home, ["brew/bin"]).first)
        #expect(formula.method == .homebrew && !formula.cask && formula.package == "gemini-cli" && formula.version == "0.67.0")
        #expect(AgentCLIs.updateCommand(Self.agent("gemini"), formula, home: home.path) == "~/brew/bin/brew upgrade gemini-cli")
        #expect(Self.agent("gemini").selfUpdate(.homebrew) == .notifies)
    }

    @Test func aTapFormulaReadsItsLatestElsewhere() {
        #expect(Self.agent("crush").latest(method: .homebrew, package: "crush", cask: false) == .npm("@charmland/crush"))
    }

    @Test func codexStandaloneReadsTheReleaseFolderLessItsTarget() throws {
        let home = try Home()
        try home.program(".codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/codex", "binary")
        try home.link(".codex/packages/standalone/current", to: "releases/0.167.0-aarch64-apple-darwin")
        try home.link(".local/bin/codex", to: home.folder(".codex/packages/standalone/current/bin/codex"))
        let copy = try #require(only("codex", home, [".local/bin"]).first)
        #expect(copy.method == .own && copy.version == "0.167.0")
        #expect(AgentCLIs.updateCommand(Self.agent("codex"), copy, home: home.path) == "CODEX_NON_INTERACTIVE=1 ~/.local/bin/codex update")
        #expect(Self.agent("codex").selfUpdate(.own) == .notifies)
    }

    @Test func nodePackageManagersEachHaveTheirCommand() throws {
        let home = try Home()
        let package = "@google/gemini-cli"
        let cases: [(String, AgentCLIs.Method, String, Bool)] = [
            ("Library/pnpm/global/5/node_modules", .pnpm, "pnpm add -g @google/gemini-cli@latest", true),
            (".bun/install/global/node_modules", .bun, "bun add -g @google/gemini-cli@latest", true),
            (".config/yarn/global/node_modules", .yarn, "yarn global add @google/gemini-cli@latest", false),
            (".volta/tools/image/packages/@google/gemini-cli/lib/node_modules", .volta, "volta install @google/gemini-cli@latest", true),
        ]
        for (index, (modules, method, command, itself)) in cases.enumerated() {
            try home.file("\(modules)/\(package)/package.json", #"{"version": "0.66.\#(index)"}"#)
            try home.program("\(modules)/\(package)/dist/index.js")
            try home.link("bin\(index)/gemini", to: home.folder("\(modules)/\(package)/dist/index.js"))
            let copy = try #require(only("gemini", home, ["bin\(index)"]).first)
            #expect(copy.method == method, "\(modules)")
            #expect(copy.version == "0.66.\(index)" && copy.package == package)
            #expect(AgentCLIs.updateCommand(Self.agent("gemini"), copy, home: home.path) == command)
            // Gemini CLI updates itself from npm, pnpm, Bun and Volta; from Yarn it only says so.
            #expect((Self.agent("gemini").selfUpdate(method) != .notifies) == itself)
        }
    }

    @Test func npxIsTemporaryAndNeverUpdated() throws {
        let home = try Home()
        try home.program(".npm/_npx/4f2a/node_modules/@openai/codex/bin/codex.js")
        try home.link("bin/codex", to: home.folder(".npm/_npx/4f2a/node_modules/@openai/codex/bin/codex.js"))
        let copy = try #require(only("codex", home, ["bin"]).first)
        #expect(copy.method == .npx && AgentCLIs.updateCommand(Self.agent("codex"), copy) == nil)
        #expect(AgentCLIs.refusal(Self.agent("codex"), copy)?.contains("temporary") == true)
        #expect(!AgentCLIs.offersSchedule(Self.agent("codex"), copy))
    }

    @Test func pythonToolsReadTheirDistInfo() throws {
        let home = try Home()
        try home.program(".local/share/uv/tools/aider-chat/bin/aider")
        try home.file(".local/share/uv/tools/aider-chat/lib/python3.12/site-packages/aider_chat-0.86.2.dist-info/METADATA", "")
        try home.link(".local/bin/aider", to: home.folder(".local/share/uv/tools/aider-chat/bin/aider"))
        let uv = try #require(only("aider", home, [".local/bin"]).first)
        #expect(uv.method == .uv && uv.version == "0.86.2")
        #expect(AgentCLIs.updateCommand(Self.agent("aider"), uv) == "uv tool upgrade aider-chat")
        try home.program(".local/pipx/venvs/aider-chat/bin/aider")
        try home.file(".local/pipx/venvs/aider-chat/lib/python3.11/site-packages/aider_chat-0.85.0.dist-info/RECORD", "")
        try home.link("pipxbin/aider", to: home.folder(".local/pipx/venvs/aider-chat/bin/aider"))
        let pipx = try #require(only("aider", home, ["pipxbin"]).first)
        #expect(pipx.method == .pipx && pipx.version == "0.85.0")
        #expect(AgentCLIs.updateCommand(Self.agent("aider"), pipx) == "pipx upgrade aider-chat")
        #expect(Self.agent("aider").latest(method: .pipx, package: "aider-chat", cask: false) == .pypi("aider-chat"))
    }

    @Test func goInstall() throws {
        let home = try Home()
        try home.program("go/bin/crush", "binary")
        let copy = try #require(only("crush", home, ["go/bin"]).first)
        #expect(copy.method == .go)
        #expect(AgentCLIs.updateCommand(Self.agent("crush"), copy) == "go install github.com/charmbracelet/crush@latest")
    }

    @Test func cursorsSharedNameCountsOnlyInItsOwnInstall() throws {
        let home = try Home()
        try home.program(".local/share/cursor-agent/versions/2026.11.05-86047df/cursor-agent", "binary")
        try home.link(".local/bin/agent", to: home.folder(".local/share/cursor-agent/versions/2026.11.05-86047df/cursor-agent"))
        try home.program("other/agent") // someone else's "agent"
        #expect(only("cursor", home, ["other"]).isEmpty)
        let copy = try #require(only("cursor", home, ["other", ".local/bin"]).first)
        #expect(copy.method == .own && copy.version == "2026.11.05-86047df")
        #expect(AgentCLIs.updateCommand(Self.agent("cursor"), copy, home: home.path) == "~/.local/bin/agent update")
        // It updates itself with no lasting switch: no schedule is offered over it.
        #expect(!AgentCLIs.offersSchedule(Self.agent("cursor"), copy))
        // An older install's folder is a hash: no version from it.
        try home.program(".local/share/cursor-agent/versions/9f86d081884c7d65/cursor-agent", "binary")
        try home.link("old/cursor-agent", to: home.folder(".local/share/cursor-agent/versions/9f86d081884c7d65/cursor-agent"))
        #expect(only("cursor", home, ["old"]).first?.version == nil)
    }

    @Test func commandCodesCmdCountsOnlyFromItsPackage() throws {
        let home = try Home()
        try home.npmInstall(prefix: "node", package: "command-code", version: "1.88.2", program: "cmd", script: "dist/index.mjs")
        try home.program("sys/cmd")
        #expect(only("commandcode", home, ["sys"]).isEmpty)
        let copy = try #require(only("commandcode", home, ["node/bin"]).first)
        #expect(copy.method == .npm && copy.version == "1.88.2")
    }

    @Test func qwenStandaloneRunsItsInstallerAgainWithoutTouchingProfiles() throws {
        let home = try Home()
        try home.program(".local/lib/qwen-code/bin/qwen")
        try home.link(".local/bin/qwen", to: home.folder(".local/lib/qwen-code/bin/qwen"))
        let copy = try #require(only("qwen", home, [".local/bin"]).first)
        #expect(copy.method == .own)
        #expect(AgentCLIs.updateCommand(Self.agent("qwen"), copy)
            == "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | NO_MODIFY_PATH=1 bash")
    }

    @Test func aFolderNotTheUsersToWriteGetsANoteNeverSudo() throws {
        let home = try Home()
        try home.npmInstall(prefix: "root", package: "@openai/codex", version: "0.160.0", program: "codex", script: "bin/codex.js")
        let copies = AgentCLIs.copies(of: Self.agent("codex"), path: [home.folder("root/bin")], home: home.path, writable: { _ in false })
        let copy = try #require(copies.first)
        #expect(!copy.writable && AgentCLIs.updateCommand(Self.agent("codex"), copy) == nil)
        let note = try #require(AgentCLIs.refusal(Self.agent("codex"), copy))
        #expect(note.contains("never uses sudo") && note.contains(home.folder("root/lib/node_modules")))
    }

    @Test func aPlainFileElsewhereIsUnknown() throws {
        let home = try Home()
        try home.program("opt/tools/goose", "binary")
        let copy = try #require(only("goose", home, ["opt/tools"]).first)
        #expect(copy.method == .unknown && AgentCLIs.updateCommand(Self.agent("goose"), copy) == nil)
        try home.program(".local/bin/goose", "binary")
        let own = try #require(only("goose", home, [".local/bin"]).first)
        #expect(own.method == .own && AgentCLIs.updateCommand(Self.agent("goose"), own, home: home.path) == "CONFIGURE=false ~/.local/bin/goose update")
    }

    @Test func pathsThatNeedQuotingAreQuoted() {
        #expect(AgentCLIs.shellWord("/Users/a/Library/Application Support/Herd/bin/npm", home: "/Users/a")
            == "'/Users/a/Library/Application Support/Herd/bin/npm'")
        #expect(AgentCLIs.shellWord("/opt/homebrew/bin/brew", home: "/Users/a") == "/opt/homebrew/bin/brew")
    }

    // MARK: Versions

    @Test func latestAnswersParse() {
        let npm = Data(#"{"name": "@openai/codex", "version": "0.167.0"}"#.utf8)
        #expect(AgentCLIs.Latest.npm("@openai/codex").parse(npm) == "0.167.0")
        #expect(AgentCLIs.Latest.formula("gemini-cli").parse(Data(#"{"versions": {"stable": "0.67.0", "head": null}}"#.utf8)) == "0.67.0")
        #expect(AgentCLIs.Latest.cask("claude-code").parse(Data(#"{"version": "2.1.311,abc"}"#.utf8)) == "2.1.311")
        #expect(AgentCLIs.Latest.pypi("aider-chat").parse(Data(#"{"info": {"version": "0.86.2"}}"#.utf8)) == "0.86.2")
        #expect(AgentCLIs.Latest.github("openai/codex").parse(Data(#"{"tag_name": "rust-v0.167.0"}"#.utf8)) == "0.167.0")
        #expect(AgentCLIs.Latest.claude("latest").parse(Data("2.1.319\n".utf8)) == "2.1.319")
        #expect(AgentCLIs.Latest.npm("x").parse(Data("<html>".utf8)) == nil)
        #expect(AgentCLIs.Latest.npm("@openai/codex").url?.absoluteString == "https://registry.npmjs.org/@openai/codex/latest")
        #expect(AgentCLIs.Latest.claude("stable").url?.absoluteString == "https://downloads.claude.ai/claude-code-releases/stable")
    }

    @Test func versionsCompare() {
        #expect(AgentCLIs.isNewer("2.1.319", than: "2.1.280"))
        #expect(!AgentCLIs.isNewer("2.1.280", than: "2.1.280"))
        #expect(AgentCLIs.isNewer("0.100.0", than: "0.99.9"))
        #expect(AgentCLIs.isNewer("1.2.0", than: "1.2.0-beta.1"))
        #expect(!AgentCLIs.isNewer("1.2.0-beta.1", than: "1.2.0"))
        #expect(AgentCLIs.isNewer("2026.11.06-1a2b3c4", than: "2026.11.05-86047df"))
        #expect(AgentCLIs.version(in: "codex-cli 0.167.0") == "0.167.0")
    }

    @Test func theCacheKeepsAnAnswerADay() {
        var cache = AgentCLIs.LatestCache()
        let now = Date()
        cache.entries[AgentCLIs.Latest.npm("a").key] = .init(version: "1.0.0", checked: now.addingTimeInterval(-3600))
        #expect(cache.fresh(.npm("a"), now: now)?.version == "1.0.0")
        #expect(cache.fresh(.npm("a"), now: now.addingTimeInterval(24 * 3600)) == nil)
        #expect(cache.fresh(.npm("b"), now: now) == nil)
    }

    // MARK: Schedules

    @Test func schedulesAreDueByTheirInterval() {
        let now = Date()
        #expect(!AgentCLIs.isDue(.off, lastTry: nil, now: now))
        #expect(AgentCLIs.isDue(.daily, lastTry: nil, now: now))
        #expect(!AgentCLIs.isDue(.daily, lastTry: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(AgentCLIs.isDue(.daily, lastTry: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!AgentCLIs.isDue(.weekly, lastTry: now.addingTimeInterval(-6 * 24 * 3600), now: now))
        #expect(AgentCLIs.isDue(.weekly, lastTry: now.addingTimeInterval(-8 * 24 * 3600), now: now))
        // The clock set back past a whole interval: as if never tried.
        #expect(AgentCLIs.isDue(.daily, lastTry: now.addingTimeInterval(3 * 24 * 3600), now: now))
    }

    @Test func aDueUpdateWaitsForTheAgentAndSkipsWhatIsUpToDate() throws {
        let home = try Home()
        try home.program(".codex/packages/standalone/releases/0.166.0-aarch64-apple-darwin/bin/codex", "binary")
        try home.link(".local/bin/codex", to: home.folder(".codex/packages/standalone/releases/0.166.0-aarch64-apple-darwin/bin/codex"))
        let codex = Self.agent("codex")
        let copy = try #require(only("codex", home, [".local/bin"]).first)
        let now = Date()
        func decide(_ schedule: AgentCLIs.Schedule, running: Bool = false, latest: String? = "0.167.0", last: Date? = nil) -> AgentCLIs.Decision {
            AgentCLIs.decide(codex, copy: copy, schedule: schedule, lastTry: last, now: now, running: running, latest: latest)
        }
        #expect(decide(.off) == .skip(.off))
        #expect(decide(.daily, last: now.addingTimeInterval(-3600)) == .skip(.notDue))
        #expect(decide(.daily, running: true) == .skip(.running))
        #expect(!AgentCLIs.Skip.running.counts)
        #expect(decide(.daily, latest: "0.166.0") == .skip(.upToDate))
        #expect(decide(.daily, latest: nil) == .skip(.noLatest))
        guard case .update(let command) = decide(.weekly) else { return #expect(Bool(false)) }
        #expect(command.hasSuffix("codex update"))
        #expect(AgentCLIs.decide(codex, copy: nil, schedule: .daily, lastTry: nil, now: now, running: false, latest: "1") == .skip(.notInstalled))
    }

    @Test func aToolThatUpdatesItselfWithNoSwitchIsNeverScheduled() throws {
        let home = try Home()
        try home.program(".local/share/cursor-agent/versions/2026.11.05-86047df/cursor-agent", "binary")
        try home.link(".local/bin/cursor-agent", to: home.folder(".local/share/cursor-agent/versions/2026.11.05-86047df/cursor-agent"))
        let copy = try #require(only("cursor", home, [".local/bin"]).first)
        #expect(AgentCLIs.decide(Self.agent("cursor"), copy: copy, schedule: .daily, lastTry: nil, now: Date(), running: false,
                                 latest: "2027.01.01") == .skip(.updatesItself))
    }

    // MARK: Running

    @Test func anAgentRunsByNameOrFromItsInstall() throws {
        let home = try Home()
        try home.npmInstall(prefix: "node", package: "@google/gemini-cli", version: "0.66.0", program: "gemini", script: "dist/index.js")
        let gemini = Self.agent("gemini")
        let copies = only("gemini", home, ["node/bin"])
        let script = home.folder("node/lib/node_modules/@google/gemini-cli/dist/index.js")
        #expect(AgentCLIs.isRunning(gemini, copies: copies, processes: [("/usr/local/bin/node", ["node", script])]))
        // Run through its bin link, which resolves into the package.
        #expect(AgentCLIs.isRunning(gemini, copies: copies, processes: [("/usr/local/bin/node", ["node", home.folder("node/bin/gemini")])]))
        #expect(AgentCLIs.isRunning(gemini, copies: copies, processes: [("/x/y", ["gemini", "--yolo"])]))
        #expect(!AgentCLIs.isRunning(gemini, copies: copies, processes: [("/usr/local/bin/node", ["node", "/srv/app.js"]), ("/bin/zsh", ["-zsh"])]))
        // Cursor's shared "agent" is no evidence by name alone.
        #expect(!AgentCLIs.isRunning(Self.agent("cursor"), copies: [], processes: [("/usr/bin/agent", ["agent"])]))
    }

    // MARK: list_agent_clis

    @Test func theAnswerNamesEachInstalledAgent() throws {
        let home = try Home()
        try home.program("brew/Cellar/block-goose-cli/1.56.0/bin/goose", "binary")
        try home.link("brew/bin/goose", to: "../Cellar/block-goose-cli/1.56.0/bin/goose")
        let goose = AgentCLIs.Status(agent: Self.agent("goose"), copies: only("goose", home, ["brew/bin"]), latest: "1.57.0", schedule: .weekly)
        let missing = AgentCLIs.Status(agent: Self.agent("amp"), copies: [])
        let answer = AgentCLIs.answer([goose, missing])
        let rows = try #require(answer["agents"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["installed_by"] as? String == "Homebrew" && rows[0]["version"] as? String == "1.56.0")
        #expect(rows[0]["latest"] as? String == "1.57.0" && rows[0]["update_available"] as? Bool == true)
        #expect(rows[0]["auto_update"] as? String == "weekly" && rows[0]["updates_itself"] as? Bool == false)
        #expect(rows[0]["update_command"] as? String == "brew upgrade block-goose-cli")
        #expect((AgentCLIs.answer([goose, missing], all: true)["agents"] as? [[String: Any]])?.count == 2)
        #expect(JSONSerialization.isValidJSONObject(answer))
    }

    @Test func everyAgentIsWellFormed() {
        let ids = AgentCLIs.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        for agent in AgentCLIs.catalog {
            #expect(!agent.programs.isEmpty && agent.strictPrograms.isSubset(of: Set(agent.programs)), "\(agent.id)")
            // An installer is a single line to type, never one that asks for sudo.
            if let installer = agent.installer { #expect(!installer.contains("sudo") && !installer.contains("\n"), "\(agent.id)") }
            // Each one's own-installer copy updates somehow, or has no own installer.
            if !agent.ownMarkers.isEmpty { #expect(agent.ownUpdate != nil || agent.updatesByInstaller, "\(agent.id)") }
        }
    }
}
