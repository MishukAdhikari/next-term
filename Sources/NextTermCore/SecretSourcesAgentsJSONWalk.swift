import Foundation

// The places in agents' JSON configs that hold keys, read with their lines: an env object, an HTTP server's headers,
// one string member, and opencode's config (https://opencode.ai/docs/config/), whose providers keep a key in
// `options.apiKey` and whose MCP servers keep an `environment` and `headers`.

extension SecretSources {
    /// opencode's config: named `opencode.json` or `opencode.jsonc`, or with opencode's schema.
    static func isOpencode(_ root: JSONC.Object, file: String, walk: JSONWalk) -> Bool {
        if file == "opencode.json" || file == "opencode.jsonc" { return true }
        let schema: String? = root.member("$schema")?.value.object(in: walk.text) as? String
        return schema?.contains("opencode.ai") ?? false
    }

    /// opencode's providers' keys, each named as the provider reads it from the environment (`openai` is
    /// OPENAI_API_KEY), and its MCP servers' `environment` and `headers`.
    static func opencodeFound(_ root: JSONC.Object, walk: inout JSONWalk) {
        if let member = root.member("provider"), case .object(let providers) = member.value {
            for provider in providers.members {
                guard case .object(let entry) = provider.value, let options = entry.member("options"),
                      case .object(let settings) = options.value else { continue }
                let place: String = "provider." + provider.key
                let name: String = StoredSecretName.fromParts([provider.key, "api_key"])
                walk.string(settings.member("apiKey"), name: name, place: place + ".options.apiKey", scope: place)
            }
        }
        guard let member = root.member("mcp"), case .object(let servers) = member.value else { return }
        for server in servers.members {
            guard case .object(let entry) = server.value else { continue }
            let place: String = "mcp." + server.key
            walk.env(entry.member("environment")?.value, place: place + ".environment", scope: place)
            walk.headers(entry.member("headers")?.value, server: server.key, place: place + ".headers", scope: place)
        }
    }
}

extension JSONWalk {
    /// An agent's env object: each string or number a value named as a `.env` names it, with its line and the walk's
    /// note. Its place is passed over by the walk over the rest of the file.
    mutating func env(_ value: JSONC.Value?, place: String, scope: String) {
        guard let value, case .object(let object) = value else { return }
        known.insert(place)
        for member in object.members {
            guard !isFull, case .scalar = member.value else { continue }
            let read: Any? = member.value.object(in: text)
            let item: String
            if let string = read as? String {
                item = string
            } else if let number = read as? NSNumber {
                item = number.stringValue
            } else {
                continue
            }
            found.append(Found(name: SecretSources.envName(member.key), value: item, place: place + "." + member.key,
                               line: line(of: member.keyRange.lowerBound), scope: scope, isText: read is String,
                               note: note))
        }
    }

    /// An HTTP server's `headers`: `Authorization` holds the server's token, named SERVER_TOKEN and kept without its
    /// `Bearer `; any other header is named as a `.env` names it.
    mutating func headers(_ value: JSONC.Value?, server: String, place: String, scope: String) {
        guard let value, case .object(let headers) = value else { return }
        known.insert(place)
        for header in headers.members {
            guard !isFull, case .scalar = header.value,
                  let raw = header.value.object(in: text) as? String else { continue }
            let isAuthorization: Bool = header.key.lowercased() == "authorization"
            let bare: String = raw.hasPrefix("Bearer ") ? String(raw.dropFirst(7)) : raw
            let name: String = isAuthorization ? StoredSecretName.fromParts([server, "token"])
                : SecretSources.envName(header.key)
            found.append(Found(name: name, value: isAuthorization ? bare : raw, place: place + "." + header.key,
                               line: line(of: header.keyRange.lowerBound), scope: scope, note: note))
        }
    }

    /// One member's string as a value named `name`, which its source calls a key; nothing for any other value, which
    /// the walk over the rest of the file reads.
    mutating func string(_ member: JSONC.Member?, name: String, place: String, scope: String) {
        guard let member, !isFull, case .scalar = member.value,
              let value = member.value.object(in: text) as? String else { return }
        known.insert(place)
        found.append(Found(name: name, value: value, place: place, line: line(of: member.keyRange.lowerBound),
                           scope: scope, sourceSays: true, note: note))
    }
}
