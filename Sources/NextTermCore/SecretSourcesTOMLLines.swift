import Foundation

// A TOML table as `YAMLSubset.Node`s, in file order with lines. The TOML reader gives values, not places; the import's
// TOML outline gives each key's and each header's line, matched to values by their paths (an array of tables'
// element by its number).

extension SecretSources {
    /// A path as one key for the line table.
    static func tomlKey(_ parts: [String]) -> String { parts.joined(separator: "\u{1F}") }

    /// The line of each key and header in the file, by its path (`["mcp_servers", "github", "env"]`, with `[0]` after
    /// an array of tables' name for its first element); empty when the outline can't read the file.
    static func tomlLines(_ text: String) -> [String: Int] {
        var source: String = text
        source.makeContiguousUTF8()
        guard let outline = TOMLOutline(source) else { return [:] }
        let walk = JSONWalk(text: outline.text)
        var lines: [String: Int] = [:]
        var arrays = TOMLArrays()
        var table: [String] = []
        var headers: ArraySlice<TOMLOutline.Header> = outline.headers[...]
        var keys: ArraySlice<TOMLOutline.Key> = outline.keys[...]
        while !headers.isEmpty || !keys.isEmpty {
            if let header = headers.first,
               keys.first.map({ (key: TOMLOutline.Key) -> Bool in header.line.lowerBound < key.line.lowerBound }) ?? true {
                headers.removeFirst()
                if header.isArray { arrays.add(header.path) }
                table = indexed(header.path, counts: arrays.counts)
                let key: String = tomlKey(table)
                if lines[key] == nil { lines[key] = walk.line(of: header.line.lowerBound) }
            } else if let key = keys.first {
                keys.removeFirst()
                lines[tomlKey(table + key.path)] = walk.line(of: key.line.lowerBound)
            }
        }
        return lines
    }

    /// The arrays of tables written so far: each one's element being written, by its path. A new element of an array
    /// starts the arrays under it again, which are found from the array itself, so each is cleared once.
    struct TOMLArrays {
        var counts: [String: Int] = [:]
        var children: [String: [String]] = [:]

        mutating func add(_ path: [String]) {
            let key: String = SecretSources.tomlKey(path)
            let isNew: Bool = counts[key] == nil
            counts[key, default: -1] += 1
            clear(below: key)
            guard isNew else { return }
            for length in stride(from: path.count - 1, to: 0, by: -1) {
                let parent: String = SecretSources.tomlKey(Array(path[..<length]))
                guard counts[parent] != nil else { continue }
                children[parent, default: []].append(key)
                break
            }
        }

        mutating func clear(below key: String) {
            var stack: [String] = children.removeValue(forKey: key) ?? []
            while let child = stack.popLast() {
                counts[child] = nil
                stack += children.removeValue(forKey: child) ?? []
            }
        }
    }

    /// A header's path with each array of tables in it followed by the number of its element being written.
    static func indexed(_ path: [String], counts: [String: Int]) -> [String] {
        var parts: [String] = []
        for index in path.indices {
            parts.append(path[index])
            if let number = counts[tomlKey(Array(path[...index]))] { parts.append("[\(number)]") }
        }
        return parts
    }

    /// A TOML value as a node: a table's members ordered by their lines (those with none after, by name), strings as
    /// quoted scalars, anything else as a plain scalar's text. A value with no line of its own takes `inherited`.
    static func tomlNode(_ value: TOMLValue, path: [String], lines: [String: Int], inherited: Int) -> YAMLSubset.Node {
        let line: Int = lines[tomlKey(path)] ?? inherited
        func plain(_ text: String) -> YAMLSubset.Node {
            .scalar(YAMLSubset.Scalar(text: text, style: .plain, line: line))
        }
        switch value {
        case .string(let text):
            return .scalar(YAMLSubset.Scalar(text: text, style: .doubleQuoted, line: line))
        case .integer(let number): return plain(String(number))
        case .float(let number): return plain(String(number))
        case .bool(let flag): return plain(flag ? "true" : "false")
        case .datetime(let text): return .scalar(YAMLSubset.Scalar(text: text, style: .doubleQuoted, line: line))
        case .array(let items):
            let nodes: [YAMLSubset.Node] = items.enumerated().map { (pair: (offset: Int, element: TOMLValue)) in
                tomlNode(pair.element, path: path + ["[\(pair.offset)]"], lines: lines, inherited: line)
            }
            return .sequence(nodes)
        case .table(let members):
            var pairs: [YAMLSubset.Pair] = members.map { (member: (key: String, value: TOMLValue)) -> YAMLSubset.Pair in
                let node: YAMLSubset.Node = tomlNode(member.value, path: path + [member.key], lines: lines,
                                                     inherited: line)
                return YAMLSubset.Pair(key: member.key, line: lines[tomlKey(path + [member.key])] ?? node.line,
                                       value: node)
            }
            pairs.sort { (left: YAMLSubset.Pair, right: YAMLSubset.Pair) -> Bool in
                let first: Int = left.line > 0 ? left.line : Int.max
                let second: Int = right.line > 0 ? right.line : Int.max
                return first != second ? first < second : left.key < right.key
            }
            return .mapping(pairs)
        }
    }
}
