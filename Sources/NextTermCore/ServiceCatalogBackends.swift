import Foundation

// Backends and storage, most used first, listed only where no database row shows them already. Each opens the
// project its files name (a Supabase ref, a Firebase project, a Convex deployment), else its dashboard's home.

extension ServiceCatalog {
    static let backends: [ServiceEntry] = [supabase, firebase, upstash, convex]

    // MARK: Supabase, Firebase

    /// The ref, 20 lower-case letters, from `supabase link`'s file, `SUPABASE_PROJECT_ID`, or an API URL's host; never
    /// `config.toml`'s `project_id`, a local name. With none, `_` lets Supabase ask which project. The local stack
    /// opens Studio, and its mail catcher beside it.
    static let supabaseRef: [FactRef] = [
        .named(.supabaseRef), .value("SUPABASE_PROJECT_ID"),
        .hostLabel(DatabaseLinks.supabaseURLKeys, domain: "supabase.co", index: 0, count: 1),
    ]
    static let supabaseSignals: [Signal] = DatabaseLinks.supabaseURLKeys.map { (key: String) -> Signal in
        .origin(key, .domain("supabase.co"))
    } + [
        .named(.supabaseRef, .cloud), .key("SUPABASE_PROJECT_ID"), .file("supabase/config.toml", .local),
        .dependency(.npm, "@supabase/supabase-js"), .dependency(.pypi, "supabase"),
    ]
    static let supabaseStudio = LocalPort("127.0.0.1", [.named(.supabaseStudioPort)], default: 54323)
    static let supabaseMail = LocalPort("127.0.0.1", [.named(.supabaseInbucketPort)], default: 54324)
    static let supabaseLinks: [LinkTemplate] = [
        LinkTemplate("dashboard", "Dashboard", .web("supabase.com"),
                     path: [.text("/dashboard/project/"), .fact(supabaseRef, .supabaseRef)], about: "project"),
        .web("dashboard", "Dashboard", "supabase.com", "/dashboard/project/_"),
        LinkTemplate("studio", "Studio", .local(supabaseStudio)),
        LinkTemplate("email", "Email", .local(supabaseMail), extra: true),
    ]
    static let supabaseValues: [String: KeyRole] = DatabaseLinks.supabaseURLKeys.reduce(into: ["SUPABASE_PROJECT_ID": .id]) {
        (values: inout [String: KeyRole], key: String) in values[key] = .url
    }
    static let supabase = ServiceEntry("supabase", "Supabase", kind: .backend, rank: 1, place: .cloud,
                                       signals: supabaseSignals, values: supabaseValues, links: supabaseLinks)

    /// The project `.firebaserc` names (or a project id value), and the Emulator UI when `firebase.json` sets up the
    /// emulators.
    static let firebaseProject: [FactRef] = [
        .named(.firebaseProject), .value("FIREBASE_PROJECT_ID"), .value("NEXT_PUBLIC_FIREBASE_PROJECT_ID"),
    ]
    static let firebaseSignals: [Signal] = [
        .named(.firebaseProject, .cloud), .key("FIREBASE_PROJECT_ID"), .key("NEXT_PUBLIC_FIREBASE_PROJECT_ID"),
        .dependency(.npm, "firebase"), .dependency(.npm, "firebase-admin"), .dependency(.pypi, "firebase-admin"),
    ]
    static let firebaseEmulatorUI = LocalPort("127.0.0.1", [.named(.firebaseEmulatorUIPort)], default: 4000)
    static let firebaseLinks: [LinkTemplate] = [
        LinkTemplate("overview", "Console", .web("console.firebase.google.com"),
                     path: [.text("/project/"), .fact(firebaseProject, .gcpProject), .text("/overview")],
                     about: "project"),
        .web("console", "Console", "console.firebase.google.com", "/"),
        LinkTemplate("emulators", "Emulator UI", .local(firebaseEmulatorUI), extra: true,
                     when: .named(.firebaseEmulators, nil), place: .cloud),
    ]
    static let firebase = ServiceEntry("firebase", "Firebase", kind: .backend, rank: 2, place: .cloud,
                                       signals: firebaseSignals,
                                       values: ["FIREBASE_PROJECT_ID": .id, "NEXT_PUBLIC_FIREBASE_PROJECT_ID": .id],
                                       links: firebaseLinks)
}

