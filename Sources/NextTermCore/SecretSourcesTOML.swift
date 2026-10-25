import Foundation

// TOML for the import, read with the importer's TOML reader into `YAMLSubset.Node`s, each member in file order with
// its line. Codex's `config.toml` gives its MCP servers' envs and `http_headers`, its shell's `set` and a model
// provider's bearer token and headers, and keeps them (the file is Codex's, and Next Term rewrites only its MCP
// servers); `bearer_token_env_var`, `env_key` and the like name a variable and are no key. Cargo's credentials are
// named as Cargo reads them from the environment. The rest of a Codex or Cargo file, and any other TOML (Streamlit's
// `secrets.toml`), is read by its paths: a key in a section is named SECTION_KEY.

extension SecretSources {
    static func tomlFound(_ text: String) -> Result<ConfigFound, Unreadable> {
        let table: [String: TOMLValue]
        switch TOMLReader.parse(text) {
        case .failure(let error): return .failure(.notTOML(line: error.line))
        case .success(let read): table = read
        }
        let root: YAMLSubset.Node = tomlNode(.table(table), path: [], lines: tomlLines(text), inherited: 0)
        let codex: Set<String> = ["mcp_servers", "shell_environment_policy", "model_providers"]
        if table.keys.contains(where: { (key: String) -> Bool in codex.contains(key) && table[key]?.table != nil }) {
            return .success(ConfigFound(values: codexFound(root), agent: "Codex"))
        }
        let cargo: Set<String> = ["registry", "registries"]
        if !table.isEmpty, table.keys.allSatisfy({ (key: String) -> Bool in cargo.contains(key) }) {
            return .success(ConfigFound(values: cargoFound(root), agent: nil))
        }
        var walk = ConfigWalk()
        walk.walk(root, at: JSONPath(), section: "")
        return .success(ConfigFound(values: walk.found, agent: nil))
    }

    /// Codex's envs, its shell's `set`, and each model provider's bearer token, named by the provider's `env_key` (the
    /// variable Codex would read it from) or as PROVIDER_API_KEY. Each keeps the note that the file still holds it.
    static func codexFound(_ root: YAMLSubset.Node) -> [Found] {
        var walk = ConfigWalk(note: .stillInFile)
        for pair in root.pairs ?? [] {
            switch pair.key {
            case "model_providers":
                for provider in pair.value.pairs ?? [] {
                    let place: String = "model_providers." + provider.key
                    walk.headers(provider.value["http_headers"], server: provider.key, place: place + ".http_headers",
                                 scope: place)
                    guard let token = provider.value["experimental_bearer_token"]?.scalar else { continue }
                    let named: String? = provider.value["env_key"]?.string
                    let valid: String? = named.flatMap { (name: String) -> String? in
                        StoredSecretName.isValid(name) ? name : nil
                    }
                    let name: String = valid ?? StoredSecretName.fromParts([provider.key, "api_key"])
                    walk.scalar(token, name: name, place: place + ".experimental_bearer_token", scope: place,
                                sourceSays: true)
                }
            case "mcp_servers":
                for server in pair.value.pairs ?? [] {
                    let place: String = "mcp_servers." + server.key
                    walk.env(server.value["env"], place: place + ".env", scope: place)
                    walk.headers(server.value["http_headers"], server: server.key, place: place + ".http_headers",
                                 scope: place)
                }
            case "shell_environment_policy":
                walk.env(pair.value["set"], place: "shell_environment_policy.set", scope: pair.key)
            default:
                continue
            }
        }
        walk.rest(root)
        return walk.found
    }

    /// Cargo's tokens: `registry.token` as CARGO_REGISTRY_TOKEN, and each `registries.NAME.token` as
    /// CARGO_REGISTRIES_NAME_TOKEN, the variables Cargo reads them from.
    static func cargoFound(_ root: YAMLSubset.Node) -> [Found] {
        var walk = ConfigWalk()
        for pair in root.pairs ?? [] {
            if pair.key == "registry", let token = pair.value["token"]?.scalar {
                walk.scalar(token, name: "CARGO_REGISTRY_TOKEN", place: "registry.token", scope: "registry",
                            sourceSays: true)
            }
            guard pair.key == "registries" else { continue }
            for registry in pair.value.pairs ?? [] {
                guard let token = registry.value["token"]?.scalar else { continue }
                let name: String = StoredSecretName.suggested(from: "CARGO_REGISTRIES_" + registry.key + "_TOKEN")
                let place: String = "registries." + registry.key
                walk.scalar(token, name: name, place: place + ".token", scope: place, sourceSays: true)
            }
        }
        walk.rest(root)
        return walk.found
    }
}
