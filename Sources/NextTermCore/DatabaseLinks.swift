import Foundation

/// A page a badge or a menu item opens in the browser: a provider's console for a database, a local tool's own page.
/// Built only from hosts, ports, names and ids a project's files hold, each checked by `SafeWebLink`, so it holds no
/// secret and may be printed, compared and shown.
public struct ServiceLink: Sendable, Hashable {
    /// Stable: the service, then the page (`neon.console`).
    public let id: String
    /// The badge's words: "Neon", "Dashboard", ":5173".
    public let badge: String
    /// The menu item: "Open Neon Console".
    public let title: String
    /// What the pointer shows over the badge and VoiceOver reads: "Open Neon Console: project cold-grass-40154007".
    public let tooltip: String
    public let url: URL
    /// The project file that gave the link its id, name, address or port; nil for a provider's fixed page or a
    /// tool's default port.
    public let source: String?

    public init(id: String, badge: String, title: String, tooltip: String, url: URL, source: String? = nil) {
        self.id = id
        self.badge = badge
        self.title = title
        self.tooltip = tooltip
        self.url = url
        self.source = source
    }
}

/// The page each provider badge on a database row opens: the most specific one the project's files allow without a
/// secret (Neon's project from `.neon`, Supabase's from its ref, Herd's site from `APP_URL`), else the provider's own
/// home. Built from the row's public host and the project's facts; the row's user, password and query values are
/// never read, even where they hold an id (a Supabase pooler's user name holds the ref).
public enum DatabaseLinks {
    /// The env keys whose values the links read, each with its role.
    public static let valueKeys: [String: KeyRole] = [
        "APP_URL": .url,
        "SUPABASE_PROJECT_ID": .id,
        "SUPABASE_URL": .url, "NEXT_PUBLIC_SUPABASE_URL": .url, "VITE_SUPABASE_URL": .url,
        "EXPO_PUBLIC_SUPABASE_URL": .url, "PUBLIC_SUPABASE_URL": .url,
        "MONGODB_ATLAS_PROJECT_ID": .id,
        "RAILWAY_PROJECT_ID": .id, "RAILWAY_SERVICE_ID": .id, "RAILWAY_ENVIRONMENT_ID": .id,
    ]

    /// Where a Supabase project's API URL may be written, the server's first, then each framework's public copy.
    static let supabaseURLKeys = ["SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_URL", "VITE_SUPABASE_URL",
                                  "EXPO_PUBLIC_SUPABASE_URL", "PUBLIC_SUPABASE_URL"]

    /// One link per provider of the row, in its order.
    public static func links(for database: DetectedDatabase, facts: ProjectFacts) -> [ServiceLink] {
        database.providers.compactMap { (provider: DatabaseProvider) -> ServiceLink? in
            page(for: provider, database: database, facts: facts)?.link(provider)
        }
    }

    static func page(for provider: DatabaseProvider, database: DetectedDatabase, facts: ProjectFacts) -> Page? {
        switch provider {
        case .vercel: return vercel()
        case .neon: return neon(facts)
        case .supabase: return database.environment == .local ? supabaseStudio(facts) : supabase(database, facts)
        case .herd: return herd(facts)
        case .planetScale: return planetScale(facts)
        case .prismaPostgres: return Page(name: "Console", url: https("console.prisma.io"))
        case .turso: return Page(name: "Dashboard", url: https("app.turso.tech"))
        case .mongoAtlas: return atlas(facts)
        case .railway: return railway(facts)
        case .render: return render(database)
        case .fly: return fly(database, facts)
        case .aws: return aws(database)
        case .cockroach: return Page(name: "Console", url: https("cockroachlabs.cloud", "/clusters"))
        case .digitalOcean: return Page(name: "Databases", url: https("cloud.digitalocean.com", "/databases"))
        case .azure: return azure(database)
        }
    }

    /// A page before it is a link: its name ("Console"), its address, and what the tooltip adds.
    struct Page {
        let name: String
        let url: URL?
        /// After "Open <Provider> <Page>: " when the link is specific: "project cold-grass-40154007".
        var detail: String?
        /// The whole tooltip, where the plain form does not fit: a local port, a site.
        var tooltip: String?
        var source: String?

        func link(_ provider: DatabaseProvider) -> ServiceLink? {
            guard let url else { return nil }
            let title = "Open " + provider.rawValue + " " + name
            let detailed = detail.map { (detail: String) -> String in title + ": " + detail } ?? title
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            return ServiceLink(id: provider.serviceID + "." + slug, badge: provider.rawValue, title: title,
                               tooltip: tooltip ?? detailed, url: url, source: source)
        }
    }