// MARK: - Upstash, Convex

extension ServiceCatalog {
    /// One row for every Upstash product a project uses, with a page for each: its databases' ids are not in their
    /// hosts, so the console's list for each product.
    static let upstashRedis: Signal = .any([
        .key("UPSTASH_REDIS_REST_URL"), .key("UPSTASH_REDIS_REST_TOKEN"), .key("KV_REST_API_URL"), .key("KV_URL"),
        .dependency(.npm, "@upstash/redis"), .dependency(.pypi, "upstash-redis"),
    ])
    static let upstashVector: Signal = .any([
        .key("UPSTASH_VECTOR_REST_URL"), .key("UPSTASH_VECTOR_REST_TOKEN"),
        .dependency(.npm, "@upstash/vector"), .dependency(.pypi, "upstash-vector"),
    ])
    static let upstashQStash: Signal = .any([
        .key("QSTASH_URL"), .key("QSTASH_TOKEN"), .dependency(.npm, "@upstash/qstash"), .dependency(.pypi, "qstash"),
    ])
    static let upstashLinks: [LinkTemplate] = [
        .web("redis", "Redis", "console.upstash.com", "/redis", badge: "Console", when: upstashRedis),
        .web("vector", "Vector", "console.upstash.com", "/vector", badge: "Console", when: upstashVector),
        .web("qstash", "QStash", "console.upstash.com", "/qstash", badge: "Console", when: upstashQStash),
        .web("console", "Console", "console.upstash.com", "/"),
        .web("vector", "Vector", "console.upstash.com", "/vector", extra: true, when: upstashVector),
        .web("qstash", "QStash", "console.upstash.com", "/qstash", extra: true, when: upstashQStash),
    ]
    static let upstashValues: [String: KeyRole] = [
        "UPSTASH_REDIS_REST_URL": .url, "KV_REST_API_URL": .url, "UPSTASH_VECTOR_REST_URL": .url, "QSTASH_URL": .url,
    ]
    static let upstash = ServiceEntry("upstash", "Upstash", kind: .backend, rank: 3, place: .cloud,
                                      signals: [upstashRedis, upstashVector, upstashQStash, .host(.domain("upstash.io"))],
                                      values: upstashValues, links: upstashLinks)

    /// The deployment `CONVEX_DEPLOYMENT` (`dev:<name>`, `prod:<name>`) or a `<name>.convex.cloud` URL names, as the
    /// Convex CLI opens it. A `local:` or `anonymous:` deployment has no cloud page, and `CONVEX_DEPLOY_KEY` is
    /// never read.
    static let convexURLKeys = ["CONVEX_URL", "NEXT_PUBLIC_CONVEX_URL", "VITE_CONVEX_URL", "EXPO_PUBLIC_CONVEX_URL"]
    static let convexDeployment: [FactRef] = [
        .afterPrefix("CONVEX_DEPLOYMENT", ["dev:", "prod:"]),
        .hostLabel(convexURLKeys, domain: "convex.cloud", index: 0, count: 1),
    ]
    static let convexSignals: [Signal] = [.textPrefix("CONVEX_DEPLOYMENT", ["dev:", "prod:"])]
        + convexURLKeys.map { (key: String) -> Signal in .origin(key, .domain("convex.cloud")) }
    static let convexLinks: [LinkTemplate] = [
        LinkTemplate("deployment", "Dashboard", .web("dashboard.convex.dev"),
                     path: [.text("/d/"), .fact(convexDeployment, .slug)], about: "deployment"),
        .web("dashboard", "Dashboard", "dashboard.convex.dev"),
    ]
    static let convexValues: [String: KeyRole] = convexURLKeys.reduce(into: ["CONVEX_DEPLOYMENT": .name]) {
        (values: inout [String: KeyRole], key: String) in values[key] = .url
    }
    static let convex = ServiceEntry("convex", "Convex", kind: .backend, rank: 4, place: .cloud, signals: convexSignals,
                                     values: convexValues, links: convexLinks)
}
