import Foundation

// YAML for the import, each document by its shape, each shape known by members only it has. Compose (a service with an
// `image`, a `build`, an `environment` or an `env_file`): each service's `environment`, a map or a list, where a name
// alone takes the shell's value, and the env in its `x-` extension fields, which services take with an alias; Docker
// advises against keys there, as the file is often in git, and the report says so. Kubernetes: in
// SecretSourcesKubernetes.swift. goose's extensions' `envs`, and Continue's models' `apiKey` and MCP servers' `env`,
// which the files keep. The rest of a Compose, goose or Continue file, and any other document, is read by its paths.

extension SecretSources {
    /// Secret types whose values are a certificate, an SSH key or a registry's login: one row, not importable yet.
    static let typedSecrets: [String: String] = [
        "kubernetes.io/tls": "TLS", "kubernetes.io/ssh-auth": "SSH",
        "kubernetes.io/dockerconfigjson": "registry", "kubernetes.io/dockercfg": "registry",
    ]

    /// goose's extension types (https://block.github.io/goose/docs/getting-started/using-extensions).
    static let gooseTypes: Set<String> = ["stdio", "builtin", "sse", "streamable_http", "frontend", "inline_python"]

    static func yamlFound(_ text: String) -> Result<ConfigFound, Unreadable> {
        let documents: [YAMLSubset.Node]
        switch YAMLSubset.documents(text) {
        case .failure(let failure): return .failure(.notYAML(failure))
        case .success(let read): documents = read
        }
        var values: [Found] = []
        var agent: String?
        var note: Note?
        for (number, document) in documents.enumerated() {
            guard values.count <= maxValues else { break }
            let read: ConfigFound = yamlDocument(document, number: number)
            values += read.values
            agent = agent ?? read.agent
            note = note ?? read.note
        }
        return .success(ConfigFound(values: values, agent: agent, note: note))
    }

    /// One document's values, by its shape.
    static func yamlDocument(_ root: YAMLSubset.Node, number: Int) -> ConfigFound {
        let section: String = number == 0 ? "" : "[\(number)]"
        if root["kind"]?.string != nil, root["apiVersion"] != nil {
            return ConfigFound(values: kubernetesFound(root, number: number))
        }
        if let services = root["services"]?.pairs, services.contains(where: isComposeService) {
            return ConfigFound(values: composeFound(root, services: services, section: section), note: .composeInGit)
        }
        if let extensions = root["extensions"]?.pairs, extensions.contains(where: isGooseExtension) {
            return ConfigFound(values: gooseFound(root, extensions: extensions, section: section), agent: "goose")
        }
        if isContinue(root) {
            return ConfigFound(values: continueFound(root, section: section), agent: "Continue")
        }
        var walk = ConfigWalk()
        walk.rest(root, section: section)
        return ConfigFound(values: walk.found)
    }

    /// A Compose service: one with an `image`, a `build`, an `environment` or an `env_file`.
    static func isComposeService(_ pair: YAMLSubset.Pair) -> Bool {
        ["image", "build", "environment", "env_file"].contains { (key: String) -> Bool in pair.value[key] != nil }
    }

    /// Compose's env: each `x-` extension field's (an env, or a service's fragment with its own `environment`), each
    /// service's `environment`, then the rest of the file by its paths. An alias or a merge (`<<: *env`) takes values
    /// read where its anchor is, so it adds no row.
    static func composeFound(_ root: YAMLSubset.Node, services: [YAMLSubset.Pair], section: String) -> [Found] {
        var walk = ConfigWalk(note: .composeInGit)
        walk.skipsAliases = true
        for pair in root.pairs ?? [] where pair.key.hasPrefix("x-") {
            if pair.value["environment"] != nil {
                composeService(pair.value, scope: pair.key, into: &walk)
            } else if pair.value.pairs != nil {
                composeMap(pair.value, place: pair.key, scope: pair.key, into: &walk)
            }
        }
        for service in services { composeService(service.value, scope: "services." + service.key, into: &walk) }
        walk.rest(root, section: section)
        return walk.found
    }

    /// A service's `environment`: `KEY: value` or `- KEY=value`, where `KEY` alone is the shell's.
    static func composeService(_ service: YAMLSubset.Node, scope: String, into walk: inout ConfigWalk) {
        let place: String = scope + ".environment"
        guard let environment = service["environment"] else { return }
        guard let items = environment.items else {
            composeMap(environment, place: place, scope: scope, into: &walk)
            return
        }
        walk.known.insert(place)
        for (index, item) in items.enumerated() {
            guard let value = item.scalar, value.kind != .null else { continue }
            let at: String = place + "[\(index)]"
            guard let equals = value.text.firstIndex(of: "=") else {
                walk.reference(name: envName(value.text), place: at, line: value.line, scope: scope)
                continue
            }
            let text: String = String(value.text[value.text.index(after: equals)...])
            let entry = YAMLSubset.Scalar(text: text, style: .doubleQuoted, line: value.line)
            walk.scalar(entry, name: envName(String(value.text[..<equals])), place: at, scope: scope)
        }
    }

    /// Compose's `environment` as a map, in order: a name with no value is the shell's, and a merge of a map (`<<`)
    /// is read as part of it. Anything else in it is left to the walk over the rest.
    static func composeMap(_ environment: YAMLSubset.Node, place: String, scope: String, into walk: inout ConfigWalk) {
        guard let pairs = environment.pairs else {
            walk.env(environment, place: place, scope: scope)
            return
        }
        for pair in pairs {
            let at: String = place + "." + pair.key
            switch pair.value {
            case .scalar(let value) where value.kind == .null:
                walk.reference(name: envName(pair.key), place: at, line: pair.line, scope: scope)
            case .scalar(let value):
                walk.scalar(value, name: envName(pair.key), place: at, scope: scope)
            case .skipped(let part, let line):
                walk.skipped(part, line: line, name: envName(pair.key), place: at, scope: scope)
            case .mapping where pair.key == "<<":
                composeMap(pair.value, place: at, scope: scope, into: &walk)
            default:
                continue
            }
        }
    }
}
