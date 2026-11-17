import Foundation
import Testing
@testable import NextTermCore

/// The Run group's tasks, read from made-up project files, and the rules for offering a tool the project needs.
@Suite struct RunTasksTests {
    func scan(_ files: [String: String]) -> RunScan {
        let project = FixtureProject()
        for (path, text) in files { project.write(path, text) }
        return RunTasks.scan(root: project.root)
    }

    func commands(_ scan: RunScan) -> [String] { scan.tasks.map(\.command) }

    // MARK: package.json

    @Test func packageScriptsInTheFilesOrderWithItsPackageManager() {
        let json = """
        {"name": "web", "scripts": {"dev": "next dev", "build": "next build", "prebuild": "rm -rf .next",
         "postinstall": "patch-package", "lint:fix": "eslint --fix .", "test e2e": "playwright test"}}
        """
        #expect(commands(scan(["package.json": json])) == ["npm run dev", "npm run build", "npm run lint:fix",
                                                           "npm run 'test e2e'"])
        #expect(commands(scan(["package.json": json, "pnpm-lock.yaml": ""])).first == "pnpm run dev")
        #expect(commands(scan(["package.json": json, "yarn.lock": ""])).first == "yarn run dev")
        #expect(commands(scan(["package.json": json, "bun.lock": ""])).first == "bun run dev")
        let task = scan(["package.json": json]).tasks[0]
        #expect(task.name == "dev" && task.file == "package.json" && task.source == .npm)
        #expect(task.paletteTitle == "Run: npm run dev")
    }

    @Test func aPackageWithNoScriptsOrBrokenJSONHasNoTasks() {
        #expect(scan(["package.json": #"{"dependencies": {"next": "1"}}"#]).tasks.isEmpty)
        #expect(scan(["package.json": "{ not json"]).tasks.isEmpty)
        #expect(scan(["package.json": #"{"scripts": {"dev": 3}}"#]).tasks.isEmpty)
    }

    // MARK: Makefile and justfile

    @Test func makeTargetsLeaveOutSpecialAndFileTargetsAndVariables() {
        let makefile = """
        CC := clang
        VERSION = 1.0
        export TOKEN := NOT-A-TOKEN
        .PHONY: build test
        build: deps
        \t$(CC) -o app main.c
        main.o: main.c
        \t$(CC) -c main.c
        test:
        \t./app --test
        build-release: build
        \tstrip app
        """
        #expect(commands(scan(["Makefile": makefile])) == ["make build", "make test", "make build-release"])
        #expect(!scan(["Makefile": makefile]).tasks.contains { $0.command.contains("NOT-A-") })
    }

    @Test func justRecipesLeaveOutPrivateOnesAndSettings() {
        let justfile = """
        set dotenv-load := true
        alias b := build
        # Build it
        build:
            cargo build
        serve port='8001':
            python -m http.server {{port}}
        _helper:
            echo hidden
        [private]
        secret:
            echo hidden
        @test: build
            cargo test
        """
        #expect(commands(scan(["justfile": justfile])) == ["just build", "just serve", "just test"])
    }

    // MARK: pyproject.toml

    @Test func pythonScriptsRunThroughTheProjectsOwnRunner() {
        let pyproject = """
        [project]
        name = "bot"
        [project.scripts]
        bot = "bot.cli:main"
        [tool.poe.tasks]
        serve = "fastapi dev"
        _private = "echo no"
        [tool.taskipy.tasks]
        lint = "ruff check ."
        """
        #expect(commands(scan(["pyproject.toml": pyproject])) == ["bot", "poe serve", "task lint"])
        #expect(commands(scan(["pyproject.toml": pyproject, "uv.lock": ""])) == ["uv run bot", "uv run poe serve",
                                                                                 "uv run task lint"])
        #expect(commands(scan(["pyproject.toml": pyproject + "\n[tool.uv]\ndev-dependencies = []\n"])).first == "uv run bot")
        #expect(commands(scan(["pyproject.toml": pyproject, "poetry.lock": ""])).first == "poetry run bot")
        #expect(commands(scan(["pyproject.toml": pyproject, "pdm.lock": ""])).first == "pdm run bot")
    }

    @Test func poetryAndPDMScriptsAlwaysRunThroughTheirOwnTool() {
        let pyproject = """
        [tool.poetry.scripts]
        app = "app:main"
        [tool.pdm.scripts]
        start = "flask run"
        """
        #expect(commands(scan(["pyproject.toml": pyproject])) == ["poetry run app", "pdm run start"])
        #expect(scan(["pyproject.toml": "[project\nbroken"]).tasks.isEmpty)
    }

    // MARK: Cargo.toml

    @Test func cargoGivesItsUsualCommandsAndEachBin() {
        let package = "[package]\nname = \"tool\"\nversion = \"0.1.0\"\n"
        #expect(commands(scan(["Cargo.toml": package])) == ["cargo build", "cargo run", "cargo test", "cargo clippy"])
        let oneBin = package + "[[bin]]\nname = \"server\"\npath = \"src/server.rs\"\n"
        #expect(commands(scan(["Cargo.toml": oneBin])) == ["cargo build", "cargo run", "cargo test", "cargo clippy",
                                                           "cargo run --bin server"])
        let twoBins = oneBin + "[[bin]]\nname = \"worker\"\n"
        #expect(commands(scan(["Cargo.toml": twoBins])) == ["cargo build", "cargo test", "cargo clippy",
                                                            "cargo run --bin server", "cargo run --bin worker"])
        let defaulted = twoBins.replacingOccurrences(of: "version = \"0.1.0\"", with: "default-run = \"server\"")
        #expect(commands(scan(["Cargo.toml": defaulted])).contains("cargo run"))
    }

    @Test func aCargoWorkspaceBuildsAndTestsButRunsNothing() {
        let workspace = "[workspace]\nmembers = [\"crates/a\", \"crates/b\"]\n"
        #expect(commands(scan(["Cargo.toml": workspace])) == ["cargo build", "cargo test", "cargo clippy"])
        #expect(scan(["Cargo.toml": "[dependencies]\nserde = \"1\"\n"]).tasks.isEmpty)
    }

    // MARK: Gradle

    @Test func gradleWrapperTasksAreWellKnownOnesOnly() {
        let app = "plugins {\n    id(\"com.android.application\")\n}\n"
        #expect(commands(scan(["gradlew": "#!/bin/sh\n", "app/build.gradle.kts": app]))
            == ["./gradlew assembleDebug", "./gradlew installDebug", "./gradlew test"])
        let catalog = "plugins {\n    alias(libs.plugins.android.application) apply false\n}\n"
        #expect(commands(scan(["gradlew": "", "build.gradle.kts": catalog])).contains("./gradlew installDebug"))
        let library = "plugins { id 'com.android.library' }\n"
        #expect(commands(scan(["gradlew": "", "build.gradle": library])) == ["./gradlew assembleDebug", "./gradlew test"])
        #expect(commands(scan(["gradlew": "", "build.gradle.kts": "plugins { java }\n"])) == ["./gradlew build", "./gradlew test"])
        #expect(scan(["build.gradle.kts": app]).tasks.isEmpty) // no wrapper, no rows
    }

    // MARK: the whole read

    @Test func aProjectListsEachFilesTasksInOneOrder() {
        let result = scan(["package.json": #"{"scripts": {"dev": "vite"}}"#, "Makefile": "check:\n\techo ok\n",
                           "Cargo.toml": "[package]\nname = \"x\"\n"])
        #expect(result.tasks.map(\.file) == ["package.json", "Makefile", "Cargo.toml", "Cargo.toml", "Cargo.toml", "Cargo.toml"])
        #expect(result.needs == [.cargo])
        #expect(scan(["README.md": "# hi\n"]) == RunScan())
    }

    @Test func needsComeOnlyFromTheFilesThatNeedATool() {
        #expect(scan(["pyproject.toml": "[project]\nname = \"a\"\n"]).needs.isEmpty)
        #expect(scan(["pyproject.toml": "[project]\nname = \"a\"\n", "uv.lock": ""]).needs == [.uv])
        #expect(scan(["pyproject.toml": "[tool.uv]\npackage = true\n"]).needs == [.uv])
        #expect(scan(["uv.lock": ""]).needs.isEmpty) // a lock with no pyproject runs nothing
        #expect(scan(["Cargo.toml": "[package]\nname = \"a\"\n"]).needs == [.cargo])
        #expect(scan(["gradlew": ""]).needs == [.jdk])
        #expect(scan(["package.json": #"{"scripts": {"dev": "vite"}}"#]).needs.isEmpty)
    }
}

