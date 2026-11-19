import Foundation
import Testing
@testable import NextTermCore

/// Model servers on this Mac in Services (plan 044, item 2): each signal that names Ollama, LM Studio or vLLM, the
/// base-URL key on Ollama's port that is Ollama's and not OpenAI's, the model names a pull may take, and the offers.
/// Every project, key and value here is made up.
@Suite struct LocalModelsTests {
    func row(_ files: [String: String], _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ServiceRow {
        let scan = FixtureProject(files).services()
        expectNoSecret(scan, sourceLocation: sourceLocation)
        return try #require(scan.rows.first { (row: ServiceRow) -> Bool in row.id == id }, "\(scan.rows.map(\.id))",
                            sourceLocation: sourceLocation)
    }

    func ids(_ files: [String: String]) -> [String] {
        FixtureProject(files).services().rows.map(\.id)
    }

    // MARK: each signal

    @Test(arguments: [
        [".env": "OLLAMA_HOST=127.0.0.1:11434\n"],
        [".env": "OLLAMA_BASE_URL=http://localhost:11434\n"],
        [".env.example": "OLLAMA_HOST=\n"],
        ["requirements.txt": "ollama>=0.5\n"],
        ["requirements.txt": "langchain_ollama\n"],
        ["pyproject.toml": "[project]\nname = \"rag\"\ndependencies = [\"llama-index-llms-ollama>=0.6\"]\n"],
        ["package.json": #"{"dependencies": {"ollama": "^0.5.0"}}"#],
        ["package.json": #"{"dependencies": {"ollama-ai-provider": "^1.2.0"}}"#],
        ["Cargo.toml": "[package]\nname = \"bot\"\n\n[dependencies]\nollama-rs = \"0.3\"\n"],
        ["compose.yaml": composeFile("llm", "ollama/ollama:latest", ["11434:11434"])],
        ["package.json": #"{"scripts": {"llm": "ollama serve"}}"#],
        [".env": "OPENAI_BASE_URL=http://localhost:11434/v1\n"],
        [".env": "LLM_BASE_URL=http://127.0.0.1:11434\n"],
    ])
    func eachSignalNamesOllama(_ files: [String: String]) throws {
        let ollama = try row(files, "ollama.local")
        #expect(ollama.kind == .aiModel && ollama.place == .local && ollama.isLocal)
        #expect(ollama.name == "Ollama")
        #expect(ollama.link.badge == ":11434")
        #expect(ollama.link.url.port == 11434 && ollama.link.url.path == "/api/tags")
        #expect(LoopbackPorts.isLoopback(ollama.link.url.host ?? ""))
        #expect(ollama.link.title == "Open Ollama Models")
        #expect(ollama.detail.hasPrefix("AI model · "))
    }

    @Test func aBaseURLOnOllamasPortIsOllamaNotOpenAI() throws {
        let files = [".env": "OPENAI_API_KEY=NOT-A-KEY\nOPENAI_BASE_URL=http://localhost:11434/v1\n",
                     "requirements.txt": "openai\n"]
        #expect(ids(files) == ["ollama.local"])
        let ollama = try row(files, "ollama.local")
        #expect(ollama.sources == [ServiceSource(file: ".env", names: ["OPENAI_BASE_URL"])])
    }

    @Test func aBaseURLOnLMStudiosPortIsLMStudio() throws {
        let files = [".env": "OPENAI_BASE_URL=http://localhost:1234/v1\n", "requirements.txt": "openai\n"]
        #expect(ids(files) == ["lm-studio.local"])
        let studio = try row(files, "lm-studio.local")
        #expect(studio.link.url.absoluteString == "http://localhost:1234/v1/models" && studio.link.badge == ":1234")
        #expect(studio.runtime?.start == "lms server start" && studio.runtime?.pull == nil)
        #expect(studio.runtime?.baseURL == "http://localhost:1234/v1")
        #expect(studio.runtime?.tool == .lmStudio)
    }

    @Test func lmStudiosStartCommandGivesItsPort() throws {
        let studio = try row(["Makefile": "llm:\n\tlms server start --port 1240\n"], "lm-studio.local")
        #expect(studio.link.url.absoluteString == "http://localhost:1240/v1/models")
    }

    @Test func vllmOpensItsModelsAndHasNoStartOrOffer() throws {
        let vllm = try row(["package.json": #"{"scripts": {"serve": "vllm serve meta-llama/Llama-3.2-1B"}}"#], "vllm.local")
        #expect(vllm.link.url.absoluteString == "http://localhost:8000/v1/models")
        #expect(vllm.runtime?.start == nil && vllm.runtime?.tool == nil)
        #expect(vllm.runtime?.baseURL == "http://localhost:8000/v1")
    }

    @Test func otherPortsAndRemoteHostsNameNoModelServer() {
        #expect(ids([".env": "OPENAI_BASE_URL=http://localhost:8080/v1\n"]).isEmpty)
        #expect(ids([".env": "SEARCH_BASE_URL=http://localhost:11435\n"]).isEmpty)
        #expect(!ids([".env": "OPENAI_BASE_URL=https://llm.example.com:11434/v1\n"]).contains("ollama.local"))
        #expect(ids(["requirements.txt": "ollama-utils\n"]).isEmpty)
    }

    @Test func ollamasHostGivesItsPortAndTheAnyAddressIsLocalhost() throws {
        let custom = try row([".env": "OLLAMA_HOST=http://127.0.0.1:11500\n"], "ollama.local")
        #expect(custom.link.url.absoluteString == "http://127.0.0.1:11500/api/tags" && custom.link.badge == ":11500")
        let bound = try row([".env": "OLLAMA_HOST=0.0.0.0\n"], "ollama.local")
        #expect(bound.link.url.absoluteString == "http://localhost:11434/api/tags")
        #expect(bound.runtime?.baseURL == "http://localhost:11434")
    }

    @Test func aComposeServicePublishesOllamasPort() throws {
        let files = ["compose.yaml": composeFile("llm", "ollama/ollama", ["11500:11434"]),
                     ".env": "OLLAMA_HOST=http://llm:11434\n"]
        let ollama = try row(files, "ollama.local")
        #expect(ollama.link.url.absoluteString == "http://localhost:11500/api/tags")
    }

    // MARK: the menu's commands

    @Test func ollamasMenuStartsPullsTheFilesModelsAndCopiesItsBaseURL() throws {
        let files = [".env": "OLLAMA_HOST=http://localhost:11434\nOLLAMA_MODEL=llama3.2\nOLLAMA_EMBED_MODEL=nomic-embed-text:v1.5\n",
                     ".env.local": "OLLAMA_MODEL=llama3.2\n"]
        let runtime = try #require(try row(files, "ollama.local").runtime)
        #expect(runtime.start == "ollama serve" && runtime.pull == "ollama pull")
        #expect(Set(runtime.models) == ["llama3.2", "nomic-embed-text:v1.5"] && runtime.models.count == 2)
        #expect(runtime.pullCommand("llama3.2") == "ollama pull llama3.2")
        #expect(runtime.baseURL == "http://localhost:11434")
        #expect(runtime.tool == .ollama)
    }

    @Test func onlyAModelNameIsTypedNeverMore() {
        #expect(LocalRuntime.isModelName("qwen3:8b") && LocalRuntime.isModelName("deepseek-r1:1.5b"))
        for bad in ["", "llama3; rm -rf ~", "$(whoami)", "a b", "-flag", "llama3:", "x:y:z"] {
            #expect(!LocalRuntime.isModelName(bad), "\(bad)")
        }
        let runtime = LocalRuntime(start: nil, pull: "ollama pull", models: [], baseURL: "http://localhost:11434", tool: nil)
        #expect(runtime.pullCommand("a b") == nil)
    }

    @Test func modelKeysOutsideOllamasAreNotItsModels() throws {
        let files = [".env": "OLLAMA_HOST=localhost:11434\nOPENAI_MODEL=gpt-4o\nOLLAMA_MODELS=/Volumes/models\n"]
        #expect(try row(files, "ollama.local").runtime?.models == [])
    }

    @Test func aSecretShapedBaseURLKeyIsNeverRead() {
        let facts = ProjectFacts.read(root: FixtureProject([".env": "OLLAMA_TOKEN_BASE_URL=http://localhost:11434\n"]).root,
                                      valueKeys: [:], valuePatterns: ServiceCatalog.valuePatterns)
        #expect(facts.envValues.isEmpty)
    }

    // MARK: offers

    func look(_ executables: Set<String>, path: [String] = ["/usr/bin", "/opt/homebrew/bin"],
              folders: [String: [String]] = [:]) -> ProjectTools.Look {
        ProjectTools.Look(path: path, home: "/Users/me", isExecutable: { executables.contains($0) },
                          entries: { folders[$0] ?? [] })
    }

    @Test func aProjectNamingOllamaNeedsItAndOneWithoutDoesNot() {
        #expect(FixtureProject([".env": "OLLAMA_HOST=localhost:11434\n"]).services().tools == [.ollama])
        #expect(FixtureProject([".env": "OPENAI_BASE_URL=http://localhost:1234/v1\n"]).services().tools == [.lmStudio])
        #expect(FixtureProject(["Makefile": "a:\n\tvllm serve m\n"]).services().tools.isEmpty)
        #expect(FixtureProject([".env": "OPENAI_API_KEY=NOT-A-KEY\n"]).services().tools.isEmpty)
    }

    @Test func missingOllamaIsOfferedThroughHomebrewTypedNotRun() {
        let offers = ProjectTools.offers(for: [.ollama, .lmStudio], look(["/opt/homebrew/bin/brew"]))
        #expect(offers.map(\.action) == [.type("brew install ollama"), .type("brew install --cask lm-studio")])
        #expect(offers.map(\.text) == ["Ollama isn’t installed", "LM Studio isn’t installed"])
        #expect(offers.map(\.tabTitle) == ["Install Ollama", "Install LM Studio"])
    }

    @Test func withoutHomebrewTheOfferOpensTheDownloadPage() {
        let offers = ProjectTools.offers(for: [.ollama, .lmStudio], look([], path: ["/usr/bin"]))
        #expect(offers.map(\.action) == [.open("https://ollama.com/download"), .open("https://lmstudio.ai/download")])
    }

    @Test func theAppOrTheCommandCountsAsACopy() {
        #expect(ProjectTools.isInstalled(.ollama, look([], folders: ["/Applications": ["Ollama.app"]])))
        #expect(ProjectTools.isInstalled(.ollama, look([], folders: ["/Users/me/Applications": ["Ollama.app"]])))
        #expect(ProjectTools.isInstalled(.ollama, look(["/usr/local/bin/ollama"], path: ["/usr/local/bin"])))
        #expect(ProjectTools.isInstalled(.lmStudio, look([], folders: ["/Applications": ["LM Studio.app"]])))
        #expect(ProjectTools.isInstalled(.lmStudio, look(["/Users/me/.lmstudio/bin/lms"])))
        #expect(!ProjectTools.isInstalled(.ollama, look([], folders: ["/Applications": ["Safari.app", "LM Studio.app"]])))
        let installed = look(["/opt/homebrew/bin/brew"], folders: ["/Applications": ["Ollama.app"]])
        #expect(ProjectTools.offers(for: [.ollama], installed).isEmpty)
    }
}

/// The "is it up" look (plan 044, item 3), with a made-up connector: which rows it looks at, each port once, and
/// IPv6's loopback when IPv4's does not answer.
@Suite struct LoopbackPortsTests {
    final class FakeConnector: PortConnector, @unchecked Sendable {
        let open: Set<String>
        private(set) var asked: [String] = []
        private let lock = NSLock()

        init(_ open: Set<String>) { self.open = open }

        func answers(host: String, port: Int, timeout: TimeInterval) -> Bool {
            lock.withLock { asked.append("\(host) \(port)") }
            return open.contains("\(host) \(port)")
        }
    }

    func rows(_ files: [String: String]) -> [ServiceRow] { FixtureProject(files).services().rows }

    @Test func onlyLocalRowsWithAPortOnThisMacAreLookedAt() {
        let scan = rows([".env": "OLLAMA_HOST=localhost:11434\nOPENAI_API_KEY=NOT-A-KEY\n",
                         "package.json": #"{"dependencies": {"vite": "^7.0.0"}}"#, "herd.yml": "name: shop\n"])
        #expect(LoopbackPorts.ports(scan) == ["ollama.local": 11434, "vite.local": 5173])
    }

    @Test func aRowIsUpWhenItsPortAnswers() {
        let scan = rows([".env": "OLLAMA_HOST=localhost:11434\n", "package.json": #"{"dependencies": {"vite": "^7.0.0"}}"#])
        let connector = FakeConnector(["127.0.0.1 11434"])
        #expect(LoopbackPorts.check(scan, connector: connector) == ["ollama.local"])
        #expect(Set(connector.asked) == ["127.0.0.1 11434", "127.0.0.1 5173", "::1 5173"],
                "IPv6 only when IPv4 does not answer")
    }

    @Test func aServerOnIPv6AloneCounts() {
        let scan = rows([".env": "OLLAMA_HOST=localhost:11434\n"])
        #expect(LoopbackPorts.check(scan, connector: FakeConnector(["::1 11434"])) == ["ollama.local"])
    }

    @Test func nothingAnswersNothingIsUpAndNoRowsAskNothing() {
        let scan = rows([".env": "OLLAMA_HOST=localhost:11434\n"])
        #expect(LoopbackPorts.check(scan, connector: FakeConnector([])).isEmpty)
        let none = FakeConnector(["127.0.0.1 443"])
        #expect(LoopbackPorts.check(rows([".env": "OPENAI_API_KEY=NOT-A-KEY\n"]), connector: none).isEmpty)
        #expect(none.asked.isEmpty)
    }

    @Test func rowsSharingAPortAreLookedAtOnce() {
        let scan = rows(["package.json": #"{"dependencies": {"next": "^15.0.0", "nuxt": "^4.0.0"}}"#])
        let connector = FakeConnector(["127.0.0.1 3000"])
        #expect(LoopbackPorts.check(scan, connector: connector) == ["nextjs.local", "nuxt.local"])
        #expect(connector.asked == ["127.0.0.1 3000"])
    }

    @Test func loopbackHostsAreThisMacOnly() {
        for host in ["localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]", "0.0.0.0"] {
            #expect(LoopbackPorts.isLoopback(host), "\(host)")
        }
        for host in ["shop.test", "example.com", "127.0.0.1.nip.io", "10.0.0.1"] {
            #expect(!LoopbackPorts.isLoopback(host), "\(host)")
        }
    }

    /// The real connector, against a listener of this test's own on a free port, then after it closes.
    @Test func theSocketConnectorSeesAListenerComeAndGo() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(fd, 4) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let connector = SocketConnector()
        #expect(connector.answers(host: "127.0.0.1", port: port, timeout: 0.5))
        close(fd)
        #expect(!connector.answers(host: "127.0.0.1", port: port, timeout: 0.5))
        #expect(!connector.answers(host: "example.com", port: 80, timeout: 0.5), "never a host off this Mac")
    }
}
