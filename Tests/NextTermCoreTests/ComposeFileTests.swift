import Foundation
import Testing
@testable import NextTermCore

/// Compose files read for a service's image and the ports it publishes on this Mac, and nothing else. Every image,
/// name and value here is made up.
@Suite struct ComposeFileTests {
    func published(_ entry: String, _ variables: [String: Int] = [:]) -> Int? {
        ComposeFile.port(short: entry, portVariables: variables)?.published
    }

    @Test func shortPortsGiveTheHostSide() {
        #expect(published("6334:6333") == 6334)
        #expect(published("127.0.0.1:6334:6333/tcp") == 6334)
        #expect(published("0.0.0.0:6334:6333") == 6334)
        #expect(published("[::1]:6334:6333") == 6334)
        #expect(published("::1:6334:6333") == 6334)
        #expect(ComposeFile.port(short: "6334:6333", portVariables: [:])?.target == 6333)
        // Not published on a fixed port of this Mac: the container side only, a range, another address, no host
        // port, UDP, or not a port at all.
        for entry in ["6333", "6000-6005:6000-6005", "6000-6005:6000", "192.168.1.5:6334:6333", "10.0.0.2:80:80",
                      "127.0.0.1::6333", "6334:6333/udp", "0:80", "70000:80", "abc:80", "", ":", "6334:"] {
            #expect(published(entry) == nil, "\(entry)")
        }
    }

    @Test func aPortFromAVariable() {
        #expect(published("${QDRANT_PORT:-6334}:6333") == 6334)
        #expect(published("${QDRANT_PORT:-6334}:6333", ["QDRANT_PORT": 7000]) == 7000)
        #expect(published("${QDRANT_PORT-6334}:6333", ["QDRANT_PORT": 7000]) == 7000)
        #expect(published("${WEB_PORT}:80", ["WEB_PORT": 8100]) == 8100)
        #expect(published("$WEB_PORT:80", ["WEB_PORT": 8100]) == 8100)
        #expect(published("${WEB_PORT:?set it}:80", ["WEB_PORT": 8100]) == 8100)
        // Unset with no default, or a form that gives no value of its own.
        #expect(published("${WEB_PORT}:80") == nil)
        #expect(published("${WEB_PORT:?set it}:80") == nil)
        #expect(published("${WEB_PORT:+1}:80", ["WEB_PORT": 8100]) == nil)
        // A name that is not a port's, or that marks a secret, is never looked up, even when handed over.
        #expect(published("${DB_PASSWORD:-8080}:80", ["DB_PASSWORD": 31337]) == 8080)
        #expect(published("${SECRET_PORT:-8080}:80", ["SECRET_PORT": 31337]) == 8080)
        #expect(published("${APP_NAME:-8080}:80", ["APP_NAME": 31337]) == 8080)
        #expect(published("${BIND_ADDRESS:-127.0.0.1}:6334:6333") == 6334)
        #expect(published("${BIND_ADDRESS:-192.168.1.5}:6334:6333") == nil)
    }

    @Test func whichVariablesMayBeRead() {
        for name in ["PORT", "WEB_PORT", "QDRANT_PORT", "N8N_PORT", "langfusePort"] {
            #expect(ComposeFile.mayReadVariable(name), "\(name)")
        }
        for name in ["DB_PASSWORD", "SECRET_PORT", "PORT_TOKEN", "PORTAL_URL", "SUPPORT", "HOST", "API_KEY"] {
            #expect(!ComposeFile.mayReadVariable(name), "\(name)")
        }
    }

    @Test func imageNamesLoseRegistryTagAndDigest() {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        #expect(ComposeFile.imageName("docker.io/qdrant/qdrant:v1.15.0@" + digest) == "qdrant/qdrant")
        #expect(ComposeFile.imageName("qdrant/qdrant") == "qdrant/qdrant")
        #expect(ComposeFile.imageName("Qdrant/Qdrant:Latest") == "qdrant/qdrant")
        #expect(ComposeFile.imageName("ghcr.io/berriai/litellm:main-latest") == "berriai/litellm")
        #expect(ComposeFile.imageName("docker.langfuse.com/langfuse/langfuse:3") == "langfuse/langfuse")
        #expect(ComposeFile.imageName("cr.weaviate.io/semitechnologies/weaviate:1.30.0") == "semitechnologies/weaviate")
        #expect(ComposeFile.imageName("localhost:5000/team/app:1") == "team/app")
        #expect(ComposeFile.imageName("postgres:16") == "postgres")
        #expect(ComposeFile.imageName("docker.io/library/postgres:16") == "postgres")
        #expect(ComposeFile.imageName("library/postgres") == "postgres")
        #expect(ComposeFile.imageName("qdrant/qdrant:${QDRANT_TAG:-latest}") == "qdrant/qdrant")
        #expect(ComposeFile.imageName("\"qdrant/qdrant:v1\"") == "qdrant/qdrant")
        for reference in ["${REGISTRY}/qdrant/qdrant", "$IMAGE", "", "qdrant qdrant", "q/../x", "@" + digest] {
            #expect(ComposeFile.imageName(reference) == nil, "\(reference)")
        }
    }

