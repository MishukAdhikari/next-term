import Foundation

/// Settings › Agents (plan 038): the coding agents' command-line tools as this Mac has them — every copy on PATH, how
/// each was installed, its version, the latest one, the exact command that updates it, and whether the tool updates
/// itself. One model for the Settings section, the scheduled updates and MCP's list_agent_clis.
///
/// Everything here is read from a copy's resolved path and the files beside it (a version folder's name, Homebrew's
/// Cellar or Caskroom, an npm package's `package.json`, a Python tool's `.dist-info`): no tool is run here, and no
/// network is asked. The app fetches the latest versions (`Latest.url`, parsed by `Latest.parse`) and runs `--version`
/// only for a copy whose files say nothing. Install and update facts: claudedocs 2026-11-08, each tool's own docs.
///
/// Next Term never fights a tool's own updater (`SelfUpdate`), never uses sudo (`Copy.writable`), and changes nothing
/// unless the user asked: every schedule is Off until they pick one.
public enum AgentCLIs {
    // MARK: How a copy was installed

    public enum Method: String, Codable, Sendable, CaseIterable {
        case npm, pnpm, yarn, bun, volta, homebrew, uv, pipx, go, own, npx, unknown

        /// As the Installed by column shows it.
        public var name: String {
            switch self {
            case .npm: return "npm"
            case .pnpm: return "pnpm"
            case .yarn: return "Yarn"
            case .bun: return "Bun"
            case .volta: return "Volta"
            case .homebrew: return "Homebrew"
            case .uv: return "uv"
            case .pipx: return "pipx"
            case .go: return "Go"
            case .own: return "Own installer"
            case .npx: return "npx (temporary)"
            case .unknown: return "Unknown"
            }
        }

        /// The Node package managers, whose installs carry a package name in their path.
        public var isNodePackageManager: Bool { [.npm, .pnpm, .yarn, .bun, .volta].contains(self) }
    }

    /// Whether a tool, installed one way, updates itself.
    public enum SelfUpdate: Equatable, Sendable {
        /// Never: an update is the user's (or a schedule's here).
        case no
        /// It checks and says so, and installs nothing by itself.
        case notifies
        /// It installs updates by itself. `off` is where the tool's own switch is, if it has a lasting one: with it
        /// turned off a schedule here makes sense; with none, Next Term offers no schedule.
        case yes(off: String?)
    }

    /// Where the latest version of a copy is read, cheaply, without the tool.
    public enum Latest: Equatable, Hashable, Sendable {
        case npm(String), formula(String), cask(String), pypi(String), github(String)
        /// Claude Code's own channel: "latest" or "stable".
        case claude(String)

        public var url: URL? {
            switch self {
            case .npm(let package): return URL(string: "https://registry.npmjs.org/\(package)/latest")
            case .formula(let token): return URL(string: "https://formulae.brew.sh/api/formula/\(token).json")
            case .cask(let token): return URL(string: "https://formulae.brew.sh/api/cask/\(token).json")
            case .pypi(let package): return URL(string: "https://pypi.org/pypi/\(package)/json")
            case .github(let repository): return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
            case .claude(let channel): return URL(string: "https://downloads.claude.ai/claude-code-releases/\(channel)")
            }
        }

        /// The cache's key.
        public var key: String {
            switch self {
            case .npm(let name): return "npm:\(name)"
            case .formula(let name): return "formula:\(name)"
            case .cask(let name): return "cask:\(name)"
            case .pypi(let name): return "pypi:\(name)"
            case .github(let name): return "github:\(name)"
            case .claude(let name): return "claude:\(name)"
            }
        }

        /// The version an answer from `url` names, or nil.
        public func parse(_ data: Data) -> String? {
            if case .claude = self {
                return AgentCLIs.version(in: String(decoding: data.prefix(200), as: UTF8.self))
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let found: String?
            switch self {
            case .npm: found = object["version"] as? String
            case .formula: found = (object["versions"] as? [String: Any])?["stable"] as? String
            case .cask: found = (object["version"] as? String)?.split(separator: ",").first.map(String.init)
            case .pypi: found = (object["info"] as? [String: Any])?["version"] as? String
            case .github: found = (object["tag_name"] as? String).flatMap(AgentCLIs.version(in:))
            case .claude: found = nil
            }
            return found.flatMap(AgentCLIs.version(in:))
        }
    }

    // MARK: The catalog

