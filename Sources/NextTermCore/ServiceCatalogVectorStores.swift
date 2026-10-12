import Foundation

// Vector stores, most used first (last month's downloads of each one's own client). A store on this Mac, run by
// Compose or named by a URL to it, opens its own page on the port the files give; one in a provider's cloud opens its
// console. A store named only by its client package makes no row: it may run inside the program, with no page.

extension ServiceCatalog {
    static let vectorStores: [ServiceEntry] = [qdrant, weaviate, lanceDB, chroma, pinecone, milvus]

    // MARK: Qdrant, Weaviate, LanceDB

    static let qdrantSignals: [Signal] = [
        .origin("QDRANT_URL", nil), .image("qdrant/qdrant"),
        .dependency(.pypi, "qdrant-client"), .dependency(.pypi, "langchain-qdrant"),
        .dependency(.npm, "@qdrant/js-client-rest"),
    ]
    /// The dashboard is served on the API's own port, 6333, on this Mac and in Qdrant Cloud alike.
    static let qdrantServer = OriginRule(["QDRANT_URL"], localPort: 6333, remotePort: 6333)
    static let qdrantCompose = LocalPort("localhost", [.compose("qdrant/qdrant", target: 6333)], default: nil)
    static let qdrantLinks: [LinkTemplate] = [
        LinkTemplate("dashboard", "Dashboard", .configured(qdrantServer), path: [.text("/dashboard")]),
        LinkTemplate("dashboard", "Dashboard", .local(qdrantCompose), path: [.text("/dashboard")]),
        .web("console", "Console", "cloud.qdrant.io", extra: true, when: .origin("QDRANT_URL", .domain("cloud.qdrant.io"))),
    ]
    static let qdrant = ServiceEntry("qdrant", "Qdrant", kind: .vectorStore, rank: 1, place: nil, signals: qdrantSignals,
                                     values: ["QDRANT_URL": .url], links: qdrantLinks)

    /// A cluster's URL may be written without its scheme. A Weaviate on this Mac has no page, so it makes no row.
    static let weaviateKeys = ["WEAVIATE_URL", "WCD_URL"]
    static let weaviateSignals: [Signal] = weaviateKeys.flatMap { (key: String) -> [Signal] in
        [.origin(key, .domain("weaviate.cloud")), .origin(key, .domain("weaviate.network"))]
    } + [.dependency(.pypi, "weaviate-client"), .dependency(.npm, "weaviate-client")]
    static let weaviate = ServiceEntry("weaviate", "Weaviate", kind: .vectorStore, rank: 2, place: nil,
                                       signals: weaviateSignals, values: ["WEAVIATE_URL": .url, "WCD_URL": .url],
                                       links: [.web("console", "Console", "console.weaviate.cloud")])

    /// LanceDB Cloud's URIs are `db://<database>`; a local table is a folder, with no page.
    static let lanceDB = ServiceEntry("lancedb", "LanceDB", cloudName: "LanceDB Cloud", kind: .vectorStore, rank: 3,
                                      place: .cloud, signals: [.scheme("LANCEDB_URI", "db")],
                                      values: ["LANCEDB_URI": .url],
                                      links: [.web("dashboard", "Dashboard", "cloud.lancedb.com", badge: "Cloud")])
}

// MARK: - Chroma, Pinecone, Milvus

extension ServiceCatalog {
    static let chromaSignals: [Signal] = [
        .origin("CHROMA_HOST", nil), .image("chromadb/chroma"),
        .dependency(.pypi, "chromadb"), .dependency(.pypi, "langchain-chroma"), .dependency(.npm, "chromadb"),
    ]
    /// Chroma's server answers on 8000, where `/docs` is its API explorer.
    static let chromaServer = OriginRule(["CHROMA_HOST"], portKeys: ["CHROMA_PORT"], localPort: 8000)
    static let chromaCompose = LocalPort("localhost", [.compose("chromadb/chroma", target: 8000)], default: nil)
    static let chromaLinks: [LinkTemplate] = [
        .web("dashboard", "Dashboard", "www.trychroma.com", "/dashboard",
             when: .origin("CHROMA_HOST", .domain("trychroma.com"))),
        LinkTemplate("docs", "API Docs", .configured(chromaServer), path: [.text("/docs")]),
        LinkTemplate("docs", "API Docs", .local(chromaCompose), path: [.text("/docs")]),
    ]
    static let chroma = ServiceEntry("chroma", "Chroma", kind: .vectorStore, rank: 4, place: nil, signals: chromaSignals,
                                     values: ["CHROMA_HOST": .host, "CHROMA_PORT": .port], links: chromaLinks)

    /// Pinecone runs only in its cloud: Pinecone Local has reached its end of life. `-` is Pinecone's own wildcard
    /// for the organization and the project the user is signed in to.
    static let pineconeSignals: [Signal] = [
        .key("PINECONE_API_KEY"),
        .dependency(.pypi, "pinecone"), .dependency(.pypi, "pinecone-client"), .dependency(.pypi, "langchain-pinecone"),
        .dependency(.npm, "@pinecone-database/pinecone"), .host(.domain("pinecone.io")),
    ]
    static let pinecone = ServiceEntry("pinecone", "Pinecone", kind: .vectorStore, rank: 5, place: .cloud,
                                       signals: pineconeSignals,
                                       values: ["PINECONE_HOST": .url, "PINECONE_INDEX_HOST": .url],
                                       links: [.web("indexes", "Console", "app.pinecone.io",
                                                    "/organizations/-/projects/-/indexes")])

    /// Milvus on this Mac opens its WebUI (2.5 and later), and Attu beside it when Compose runs it; Zilliz Cloud
    /// opens its console. A `MILVUS_URI` that is a file (`./milvus.db`) is Milvus Lite, inside the program: no row.
    static let milvusKeys = ["MILVUS_URI", "ZILLIZ_CLOUD_URI"]
    static let milvusHosts: [HostMatch] = [
        .domain("zillizcloud.com"), .domain("cloud.zilliz.com"), .domain("localhost"), .domain("127.0.0.1"),
    ]
    static let milvusSignals: [Signal] = milvusKeys.flatMap { (key: String) -> [Signal] in
        milvusHosts.map { (match: HostMatch) -> Signal in .origin(key, match) }
    } + [.image("milvusdb/milvus"), .image("zilliz/attu"), .dependency(.pypi, "pymilvus")]
    static let milvusLinks: [LinkTemplate] = [
        LinkTemplate("webui", "WebUI", .local(LocalPort("localhost", [.compose("milvusdb/milvus", target: 9091)], default: 9091)),
                     path: [.text("/webui")]),
        .web("console", "Console", "cloud.zilliz.com", badge: "Cloud"),
        LinkTemplate("attu", "Attu", .local(LocalPort("localhost", [.compose("zilliz/attu", target: 3000)], default: nil)),
                     extra: true),
    ]
    static let milvus = ServiceEntry("milvus", "Milvus", cloudName: "Zilliz Cloud", kind: .vectorStore, rank: 6,
                                     place: nil, signals: milvusSignals,
                                     values: ["MILVUS_URI": .url, "ZILLIZ_CLOUD_URI": .url], links: milvusLinks)
}
