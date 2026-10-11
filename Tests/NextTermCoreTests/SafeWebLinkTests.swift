import Foundation
import Testing
@testable import NextTermCore

/// Every value here is made up: hosts, ids and keys like NOT-A-KEY.
@Suite struct SafeWebLinkTests {
    @Test func linksThatMayOpen() throws {
        let allowed = ["https://console.neon.tech/app/projects/cold-grass-40154007", "http://localhost:6334/dashboard",
                       "http://127.0.0.1:2024/docs", "http://shop.test", "http://[::1]:8000"]
        for text in allowed {
            let link = try #require(URL(string: text))
            #expect(SafeWebLink.isAllowed(link), "\(text)")
        }
    }

    @Test func linksBuiltFromParts() {
        let neon = SafeWebLink.make(scheme: "https", host: "console.neon.tech",
                                    path: [.fixed("/app/projects/"), .value("cold-grass-40154007", .slug)])
        #expect(neon?.absoluteString == "https://console.neon.tech/app/projects/cold-grass-40154007")
        let qdrant = SafeWebLink.make(scheme: "http", host: "localhost", port: 6334, path: [.fixed("/dashboard")])
        #expect(qdrant?.absoluteString == "http://localhost:6334/dashboard")
        #expect(SafeWebLink.make(scheme: "http", host: "[::1]", port: 8000)?.absoluteString == "http://[::1]:8000")
        #expect(SafeWebLink.make(scheme: "http", host: "::1", port: 8000)?.absoluteString == "http://[::1]:8000")
        #expect(SafeWebLink.make(scheme: "http", host: "shop.test")?.absoluteString == "http://shop.test")
        #expect(SafeWebLink.make(scheme: "HTTPS", host: "Console.Neon.Tech")?.absoluteString == "https://console.neon.tech")
        // What it builds, it allows when opened.
        for link in [neon, qdrant].compactMap({ $0 }) { #expect(SafeWebLink.isAllowed(link)) }
    }

    @Test func linksThatNeverOpen() {
        let refused = ["javascript:alert(1)", "file:///etc/hosts", "ftp://x", "HTTPS://user:pw@x.example.com",
                       "https://x.example.com:0", "https://x.example.com:70000", "https://x .example.com",
                       "https://x%2eexample.com", "http://example.com", "https://x\u{7}y.example.com",
                       "https://\u{043F}\u{0440}\u{0438}\u{043C}\u{0435}\u{0440}.com", "https://xn--e1afmkfd.com",
                       "https://user@x.example.com", "https://:pw@x.example.com", "https://0.0.0.0:3000"]
        for text in refused {
            if let link = URL(string: text) { #expect(!SafeWebLink.isAllowed(link), "\(text)") }
        }
        for text in refused where text != "https://0.0.0.0:3000" {
            #expect(SafeWebLink.origin(of: text) == nil, "\(text)")
        }
    }

    @Test func hostsAndPortsRefusedWhenBuilding() {
        let hosts = ["", "x .example.com", "x%2eexample.com", "x\u{7}y.example.com", "x\ny.example.com",
                     "\u{043F}\u{0440}\u{0438}\u{043C}\u{0435}\u{0440}.com", "xn--e1afmkfd.com", "user@x.example.com",
                     "x.example.com.", "a..example.com", ".example.com", "[::2]", "x.example.com:443", "x.example.com/a",
                     "x_y.example.com"]
        for host in hosts {
            #expect(SafeWebLink.make(scheme: "https", host: host) == nil, "\(host)")
        }
        for scheme in ["javascript", "file", "ftp", "", "data"] {
            #expect(SafeWebLink.make(scheme: scheme, host: "x.example.com") == nil, "\(scheme)")
        }
        for port in [0, -1, 65536, 70000] {
            #expect(SafeWebLink.make(scheme: "https", host: "x.example.com", port: port) == nil, "\(port)")
        }
        #expect(SafeWebLink.make(scheme: "https", host: "x.example.com", port: 65535) != nil)
        #expect(SafeWebLink.make(scheme: "http", host: "example.com") == nil)
    }

    @Test func originsOfProjectValues() throws {
        let qdrant = try #require(SafeWebLink.origin(of: "https://abc.cloud.qdrant.io:6333?api_key=NOT-A-KEY"))
        #expect(qdrant.scheme == "https")
        #expect(qdrant.host == "abc.cloud.qdrant.io")
        #expect(qdrant.port == 6333)
        #expect(qdrant.string == "https://abc.cloud.qdrant.io:6333")
        var dumped = ""
        dump(qdrant, to: &dumped)
        for shown in [String(describing: qdrant), String(reflecting: qdrant), dumped] {
            #expect(!shown.contains("NOT-A-KEY"), "\(shown)")
        }
        let weaviate = try #require(SafeWebLink.origin(of: "abc.weaviate.cloud"))
        #expect(weaviate.string == "https://abc.weaviate.cloud")
        #expect(weaviate.port == nil)
        #expect(SafeWebLink.origin(of: "http://u:p@shop.test") == nil)
        #expect(SafeWebLink.origin(of: "${HOST}") == nil)
        #expect(SafeWebLink.origin(of: "https://cloud.langfuse.com/project/x#y")?.string == "https://cloud.langfuse.com")
        #expect(SafeWebLink.origin(of: "  https://eu.api.smith.langchain.com/api/v1 \n")?.string == "https://eu.api.smith.langchain.com")
        for text in ["", "   ", "https://$HOST.example.com", "https://${HOST}", "$(hostname)", "`hostname`",
                     "https://x.example.com/`id`", "db://my-table", "mailto:x@example.com",
                     "https://x.example.com:6333:1"] {
            #expect(SafeWebLink.origin(of: text) == nil, "\(text)")
        }
    }

    @Test func hostsAreLowerCasedAndPlainHTTPStaysOnThisMac() throws {
        #expect(SafeWebLink.origin(of: "HTTPS://ABC.Cloud.Qdrant.IO:6333")?.host == "abc.cloud.qdrant.io")
        #expect(SafeWebLink.origin(of: "http://shop.test.") == nil)
        let any = try #require(SafeWebLink.origin(of: "http://0.0.0.0:3000"))
        #expect(any.string == "http://localhost:3000")
        #expect(any.link()?.absoluteString == "http://localhost:3000")
        #expect(SafeWebLink.make(scheme: "http", host: "0.0.0.0", port: 3000)?.absoluteString == "http://localhost:3000")
        for host in ["abc.orb.local", "shop.ddev.site"] {
            #expect(SafeWebLink.origin(of: "http://\(host)") == nil, "\(host)")
            #expect(SafeWebLink.make(scheme: "http", host: host) == nil, "\(host)")
            #expect(SafeWebLink.origin(of: "https://\(host)")?.string == "https://\(host)")
            #expect(SafeWebLink.make(scheme: "https", host: host)?.absoluteString == "https://\(host)")
        }
        #expect(SafeWebLink.make(scheme: "http", host: "app.localhost", port: 5173)?.absoluteString == "http://app.localhost:5173")
        #expect(SafeWebLink.make(scheme: "http", host: "127.0.0.2")?.absoluteString == "http://127.0.0.2")
    }

    /// A Compose service's name in a URL (`http://qdrant:6333`) is read as an address, for its published port; it is
    /// never a link itself, since plain http goes only to this Mac.
    @Test func anAddressKeepsAComposeServiceName() throws {
        let qdrant = try #require(SafeWebLink.address(of: "http://qdrant:6333"))
        #expect(qdrant.host == "qdrant")
        #expect(qdrant.port == 6333)
        #expect(qdrant.link() == nil)
        #expect(SafeWebLink.origin(of: "http://qdrant:6333") == nil)
        #expect(SafeWebLink.address(of: "http://u:p@qdrant:6333") == nil)
        #expect(SafeWebLink.address(of: "file:///srv/qdrant") == nil)
    }

    @Test func placeholdersMatchTheirPattern() {
        #expect(SafeWebLink.Placeholder.supabaseRef.accepts("abcdefghijklmnopqrst"))
        #expect(!SafeWebLink.Placeholder.supabaseRef.accepts("abcdefghijklmnopqrs"))
        #expect(!SafeWebLink.Placeholder.supabaseRef.accepts("Abcdefghijklmnopqrst"))
        #expect(SafeWebLink.Placeholder.triggerRef.accepts("proj_abc"))
        #expect(!SafeWebLink.Placeholder.triggerRef.accepts("proj_ABC/../x"))
        #expect(SafeWebLink.Placeholder.awsRegion.accepts("us-east-1"))
        #expect(SafeWebLink.Placeholder.awsRegion.accepts("us-gov-west-1"))
        #expect(!SafeWebLink.Placeholder.awsRegion.accepts("us-east-1/../"))
        #expect(!SafeWebLink.Placeholder.awsRegion.accepts("us-east-\u{0661}"))
        #expect(SafeWebLink.Placeholder.gcpProject.accepts("shop-web-123"))
        #expect(!SafeWebLink.Placeholder.gcpProject.accepts("1shop"))
        #expect(!SafeWebLink.Placeholder.gcpProject.accepts("shop-"))
        #expect(SafeWebLink.Placeholder.atlasProject.accepts("0123456789abcdef01234567"))
        #expect(!SafeWebLink.Placeholder.atlasProject.accepts("0123456789abcdef0123456"))
        #expect(SafeWebLink.Placeholder.uuid.accepts("123e4567-e89b-42d3-a456-426614174000"))
        #expect(!SafeWebLink.Placeholder.uuid.accepts("123e4567e89b42d3a456426614174000"))
        #expect(SafeWebLink.Placeholder.slug.accepts("cold-grass-40154007"))
        #expect(!SafeWebLink.Placeholder.slug.accepts("Cold-grass"))
        #expect(SafeWebLink.Placeholder.name.accepts("My App"))
        #expect(SafeWebLink.Placeholder.digits.accepts("42"))
        #expect(!SafeWebLink.Placeholder.digits.accepts("\u{0664}\u{0662}"))
        for placeholder in SafeWebLink.Placeholder.allCases {
            for value in ["a/b", "a?b", "a#b", "a%2Fb", "a\nb", "", ".", "..", "a\u{301}"] {
                #expect(!placeholder.accepts(value), "\(placeholder) took \(value)")
            }
        }
    }

    @Test func valuesAreEncodedIntoThePath() {
        let logs: [SafeWebLink.Part] = [.fixed("/app/"), .value("acme", .name), .fixed("/p/"), .value("My App", .name), .fixed("/logs")]
        let braintrust = SafeWebLink.make(scheme: "https", host: "www.braintrust.dev", path: logs)
        #expect(braintrust?.absoluteString == "https://www.braintrust.dev/app/acme/p/My%20App/logs")
        #expect(SafeWebLink.make(scheme: "https", host: "app.phoenix.arize.com", path: [.fixed("/s/"), .value("team/x", .slug)]) == nil)
        for project in [".", ".."] {
            let path: [SafeWebLink.Part] = [.fixed("/app/acme/p/"), .value(project, .name), .fixed("/logs")]
            #expect(SafeWebLink.make(scheme: "https", host: "www.braintrust.dev", path: path) == nil, "\(project)")
        }
        // The template's own text cannot move a value out of the path, nor point it elsewhere.
        for fixed in ["/a?b", "/a#b", "/a b", "@evil.example.com", "a", "/a/../b"] {
            #expect(SafeWebLink.make(scheme: "https", host: "x.example.com", path: [.fixed(fixed)]) == nil, "\(fixed)")
        }
    }

    @Test func queriesAndFragmentsComeFromTheTemplate() throws {
        let local = try #require(SafeWebLink.origin(of: "http://127.0.0.1:2100"))
        let studio = SafeWebLink.make(scheme: "https", host: "smith.langchain.com", path: [.fixed("/studio/")],
                                      query: [.init("baseUrl", .origin(local))])
        #expect(studio?.absoluteString == "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2100")
        let fragment: [SafeWebLink.Part] = [.fixed("database:id="), .value("orders-db", .slug), .fixed(";is-cluster=false")]
        let rds = SafeWebLink.make(scheme: "https", host: "us-east-1.console.aws.amazon.com", path: [.fixed("/rds/home")],
                                   query: [.init("region", .value("us-east-1", .awsRegion))], fragment: fragment)
        #expect(rds?.absoluteString == "https://us-east-1.console.aws.amazon.com/rds/home?region=us-east-1#database:id=orders-db;is-cluster=false")
        let mlflow = SafeWebLink.make(scheme: "http", host: "127.0.0.1", port: 5000, path: [.fixed("/")],
                                      fragment: [.fixed("/experiments/"), .value("12", .digits)])
        #expect(mlflow?.absoluteString == "http://127.0.0.1:5000/#/experiments/12")
        let named = SafeWebLink.make(scheme: "https", host: "x.example.com", query: [.init("project", .value("My App", .name))])
        #expect(named?.absoluteString == "https://x.example.com?project=My%20App")
        #expect(SafeWebLink.make(scheme: "https", host: "x.example.com", query: [.init("a&b", .fixed("c"))]) == nil)
        #expect(SafeWebLink.make(scheme: "https", host: "x.example.com", fragment: [.fixed("a#b")]) == nil)
        for link in [studio, rds, mlflow, named].compactMap({ $0 }) { #expect(SafeWebLink.isAllowed(link), "\(link)") }
    }

    @Test func aFinishedLinkNeverLeavesItsPath() throws {
        for text in ["https://x.example.com/a/../b", "https://x.example.com/a/%2e%2e/b", "https://x.example.com/./a",
                     "https://x.example.com/a/%2E"] {
            #expect(!SafeWebLink.isAllowed(try #require(URL(string: text))), "\(text)")
        }
    }

    @Test func valuesThatNameOtherValues() {
        for value in ["https://x.example.com", "6333", "support-bot", "price $5", "a$"] {
            #expect(SafeWebLink.isLiteral(value), "\(value)")
        }
        for value in ["$HOST", "${HOST}", "https://${HOST}:6333", "$(hostname)", "`hostname`", "a$_b"] {
            #expect(!SafeWebLink.isLiteral(value), "\(value)")
        }
    }
}

@Suite struct SecretNameTests {
    @Test func namesWhoseValuesAreNeverRead() {
        let secret = ["OPENAI_API_KEY", "LANGFUSE_PUBLIC_KEY", "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "KV_REST_API_TOKEN",
                      "MLFLOW_TRACKING_PASSWORD", "OTEL_EXPORTER_OTLP_HEADERS", "SENTRY_DSN", "EDGE_CONFIG", "MILVUS_TOKEN",
                      "DB_PASS", "GPG_PASSPHRASE", "REDIS_PASS", "SMTP_PWD", "GOOGLE_APPLICATION_CREDENTIALS", "AUTH_URL",
                      "SESSION_COOKIE", "JWT_PRIVATE", "SIGNING_URL", "x-api-key", "app.secret", "BLOB_READ_WRITE_TOKEN",
                      "CONVEX_DEPLOY_KEY", "NEXT_PUBLIC_EDGE_CONFIG", "openai_apikey", "sessionCookie", "dbPass", "DBPass"]
        for name in secret { #expect(SecretName.isSecret(name), "\(name)") }
    }

    @Test func namesThatMayHaveTheirValueRead() {
        let plain = ["QDRANT_URL", "LANGSMITH_PROJECT", "WANDB_ENTITY", "AWS_REGION", "KEYCLOAK_URL", "MONKEY_PORT",
                     "LANGSMITH_ENDPOINT", "LANGFUSE_HOST", "MLFLOW_TRACKING_URI", "SUPABASE_PROJECT_ID", "CONVEX_DEPLOYMENT",
                     "TEMPORAL_ADDRESS", "FLASK_RUN_PORT", "NEXTAUTH_URL", "OPIK_WORKSPACE", "BRAINTRUST_ORG_NAME", "projectId",
                     "AUTHOR_NAME", "PASSENGER_PORT", ""]
        for name in plain { #expect(!SecretName.isSecret(name), "\(name)") }
    }

    /// MCP's redaction looks for these words anywhere in a name; every name it masks is secret here too.
    @Test func everyNameMCPMasksIsSecret() {
        let names = ["MYSECRETVALUE", "githubTokens", "apiKey", "AccessKeyId", "privatekey", "credentialsFile", "DBPASSWD",
                     "SMTP_PASSPHRASE2", "TOKEN2", "client_secret"]
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            #expect(MCPRedaction.secretWord.firstMatch(in: name, range: range) != nil, "\(name)")
            #expect(SecretName.isSecret(name), "\(name)")
        }
    }

    @Test func segments() {
        #expect(SecretName.segments(of: "NEXT_PUBLIC_SUPABASE_URL") == ["NEXT", "PUBLIC", "SUPABASE", "URL"])
        #expect(SecretName.segments(of: "apiPort") == ["API", "PORT"])
        #expect(SecretName.segments(of: "DBPass") == ["DB", "PASS"])
        #expect(SecretName.segments(of: "x-api.key") == ["X", "API", "KEY"])
        #expect(SecretName.segments(of: "__A__") == ["A"])
    }
}
