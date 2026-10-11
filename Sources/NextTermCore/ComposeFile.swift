import Foundation

/// A port a Compose service publishes on this Mac: the host side, and the container port it maps to.
public struct ComposePort: Sendable, Equatable {
    public let published: Int
    public let target: Int?

    public init(published: Int, target: Int?) {
        self.published = published
        self.target = target
    }
}

/// One service of a Compose file: its name, its image and the ports it publishes on this Mac. Nothing else a service
/// holds is read, its `environment:` and `env_file:` least of all.
public struct ComposeService: Sendable, Equatable {
    /// As written in the file.
    public let name: String
    /// Without its registry, tag or digest, lower-cased: `qdrant/qdrant`, `postgres`. Nil for a service that builds
    /// its own image or names it through a variable.
    public let image: String?
    public let ports: [ComposePort]

    /// The host port that reaches `target` in the container (6333, Qdrant's dashboard), else nil.
    public func port(forTarget target: Int) -> Int? {
        ports.first { (port: ComposePort) -> Bool in port.target == target }?.published
    }
}

/// The Compose file a project runs with, read for its services' images and published ports only. It is read by a
/// narrow reader of its own, never a YAML library: `services:`, then each service's `image:` and `ports:`, in either
/// form. A service that uses an anchor, an alias or a merge key is skipped, since what it holds may come from
/// elsewhere in the file. A port written with a variable takes the variable's value only when its name is a port's
/// and not a secret's, as `mayReadVariable` says; otherwise its default, and with no default there is no port.
public struct ComposeFile: Sendable, Equatable {
    /// Relative to the project.
    public let file: String
    public let services: [ComposeService]

    public init(file: String, services: [ComposeService]) {
        self.file = file
        self.services = services
    }

    /// The names Compose looks for, in its order; the first that exists is the one it runs.
    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    /// The service a URL's host names (`http://qdrant:6333`), matched without case, as a host is.
    public func service(named name: String) -> ComposeService? {
        let lowered = name.lowercased()
        return services.first { (service: ComposeService) -> Bool in service.name.lowercased() == lowered }
    }

    /// The services that run an image, written with or without registry and tag (`ghcr.io/berriai/litellm`).
    public func services(withImage image: String) -> [ComposeService] {
        guard let wanted = Self.imageName(image) else { return [] }
        return services.filter { (service: ComposeService) -> Bool in service.image == wanted }
    }

    /// Whether a variable in a port may have its value read from the project's `.env`: a name with a `PORT` segment
    /// that does not mark a secret (`QDRANT_PORT`, not `DB_PASSWORD` or `SECRET_PORT`).
    public static func mayReadVariable(_ name: String) -> Bool {
        SecretName.segments(of: name).contains("PORT") && !SecretName.isSecret(name)
    }

    /// An image reference without its registry, tag and digest, lower-cased, and Docker Hub's `library/` cut:
    /// `docker.io/qdrant/qdrant:v1.15.0@sha256:…` gives `qdrant/qdrant`. Nil when the name itself holds a variable or
    /// anything but `[a-z0-9._-]` between slashes.
    public static func imageName(_ reference: String) -> String? {
        let text = unquoted(reference.trimmingCharacters(in: .whitespaces))
        let named = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        var components = named.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = components.last else { return nil }
        let untagged = last.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        components[components.count - 1] = String(untagged)
        var registry: String?
        if components.count > 1, let first = components.first,
           first.contains(".") || first.contains(":") || first == "localhost" {
            registry = first.lowercased()
            components.removeFirst()
        }
        let lowered = components.map { (component: String) -> String in component.lowercased() }
        let plain = lowered.allSatisfy { (component: String) -> Bool in isImageComponent(component) }
        guard !lowered.isEmpty, plain else { return nil }
        let hub: Bool = registry == nil || dockerHub.contains(registry ?? "")
        let path = hub && lowered.count > 1 && lowered[0] == "library" ? Array(lowered.dropFirst()) : lowered
        return path.joined(separator: "/")
    }

