import Foundation

// Kubernetes objects for the import (https://kubernetes.io/docs/concepts/configuration/secret/): a Secret's
// `stringData` and base64 `data`, a ConfigMap's `data`, and any `env` list of `{name, value}` items, where `valueFrom`
// only points at a key kept elsewhere.

extension SecretSources {
    /// A Kubernetes object's values. Every value in a Secret is a secret by its source.
    static func kubernetesFound(_ root: YAMLSubset.Node, number: Int) -> [Found] {
        let name: String = root["metadata"]?["name"]?.string ?? "secret"
        let scope: String = "[\(number)].\(name)"
        var walk = ConfigWalk()
        switch root["kind"]?.string {
        case "Secret": secretFound(root, name: name, scope: scope, into: &walk)
        case "ConfigMap": walk.env(root["data"], place: "data", scope: scope)
        default: break
        }
        envLists(root, at: JSONPath(), into: &walk)
        return walk.found
    }

    /// A Secret's values: `stringData` as written, then each `data` value it doesn't set, decoded from base64. A value
    /// that doesn't decode to UTF-8 text is refused. A Secret of a type that holds a certificate, an SSH key or a
    /// registry's login is one row, not importable yet.
    static func secretFound(_ root: YAMLSubset.Node, name: String, scope: String, into walk: inout ConfigWalk) {
        if let type = root["type"]?.string, let label = typedSecrets[type] {
            walk.refused(name: StoredSecretName.fromParts([name]), place: "the whole secret", line: root.line,
                         scope: scope, refusal: .typedSecret(label), kind: "a Kubernetes \(label) secret")
            return
        }
        let written: [YAMLSubset.Pair] = root["stringData"]?.pairs ?? []
        let given = Set(written.map(\.key))
        for pair in written {
            guard let value = pair.value.scalar else { continue }
            walk.scalar(value, name: secretKeyName(pair.key, secret: name), place: "stringData." + pair.key,
                        scope: scope, sourceSays: true)
        }
        for pair in root["data"]?.pairs ?? [] where !given.contains(pair.key) {
            guard let value = pair.value.scalar, value.kind != .null else { continue }
            let key: String = secretKeyName(pair.key, secret: name)
            let place: String = "data." + pair.key
            guard let text = decodedText(value.text) else {
                walk.refused(name: key, place: place, line: value.line, scope: scope, refusal: .notText,
                             kind: "a Kubernetes secret's value")
                continue
            }
            let decoded = YAMLSubset.Scalar(text: text, style: .doubleQuoted, line: value.line)
            walk.scalar(decoded, name: key, place: place, scope: scope, sourceSays: true)
        }
    }

    /// A Secret's key as a key's name: as it is when it is one, else with the Secret's name before it (`api-key` in
    /// the Secret `openai` is OPENAI_API_KEY).
    static func secretKeyName(_ key: String, secret: String) -> String {
        StoredSecretName.isValid(key) ? key : StoredSecretName.fromParts([secret, key])
    }

    /// Base64 decoded to UTF-8 text, or nil. The decoded bytes are wiped.
    static func decodedText(_ base64: String) -> String? {
        guard var data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespaces)) else { return nil }
        defer { SecretBytes.wipe(&data) }
        return String(data: data, encoding: .utf8)
    }

    /// Every `env` list in an object, each `{name, value}` item one value.
    static func envLists(_ node: YAMLSubset.Node, at path: JSONPath, into walk: inout ConfigWalk) {
        switch node {
        case .mapping(let pairs):
            for pair in pairs {
                let place: JSONPath = path.member(pair.key)
                guard pair.key == "env", let items = pair.value.items else {
                    envLists(pair.value, at: place, into: &walk)
                    continue
                }
                for (index, item) in items.enumerated() {
                    _ = walk.pair(item, at: place.element(index), section: path.text)
                }
            }
        case .sequence(let items):
            for (index, item) in items.enumerated() { envLists(item, at: path.element(index), into: &walk) }
        default:
            break
        }
    }
}
