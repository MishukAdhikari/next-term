import Foundation

/// What a service is for, in the order the Services section lists kinds.
public enum ServiceKind: Int, Sendable, Hashable, CaseIterable, Comparable {
    case aiModel, vectorStore, tracing, agent, localServer, backend, hosting

    /// The row's dimmed detail starts with it: "vector store · compose.yaml".
    public var title: String {
        switch self {
        case .aiModel: return "AI model"
        case .vectorStore: return "vector store"
        case .tracing: return "tracing"
        case .agent: return "agent"
        case .localServer: return "local server"
        case .backend: return "backend"
        case .hosting: return "hosting"
        }
    }

    /// The group's tooltip lists the kinds found: "AI models, vector stores, tracing and evals".
    public var plural: String {
        switch self {
        case .aiModel: return "AI models"
        case .vectorStore: return "vector stores"
        case .tracing: return "tracing and evals"
        case .agent: return "agents"
        case .localServer: return "local servers"
        case .backend: return "backends"
        case .hosting: return "hosting"
        }
    }

    public static func < (lhs: ServiceKind, rhs: ServiceKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a service runs: on this Mac (a Compose service, a dev server) or a provider's cloud. A service found in both
/// places gives a row for each.
public enum ServicePlace: String, Sendable, Hashable, CaseIterable {
    case local, cloud
}

/// A host a provider owns, matched against the hosts of the URL and host values the catalog reads.
public enum HostMatch: Sendable, Hashable {
    /// The domain or any host under it: `openrouter.ai`; `abc.cloud.qdrant.io` under `cloud.qdrant.io`.
    case domain(String)
    /// Any host that ends so, at a label or not: `us-central1-aiplatform.googleapis.com` ends `aiplatform.googleapis.com`.
    case suffix(String)
    /// A host that starts and ends so: `bedrock-runtime.eu-west-1.amazonaws.com`.
    case around(prefix: String, suffix: String)

    public func matches(_ host: String) -> Bool {
        let host = host.lowercased()
        switch self {
        case .domain(let domain): return host == domain || host.hasSuffix("." + domain)
        case .suffix(let suffix): return host.hasSuffix(suffix)
        case .around(let prefix, let suffix): return host.hasPrefix(prefix) && host.hasSuffix(suffix)
        }
    }
}

/// What in a project's files names a service. Data, never code, so the catalog can be read, compared and tested.
/// Some signals also say where the service runs: a Compose image or a start command runs it on this Mac, a provider's
/// host in a value is its cloud, and a URL value is wherever its host is.
public indirect enum Signal: Sendable, Hashable {
    /// A key's name in an env file. Its value is not read.
    case key(String)
    case dependency(Ecosystem, String)
    /// A Compose service's image, without registry and tag: `qdrant/qdrant`. Local.
    case image(String)
    /// A file or folder in the project (`langgraph.json`, `mlruns/`, `*.ipynb`), and where it says the service runs.
    case file(String, ServicePlace?)
    /// A fact a tool's config names (`fly.toml`'s app), and where it says the service runs.
    case named(NamedFact, ServicePlace?)
    /// A script, task or process that runs a tool: `langgraph dev`. Local.
    case start(String)
    /// A `[tool.<name>]` table in `pyproject.toml`.
    case pyprojectTool(String)
    /// A URL or host value the catalog reads whose host the provider owns. Cloud.
    case host(HostMatch)
    /// A key whose value is a server's address, wherever that is: on this Mac (or a Compose service) is local, a
    /// remote `https` server is cloud. With a match, only a host that matches names it.
    case origin(String, HostMatch?)
    /// A key whose value is a URL of this scheme: LanceDB Cloud's `db://`.
    case scheme(String, String)
    /// A key whose value starts so: Convex's `dev:` and `prod:` deployments.
    case textPrefix(String, [String])
    /// Every one of them.
    case all([Signal])
    /// Any one of them.
    case any([Signal])
}

/// Where a value put in a link comes from, and nothing else: each is checked against its placeholder's pattern.
public enum FactRef: Sendable, Hashable {
    case named(NamedFact)
    /// A name, id or region value.
    case value(String)
    /// A label of a URL value's host, under `domain`, when exactly `count` labels come before it:
    /// `abcdefghijklmnopqrst` in `abcdefghijklmnopqrst.supabase.co`.
    case hostLabel([String], domain: String, index: Int, count: Int)
    /// A value's text after one of these prefixes: `happy-otter-123` in `dev:happy-otter-123`.
    case afterPrefix(String, [String])
    /// The binding a repeated link is for: a D1 database's id.
    case item
    /// The project's folder name, lower-cased.
    case folderName
}

/// A piece of a link's path, query value or fragment: the template's own text, or a fact that must match its pattern.
public enum Piece: Sendable, Hashable {
    case text(String)
    case fact([FactRef], SafeWebLink.Placeholder)
}

/// One `name=value` of a template's query.
public struct QueryPiece: Sendable, Hashable {
    public let name: String
    public let value: [Piece]

    public init(_ name: String, _ value: [Piece]) {
        self.name = name
        self.value = value
    }
}

// MARK: - Where a link's server is

/// A server a project value names, read as its scheme, host and port only. A host that is a Compose service's name
/// is reached on this Mac at the port that service publishes.
public struct OriginRule: Sendable, Hashable {
    public enum Mapping: Sendable, Hashable {
        case asWritten
        /// LangSmith's API host to its site, as its SDK maps it: `api.smith.langchain.com` to `smith.langchain.com`,
        /// `eu.api.smith.langchain.com` to `eu.smith.langchain.com`; a self-hosted one as it is.
        case langsmithSite
        /// W&B's API host to its app, as wandb maps it: `api.wandb.ai` to `wandb.ai`, another `api.` host to `app.`.
        case wandbApp
    }

    /// The keys that may name it, most preferred first.
    public let keys: [String]
    public let mapping: Mapping
    /// Only a host that matches one of these; any host when empty.
    public let hosts: [HostMatch]
    /// Keys whose port value fills in a port the address does not write (Chroma's `CHROMA_PORT`).
    public let portKeys: [String]
    /// The port on this Mac or in a Compose service when none is written: the container port a service name maps.
    public let localPort: Int?
    /// The port on a remote host when none is written (Qdrant Cloud's 6333).
    public let remotePort: Int?

    public init(_ keys: [String], mapping: Mapping = .asWritten, hosts: [HostMatch] = [], portKeys: [String] = [],
                localPort: Int? = nil, remotePort: Int? = nil) {
        self.keys = keys
        self.mapping = mapping
        self.hosts = hosts
        self.portKeys = portKeys
        self.localPort = localPort
        self.remotePort = remotePort
    }
}

/// Where a local tool's port comes from, tried in order: Compose, the tool's config, a start command, a key the tool
/// reads, then its documented default.
public enum PortSource: Sendable, Hashable {
    /// The host side of the port a Compose service of this image publishes for `target`.
    case compose(String, target: Int)
    /// A port a config file names.
    case named(NamedFact)
    /// A start command's `--port`, `-p` or leading `PORT=`.
    case start([String])
    /// A start command's `--ui-port`.
    case startUI([String])
    /// A start command's port plus this much (Temporal's dev UI is its server's port plus 1000).
    case startPlus([String], Int)
    /// A port value from an env file.
    case env(String)
    /// The port of an address on this Mac a value names, plus this much.
    case valuePlus(String, Int)
}

/// A tool on this Mac: the host its own links use, where its port comes from, and the default.
public struct LocalPort: Sendable, Hashable {
    /// `localhost`, or `127.0.0.1` where the tool's own links use it.
    public let host: String
    public let sources: [PortSource]
    public let defaultPort: Int?
    /// `https` when this fact is "true" (Vite's `server.https`).
    public let httpsWhen: NamedFact?

    public init(_ host: String = "localhost", _ sources: [PortSource] = [], default defaultPort: Int?,
                httpsWhen: NamedFact? = nil) {
        self.host = host
        self.sources = sources
        self.defaultPort = defaultPort
        self.httpsWhen = httpsWhen
    }
}

/// A site a local dev environment serves under its own name: `shop.test` (Herd), `shop.ddev.site` (DDEV).
public struct SiteRule: Sendable, Hashable {
    /// The site's name, the first that is a host's label.
    public let names: [FactRef]
    public let tld: [FactRef]
    public let defaultTLD: String
    public let port: NamedFact?
    /// The port when the files name none; nil for the scheme's own.
    public let defaultPort: Int?
    /// `https` only when this fact is "true"; always when nil.
    public let httpsWhen: NamedFact?

    public init(names: [FactRef], tld: [FactRef] = [], defaultTLD: String, port: NamedFact? = nil,
                defaultPort: Int? = nil, httpsWhen: NamedFact? = nil) {
        self.names = names
        self.tld = tld
        self.defaultTLD = defaultTLD
        self.port = port
        self.defaultPort = defaultPort
        self.httpsWhen = httpsWhen
    }
}

// MARK: - Link templates

/// One page a service's row can open, from the most specific to the provider's home. A template is used only when
/// every fact it needs is present and matches its pattern; one that misses is skipped, never filled with a guess.
public struct LinkTemplate: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// A provider's own host, over `https`.
        case web(String)
        /// The AWS console of the region a fact names (`<region>.console.aws.amazon.com`, GovCloud's own).
        case awsConsole([FactRef])
        /// A server a project value names: on this Mac, in Compose or remote, and the row it opens in is there.
        case configured(OriginRule)
        /// A tool on this Mac.
        case local(LocalPort)
        /// LangGraph Studio: a hosted page for a server on this Mac (`?baseUrl=`), on the LangSmith site a value names.
        case studio(LocalPort, OriginRule)
        /// A site a local dev environment serves.
        case site(SiteRule)
    }

