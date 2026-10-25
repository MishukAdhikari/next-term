import Foundation
import Testing
@testable import NextTermCore

/// Every link of every row, as text: what a badge, its tooltip, its menu item or the browser could show.
func linkText(_ scan: DatabaseScan) -> String {
    var parts: [String] = []
    for database in scan.databases {
        for link in database.links {
            let fields: [String] = [link.id, link.badge, link.title, link.tooltip, link.url.absoluteString, link.source ?? ""]
            parts.append(fields.joined(separator: "\n"))
        }
    }
    return parts.joined(separator: "\n")
}

/// Each provider badge on a database row opens that provider's page for it, built only from hosts, names and ids the
/// project's files hold. Every project, host, id and secret here is made up.
@Suite struct DatabaseLinksTests {
    /// The one row a fixture should give, with its links checked against the rules every link keeps.
    func onlyRow(_ project: FixtureProject, herd: Bool = false) throws -> DetectedDatabase {
        let scan = project.scan(herd: herd)
        #expect(scan.databases.count == 1, "\(scan.databases.map(\.id))")
        let database = try #require(scan.databases.first)
        expectSafe(scan)
        return database
    }

    /// No link holds a made-up user, password or query value, and each may open.
    func expectSafe(_ scan: DatabaseScan, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = linkText(scan)
        for secret in ["shopuser", "NOT-A-", "sslmode", "api_key", "pgbouncer", "appName", "retryWrites"] {
            #expect(!text.contains(secret), "\(secret) in \(text)", sourceLocation: sourceLocation)
        }
        for database in scan.databases {
            #expect(database.links.count == database.providers.count, sourceLocation: sourceLocation)
            for link in database.links {
                #expect(SafeWebLink.isAllowed(link.url), "\(link.url)", sourceLocation: sourceLocation)
            }
        }
    }

    func urls(_ database: DetectedDatabase) -> [String] {
        database.links.map { (link: ServiceLink) -> String in link.url.absoluteString }
    }

    // MARK: Neon and Vercel

    static let neonFromVercel = """
    # Created by Vercel CLI
    DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@ep-cool-dawn-123456-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require
    """

