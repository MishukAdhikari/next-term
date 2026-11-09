import Foundation

/// One server in the MCP hub's list (MCPHubFile), as Next Term uses it: a local server it starts (`stdio`), or a remote
/// one at a URL (`http`, or the older `sse`). Read from an entry (`decode`) and put back into one (`merged`), changing
/// only the keys whose meaning changed, so every other key of the entry stays as written.
public struct MCPHubServer: Equatable, Sendable {
    public enum Transport: String, Sendable, CaseIterable {
        case stdio, http, sse
    }

    /// The projects a server in the user's list applies to. A project's own list applies to that project only.
    public enum Projects: Equatable, Sendable {
        case all
        /// Folders, each a full path or one starting with `~/`: the server applies in each and every folder inside it.
        case only([String])
    }

    public var name: String
    public var transport: Transport
    /// What a local server runs, and its arguments and environment. Empty for a remote server.
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// Where a remote server is, and the headers sent with each request. Empty for a local server.
    public var url: String
    public var headers: [String: String]
    /// Off: listed, never used.
    public var enabled: Bool
    public var projects: Projects
    /// The user's own OAuth app for a server at a URL that can't register Next Term (GitHub's): `nextTerm.oauth`.
    public var oauth: OAuthApp?

    /// The user's own OAuth app, as the entry keeps it: `"nextTerm": {"oauth": {"clientID": "Ov23li…", "clientSecret":
    /// "${secret:GITHUB_OAUTH_CLIENT_SECRET}", "issuer": "https://github.com/login/oauth"}}`. The client ID isn't a
    /// secret; the secret is a key in Secrets, named here, never written here; the issuer is the authorization server
    /// the app was made at, once Next Term has seen it, so the secret is never sent to another.
    public struct OAuthApp: Equatable, Sendable {
        public var clientID: String
        /// The key in Secrets that holds the app's client secret; nil for an app with none (a public client).
        public var secretName: String?
        public var issuer: String?

        public init(clientID: String, secretName: String? = nil, issuer: String? = nil) {
            self.clientID = clientID
            self.secretName = secretName
            self.issuer = issuer
        }

        /// As the entry keeps it.
        var value: MCPHubFile.Value {
            var members = [MCPHubFile.Member("clientID", .string(clientID))]
            if let secretName { members.append(MCPHubFile.Member("clientSecret", .string("${secret:\(secretName)}"))) }
            if let issuer { members.append(MCPHubFile.Member("issuer", .string(issuer))) }
            return .object(members)
        }

