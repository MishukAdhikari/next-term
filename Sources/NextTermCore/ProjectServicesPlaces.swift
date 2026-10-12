import Foundation

/// A local tool's port, and what said it: "from compose.yaml", "from package.json's dev script", "default port".
struct FoundPort {
    let port: Int
    let from: String
    /// The file that named it; nil for the tool's default.
    let file: String?
}

// MARK: - Servers a value names

extension ServiceReader {
    /// The first value of the rule's keys, most preferred key first, that names a server a link can reach.
    func resolve(_ rule: OriginRule) -> ResolvedOrigin? {
        for key in rule.keys {
            for fact in facts.values(key) {
                if let found = resolve(fact, rule) { return found }
            }
        }
        return nil
    }

    /// A value's server as a link from this Mac reaches it: a Compose service's name at the port that service
    /// publishes, Docker's name for this Mac as `localhost`, any other host as written, after the rule's mapping. Its
    /// port is the one written, else a port key's, else the tool's own for where it runs. Nil when the rule's hosts
    /// do not match, a Compose service publishes no such port, or a link there may not open.
    func resolve(_ fact: ServiceFact, _ rule: OriginRule) -> ResolvedOrigin? {
        guard let written = fact.origin else { return nil }
        let matches: Bool = rule.hosts.isEmpty || rule.hosts.contains { (match: HostMatch) -> Bool in
            match.matches(written.host)
        }
        guard matches else { return nil }
        let keyPort: Int? = portValue(rule.portKeys)
        if let compose = facts.compose, let service = compose.service(named: written.host) {
            guard let target = written.port ?? keyPort ?? rule.localPort,
                  let published = service.port(forTarget: target),
                  let origin = SafeWebLink.Origin(scheme: written.scheme, host: "localhost", port: published) else {
                return nil
            }
            return ResolvedOrigin(origin: origin, place: .local, file: compose.file)
        }
        let docker: Bool = written.host == "host.docker.internal"
        guard let named = SafeWebLink.Origin(scheme: written.scheme, host: docker ? "localhost" : written.host,
                                             port: written.port ?? keyPort) else { return nil }
        let mapped = Self.mapped(named, rule.mapping)
        let local: Bool = DatabaseEnvironment.classify(host: mapped.host) == .local
        let port: Int? = mapped.port ?? (local ? rule.localPort : rule.remotePort)
        guard let origin = SafeWebLink.Origin(scheme: mapped.scheme, host: mapped.host, port: port),
              origin.mayOpen else { return nil }
        return ResolvedOrigin(origin: origin, place: local ? .local : .cloud, file: fact.file)
    }

    /// The first port value of these keys.
    func portValue(_ keys: [String]) -> Int? {
        for key in keys {
            if let port = facts.values(key).compactMap(\.port).first { return port }
        }
        return nil
    }

    /// An API's host as the page a person opens, as the tool's own SDK maps it.
    static func mapped(_ origin: SafeWebLink.Origin, _ mapping: OriginRule.Mapping) -> SafeWebLink.Origin {
        let host: String
        switch mapping {
        case .asWritten: return origin
        case .langsmithSite: host = langsmithSite(origin.host) ?? origin.host
        case .wandbApp: host = wandbApp(origin.host)
        }
        let hosted: Bool = host != origin.host && mapping == .langsmithSite
        let port: Int? = hosted ? nil : origin.port
        return SafeWebLink.Origin(scheme: origin.scheme, host: host, port: port) ?? origin
    }

    /// LangSmith's own API hosts to its regions' sites: `eu.api.smith.langchain.com` gives `eu.smith.langchain.com`;
    /// a self-hosted one is nil, kept as written.
    static func langsmithSite(_ host: String) -> String? {
        guard HostMatch.domain("smith.langchain.com").matches(host) else { return nil }
        for region in ["eu", "aws", "apac"] where host.hasPrefix(region + ".") { return region + ".smith.langchain.com" }
        return "smith.langchain.com"
    }

    /// W&B's API host to its app: `api.wandb.ai` to `wandb.ai`, another `api.` host to `app.`, any other as written.
    static func wandbApp(_ host: String) -> String {
        guard host.hasPrefix("api.") else { return host }
        let rest = String(host.dropFirst("api.".count))
        return rest.hasPrefix("wandb.") ? rest : "app." + rest
    }
}

// MARK: - Local tools' ports

