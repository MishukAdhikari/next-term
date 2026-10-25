import Foundation

/// A link before its row is named: where it goes, and what its tooltip says beside the row's name.
struct LinkDraft {
    let template: LinkTemplate
    let url: URL
    /// The row it belongs in.
    let place: ServicePlace
    /// Whether it opens a tool on this Mac.
    let isLocal: Bool
    /// `localhost:6334`, `abc.cloud.qdrant.io:6333`: where a tool or a configured server is.
    let address: String?
    /// "from compose.yaml", "default port".
    let from: String?
    /// The ids and names in the link: "project cold-grass-40154007".
    let detail: String?
    /// The file that gave its id, address or port.
    let source: String?
    /// The binding's name, for one of a repeated link's: a D1 database's.
    let item: String?
    let port: Int?
}

extension ServiceReader {
    /// The entry's rows, one per place where something says it runs and a main link can be built there. A row's
    /// sources are what named it there, or nowhere in particular.
    func rows(for entry: ServiceEntry, in places: [ServicePlace]) -> [ServiceRow] {
        let signals = isRouted(entry) ? entry.signals.filter(Self.isHost) : entry.signals
        let found = signals.flatMap { (signal: Signal) -> [ServiceHit] in hits(signal) }
        guard !found.isEmpty else { return [] }
        let refused = isRefused(entry)
        var evidence = Set(found.compactMap(\.place))
        if evidence.isEmpty, !refused, let place = entry.place { evidence.insert(place) }
        var drafts: [(place: ServicePlace, links: [LinkDraft])] = []
        for place in places where evidence.contains(place) {
            let links = self.links(for: entry, in: place, refused: refused)
            if !links.isEmpty { drafts.append((place, links)) }
        }
        let notes = self.notes(entry)
        return drafts.map { (draft: (place: ServicePlace, links: [LinkDraft])) -> ServiceRow in
            let name = rowName(entry, draft.place, beside: drafts.count > 1)
            let links = draft.links.enumerated().map { (pair: (offset: Int, element: LinkDraft)) -> ServiceLink in
                pair.element.link(entry: entry, rowName: name, index: pair.offset)
            }
            return ServiceRow(id: entry.id + "." + draft.place.rawValue, entryID: entry.id, name: name, kind: entry.kind,
                              place: draft.place, sources: Self.sources(found, in: draft.place), notes: notes,
                              links: links, isLocal: draft.links[0].isLocal)
        }
    }

    static func isHost(_ signal: Signal) -> Bool {
        if case .host = signal { return true }
        return false
    }

    /// "Qdrant Cloud" beside a local Qdrant; another product's name for a cloud that has one ("Zilliz Cloud"). A
    /// `.test` site with neither Herd nor its `herd.yml` is Valet's.
    func rowName(_ entry: ServiceEntry, _ place: ServicePlace, beside other: Bool) -> String {
        if entry.id == "herd", !herdInstalled, !facts.files.contains("herd.yml") { return "Valet" }
        guard place == .cloud else { return entry.name }
        if let cloudName = entry.cloudName { return cloudName }
        return other ? entry.name + " Cloud" : entry.name
    }

    /// The files that named it, each once, in the order found, with their names: those that say this place, or none.
    static func sources(_ found: [ServiceHit], in place: ServicePlace) -> [ServiceSource] {
        var files: [String] = []
        var names: [String: [String]] = [:]
        for hit in found where hit.place == nil || hit.place == place {
            if names[hit.file] == nil {
                files.append(hit.file)
                names[hit.file] = []
            }
            if let name = hit.name, names[hit.file]?.contains(name) == false { names[hit.file]?.append(name) }
        }
        return files.map { (file: String) -> ServiceSource in ServiceSource(file: file, names: names[file] ?? []) }
    }

    func notes(_ entry: ServiceEntry) -> [String] {
        entry.notes.compactMap { (note: ServiceNote) -> String? in
            first(note.refs, .name, item: nil).map { (found: FoundValue) -> String in note.label + ": " + found.value }
        }
    }

    /// Its SDK's base URL, the value in effect, names another host, so the SDK talks to that host's provider, not
    /// this one.
    func isRouted(_ entry: ServiceEntry) -> Bool {
        let own = entry.signals.compactMap { (signal: Signal) -> HostMatch? in
            if case .host(let match) = signal { return match }
            return nil
        }
        for key in entry.routes {
            guard let origin = inEffect(key)?.origin else { continue }
            return !own.contains { (match: HostMatch) -> Bool in match.matches(origin.host) }
        }
        return false
    }