    /// The page, after the service's id: `openai.platform`.
    public let id: String
    /// "Platform", "API Keys"; nil for a local server's own page ("Open Vite at localhost:5173").
    public let page: String?
    /// The badge's words when the page has no port of its own to show; else the page's name.
    public let badge: String?
    public let target: Target
    public let path: [Piece]
    public let query: [QueryPiece]
    public let fragment: [Piece]
    /// The word before the ids in the tooltip: "project" in "Open Supabase Dashboard: project abc…".
    public let about: String?
    /// A menu item after the row's main link, not a main link.
    public let isExtra: Bool
    /// Used only when this holds too.
    public let when: Signal?
    /// The row it belongs in, when that is not where its server is: Firebase's Emulator UI in the cloud row.
    public let place: ServicePlace?
    /// One link for each value of this fact: Cloudflare's D1 databases.
    public let each: NamedFact?

    public init(_ id: String, _ page: String?, _ target: Target, path: [Piece] = [], query: [QueryPiece] = [],
                fragment: [Piece] = [], badge: String? = nil, about: String? = nil, extra: Bool = false,
                when: Signal? = nil, place: ServicePlace? = nil, each: NamedFact? = nil) {
        self.id = id
        self.page = page
        self.badge = badge
        self.target = target
        self.path = path
        self.query = query
        self.fragment = fragment
        self.about = about
        self.isExtra = extra
        self.when = when
        self.place = place
        self.each = each
    }