        /// The app an entry's `nextTerm.oauth` describes, or why not, each reason a sentence.
        static func decode(_ value: MCPHubFile.Value, _ reasons: inout [String]) -> OAuthApp? {
            guard value.members != nil else { reasons.append("Its nextTerm.oauth is not an object."); return nil }
            let before = reasons.count
            let id = value.member("clientID")?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            if id.isEmpty || id.count > 256 || id.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) {
                reasons.append("Its nextTerm.oauth.clientID is not a client ID: one word of text, as the provider shows it.")
            }
            var secret: String?
            if let found = value.member("clientSecret") {
                let text = found.string ?? ""
                let names = MCPHubRules.secretNames(in: text)
                if names.count == 1, text == "${secret:\(names[0])}", StoredSecretName.isValid(names[0]) {
                    secret = names[0]
                } else if found.string == nil || text.contains("${secret:") {
                    reasons.append(MCPHubRules.badPlaceholder("Its nextTerm.oauth.clientSecret"))
                } else {
                    reasons.append("Its nextTerm.oauth.clientSecret is the secret itself. Move it to Secrets, and use ${secret:NAME} in its place.")
                }
            }
            var issuer: String?
            if let found = value.member("issuer") {
                if let text = found.string, let url = URL(string: text), let host = url.host, !host.isEmpty, url.user == nil,
                   url.scheme == "https" || (url.scheme == "http" && MCPHubRules.isThisMac(host)) {
                    issuer = text
                } else {
                    reasons.append("Its nextTerm.oauth.issuer is not an https address.")
                }
            }
            return reasons.count == before ? OAuthApp(clientID: id, secretName: secret, issuer: issuer) : nil
        }
    }

    public init(name: String, transport: Transport, command: String = "", args: [String] = [], env: [String: String] = [:],
                url: String = "", headers: [String: String] = [:], enabled: Bool = true, projects: Projects = .all,
                oauth: OAuthApp? = nil) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.projects = projects
        self.oauth = oauth
    }

    /// A local server: a command Next Term starts for each agent session.
    public static func local(_ name: String, command: String, args: [String] = [], env: [String: String] = [:],
                             projects: Projects = .all) -> MCPHubServer {
        MCPHubServer(name: name, transport: .stdio, command: command, args: args, env: env, projects: projects)
    }

    /// A remote server at a URL.
    public static func remote(_ name: String, url: String, headers: [String: String] = [:], projects: Projects = .all) -> MCPHubServer {
        MCPHubServer(name: name, transport: .http, url: url, headers: headers, projects: projects)
    }

    // MARK: reading

    /// The server an entry describes, or why it can't be used, in plain words. A key with the wrong kind of value is a
    /// reason; a key Next Term doesn't know is not (it stays in the file). `type` may be left out: a `command` makes it
    /// `stdio`, a `url` `http`. In a project's file, `nextTerm.projects` means nothing and is passed over.
    public static func decode(name: String, _ value: MCPHubFile.Value, place: MCPHubFile.Place) -> Result<MCPHubServer, Broken> {
        guard let members = value.members else { return .failure(Broken(reasons: ["It is not a JSON object."])) }
        var reasons: [String] = []
        var seen = Set<String>()
        for member in members where !seen.insert(member.key).inserted { reasons.append("It has \(member.key) twice.") }
        guard reasons.isEmpty else { return .failure(Broken(reasons: reasons)) }

        func text(_ key: String) -> String? {
            guard let found = value.member(key) else { return nil }
            guard let text = found.string else { reasons.append("Its \(key) is not text."); return nil }
            return text
        }
        let command = text("command"), url = text("url"), type = text("type")
        let args = value.member("args").map { strings($0, "args", &reasons) } ?? []
        let env = value.member("env").map { table($0, "env", &reasons) } ?? [:]
        let headers = value.member("headers").map { table($0, "headers", &reasons) } ?? [:]

        var enabled = true, projects = Projects.all, oauth: OAuthApp?
        if let own = value.member("nextTerm") {
            var keys = Set<String>()
            if own.members == nil {
                reasons.append("Its nextTerm is not an object.")
            } else if let twice = own.members?.first(where: { !keys.insert($0.key).inserted }) {
                reasons.append("Its nextTerm has \(twice.key) twice.")
            } else {
                if let flag = own.member("enabled") {
                    if case .bool(let on) = flag { enabled = on } else { reasons.append("Its nextTerm.enabled is not true or false.") }
                }
                if place == .user, let scope = own.member("projects") {
                    if scope.string == "all" {
                        projects = .all
                    } else if case .array = scope {
                        projects = .only(strings(scope, "nextTerm.projects", &reasons))
                    } else {
                        reasons.append("Its nextTerm.projects is neither \"all\" nor a list of folders.")
                    }
                }
                if let app = own.member("oauth") { oauth = OAuthApp.decode(app, &reasons) }
            }
        }

        // By the keys there, so a command that is not text is said once.
        let hasCommand = value.member("command") != nil, hasURL = value.member("url") != nil
        var transport: Transport?
        if let type {
            transport = Transport(rawValue: type)
            if transport == nil { reasons.append("Its type is \(type); Next Term runs stdio, http and sse servers.") }
        } else if hasCommand, hasURL {
            reasons.append("It has both a command and a url; give it a type, or keep one.")
        } else if hasCommand {
            transport = .stdio
        } else if hasURL {
            transport = .http
        } else if value.member("type") == nil {
            reasons.append("It has no command to run and no url to reach.")
        }
        if transport == .stdio, !hasCommand { reasons.append("Its type is stdio, and it has no command.") }
        if transport == .stdio, oauth != nil { reasons.append("Its nextTerm.oauth is for a server at a URL; a command signs in by itself.") }
        if let transport, transport != .stdio, !hasURL { reasons.append("Its type is \(transport.rawValue), and it has no url.") }
        guard reasons.isEmpty, let transport else { return .failure(Broken(reasons: reasons)) }

        let server = MCPHubServer(name: name, transport: transport, command: transport == .stdio ? command ?? "" : "",
                                  args: transport == .stdio ? args : [], env: transport == .stdio ? env : [:],
                                  url: transport == .stdio ? "" : url ?? "", headers: transport == .stdio ? [:] : headers,
                                  enabled: enabled, projects: projects, oauth: transport == .stdio ? nil : oauth)
        let broken = MCPHubRules.reasons(server, place: place)
        return broken.isEmpty ? .success(server) : .failure(Broken(reasons: broken))
    }

    /// Why an entry can't be used: each reason a sentence.
    public struct Broken: Error, Equatable, Sendable {
        public let reasons: [String]
    }

    static func strings(_ value: MCPHubFile.Value, _ key: String, _ reasons: inout [String]) -> [String] {
        guard case .array(let items) = value else { reasons.append("Its \(key) is not a list."); return [] }
        let texts = items.compactMap(\.string)
        if texts.count != items.count { reasons.append("Its \(key) has something other than text in it.") }
        return texts
    }

    static func table(_ value: MCPHubFile.Value, _ key: String, _ reasons: inout [String]) -> [String: String] {
        guard let members = value.members else { reasons.append("Its \(key) is not an object."); return [:] }
        var out: [String: String] = [:]
        for member in members {
            guard let text = member.value.string else { reasons.append("Its \(key).\(member.key) is not text."); continue }
            guard out.updateValue(text, forKey: member.key) == nil else { reasons.append("Its \(key) has \(member.key) twice."); continue }
        }
        return out
    }

    // MARK: writing

    /// The entry with this server put in, from the entry as read (`old`; an empty object for a new one). A key keeps
    /// its text when its meaning is the same; one that changed is replaced where it was; one this server has no use
    /// for (`url` on a local server) is removed; every other key stays. `type` is written for a remote server, and for a
    /// local one only when the entry had one. `nextTerm` gets `enabled`, and in the user's list `projects`.
    func merged(into old: MCPHubFile.Value, place: MCPHubFile.Place) -> MCPHubFile.Value {
        var members = old.members ?? []
        let local = transport == .stdio
        let hadType = members.contains { $0.key == "type" }
        Self.put("type", local && !hadType ? nil : .string(transport.rawValue), in: &members) { $0.string == transport.rawValue }
        Self.put("command", local ? .string(command) : nil, in: &members) { local && $0.string == command }
        Self.put("args", local && !args.isEmpty ? .array(args.map { .string($0) }) : nil, in: &members) {
            local && Self.decoded($0, Self.strings) == args
        }
        Self.put("env", local && !env.isEmpty ? Self.object(env) : nil, in: &members) { local && Self.decoded($0, Self.table) == env }
        Self.put("url", local ? nil : .string(url), in: &members) { !local && $0.string == url }
        Self.put("headers", !local && !headers.isEmpty ? Self.object(headers) : nil, in: &members) {
            !local && Self.decoded($0, Self.table) == headers
        }
        var own = members.first { $0.key == "nextTerm" }?.value.members ?? []
        Self.put("enabled", .bool(enabled), in: &own) { $0 == .bool(enabled) }
        if place == .user {
            let scope: MCPHubFile.Value
            switch projects {
            case .all: scope = .string("all")
            case .only(let folders): scope = .array(folders.map { .string($0) })
            }
            Self.put("projects", scope, in: &own) { $0 == scope }
        }
        let app = local ? nil : oauth?.value
        Self.put("oauth", app, in: &own) { $0 == app }
        Self.put("nextTerm", .object(own), in: &members) { $0 == .object(own) }
        return .object(members)
    }

    /// Puts `value` at `key` (nil: removes it). Kept as written when there is one copy and `same` says it means this
    /// (`"args": []` on a server with none).
    static func put(_ key: String, _ value: MCPHubFile.Value?, in members: inout [MCPHubFile.Member],
                    same: (MCPHubFile.Value) -> Bool) {
        let copies = members.indices.filter { members[$0].key == key }
        if copies.count == 1, same(members[copies[0]].value) { return }
        guard let value else { members.removeAll { $0.key == key }; return }
        guard let first = copies.first else { members.append(MCPHubFile.Member(key, value)); return }
        members[first].value = value
        members = members.enumerated().filter { $0.offset == first || $0.element.key != key }.map(\.element)
    }

    static func decoded<T>(_ value: MCPHubFile.Value, _ read: (MCPHubFile.Value, String, inout [String]) -> T) -> T? {
        var reasons: [String] = []
        let result = read(value, "", &reasons)
        return reasons.isEmpty ? result : nil
    }

    static func object(_ table: [String: String]) -> MCPHubFile.Value {
        .object(table.keys.sorted().map { MCPHubFile.Member($0, .string(table[$0] ?? "")) })
    }
}