    public struct Agent: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// The names it is run by, first the usual one.
        public var programs: [String]
        /// Names other programs share ("agent", "cmd"): a copy by such a name counts only when it resolves into the
        /// tool's own install (`ownMarkers`, or its npm package).
        public var strictPrograms: Set<String> = []
        public var npm: String?
        /// Its Homebrew core formula, or its cask.
        public var formula: String?
        public var cask: String?
        public var pypi: String?
        /// owner/repo, for GitHub's latest release.
        public var github: String?
        /// A Go module, for `go install …@latest`.
        public var goModule: String?
        /// Pieces of a resolved path that mean its own installer put it there.
        public var ownMarkers: [String] = []
        /// The official one-line installer, as its docs give it (Install… types it in a tab, for the user to run).
        public var installer: String?
        /// What its own installer's copy is updated with, after the program: ["update"].
        public var ownUpdate: [String]?
        /// Variables an own-installer update runs with, so it never stops to ask or edits a shell profile.
        public var ownUpdateEnvironment: [String: String] = [:]
        /// Its own installer's copy is updated by running the installer again (with `ownUpdateEnvironment`).
        public var updatesByInstaller = false
        /// Where an own-installer copy's latest version is read.
        public var ownLatest: Latest?
        /// How it updates itself, by method; any other method: `.no`.
        public var selfUpdates: [Method: SelfUpdate] = [:]
        /// The arguments that print its version when its files say none; nil: never run it for that (Copilot's
        /// `version` checks the network).
        public var versionArguments: [String]? = ["--version"]

        public func selfUpdate(_ method: Method) -> SelfUpdate { selfUpdates[method] ?? .no }

        /// Where a copy of this tool installed by `method`, as `package`, reads its latest version.
        func latest(method: Method, package: String?, cask isCask: Bool) -> Latest? {
            switch method {
            case .homebrew:
                if isCask, let package, package == cask || package.hasPrefix((cask ?? "\u{0}") + "@") { return .cask(package) }
                if !isCask, let package, package == formula { return .formula(package) }
                return ownLatest ?? npm.map(Latest.npm) ?? github.map(Latest.github)
            case .npm, .pnpm, .yarn, .bun, .volta: return (package ?? npm).map(Latest.npm)
            case .uv, .pipx: return pypi.map(Latest.pypi)
            case .go: return github.map(Latest.github)
            case .own: return ownLatest ?? npm.map(Latest.npm) ?? github.map(Latest.github)
            case .npx, .unknown: return nil
            }
        }
    }