    /// A provider's fixed page over `https`.
    static func https(_ host: String, _ path: String = "", fragment: String? = nil) -> URL? {
        let parts: [SafeWebLink.Part] = path.isEmpty ? [] : [.fixed(path)]
        let fragmentParts: [SafeWebLink.Part] = fragment.map { (text: String) -> [SafeWebLink.Part] in [.fixed(text)] } ?? []
        return SafeWebLink.make(scheme: "https", host: host, path: parts, fragment: fragmentParts)
    }
}

// MARK: - Vercel, Neon, Supabase, Herd

extension DatabaseLinks {
    /// The team's storage list: `[team]` lets Vercel pick the team the user is signed in to.
    static func vercel() -> Page? {
        let to = SafeWebLink.QueryItem("to", .fixed("%2F%5Bteam%5D%2F%7E%2Fstores"))
        let url = SafeWebLink.make(scheme: "https", host: "vercel.com", path: [.fixed("/d")], query: [to])
        return Page(name: "Storage", url: url)
    }

    /// The project `.neon` names (neonctl writes it), else the project list.
    static func neon(_ facts: ProjectFacts) -> Page? {
        if let id = facts.named(.neonProjectID), SafeWebLink.Placeholder.slug.accepts(id) {
            let path: [SafeWebLink.Part] = [.fixed("/app/projects/"), .value(id, .slug)]
            let url = SafeWebLink.make(scheme: "https", host: "console.neon.tech", path: path)
            return Page(name: "Console", url: url, detail: "project " + id, source: facts.namedFile(.neonProjectID))
        }
        return Page(name: "Console", url: https("console.neon.tech", "/app/projects"))
    }

    /// The project its ref names, else `_`, where Supabase asks which project.
    static func supabase(_ database: DetectedDatabase, _ facts: ProjectFacts) -> Page? {
        guard let found = supabaseRef(database, facts) else {
            return Page(name: "Dashboard", url: https("supabase.com", "/dashboard/project/_"))
        }
        let path: [SafeWebLink.Part] = [.fixed("/dashboard/project/"), .value(found.ref, .supabaseRef)]
        let url = SafeWebLink.make(scheme: "https", host: "supabase.com", path: path)
        return Page(name: "Dashboard", url: url, detail: "project " + found.ref, source: found.file)
    }

    /// The ref, 20 lower-case letters, from the first place that holds a valid one: the row's own `db.<ref>` host,
    /// `supabase/.temp/project-ref` (`supabase link` writes it), `SUPABASE_PROJECT_ID`, then the `<ref>.supabase.co`
    /// host of an API URL. Never from the row's user name, and never `config.toml`'s `project_id`, a local name.
    static func supabaseRef(_ database: DetectedDatabase, _ facts: ProjectFacts) -> (ref: String, file: String?)? {
        var found: [(ref: String, file: String?)] = []
        let labels = (database.host ?? "").lowercased().split(separator: ".").map(String.init)
        if labels.count == 4, labels[0] == "db", labels[2] == "supabase", labels[3] == "co" {
            found.append((labels[1], database.sourceFile))
        }
        if let ref = facts.named(.supabaseRef) { found.append((ref, facts.namedFile(.supabaseRef))) }
        if let id = facts.value("SUPABASE_PROJECT_ID"), let ref = id.text { found.append((ref, id.file)) }
        for key in supabaseURLKeys {
            guard let fact = facts.value(key), let host = fact.origin?.host else { continue }
            let parts = host.split(separator: ".").map(String.init)
            if parts.count == 3, parts[1] == "supabase", parts[2] == "co" { found.append((parts[0], fact.file)) }
        }
        return found.first { (item: (ref: String, file: String?)) -> Bool in
            SafeWebLink.Placeholder.supabaseRef.accepts(item.ref)
        }
    }

    /// The local stack's Studio, on `[studio] port` or Supabase's default, at the address the CLI prints.
    static func supabaseStudio(_ facts: ProjectFacts) -> Page? {
        let configured = facts.port(.supabaseStudioPort)
        let port = configured ?? 54323
        let url = SafeWebLink.make(scheme: "http", host: "127.0.0.1", port: port)
        let file = configured == nil ? nil : facts.namedFile(.supabaseStudioPort)
        let from = file.map { (file: String) -> String in "from " + file } ?? "default port"
        let tooltip = "Open Supabase Studio at 127.0.0.1:\(port) (\(from))"
        return Page(name: "Studio", url: url, tooltip: tooltip, source: file)
    }

