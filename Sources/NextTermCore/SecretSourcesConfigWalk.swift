import Foundation

// The walk over a TOML or YAML document read into `YAMLSubset.Node`s: an env's names and values, a value at a known
// place, or every value by its path, as JSON's are. A part the YAML reader doesn't follow is a row it refuses. A known
// shape's reader reads its places first; `rest` then reads every other value by its path, so none goes unseen.

struct ConfigWalk {
    typealias Found = SecretSources.Found
    typealias Node = YAMLSubset.Node
    typealias JSONPath = SecretSources.JSONPath

    /// Members that name a variable instead of holding a value: Codex's `env_key`, `bearer_token_env_var`, `env_vars`
    /// and `env_http_headers`, goose's `env_keys`. Never a row, and not counted.
    static let variableNames: Set<String> = [
        "env_key", "bearer_token_env_var", "env_vars", "env_http_headers", "env_keys",
    ]

    var found: [Found] = []
    /// The note each row of this file carries: the file keeps its keys, or is often in git.
    var note: SecretSources.Note?
    /// Places a known shape's reader read: `rest` passes them over.
    var known: Set<String> = []
    /// Aliases add no row: each takes values read where its anchor is (Compose's `environment: *env`).
    var skipsAliases = false

    var isFull: Bool { found.count > SecretSources.maxValues }

    static func line(_ number: Int) -> Int? { number > 0 ? number : nil }

    /// One value. A null is nothing, and a boolean a setting. `fromTitle` when its name was made from a name the user
    /// typed (Continue's model's `name`): agents will see it.
    mutating func scalar(_ scalar: YAMLSubset.Scalar, name: String, place: String, scope: String,
                         sourceSays: Bool = false, fromTitle: Bool = false) {
        known.insert(place)
        guard !isFull, scalar.kind != .null else { return }
        found.append(Found(name: name, value: scalar.text, place: place, line: Self.line(scalar.line), scope: scope,
                           sourceSays: sourceSays, isText: scalar.kind != .boolean, note: note, fromTitle: fromTitle))
    }

    /// A part not followed: a row refused with what it is.
    mutating func skipped(_ part: YAMLSubset.Part, line: Int, name: String, place: String, scope: String) {
        known.insert(place)
        if part == .alias, skipsAliases { return }
        let kind: String
        switch part {
        case .alias: kind = "a YAML alias"
        case .tag: kind = "a YAML tag"
        case .flow: kind = "a YAML flow collection"
        }
        refused(name: name, place: place, line: line, scope: scope, refusal: .unreadablePart, kind: kind)
    }

    /// A row refused whole, with no value read into it.
    mutating func refused(name: String, place: String, line: Int, scope: String, refusal: SecretSources.Refusal,
                          kind: String) {
        known.insert(place)
        guard !isFull else { return }
        found.append(Found(name: name, value: "", place: place, line: Self.line(line), scope: scope, refusal: refusal,
                           kind: kind))
    }

    /// A name whose value is kept elsewhere (Compose's name alone, Kubernetes' `valueFrom`): counted as a reference.
    mutating func reference(name: String, place: String, line: Int, scope: String) {
        known.insert(place)
        guard !isFull else { return }
        found.append(Found(name: name, value: "", place: place, line: Self.line(line), scope: scope, reference: true))
    }

    /// An env: each value named by its key, as a `.env` names one. Its values are strings; anything deeper is passed
    /// over.
    mutating func env(_ node: Node?, place: String, scope: String) {
        guard let node else { return }
        known.insert(place)
        if case .skipped(let part, let line) = node {
            let last: String = String(place.split(separator: ".").last ?? "")
            skipped(part, line: line, name: StoredSecretName.fromParts([scope, last]), place: place, scope: scope)
            return
        }
        for pair in node.pairs ?? [] {
            let at: String = place + "." + pair.key
            let name: String = SecretSources.envName(pair.key)
            switch pair.value {
            case .scalar(let value): scalar(value, name: name, place: at, scope: scope)
            case .skipped(let part, let line): skipped(part, line: line, name: name, place: at, scope: scope)
            default: continue
            }
        }
    }

    /// Every value in a node, named by its path as JSON's are. In a list, `{name, value}` and `{key, value}` items are
    /// named by their member, and each other item is a section of its own.
    mutating func walk(_ node: Node, at path: JSONPath, section: String) {
        guard !isFull else { return }
        switch node {
        case .mapping(let pairs):
            for pair in pairs where !Self.variableNames.contains(pair.key) {
                let place: JSONPath = path.member(pair.key)
                guard !known.contains(place.text) else { continue }
                walk(pair.value, at: place, section: path.text)
            }
        case .sequence(let items):
            for (index, item) in items.enumerated() {
                let place: JSONPath = path.element(index)
                if known.contains(place.text) || pair(item, at: place, section: path.text) { continue }
                walk(item, at: place, section: place.text)
            }
        case .scalar(let value):
            scalar(value, name: SecretSources.jsonName(path), place: path.text, scope: section)
        case .skipped(let part, let line):
            skipped(part, line: line, name: SecretSources.jsonName(path), place: path.text, scope: section)
        }
    }

    /// `{name, value}` or `{key, value}`: one value named by that member; `{name, valueFrom}` only points at a key kept
    /// elsewhere. False for any other node.
    mutating func pair(_ node: Node, at path: JSONPath, section: String) -> Bool {
        guard node.pairs != nil, let label = (node["name"] ?? node["key"])?.string else { return false }
        let name: String = StoredSecretName.isValid(label) ? label : StoredSecretName.fromParts([label])
        if let pointer = node["valueFrom"] {
            reference(name: name, place: path.text, line: pointer.line, scope: section)
            return true
        }
        guard let value = node["value"]?.scalar else { return false }
        scalar(value, name: name, place: path.text, scope: section)
        return true
    }
}

// MARK: - The rest of a file, and headers

extension ConfigWalk {
    /// Every value of a document outside the places read already, by its path: a known shape's other members.
    mutating func rest(_ root: Node, section: String = "") {
        walk(root, at: JSONPath(), section: section)
    }

    /// An HTTP server's headers (Codex's `http_headers`): `Authorization` holds the server's token, named SERVER_TOKEN
    /// and kept without its `Bearer `; any other header is named as a `.env` names it.
    mutating func headers(_ node: Node?, server: String, place: String, scope: String) {
        guard let pairs = node?.pairs else { return }
        known.insert(place)
        for pair in pairs {
            guard let value = pair.value.scalar else { continue }
            let at: String = place + "." + pair.key
            guard pair.key.lowercased() == "authorization" else {
                scalar(value, name: SecretSources.envName(pair.key), place: at, scope: scope)
                continue
            }
            let bare: String = value.text.hasPrefix("Bearer ") ? String(value.text.dropFirst(7)) : value.text
            let token = YAMLSubset.Scalar(text: bare, style: value.style, line: value.line)
            scalar(token, name: StoredSecretName.fromParts([server, "token"]), place: at, scope: scope)
        }
    }
}
