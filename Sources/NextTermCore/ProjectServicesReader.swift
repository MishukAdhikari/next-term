import Foundation

/// One file's part in naming a service: the key, package, image or start word in it, and where it says the service
/// runs, if it says.
struct ServiceHit: Equatable {
    let file: String
    let name: String?
    let place: ServicePlace?
}

/// A server's address as a link reaches it from this Mac, and which file said so.
struct ResolvedOrigin {
    let origin: SafeWebLink.Origin
    let place: ServicePlace
    let file: String
}

/// The catalog read against one project's facts. It looks only at what the facts hold, never at a file.
struct ServiceReader {
    let root: String
    let facts: ProjectFacts
    let herdInstalled: Bool

    /// The files a signal finds, or none when it does not hold.
    func hits(_ signal: Signal) -> [ServiceHit] {
        switch signal {
        case .key(let key):
            return facts.envFiles(naming: key).map { (file: String) -> ServiceHit in ServiceHit(file: file, name: key, place: nil) }
        case .dependency(let ecosystem, let name):
            guard let file = facts.dependencyFile(name, in: ecosystem) else { return [] }
            return [ServiceHit(file: file, name: name, place: nil)]
        case .image(let image):
            guard let compose = facts.compose, !compose.services(withImage: image).isEmpty else { return [] }
            return [ServiceHit(file: compose.file, name: image, place: .local)]
        case .file(let file, let place):
            return facts.files.contains(file) ? [ServiceHit(file: file, name: nil, place: place)] : []
        case .named(let fact, let place):
            guard let file = facts.namedFile(fact) else { return [] }
            return [ServiceHit(file: file, name: nil, place: place)]
        case .start(let word):
            let command = facts.startCommands.first { (command: StartCommand) -> Bool in command.word == word }
            return command.map { (command: StartCommand) -> [ServiceHit] in
                [ServiceHit(file: command.file, name: word, place: .local)]
            } ?? []
        case .pyprojectTool(let tool):
            guard facts.pyprojectTools.contains(tool) else { return [] }
            return [ServiceHit(file: "pyproject.toml", name: "[tool.\(tool)]", place: nil)]
        case .host(let match):
            return hostHits(match)
        case .origin(let key, let match):
            return originHits(key, match)
        case .scheme(let key, let scheme):
            return facts.values(key).filter { (fact: ServiceFact) -> Bool in fact.value == .scheme(scheme) }
                .map { (fact: ServiceFact) -> ServiceHit in ServiceHit(file: fact.file, name: key, place: nil) }
        case .textPrefix(let key, let prefixes):
            return facts.values(key).filter { (fact: ServiceFact) -> Bool in
                let text = fact.text ?? ""
                return prefixes.contains { (prefix: String) -> Bool in text.hasPrefix(prefix) }
            }.map { (fact: ServiceFact) -> ServiceHit in ServiceHit(file: fact.file, name: key, place: nil) }
        case .all(let signals):
            var found: [ServiceHit] = []
            for signal in signals {
                let more = hits(signal)
                if more.isEmpty { return [] }
                found += more
            }
            return found
        case .any(let signals):
            return signals.flatMap { (signal: Signal) -> [ServiceHit] in hits(signal) }
        }
    }

    /// The URL and host values the catalog reads whose host matches: a provider's own, so its cloud. Only a value in
    /// effect counts: one a more preferred env file overrides names nothing.
    func hostHits(_ match: HostMatch) -> [ServiceHit] {
        var found: [ServiceHit] = []
        for key in ServiceCatalog.hostKeys {
            guard let fact = inEffect(key), let host = fact.origin?.host, match.matches(host) else { continue }
            found.append(ServiceHit(file: fact.file, name: key, place: .cloud))
        }
        return found
    }

    /// A key's value as a tool started in development reads it: the most preferred env file that names the key
    /// decides. Nil when that file's value is not one the readers kept (it names another value, or is empty).
    func inEffect(_ key: String) -> ServiceFact? {
        guard let file = facts.envFiles(naming: key).first else { return nil }
        return facts.values(key).first { (fact: ServiceFact) -> Bool in fact.file == file }
    }

    /// A key that names a server: where its value says it runs. A value that is not a server's address (a store's
    /// `file:`), or one refused, names the service but says nowhere; so does a key named with no value read (a fresh
    /// clone's `.env.example`).
    func originHits(_ key: String, _ match: HostMatch?) -> [ServiceHit] {
        var found: [ServiceHit] = []
        for fact in facts.values(key) {
            if let origin = fact.origin {
                if let match, !match.matches(origin.host) { continue }
                found.append(ServiceHit(file: fact.file, name: key, place: place(of: origin)))
            } else if match == nil {
                found.append(ServiceHit(file: fact.file, name: key, place: nil))
            }
        }
        guard found.isEmpty, match == nil else { return found }
        return facts.envFiles(naming: key).map { (file: String) -> ServiceHit in ServiceHit(file: file, name: key, place: nil) }
    }

    /// On this Mac (a loopback or `.test` host, a Compose service's name, Docker's name for this Mac), a remote server
    /// a link may open, or nowhere a link may go.
    func place(of origin: SafeWebLink.Origin) -> ServicePlace? {
        let docker: Bool = origin.host == "host.docker.internal" || facts.compose?.service(named: origin.host) != nil
        if docker { return .local }
        guard origin.mayOpen else { return nil }
        return DatabaseEnvironment.classify(host: origin.host) == .local ? .local : .cloud
    }
}