    /// The agents Settings › Agents knows, in the order it lists them.
    public static let catalog: [Agent] = {
        let nodeFamily: [Method] = [.npm, .pnpm, .yarn, .bun, .volta]
        func each(_ methods: [Method], _ value: SelfUpdate) -> [Method: SelfUpdate] {
            Dictionary(uniqueKeysWithValues: methods.map { ($0, value) })
        }
        return [
            Agent(id: "claude", name: "Claude Code", programs: ["claude"], npm: "@anthropic-ai/claude-code", cask: "claude-code",
                  ownMarkers: ["/claude/versions/"], installer: "curl -fsSL https://claude.ai/install.sh | bash",
                  ownUpdate: ["update"], ownLatest: .claude("latest"),
                  // Homebrew's copy updates only with CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE set (code.claude.com/docs/en/setup).
                  selfUpdates: each([.own, .npm], .yes(off: "DISABLE_AUTOUPDATER in the env of ~/.claude/settings.json"))),
            Agent(id: "codex", name: "Codex", programs: ["codex"], npm: "@openai/codex", cask: "codex", github: "openai/codex",
                  ownMarkers: ["/.codex/packages/standalone/"], installer: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                  ownUpdate: ["update"], ownUpdateEnvironment: ["CODEX_NON_INTERACTIVE": "1"], ownLatest: .npm("@openai/codex"),
                  // It checks at startup and asks (check_for_update_on_startup in ~/.codex/config.toml).
                  selfUpdates: each(Method.allCases, .notifies)),
            Agent(id: "gemini", name: "Gemini CLI", programs: ["gemini"], npm: "@google/gemini-cli", formula: "gemini-cli",
                  selfUpdates: each([.npm, .pnpm, .bun, .volta], .yes(off: "general.enableAutoUpdate in ~/.gemini/settings.json"))
                    .merging(each([.homebrew, .yarn], .notifies)) { $1 }),
            Agent(id: "qwen", name: "Qwen Code", programs: ["qwen"], npm: "@qwen-code/qwen-code", formula: "qwen-code",
                  ownMarkers: ["/.local/lib/qwen-code/"],
                  installer: "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash",
                  ownUpdateEnvironment: ["NO_MODIFY_PATH": "1"], updatesByInstaller: true, ownLatest: .npm("@qwen-code/qwen-code"),
                  selfUpdates: each(nodeFamily + [.own], .yes(off: "general.enableAutoUpdate in ~/.qwen/settings.json"))),
            Agent(id: "opencode", name: "OpenCode", programs: ["opencode", "opencode2"], npm: "@opencode/cli", formula: "opencode",
                  ownMarkers: ["/.opencode/bin/"], installer: "curl -fsSL https://opencode.ai/v2/install | bash",
                  ownUpdate: ["upgrade"], ownLatest: .npm("@opencode/cli"),
                  // Its update setting is "notify" unless the user set "auto" (opencode.ai/docs/config).
                  selfUpdates: each(Method.allCases, .notifies)),
            Agent(id: "cursor", name: "Cursor CLI", programs: ["cursor-agent", "agent"], strictPrograms: ["agent"],
                  ownMarkers: ["/cursor-agent/"], installer: "curl https://cursor.com/install -fsS | bash", ownUpdate: ["update"],
                  // Only a launch flag turns it off (--disable-auto-update): no lasting switch.
                  selfUpdates: each(Method.allCases, .yes(off: nil))),
            Agent(id: "copilot", name: "Copilot CLI", programs: ["copilot"], npm: "@github/copilot", cask: "copilot-cli",
                  github: "github/copilot-cli", ownMarkers: ["/.local/bin/copilot", "/.copilot/pkg/"],
                  installer: "curl -fsSL https://gh.io/copilot-install | bash", ownUpdate: ["update"], ownLatest: .npm("@github/copilot"),
                  // The settings key is reported ignored (github/copilot-cli#2615, #4534); the variable holds.
                  selfUpdates: each(Method.allCases, .yes(off: "COPILOT_AUTO_UPDATE=false in your shell")),
                  versionArguments: nil),
            Agent(id: "amp", name: "Amp", programs: ["amp"], npm: "@ampcode/cli", ownMarkers: ["/.amp/bin/"],
                  installer: "curl -fsSL https://ampcode.com/install.sh | bash", ownUpdate: ["update"], ownLatest: .npm("@ampcode/cli"),
                  selfUpdates: each([.own, .npm], .yes(off: "amp.updates.mode in Amp\u{2019}s settings")), versionArguments: ["version"]),
            Agent(id: "goose", name: "Goose", programs: ["goose"], formula: "block-goose-cli", github: "aaif-goose/goose",
                  ownMarkers: ["/.local/bin/goose"],
                  installer: "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash",
                  ownUpdate: ["update"], ownUpdateEnvironment: ["CONFIGURE": "false"], ownLatest: .github("aaif-goose/goose")),
            Agent(id: "aider", name: "Aider", programs: ["aider"], formula: "aider", pypi: "aider-chat",
                  installer: "curl -LsSf https://aider.chat/install.sh | sh",
                  // It checks on launch (--check-update) and installs nothing by itself.
                  selfUpdates: each(Method.allCases, .notifies)),
            Agent(id: "kiro", name: "Kiro CLI", programs: ["kiro-cli"], cask: "kiro-cli", ownMarkers: ["/.local/bin/kiro-cli"],
                  installer: "curl -fsSL https://cli.kiro.dev/install | bash", ownUpdate: ["update"], ownLatest: .cask("kiro-cli"),
                  selfUpdates: each(Method.allCases, .yes(off: "kiro-cli settings app.disableAutoupdates true"))),
            Agent(id: "commandcode", name: "Command Code", programs: ["cmd", "command-code", "commandcode", "cmdc"],
                  strictPrograms: ["cmd", "cmdc"], npm: "command-code"),
            Agent(id: "crush", name: "Crush", programs: ["crush"], npm: "@charmland/crush", github: "charmbracelet/crush",
                  goModule: "github.com/charmbracelet/crush"),
        ]
    }()

    public static func agent(_ id: String) -> Agent? { catalog.first { $0.id == id } }

    // MARK: Copies on PATH

    /// One copy of a tool on PATH.
    public struct Copy: Equatable, Sendable {
        /// The name in a PATH folder.
        public var path: String
        /// Every link resolved.
        public var resolved: String
        public var method: Method
        /// The npm package, Homebrew token or Python package it came as.
        public var package: String?
        /// A Homebrew cask, not a formula.
        public var cask = false
        /// The npm or Homebrew it came with (`<prefix>/bin/npm`): the one that updates it.
        public var manager: String?
        /// The version its path or files give.
        public var version: String?
        /// The folder an update writes is the user's to write: false means it needs an administrator, which Next Term
        /// never asks for.
        public var writable = true
        /// The folder an update writes, for that note.
        public var folder: String?
    }