    /// The site Herd serves for the project: `APP_URL`'s origin when its host ends `.test`, else `herd.yml`'s name as
    /// `<name>.test` (`https` when it is secured). Herd's app has no web page, so with neither, its services docs.
    static func herd(_ facts: ProjectFacts) -> Page? {
        if let fact = facts.value("APP_URL"), let origin = fact.origin, origin.host.hasSuffix(".test"),
           let url = origin.link() {
            return herdSite(url: url, host: origin.host, port: origin.port, source: fact.file)
        }
        if let name = facts.named(.herdName) {
            let secured: Bool = facts.named(.herdSecured) == "true"
            let host = name.lowercased() + ".test"
            if let url = SafeWebLink.make(scheme: secured ? "https" : "http", host: host) {
                return herdSite(url: url, host: host, port: nil, source: facts.namedFile(.herdName))
            }
        }
        let docs = https("herd.laravel.com", "/docs/macos/herd-pro-services/services")
        return Page(name: "Services Docs", url: docs)
    }

    static func herdSite(url: URL, host: String, port: Int?, source: String?) -> Page {
        let address = host + (port.map { (port: Int) -> String in ":\(port)" } ?? "")
        return Page(name: "Site", url: url, tooltip: "Open " + address + ", the site Herd serves", source: source)
    }
}

// MARK: - PlanetScale, Atlas, Railway, Render, Fly.io

extension DatabaseLinks {
    /// The database `.pscale.yml` names (the CLI writes it), else the dashboard.
    static func planetScale(_ facts: ProjectFacts) -> Page? {
        if let org = facts.named(.pscaleOrg), let name = facts.named(.pscaleDatabase),
           SafeWebLink.Placeholder.slug.accepts(org), SafeWebLink.Placeholder.slug.accepts(name) {
            let path: [SafeWebLink.Part] = [.fixed("/"), .value(org, .slug), .fixed("/"), .value(name, .slug)]
            let url = SafeWebLink.make(scheme: "https", host: "app.planetscale.com", path: path)
            return Page(name: "Dashboard", url: url, detail: "database " + org + "/" + name,
                        source: facts.namedFile(.pscaleDatabase))
        }
        return Page(name: "Dashboard", url: https("app.planetscale.com", "/"))
    }

    /// The project's clusters when `MONGODB_ATLAS_PROJECT_ID` holds one, else Atlas's home. A host's cluster label
    /// is never used: its case is lost.
    static func atlas(_ facts: ProjectFacts) -> Page? {
        if let fact = facts.value("MONGODB_ATLAS_PROJECT_ID"), let id = fact.text,
           SafeWebLink.Placeholder.atlasProject.accepts(id) {
            let path: [SafeWebLink.Part] = [.fixed("/v2/"), .value(id, .atlasProject)]
            let url = SafeWebLink.make(scheme: "https", host: "cloud.mongodb.com", path: path, fragment: [.fixed("/clusters")])
            return Page(name: "Console", url: url, detail: "project " + id, source: fact.file)
        }
        return Page(name: "Console", url: https("cloud.mongodb.com", "/"))
    }

    /// The service in its environment, as the Railway CLI opens it, when all three ids are known; else the project;
    /// else the dashboard.
    static func railway(_ facts: ProjectFacts) -> Page? {
        func id(_ key: String) -> (id: String, file: String)? {
            guard let fact = facts.value(key), let text = fact.text, SafeWebLink.Placeholder.uuid.accepts(text) else {
                return nil
            }
            return (text, fact.file)
        }
        guard let project = id("RAILWAY_PROJECT_ID") else {
            return Page(name: "Dashboard", url: https("railway.com", "/dashboard"))
        }
        let projectPath: [SafeWebLink.Part] = [.fixed("/project/"), .value(project.id, .uuid)]
        if let service = id("RAILWAY_SERVICE_ID"), let environment = id("RAILWAY_ENVIRONMENT_ID") {
            let path: [SafeWebLink.Part] = projectPath + [.fixed("/service/"), .value(service.id, .uuid)]
            let query = [SafeWebLink.QueryItem("environmentId", .value(environment.id, .uuid))]
            let url = SafeWebLink.make(scheme: "https", host: "railway.com", path: path, query: query)
            return Page(name: "Service", url: url, source: service.file)
        }
        let url = SafeWebLink.make(scheme: "https", host: "railway.com", path: projectPath)
        return Page(name: "Project", url: url, source: project.file)
    }

