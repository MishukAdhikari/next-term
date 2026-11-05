import Foundation

/// What a server in the MCP hub's list (MCPHubServer) must be before Next Term saves it or uses it. Each rule gives its
/// reason in plain words, as one sentence, for Settings and for an agent's add request to show.
///
/// - **Names** are lowercase letters, digits and single `-` between them, at most `maxName`: an agent sees a server's
///   tools as `<server>__<tool>` inside its own prefix and a 64-character limit, and Gemini CLI's parser warns on `_`.
///   `next-term` is Next Term's own entry.
/// - **Commands** are one program, as written: no space at either end, no control character.
/// - **URLs** are https://, or http:// to this Mac only (a key sent over plain HTTP crosses the network readable).
///   javascript:, data:, file: and every other scheme are refused, and so is a user name or password in the URL.
/// - **Keys stay in Secrets.** A value that looks like a key, by Secrets' import's own detection (SecretImport.detect,
///   argumentFindings and headerKind), is refused with where it goes instead: for a command, `nxtrm secret run NAME --`
///   in front; in a URL or header, `${secret:NAME}`, which only the app fills in, at request time. That placeholder is
///   refused in a command, where nothing would fill it in, and a URL or header takes no other reference (`${X}`,
///   `{env:X}`): the app would send it as written.
public enum MCPHubRules {
    public static let maxName = 32
    /// Names a server can't have: Next Term's own MCP server's.
    public static let reservedNames: Set<String> = [MCPServer.name]

    /// Every rule `server` breaks in a list at `place`: none when it can be saved and used.
    public static func reasons(_ server: MCPHubServer, place: MCPHubFile.Place) -> [String] {
        var reasons: [String] = []
        if let reason = nameReason(server.name) { reasons.append(reason) }
        switch server.transport {
        case .stdio: reasons += commandReasons(server)
        case .http, .sse: reasons += remoteReasons(server)
        }
        if place == .user, case .only(let folders) = server.projects {
            if folders.isEmpty { reasons.append("Its project list names no folder; give it one, or all projects.") }
            for folder in folders where !(folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/")) {
                reasons.append("\(folder) is not a folder's full path.")
            }
        }
        return reasons
    }

    // MARK: names

    public static func nameReason(_ name: String) -> String? {
        if name.isEmpty { return "It has no name." }
        if reservedNames.contains(name) { return "\(name) is Next Term's own server; give this one another name." }
        if name.utf8.count > maxName { return "Its name is over \(maxName) characters." }
        let allowed = name.utf8.allSatisfy { isLowerOrDigit($0) || $0 == UInt8(ascii: "-") }
        guard allowed, !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else {
            return "\(name) can't be a server's name: lowercase letters, digits, and - between them."
        }
        return nil
    }

    /// A name that follows the rules, made from one that may not (a pasted entry's `GitHub`, `my_server`): lowercase,
    /// every run of other characters one `-`, cut to `maxName`. Next Term's own name gets `-2`.
    public static func suggestedName(from text: String) -> String {
        var name = ""
        for byte in text.lowercased().utf8 {
            if isLowerOrDigit(byte) {
                name.append(Character(Unicode.Scalar(byte)))
            } else if !name.isEmpty, !name.hasSuffix("-") {
                name += "-"
            }
        }
        name = String(name.prefix(maxName))
        while name.hasSuffix("-") { name.removeLast() }
        if name.isEmpty { return "server" }
        return reservedNames.contains(name) ? name + "-2" : name
    }

    static func isLowerOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    // MARK: local servers

    static let moveToSecrets = "Move it to Secrets, and start the server with nxtrm secret run NAME -- in front."
    static let placeholderInCommand = "uses ${secret:…}, which Next Term fills in only in a URL or header; for a command, "
        + "start it with nxtrm secret run NAME -- in front."

    static func commandReasons(_ server: MCPHubServer) -> [String] {
        var reasons: [String] = []
        let command = server.command
        if command.trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append("Its command is empty.")
        } else if command != command.trimmingCharacters(in: .whitespacesAndNewlines) || hasControl(command) {
            reasons.append("Its command has spaces at an end, or a line break; give the program alone, and the rest as arguments.")
        }
        if server.args.contains(where: { $0.contains("\u{0}") }) { reasons.append("An argument holds a NUL character.") }
        for (name, value) in server.env.sorted(by: { $0.key < $1.key }) {
            if !isVariableName(name) { reasons.append("\(name) can't be an environment variable's name.") }
            if value.contains("\u{0}") { reasons.append("\(name) holds a NUL character.") }
        }