    private static let dockerHub: Set<String> = ["docker.io", "index.docker.io", "registry-1.docker.io"]
    private static let imageCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func isImageComponent(_ component: String) -> Bool {
        let plain = component.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in imageCharacters.contains(scalar) }
        return !component.isEmpty && plain && component != "." && component != ".."
    }

    /// A YAML scalar without its quotes.
    static func unquoted<S: StringProtocol>(_ value: S) -> String {
        let text = String(value)
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - Reading the file

extension ComposeFile {
    /// One line that holds something: its indent, and its text without the comment and the blanks at the end.
    struct Line {
        let indent: Int
        let text: Substring
    }

    /// The services of a Compose file, in file order. `portVariables` are the project `.env`'s values for port
    /// names; only those `mayReadVariable` allows are looked at.
    public static func parse(_ text: String, portVariables: [String: Int] = [:]) -> [ComposeService] {
        let lines = meaningfulLines(text)
        let top = lines.firstIndex { (line: Line) -> Bool in
            line.indent == 0 && keyValue(line.text).map { (pair: (key: String, value: Substring)) -> Bool in
                pair.key == "services" && pair.value.isEmpty
            } ?? false
        }
        guard let top else { return [] }
        let end = lines[(top + 1)...].firstIndex { (line: Line) -> Bool in line.indent == 0 } ?? lines.count
        guard top + 1 < end else { return [] }
        let serviceIndent = lines[top + 1].indent
        var services: [ComposeService] = []
        var index = top + 1
        while index < end {
            let blockEnd = endOfBlock(lines, after: index, indent: lines[index].indent, limit: end)
            if lines[index].indent == serviceIndent,
               let service = service(lines[index..<blockEnd], portVariables: portVariables) {
                services.append(service)
            }
            index = blockEnd
        }
        return services
    }

    /// The first line after `index` that is not deeper than `indent`, or `limit`.
    static func endOfBlock(_ lines: [Line], after index: Int, indent: Int, limit: Int) -> Int {
        var next = index + 1
        while next < limit, lines[next].indent > indent { next += 1 }
        return next
    }

    /// A service from its header line and the lines under it, or nil if it is not one this reader can trust.
    static func service(_ block: ArraySlice<Line>, portVariables: [String: Int]) -> ComposeService? {
        let lines = Array(block)
        guard let header = lines.first, let pair = keyValue(header.text), pair.value.isEmpty,
              isServiceName(pair.key), lines.count > 1 else { return nil }
        let propertyIndent = lines[1].indent
        var image: String?
        var ports: [ComposePort] = []
        var index = 1
        while index < lines.count {
            // A list may sit at its key's own indent: `ports:`, then `- "80:80"` straight below the p of `ports`.
            var blockEnd = endOfBlock(lines, after: index, indent: lines[index].indent, limit: lines.count)
            while blockEnd < lines.count, lines[blockEnd].indent == lines[index].indent, lines[blockEnd].text.hasPrefix("-") {
                blockEnd = endOfBlock(lines, after: blockEnd, indent: lines[blockEnd].indent, limit: lines.count)
            }
            defer { index = blockEnd }
            guard lines[index].indent == propertyIndent else { continue }
            guard let property = keyValue(lines[index].text) else { return nil }
            var value = property.value
            if opensFlow(value) {
                // `ports: [`, its items, then `]`, which may sit at the key's own indent.
                guard let flow = flowValue(lines, after: index, opening: value) else { return nil }
                value = flow.text
                blockEnd = max(blockEnd, flow.end)
            }
            let shared: Bool = property.key == "<<" || value.hasPrefix("&") || value.hasPrefix("*")
            guard !shared else { return nil }
            if property.key == "image" { image = imageName(String(value)) }
            guard property.key == "ports" else { continue }
            let items = lines[(index + 1)..<blockEnd]
            guard let found = publishedPorts(value, under: items, portVariables: portVariables) else { return nil }
            ports = found
        }
        return ComposeService(name: pair.key, image: image, ports: ports)
    }

    private static let serviceNameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    static func isServiceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && name.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in serviceNameCharacters.contains(scalar) }
    }
}

// MARK: - Lines, keys and flow collections