    /// The database its `dpg-…-a` host names, else the dashboard.
    static func render(_ database: DetectedDatabase) -> Page? {
        let host = (database.host ?? "").lowercased()
        let label = String(host.split(separator: ".").first ?? "")
        guard DatabaseProvider.isRenderPostgres(host), SafeWebLink.Placeholder.slug.accepts(label) else {
            return Page(name: "Dashboard", url: https("dashboard.render.com"))
        }
        let path: [SafeWebLink.Part] = [.fixed("/d/"), .value(label, .slug)]
        let url = SafeWebLink.make(scheme: "https", host: "dashboard.render.com", path: path)
        return Page(name: "Dashboard", url: url, detail: "database " + label, source: database.sourceFile)
    }

    /// The app `fly.toml` names, for a host on Fly.io's private network; the dashboard for Managed Postgres
    /// (`*.flympg.net`), whose organisation no file names, or when `fly.toml` names no app.
    static func fly(_ database: DetectedDatabase, _ facts: ProjectFacts) -> Page? {
        let managed: Bool = (database.host ?? "").lowercased().hasSuffix(".flympg.net")
        guard !managed, let app = facts.named(.flyApp), SafeWebLink.Placeholder.slug.accepts(app) else {
            return Page(name: "Dashboard", url: https("fly.io", "/dashboard"))
        }
        let url = SafeWebLink.make(scheme: "https", host: "fly.io", path: [.fixed("/apps/"), .value(app, .slug)])
        return Page(name: "App", url: url, detail: app, source: facts.namedFile(.flyApp))
    }
}

// MARK: - AWS and Azure

extension DatabaseLinks {
    /// The instance or Aurora cluster its `<id>.<endpoint>.<region>.rds.amazonaws.com` host names, in that region's
    /// console; the region's list for an RDS Proxy (its name is not a database's); else the console's home. A host in
    /// another partition (`amazonaws.com.cn`) has no AWS badge at all.
    static func aws(_ database: DetectedDatabase) -> Page? {
        let host = (database.host ?? "").lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let home = Page(name: "RDS Console", url: https("console.aws.amazon.com", "/rds/home"))
        guard labels.count == 6, host.hasSuffix(".rds.amazonaws.com") else { return home }
        let id = labels[0]
        let endpoint = labels[1]
        let region = labels[2]
        guard SafeWebLink.Placeholder.awsRegion.accepts(region) else { return home }
        let console = region + ".console.aws.amazon.com"
        let path: [SafeWebLink.Part] = [.fixed("/rds/home")]
        let query = [SafeWebLink.QueryItem("region", .value(region, .awsRegion))]
        guard !endpoint.hasPrefix("proxy-"), SafeWebLink.Placeholder.slug.accepts(id) else {
            let list: [SafeWebLink.Part] = [.fixed("databases:")]
            let url = SafeWebLink.make(scheme: "https", host: console, path: path, query: query, fragment: list)
            return Page(name: "RDS Console", url: url, detail: region)
        }
        let cluster: Bool = endpoint.hasPrefix("cluster-")
        let fragment: [SafeWebLink.Part] = [.fixed("database:id="), .value(id, .slug),
                                            .fixed(cluster ? ";is-cluster=true" : ";is-cluster=false")]
        let url = SafeWebLink.make(scheme: "https", host: console, path: path, query: query, fragment: fragment)
        let detail = (cluster ? "cluster " : "database ") + id + " in " + region
        return Page(name: "RDS Console", url: url, detail: detail, source: database.sourceFile)
    }

    /// The portal's list of that kind of server: a resource's own page needs a subscription no file names.
    static func azure(_ database: DetectedDatabase) -> Page? {
        let host = (database.host ?? "").lowercased()
        let kinds: [(suffix: String, list: String)] = [
            (".postgres.database.azure.com", "browse/Microsoft.DBforPostgreSQL%2FflexibleServers"),
            (".mysql.database.azure.com", "browse/Microsoft.DBforMySQL%2FflexibleServers"),
            (".database.windows.net", "browse/Microsoft.Sql%2Fservers%2Fdatabases"),
        ]
        let kind = kinds.first { (kind: (suffix: String, list: String)) -> Bool in host.hasSuffix(kind.suffix) }
        return Page(name: "Portal", url: https("portal.azure.com", "/", fragment: kind?.list))
    }
}