    /// A key that names this entry's server holds a value no link may use (it names another value, holds a user or
    /// password, is plain `http` to a remote host, or has another scheme): the project said where its server is, so
    /// no vendor default and no default port stands in for it.
    func isRefused(_ entry: ServiceEntry) -> Bool {
        for template in entry.links {
            guard case .configured(let rule) = template.target else { continue }
            let any = OriginRule(rule.keys, mapping: rule.mapping, portKeys: rule.portKeys, localPort: rule.localPort,
                                 remotePort: rule.remotePort)
            for key in rule.keys where isRefused(key, any, stores: entry.storeSchemes(key)) { return true }
        }
        return false
    }

    /// Whether a key's values are written and none is one a link may use. A value that names no web server counts
    /// only as a store the entry keeps on this Mac (MLflow's `file:`): any other scheme (`databricks://`, `ftp://`)
    /// names a server no link reaches.
    func isRefused(_ key: String, _ rule: OriginRule, stores: Set<String> = []) -> Bool {
        let values = facts.values(key)
        let usable = values.contains { (fact: ServiceFact) -> Bool in
            if case .scheme(let scheme) = fact.value { return stores.contains(scheme) }
            return resolve(fact, rule) != nil
        }
        return !usable && (facts.refused.contains(key) || !values.isEmpty)
    }
}

// MARK: - Building links

extension ServiceReader {
    /// The first main link that builds for this place, then every extra that does, each page once.
    func links(for entry: ServiceEntry, in place: ServicePlace, refused: Bool) -> [LinkDraft] {
        var main: LinkDraft?
        for template in entry.links where !template.isExtra {
            main = build(template, refused: refused).first { (draft: LinkDraft) -> Bool in draft.place == place }
            if main != nil { break }
        }
        guard let main else { return [] }
        var all: [LinkDraft] = [main]
        for template in entry.links where template.isExtra {
            for draft in build(template, refused: refused) where draft.place == place {
                let seen = all.contains { (other: LinkDraft) -> Bool in other.url == draft.url }
                if !seen { all.append(draft) }
            }
        }
        return all
    }

    /// A template's links: none when its condition fails or a fact it needs is missing or fails its pattern; one per
    /// binding for a repeated one. After a refused address, no page on a vendor's own host is used: the project said
    /// where its server is, and it is not the vendor's.
    func build(_ template: LinkTemplate, refused: Bool) -> [LinkDraft] {
        if let when = template.when, hits(when).isEmpty { return [] }
        if refused, template.isVendorPage { return [] }
        guard let fact = template.each else { return build(template, item: nil, refused: refused).map { [$0] } ?? [] }
        return facts.all(fact).compactMap { (item: NamedValue) -> LinkDraft? in build(template, item: item, refused: refused) }
    }

    func build(_ template: LinkTemplate, item: NamedValue?, refused: Bool) -> LinkDraft? {
        var pieces = PieceReader(reader: self, item: item)
        guard let path = pieces.parts(template.path), let fragment = pieces.parts(template.fragment),
              let query = pieces.query(template.query) else { return nil }
        let label = item.map { (item: NamedValue) -> String in item.label ?? item.value }
        let target: (url: URL?, place: ServicePlace, isLocal: Bool, address: String?, from: String?, source: String?)
        switch template.target {
        case .web(let host):
            let url = SafeWebLink.make(scheme: "https", host: host, path: path, query: query, fragment: fragment)
            target = (url, .cloud, false, nil, nil, pieces.file)
        case .awsConsole(let refs):
            guard let region = first(refs, .awsRegion, item: item) else { return nil }
            let host = DatabaseLinks.awsConsole(region.value)
            let url = SafeWebLink.make(scheme: "https", host: host, path: path, query: query, fragment: fragment)
            target = (url, .cloud, false, nil, nil, pieces.file ?? region.file)
        case .configured(let rule):
            guard let found = resolve(rule) else { return nil }
            let url = found.origin.link(path: path, query: query, fragment: fragment)
            let local: Bool = found.place == .local
            let address = Self.address(found.origin)
            target = (url, found.place, local, address, local ? "from " + found.file : nil, found.file)
        case .local(let spec):
            guard let found = localPort(spec, refused: refused) else { return nil }
            let https: Bool = spec.httpsWhen.map { (fact: NamedFact) -> Bool in facts.named(fact) == "true" } ?? false
            let url = SafeWebLink.make(scheme: https ? "https" : "http", host: spec.host, port: found.port, path: path,
                                       query: query, fragment: fragment)
            target = (url, .local, true, spec.host + ":\(found.port)", found.from, found.file)
        case .studio(let spec, let rule):
            guard let found = localPort(spec, refused: refused),
                  let server = SafeWebLink.Origin(scheme: "http", host: spec.host, port: found.port),
                  let site = studioSite(spec, rule) else { return nil }
            let baseURL = SafeWebLink.QueryItem("baseUrl", .origin(server))
            let url = site.link(path: [.fixed("/studio/")], query: [baseURL])
            target = (url, .local, true, spec.host + ":\(found.port)", found.from, found.file)
        case .site(let rule):
            guard let site = self.site(rule, pieces: &pieces) else { return nil }
            let url = SafeWebLink.make(scheme: site.scheme, host: site.host, port: site.port, path: path, query: query,
                                       fragment: fragment)
            target = (url, .local, true, Self.address(site), nil, pieces.file)
        }
        guard let url = target.url else { return nil }
        return LinkDraft(template: template, url: url, place: template.place ?? target.place, isLocal: target.isLocal,
                         address: target.address, from: target.from, detail: pieces.detail(about: template.about),
                         source: target.source, item: label, port: url.port)
    }

