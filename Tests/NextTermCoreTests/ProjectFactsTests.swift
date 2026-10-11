import Foundation
import Testing
@testable import NextTermCore

/// Everything a printed `ProjectFacts` shows, by every road a log or the self-test could print it.
func printed(_ facts: ProjectFacts) -> String {
    var dumped = ""
    dump(facts, to: &dumped)
    var factsDumped = ""
    dump(facts.envValues, to: &factsDumped)
    let parts: [String] = [String(describing: facts), String(reflecting: facts), dumped, factsDumped,
                           String(describing: facts.envValues), String(reflecting: facts.envValues)]
    return parts.joined(separator: "\n")
}

/// The project files the service scan reads: env key names, the values the catalog allows, manifests, Compose, start
/// commands and tool configs. Every project, key and value here is made up; values like NOT-A-KEY must never come
/// back out.
@Suite struct ProjectFactsTests {
    static let valueKeys: [String: KeyRole] = [
        "QDRANT_URL": .url, "MLFLOW_TRACKING_URI": .url, "LANCEDB_URI": .url, "LANGFUSE_HOST": .url,
        "CHROMA_HOST": .host, "FLASK_RUN_PORT": .port, "PHOENIX_PORT": .port, "LANGSMITH_PROJECT": .name,
        "BRAINTRUST_DEFAULT_PROJECT": .name, "AWS_REGION": .region, "RAILWAY_PROJECT_ID": .id,
        // Asked for by mistake: a secret's value is never read, whatever the caller says.
        "OPENAI_API_KEY": .url, "LANGFUSE_PUBLIC_KEY": .name, "DB_PASSWORD": .port,
    ]

    static let startWords = ["next dev", "langgraph dev", "uvicorn", "manage.py runserver", "temporal server start-dev",
                             "streamlit run", "rails server", "mlflow server"]

    func read(_ project: FixtureProject, markers: [String] = []) -> ProjectFacts {
        ProjectFacts.read(root: project.root, valueKeys: Self.valueKeys, startWords: Self.startWords, markerFiles: markers)
    }

    // MARK: env files

