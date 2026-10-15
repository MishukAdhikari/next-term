import Foundation

// The walk over a TOML or YAML document read into `YAMLSubset.Node`s: an env's names and values, a value at a known
// place, or every value by its path, as JSON's are. A part the YAML reader doesn't follow is a row it refuses.

struct ConfigWalk {
    typealias Found = SecretSources.Found
    typealias Node = YAMLSubset.Node
    typealias JSONPath = SecretSources.JSONPath

    var found: [Found] = []
    /// The note each row of this file carries: the file keeps its keys, or is often in git.
    var note: SecretSources.Note?

    var isFull: Bool { found.count > SecretSources.maxValues }

    static func line(_ number: Int) -> Int? { number > 0 ? number : nil }

    /// One value. A null is nothing, and a boolean a setting.
    mutating func scalar(_ scalar: YAMLSubset.Scalar, name: String, place: String, scope: String,
                         sourceSays: Bool = false) {
        guard !isFull, scalar.kind != .null else { return }
        found.append(Found(name: name, value: scalar.text, place: place, line: Self.line(scalar.line), scope: scope,
                           sourceSays: sourceSays, isText: scalar.kind != .boolean, note: note))
    }

    /// A part not followed: a row refused with what it is.
    mutating func skipped(_ part: YAMLSubset.Part, line: Int, name: String, place: String, scope: String) {
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
        guard !isFull else { return }
        found.append(Found(name: name, value: "", place: place, line: Self.line(line), scope: scope, refusal: refusal,
                           kind: kind))
    }

    /// A name whose value is kept elsewhere (Compose's name alone, Kubernetes' `valueFrom`): counted as a reference.
    mutating func reference(name: String, place: String, line: Int, scope: String) {
        guard !isFull else { return }
        found.append(Found(name: name, value: "", place: place, line: Self.line(line), scope: scope, reference: true))
    }

    /// An env: each value named by its key, as a `.env` names one. Its values are strings; anything deeper is passed
    /// over.
    mutating func env(_ node: Node?, place: String, scope: String) {
        guard let node else { return }
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
            for pair in pairs { walk(pair.value, at: path.member(pair.key), section: path.text) }
        case .sequence(let items):
            for (index, item) in items.enumerated() {
                let place: JSONPath = path.element(index)
                if pair(item, at: place, section: path.text) { continue }
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

// MARK: - Agents' JSON configs

extension JSONWalk {
    /// An agent's env object: each string a value named as a `.env` names one, with its line and `note`.
    mutating func env(_ value: JSONC.Value?, place: String, scope: String, note: SecretSources.Note?) {
        guard let value, case .object(let object) = value else { return }
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
}
