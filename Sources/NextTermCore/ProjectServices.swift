import Foundation

/// A file that named a service, and the key, package, image or start word in it that did. Names only: never a value.
public struct ServiceSource: Sendable, Equatable {
    /// Relative to the project.
    public let file: String
    public let names: [String]

    public init(file: String, names: [String]) {
        self.file = file
        self.names = names
    }
}

/// A row of the Services section: one service in one place, with the pages it opens. It holds names, files, ports and
/// the links themselves, which hold only validated hosts, ports, names and ids; it prints its id only.
public struct ServiceRow: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The entry, then the place: `qdrant.local`.
    public let id: String
    public let entryID: String
    /// "Qdrant", or "Qdrant Cloud" beside a local Qdrant.
    public let name: String
    public let kind: ServiceKind
    public let place: ServicePlace
    /// What named it, file by file, in the order found.
    public let sources: [ServiceSource]
    /// Lines the tooltip adds: "Project: support-bot".
    public let notes: [String]
    /// The main link first, then its extras; never empty.
    public let links: [ServiceLink]
    /// Whether the main link opens a tool on this Mac, which answers only while it runs.
    public let isLocal: Bool

    public init(id: String, entryID: String, name: String, kind: ServiceKind, place: ServicePlace,
                sources: [ServiceSource], notes: [String], links: [ServiceLink], isLocal: Bool) {
        self.id = id
        self.entryID = entryID
        self.name = name
        self.kind = kind
        self.place = place
        self.sources = sources
        self.notes = notes
        self.links = links
        self.isLocal = isLocal
    }

    /// The badge's link, and the one Open and a double-click open.
    public var link: ServiceLink { links[0] }

    /// The dimmed text after the name: its kind and the file that named it, "vector store · compose.yaml".
    public var detail: String {
        let file = link.source ?? sources.first?.file ?? ""
        return file.isEmpty ? kind.title : kind.title + " · " + file
    }

    /// The page the badge opens (and, for a tool on this Mac, that it must be running), the notes, then what named
    /// it, by file and key name only.
    public var tooltip: String {
        var lines: [String] = [link.tooltip + (isLocal ? ", if it is running" : "")]
        lines += notes
        let from = sources.map { (source: ServiceSource) -> String in
            source.names.isEmpty ? source.file : source.file + ": " + source.names.joined(separator: ", ")
        }
        if !from.isEmpty { lines.append("From " + from.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    public var description: String { "ServiceRow(\(id), links: \(links.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Services section's rows, by kind and then by how much each service is used. Equal scans draw the same rows.
/// It prints row ids only.
public struct ServiceScan: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var rows: [ServiceRow]

    public init(rows: [ServiceRow] = []) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }

    public var description: String {
        "ServiceScan(rows: [" + rows.map(\.id).joined(separator: ", ") + "])"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Services section's scan: the catalog against what the project's files say, after the Databases pass that read
/// them. A service a database row already shows in the same place is left out, so it is listed once. Nothing is run
/// or fetched, and no file is read again.
public enum ProjectServices {
    public static func scan(root: String, databases: [DetectedDatabase], facts: ProjectFacts,
                            herdInstalled: Bool = Databases.herdIsInstalled) -> ServiceScan {
        let reader = ServiceReader(root: root, facts: facts, herdInstalled: herdInstalled)
        let shown = shownByDatabases(databases)
        var rows: [ServiceRow] = []
        for entry in ServiceCatalog.all {
            let places = ServicePlace.allCases.filter { (place: ServicePlace) -> Bool in
                !shown.contains(entry.id + "." + place.rawValue)
            }
            rows += reader.rows(for: entry, in: places)
        }
        rows.sort { (lhs: ServiceRow, rhs: ServiceRow) -> Bool in order(lhs).lexicographicallyPrecedes(order(rhs)) }
        return ServiceScan(rows: rows)
    }

    /// `<service>.<place>` for each provider a database row carries: on this Mac for a local or container row. Vercel
    /// on a database row is the team's storage, a page of its own, so the Vercel hosting row, which opens the
    /// project's dashboard, stays.
    static func shownByDatabases(_ databases: [DetectedDatabase]) -> Set<String> {
        var shown = Set<String>()
        for database in databases {
            let local: Bool = database.environment == .local || database.environment == .development
            let place: ServicePlace = local ? .local : .cloud
            for provider in database.providers where !storageOnly.contains(provider) {
                shown.insert(provider.serviceID + "." + place.rawValue)
            }
        }
        return shown
    }

    /// Providers whose badge on a database row opens their storage, not the service the catalog lists.
    static let storageOnly: Set<DatabaseProvider> = [.vercel]

    /// Kind, then rank, then this Mac before the cloud.
    static func order(_ row: ServiceRow) -> [Int] {
        let rank = ServiceCatalog.all.first { (entry: ServiceEntry) -> Bool in entry.id == row.entryID }?.rank ?? 0
        return [row.kind.rawValue, rank, row.place == .local ? 0 : 1]
    }
}
