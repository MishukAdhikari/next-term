import Foundation

// Agents' YAML configs, which keep their keys after a copy: goose's `config.yaml` (its settings at the root, each
// extension's `envs`) and Continue's `config.yaml` (its models' `apiKey`, its MCP servers' `env`). The rest of each
// file is read by its paths.

extension SecretSources {
    /// goose's extension: one with `envs`, `env_keys` or `cmd`, or with a type goose has.
    static func isGooseExtension(_ pair: YAMLSubset.Pair) -> Bool {
        if pair.value["envs"] != nil || pair.value["env_keys"] != nil || pair.value["cmd"] != nil { return true }
        guard let type = pair.value["type"]?.string else { return false }
        return gooseTypes.contains(type)
    }

    /// goose's settings at the root, each extension's `envs`, then the rest of the file.
    static func gooseFound(_ root: YAMLSubset.Node, extensions: [YAMLSubset.Pair], section: String) -> [Found] {
        var walk = ConfigWalk(note: .stillInFile)
        for pair in root.pairs ?? [] {
            guard let value = pair.value.scalar else { continue }
            walk.scalar(value, name: envName(pair.key), place: pair.key, scope: "")
        }
        for pair in extensions {
            let place: String = "extensions." + pair.key
            walk.env(pair.value["envs"], place: place + ".envs", scope: place)
        }
        walk.rest(root, section: section)
        return walk.found
    }

    /// Continue's config: a model with a `provider` or `uses`, or an MCP server with a `command`, a `url` or `uses`.
    static func isContinue(_ root: YAMLSubset.Node) -> Bool {
        let models: [YAMLSubset.Node] = root["models"]?.items ?? []
        let servers: [YAMLSubset.Node] = root["mcpServers"]?.items ?? []
        let model: Bool = models.contains { (item: YAMLSubset.Node) -> Bool in
            item["provider"] != nil || item["uses"] != nil
        }
        return model || servers.contains { (item: YAMLSubset.Node) -> Bool in
            item["command"] != nil || item["url"] != nil || item["uses"] != nil
        }
    }

    /// Continue's models' `apiKey`, named by the provider (ANTHROPIC_API_KEY), or by the model's `name`, which the user
    /// typed, when it has no provider: agents will see that name, and the row says so. Then its MCP servers' `env`, and
    /// the rest of the file.
    static func continueFound(_ root: YAMLSubset.Node, section: String) -> [Found] {
        var walk = ConfigWalk(note: .stillInFile)
        for (index, model) in (root["models"]?.items ?? []).enumerated() {
            guard let key = model["apiKey"]?.scalar else { continue }
            let provider: String? = model["provider"]?.string
            let title: String? = model["name"]?.string
            let label: String = provider ?? title ?? "model"
            let scope: String = "models." + (title ?? String(index))
            let name: String = StoredSecretName.fromParts([label, "api_key"])
            walk.scalar(key, name: name, place: "models[\(index)].apiKey", scope: scope, sourceSays: true,
                        fromTitle: provider == nil && title != nil)
        }
        for (index, server) in (root["mcpServers"]?.items ?? []).enumerated() {
            let scope: String = "mcpServers." + (server["name"]?.string ?? String(index))
            walk.env(server["env"], place: "mcpServers[\(index)].env", scope: scope)
        }
        walk.rest(root, section: section)
        return walk.found
    }
}