    /// Every copy of `agent` along `path`, in PATH's order: the first is the one a shell runs. A name in a folder twice
    /// over (links to the same file) is one copy. `exists` says a file is executable there (FileManager's by default).
    public static func copies(of agent: Agent, path: [String], home: String = NSHomeDirectory(),
                              executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              writable: (String) -> Bool = { userCanWrite($0) }) -> [Copy] {
        var found: [Copy] = []
        var seen = Set<String>()
        for folder in path where !folder.isEmpty {
            for program in agent.programs {
                let candidate = (folder as NSString).appendingPathComponent(program)
                guard executable(candidate) else { continue }
                let resolved = canonicalPath(candidate)
                guard seen.insert(resolved).inserted else { continue }
                var copy = describe(path: candidate, resolved: resolved, agent: agent, home: home)
                if agent.strictPrograms.contains(program), copy.method == .unknown || !ownsPath(agent, resolved) { continue }
                if let folder = copy.folder { copy.writable = writable(folder) }
                found.append(copy)
            }
        }
        return found
    }

    /// The user (never root: an app run as root would update into any folder, as sudo would) can write `folder`.
    public static func userCanWrite(_ folder: String, euid: uid_t = geteuid(),
                                    writable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) -> Bool {
        euid != 0 && writable(folder)
    }

    /// A strict name's copy is the tool's only when its resolved path lies in the tool's own install.
    static func ownsPath(_ agent: Agent, _ resolved: String) -> Bool {
        if agent.ownMarkers.contains(where: resolved.contains) { return true }
        if let npm = agent.npm, resolved.contains("/node_modules/\(npm)/") { return true }
        return false
    }

    /// What a copy's resolved path says: its method, package, version, and the folder an update writes.
    public static func describe(path: String, resolved: String, agent: Agent, home: String = NSHomeDirectory()) -> Copy {
        var copy = Copy(path: path, resolved: resolved, method: .unknown)
        let parts = resolved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func after(_ word: String) -> (index: Int, name: String)? {
            guard let index = parts.lastIndex(of: word), index + 1 < parts.count else { return nil }
            return (index, parts[index + 1])
        }
        func prefix(upTo index: Int) -> String { "/" + parts[..<index].joined(separator: "/") }

        if let (index, token) = after("Cellar") ?? after("Caskroom") {
            copy.method = .homebrew
            copy.cask = parts[index] == "Caskroom"
            copy.package = token
            if index + 2 < parts.count { copy.version = version(in: parts[index + 2].split(separator: ",").first.map(String.init) ?? "") }
            // A formula from a tap other than core is upgraded, and its latest read, by its full name (sst/tap/opencode):
            // core's formula of the same name is another tool's version.
            if !copy.cask, index + 2 < parts.count, let tap = formulaTap(keg: prefix(upTo: index + 3)), tap != "homebrew/core" {
                copy.package = tap + "/" + token
            }
            let brewPrefix = prefix(upTo: index)
            copy.manager = brewPrefix + "/bin/brew"
            copy.folder = prefix(upTo: index + 1)
            return copy
        }
        if resolved.contains("/.npm/_npx/") {
            copy.method = .npx
            return copy
        }
        if let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count {
            let scoped = parts[modules + 1].hasPrefix("@") && modules + 2 < parts.count
            let package = scoped ? parts[modules + 1] + "/" + parts[modules + 2] : parts[modules + 1]
            let packageDir = prefix(upTo: modules + (scoped ? 3 : 2))
            copy.package = package
            copy.folder = prefix(upTo: modules + 1)
            copy.version = packageVersion(at: packageDir)
            if resolved.contains("/.pnpm/") || resolved.contains("/share/pnpm/") || resolved.contains("/Library/pnpm/") {
                copy.method = .pnpm
            } else if resolved.contains("/.yarn/") || resolved.contains("/yarn/global/") {
                copy.method = .yarn
            } else if resolved.contains("/.bun/install/global/") {
                copy.method = .bun
            } else if resolved.contains("/.volta/") {
                copy.method = .volta
            } else if modules >= 1, parts[modules - 1] == "lib" {
                copy.method = .npm
                let npmPrefix = prefix(upTo: modules - 1)
                copy.manager = npmPrefix + "/bin/npm"
            } else {
                // node_modules in a folder of its own (an old ~/.claude/local): no global npm updates it.
                copy.method = .unknown
            }
            return copy
        }
        // Volta's bin folder links every tool to one shim, which runs the package Volta installed for that name.
        if resolved.hasSuffix("/.volta/bin/volta-shim") {
            copy.method = .volta
            copy.package = agent.npm
            copy.folder = (resolved as NSString).deletingLastPathComponent
            return copy
        }
        // pnpm's own bin folder holds shims, not links: the package is the tool's own.
        if resolved.contains("/Library/pnpm/") || resolved.contains("/share/pnpm/") {
            copy.method = .pnpm
            copy.package = agent.npm
            copy.folder = (resolved as NSString).deletingLastPathComponent
            return copy
        }
        if let (index, tool) = after("tools"), index >= 1, parts[index - 1] == "uv" {
            copy.method = .uv
            copy.package = tool
            copy.folder = prefix(upTo: index + 2)
            copy.version = distributionVersion(in: copy.folder!, package: agent.pypi ?? tool)
            return copy
        }
        if let (index, venv) = after("venvs"), index >= 1, parts[index - 1] == "pipx" {
            copy.method = .pipx
            copy.package = venv
            copy.folder = prefix(upTo: index + 2)
            copy.version = distributionVersion(in: copy.folder!, package: agent.pypi ?? venv)
            return copy
        }
        if resolved.hasPrefix(home + "/go/bin/") || (agent.goModule != nil && resolved.contains("/go/bin/")) {
            copy.method = .go
            copy.package = agent.goModule
            copy.folder = (resolved as NSString).deletingLastPathComponent
            return copy
        }
        if agent.ownMarkers.contains(where: resolved.contains) {
            copy.method = .own
            copy.folder = (resolved as NSString).deletingLastPathComponent
            if let (_, name) = after("versions") { copy.version = version(in: name).flatMap { name.hasPrefix($0) ? $0 : nil } ?? cursorVersion(name) }
            if let (_, name) = after("releases") { copy.version = version(in: strippingTarget(name)) }
            return copy
        }
        copy.folder = (resolved as NSString).deletingLastPathComponent
        return copy
    }

