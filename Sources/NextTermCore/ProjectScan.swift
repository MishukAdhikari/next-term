import Foundation

/// What the sidebar's one scan of a project finds: its Databases rows, then its Services rows from the same read of its
/// files. The sidebar runs it off the main thread, on one gated refresh, and shows both groups together; each group
/// redraws only when what it shows changed (`DatabaseScan` and `ServiceScan` compare what their rows show). It prints
/// kinds and counts only: each database row's engine, never its host, user, port, name or file.
public struct ProjectScan: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var databases: DatabaseScan
    public var services: ServiceScan

    public init(databases: DatabaseScan = DatabaseScan(), services: ServiceScan = ServiceScan()) {
        self.databases = databases
        self.services = services
    }

    /// Reads the project's files once (`Databases.scan`, which hands on its facts) and names the services from what
    /// that read found (`ProjectServices.scan`, which opens no file). Herd's app folder is looked for once, for both.
    /// Nothing is run or fetched.
    public static func scan(root: String, herdInstalled: Bool = Databases.herdIsInstalled) -> ProjectScan {
        let databases = Databases.scan(root: root, herdInstalled: herdInstalled)
        let services = ProjectServices.scan(root: root, databases: databases.databases, facts: databases.facts,
                                            herdInstalled: herdInstalled)
        return ProjectScan(databases: databases, services: services)
    }

    /// The database rows' engines, whether a Vercel project is linked, the Services rows' ids and the facts' counts.
    public var description: String {
        let engines = databases.databases.map { (database: DetectedDatabase) -> String in database.engine.rawValue }
        let vercel: String = databases.isVercelLinked ? "linked" : "none"
        let parts: [String] = ["databases: [\(engines.joined(separator: ", "))]", "vercel: \(vercel)",
                               services.description, databases.facts.description]
        return "ProjectScan(" + parts.joined(separator: ", ") + ")"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