    /// `host` or `host:port`.
    static func address(_ origin: SafeWebLink.Origin) -> String {
        origin.host + (origin.port.map { (port: Int) -> String in ":\(port)" } ?? "")
    }

    /// Where Studio's page is: the `--studio-url` a start command gives; else the LangSmith the project's endpoint
    /// names, a region's site (`eu.smith.langchain.com`) or a server of its own; else LangSmith's. Nil when either
    /// is written in a form no link may use: the project's Studio is not LangSmith's, so that is not opened instead.
    func studioSite(_ spec: LocalPort, _ rule: OriginRule) -> SafeWebLink.Origin? {
        let words = Set(spec.sources.flatMap { (source: PortSource) -> [String] in
            if case .start(let list) = source { return list }
            return []
        })
        let named = facts.startCommands.first { (command: StartCommand) -> Bool in
            words.contains(command.word) && command.studio != nil
        }
        if let studio = named?.studio { return studio.mayOpen ? studio : nil }
        if let found = resolve(rule) { return found.origin }
        if rule.keys.contains(where: { (key: String) -> Bool in isRefused(key, rule) }) { return nil }
        return SafeWebLink.Origin(scheme: "https", host: "smith.langchain.com", port: nil)
    }

    /// A site a local dev environment serves: its name and top-level domain as host labels, `https` unless the
    /// files say it is not secured, and its port unless it is the scheme's own. A domain the files write that is not
    /// host labels gives no site: the default does not stand in for it.
    func site(_ rule: SiteRule, pieces: inout PieceReader) -> SafeWebLink.Origin? {
        guard let name = pieces.take(rule.names, .slug) else { return nil }
        let peeking = pieces
        let tld = rule.tld.lazy.compactMap { (ref: FactRef) -> String? in peeking.peek(ref) }.first ?? rule.defaultTLD
        let host = name + "." + tld.lowercased()
        guard Self.isDomain(host) else { return nil }
        let https: Bool = rule.httpsWhen.map { (fact: NamedFact) -> Bool in facts.named(fact) == "true" } ?? true
        let port = rule.port.flatMap { (fact: NamedFact) -> Int? in facts.port(fact) } ?? rule.defaultPort
        let ownPort: Bool = port == (https ? 443 : 80)
        return SafeWebLink.Origin(scheme: https ? "https" : "http", host: host, port: ownPort ? nil : port)
    }

    /// Host labels joined by dots, each of lower-case letters and digits with `-` only inside: `shop.ddev.site`.
    static func isDomain(_ host: String) -> Bool {
        host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { (label: Substring) -> Bool in
            label.wholeMatch(of: domainLabel) != nil
        }
    }

    private static let domainLabel = #/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/#
}

// MARK: - Facts in links

/// A value a link may hold, and the file it came from (none for the project's folder name).
struct FoundValue {
    let value: String
    let file: String?
}

extension ServiceReader {
    /// The first of these facts that is present and matches the pattern.
    func first(_ refs: [FactRef], _ placeholder: SafeWebLink.Placeholder, item: NamedValue?) -> FoundValue? {
        for ref in refs {
            for found in values(ref, item: item) where placeholder.accepts(found.value) { return found }
        }
        return nil
    }