    static let rag = """
    # A made-up RAG stack.
    name: rag-demo
    x-defaults: &defaults
      restart: unless-stopped

    services:
      qdrant:
        image: docker.io/qdrant/qdrant:v1.15.0
        environment:
          QDRANT__SERVICE__API_KEY: NOT-A-KEY
          PORTS: "9999:80"
        ports:
          - "6334:6333"   # the dashboard
          - 6335:6334
        volumes:
          - ./data:/qdrant/storage
      langfuse:
        image: "langfuse/langfuse:3"
        env_file: .env
        ports: ["3030:3000", "127.0.0.1:3031:3001/tcp"]
      litellm:
        image: ghcr.io/berriai/litellm:main-latest
        ports:
          - target: 4000
            published: "4100"
            host_ip: 127.0.0.1
            protocol: tcp
          - {target: 4001, published: 4101}
          - target: 4002
            published: "4200-4210"
          - target: 4003
            published: 4300
            host_ip: 192.168.1.5
      worker:
        <<: *defaults
        image: example/worker:1
        ports:
          - "7000:7000"
      api:
        build: .
        ports:
          - "8000:8000"
    volumes:
      data: {}
    """

    @Test func servicesWithTheirImageAndPorts() throws {
        let services = ComposeFile.parse(Self.rag)
        #expect(services.map(\.name) == ["qdrant", "langfuse", "litellm", "api"])
        let qdrant = try #require(services.first)
        #expect(qdrant.image == "qdrant/qdrant")
        #expect(qdrant.ports == [ComposePort(published: 6334, target: 6333), ComposePort(published: 6335, target: 6334)])
        let langfuse = try #require(services.first { (service: ComposeService) -> Bool in service.name == "langfuse" })
        #expect(langfuse.image == "langfuse/langfuse")
        #expect(langfuse.ports.map(\.published) == [3030, 3031])
        let litellm = try #require(services.first { (service: ComposeService) -> Bool in service.name == "litellm" })
        #expect(litellm.image == "berriai/litellm")
        #expect(litellm.ports == [ComposePort(published: 4100, target: 4000), ComposePort(published: 4101, target: 4001)])
        let api = try #require(services.last)
        #expect(api.image == nil)
        #expect(api.ports.map(\.published) == [8000])
    }

    @Test func environmentIsNeverRead() {
        let services = ComposeFile.parse(Self.rag)
        let text = String(describing: services) + String(reflecting: services)
        #expect(!text.contains("NOT-A-KEY"))
        #expect(!text.contains("9999"))
        #expect(!text.contains("QDRANT__SERVICE"))
    }

    @Test func aServiceWithAnAnchorAliasOrMergeKeyIsSkipped() {
        let text = """
        services:
          merged:
            <<: *defaults
            image: example/a
          anchored: &anchored
            image: example/b
          aliased: *anchored
          aliasedPorts:
            image: example/c
            ports: *ports
          anchoredImage:
            image: &img example/d
          plain:
            image: example/e
            ports:
              - "8080:80"
        """
        let services = ComposeFile.parse(text)
        #expect(services.map(\.name) == ["plain"])
    }

    @Test func layoutsAndOddities() {
        let fourSpaces = "services:\n    web:\n        image: example/web\n        ports:\n            - \"8081:80\"\n"
        #expect(ComposeFile.parse(fourSpaces).first?.ports.map(\.published) == [8081])
        let quotedName = "services:\n  \"web\":\n    image: 'example/web'\n    ports: [ '8082:80' ]\n"
        #expect(ComposeFile.parse(quotedName).first?.name == "web")
        #expect(ComposeFile.parse(quotedName).first?.ports.map(\.published) == [8082])
        let crlf = "services:\r\n  web:\r\n    image: example/web\r\n    ports:\r\n      - \"8083:80\"\r\n"
        #expect(ComposeFile.parse(crlf).first?.ports.map(\.published) == [8083])
        // No services block at the top, an empty one, or not YAML at all.
        #expect(ComposeFile.parse("version: '3'\nother:\n  services:\n    web:\n      image: x/y\n").isEmpty)
        #expect(ComposeFile.parse("services: {}\n").isEmpty)
        #expect(ComposeFile.parse("\u{0}\u{1}not yaml").isEmpty)
    }

    @Test func aPortFromTheProjectEnv() {
        let text = "services:\n  qdrant:\n    image: qdrant/qdrant\n    ports:\n      - \"${QDRANT_PORT:-6334}:6333\"\n"
        #expect(ComposeFile.parse(text).first?.ports.map(\.published) == [6334])
        #expect(ComposeFile.parse(text, portVariables: ["QDRANT_PORT": 7100]).first?.ports.map(\.published) == [7100])
    }
}
