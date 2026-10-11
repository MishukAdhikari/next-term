import Foundation

/// How the service catalog uses a key in an env file: by its name alone, or by its value as one kind of thing. Only a
/// key with a role other than `presence`, whose name does not mark a secret, ever has its value read.
public enum KeyRole: String, Sendable, Hashable, CaseIterable {
    case presence, url, host, port, name, id, region
}

/// One value read from an env file for a key the catalog asked about, kept only in the form its role allows: a URL or
/// host as its scheme, host and port; a port as a number; a name, id or region as plain text. It prints the key's name
/// and role only, never the value.
public struct ServiceFact: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Value: Sendable, Equatable {
        /// A server's scheme, host and port. Its path, query, fragment, user and password were never kept.
        case origin(SafeWebLink.Origin)
        /// A URL that names no web server (`db://…`, `file:…`): its scheme alone, lower-cased.
        case scheme(String)
        case port(Int)
        /// Up to 100 of ASCII letters, digits, `.`, `_`, `-`, `:` and spaces.
        case text(String)
    }

    /// The env file, relative to the project.
    public let file: String
    public let key: String
    public let role: KeyRole
    public let value: Value

    public init(file: String, key: String, role: KeyRole, value: Value) {
        self.file = file
        self.key = key
        self.role = role
        self.value = value
    }

    public var origin: SafeWebLink.Origin? {
        if case .origin(let origin) = value { return origin }
        return nil
    }

    public var port: Int? {
        if case .port(let port) = value { return port }
        return nil
    }

    public var text: String? {
        if case .text(let text) = value { return text }
        return nil
    }

    public var description: String { "ServiceFact(\(key), \(role.rawValue), \(file))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The key names of one env file, in file order, each once. Names only: no value.
public struct EnvNames: Sendable, Equatable {
    public let file: String
    public let names: [String]

    public init(file: String, names: [String]) {
        self.file = file
        self.names = names
    }
}

/// Where a dependency's name comes from.
public enum Ecosystem: String, Sendable, Hashable, CaseIterable {
    /// Python: `pyproject.toml`, `requirements*.txt`, `Pipfile`. Names are normalised as PyPI compares them.
    case pypi
    /// JavaScript: `package.json`, names as written.
    case npm
    /// Ruby: `Gemfile`.
    case rubygems
    /// Elixir: `mix.exs`.
    case hex
}

/// The dependency names one manifest lists, in file order, each once. Versions, URLs and paths are never kept.
public struct ManifestNames: Sendable, Equatable {
    public let file: String
    public let ecosystem: Ecosystem
    public let names: [String]
}

/// A script that runs a tool the catalog knows (`next dev`, `langgraph dev`), and the port it names. The script's own
/// line is dropped as soon as it is read: it may hold a secret inline.
public struct StartCommand: Sendable, Equatable {
    /// `package.json`, `pyproject.toml`, `Procfile`, `Procfile.dev`, `Makefile` or `justfile`.
    public let file: String
    /// The script's, task's, process's, target's or recipe's name.
    public let script: String
    /// The catalog's start words it matched, as the catalog wrote them.
    public let word: String
    /// From `--port N`, `--port=N`, `-p N`, `runserver [addr:]N`, `--server.port N`, or a leading `PORT=N` or
    /// `GRADIO_SERVER_PORT=N`.
    public let port: Int?
    /// From `--ui-port N` (Temporal's dev server).
    public let uiPort: Int?

    public init(file: String, script: String, word: String, port: Int?, uiPort: Int? = nil) {
        self.file = file
        self.script = script
        self.word = word
        self.port = port
        self.uiPort = uiPort
    }
}

/// A fact a tool's own config file names: an id, a name or a port, never a secret.
public enum NamedFact: String, Sendable, Hashable, CaseIterable {
    case neonProjectID = "neon.projectId"
    case pscaleOrg = "pscale.org", pscaleDatabase = "pscale.database"
    case supabaseRef = "supabase.ref"
    case supabaseDBPort = "supabase.db.port", supabaseStudioPort = "supabase.studio.port"
    case supabaseInbucketPort = "supabase.inbucket.port"
    case flyApp = "fly.app"
    case wranglerAccountID = "wrangler.accountId"
    /// A D1 database's id; its `label` is the database's name.
    case d1Database = "wrangler.d1"
    case r2Bucket = "wrangler.r2"
    case firebaseProject = "firebase.project"
    /// "true" when `firebase.json` configures the emulators.
    case firebaseEmulators = "firebase.emulators"
    case firebaseEmulatorUIPort = "firebase.emulators.ui.port"
    case herdName = "herd.name"
    /// "true" or "false".
    case herdSecured = "herd.secured"
    case ddevName = "ddev.name", ddevTLD = "ddev.projectTLD", ddevHTTPSPort = "ddev.routerHTTPSPort"
    case ddevMailpitHTTPSPort = "ddev.mailpitHTTPSPort"
    case streamlitPort = "streamlit.port"
    case inngestPort = "inngest.port"
    case triggerProjectRef = "trigger.projectRef"
    case mastraPort = "mastra.port"
    case vitePort = "vite.port"
    /// "true" when Vite's `server.https` is set.
    case viteHTTPS = "vite.https"
    case astroPort = "astro.port"
    case nuxtPort = "nuxt.port"
    case replicateOwner = "replicate.owner", replicateModel = "replicate.model"
    case vercelProjectID = "vercel.projectId", vercelProjectName = "vercel.projectName", vercelOrgID = "vercel.orgId"
}

/// One named fact, with the file that named it.
public struct NamedValue: Sendable, Equatable {
    public let fact: NamedFact
    public let value: String
    /// Relative to the project.
    public let file: String
    /// What else names it, where the file says: a D1 database's name.
    public let label: String?

    public init(fact: NamedFact, value: String, file: String, label: String? = nil) {
        self.fact = fact
        self.value = value
        self.file = file
        self.label = label
    }
}

/// What a project's own files say about the services it uses, read once per scan and never by running anything:
/// env key names, the values the catalog allows, dependency names, Compose services, start commands, marker files and
/// the ids and ports tool configs name. It reads only regular files of at most 512 KB inside the project, follows a
/// symbolic link only when it stays inside, and skips a file iCloud has not downloaded. It prints names and counts
/// only, so a log or a printed scan never shows a value.
public struct ProjectFacts: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Each env file's key names, in the order Next.js prefers the files; `.env.example`'s only when no other exists.
    public var envNames: [EnvNames] = []
    /// The values of keys the caller asked for whose names do not mark a secret, most preferred file first.
    public var envValues: [ServiceFact] = []
    public var dependencies: [ManifestNames] = []
    public var compose: ComposeFile?
    public var startCommands: [StartCommand] = []
    /// The marker files asked for that exist, as the caller wrote them (`mlruns/` for a folder, `*.ipynb` for any
    /// file of that kind at the project's top).
    public var files: Set<String> = []
    public var named: [NamedValue] = []
    /// The tables under `[tool]` in `pyproject.toml`: `poetry`, `crewai`, `fastapi`.
    public var pyprojectTools: Set<String> = []
    /// Every file the readers opened, relative to the project, in order: each once.
    public var read: [String] = []

    public init() {}

    public func hasEnvName(_ name: String) -> Bool {
        envNames.contains { (file: EnvNames) -> Bool in file.names.contains(name) }
    }

    /// The env files that name a key, most preferred first.
    public func envFiles(naming name: String) -> [String] {
        envNames.filter { (file: EnvNames) -> Bool in file.names.contains(name) }.map(\.file)
    }

    /// The value of a key from the most preferred env file that holds one.
    public func value(_ key: String) -> ServiceFact? {
        envValues.first { (fact: ServiceFact) -> Bool in fact.key == key }
    }

    public func values(_ key: String) -> [ServiceFact] {
        envValues.filter { (fact: ServiceFact) -> Bool in fact.key == key }
    }

    /// The manifest that lists a dependency, or nil. A PyPI name is compared normalised.
    public func dependencyFile(_ name: String, in ecosystem: Ecosystem) -> String? {
        let wanted = ecosystem == .pypi ? Self.normalisedPyPI(name) : name
        return dependencies.first { (manifest: ManifestNames) -> Bool in
            manifest.ecosystem == ecosystem && manifest.names.contains(wanted)
        }?.file
    }

    public func named(_ fact: NamedFact) -> String? {
        named.first { (value: NamedValue) -> Bool in value.fact == fact }?.value
    }

    public func namedFile(_ fact: NamedFact) -> String? {
        named.first { (value: NamedValue) -> Bool in value.fact == fact }?.file
    }

    public func all(_ fact: NamedFact) -> [NamedValue] {
        named.filter { (value: NamedValue) -> Bool in value.fact == fact }
    }

    /// A named fact that is a port.
    public func port(_ fact: NamedFact) -> Int? {
        named(fact).flatMap { (text: String) -> Int? in ComposeFile.portNumber(Substring(text)) }
    }

    public var description: String {
        let keys = envValues.map { (fact: ServiceFact) -> String in fact.key + " " + fact.role.rawValue }
        let facts = named.map { (value: NamedValue) -> String in value.fact.rawValue }
        let names = envNames.reduce(0) { (count: Int, file: EnvNames) -> Int in count + file.names.count }
        let deps = dependencies.reduce(0) { (count: Int, file: ManifestNames) -> Int in count + file.names.count }
        let parts: [String] = ["env files: \(envNames.count)", "env names: \(names)",
                               "values: [\(keys.joined(separator: ", "))]",
                               "dependencies: \(deps)", "compose services: \(compose?.services.count ?? 0)",
                               "start commands: \(startCommands.count)", "files: \(files.count)",
                               "named: [\(facts.joined(separator: ", "))]", "read: \(read.count)"]
        return "ProjectFacts(" + parts.joined(separator: ", ") + ")"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Reading

extension ProjectFacts {
    /// The env files read for names and values: `Databases.envFiles`, then Flask's and Phoenix's own.
    public static let envFiles = Databases.envFiles + [".flaskenv", ".env.phoenix"]

    /// What the project's files say. `valueKeys` names the keys whose values may be read, each with its role; a key
    /// whose name marks a secret is never read, whatever its role. `startWords` are the commands that run a tool
    /// (`next dev`), and `markerFiles` the files whose presence counts (`langgraph.json`, `mlruns/`, `*.ipynb`).
    public static func read(root: String, valueKeys: [String: KeyRole], startWords: [String] = [],
                            markerFiles: [String] = []) -> ProjectFacts {
        var reader = FactReader(root: canonicalPath(root))
        var facts = ProjectFacts()
        let rootEnv = facts.readEnv(&reader, valueKeys: valueKeys)
        facts.readCompose(&reader, rootEnv: rootEnv)
        facts.readManifests(&reader, startWords: startWords)
        facts.readScripts(&reader, startWords: startWords)
        facts.readConfigs(&reader)
        for marker in markerFiles where reader.hasMarker(marker) { facts.files.insert(marker) }
        facts.read = reader.opened
        return facts
    }

    /// Names from every env file, and the values `valueKeys` allows; `.env.example`'s names when no other exists.
    /// Values are read as written, never interpolated. Returns the root `.env`'s entries, for Compose's variables.
    mutating func readEnv(_ reader: inout FactReader, valueKeys: [String: KeyRole]) -> [EnvEntry] {
        var rootEnv: [EnvEntry] = []
        for file in Self.envFiles {
            guard let text = reader.text(file) else { continue }
            let entries = EnvFile.parse(text, interpolating: false)
            envNames.append(EnvNames(file: file, names: Self.uniqueKeys(entries)))
            envValues += Self.facts(entries, file: file, valueKeys: valueKeys)
            if file == ".env" { rootEnv = entries }
        }
        if envNames.isEmpty, let example = Databases.exampleFiles.first, let text = reader.text(example) {
            envNames.append(EnvNames(file: example, names: Self.uniqueKeys(EnvFile.parse(text, interpolating: false))))
        }
        return rootEnv
    }

    static func uniqueKeys(_ entries: [EnvEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.key).filter { (key: String) -> Bool in seen.insert(key).inserted }
    }

    /// Whether a key's value may be read: the caller asked for it with a role, and its name marks no secret.
    static func mayRead(_ key: String, valueKeys: [String: KeyRole]) -> Bool {
        guard let role = valueKeys[key], role != .presence else { return false }
        return !SecretName.isSecret(key)
    }

    /// The allowed keys' facts from one file: the last value of each key, as dotenv keeps it.
    static func facts(_ entries: [EnvEntry], file: String, valueKeys: [String: KeyRole]) -> [ServiceFact] {
        var last: [String: String] = [:]
        var order: [String] = []
        for entry in entries where mayRead(entry.key, valueKeys: valueKeys) {
            if last[entry.key] == nil { order.append(entry.key) }
            last[entry.key] = entry.value
        }
        return order.compactMap { (key: String) -> ServiceFact? in
            guard let role = valueKeys[key], let written = last[key],
                  let value = factValue(written, role: role) else { return nil }
            return ServiceFact(file: file, key: key, role: role, value: value)
        }
    }

    /// Compose's file, the first of its names that exists; a port's variable from the root `.env` when Compose may
    /// read it there and it is a port.
    mutating func readCompose(_ reader: inout FactReader, rootEnv: [EnvEntry]) {
        guard let file = ComposeFile.fileNames.first(where: { (name: String) -> Bool in reader.isFile(name) }),
              let text = reader.text(file) else { return }
        var variables: [String: Int] = [:]
        for entry in rootEnv where ComposeFile.mayReadVariable(entry.key) {
            let written = entry.value.trimmingCharacters(in: .whitespaces)
            if let port = ComposeFile.portNumber(Substring(written)) { variables[entry.key] = port }
        }
        compose = ComposeFile(file: file, services: ComposeFile.parse(text, portVariables: variables))
    }
}

// MARK: - Values by role

extension ProjectFacts {
    /// A value in the form its role allows, or nil. A value that names another value (`${HOST}`, `$(cmd)`, a
    /// backtick) is refused whole.
    static func factValue(_ written: String, role: KeyRole) -> ServiceFact.Value? {
        let text = written.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, SafeWebLink.isLiteral(text) else { return nil }
        switch role {
        case .presence: return nil
        case .url: return urlValue(text)
        case .host: return hostValue(text)
        case .port: return ComposeFile.portNumber(Substring(text)).map { (port: Int) -> ServiceFact.Value in .port(port) }
        case .name, .id, .region: return plainText(text).map { (text: String) -> ServiceFact.Value in .text(text) }
        }
    }

    /// A URL as its server's origin. One that names no web server keeps its scheme alone (`db://shop` gives `db`, and
    /// `file:` a store, not a server); an `http` or `https` value with a user or password is dropped whole.
    static func urlValue(_ text: String) -> ServiceFact.Value? {
        if let origin = SafeWebLink.address(of: text) { return .origin(origin) }
        guard let scheme = SafeWebLink.schemeWritten(in: text) else { return nil }
        let lowered = scheme.lowercased()
        guard !SafeWebLink.schemes.contains(lowered), lowered.count <= 32 else { return nil }
        return .scheme(lowered)
    }

    /// A host, as a URL's origin, or a single name with an optional port (`chroma`, `chroma:8000`), such as a
    /// Compose service's. A single name is kept on plain `http`, which opens only on this Mac.
    static func hostValue(_ text: String) -> ServiceFact.Value? {
        if let origin = SafeWebLink.address(of: text) { return .origin(origin) }
        let plain: Bool = SafeWebLink.isPrintable(text) && !text.contains("/") && !text.contains("@")
        guard plain, SafeWebLink.schemeWritten(in: text) == nil,
              let parts = URLComponents(string: "http://" + text), let host = parts.percentEncodedHost,
              parts.percentEncodedPath.isEmpty, parts.percentEncodedQuery == nil, parts.percentEncodedFragment == nil,
              let origin = SafeWebLink.Origin(scheme: "http", host: host, port: parts.port) else { return nil }
        return .origin(origin)
    }

    /// A name, id or region: 1 to 100 of ASCII letters, digits, `.`, `_`, `-`, `:` and spaces, with no space at either
    /// end. Anything else (a path, a URL, a quote) is not one.
    static func plainText(_ text: String) -> String? {
        let allowed = text.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in plainCharacters.contains(scalar) }
        let trimmed: Bool = text.first != " " && text.last != " "
        guard allowed, trimmed, (1...100).contains(text.count) else { return nil }
        return text
    }

    private static let plainCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-: ")
}

// MARK: - Files

/// The one way the fact readers open a file: a path inside the project, resolved, that stays inside it; a regular
/// file of at most 512 KB; and not one iCloud has evicted, which reading would download. Each file read is recorded.
struct FactReader {
    let root: String
    var opened: [String] = []
    private var topNames: [String]?

    static let maxSize = 512 * 1024
    /// `SF_DATALESS` in `st_flags`: the file's content is in iCloud, not on this Mac.
    static let dataless: UInt32 = 0x4000_0000

    init(root: String) {
        self.root = root
    }

    /// The real path of a project file, if it exists and stays inside the project.
    func inside(_ relative: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        let plain = parts.allSatisfy { (part: Substring) -> Bool in !part.isEmpty && part != "." && part != ".." }
        guard plain, !relative.hasPrefix("/"), let resolved = realpath(root + "/" + relative, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return path.hasPrefix(root + "/") ? path : nil
    }

    func isFile(_ relative: String) -> Bool {
        guard let path = inside(relative) else { return false }
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    func isFolder(_ relative: String) -> Bool {
        guard let path = inside(relative) else { return false }
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// The names in a project folder (`""` for the project's own), sorted; empty if it is not one inside.
    func names(in relative: String) -> [String] {
        let folder = relative.isEmpty ? root : inside(relative)
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.sorted()
    }

    /// The project's top folder, listed once.
    mutating func topLevelNames() -> [String] {
        if let topNames { return topNames }
        let names = names(in: "")
        topNames = names
        return names
    }

    /// `name` for a file, `name/` for a folder, `*.ext` for any file of that kind at the project's top.
    mutating func hasMarker(_ marker: String) -> Bool {
        if marker.hasPrefix("*.") {
            let suffix = String(marker.dropFirst())
            return topLevelNames().contains { (name: String) -> Bool in name.hasSuffix(suffix) && isFile(name) }
        }
        if marker.hasSuffix("/") { return isFolder(String(marker.dropLast())) }
        return isFile(marker)
    }

    mutating func text(_ relative: String) -> String? {
        guard let path = inside(relative) else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= Self.maxSize,
              info.st_flags & Self.dataless == 0,
              let data = FileManager.default.contents(atPath: path), data.count <= Self.maxSize else { return nil }
        opened.append(relative)
        return String(decoding: data, as: UTF8.self)
    }
}