    @Test func neonOpensTheProjectThatDotNeonNames() throws {
        let project = FixtureProject()
        project.write(".env.local", Self.neonFromVercel)
        project.write(".neon", #"{"projectId": "cold-grass-40154007"}"#)
        let database = try onlyRow(project)
        #expect(database.providers == [.neon, .vercel])
        let neon = try #require(database.links.first)
        #expect(neon.badge == "Neon" && neon.title == "Open Neon Console")
        #expect(neon.tooltip == "Open Neon Console: project cold-grass-40154007")
        #expect(neon.url.absoluteString == "https://console.neon.tech/app/projects/cold-grass-40154007")
        #expect(neon.source == ".neon" && neon.id == "neon.console")
        let vercel = try #require(database.links.last)
        #expect(vercel.badge == "Vercel" && vercel.title == "Open Vercel Storage" && vercel.tooltip == "Open Vercel Storage")
        #expect(vercel.url.absoluteString == "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fstores")
        #expect(vercel.source == nil)
    }

    @Test func neonWithoutDotNeonOpensTheProjectList() throws {
        let project = FixtureProject()
        project.write(".env.local", Self.neonFromVercel)
        let neon = try #require(try onlyRow(project).links.first)
        #expect(neon.url.absoluteString == "https://console.neon.tech/app/projects")
        #expect(neon.tooltip == "Open Neon Console" && neon.source == nil)
    }

    @Test func aDotNeonIdThatIsNotANameIsNeverUsed() throws {
        let project = FixtureProject()
        project.write(".env.local", Self.neonFromVercel)
        project.write(".neon", #"{"projectId": "../../settings"}"#)
        let neon = try #require(try onlyRow(project).links.first)
        #expect(neon.url.absoluteString == "https://console.neon.tech/app/projects")
    }

    // MARK: the provider fixes

    @Test func prismaPostgresPooledHostGetsItsBadge() throws {
        let project = FixtureProject()
        project.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@pooled.db.prisma.io:5432/postgres?sslmode=require\n")
        let database = try onlyRow(project)
        #expect(database.providers == [.prismaPostgres])
        #expect(urls(database) == ["https://console.prisma.io"])
        #expect(database.links.first?.title == "Open Prisma Postgres Console")
    }

    @Test func prismaDevOnThisMacGetsNoCloudBadge() throws {
        let project = FixtureProject()
        project.write(".env", "DATABASE_URL=prisma+postgres://localhost:51213/?api_key=NOT-A-KEY\n")
        let database = try onlyRow(project)
        #expect(database.providers.isEmpty && database.links.isEmpty && database.environment == .local)
        let remote = FixtureProject()
        remote.write(".env", "DATABASE_URL=prisma+postgres://accelerate.prisma-data.net/?api_key=NOT-A-KEY\n")
        #expect(try onlyRow(remote).providers == [.prismaPostgres])
        // A remote host of its own gets the badge by the scheme alone.
        let other = FixtureProject()
        other.write(".env", "DATABASE_URL=prisma+postgres://prisma.shop.example.com/?api_key=NOT-A-KEY\n")
        #expect(try urls(onlyRow(other)) == ["https://console.prisma.io"])
    }

    @Test func prismaDevReachedAnyLocalWayGetsNoCloudBadge() throws {
        // Loopback as written any way, and `prisma dev` reached from a container: Docker's name or a Compose service.
        let hosts = ["LOCALHOST:51213", "127.0.0.1:51213", "[::1]:51213", "host.docker.internal:51213", "db:51213"]
        for host in hosts {
            let project = FixtureProject()
            project.write(".env", "DATABASE_URL=prisma+postgres://\(host)/?api_key=NOT-A-KEY\n")
            let database = try onlyRow(project)
            #expect(database.providers.isEmpty && database.links.isEmpty, "\(host)")
            #expect(database.environment != .remote, "\(host)")
        }
    }

    @Test func legacyVercelPostgresIsNeonAndVercel() throws {
        let project = FixtureProject()
        project.write(".env", """
        POSTGRES_URL=postgres://shopuser:NOT-A-PASSWORD@ep-x-pooler.us-east-1.postgres.vercel-storage.com/verceldb?sslmode=require
        POSTGRES_URL_NON_POOLING=postgres://shopuser:NOT-A-PASSWORD@ep-x.us-east-1.postgres.vercel-storage.com/verceldb?sslmode=require
        """)
        let database = try onlyRow(project)
        #expect(database.providers == [.neon, .vercel] && database.hasPooledAndDirect)
        #expect(database.links.map(\.badge) == ["Neon", "Vercel"])
        #expect(database.links.first?.url.absoluteString == "https://console.neon.tech/app/projects")
        // Under the Vercel CLI's header, which names Vercel too: still one Vercel badge.
        let pulled = FixtureProject()
        pulled.write(".env.local", "# Created by Vercel CLI\n"
            + "POSTGRES_URL=postgres://shopuser:NOT-A-PASSWORD@ep-x-pooler.us-east-1.postgres.vercel-storage.com/verceldb\n")
        #expect(try onlyRow(pulled).links.map(\.badge) == ["Neon", "Vercel"])
    }

    @Test func renderPostgresOpensItsDatabase() throws {
        let project = FixtureProject()
        project.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@dpg-abcdefghijklmnopqrst-a.oregon-postgres.render.com/shop\n")
        let database = try onlyRow(project)
        #expect(database.providers == [.render])
        let render = try #require(database.links.first)
        #expect(render.url.absoluteString == "https://dashboard.render.com/d/dpg-abcdefghijklmnopqrst-a")
        #expect(render.title == "Open Render Dashboard")
        #expect(render.tooltip == "Open Render Dashboard: database dpg-abcdefghijklmnopqrst-a")
        let inside = FixtureProject()
        inside.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@dpg-abcdefghijklmnopqrst-a/shop\n")
        #expect(try onlyRow(inside).providers == [.render])
        // Render's form under someone else's domain is not Render's.
        let elsewhere = FixtureProject()
        elsewhere.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@dpg-abcdefghijklmnopqrst-a.example.com/shop\n")
        #expect(try onlyRow(elsewhere).providers.isEmpty)
    }

    // MARK: Supabase

    static let supabaseRef = "abcdefghijklmnopqrst"

    @Test func supabaseDirectHostOpensItsProject() throws {
        let project = FixtureProject()
        project.write(".env", "DATABASE_URL=postgresql://postgres:NOT-A-PASSWORD@db.abcdefghijklmnopqrst.supabase.co:5432/postgres\n")
        let database = try onlyRow(project)
        let link = try #require(database.links.first)
        #expect(database.providers == [.supabase])
        #expect(link.url.absoluteString == "https://supabase.com/dashboard/project/abcdefghijklmnopqrst")
        #expect(link.title == "Open Supabase Dashboard" && link.badge == "Supabase")
        #expect(link.tooltip == "Open Supabase Dashboard: project abcdefghijklmnopqrst" && link.source == ".env")
    }

    @Test func aPoolerUserNameNeverGivesTheRef() throws {
        let project = FixtureProject()
        project.write(".env", """
        DATABASE_URL=postgresql://postgres.abcdefghijklmnopqrst:NOT-A-PASSWORD@aws-0-eu-west-1.pooler.supabase.com:6543/postgres
        """)
        // A local project name in config.toml is not the ref, even when it looks like one.
        project.write("supabase/config.toml", "project_id = \"zyxwvutsrqponmlkjihg\"\n")
        let database = try onlyRow(project)
        #expect(database.user == "postgres.abcdefghijklmnopqrst")
        #expect(urls(database) == ["https://supabase.com/dashboard/project/_"])
        #expect(database.links.first?.tooltip == "Open Supabase Dashboard")
        #expect(!linkText(project.scan()).contains(Self.supabaseRef) && !linkText(project.scan()).contains("zyxwvu"))
    }

    @Test func supabaseRefFromTheLinkedProjectOrTheAPIURL() throws {
        let pooler = "DATABASE_URL=postgresql://postgres.abcdefghijklmnopqrst:NOT-A-PASSWORD@aws-0-eu-west-1.pooler.supabase.com:6543/postgres\n"
        let linked = FixtureProject()
        linked.write(".env", pooler)
        linked.write("supabase/.temp/project-ref", "klmnopqrstabcdefghij\n")
        let fromLink = try #require(try onlyRow(linked).links.first)
        #expect(fromLink.url.absoluteString == "https://supabase.com/dashboard/project/klmnopqrstabcdefghij")
        #expect(fromLink.source == "supabase/.temp/project-ref")
        let byID = FixtureProject()
        byID.write(".env", pooler + "SUPABASE_PROJECT_ID=bcdefghijklmnopqrsta\n")
        #expect(try urls(onlyRow(byID)) == ["https://supabase.com/dashboard/project/bcdefghijklmnopqrsta"])
        let byURL = FixtureProject()
        byURL.write(".env", pooler + "NEXT_PUBLIC_SUPABASE_URL=https://cdefghijklmnopqrstab.supabase.co\n")
        #expect(try urls(onlyRow(byURL)) == ["https://supabase.com/dashboard/project/cdefghijklmnopqrstab"])
        // Not 20 letters: no ref.
        let short = FixtureProject()
        short.write(".env", pooler + "SUPABASE_PROJECT_ID=abcdefghijklmnop\n")
        #expect(try urls(onlyRow(short)) == ["https://supabase.com/dashboard/project/_"])
    }

    @Test func localSupabaseOpensStudioOnItsPort() throws {
        let project = FixtureProject()
        project.write("supabase/config.toml", """
        project_id = "shop"

        [db]
        port = 54322

        [studio]
        enabled = true
        port = 54423
        """)
        let database = try onlyRow(project)
        #expect(database.environment == .local && database.providers == [.supabase])
        let studio = try #require(database.links.first)
        #expect(studio.url.absoluteString == "http://127.0.0.1:54423" && studio.title == "Open Supabase Studio")
        #expect(studio.tooltip == "Open Supabase Studio at 127.0.0.1:54423 (from supabase/config.toml)")
        #expect(studio.source == "supabase/config.toml" && studio.id == "supabase.studio")
        let plain = FixtureProject()
        plain.write("supabase/config.toml", "[db]\nport = 54322\n")
        let fallback = try #require(try onlyRow(plain).links.first)
        #expect(fallback.url.absoluteString == "http://127.0.0.1:54323")
        #expect(fallback.tooltip == "Open Supabase Studio at 127.0.0.1:54323 (default port)" && fallback.source == nil)
        // A linked cloud project does not move the local stack's link to the cloud.
        project.write("supabase/.temp/project-ref", "klmnopqrstabcdefghij\n")
        let linked = try #require(try onlyRow(project).links.first)
        #expect(linked.url.absoluteString == "http://127.0.0.1:54423" && linked.id == "supabase.studio")
    }

    // MARK: Herd

    static func laravel(appURL: String, extra: String = "") -> String {
        "APP_NAME=Shop\nAPP_URL=\(appURL)\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=shop\n" + extra
    }

    @Test func herdOpensTheSiteItServes() throws {
        let project = FixtureProject()
        project.write("artisan", "#!/usr/bin/env php\n")
        project.write(".env", Self.laravel(appURL: "https://shop.test"))
        let database = try onlyRow(project, herd: true)
        #expect(database.providers == [.herd])
        let herd = try #require(database.links.first)
        #expect(herd.url.absoluteString == "https://shop.test" && herd.badge == "Herd")
        #expect(herd.tooltip == "Open shop.test, the site Herd serves" && herd.title == "Open Herd Site")
        #expect(herd.source == ".env" && herd.id == "herd.site")
        let plain = FixtureProject()
        plain.write(".env", Self.laravel(appURL: "http://shop.test:8080"))
        let local = try #require(try onlyRow(plain, herd: true).links.first)
        #expect(local.url.absoluteString == "http://shop.test:8080")
        #expect(local.tooltip == "Open shop.test:8080, the site Herd serves")
    }

    @Test func herdNeverOpensAnAppURLWithAUserOrPassword() throws {
        let project = FixtureProject()
        project.write("artisan", "#!/usr/bin/env php\n")
        project.write(".env", Self.laravel(appURL: "http://admin:NOT-A-PASSWORD@shop.test"))
        let scan = project.scan(herd: true)
        let database = try onlyRow(project, herd: true)
        #expect(database.providers == [.herd])
        let docs = try #require(database.links.first)
        #expect(docs.url.absoluteString == "https://herd.laravel.com/docs/macos/herd-pro-services/services")
        #expect(docs.title == "Open Herd Services Docs" && docs.tooltip == "Open Herd Services Docs")
        #expect(!visibleText(scan).contains("admin") && !visibleText(scan).contains("NOT-A-PASSWORD"))
        // herd.yml names the site when APP_URL cannot.
        project.write("herd.yml", "name: shop\nsecured: true\nphp: 8.4\n")
        let site = try #require(try onlyRow(project, herd: true).links.first)
        #expect(site.url.absoluteString == "https://shop.test" && site.source == "herd.yml")
        #expect(site.tooltip == "Open shop.test, the site Herd serves")
    }

    @Test func herdYAMLWithoutSecuredIsPlainHTTP() throws {
        let project = FixtureProject()
        project.write(".env", "DB_CONNECTION=mysql\nDB_SOCKET=/opt/Herd/mysql.sock\nDB_DATABASE=shop\n")
        project.write("herd.yml", "name: Shop\n")
        let database = try onlyRow(project, herd: true)
        #expect(database.providers == [.herd])
        #expect(urls(database) == ["http://shop.test"])
        for quoted in ["name: 'shop'\n", "name: \"shop\"\nsecured: true\n"] {
            project.write("herd.yml", quoted)
            let site = try #require(try onlyRow(project, herd: true).links.first)
            #expect(site.url.host == "shop.test" && site.source == "herd.yml", "\(quoted)")
        }
    }

    @Test func herdWithAnAppURLOffTestAndNoHerdYAMLOpensItsDocs() throws {
        let project = FixtureProject()
        project.write(".env", "APP_URL=http://localhost:8000\nDB_CONNECTION=mysql\nDB_SOCKET=/opt/Herd/mysql.sock\nDB_DATABASE=shop\n")
        let database = try onlyRow(project, herd: true)
        #expect(database.providers == [.herd])
        #expect(urls(database) == ["https://herd.laravel.com/docs/macos/herd-pro-services/services"])
    }

    // MARK: Fly.io and Railway

    @Test func flyPrivateHostsOpenTheDatabasesOwnApp() throws {
        // The host names the app the database runs as; fly.toml's app is the web app beside it.
        let hosts = ["shop-db.flycast", "shop-db.internal", "top2.nearest.of.shop-db.internal", "fra.shop-db.internal"]
        for host in hosts {
            let project = FixtureProject()
            project.write("fly.toml", "app = \"shop-api\"\nprimary_region = \"ams\"\n")
            project.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@\(host):5432/shop\n")
            let database = try onlyRow(project)
            #expect(database.providers == [.fly], "\(host)")
            let fly = try #require(database.links.first)
            #expect(fly.url.absoluteString == "https://fly.io/apps/shop-db" && fly.source == ".env", "\(host)")
            #expect(fly.title == "Open Fly.io App" && fly.tooltip == "Open Fly.io App: shop-db" && fly.badge == "Fly.io")
        }
        // A host that names no app: fly.toml's.
        let project = FixtureProject()
        project.write("fly.toml", "app = \"shop-api\"\n")
        project.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@_apps.internal:5432/shop\n")
        let fly = try #require(try onlyRow(project).links.first)
        #expect(fly.url.absoluteString == "https://fly.io/apps/shop-api" && fly.source == "fly.toml")
        #expect(fly.tooltip == "Open Fly.io App: shop-api")
    }

    @Test func dotInternalIsFlyOnlyWithFlyToml() throws {
        let bare = FixtureProject()
        bare.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@db.internal:5432/shop\n")
        #expect(try onlyRow(bare).providers.isEmpty)
        let docker = FixtureProject()
        docker.write("fly.toml", "app = \"shop-api\"\n")
        docker.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@host.docker.internal:5432/shop\n")
        #expect(try onlyRow(docker).providers.isEmpty)
        let railway = FixtureProject()
        railway.write("fly.toml", "app = \"shop-api\"\n")
        railway.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@postgres.railway.internal:5432/railway\n")
        #expect(try onlyRow(railway).providers == [.railway])
        let flycast = FixtureProject()
        flycast.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@shop-db.flycast:5432/shop\n")
        #expect(try urls(onlyRow(flycast)) == ["https://fly.io/apps/shop-db"])
        let managed = FixtureProject()
        managed.write("fly.toml", "app = \"shop-api\"\n")
        managed.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@pgbouncer.abc123.flympg.net/shop\n")
        let fly = try #require(try onlyRow(managed).links.first)
        #expect(fly.url.absoluteString == "https://fly.io/dashboard" && fly.title == "Open Fly.io Dashboard")
    }

    @Test func railwayOpensAsDeepAsItsIdsGo() throws {
        let url = "DATABASE_URL=postgresql://shopuser:NOT-A-PASSWORD@shuttle.proxy.rlwy.net:12345/railway\n"
        let project = "RAILWAY_PROJECT_ID=0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b\n"
        let service = "RAILWAY_SERVICE_ID=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d\n"
        let environment = "RAILWAY_ENVIRONMENT_ID=2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e\n"
        let bare = FixtureProject()
        bare.write(".env", url)
        let home = try #require(try onlyRow(bare).links.first)
        #expect(home.url.absoluteString == "https://railway.com/dashboard" && home.title == "Open Railway Dashboard")
        let byProject = FixtureProject()
        byProject.write(".env", url + project)
        let projectLink = try #require(try onlyRow(byProject).links.first)
        #expect(projectLink.url.absoluteString == "https://railway.com/project/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b")
        #expect(projectLink.title == "Open Railway Project" && projectLink.source == ".env")
        let byService = FixtureProject()
        byService.write(".env", url + project + service + environment)
        let serviceLink = try #require(try onlyRow(byService).links.first)
        let expected = "https://railway.com/project/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b/service/"
            + "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d?environmentId=2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e"
        #expect(serviceLink.url.absoluteString == expected && serviceLink.title == "Open Railway Service")
    }

    // MARK: AWS, Atlas, PlanetScale

    func awsLink(_ host: String) throws -> ServiceLink? {
        let project = FixtureProject()
        project.write(".env", "DB_CONNECTION=mysql\nDB_HOST=\(host)\nDB_DATABASE=shop\nDB_USERNAME=shopuser\nDB_PASSWORD=NOT-A-PASSWORD\n")
        return try onlyRow(project).links.first
    }

    @Test func awsOpensTheInstanceOrTheCluster() throws {
        let instance = try #require(try awsLink("shop.abc123def456.eu-west-1.rds.amazonaws.com"))
        let instanceURL = "https://eu-west-1.console.aws.amazon.com/rds/home?region=eu-west-1#database:id=shop;is-cluster=false"
        #expect(instance.url.absoluteString == instanceURL && instance.badge == "AWS")
        #expect(instance.title == "Open AWS RDS Console")
        #expect(instance.tooltip == "Open AWS RDS Console: database shop in eu-west-1")
        let cluster = try #require(try awsLink("shop.cluster-abc123def456.us-east-2.rds.amazonaws.com"))
        let clusterURL = "https://us-east-2.console.aws.amazon.com/rds/home?region=us-east-2#database:id=shop;is-cluster=true"
        #expect(cluster.url.absoluteString == clusterURL)
        #expect(cluster.tooltip == "Open AWS RDS Console: cluster shop in us-east-2")
        let reader = try #require(try awsLink("shop.cluster-ro-abc123def456.us-east-1.rds.amazonaws.com"))
        #expect(reader.url.absoluteString.hasSuffix("#database:id=shop;is-cluster=true"))
        // Another partition: no badge, so no link.
        #expect(try awsLink("shop.abc123def456.cn-north-1.rds.amazonaws.com.cn") == nil)
    }

    @Test func awsEndpointsThatNameNoDatabaseOpenTheRegionsList() throws {
        // A proxy's, a proxy endpoint's and an Aurora custom endpoint's names are not a database's id.
        let hosts = ["shop-proxy.proxy-abc123def456.us-east-1.rds.amazonaws.com",
                     "shop-reader.endpoint.proxy-abc123def456.us-east-1.rds.amazonaws.com",
                     "reporting.cluster-custom-abc123def456.us-east-1.rds.amazonaws.com"]
        for host in hosts {
            let link = try #require(try awsLink(host))
            let list = "https://us-east-1.console.aws.amazon.com/rds/home?region=us-east-1#databases:"
            #expect(link.url.absoluteString == list, "\(host)")
            #expect(link.tooltip == "Open AWS RDS Console: us-east-1" && link.source == nil, "\(host)")
        }
    }

    @Test func awsGovCloudOpensItsOwnConsole() throws {
        let cluster = try #require(try awsLink("shop.cluster-abc123def456.us-gov-west-1.rds.amazonaws.com"))
        let clusterURL = "https://console.amazonaws-us-gov.com/rds/home?region=us-gov-west-1#database:id=shop;is-cluster=true"
        #expect(cluster.url.absoluteString == clusterURL)
        #expect(cluster.tooltip == "Open AWS RDS Console: cluster shop in us-gov-west-1")
        let proxy = try #require(try awsLink("shop-proxy.proxy-abc123def456.us-gov-east-1.rds.amazonaws.com"))
        #expect(proxy.url.absoluteString == "https://console.amazonaws-us-gov.com/rds/home?region=us-gov-east-1#databases:")
    }

    @Test func atlasOpensTheProjectItsIdNames() throws {
        let mongo = "MONGODB_URI=mongodb+srv://shopuser:NOT-A-PASSWORD@cluster0.ab1cd.mongodb.net/?retryWrites=true&appName=Cluster0\n"
        let project = FixtureProject()
        project.write(".env", mongo + "MONGODB_ATLAS_PROJECT_ID=0123456789abcdef01234567\n")
        let atlas = try #require(try onlyRow(project).links.first)
        #expect(atlas.url.absoluteString == "https://cloud.mongodb.com/v2/0123456789abcdef01234567#/clusters")
        #expect(atlas.tooltip == "Open MongoDB Atlas Console: project 0123456789abcdef01234567")
        #expect(atlas.source == ".env" && atlas.badge == "MongoDB Atlas")
        let short = FixtureProject()
        short.write(".env", mongo + "MONGODB_ATLAS_PROJECT_ID=0123456789abcdef0123456\n")
        let home = try #require(try onlyRow(short).links.first)
        #expect(home.url.absoluteString == "https://cloud.mongodb.com/" && home.tooltip == "Open MongoDB Atlas Console")
    }

    @Test func planetScaleOpensTheDatabaseItsFileNames() throws {
        let url = "DATABASE_URL=mysql://shopuser:NOT-A-PASSWORD@aws.connect.psdb.cloud/shop?sslaccept=strict\n"
        let project = FixtureProject()
        project.write(".env", url)
        project.write(".pscale.yml", "org: acme\ndatabase: shop\nbranch: main\n")
        let link = try #require(try onlyRow(project).links.first)
        #expect(link.url.absoluteString == "https://app.planetscale.com/acme/shop" && link.source == ".pscale.yml")
        #expect(link.tooltip == "Open PlanetScale Dashboard: database acme/shop")
        let bare = FixtureProject()
        bare.write(".env", url)
        #expect(try urls(onlyRow(bare)) == ["https://app.planetscale.com/"])
    }

    // MARK: providers with one page

    @Test func eachNewHostGetsItsProviderAndPage() throws {
        let cases: [(host: String, provider: DatabaseProvider, url: String)] = [
            ("acme-db.turso.io", .turso, "https://app.turso.tech"),
            ("free-tier.gcp-us-central1.cockroachlabs.cloud", .cockroach, "https://cockroachlabs.cloud/clusters"),
            ("db-postgresql-nyc3-12345-do-user-1-0.b.db.ondigitalocean.com", .digitalOcean,
             "https://cloud.digitalocean.com/databases"),
            ("shop.postgres.database.azure.com", .azure,
             "https://portal.azure.com/#browse/Microsoft.DBforPostgreSQL%2FflexibleServers"),
            ("shop.mysql.database.azure.com", .azure, "https://portal.azure.com/#browse/Microsoft.DBforMySQL%2FflexibleServers"),
            ("shop.database.windows.net", .azure, "https://portal.azure.com/#browse/Microsoft.Sql%2Fservers%2Fdatabases"),
            ("roundhouse.proxy.rlwy.net", .railway, "https://railway.com/dashboard"),
        ]
        for item in cases {
            let project = FixtureProject()
            project.write(".env", "DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@\(item.host):5432/shop\n")
            let database = try onlyRow(project)
            #expect(database.providers == [item.provider], "\(item.host)")
            #expect(urls(database) == [item.url], "\(item.host)")
            #expect(database.links.first?.badge == item.provider.rawValue)
        }
    }

    @Test func everyProviderHasAPageWithNoFactsAtAll() throws {
        let database = DetectedDatabase(
            id: "x", engine: .postgres, name: "shop", host: "db.example.com", port: 5432, user: "shopuser", database: "shop",
            socket: nil, providers: DatabaseProvider.allCases, environment: .remote, masked: "", sources: [], filePath: nil,
            hasPassword: true, isConnection: true, note: nil, tools: [])
        let links = DatabaseLinks.links(for: database, facts: ProjectFacts())
        #expect(links.map(\.badge) == DatabaseProvider.allCases.map(\.rawValue))
        #expect(Set(links.map(\.id)).count == links.count)
        for link in links {
            #expect(SafeWebLink.isAllowed(link.url) && link.url.scheme == "https", "\(link.url)")
            #expect(link.title.hasPrefix("Open ") && link.tooltip.hasPrefix("Open "), "\(link.title)")
        }
        // A badge finds its link by its provider, whatever the place.
        var row = database
        row.links = links.reversed()
        for provider in DatabaseProvider.allCases {
            #expect(row.link(for: provider)?.badge == provider.rawValue, "\(provider)")
        }
        row.links = []
        #expect(row.link(for: .neon) == nil)
    }

    @Test func noKeyTheLinksReadHasASecretsName() {
        for key in DatabaseLinks.valueKeys.keys {
            #expect(!SecretName.isSecret(key), "\(key)")
        }
    }

    // MARK: badges

    @Test func aRowsBadgesAreItsFirstTwoProvidersEachOpeningItsOwnPage() throws {
        let project = FixtureProject()
        project.write(".env.local", Self.neonFromVercel)
        project.write(".neon", #"{"projectId": "cold-grass-40154007"}"#)
        let database = try onlyRow(project)
        let badges = database.badges
        #expect(badges.map(\.word) == ["Neon", "Vercel"])
        #expect(ServiceBadge.text(badges) == "Neon · Vercel")
        #expect(badges.first?.link?.url.absoluteString == "https://console.neon.tech/app/projects/cold-grass-40154007")
        #expect(badges.first?.link?.tooltip == "Open Neon Console: project cold-grass-40154007")
        #expect(badges.last?.link?.url.absoluteString == "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fstores")
        // The row's menu starts with one item per page, in the badges' order.
        #expect(database.links.map(\.title) == ["Open Neon Console", "Open Vercel Storage"])
    }

    @Test func aBadgeWithNoPageIsALabelAndARowShowsTwoAtMost() {
        var row = DetectedDatabase(
            id: "x", engine: .postgres, name: "shop", host: "db.example.com", port: 5432, user: "shopuser", database: "shop",
            socket: nil, providers: [.neon, .vercel, .aws], environment: .remote, masked: "", sources: [], filePath: nil,
            hasPassword: true, isConnection: true, note: nil, tools: [])
        #expect(row.badges.map(\.word) == ["Neon", "Vercel"])
        #expect(row.badges.allSatisfy { (badge: ServiceBadge) -> Bool in badge.link == nil })
        // A badge finds its own provider's page, whatever its place in the links.
        let links = DatabaseLinks.links(for: row, facts: ProjectFacts())
        row.links = links.reversed()
        #expect(row.badges.compactMap(\.link?.badge) == ["Neon", "Vercel"])
        row.links = links.filter { (link: ServiceLink) -> Bool in link.badge != "Neon" }
        #expect(row.badges.map(\.word) == ["Neon", "Vercel"] && row.badges.first?.link == nil)
        let plain = DetectedDatabase(
            id: "y", engine: .sqlite, name: "app.db", host: nil, port: nil, user: nil, database: nil, socket: nil, providers: [],
            environment: .local, masked: "", sources: [], filePath: "/tmp/app.db", hasPassword: false, isConnection: true,
            note: nil, tools: [])
        #expect(plain.badges.isEmpty && ServiceBadge.text(plain.badges).isEmpty)
    }

    @Test func theGroupsVercelBadgeOpensTheTeamsStorage() throws {
        #expect(DatabaseLinks.groupBadges(vercelProject: nil).isEmpty)
        for project in ["shop-web", "linked"] {
            let badges = DatabaseLinks.groupBadges(vercelProject: project)
            #expect(badges.map(\.word) == ["Vercel"], "\(project)")
            let link = try #require(badges.first?.link)
            #expect(link.url.absoluteString == "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fstores")
            #expect(link.title == "Open Vercel Storage" && link.tooltip == "Open Vercel Storage")
            #expect(SafeWebLink.isAllowed(link.url) && !link.tooltip.contains(project))
        }
    }

    // MARK: the facts the scan hands on

    @Test func theScanHandsItsFactsOnWithNoRawValue() throws {
        let project = FixtureProject()
        project.write(".env", """
        DATABASE_URL=postgresql://postgres.abcdefghijklmnopqrst:NOT-A-PASSWORD@aws-0-eu-west-1.pooler.supabase.com:6543/postgres
        NEXT_PUBLIC_SUPABASE_URL=https://cdefghijklmnopqrstab.supabase.co/rest/v1?apikey=NOT-A-KEY
        SUPABASE_SERVICE_ROLE_KEY=NOT-A-KEY-EITHER
        """)
        project.write("package.json", #"{"dependencies": {"@supabase/supabase-js": "2.50.0"}}"#)
        let scan = project.scan()
        #expect(scan.facts.read.contains(".env") && scan.facts.read.contains("package.json"))
        #expect(scan.facts.hasEnvName("SUPABASE_SERVICE_ROLE_KEY"))
        #expect(scan.facts.values("SUPABASE_SERVICE_ROLE_KEY").isEmpty)
        #expect(scan.facts.value("NEXT_PUBLIC_SUPABASE_URL")?.origin?.string == "https://cdefghijklmnopqrstab.supabase.co")
        #expect(scan.facts.dependencyFile("@supabase/supabase-js", in: .npm) == "package.json")
        var dumped = ""
        dump(scan, to: &dumped)
        let printed = [visibleText(scan), dumped].joined(separator: "\n")
        for secret in ["NOT-A-", "rest/v1", "apikey"] {
            #expect(!printed.contains(secret), "\(secret)")
        }
        // Equal scans of an unchanged project, so the sidebar redraws only on a change.
        #expect(project.scan() == scan)
    }

    @Test func aChangeNoDatabaseRowShowsLeavesTheScanEqual() throws {
        let project = FixtureProject()
        project.write(".env.local", Self.neonFromVercel)
        project.write("package.json", #"{"dependencies": {"pg": "8.16.0"}}"#)
        let before = project.scan()
        // A dependency only the Services pass reads: the Databases group has nothing to reload.
        project.write("package.json", #"{"dependencies": {"pg": "8.16.0", "openai": "5.0.0"}}"#)
        let after = project.scan()
        #expect(after.facts != before.facts)
        #expect(after == before)
        // A fact a row's link reads changes the row, so the scan.
        project.write(".neon", #"{"projectId": "cold-grass-40154007"}"#)
        #expect(project.scan() != after)
    }
}