    /// A page on a provider's own host. The path is the template's text, already percent-encoded.
    public static func web(_ id: String, _ page: String, _ host: String, _ path: String = "", badge: String? = nil,
                           extra: Bool = false, when: Signal? = nil) -> LinkTemplate {
        let pieces: [Piece] = path.isEmpty ? [] : [.text(path)]
        return LinkTemplate(id, page, .web(host), path: pieces, badge: badge, extra: extra, when: when)
    }

    /// Whether it opens a page on a provider's own host, not a server the project's files place.
    public var isVendorPage: Bool {
        switch target {
        case .web, .awsConsole: return true
        case .configured, .local, .studio, .site: return false
        }
    }

    /// Whether it can be built from the project's folder alone: a provider's fixed page, a local tool's default
    /// port, or a site under the folder's name.
    public var needsNoFact: Bool {
        let pieces: [Piece] = path + fragment + query.flatMap(\.value)
        let factFree = !pieces.contains { (piece: Piece) -> Bool in
            if case .fact = piece { return true }
            return false
        }
        guard factFree, each == nil else { return false }
        switch target {
        case .web: return true
        case .local(let port), .studio(let port, _): return port.defaultPort != nil
        case .site(let rule): return rule.names.contains(.folderName)
        case .awsConsole, .configured: return false
        }
    }
}

