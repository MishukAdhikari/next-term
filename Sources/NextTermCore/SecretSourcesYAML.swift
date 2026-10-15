import Foundation

// YAML for the import, each document by its shape. Compose: each service's `environment`, a map or a list, where a
// name alone takes the shell's value; Docker advises against keys there, as the file is often in git, and each row says
// so. Kubernetes: a Secret's `stringData` and base64 `data` (`stringData` wins), a Secret of a type that holds a
// certificate, an SSH key or a registry's login listed as not importable yet, a ConfigMap's `data`, and any object's
// `env` list. goose's extensions' `envs` and Continue's models' `apiKey` and MCP servers' `env`, which the files keep.
// Any other document is read by its paths.

extension SecretSources {
    /// Secret types whose values are a certificate, an SSH key or a registry's login: one row, not importable yet.
    static let typedSecrets: [String: String] = [
        "kubernetes.io/tls": "TLS", "kubernetes.io/ssh-auth": "SSH",
        "kubernetes.io/dockerconfigjson": "registry", "kubernetes.io/dockercfg": "registry",
    ]

    static func yamlFound(_ text: String) -> Result<ConfigFound, Unreadable> {
        let documents: [YAMLSubset.Node]
        switch YAMLSubset.documents(text) {
        case .failure(let failure): return .failure(.notYAML(failure))
        case .success(let read): documents = read
        }
        var values: [Found] = []
        var agent: String?
        for (number, document) in documents.enumerated() {
            guard values.count <= maxValues else { break }
            let read: ConfigFound = yamlDocument(document, number: number)
            values += read.values
            agent = agent ?? read.agent
        }
        return .success(ConfigFound(values: values, agent: agent))
    }

    /// One document's values, by its shape.
    static func yamlDocument(_ root: YAMLSubset.Node, number: Int) -> ConfigFound {
        let kind: String? = root["kind"]?.string
        if kind != nil, root["apiVersion"] != nil { return ConfigFound(values: kubernetesFound(root, number: number)) }
        if let services = root["services"]?.pairs { return ConfigFound(values: composeFound(services)) }
        if let extensions = root["extensions"]?.pairs, extensions.contains(where: isGooseExtension) {
            return ConfigFound(values: gooseFound(root, extensions: extensions), agent: "goose")
        }
        if root["mcpServers"]?.items != nil || root["models"]?.items != nil {
            return ConfigFound(values: continueFound(root), agent: "Continue")
        }
        var walk = ConfigWalk()
        walk.walk(root, at: JSONPath(), section: number == 0 ? "" : "[\(number)]")
        return ConfigFound(values: walk.found)
    }

    /// Compose's services' `environment`: `KEY: value` or `- KEY=value`, where `KEY` alone is the shell's.
    static func composeFound(_ services: [YAMLSubset.Pair]) -> [Found] {
        var walk = ConfigWalk(note: .composeInGit)
        for service in services {
            let scope: String = "services." + service.key
            let place: String = scope + ".environment"
            guard let environment = service.value["environment"] else { continue }
            guard let items = environment.items else {
                composeMap(environment, place: place, scope: scope, into: &walk)
                continue
            }
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
        return walk.found
    }

    /// Compose's `environment` as a map, in order: a name with no value is the shell's.
    static func composeMap(_ environment: YAMLSubset.Node, place: String, scope: String, into walk: inout ConfigWalk) {
        guard environment.pairs != nil else {
            walk.env(environment, place: place, scope: scope)
            return
        }
        for pair in environment.pairs ?? [] {
            let at: String = place + "." + pair.key
            if pair.value.scalar?.kind == .null {
                walk.reference(name: envName(pair.key), place: at, line: pair.line, scope: scope)
            } else {
                walk.env(.mapping([pair]), place: place, scope: scope)
            }
        }
    }

    static func isGooseExtension(_ pair: YAMLSubset.Pair) -> Bool {
        pair.value["envs"] != nil || pair.value["cmd"] != nil || pair.value["type"] != nil
    }

    /// goose's settings at the root, and each extension's `envs`.
    static func gooseFound(_ root: YAMLSubset.Node, extensions: [YAMLSubset.Pair]) -> [Found] {
        var walk = ConfigWalk(note: .stillInFile)
        for pair in root.pairs ?? [] {
            guard let value = pair.value.scalar else { continue }
            walk.scalar(value, name: envName(pair.key), place: pair.key, scope: "")
        }
        for pair in extensions {
            let place: String = "extensions." + pair.key
            walk.env(pair.value["envs"], place: place + ".envs", scope: place)
        }
        return walk.found
    }

    /// Continue's models' `apiKey`, named by the provider (ANTHROPIC_API_KEY), and its MCP servers' `env`.
    static func continueFound(_ root: YAMLSubset.Node) -> [Found] {
        var walk = ConfigWalk(note: .stillInFile)
        for (index, model) in (root["models"]?.items ?? []).enumerated() {
            guard let key = model["apiKey"]?.scalar else { continue }
            let label: String = model["provider"]?.string ?? model["name"]?.string ?? "model"
            let scope: String = "models." + (model["name"]?.string ?? String(index))
            walk.scalar(key, name: StoredSecretName.fromParts([label, "api_key"]), place: "models[\(index)].apiKey",
                        scope: scope, sourceSays: true)
        }
        for (index, server) in (root["mcpServers"]?.items ?? []).enumerated() {
            let scope: String = "mcpServers." + (server["name"]?.string ?? String(index))
            walk.env(server["env"], place: "mcpServers[\(index)].env", scope: scope)
        }
        return walk.found
    }
}
