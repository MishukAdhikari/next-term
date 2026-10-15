import Foundation

// JSON and JSONC for the import: a flat object (`doppler secrets download`, `dotenvx get`), nested objects whose path
// names the key (`{"openai":{"apiKey":…}}` is OPENAI_API_KEY), `[{name, value}]` arrays (Azure App Service, ECS,
// Kubernetes `env`) and `[{key, value}]` ones. A `valueFrom` only points at a key, so it is a reference. A whole
// credential file (a Google Cloud service-account key) is one refused row. Objects are read with the import's own
// JSONC reader, in file order and with their lines; arrays with Foundation's, after it checked their depth.

extension SecretSources {
    /// Credential files by their `type`: Google Cloud's service-account keys, user credentials and workload identity.
    static let credentialTypes: Set<String> = ["service_account", "authorized_user", "external_account"]

    /// One leaf's or pair's walk: where it is, as parts and as text.
    struct JSONPath {
        var parts: [String] = []
        /// "containerDefinitions[0].environment[1]".
        var text: String = ""

        func member(_ key: String) -> JSONPath {
            JSONPath(parts: parts + [key], text: text.isEmpty ? key : text + "." + key)
        }

        func element(_ index: Int) -> JSONPath {
            JSONPath(parts: parts, text: text + "[\(index)]")
        }
    }

    /// Every string, number and boolean in the document as a found value, or nil when it isn't JSON (comments and
    /// trailing commas allowed). Stops one past `maxValues`.
    static func jsonFound(_ text: String) -> [Found]? {
        var source: String = text
        source.makeContiguousUTF8()
        guard let document = JSONC(source), let root = document.root else { return nil }
        var walk = JSONWalk(text: source)
        if case .object(let object) = root, let credential = walk.credentialFile(object) { return [credential] }
        walk.value(root, at: JSONPath(), section: "", line: nil)
        return walk.found
    }

    /// A key name for a leaf: its member's name when that is already one, else made from the path's parts.
    static func jsonName(_ path: JSONPath) -> String {
        if let last = path.parts.last, StoredSecretName.isValid(last) { return last }
        return StoredSecretName.fromParts(path.parts)
    }
}

/// The walk over one JSON document, collecting found values in order.
struct JSONWalk {
    typealias Found = SecretSources.Found
    typealias JSONPath = SecretSources.JSONPath

    let text: String
    var found: [Found] = []
    /// Where each line starts, as UTF-8 offsets: a member's line from its key's place.
    private let lineStarts: [Int]

    init(text: String) {
        self.text = text
        var starts: [Int] = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") { starts.append(offset + 1) }
        lineStarts = starts
    }

    var isFull: Bool { found.count > SecretSources.maxValues }

    /// The 1-based line of a place in the text.
    func line(of index: String.Index) -> Int {
        let offset: Int = text.utf8.distance(from: text.startIndex, to: index)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// A root object whose `type` names a credential file: one refused row for it all.
    func credentialFile(_ object: JSONC.Object) -> Found? {
        guard let member = object.member("type"), let type = member.value.object(in: text) as? String,
              SecretSources.credentialTypes.contains(type) else { return nil }
        let kind: String = type == "service_account" ? "Google Cloud service-account key" : "Google Cloud credentials"
        return Found(name: "GOOGLE_APPLICATION_CREDENTIALS", value: "", place: "the whole file", line: nil,
                     refusal: .credentialFile, kind: kind)
    }
}

// MARK: - The walk

extension JSONWalk {
    /// A value read with the JSONC reader: an object's members in file order, with their lines.
    mutating func value(_ value: JSONC.Value, at path: JSONPath, section: String, line: Int?) {
        guard !isFull else { return }
        switch value {
        case .object(let object):
            for member in object.members {
                let at: Int = self.line(of: member.keyRange.lowerBound)
                self.value(member.value, at: path.member(member.key), section: path.text, line: at)
            }
        case .scalar:
            leaf(value.object(in: text), at: path, section: section, line: line)
        case .array:
            guard let elements = value.object(in: text) as? [Any] else { return }
            array(elements, at: path)
        }
    }

    /// A value read with Foundation's reader, inside an array: an object's members by name, with no lines.
    mutating func foundation(_ object: Any, at path: JSONPath, section: String) {
        guard !isFull else { return }
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let member = dictionary[key] else { continue }
                foundation(member, at: path.member(key), section: path.text)
            }
        } else if let elements = object as? [Any] {
            array(elements, at: path)
        } else {
            leaf(object, at: path, section: section, line: nil)
        }
    }

    /// An array's elements: a name/value pair is one value named by its member; anything else is walked.
    mutating func array(_ elements: [Any], at path: JSONPath) {
        for (index, element) in elements.enumerated() {
            guard !isFull else { return }
            let place: JSONPath = path.element(index)
            if let dictionary = element as? [String: Any], pair(dictionary, at: place, section: path.text) { continue }
            foundation(element, at: place, section: path.text)
        }
    }

    /// `{name, value}` or `{key, value}`: a value named by that member. `{name, valueFrom}` only points at a key kept
    /// elsewhere (a Kubernetes Secret, an ECS parameter): a reference. False for any other object.
    mutating func pair(_ dictionary: [String: Any], at path: JSONPath, section: String) -> Bool {
        let label: Any? = dictionary["name"] ?? dictionary["key"]
        guard let label = label as? String else { return false }
        let name: String = StoredSecretName.isValid(label) ? label : StoredSecretName.fromParts([label])
        if dictionary["valueFrom"] != nil {
            found.append(Found(name: name, value: "", place: path.text, line: nil, scope: section, reference: true))
            return true
        }
        guard let value = dictionary["value"] else { return false }
        if let text = value as? String {
            found.append(Found(name: name, value: text, place: path.text, line: nil, scope: section))
        } else if let number = value as? NSNumber {
            found.append(Found(name: name, value: number.stringValue, place: path.text, line: nil, scope: section,
                               isText: false))
        }
        return true
    }

    /// A string, number or boolean at its path; a null is nothing.
    mutating func leaf(_ object: Any?, at path: JSONPath, section: String, line: Int?) {
        let name: String = SecretSources.jsonName(path)
        if let text = object as? String {
            found.append(Found(name: name, value: text, place: path.text, line: line, scope: section))
        } else if let number = object as? NSNumber {
            found.append(Found(name: name, value: number.stringValue, place: path.text, line: line, scope: section,
                               isText: false))
        }
    }
}