    /// The tap a Homebrew keg's formula came from, as its INSTALL_RECEIPT.json says ("homebrew/core"), or nil.
    static func formulaTap(keg: String) -> String? {
        guard let data = FileManager.default.contents(atPath: keg + "/INSTALL_RECEIPT.json"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tap = (object["source"] as? [String: Any])?["tap"] as? String, isSafeWord(tap) else { return nil }
        return tap
    }

    /// Cursor's versions are dated, "2026.11.05-86047df"; an older install's folder is a hash, which says none.
    static func cursorVersion(_ name: String) -> String? {
        let pattern = #"^\d{4}\.\d{2}\.\d{2}(-[0-9a-f]+)?$"#
        return name.range(of: pattern, options: .regularExpression) != nil ? name : nil
    }

    /// Codex's release folder, "0.167.0-aarch64-apple-darwin", less its target.
    static func strippingTarget(_ name: String) -> String {
        guard let range = name.range(of: #"-(aarch64|x86_64|arm64|universal)(-.*)?$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }

    /// The version in an npm package's `package.json`.
    static func packageVersion(at folder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder + "/package.json"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object["version"] as? String).flatMap(version(in:))
    }

    /// The version in a Python environment's `<package>-<version>.dist-info` folder.
    static func distributionVersion(in environment: String, package: String) -> String? {
        let normalized = package.lowercased().replacingOccurrences(of: "-", with: "_")
        let manager = FileManager.default
        guard let pythons = try? manager.contentsOfDirectory(atPath: environment + "/lib") else { return nil }
        for python in pythons.sorted() {
            let site = environment + "/lib/" + python + "/site-packages"
            guard let names = try? manager.contentsOfDirectory(atPath: site) else { continue }
            for name in names where name.hasSuffix(".dist-info") && name.lowercased().hasPrefix(normalized + "-") {
                let middle = name.dropFirst(normalized.count + 1).dropLast(".dist-info".count)
                if let found = version(in: String(middle)) { return found }
            }
        }
        return nil
    }

    // MARK: Versions

    private static let versionPattern = try! NSRegularExpression(pattern: #"\d+\.\d+(?:\.\d+)*(?:-[0-9A-Za-z.]+)?"#)

    /// The first version number in `text`.
    public static func version(in text: String) -> String? {
        let ns = text as NSString
        guard let match = versionPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range)
    }

    /// Whether `candidate` is a later version than `installed`: number by number, and a release later than its own
    /// pre-release ("1.2.0" after "1.2.0-beta.1").
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func split(_ version: String) -> (numbers: [Int], pre: String?) {
            let main = version.split(separator: "-", maxSplits: 1)
            let numbers = main.first.map { $0.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } } ?? []
            return (numbers, main.count > 1 ? String(main[1]) : nil)
        }
        let a = split(candidate), b = split(installed)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        switch (a.pre, b.pre) {
        case (nil, .some): return true
        case (.some(let x), .some(let y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    // MARK: Updating

    /// The exact line that updates `copy`, as a shell runs it and a tab shows it; nil when nothing updates it from here
    /// (npx's temporary copies, an unknown install, one needing an administrator).
    public static func updateCommand(_ agent: Agent, _ copy: Copy, home: String = NSHomeDirectory()) -> String? {
        guard copy.writable else { return nil }
        // A package name read from a folder's name goes into a shell line: only a plain name does (no option, no
        // quoting, nothing a shell reads as more), else nothing updates it from here.
        guard [copy.package, agent.npm, agent.pypi, agent.goModule].allSatisfy({ $0.map(isSafeWord) ?? true }) else { return nil }
        let package = copy.package ?? agent.npm
        func tool(_ name: String) -> String {
            guard let manager = copy.manager, FileManager.default.isExecutableFile(atPath: manager) else { return name }
            return shellWord(manager, home: home)
        }
        switch copy.method {
        case .npm: return package.map { "\(tool("npm")) install -g \($0)@latest" } // never `npm update -g` (the setup docs)
        case .pnpm: return package.map { "pnpm add -g \($0)@latest" }
        case .yarn: return package.map { "yarn global add \($0)@latest" }
        case .bun: return package.map { "bun add -g \($0)@latest" }
        case .volta: return package.map { "volta install \($0)@latest" }
        case .homebrew:
            guard let token = copy.package else { return nil }
            return "\(tool("brew")) upgrade \(copy.cask ? "--cask " : "")\(token)"
        case .uv: return (copy.package ?? agent.pypi).map { "uv tool upgrade \($0)" }
        case .pipx: return (copy.package ?? agent.pypi).map { "pipx upgrade \($0)" }
        case .go: return agent.goModule.map { "go install \($0)@latest" }
        case .own:
            let environment = agent.ownUpdateEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            if agent.updatesByInstaller, let installer = agent.installer, let bar = installer.range(of: "| ", options: .backwards) {
                // The installer again, its shell given the variables: `curl … | NO_MODIFY_PATH=1 bash`.
                return installer[..<bar.upperBound] + (environment.isEmpty ? "" : environment + " ") + installer[bar.upperBound...]
            }
            guard let words = agent.ownUpdate else { return nil }
            let line = ([shellWord(copy.path, home: home)] + words).joined(separator: " ")
            return environment.isEmpty ? line : environment + " " + line
        case .npx, .unknown: return nil
        }
    }

    /// A package name, Homebrew token or tap a shell line can take as it is: letters, digits and `@/._+-`, never
    /// starting with `-` (an option) or `.`.
    public static func isSafeWord(_ word: String) -> Bool {
        guard let first = word.first, first != "-", first != "." else { return false }
        return word.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "@/._+-".contains($0) }
    }

    /// A path as a shell word: `~/…` for the home folder when nothing in it needs quoting, else single-quoted.
    static func shellWord(_ path: String, home: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@".contains($0) }
        if safe, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        if safe { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Why a copy gets no update from here, in a sentence; nil when it does.
    public static func refusal(_ agent: Agent, _ copy: Copy) -> String? {
        if !copy.writable {
            let folder = copy.folder.map { " (\($0))" } ?? ""
            return "Its folder\(folder) needs an administrator to change, and Next Term never uses sudo. Update it yourself in a tab."
        }
        switch copy.method {
        case .npx: return "npx runs a temporary copy, fetched again when it is out of date. There is nothing to update."
        case .unknown: return "Next Term can\u{2019}t tell how this copy was installed, so it doesn\u{2019}t update it."
        default: return updateCommand(agent, copy) == nil ? "Next Term has no update command for this copy." : nil
        }
    }

    // MARK: Running in the background

    /// The environment a scheduled update runs with: the app's (cleaned), the login shell's PATH with the copy's own npm
    /// or brew first, nothing asked (Homebrew's NONINTERACTIVE), and for pnpm its home (PNPM_HOME, set by the user's
    /// shell profile, which a Finder-launched app never read): without it `pnpm add -g` has no global folder.
    public static func backgroundEnvironment(_ base: [String: String], path: [String], copy: Copy) -> [String: String] {
        var environment = base
        var folders = path
        if let manager = copy.manager { folders.insert((manager as NSString).deletingLastPathComponent, at: 0) }
        environment["PATH"] = folders.joined(separator: ":")
        environment["NONINTERACTIVE"] = "1"
        if copy.method == .pnpm, environment["PNPM_HOME"] == nil, let home = pnpmHome(copy.resolved) {
            environment["PNPM_HOME"] = home
        }
        return environment
    }

    /// pnpm's home folder (`~/Library/pnpm`, `~/.local/share/pnpm`) from a path inside it.
    static func pnpmHome(_ resolved: String) -> String? {
        for marker in ["/Library/pnpm/", "/share/pnpm/"] {
            if let range = resolved.range(of: marker) { return String(resolved[..<range.upperBound].dropLast()) }
        }
        return nil
    }

    /// The most an update's log keeps: when it is over `limit` bytes, only its last `keep` stay (cut at a line).
    public static func trimLog(at url: URL, limit: Int = 512 * 1024, keep: Int = 128 * 1024) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(size - keep))
        guard var tail = try? handle.readToEnd() else { return }
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }

    /// Every process `pid` started, and theirs (a timed-out update's npm under its shell), deepest first.
    public static func descendants(of pid: Int32, in snapshot: [ProcessRecord]) -> [Int32] {
        var found: [Int32] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            let children = snapshot.filter { $0.parent == parent && $0.pid != parent && !found.contains($0.pid) }.map(\.pid)
            found.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return found.reversed()
    }

    // MARK: Schedules

    public enum Schedule: String, Codable, Sendable, CaseIterable {
        case off, daily, weekly

        public var title: String {
            switch self {
            case .off: return "Off"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .off: return nil
            case .daily: return 24 * 60 * 60
            case .weekly: return 7 * 24 * 60 * 60
            }
        }
    }

    /// Whether a scheduled update is due: never tried, or its interval past since the last try. A last try further
    /// ahead of the clock than one interval (it was set back) counts as none.
    public static func isDue(_ schedule: Schedule, lastTry: Date?, now: Date) -> Bool {
        guard let interval = schedule.interval else { return false }
        guard let lastTry else { return true }
        let age = now.timeIntervalSince(lastTry)
        return age >= interval || age < -interval
    }

    /// Whether Settings offers a schedule for `copy`: it has an update command, and either the tool doesn't update
    /// itself or it has a lasting switch for that (turned off, a schedule here takes over).
    public static func offersSchedule(_ agent: Agent, _ copy: Copy) -> Bool {
        guard updateCommand(agent, copy) != nil else { return false }
        if case .yes(off: nil) = agent.selfUpdate(copy.method) { return false }
        return true
    }

    public enum Decision: Equatable, Sendable {
        case update(command: String)
        /// Nothing now (`Skip.counts` says whether the look counts as the interval's).
        case skip(Skip)
    }

    public enum Skip: String, Equatable, Sendable {
        case off, notDue, notInstalled, updatesItself, noCommand, running, upToDate, noLatest

        /// Whether the look counts as the interval's try, so the next comes a whole interval later. A busy agent or no
        /// answer about the latest version (offline) is looked at again within the hour.
        public var counts: Bool { ![.off, .notDue, .running, .noLatest].contains(self) }
    }

    /// What a scheduled look does for one agent. `running`: a tab runs it, or any process of it is running (an
    /// in-place update would pull the files from under it). `latest`: the latest version, nil when no source answered.
    public static func decide(_ agent: Agent, copy: Copy?, schedule: Schedule, lastTry: Date?, now: Date,
                              running: Bool, latest: String?) -> Decision {
        guard schedule != .off else { return .skip(.off) }
        guard isDue(schedule, lastTry: lastTry, now: now) else { return .skip(.notDue) }
        guard let copy else { return .skip(.notInstalled) }
        guard offersSchedule(agent, copy), let command = updateCommand(agent, copy) else {
            if case .yes(off: nil) = agent.selfUpdate(copy.method) { return .skip(.updatesItself) }
            return .skip(.noCommand)
        }
        if running { return .skip(.running) }
        guard let latest else { return .skip(.noLatest) }
        if let installed = copy.version, !isNewer(latest, than: installed) { return .skip(.upToDate) }
        return .update(command: command)
    }

    // MARK: Running

    /// The folder an install's files are in, for telling its processes: an npm package's own folder, a Homebrew
    /// token's, a version folder's parent, else the copy's own folder.
    public static func installRoot(_ copy: Copy) -> String {
        let parts = copy.resolved.split(separator: "/").map(String.init)
        func through(_ index: Int) -> String { "/" + parts[...index].joined(separator: "/") }
        if let index = parts.lastIndex(where: { $0 == "Cellar" || $0 == "Caskroom" }), index + 1 < parts.count { return through(index + 1) }
        if let index = parts.lastIndex(of: "node_modules"), index + 1 < parts.count {
            let scoped = parts[index + 1].hasPrefix("@") && index + 2 < parts.count
            return through(index + (scoped ? 2 : 1))
        }
        if let index = parts.lastIndex(where: { $0 == "versions" || $0 == "releases" }), index >= 1 { return through(index - 1) }
        return (copy.resolved as NSString).deletingLastPathComponent
    }

    /// Whether one of `processes` (each its executable and argv) runs `agent`: by its executable's or argv[0]'s name
    /// (not a shared name such as "agent"), or by its executable or a script it runs lying in one of the copies' installs.
    public static func isRunning(_ agent: Agent, copies: [Copy], processes: [(executable: String, arguments: [String])]) -> Bool {
        let names = Set(agent.programs).subtracting(agent.strictPrograms)
        let roots = copies.map { installRoot($0) + "/" }
        return processes.contains { process in
            let words = [process.executable] + process.arguments.prefix(3)
            if words.prefix(2).contains(where: { names.contains(($0 as NSString).lastPathComponent) }) { return true }
            return words.contains { word in word.hasPrefix("/") && roots.contains { word.hasPrefix($0) || canonicalPath(word).hasPrefix($0) } }
        }
    }

    // MARK: What the app keeps

    /// The latest versions asked, by source: kept a day.
    public struct LatestCache: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var version: String?
            public var checked: Date

            public init(version: String?, checked: Date) {
                self.version = version
                self.checked = checked
            }
        }

        public var entries: [String: Entry] = [:]

        public init() {}

        public static let lifetime: TimeInterval = 24 * 60 * 60

        /// Keeps what asking `source` gave: a version, or the server's answer that it names none (kept a day too, so a
        /// source that is gone isn't asked every hour). No answer at all (offline) keeps what was known, to ask again.
        public mutating func record(_ version: String?, answered: Bool, for source: Latest, now: Date) {
            guard answered else { return }
            entries[source.key] = Entry(version: version, checked: now)
        }

        /// A fresh answer for `source`, if there is one (the version may be nil: it was asked and said none).
        public func fresh(_ source: Latest, now: Date) -> Entry? {
            guard let entry = entries[source.key] else { return nil }
            let age = now.timeIntervalSince(entry.checked)
            return age < Self.lifetime && age > -Self.lifetime ? entry : nil
        }
    }

    /// One agent as Settings and list_agent_clis show it.
    public struct Status: Equatable, Sendable {
        public var agent: Agent
        /// Every copy on PATH, the one a shell runs first.
        public var copies: [Copy]
        public var latest: String?
        public var schedule: Schedule
        public var lastTry: Date?

        public init(agent: Agent, copies: [Copy], latest: String? = nil, schedule: Schedule = .off, lastTry: Date? = nil) {
            self.agent = agent
            self.copies = copies
            self.latest = latest
            self.schedule = schedule
            self.lastTry = lastTry
        }

        public var copy: Copy? { copies.first }
        public var installed: Bool { copy != nil }
        public var updateAvailable: Bool {
            guard let latest, let version = copy?.version else { return false }
            return isNewer(latest, than: version)
        }

        public var latestSource: Latest? { copy.flatMap { agent.latest(method: $0.method, package: $0.package, cask: $0.cask) } }
    }

    /// list_agent_clis' answer: each installed agent (and, with `all`, the others as not installed).
    public static func answer(_ statuses: [Status], all: Bool = false) -> [String: Any] {
        let rows: [[String: Any]] = statuses.filter { all || $0.installed }.map { status in
            var row: [String: Any] = ["id": status.agent.id, "name": status.agent.name, "installed": status.installed]
            guard let copy = status.copy else { return row }
            row["path"] = copy.path
            row["installed_by"] = copy.method.name
            if let version = copy.version { row["version"] = version }
            if let latest = status.latest { row["latest"] = latest; row["update_available"] = status.updateAvailable }
            switch status.agent.selfUpdate(copy.method) {
            case .no: row["updates_itself"] = false
            case .notifies: row["updates_itself"] = "notifies"
            case .yes(let off):
                row["updates_itself"] = true
                if let off { row["its_own_switch"] = off }
            }
            row["auto_update"] = offersSchedule(status.agent, copy) ? status.schedule.rawValue : "not offered"
            if let command = updateCommand(status.agent, copy) { row["update_command"] = command }
            if let refusal = refusal(status.agent, copy) { row["note"] = refusal }
            if status.copies.count > 1 {
                row["other_copies"] = status.copies.dropFirst().map { other -> [String: Any] in
                    var described: [String: Any] = ["path": other.path, "installed_by": other.method.name]
                    if let version = other.version { described["version"] = version }
                    return described
                }
            }
            return row
        }
        return ["agents": rows, "change": "Schedules and updates are the user\u{2019}s, in Settings \u{203A} Agents (show_settings with tab agents)."]
    }
}