    /// Every value a fact has, most preferred first.
    func values(_ ref: FactRef, item: NamedValue?) -> [FoundValue] {
        switch ref {
        case .named(let fact):
            return facts.all(fact).map { (named: NamedValue) -> FoundValue in FoundValue(value: named.value, file: named.file) }
        case .value(let key):
            return facts.values(key).compactMap { (fact: ServiceFact) -> FoundValue? in
                fact.text.map { (text: String) -> FoundValue in FoundValue(value: text, file: fact.file) }
            }
        case .hostLabel(let keys, let domain, let index, let count):
            return keys.flatMap { (key: String) -> [FoundValue] in
                facts.values(key).compactMap { (fact: ServiceFact) -> FoundValue? in
                    Self.label(fact.origin?.host, under: domain, index: index, count: count).map { (label: String) -> FoundValue in
                        FoundValue(value: label, file: fact.file)
                    }
                }
            }
        case .afterPrefix(let key, let prefixes):
            return facts.values(key).compactMap { (fact: ServiceFact) -> FoundValue? in
                let text = fact.text ?? ""
                guard let prefix = prefixes.first(where: { (prefix: String) -> Bool in text.hasPrefix(prefix) }) else { return nil }
                return FoundValue(value: String(text.dropFirst(prefix.count)), file: fact.file)
            }
        case .item:
            return item.map { (item: NamedValue) -> [FoundValue] in [FoundValue(value: item.value, file: item.file)] } ?? []
        case .folderName:
            let name = URL(fileURLWithPath: root).lastPathComponent.lowercased()
            return name.isEmpty ? [] : [FoundValue(value: name, file: nil)]
        }
    }

    /// A label of `host` under `domain`, when exactly `count` labels come before the domain.
    static func label(_ host: String?, under domain: String, index: Int, count: Int) -> String? {
        guard let host, host.hasSuffix("." + domain) else { return nil }
        let labels = host.dropLast(domain.count + 1).split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == count, labels.indices.contains(index) else { return nil }
        return String(labels[index])
    }
}

/// Turns a template's pieces into a link's parts, keeping the values it put in (for the tooltip) and the file the
/// first came from.
struct PieceReader {
    let reader: ServiceReader
    let item: NamedValue?
    private(set) var file: String?
    private var values: [String] = []
    private var joiners: [String] = []

    init(reader: ServiceReader, item: NamedValue?) {
        self.reader = reader
        self.item = item
    }

    /// The first of these facts that matches, kept for the tooltip like a piece's.
    mutating func take(_ refs: [FactRef], _ placeholder: SafeWebLink.Placeholder) -> String? {
        guard let found = reader.first(refs, placeholder, item: item) else { return nil }
        keep(found, after: "/")
        return found.value
    }

    /// A fact's first value, unchecked and not kept: a part a link's own check reads.
    func peek(_ ref: FactRef) -> String? {
        reader.values(ref, item: item).first?.value
    }

    private mutating func keep(_ found: FoundValue, after text: String) {
        if !values.isEmpty { joiners.append(text == "." ? "." : "/") }
        values.append(found.value)
        if file == nil { file = found.file }
    }

    mutating func parts(_ pieces: [Piece]) -> [SafeWebLink.Part]? {
        var parts: [SafeWebLink.Part] = []
        var last = ""
        for piece in pieces {
            switch piece {
            case .text(let text):
                parts.append(.fixed(text))
                last = text
            case .fact(let refs, let placeholder):
                guard let found = reader.first(refs, placeholder, item: item) else { return nil }
                keep(found, after: last)
                parts.append(.value(found.value, placeholder))
            }
        }
        return parts
    }

    /// One part per query value: a lone fact is checked and encoded by the link; a value written around a fact is
    /// joined here, the fact percent-encoded as a query value is.
    mutating func query(_ items: [QueryPiece]) -> [SafeWebLink.QueryItem]? {
        var query: [SafeWebLink.QueryItem] = []
        for item in items {
            guard let parts = parts(item.value) else { return nil }
            if parts.count == 1, let part = parts.first {
                query.append(SafeWebLink.QueryItem(item.name, part))
                continue
            }
            var text = ""
            for part in parts {
                switch part {
                case .fixed(let fixed): text += fixed
                case .value(let value, _): text += value.addingPercentEncoding(withAllowedCharacters: Self.queryValues) ?? ""
                case .origin: return nil
                }
            }
            query.append(SafeWebLink.QueryItem(item.name, .fixed(text)))
        }
        return query
    }

    private static let queryValues = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    /// "project cold-grass-40154007", "acme/shop": the values the link holds, after the template's word for them.
    func detail(about: String?) -> String? {
        guard let first = values.first else { return nil }
        var text = first
        for (joiner, value) in zip(joiners, values.dropFirst()) { text += joiner + value }
        return about.map { (word: String) -> String in word + " " + text } ?? text
    }
}