/// A line a row's tooltip adds from a value that is not a link: "Project: support-bot".
public struct ServiceNote: Sendable, Hashable {
    public let label: String
    public let refs: [FactRef]

    public init(_ label: String, _ refs: [FactRef]) {
        self.label = label
        self.refs = refs
    }
}

// MARK: - Entries

/// One service the Services section can list: what names it, where it runs, and the pages its row opens. Adding a
/// service is one entry and one test.
public struct ServiceEntry: Sendable, Hashable, Identifiable {
    /// Stable, and the same as `DatabaseProvider.serviceID` for a provider a database row can carry.
    public let id: String
    public let name: String
    /// The cloud row's name when it is another product's ("Zilliz Cloud"); else "<name> Cloud" beside a local row.
    public let cloudName: String?
    public let kind: ServiceKind
    /// Its order within its kind: most used first.
    public let rank: Int
    /// Where it runs when no signal says: an SDK's provider is its cloud, a web framework runs on this Mac. Nil when
    /// only an address says (a vector store named by its client package alone makes no row).
    public let place: ServicePlace?
    public let signals: [Signal]
    /// Base-URL keys of its SDK. One whose value is another host sends the SDK there, so the entry's own keys and
    /// packages no longer name it; only its own host in a value does.
    public let routes: [String]
    /// The keys whose values its signals, links and notes read, each with its role. None may look like a secret.
    public let values: [String: KeyRole]
    /// Main links first, in order, then extras.
    public let links: [LinkTemplate]
    public let notes: [ServiceNote]

    public init(_ id: String, _ name: String, cloudName: String? = nil, kind: ServiceKind, rank: Int,
                place: ServicePlace?, signals: [Signal], routes: [String] = [], values: [String: KeyRole] = [:],
                links: [LinkTemplate], notes: [ServiceNote] = []) {
        self.id = id
        self.name = name
        self.cloudName = cloudName
        self.kind = kind
        self.rank = rank
        self.place = place
        self.signals = signals
        self.routes = routes
        self.values = values
        self.links = links
        self.notes = notes
    }
}

/// The services Next Term can name from a project's files, and what the fact readers must be asked for to name them.
public enum ServiceCatalog {
    /// Every entry, kind by kind in the order the Services section lists them.
    public static let all: [ServiceEntry] = {
        let kinds: [[ServiceEntry]] = [aiModels, vectorStores, tracing, agents, localServers, backends, hosting]
        return kinds.flatMap { (entries: [ServiceEntry]) -> [ServiceEntry] in entries }
    }()

    /// Every key whose value an entry reads, with its role: what `ProjectFacts.read` takes as `valueKeys`.
    public static let valueKeys: [String: KeyRole] = {
        var keys: [String: KeyRole] = [:]
        for entry in all { keys.merge(entry.values) { (first: KeyRole, _: KeyRole) -> KeyRole in first } }
        return keys
    }()

    /// The URL and host keys whose values a provider's host may be found in.
    static let hostKeys: [String] = valueKeys.filter { (pair: (key: String, value: KeyRole)) -> Bool in
        pair.value == .url || pair.value == .host
    }.keys.sorted()

    /// Subcommands that run no server, read only so that a port they name is not taken for a server's.
    static let otherStartWords = ["vite build", "vite preview", "vite optimize"]

    /// Every start word an entry looks for, then the ones that run no server.
    public static let startWords: [String] = {
        var words: [String] = []
        for entry in all { words += entry.startWords.filter { (word: String) -> Bool in !words.contains(word) } }
        return words + otherStartWords
    }()

    /// Every marker file an entry looks for.
    public static let markerFiles: [String] = {
        var files: [String] = []
        for entry in all { files += entry.markerFiles.filter { (file: String) -> Bool in !files.contains(file) } }
        return files
    }()
}