extension ComposeFile {
    /// The lines that hold something, without comments, line ends or the blanks at the end. A tab never indents YAML,
    /// so a line indented by one is not read.
    static func meaningfulLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        let rows = text.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r\n" || c == "\r" })
        for raw in rows {
            let indent = raw.prefix { (c: Character) -> Bool in c == " " }.count
            let body = withoutComment(raw.dropFirst(indent))
            guard !body.isEmpty, body.first != "\t", body != "---", body != "..." else { continue }
            lines.append(Line(indent: indent, text: body))
        }
        return lines
    }

    /// The text before a `#` that starts a comment (at the start, or after a blank, outside quotes), without the
    /// blanks at its end.
    static func withoutComment(_ text: Substring) -> Substring {
        var quote: Character?
        var previous: Character = " "
        var end = text.endIndex
        for index in text.indices {
            let c = text[index]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" {
                end = index
                break
            }
            previous = c
        }
        var body = text[..<end]
        while let last = body.last, last == " " || last == "\t" { body = body.dropLast() }
        return body
    }

    /// `key: value` or `key:`, with the key unquoted; nil for a line that is not a mapping's (a list item).
    static func keyValue(_ text: Substring) -> (key: String, value: Substring)? {
        guard !text.hasPrefix("- "), text != "-" else { return nil }
        var quote: Character?
        for index in text.indices {
            let c = text[index]
            if let open = quote {
                if c == open { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; continue }
            guard c == ":" else { continue }
            let after = text.index(after: index)
            guard after == text.endIndex || text[after] == " " else { continue }
            let key = unquoted(text[..<index].trimmingCharacters(in: .whitespaces))
            let value = text[after...].drop { (c: Character) -> Bool in c == " " }
            return key.isEmpty ? nil : (key, value)
        }
        return nil
    }

    /// Whether a value starts a flow collection that its own line does not close.
    static func opensFlow(_ value: Substring) -> Bool {
        (value.first == "[" || value.first == "{") && flowDepth(value) > 0
    }

    /// A flow collection that a key's line opens and later lines close, however those are indented: its text as one
    /// line, and the index of the line after its last. Nil when it never closes.
    static func flowValue(_ lines: [Line], after index: Int, opening value: Substring) -> (text: Substring, end: Int)? {
        var text = String(value)
        var depth = flowDepth(value)
        var next = index + 1
        while depth > 0 {
            guard next < lines.count else { return nil }
            text += " " + lines[next].text
            depth += flowDepth(lines[next].text)
            next += 1
        }
        return (Substring(text), next)
    }

    /// How many more brackets a line opens than it closes, outside quotes.
    static func flowDepth(_ text: Substring) -> Int {
        var depth = 0
        var quote: Character?
        for c in text {
            if let open = quote {
                if c == open { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// The items of a flow collection, `[a, b]` or `{a: 1, b: 2}`, split at commas outside quotes and inner
    /// brackets; nil if it is not one or does not close.
    static func flowItems(_ text: Substring, open: Character, close: Character) -> [Substring]? {
        guard text.first == open, text.last == close, text.count >= 2 else { return nil }
        let inner = text.dropFirst().dropLast()
        var items: [Substring] = []
        var depth = 0
        var quote: Character?
        var start = inner.startIndex
        for index in inner.indices {
            let c = inner[index]
            if let open = quote {
                if c == open { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case "," where depth == 0:
                items.append(inner[start..<index])
                start = inner.index(after: index)
            default: break
            }
        }
        items.append(inner[start...])
        let trimmed = items.map { (item: Substring) -> Substring in Substring(item.trimmingCharacters(in: .whitespaces)) }
        return trimmed.filter { (item: Substring) -> Bool in !item.isEmpty }
    }
}

// MARK: - Ports

extension ComposeFile {
    /// One item of `ports:` as written.
    enum PortItem {
        /// `"[IP:]HOST:CONTAINER[/PROTOCOL]"`.
        case short(String)
        /// `target`, `published`, `host_ip`, `protocol`.
        case long([String: String])
        /// An anchor or an alias: what it holds is written elsewhere.
        case shared
    }

    /// The ports `ports:` publishes: a flow list on its own line, or a block list under it. Nil when an item is
    /// shared from elsewhere, which skips the service.
    static func publishedPorts(_ value: Substring, under lines: ArraySlice<Line>,
                               portVariables: [String: Int]) -> [ComposePort]? {
        var items: [PortItem] = []
        if !value.isEmpty {
            let flow = flowItems(value, open: "[", close: "]") ?? []
            items = flow.map { (item: Substring) -> PortItem in portItem(item, more: []) }
        } else {
            items = blockItems(lines)
        }
        var ports: [ComposePort] = []
        for item in items {
            switch item {
            case .shared: return nil
            case .short(let entry):
                if let found = port(short: entry, portVariables: portVariables) { ports.append(found) }
            case .long(let fields):
                if let found = port(long: fields, portVariables: portVariables) { ports.append(found) }
            }
        }
        return ports
    }

    /// The items of a block list: each `- ` line with the deeper lines that go on with it.
    static func blockItems(_ lines: ArraySlice<Line>) -> [PortItem] {
        var items: [PortItem] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            var next = index + 1
            while next < lines.endIndex, lines[next].indent > line.indent { next += 1 }
            if line.text.hasPrefix("-") {
                let first = line.text.dropFirst().drop { (c: Character) -> Bool in c == " " }
                let more = lines[(index + 1)..<next].map { (more: Line) -> Substring in more.text }
                items.append(portItem(first, more: more))
            }
            index = next
        }
        return items
    }

    /// One item from its first line's text and any lines that go on with it.
    static func portItem(_ first: Substring, more: [Substring]) -> PortItem {
        if first.hasPrefix("&") || first.hasPrefix("*") { return .shared }
        let mapping: [Substring]?
        if first.hasPrefix("{") {
            mapping = flowItems(first, open: "{", close: "}")
        } else {
            mapping = keyValue(first) == nil ? nil : [first] + more
        }
        guard let mapping else { return .short(unquoted(first)) }
        var fields: [String: String] = [:]
        for text in mapping {
            guard let pair = keyValue(text) else { continue }
            if pair.value.hasPrefix("&") || pair.value.hasPrefix("*") { return .shared }
            fields[pair.key] = unquoted(pair.value)
        }
        return .long(fields)
    }

    /// The port a short entry publishes on this Mac: one host port (not a range) on loopback or every address, over
    /// TCP. `"127.0.0.1:6334:6333/tcp"` gives 6334 for 6333; `"6333"` (the container's only) gives none.
    static func port(short entry: String, portVariables: [String: Int]) -> ComposePort? {
        let written = unquoted(entry.trimmingCharacters(in: .whitespaces))
        guard let text = substituted(written, portVariables: portVariables) else { return nil }
        var body = Substring(text)
        if let slash = body.lastIndex(of: "/") {
            guard body[body.index(after: slash)...].lowercased() == "tcp" else { return nil }
            body = body[..<slash]
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let published = portNumber(parts[parts.count - 2]),
              let target = portNumber(parts[parts.count - 1]) else { return nil }
        let address = parts.dropLast(2).joined(separator: ":")
        guard address.isEmpty || isThisMac(address) else { return nil }
        return ComposePort(published: published, target: target)
    }

    /// The long form's port: `published` one port, `host_ip` this Mac's if given, and TCP.
    static func port(long fields: [String: String], portVariables: [String: Int]) -> ComposePort? {
        guard let written = fields["published"], let text = substituted(written, portVariables: portVariables),
              let published = portNumber(Substring(text)) else { return nil }
        if let wire = fields["protocol"], wire.lowercased() != "tcp" { return nil }
        if let ip = fields["host_ip"] {
            guard let address = substituted(ip, portVariables: portVariables), isThisMac(address) else { return nil }
        }
        let targetText = fields["target"].flatMap { (value: String) -> String? in
            substituted(value, portVariables: portVariables)
        }
        let target = targetText.flatMap { (value: String) -> Int? in portNumber(Substring(value)) }
        return ComposePort(published: published, target: target)
    }

    /// 1 to 65535, written in digits only.
    static func portNumber(_ text: Substring) -> Int? {
        let digits = text.allSatisfy { (c: Character) -> Bool in c >= "0" && c <= "9" }
        guard digits, (1...5).contains(text.count), let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    /// Loopback, or every address of this Mac (`0.0.0.0`, `::`), with or without brackets.
    static func isThisMac(_ address: String) -> Bool {
        var host = address
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host == "0.0.0.0" || host == "::" || host == "::1" || DatabaseEnvironment.isLoopbackIPv4(host)
    }
}

// MARK: - Variables

extension ComposeFile {
    /// The text with each variable replaced as Compose would from the project's `.env`, for port names only:
    /// `${NAME}`, `$NAME`, `${NAME:-default}`, `${NAME-default}`, `${NAME:?error}` and `$$`. Nil when a variable has
    /// no value this reader may use, or its form gives none of its own (`${NAME:+other}`).
    static func substituted(_ text: String, portVariables: [String: Int]) -> String? {
        guard text.contains("$") else { return text }
        var result = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            if after.first == "$" {
                result += "$"
                rest = after.dropFirst()
                continue
            }
            if after.first == "{" {
                guard let close = after.firstIndex(of: "}") else { return nil }
                let inner = after[after.index(after: after.startIndex)..<close]
                guard let value = resolved(inner, portVariables) else { return nil }
                result += value
                rest = after[after.index(after: close)...]
                continue
            }
            let name = after.prefix { (c: Character) -> Bool in isNameCharacter(c) }
            guard !name.isEmpty, let value = resolved(name, portVariables) else { return nil }
            result += value
            rest = after.dropFirst(name.count)
        }
        return result + rest
    }

    /// One variable's text: its value when `mayReadVariable` allows it and the project gave one, else its default.
    static func resolved(_ expression: Substring, _ portVariables: [String: Int]) -> String? {
        let name = String(expression.prefix { (c: Character) -> Bool in isNameCharacter(c) })
        guard !name.isEmpty else { return nil }
        let operation = expression.dropFirst(name.count)
        let given: Int? = mayReadVariable(name) ? portVariables[name] : nil
        let value = given.map { (port: Int) -> String in String(port) }
        if operation.isEmpty { return value }
        for form in [":-", "-"] where operation.hasPrefix(form) {
            let fallback = operation.dropFirst(form.count)
            guard !fallback.contains("$") else { return nil }
            return value ?? String(fallback)
        }
        let required: Bool = operation.hasPrefix(":?") || operation.hasPrefix("?")
        return required ? value : nil
    }

    static func isNameCharacter(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
    }
}
