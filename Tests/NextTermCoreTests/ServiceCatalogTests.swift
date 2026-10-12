import Foundation
import Testing
@testable import NextTermCore

/// A made-up project that names one catalog entry, the row it must give (name, badge, main link), and a project that
/// must not name it. Every project, key and value here is made up.
struct EntryCase: Sendable, CustomTestStringConvertible {
    let entry: String
    let files: [String: String]
    let name: String
    let badge: String
    let url: String
    let not: [String: String]

    init(_ entry: String, _ files: [String: String], name: String, badge: String, url: String, not: [String: String]) {
        self.entry = entry
        self.files = files
        self.name = name
        self.badge = badge
        self.url = url
        self.not = not
    }

    var testDescription: String { entry }
}

extension FixtureProject {
    convenience init(_ files: [String: String]) {
        self.init()
        for (path, text) in files { write(path, text) }
    }

    /// The Services rows, after the Databases pass that reads the facts, as the sidebar runs them.
    func services(herd: Bool = false) -> ServiceScan {
        let databases = scan(herd: herd)
        return ProjectServices.scan(root: root, databases: databases.databases, facts: databases.facts,
                                    herdInstalled: herd)
    }
}

/// Everything a Services row could show or hand on: its text, tooltip, notes, sources, every link's fields, and the
/// scan as printed, dumped and reflected.
func serviceText(_ scan: ServiceScan) -> String {
    var parts: [String] = [String(describing: scan), String(reflecting: scan)]
    var dumped = ""
    dump(scan, to: &dumped)
    parts.append(dumped)
    for row in scan.rows {
        let fields: [String] = [row.id, row.name, row.detail, row.tooltip, String(describing: row), String(reflecting: row)]
        parts.append(fields.joined(separator: "\n"))
        parts.append(row.notes.joined(separator: "\n"))
        for source in row.sources { parts.append(source.file + " " + source.names.joined(separator: " ")) }
        for link in row.links {
            let linkFields: [String] = [link.id, link.badge, link.title, link.tooltip, link.url.absoluteString, link.source ?? ""]
            parts.append(linkFields.joined(separator: "\n"))
        }
    }
    return parts.joined(separator: "\n")
}

/// No made-up secret reaches a row, and every link may open.
func expectNoSecret(_ scan: ServiceScan, sourceLocation: SourceLocation = #_sourceLocation) {
    let text = serviceText(scan)
    for secret in ["NOT-A-", "sk-test", "31337", "api_key=", "admin:"] {
        #expect(!text.contains(secret), "\(secret) in \(text)", sourceLocation: sourceLocation)
    }
    for row in scan.rows {
        #expect(!row.links.isEmpty, sourceLocation: sourceLocation)
        for link in row.links {
            #expect(SafeWebLink.isAllowed(link.url), "\(link.url)", sourceLocation: sourceLocation)
        }
    }
}

/// The catalog's own rules, and one made-up project per entry: the row it names, and one it must not name.
@Suite struct ServiceCatalogTests {
    static let cases: [EntryCase] = aiModels + vectorStores + tracing

    @Test(arguments: ServiceCatalogTests.cases)
    func eachEntryNamesItsRow(_ entry: EntryCase) throws {
        let scan = FixtureProject(entry.files).services()
        let row = try #require(scan.rows.first { (row: ServiceRow) -> Bool in row.entryID == entry.entry },
                               "\(scan.rows.map(\.id))")
        #expect(row.name == entry.name)
        #expect(row.link.badge == entry.badge)
        #expect(row.link.url.absoluteString == entry.url)
        expectNoSecret(scan)
        let other = FixtureProject(entry.not).services()
        #expect(!other.rows.contains { (row: ServiceRow) -> Bool in row.entryID == entry.entry }, "\(other.rows.map(\.id))")
        expectNoSecret(other)
    }

    @Test func everyEntryHasItsCase() {
        let tested = Set(Self.cases.map(\.entry))
        let entries = Set(ServiceCatalog.all.map(\.id))
        #expect(tested == entries, "untested: \(entries.subtracting(tested)), unknown: \(tested.subtracting(entries))")
    }

    @Test func everyEntryIsComplete() {
        for entry in ServiceCatalog.all {
            #expect(!entry.name.isEmpty && entry.rank > 0, "\(entry.id)")
            #expect(!entry.signals.isEmpty, "\(entry.id)")
            #expect(entry.links.contains { (link: LinkTemplate) -> Bool in !link.isExtra }, "\(entry.id)")
            let factFree = entry.links.contains { (link: LinkTemplate) -> Bool in link.needsNoFact }
            #expect(factFree, "\(entry.id) has no link that needs no fact")
        }
    }

    @Test func idsAndRanksAreUnique() {
        let ids = ServiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for kind in ServiceKind.allCases {
            let ranks = ServiceCatalog.all.filter { (entry: ServiceEntry) -> Bool in entry.kind == kind }.map(\.rank)
            #expect(Set(ranks).count == ranks.count, "\(kind)")
        }
    }

    /// No entry, whoever writes it, can read the value of a key whose name marks a secret.
    @Test func noValueKeyIsSecretShaped() {
        for entry in ServiceCatalog.all {
            for (key, role) in entry.values {
                #expect(role != .presence, "\(entry.id) \(key)")
                #expect(!SecretName.isSecret(key), "\(entry.id) reads the value of \(key)")
            }
        }
        for (key, _) in ServiceCatalog.valueKeys { #expect(!SecretName.isSecret(key), "\(key)") }
    }

    /// Every key whose value a signal, a link or a note reads is one the entry lists with its role.
    @Test func everyValueReadIsListed() {
        for entry in ServiceCatalog.all {
            for key in entry.keysRead { #expect(entry.values[key] != nil, "\(entry.id) reads \(key) unlisted") }
            for (key, role) in entry.values { #expect(ServiceCatalog.valueKeys[key] == role, "\(entry.id) \(key)") }
        }
    }

    @Test func fixedHostsAreHTTPSAndImagesHaveNoTag() {
        for entry in ServiceCatalog.all {
            for host in entry.fixedHosts {
                let url = SafeWebLink.make(scheme: "https", host: host)
                #expect(url?.absoluteString == "https://" + host, "\(entry.id) \(host)")
            }
            for image in entry.images {
                #expect(ComposeFile.imageName(image) == image, "\(entry.id) \(image)")
            }
        }
    }

    /// The reader is asked for every start word and marker file an entry looks for.
    @Test func theReaderIsAskedForWhatTheCatalogUses() {
        for entry in ServiceCatalog.all {
            for word in entry.startWords { #expect(ServiceCatalog.startWords.contains(word), "\(entry.id) \(word)") }
            for file in entry.markerFiles { #expect(ServiceCatalog.markerFiles.contains(file), "\(entry.id) \(file)") }
        }
    }
}