    @Test func aSecretIsNamedButItsValueIsNeverRead() throws {
        let project = FixtureProject()
        project.write(".env", """
        OPENAI_API_KEY=sk-test-NOT-A-KEY
        LANGFUSE_PUBLIC_KEY=pk-lf-NOT-A-KEY
        DB_PASSWORD=31337
        QDRANT_URL=http://qdrant:6333
        LANGSMITH_PROJECT=support-bot
        """)
        let facts = read(project)
        #expect(facts.envNames == [EnvNames(file: ".env", names: ["OPENAI_API_KEY", "LANGFUSE_PUBLIC_KEY", "DB_PASSWORD",
                                                                   "QDRANT_URL", "LANGSMITH_PROJECT"])])
        #expect(facts.hasEnvName("OPENAI_API_KEY"))
        #expect(facts.values("OPENAI_API_KEY").isEmpty)
        #expect(facts.values("LANGFUSE_PUBLIC_KEY").isEmpty)
        #expect(facts.values("DB_PASSWORD").isEmpty)
        let qdrant = try #require(SafeWebLink.Origin(scheme: "http", host: "qdrant", port: 6333))
        #expect(facts.value("QDRANT_URL") == ServiceFact(file: ".env", key: "QDRANT_URL", role: .url, value: .origin(qdrant)))
        #expect(facts.value("LANGSMITH_PROJECT")?.value == .text("support-bot"))
        let text = printed(facts)
        for secret in ["NOT-A-KEY", "sk-test", "31337", "support-bot", "qdrant:6333"] {
            #expect(!text.contains(secret), "\(secret)")
        }
        #expect(text.contains("QDRANT_URL"))
    }

    @Test func aURLIsCutToItsOrigin() throws {
        let project = FixtureProject()
        project.write(".env", """
        QDRANT_URL=https://abc.cloud.qdrant.io:6333?api_key=NOT-A-KEY
        MLFLOW_TRACKING_URI=https://u:NOT-A-PASSWORD@ml.example.com
        LANGFUSE_HOST=https://cloud.langfuse.com/project/x#y
        LANCEDB_URI=db://shop-vectors
        CHROMA_HOST=localhost
        """)
        let facts = read(project)
        let qdrant = try #require(SafeWebLink.Origin(scheme: "https", host: "abc.cloud.qdrant.io", port: 6333))
        #expect(facts.value("QDRANT_URL")?.value == .origin(qdrant))
        // A user or password drops the value whole.
        #expect(facts.value("MLFLOW_TRACKING_URI") == nil)
        #expect(facts.value("LANGFUSE_HOST")?.origin?.string == "https://cloud.langfuse.com")
        // A value that names no web server keeps only its scheme.
        #expect(facts.value("LANCEDB_URI")?.value == .scheme("db"))
        #expect(facts.value("CHROMA_HOST")?.origin?.string == "http://localhost")
        let text = printed(facts)
        for secret in ["NOT-A-KEY", "NOT-A-PASSWORD", "api_key", "shop-vectors", "project/x"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func aValueWithUserInfoKeepsNothingAtAll() {
        let project = FixtureProject()
        project.write(".env", """
        QDRANT_URL=admin:NOT-A-PASSWORD@qdrant.example.com:6333
        LANCEDB_URI=sk-live-NOTAKEY123:xyz
        MLFLOW_TRACKING_URI=postgresql://mlflow:NOT-A-PASSWORD@db.example.com/mlflow
        LANGFUSE_HOST=admin@localhost:3000
        CHROMA_HOST=admin:NOT-A-PASSWORD@chroma
        """)
        let facts = read(project)
        #expect(facts.envValues.isEmpty)
        let text = printed(facts).lowercased()
        for secret in ["admin", "not-a-password", "notakey", "sk-live", "mlflow:", "postgresql"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func aSchemeIsKeptOnlyWhenItIsOne() {
        // Text before a colon is a scheme only when nothing, or a `/`, follows the colon.
        #expect(ProjectFacts.urlValue("file:") == .scheme("file"))
        #expect(ProjectFacts.urlValue("file:/srv/mlruns") == .scheme("file"))
        #expect(ProjectFacts.urlValue("sqlite:///mlflow.db") == .scheme("sqlite"))
        #expect(ProjectFacts.urlValue("DB://shop-vectors") == .scheme("db"))
        // A user and password, a token, or a word before a colon is not one.
        for value in ["admin:NOT-A-PASSWORD@qdrant.example.com:6333", "sk-live-NOTAKEY123:xyz", "mailto:a@example.com",
                      "db:admin@shop", "db://admin@shop/x", "postgresql://u:NOT-A-PASSWORD@db/x", "user@db.example.com",
                      "git@example.com:team/repo", "javascript:alert(1)", "databricks", "s3:bucket"] {
            #expect(ProjectFacts.urlValue(value) == nil, "\(value)")
        }
    }

    @Test func aHostWithNoSchemeIsPlainHTTPOnlyOnThisMac() throws {
        func origin(_ value: String) -> String? { ProjectFacts.hostValue(value).flatMap(originText) }
        #expect(origin("localhost") == "http://localhost")
        #expect(origin("127.0.0.1") == "http://127.0.0.1")
        #expect(origin("0.0.0.0:8000") == "http://localhost:8000")
        #expect(origin("[::1]:8000") == "http://[::1]:8000")
        #expect(origin("chroma") == "http://chroma")
        #expect(origin("vector_db:8000") == "http://vector_db:8000")
        #expect(origin("api.trychroma.com") == "https://api.trychroma.com")
        // A scheme written is kept as written.
        #expect(origin("https://api.trychroma.com") == "https://api.trychroma.com")
        #expect(origin("http://localhost:8001") == "http://localhost:8001")
        for value in ["admin:NOT-A-PASSWORD@chroma", "admin:secret", "ftp://chroma", "chroma/x", "chroma host"] {
            #expect(ProjectFacts.hostValue(value) == nil, "\(value)")
        }
        let project = FixtureProject()
        project.write(".env", "CHROMA_HOST=localhost\n")
        let link = read(project).value("CHROMA_HOST")?.origin?.link(path: [.fixed("/api/v2/heartbeat")])
        #expect(link?.absoluteString == "http://localhost/api/v2/heartbeat")
    }

    func originText(_ value: ServiceFact.Value) -> String? {
        if case .origin(let origin) = value { return origin.string }
        return nil
    }

    @Test func aValueThatNamesAnotherIsRefused() {
        let project = FixtureProject()
        project.write(".env", """
        QDRANT_HOST=abc.example.com
        QDRANT_URL=https://${QDRANT_HOST}
        LANGSMITH_PROJECT=$(whoami)
        BRAINTRUST_DEFAULT_PROJECT=shop-`id`
        LANGFUSE_HOST=$LANGFUSE_BASE
        AWS_REGION=`eu-west-1`
        """)
        let facts = read(project)
        // Backticks around a whole value quote it, as in dotenv; nothing is run.
        #expect(facts.envValues.map(\.key) == ["AWS_REGION"])
        #expect(facts.value("AWS_REGION")?.text == "eu-west-1")
        #expect(facts.hasEnvName("QDRANT_URL"))
    }

    @Test func valuesByRole() throws {
        let project = FixtureProject()
        project.write(".flaskenv", "FLASK_RUN_PORT=5001\n")
        project.write(".env.phoenix", "PHOENIX_PORT=abc\n")
        project.write(".env", """
        MLFLOW_TRACKING_URI=file:///Users/someone/mlruns
        BRAINTRUST_DEFAULT_PROJECT="My App"
        AWS_REGION=eu-west-1
        RAILWAY_PROJECT_ID=12345678-aaaa-bbbb-cccc-1234567890ab
        LANGSMITH_PROJECT=a/b
        CHROMA_HOST=chroma
        """)
        let facts = read(project)
        #expect(facts.value("FLASK_RUN_PORT") == ServiceFact(file: ".flaskenv", key: "FLASK_RUN_PORT", role: .port, value: .port(5001)))
        #expect(facts.value("PHOENIX_PORT") == nil)
        #expect(facts.value("MLFLOW_TRACKING_URI")?.value == .scheme("file"))
        #expect(facts.value("BRAINTRUST_DEFAULT_PROJECT")?.value == .text("My App"))
        #expect(facts.value("AWS_REGION")?.value == .text("eu-west-1"))
        #expect(facts.value("RAILWAY_PROJECT_ID")?.value == .text("12345678-aaaa-bbbb-cccc-1234567890ab"))
        #expect(facts.value("LANGSMITH_PROJECT") == nil)
        // A host by itself, such as a Compose service's name.
        #expect(facts.value("CHROMA_HOST")?.origin?.string == "http://chroma")
        let text = printed(facts)
        for value in ["someone", "mlruns", "My App", "eu-west-1", "12345678"] { #expect(!text.contains(value), "\(value)") }
    }

    @Test func envFilesInTheOrderNextJSPrefersThem() {
        let project = FixtureProject()
        project.write(".env", "QDRANT_URL=http://qdrant:6333\nSHARED=1\n")
        project.write(".env.local", "QDRANT_URL=https://abc.cloud.qdrant.io\n")
        project.write(".env.example", "PINECONE_API_KEY=\n")
        let facts = read(project)
        #expect(facts.envNames.map(\.file) == [".env.local", ".env"])
        #expect(facts.values("QDRANT_URL").map(\.file) == [".env.local", ".env"])
        #expect(facts.value("QDRANT_URL")?.origin?.host == "abc.cloud.qdrant.io")
        // With a live env file, .env.example says nothing.
        #expect(!facts.hasEnvName("PINECONE_API_KEY"))
        let text = printed(facts)
        for value in ["abc.cloud.qdrant.io", "qdrant:6333", "http://"] { #expect(!text.contains(value), "\(value)") }
    }

    @Test func aFreshCloneNamesKeysFromTheExampleButReadsNoValue() {
        let project = FixtureProject()
        project.write(".env.example", "OPENAI_API_KEY=sk-test-NOT-A-KEY\nQDRANT_URL=https://abc.cloud.qdrant.io\n")
        let facts = read(project)
        #expect(facts.envNames == [EnvNames(file: ".env.example", names: ["OPENAI_API_KEY", "QDRANT_URL"])])
        #expect(facts.envValues.isEmpty)
        #expect(!printed(facts).contains("NOT-A-KEY"))
    }

    @Test func theExampleCountsOnlyWhenNoEnvFileExists() throws {
        // An env file that exists but is not read (too large, a link out of the project) is not a fresh clone.
        let large = FixtureProject()
        large.write(".env", "QDRANT_URL=http://localhost:6333\n" + String(repeating: "# made-up padding line\n", count: 25_000))
        large.write(".env.example", "OPENAI_API_KEY=\n")
        let facts = read(large)
        #expect(facts.envNames.isEmpty)
        #expect(!facts.hasEnvName("OPENAI_API_KEY"))
        #expect(facts.read.isEmpty)
        let outside = FixtureProject()
        outside.write("secrets.env", "QDRANT_URL=https://abc.cloud.qdrant.io\n")
        let linked = FixtureProject()
        linked.write(".env.example", "OPENAI_API_KEY=\n")
        try FileManager.default.createSymbolicLink(atPath: linked.root + "/.flaskenv", withDestinationPath: outside.root + "/secrets.env")
        #expect(read(linked).envNames.isEmpty)
        // A folder by an env file's name is not one.
        let folder = FixtureProject()
        folder.write(".env/readme.txt", "made up\n")
        folder.write(".env.example", "OPENAI_API_KEY=\n")
        #expect(read(folder).envNames == [EnvNames(file: ".env.example", names: ["OPENAI_API_KEY"])])
    }

    @Test func anICloudPlaceholderOrAPipeIsNeverOpened() throws {
        var info = stat()
        info.st_mode = S_IFREG | 0o644
        info.st_size = 64
        #expect(FactReader.mayRead(info))
        info.st_flags = FactReader.dataless
        #expect(!FactReader.mayRead(info))
        info.st_flags = 0
        info.st_size = off_t(FactReader.maxSize + 1)
        #expect(!FactReader.mayRead(info))
        info.st_size = 64
        info.st_mode = S_IFIFO | 0o644
        #expect(!FactReader.mayRead(info))
        // A named pipe by an env file's name (some secret managers serve .env so): reading it would wait for a writer,
        // or ask the manager for every secret. It is never opened, and it still counts as the project's env file.
        let project = FixtureProject()
        #expect(mkfifo(project.root + "/.env", 0o600) == 0)
        project.write(".env.example", "OPENAI_API_KEY=\n")
        project.write("package.json", #"{"dependencies": {"next": "15.5.0"}}"#)
        let facts = read(project)
        #expect(facts.envNames.isEmpty)
        #expect(facts.read == ["package.json"])
    }

    @Test func aSymlinkOutOfTheProjectIsNotFollowed() throws {
        let outside = FixtureProject()
        outside.write("secrets.env", "QDRANT_URL=https://abc.cloud.qdrant.io\n")
        outside.write("package.json", #"{"dependencies": {"next": "15.5.0"}}"#)
        let project = FixtureProject()
        try FileManager.default.createSymbolicLink(atPath: project.root + "/.env", withDestinationPath: outside.root + "/secrets.env")
        try FileManager.default.createSymbolicLink(atPath: project.root + "/package.json",
                                                   withDestinationPath: outside.root + "/package.json")
        let facts = read(project)
        #expect(facts.envNames.isEmpty)
        #expect(facts.envValues.isEmpty)
        #expect(facts.dependencies.isEmpty)
        #expect(facts.read.isEmpty)
        // A link that stays inside is followed.
        project.write("config/app.env", "QDRANT_URL=http://localhost:6333\n")
        try FileManager.default.removeItem(atPath: project.root + "/.env")
        try FileManager.default.createSymbolicLink(atPath: project.root + "/.env", withDestinationPath: "config/app.env")
        let inside = read(project)
        #expect(inside.value("QDRANT_URL")?.origin?.port == 6333)
        let text = printed(facts) + printed(inside)
        for value in ["abc.cloud.qdrant.io", "localhost", "6333", "15.5.0"] { #expect(!text.contains(value), "\(value)") }
    }

    @Test func eachFileIsReadOnce() {
        let project = FixtureProject()
        project.write(".env", "QDRANT_URL=http://qdrant:6333\nQDRANT_PORT=7100\n")
        project.write("compose.yaml", "services:\n  qdrant:\n    image: qdrant/qdrant\n    ports: [\"${QDRANT_PORT:-6334}:6333\"]\n")
        project.write("package.json", #"{"dependencies": {"next": "15.5.0"}, "scripts": {"dev": "next dev -p 3100"}}"#)
        project.write("pyproject.toml", "[project]\ndependencies = [\"fastapi\"]\n[tool.poe.tasks]\nserve = \"uvicorn app:app\"\n")
        let facts = read(project)
        #expect(facts.read.count == Set(facts.read).count)
        #expect(Set(facts.read) == [".env", "compose.yaml", "package.json", "pyproject.toml"])
        #expect(facts.compose?.services.first?.ports.map(\.published) == [7100])
        let text = printed(facts)
        for value in ["7100", "6334", "3100", "qdrant:6333", "15.5.0", "uvicorn", "next dev"] {
            #expect(!text.contains(value), "\(value)")
        }
    }

    // MARK: manifests

    @Test func pythonNamesAreNormalised() {
        #expect(ProjectFacts.requirementName("langgraph-cli[inmem]>=0.2") == "langgraph-cli")
        #expect(ProjectFacts.requirementName("Qdrant_Client==1.15") == "qdrant-client")
        #expect(ProjectFacts.requirementName("langchain.openai") == "langchain-openai")
        #expect(ProjectFacts.requirementName("  openai ~= 1.40 ; python_version >= '3.9'  # pinned") == "openai")
        #expect(ProjectFacts.requirementName("shop-sdk @ https://example.com/shop_sdk-1.0.tar.gz") == "shop-sdk")
        for line in ["-r base.txt", "-e .", "git+https://example.com/x.git#egg=x", "--index-url https://u:NOT-A-KEY@example.com",
                     "# a comment", "", "./local-package", "/abs/path", "https://example.com/x.whl", "-c constraints.txt"] {
            #expect(ProjectFacts.requirementName(line) == nil, "\(line)")
        }
    }

    @Test func requirementsFiles() {
        let project = FixtureProject()
        project.write("requirements.txt", "-r requirements/base.txt\nlanggraph-cli[inmem]>=0.2\nQdrant_Client==1.15\n")
        project.write("requirements-dev.txt", "-e .\nlangchain.openai\n")
        project.write("requirements/base.txt", "fastapi\ngit+https://u:NOT-A-KEY@example.com/x.git\n")
        project.write("notes.txt", "flask\n")
        let facts = read(project)
        #expect(facts.dependencyFile("langgraph-cli", in: .pypi) == "requirements.txt")
        #expect(facts.dependencyFile("qdrant-client", in: .pypi) == "requirements.txt")
        #expect(facts.dependencyFile("langchain-openai", in: .pypi) == "requirements-dev.txt")
        #expect(facts.dependencyFile("fastapi", in: .pypi) == "requirements/base.txt")
        #expect(facts.dependencyFile("flask", in: .pypi) == nil)
        #expect(!printed(facts).contains("NOT-A-KEY"))
    }

    @Test func pyprojectAndPipfile() {
        let project = FixtureProject()
        project.write("pyproject.toml", """
        [project]
        name = "support-bot"
        dependencies = ["langgraph>=0.3", "Anthropic", "langfuse[openai]"]
        [project.optional-dependencies]
        server = ["fastapi"]
        [dependency-groups]
        dev = ["pytest", {include-group = "server"}]
        [tool.poetry.dependencies]
        python = "^3.12"
        qdrant-client = "^1.15"
        [tool.poetry.group.dev.dependencies]
        ruff = "*"
        [tool.crewai]
        type = "crew"
        [tool.poe.tasks]
        studio = "langgraph dev --port 2100"
        api = { cmd = "uvicorn app:app --port=8100" }
        both = ["studio", { shell = "OPENAI_API_KEY=NOT-A-KEY uvicorn app:app --port 8200" }]
        [tool.taskipy.tasks]
        web = "python manage.py runserver 0.0.0.0:8001"
        """)
        project.write("Pipfile", "[packages]\nstreamlit = \"*\"\n[dev-packages]\nJupyterLab = \"*\"\n")
        let facts = read(project)
        for name in ["langgraph", "anthropic", "langfuse", "fastapi", "pytest", "qdrant-client", "ruff"] {
            #expect(facts.dependencyFile(name, in: .pypi) == "pyproject.toml", "\(name)")
        }
        #expect(facts.dependencyFile("python", in: .pypi) == nil)
        #expect(facts.dependencyFile("support-bot", in: .pypi) == nil)
        #expect(facts.dependencyFile("streamlit", in: .pypi) == "Pipfile")
        #expect(facts.dependencyFile("jupyterlab", in: .pypi) == "Pipfile")
        #expect(facts.pyprojectTools.contains("crewai"))
        #expect(facts.pyprojectTools.contains("poe"))
        let commands = facts.startCommands
        #expect(commands.contains(StartCommand(file: "pyproject.toml", script: "studio", word: "langgraph dev", port: 2100)))
        #expect(commands.contains(StartCommand(file: "pyproject.toml", script: "api", word: "uvicorn", port: 8100)))
        #expect(commands.contains(StartCommand(file: "pyproject.toml", script: "both", word: "uvicorn", port: 8200)))
        #expect(commands.contains(StartCommand(file: "pyproject.toml", script: "web", word: "manage.py runserver", port: 8001)))
        #expect(!printed(facts).contains("NOT-A-KEY"))
    }

    @Test func aTableKeyThatIsNoPackageNameIsSkipped() {
        let project = FixtureProject()
        project.write("Pipfile", "[packages]\n\"Foo Bar/../x\" = \"*\"\nStreamlit = \"*\"\n\"-e\" = \"*\"\n")
        project.write("pyproject.toml", "[tool.poetry.dependencies]\npython = \"^3.12\"\n\"a b\" = \"1\"\nqdrant-client = \"^1.15\"\n")
        let facts = read(project)
        #expect(facts.dependencies.map(\.names) == [["qdrant-client"], ["streamlit"]])
    }

    @Test func aFlatYAMLValueLosesItsComment() {
        let project = FixtureProject()
        project.write("herd.yml", "name: shop # the site\nsecured: true # https\n")
        project.write(".ddev/config.yaml", "# made up\nname: \"shop\" # quoted\nproject_tld: \"ddev # site\"\n")
        let facts = read(project)
        #expect(facts.named(.herdName) == "shop")
        #expect(facts.named(.herdSecured) == "true")
        #expect(facts.named(.ddevName) == "shop")
        // A `#` inside quotes is the value's; such a value is no plain name, so it is not kept.
        #expect(facts.named(.ddevTLD) == nil)
    }

    @Test func aPyprojectTheReaderRefusesGivesNothing() {
        let project = FixtureProject()
        project.write("pyproject.toml", "[project\ndependencies = [\"fastapi\"\n")
        let facts = read(project)
        #expect(facts.dependencies.isEmpty)
        #expect(facts.startCommands.isEmpty)
        #expect(facts.read == ["pyproject.toml"])
    }

    @Test func packageJSONGemfileAndMix() {
        let project = FixtureProject()
        project.write("package.json", """
        {"name": "shop-web", "dependencies": {"next": "15.5.0", "@ai-sdk/anthropic": "^2.0"},
         "devDependencies": {"vite": "^7.0"},
         "scripts": {"dev": "OPENAI_API_KEY=NOT-A-KEY next dev -p 3100", "build": "next build"}}
        """)
        project.write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\", \"~> 8.0\"\n  gem 'puma'\n# gem \"sidekiq\"\n")
        project.write("mix.exs", "defp deps do\n  [\n    {:phoenix, \"~> 1.7\"},\n    {:phoenix_live_dashboard, \"~> 0.8\"}\n  ]\nend\n")
        let facts = read(project)
        #expect(facts.dependencyFile("next", in: .npm) == "package.json")
        #expect(facts.dependencyFile("@ai-sdk/anthropic", in: .npm) == "package.json")
        #expect(facts.dependencyFile("vite", in: .npm) == "package.json")
        #expect(facts.dependencyFile("shop-web", in: .npm) == nil)
        #expect(facts.dependencyFile("rails", in: .rubygems) == "Gemfile")
        #expect(facts.dependencyFile("puma", in: .rubygems) == "Gemfile")
        #expect(facts.dependencyFile("sidekiq", in: .rubygems) == nil)
        #expect(facts.dependencyFile("phoenix", in: .hex) == "mix.exs")
        #expect(facts.dependencyFile("phoenix_live_dashboard", in: .hex) == "mix.exs")
        #expect(facts.startCommands == [StartCommand(file: "package.json", script: "dev", word: "next dev", port: 3100)])
        #expect(!printed(facts).contains("NOT-A-KEY"))
    }

    // MARK: start commands and ports

    func command(_ line: String) -> [StartCommand] {
        ProjectFacts.startCommands(in: line, file: "package.json", script: "dev", words: Self.startWords)
    }

    @Test func aPortFromAStartCommand() {
        #expect(command("uvicorn app:app --port=8100").map(\.port) == [8100])
        #expect(command("python -m uvicorn app:app --reload --port 8101").map(\.port) == [8101])
        #expect(command("python manage.py runserver 0.0.0.0:8001").map(\.port) == [8001])
        #expect(command("python manage.py runserver 8002").map(\.port) == [8002])
        #expect(command("PORT=4100 next dev").map(\.port) == [4100])
        #expect(command("cross-env PORT=4101 next dev --turbopack").map(\.port) == [4101])
        #expect(command("next dev -p 3100").map(\.port) == [3100])
        #expect(command("./node_modules/.bin/next dev --port 3101").map(\.port) == [3101])
        #expect(command("streamlit run app.py --server.port 8600").map(\.port) == [8600])
        #expect(command("streamlit run app.py --server.port=8601").map(\.port) == [8601])
        #expect(command("bin/rails server -p 3200").map(\.port) == [3200])
        let temporal = command("temporal server start-dev --port 7300 --ui-port 8300")
        #expect(temporal == [StartCommand(file: "package.json", script: "dev", word: "temporal server start-dev", port: 7300, uiPort: 8300)])
        // The tool with no port named, an expression, or a port that belongs to another command on the line.
        #expect(command("next dev").map(\.port) == [nil])
        #expect(command("next dev -p $PORT").map(\.port) == [nil])
        #expect(command("next dev && vite --port 5175").map(\.port) == [nil])
        #expect(command("concurrently \"next dev -p 3300\" \"langgraph dev --port 2100\"").map(\.port) == [3300, 2100])
        #expect(command("next build && next start -p 4000").isEmpty)
        #expect(command("echo next dev is not run here").count == 1) // words in a line count; the catalog picks them
        #expect(command("nextdev -p 1").isEmpty)
    }

    @Test func aSecretOnAScriptLineLeavesNoTrace() {
        let found = command("OPENAI_API_KEY=NOT-A-KEY next dev -p 3100")
        #expect(found.map(\.port) == [3100])
        var dumped = ""
        dump(found, to: &dumped)
        #expect(!(dumped + String(describing: found)).contains("NOT-A-KEY"))
        let mlflow = ProjectFacts.startCommands(in: "mlflow server --backend-store-uri postgresql://u:NOT-A-PASSWORD@db/x --port 5001",
                                                file: "Makefile", script: "ml", words: Self.startWords)
        #expect(mlflow.map(\.port) == [5001])
        #expect(!String(describing: mlflow).contains("NOT-A-PASSWORD"))
    }

    @Test func procfileMakefileAndJustfile() {
        let project = FixtureProject()
        project.write("Procfile.dev", "web: bin/rails server -p 3200\ncss: bin/rails tailwindcss:watch\n")
        project.write("Makefile", "export TOKEN=NOT-A-TOKEN\n\nrun: deps\n\tuvicorn app:app --port=8100\n\ndeps:\n\tpip install -r requirements.txt\n")
        project.write("justfile", "# made up\nserve port='8001':\n    python manage.py runserver 0.0.0.0:8001\n")
        let facts = read(project)
        #expect(facts.startCommands.contains(StartCommand(file: "Procfile.dev", script: "web", word: "rails server", port: 3200)))
        #expect(facts.startCommands.contains(StartCommand(file: "Makefile", script: "run", word: "uvicorn", port: 8100)))
        #expect(facts.startCommands.contains(StartCommand(file: "justfile", script: "serve", word: "manage.py runserver", port: 8001)))
        #expect(facts.startCommands.count == 3)
        #expect(!printed(facts).contains("NOT-A-TOKEN"))
    }

    func recipePorts(_ text: String, file: String = "Makefile") -> [Int?] {
        ProjectFacts.recipes(text, file: file, words: Self.startWords).map(\.port)
    }

    @Test func recipeLinesWithMakesPrefixesAndContinuations() {
        // `@` (quiet), `-` (ignore errors) and `+` (always run) go before the command, alone or together.
        #expect(recipePorts("dev:\n\t@uvicorn app:app --port 8100\n") == [8100])
        #expect(recipePorts("dev:\n\t-uvicorn app:app --port 8101\n") == [8101])
        #expect(recipePorts("dev:\n\t@-+ uvicorn app:app --port 8102\n") == [8102])
        let named = ProjectFacts.recipes("web:\n\t@PORT=4100 next dev\n", file: "Makefile", words: Self.startWords)
        #expect(named == [StartCommand(file: "Makefile", script: "web", word: "next dev", port: 4100)])
        // A line that ends in `\` goes on with the next, however that one is indented.
        #expect(recipePorts("dev:\n\tuvicorn app:app \\\n\t\t--port 8103\n") == [8103])
        #expect(recipePorts("dev:\n\t@uvicorn app:app \\\n--reload \\\n  --port 8104\n\nother:\n\techo\n") == [8104])
        #expect(recipePorts("dev:\n\tuvicorn app:app \\\n") == [nil])
        // A justfile's recipes take `@` and `-` too.
        #expect(recipePorts("serve:\n    @uvicorn app:app --port 8105\n", file: "justfile") == [8105])
        // A continued variable is not a recipe line.
        #expect(recipePorts("FLAGS = --port 9000 \\\n\t--reload\nrun:\n\tuvicorn app:app\n") == [nil])
        let secret = ProjectFacts.recipes("ml:\n\t@OPENAI_API_KEY=NOT-A-KEY \\\n\tmlflow server --port 5001\n",
                                          file: "Makefile", words: Self.startWords)
        #expect(secret.map(\.port) == [5001])
        #expect(!String(describing: secret).contains("NOT-A-KEY"))
    }

    // MARK: Compose

    @Test func composeFromTheFirstFileThatExists() {
        let project = FixtureProject()
        project.write("docker-compose.yml", "services:\n  old:\n    image: example/old\n")
        project.write("compose.yml", "services:\n  qdrant:\n    image: qdrant/qdrant:v1.15.0\n    ports: [\"6334:6333\"]\n")
        let facts = read(project)
        #expect(facts.compose?.file == "compose.yml")
        #expect(facts.compose?.services.map(\.name) == ["qdrant"])
        #expect(facts.compose?.services(withImage: "qdrant/qdrant").first?.port(forTarget: 6333) == 6334)
        #expect(facts.compose?.service(named: "qdrant")?.image == "qdrant/qdrant")
        let text = printed(facts)
        for value in ["qdrant", "6334", "v1.15.0", "example/old"] { #expect(!text.contains(value), "\(value)") }
    }

    @Test func aComposePortNeverTakesASecretsValue() {
        let project = FixtureProject()
        project.write(".env", "DB_PASSWORD=31337\nWEB_PORT=8180\n")
        project.write("compose.yaml", """
        services:
          web:
            image: example/web
            ports:
              - "${DB_PASSWORD:-8080}:80"
              - "${WEB_PORT:-8081}:81"
        """)
        let facts = read(project)
        #expect(facts.compose?.services.first?.ports.map(\.published) == [8080, 8180])
        #expect(!printed(facts).contains("31337"))
    }

    @Test func aLargeFileIsNotRead() {
        let project = FixtureProject()
        let padding = String(repeating: "# padding line for a made-up compose file\n", count: 15_000)
        project.write("compose.yaml", "services:\n  qdrant:\n    image: qdrant/qdrant\n" + padding)
        let facts = read(project)
        #expect(facts.compose == nil)
        #expect(facts.read.isEmpty)
    }

    // MARK: tool configs

    @Test func namedFactsFromToolConfigs() {
        let project = FixtureProject()
        project.write("supabase/.temp/project-ref", "abcdefghijklmnopqrst\n")
        project.write("supabase/config.toml", "project_id = \"shop\"\n[db]\nport = 54322\n[studio]\nport = 54423\n[inbucket]\nport = 54424\n")
        project.write(".firebaserc", #"{"projects":{"default":"shop-prod"}}"#)
        project.write("firebase.json", #"{"emulators":{"ui":{"port":4005},"firestore":{"port":8080}}}"#)
        project.write("trigger.config.ts", "export default defineConfig({\n  project: \"proj_abcdefghijklmnop\",\n});\n")
        project.write(".neon", #"{"projectId": "cold-grass-40154007"}"#)
        project.write(".pscale.yml", "org: acme\ndatabase: shop\nbranch: main\n")
        project.write("fly.toml", "app = \"shop-api\"\nprimary_region = \"ams\"\n")
        project.write("herd.yml", "name: shop\nsecured: true\n")
        project.write(".ddev/config.yaml", "name: shop\ntype: laravel\nproject_tld: ddev.site\nrouter_https_port: \"8443\"\n")
        project.write(".streamlit/config.toml", "[server]\nport = 8600\n")
        project.write("inngest.json", #"{"port": 8300}"#)
        project.write("cog.yaml", "build:\n  gpu: true\nimage: \"r8.im/acme/shop-model\"\n")
        project.write(".vercel/project.json", #"{"projectId":"prj_abc123","orgId":"team_abc123","projectName":"shop-web"}"#)
        let facts = read(project)
        let expected: [NamedFact: String] = [
            .supabaseRef: "abcdefghijklmnopqrst", .supabaseDBPort: "54322", .supabaseStudioPort: "54423",
            .supabaseInbucketPort: "54424", .firebaseProject: "shop-prod", .firebaseEmulators: "true",
            .firebaseEmulatorUIPort: "4005", .triggerProjectRef: "proj_abcdefghijklmnop", .neonProjectID: "cold-grass-40154007",
            .pscaleOrg: "acme", .pscaleDatabase: "shop", .flyApp: "shop-api", .herdName: "shop", .herdSecured: "true",
            .ddevName: "shop", .ddevTLD: "ddev.site", .ddevHTTPSPort: "8443", .streamlitPort: "8600", .inngestPort: "8300",
            .replicateOwner: "acme", .replicateModel: "shop-model", .vercelProjectID: "prj_abc123",
            .vercelOrgID: "team_abc123", .vercelProjectName: "shop-web",
        ]
        for (fact, value) in expected { #expect(facts.named(fact) == value, "\(fact)") }
        #expect(facts.port(.supabaseStudioPort) == 54423)
        #expect(facts.namedFile(.flyApp) == "fly.toml")
        // Supabase's local project_id is a name, never the cloud ref.
        #expect(!facts.named.contains { (named: NamedValue) -> Bool in named.value == "shop" && named.fact == .supabaseRef })
        let text = printed(facts)
        for value in ["abcdefghijklmnopqrst", "shop-prod", "cold-grass", "shop-api", "team_abc123"] {
            #expect(!text.contains(value), "\(value)")
        }
    }

    @Test func cloudflareBindings() {
        let project = FixtureProject()
        project.write("wrangler.jsonc", """
        // made up
        {
          "name": "shop-worker", /* the worker */
          "account_id": "0123456789abcdef0123456789abcdef",
          "d1_databases": [{"binding": "DB", "database_name": "shop-db", "database_id": "12345678-aaaa-bbbb-cccc-1234567890ab"},],
          "r2_buckets": [{"binding": "FILES", "bucket_name": "shop-files"}],
        }
        """)
        let facts = read(project)
        #expect(facts.named(.wranglerAccountID) == "0123456789abcdef0123456789abcdef")
        #expect(facts.all(.d1Database).map(\.value) == ["12345678-aaaa-bbbb-cccc-1234567890ab"])
        #expect(facts.all(.d1Database).first?.label == "shop-db")
        #expect(facts.all(.r2Bucket).map(\.value) == ["shop-files"])
        let toml = FixtureProject()
        toml.write("wrangler.toml", """
        name = "shop-worker"
        account_id = "0123456789abcdef0123456789abcdef"
        [[d1_databases]]
        binding = "DB"
        database_name = "shop-db"
        database_id = "12345678-aaaa-bbbb-cccc-1234567890ab"
        [[r2_buckets]]
        binding = "FILES"
        bucket_name = "shop-files"
        """)
        let fromTOML = read(toml)
        #expect(fromTOML.all(.d1Database).first?.label == "shop-db")
        #expect(fromTOML.named(.wranglerAccountID) == "0123456789abcdef0123456789abcdef")
        let text = printed(facts) + printed(fromTOML)
        for value in ["0123456789abcdef", "12345678-aaaa", "shop-db", "shop-files", "shop-worker"] {
            #expect(!text.contains(value), "\(value)")
        }
    }

    @Test func portLiteralsInConfigCode() {
        let project = FixtureProject()
        project.write("vite.config.ts", "export default defineConfig({\n  server: {\n    hmr: { port: 24678 },\n    port: 5174,\n    https: true,\n  },\n})\n")
        project.write("astro.config.mjs", "export default defineConfig({ server: { port: 4400 } })\n")
        project.write("nuxt.config.ts", "export default defineNuxtConfig({ devServer: { port: 3300 } })\n")
        project.write("src/mastra/index.ts", "export const mastra = new Mastra({\n  server: { port: 4200, timeout: 30000 },\n})\n")
        let facts = read(project)
        #expect(facts.port(.vitePort) == 5174)
        #expect(facts.named(.viteHTTPS) == "true")
        #expect(facts.namedFile(.vitePort) == "vite.config.ts")
        #expect(facts.port(.astroPort) == 4400)
        #expect(facts.port(.nuxtPort) == 3300)
        #expect(facts.port(.mastraPort) == 4200)
        let text = printed(facts)
        for value in ["5174", "24678", "4400", "3300", "4200", "30000"] { #expect(!text.contains(value), "\(value)") }
    }

    @Test func anExpressionGivesNoPort() {
        let cases = ["server: { port: Number(process.env.PORT) }", "server: { port: process.env.PORT || 5174 }",
                     "server: { hmr: { port: 24678 } }", "server: { port: 5174 * 2 }", "server: { port: 99999 }",
                     "preview: { port: 4173 }", "server: { port: '5174' }"]
        for text in cases {
            #expect(ProjectFacts.portLiteral(in: "export default {" + text + "}", block: "server") == nil, "\(text)")
        }
        #expect(ProjectFacts.portLiteral(in: "server:{port:5180}", block: "server") == 5180)
        #expect(ProjectFacts.portLiteral(in: "server: {\n  // port: 1\n  port: 5181 // dev\n}", block: "server") == 5181)
    }

    @Test func markerFiles() {
        let project = FixtureProject()
        project.write("langgraph.json", "{}")
        project.write("manage.py", "")
        project.write(".ddev/config.yaml", "name: shop\n")
        project.write("mlruns/0/meta.yaml", "")
        project.write("notebooks/explore.ipynb", "{}")
        project.write("analysis.ipynb", "{}")
        let markers = ["langgraph.json", "manage.py", ".ddev/config.yaml", "mlruns/", "convex.json", "*.ipynb", "../outside", "/etc/hosts"]
        let facts = read(project, markers: markers)
        #expect(facts.files == ["langgraph.json", "manage.py", ".ddev/config.yaml", "mlruns/", "*.ipynb"])
        let text = printed(facts)
        for value in ["shop", "explore", "analysis", "langgraph.json"] { #expect(!text.contains(value), "\(value)") }
    }
}
