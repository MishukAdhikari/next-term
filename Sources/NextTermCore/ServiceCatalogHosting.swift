import Foundation

// Hosting, most used first, from the files each platform's CLI writes into the project. Each opens the app or project
// they name, else its dashboard. Vercel stays here beside the Databases group's own Vercel link, which is no row.

extension ServiceCatalog {
    static let hosting: [ServiceEntry] = [vercel, cloudflare, fly, railway, render]

    // MARK: Vercel, Cloudflare

    /// A project's page needs its team's slug, which `.vercel/project.json` does not hold, so the project's name goes
    /// in the tooltip.
    static let vercel = ServiceEntry("vercel", "Vercel", kind: .hosting, rank: 1, place: .cloud,
                                     signals: [.named(.vercelProjectID, .cloud)],
                                     links: [.web("dashboard", "Dashboard", "vercel.com", "/dashboard")],
                                     notes: [ServiceNote("Project", [.named(.vercelProjectName)])])

    /// Workers & Pages for the account Wrangler's config names, else the dashboard's account picker (`?to=`); a link
    /// for each D1 database and R2 bucket it binds, through the picker.
    static let wranglerFiles = ["wrangler.toml", "wrangler.json", "wrangler.jsonc"]
    static let cloudflareAccount: Piece = .fact([.named(.wranglerAccountID)], .slug)
    static let cloudflareLinks: [LinkTemplate] = [
        LinkTemplate("workers", "Dashboard", .web("dash.cloudflare.com"),
                     path: [.text("/"), cloudflareAccount, .text("/workers-and-pages")], about: "account"),
        LinkTemplate("workers", "Dashboard", .web("dash.cloudflare.com"), path: [.text("/")],
                     query: [QueryPiece("to", [.text("/:account/workers-and-pages")])]),
        LinkTemplate("d1", "D1", .web("dash.cloudflare.com"), path: [.text("/")],
                     query: [QueryPiece("to", [.text("/:account/workers/d1/databases/"), .fact([.item], .uuid)])],
                     extra: true, each: .d1Database),
        LinkTemplate("r2", "R2", .web("dash.cloudflare.com"), path: [.text("/")],
                     query: [QueryPiece("to", [.text("/:account/r2/default/buckets/"), .fact([.item], .slug)])],
                     extra: true, each: .r2Bucket),
    ]
    static let cloudflare = ServiceEntry("cloudflare", "Cloudflare", kind: .hosting, rank: 2, place: .cloud,
                                         signals: wranglerFiles.map { (file: String) -> Signal in .file(file, .cloud) },
                                         links: cloudflareLinks)
}

// MARK: - Fly.io, Railway, Render

extension ServiceCatalog {
    /// The app `fly.toml` names, as flyctl opens it.
    static let flyLinks: [LinkTemplate] = [
        LinkTemplate("app", "App", .web("fly.io"), path: [.text("/apps/"), .fact([.named(.flyApp)], .slug)],
                     about: "app"),
        .web("dashboard", "Dashboard", "fly.io", "/dashboard"),
    ]
    static let fly = ServiceEntry("fly", "Fly.io", kind: .hosting, rank: 3, place: .cloud,
                                  signals: [.named(.flyApp, .cloud), .file("fly.toml", .cloud)], links: flyLinks)

    /// The service in its environment when all three ids are known, as the Railway CLI opens it; else the project;
    /// else the dashboard. Its config files hold no id.
    static let railwayProject: Piece = .fact([.value("RAILWAY_PROJECT_ID")], .uuid)
    static let railwayLinks: [LinkTemplate] = [
        LinkTemplate("service", "Service", .web("railway.com"),
                     path: [.text("/project/"), railwayProject, .text("/service/"),
                            .fact([.value("RAILWAY_SERVICE_ID")], .uuid)],
                     query: [QueryPiece("environmentId", [.fact([.value("RAILWAY_ENVIRONMENT_ID")], .uuid)])],
                     badge: "Project"),
        LinkTemplate("project", "Project", .web("railway.com"), path: [.text("/project/"), railwayProject]),
        .web("dashboard", "Dashboard", "railway.com", "/dashboard"),
    ]
    static let railwayValues: [String: KeyRole] = [
        "RAILWAY_PROJECT_ID": .id, "RAILWAY_SERVICE_ID": .id, "RAILWAY_ENVIRONMENT_ID": .id,
    ]
    static let railway = ServiceEntry("railway", "Railway", kind: .hosting, rank: 4, place: .cloud,
                                      signals: [.file("railway.json", .cloud), .file("railway.toml", .cloud),
                                                .key("RAILWAY_PROJECT_ID")],
                                      values: railwayValues, links: railwayLinks)

    /// A service's page needs its kind, which its id does not say, so the dashboard.
    static let render = ServiceEntry("render", "Render", kind: .hosting, rank: 5, place: .cloud,
                                     signals: [.file("render.yaml", .cloud), .key("RENDER_SERVICE_ID")],
                                     links: [.web("dashboard", "Dashboard", "dashboard.render.com")])
}