/// When a tool is offered, and what Install… does.
@Suite struct ProjectToolsTests {
    /// A Mac with these executables and these folder listings, and nothing else.
    func look(_ executables: Set<String>, path: [String] = ["/usr/bin", "/opt/homebrew/bin"],
              folders: [String: [String]] = [:]) -> ProjectTools.Look {
        ProjectTools.Look(path: path, home: "/Users/me", isExecutable: { executables.contains($0) },
                          entries: { folders[$0] ?? [] })
    }

    @Test func aToolOnPathIsNeverOffered() {
        let mac = look(["/opt/homebrew/bin/uv", "/opt/homebrew/bin/cargo"])
        #expect(ProjectTools.offers(for: [.uv, .cargo], mac).isEmpty)
    }

    @Test func aMissingToolIsOfferedWithItsOfficialInstallerTypedNotRun() {
        let offers = ProjectTools.offers(for: [.uv, .cargo], look([]))
        #expect(offers.map(\.tool) == [.uv, .cargo])
        #expect(offers[0].action == .type("curl -LsSf https://astral.sh/uv/install.sh | sh"))
        #expect(offers[1].action == .type("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"))
        #expect(offers[0].text == "uv isn’t installed" && ToolOffer.install == "Install…")
        #expect(offers[1].tabTitle == "Install cargo")
        for tool in ProjectTool.catalog { #expect(!tool.installer.contains("sudo"), "\(tool.id)") }
    }

    @Test func nothingIsOfferedThatTheProjectDoesNotNeed() {
        #expect(ProjectTools.offers(for: [], look([])).isEmpty)
    }

    @Test func aCopyInItsInstallersOwnFolderCountsBeforePathHasIt() {
        #expect(ProjectTools.isInstalled(.cargo, look(["/Users/me/.cargo/bin/cargo"])))
        #expect(ProjectTools.isInstalled(.uv, look(["/Users/me/.local/bin/uv"])))
        #expect(!ProjectTools.isInstalled(.uv, look(["/Users/me/.local/bin/cargo"])))
    }

    @Test func macOSsJavaStubIsNoJDK() {
        let stubOnly = look(["/usr/bin/java", "/opt/homebrew/bin/brew"])
        #expect(!ProjectTools.isInstalled(.jdk, stubOnly))
        #expect(ProjectTools.offers(for: [.jdk], stubOnly).first?.action == .type("brew install --cask temurin"))
        #expect(ProjectTools.offers(for: [.jdk], stubOnly).first?.text == "Java isn’t installed")
        #expect(ProjectTools.isInstalled(.jdk, look(["/usr/bin/java", "/opt/homebrew/opt/sdk/bin/java"],
                                                    path: ["/opt/homebrew/opt/sdk/bin", "/usr/bin"])))
    }

    @Test func aJDKMacOSKnowsCountsWithoutJavaOnPath() {
        let system = look([], folders: ["/Library/Java/JavaVirtualMachines": ["temurin-21.jdk"]])
        #expect(ProjectTools.isInstalled(.jdk, system))
        let mine = look([], folders: ["/Users/me/Library/Java/JavaVirtualMachines": ["openjdk-17.jdk"]])
        #expect(ProjectTools.isInstalled(.jdk, mine))
        let hidden = look([], folders: ["/Library/Java/JavaVirtualMachines": [".DS_Store"]])
        #expect(!ProjectTools.isInstalled(.jdk, hidden))
    }

    @Test func withoutHomebrewTheJDKOfferOpensItsPage() {
        let offer = ProjectTools.offers(for: [.jdk], look([], path: ["/usr/bin"])).first
        #expect(offer?.action == .open("https://adoptium.net/"))
        // Homebrew in its own place counts, before the shell's PATH has it.
        let brewed = look(["/opt/homebrew/bin/brew"], path: ["/usr/bin"])
        #expect(ProjectTools.offers(for: [.jdk], brewed).first?.action == .type("brew install --cask temurin"))
    }
}