extension ServiceReader {
    /// The port a local tool's files name, by its sources in order, else its documented default. After a refused
    /// address there is no default: the project said where its server is, and it is not there.
    func localPort(_ spec: LocalPort, refused: Bool) -> FoundPort? {
        for source in spec.sources {
            if let found = port(from: source) { return found }
        }
        guard !refused, let port = spec.defaultPort else { return nil }
        return FoundPort(port: port, from: "default port", file: nil)
    }

    func port(from source: PortSource) -> FoundPort? {
        switch source {
        case .compose(let image, let target):
            guard let compose = facts.compose else { return nil }
            let published = compose.services(withImage: image).lazy.compactMap { (service: ComposeService) -> Int? in
                service.port(forTarget: target)
            }.first
            return published.map { (port: Int) -> FoundPort in FoundPort(port: port, from: "from " + compose.file, file: compose.file) }
        case .named(let fact):
            guard let port = facts.port(fact), let file = facts.namedFile(fact) else { return nil }
            return FoundPort(port: port, from: "from " + file, file: file)
        case .start(let words):
            return startPort(words) { (command: StartCommand) -> Int? in command.port }
        case .startUI(let words):
            return startPort(words) { (command: StartCommand) -> Int? in command.uiPort }
        case .startPlus(let words, let plus):
            return startPort(words) { (command: StartCommand) -> Int? in command.port.map { (port: Int) -> Int in port + plus } }
        case .env(let key):
            guard let fact = facts.values(key).first(where: { (fact: ServiceFact) -> Bool in fact.port != nil }),
                  let port = fact.port else { return nil }
            return FoundPort(port: port, from: "from " + fact.file, file: fact.file)
        case .valuePlus(let key, let plus):
            for fact in facts.values(key) {
                guard let origin = fact.origin, let port = origin.port,
                      DatabaseEnvironment.classify(host: origin.host) == .local else { continue }
                return FoundPort(port: port + plus, from: "from " + fact.file, file: fact.file)
            }
            return nil
        }
    }

    /// The first start command of these words with a port, as `pick` reads it, and a valid one.
    func startPort(_ words: [String], _ pick: (StartCommand) -> Int?) -> FoundPort? {
        for command in facts.startCommands where words.contains(command.word) {
            guard let port = pick(command), SafeWebLink.isPort(port) else { continue }
            return FoundPort(port: port, from: Self.scriptSource(command), file: command.file)
        }
        return nil
    }

    /// "from package.json's dev script", "from Procfile's web process", "from Makefile's run target".
    static func scriptSource(_ command: StartCommand) -> String {
        guard !command.script.isEmpty else { return "from " + command.file }
        let what: String
        switch command.file {
        case "package.json": what = "script"
        case "pyproject.toml": what = "task"
        case "Procfile", "Procfile.dev": what = "process"
        case "justfile": what = "recipe"
        default: what = "target"
        }
        return "from " + command.file + "'s " + command.script + " " + what
    }
}

// MARK: - The link a row shows

extension LinkDraft {
    /// The link as the row shows it. A tool on this Mac shows its port on the badge (":6334") and says where it is
    /// and what named the port; a provider's page shows its name ("Console") and the ids it opens.
    func link(entry: ServiceEntry, rowName: String, index: Int) -> ServiceLink {
        let page: String = template.page.map { (page: String) -> String in " " + page } ?? ""
        let itemText: String = item.map { (item: String) -> String in " " + item } ?? ""
        let title = "Open " + rowName + page + itemText
        let showsPort: Bool
        switch template.target {
        case .local: showsPort = true
        case .configured: showsPort = isLocal
        default: showsPort = false
        }
        let named: String = template.badge ?? template.page ?? rowName
        let badge: String = showsPort ? port.map { (port: Int) -> String in ":\(port)" } ?? named : named
        let tooltip: String
        if let address {
            let busy: String = isLocal && port == 5000 ? "; macOS AirPlay Receiver also listens on 5000" : ""
            let said: String = from.map { (from: String) -> String in " (" + from + busy + ")" } ?? ""
            tooltip = title + " at " + address + said
        } else if let detail {
            tooltip = title + ": " + detail
        } else {
            tooltip = title
        }
        let suffix: String = item == nil ? "" : ".\(index)"
        return ServiceLink(id: entry.id + "." + template.id + suffix, badge: badge, title: title, tooltip: tooltip,
                           url: url, source: source)
    }
}