// MARK: - What an entry asks of the readers

extension Signal {
    /// It and every signal inside it.
    var leaves: [Signal] {
        switch self {
        case .all(let signals), .any(let signals):
            return signals.flatMap { (signal: Signal) -> [Signal] in signal.leaves }
        default:
            return [self]
        }
    }

    var keysRead: Set<String> {
        switch self {
        case .origin(let key, _), .scheme(let key, _), .textPrefix(let key, _): return [key]
        case .all(let signals), .any(let signals):
            return signals.reduce(into: Set<String>()) { (keys: inout Set<String>, signal: Signal) in
                keys.formUnion(signal.keysRead)
            }
        default: return []
        }
    }
}

extension FactRef {
    var keysRead: Set<String> {
        switch self {
        case .value(let key), .afterPrefix(let key, _): return [key]
        case .hostLabel(let keys, _, _, _): return Set(keys)
        case .named, .item, .folderName: return []
        }
    }
}

extension LinkTemplate {
    var refs: [FactRef] {
        let pieces: [Piece] = path + fragment + query.flatMap(\.value)
        var refs = pieces.flatMap { (piece: Piece) -> [FactRef] in
            if case .fact(let refs, _) = piece { return refs }
            return []
        }
        switch target {
        case .awsConsole(let regions): refs += regions
        case .site(let rule): refs += rule.names + rule.tld
        default: break
        }
        return refs
    }

    var ports: LocalPort? {
        switch target {
        case .local(let port), .studio(let port, _): return port
        default: return nil
        }
    }

    var keysRead: Set<String> {
        var keys = refs.reduce(into: Set<String>()) { (keys: inout Set<String>, ref: FactRef) in keys.formUnion(ref.keysRead) }
        keys.formUnion(when?.keysRead ?? [])
        switch target {
        case .configured(let rule), .studio(_, let rule): keys.formUnion(rule.keys + rule.portKeys)
        default: break
        }
        for source in ports?.sources ?? [] {
            switch source {
            case .env(let key), .valuePlus(let key, _): keys.insert(key)
            default: break
            }
        }
        return keys
    }
}

extension ServiceEntry {
    var allSignals: [Signal] {
        let whens: [Signal] = links.compactMap(\.when)
        return (signals + whens).flatMap(\.leaves)
    }

    /// Every key whose value it reads.
    var keysRead: Set<String> {
        var keys = Set(routes)
        for signal in allSignals { keys.formUnion(signal.keysRead) }
        for link in links { keys.formUnion(link.keysRead) }
        for note in notes { for ref in note.refs { keys.formUnion(ref.keysRead) } }
        return keys
    }

    /// The provider hosts its links name.
    var fixedHosts: [String] {
        links.compactMap { (link: LinkTemplate) -> String? in
            if case .web(let host) = link.target { return host }
            return nil
        }
    }

    var images: [String] {
        let named = allSignals.compactMap { (signal: Signal) -> String? in
            if case .image(let image) = signal { return image }
            return nil
        }
        let ported = links.flatMap { (link: LinkTemplate) -> [String] in
            (link.ports?.sources ?? []).compactMap { (source: PortSource) -> String? in
                if case .compose(let image, _) = source { return image }
                return nil
            }
        }
        return named + ported
    }

    var startWords: [String] {
        var words = allSignals.compactMap { (signal: Signal) -> String? in
            if case .start(let word) = signal { return word }
            return nil
        }
        for link in links {
            for source in link.ports?.sources ?? [] {
                switch source {
                case .start(let list), .startUI(let list), .startPlus(let list, _): words += list
                default: break
                }
            }
        }
        return words
    }

    /// The schemes whose value names a store of this entry's own on this Mac, not a server: MLflow's `file:`.
    func storeSchemes(_ key: String) -> Set<String> {
        Set(allSignals.compactMap { (signal: Signal) -> String? in
            if case .scheme(let named, let scheme) = signal, named == key { return scheme }
            return nil
        })
    }

    var markerFiles: [String] {
        allSignals.compactMap { (signal: Signal) -> String? in
            if case .file(let file, _) = signal { return file }
            return nil
        }
    }
}