        if ([command] + server.args + Array(server.env.values)).contains(where: { $0.contains("${secret:") }) {
            reasons.append("It " + placeholderInCommand)
        }
        let words = [command] + server.args
        if SecretImport.isWrapped(command: words) {
            let rest = Array(words.dropFirst((command as NSString).lastPathComponent == "nxtrm" ? 3 : 4))
            if case .failure(let error) = SecretRun.parse(rest) { reasons.append("Its nxtrm secret run is wrong: \(error.reason).") }
        }
        for found in SecretImport.argumentFindings(server.args.map { ($0, 0..<0) }) {
            reasons.append("Its \(found.variable) looks like a key (\(found.kind)). " + moveToSecrets)
        }
        for (name, value) in server.env.sorted(by: { $0.key < $1.key }) {
            if let kind = SecretImport.detect(name: name, value: value) {
                reasons.append("\(name) looks like a key (\(kind)). " + moveToSecrets)
            }
        }
        return reasons
    }

    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
        return name.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || isLowerOrDigit(byte) || byte == UInt8(ascii: "_")
        }
    }

    static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    // MARK: remote servers

    /// Stands in for each `${secret:NAME}` while a URL is checked: letters only, so it parses in any part.
    static let stand = "nxtrmsecret"
    static let moveToHeader = "Move it to Secrets, and use ${secret:NAME} in its place."

    static func remoteReasons(_ server: MCPHubServer) -> [String] {
        var reasons: [String] = []
        let (url, urlNames) = withoutPlaceholders(server.url)
        if urlNames.contains(where: { !StoredSecretName.isValid($0) }) || url.contains("${secret:") {
            reasons.append(badPlaceholder("Its URL"))
        } else if let reason = urlReason(url) {
            reasons.append(reason)
        }
        for (name, value) in server.headers.sorted(by: { $0.key < $1.key }) {
            if !isHeaderName(name) { reasons.append("\(name) can't be a header's name.") }
            if hasControl(value) { reasons.append("Its \(name) header has a line break or a control character.") }
            let (bare, names) = withoutPlaceholders(value, as: "")
            if names.contains(where: { !StoredSecretName.isValid($0) }) || bare.contains("${secret:") {
                reasons.append(badPlaceholder("Its \(name) header"))
            } else if SecretImport.withoutReferences(bare) != nil {
                reasons.append("Its \(name) header has a reference Next Term doesn't fill in; for a key, use ${secret:NAME}.")
            } else if let kind = SecretImport.headerKind(name: name, value: bare) {
                reasons.append("Its \(name) header looks like a key (\(kind)). " + moveToHeader)
            }
        }
        return reasons
    }

    static func badPlaceholder(_ what: String) -> String {
        "\(what) has a ${secret:…} without a key's name in it; a name is capital letters, digits and _, starting with a letter."
    }

    /// Why a remote server's URL (each `${secret:NAME}` already `stand`) can't be used, or nil.
    static func urlReason(_ url: String) -> String? {
        if url.isEmpty { return "Its URL is empty." }
        if url.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) {
            return "Its URL has a space or a line break in it."
        }
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else {
            return "Its URL is not a URL Next Term can read."
        }
        guard scheme == "https" || scheme == "http" else {
            return "Its URL is a \(scheme): address; Next Term reaches only https:// servers (and http:// on this Mac)."
        }
        guard let host = parts.host?.lowercased(), !host.isEmpty else { return "Its URL has no server name." }
        if host.contains(stand) { return "Its URL's server name can't come from a key." }
        if scheme == "http", !isThisMac(host) {
            return "Its URL is http:// to another machine, which would send what it is sent unencrypted; use https://."
        }
        if parts.user != nil || parts.password != nil {
            return "Its URL has a user name or password in it. Move it to Secrets, and send it in a header with ${secret:NAME}."
        }
        if SecretImport.withoutReferences(url) != nil {
            return "Its URL has a reference Next Term doesn't fill in; for a key, use ${secret:NAME}."
        }
        for item in parts.queryItems ?? [] {
            if let value = item.value?.replacingOccurrences(of: stand, with: ""), let kind = SecretImport.detect(name: item.name, value: value) {
                return "Its URL's \(item.name) looks like a key (\(kind)). " + moveToHeader
            }
        }
        for segment in parts.path.split(separator: "/").map(String.init) where !segment.contains(stand) {
            if let kind = SecretImport.tokenKind(segment) ?? (segment.count >= 20 && MCPRedaction.looksRandom(segment) ? "a key, by its shape" : nil) {
                return "Its URL has what looks like a key in its path (\(kind)). " + moveToHeader
            }
        }
        return nil
    }

    static func isThisMac(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" { return true }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// RFC 9110's token: letters, digits and `!#$%&'*+-.^_`|~`.
    static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || isLowerOrDigit(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    // MARK: ${secret:NAME}

    /// The keys a value names as `${secret:NAME}`, in order: what the app fills in for a remote server, and what an add
    /// request shows the user by name. A placeholder with no closing `}` names nothing.
    public static func secretNames(in text: String) -> [String] {
        withoutPlaceholders(text).names
    }

    /// `text` with each `${secret:NAME}` made `replacement` (`stand`, so a URL still parses; nothing, so what is left is
    /// what the file holds), and the names. An opening with no `}` after it is left as is.
    static func withoutPlaceholders(_ text: String, as replacement: String = stand) -> (text: String, names: [String]) {
        var out = "", names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "${secret:") {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            out += rest[..<open.lowerBound] + replacement
            names.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return (out + rest, names)
    }
}
