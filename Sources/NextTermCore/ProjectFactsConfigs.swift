import Foundation

// Ids, names and ports that tools' own config files name: Neon's project, Supabase's ref and local ports, Fly.io's
// app, Cloudflare's account and bindings, Firebase's project, Herd's and DDEV's sites, and the port literals of
// Vite, Astro, Nuxt and Mastra. Each is checked as plain text or a port before it is kept; a secret is never one of
// them.

extension ProjectFacts {
    mutating func readConfigs(_ reader: inout FactReader) {
        readJSONConfigs(&reader)
        readYAMLConfigs(&reader)
        readTOMLConfigs(&reader)
        readCodeConfigs(&reader)
        if let text = reader.text("supabase/.temp/project-ref") {
            let ref = text.split(whereSeparator: { (c: Character) -> Bool in c.isNewline }).first ?? ""
            addNamed(.supabaseRef, ref.trimmingCharacters(in: .whitespaces), file: "supabase/.temp/project-ref")
        }
    }

    /// Kept when it is plain text (`plainText`); a port fact only when it is a port.
    mutating func addNamed(_ fact: NamedFact, _ value: String?, file: String, label: String? = nil) {
        guard let value, let text = Self.plainText(value) else { return }
        let isPort = fact.rawValue.hasSuffix("port") || fact.rawValue.hasSuffix("Port")
        if isPort, ComposeFile.portNumber(Substring(text)) == nil { return }
        named.append(NamedValue(fact: fact, value: text, file: file, label: label.flatMap(Self.plainText)))
    }

    /// A JSON number or string as text: `4005` and `"4005"` both give "4005".
    static func scalarText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    mutating func readJSONConfigs(_ reader: inout FactReader) {
        if let json = reader.text(".neon").flatMap(Self.jsonObject) {
            addNamed(.neonProjectID, Self.scalarText(json["projectId"]), file: ".neon")
        }
        if let json = reader.text(".firebaserc").flatMap(Self.jsonObject) {
            let projects = json["projects"] as? [String: Any]
            addNamed(.firebaseProject, Self.scalarText(projects?["default"]), file: ".firebaserc")
        }
        if let json = reader.text("firebase.json").flatMap(Self.jsonObject),
           let emulators = json["emulators"] as? [String: Any] {
            addNamed(.firebaseEmulators, "true", file: "firebase.json")
            let ui = emulators["ui"] as? [String: Any]
            addNamed(.firebaseEmulatorUIPort, Self.scalarText(ui?["port"]), file: "firebase.json")
        }
        if let json = reader.text("inngest.json").flatMap(Self.jsonObject) {
            addNamed(.inngestPort, Self.scalarText(json["port"]), file: "inngest.json")
        }
        if let json = reader.text(".vercel/project.json").flatMap(Self.jsonObject) {
            let file = ".vercel/project.json"
            addNamed(.vercelProjectID, Self.scalarText(json["projectId"]), file: file)
            addNamed(.vercelOrgID, Self.scalarText(json["orgId"]), file: file)
            addNamed(.vercelProjectName, Self.scalarText(json["projectName"]), file: file)
        }
        readWrangler(&reader)
    }

    /// Wrangler's config, the first of its names that exists: the account, each D1 database and each storage bucket.
    mutating func readWrangler(_ reader: inout FactReader) {
        guard let file = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].first(where: { (name: String) -> Bool in
                  reader.isFile(name) }),
              let text = reader.text(file) else { return }
        var config: [String: Any] = [:]
        if file.hasSuffix(".toml") {
            guard case .success(let table) = TOMLReader.parse(text) else { return }
            config = Self.plainObject(.table(table)) as? [String: Any] ?? [:]
        } else {
            config = Self.jsonObject(Self.withoutJSONComments(text)) ?? [:]
        }
        addNamed(.wranglerAccountID, Self.scalarText(config["account_id"]), file: file)
        for database in config["d1_databases"] as? [[String: Any]] ?? [] {
            addNamed(.d1Database, Self.scalarText(database["database_id"]), file: file,
                     label: Self.scalarText(database["database_name"]))
        }
        for bucket in config["r2_buckets"] as? [[String: Any]] ?? [] {
            addNamed(.r2Bucket, Self.scalarText(bucket["bucket_name"]), file: file)
        }
    }

    /// A TOML value as JSONSerialization would give it, so one reader serves both forms.
    static func plainObject(_ value: TOMLValue) -> Any {
        switch value {
        case .string(let text), .datetime(let text): return text
        case .integer(let number): return NSNumber(value: number)
        case .float(let number): return NSNumber(value: number)
        case .bool(let flag): return flag
        case .array(let items): return items.map { (item: TOMLValue) -> Any in plainObject(item) }
        case .table(let table): return table.mapValues { (item: TOMLValue) -> Any in plainObject(item) }
        }
    }
}

// MARK: - YAML and TOML configs

extension ProjectFacts {
    mutating func readYAMLConfigs(_ reader: inout FactReader) {
        if let yaml = reader.text(".pscale.yml").map(Self.flatYAML) {
            addNamed(.pscaleOrg, yaml["org"], file: ".pscale.yml")
            addNamed(.pscaleDatabase, yaml["database"], file: ".pscale.yml")
        }
        if let yaml = reader.text("herd.yml").map(Self.flatYAML) {
            addNamed(.herdName, yaml["name"], file: "herd.yml")
            addNamed(.herdSecured, yaml["secured"].flatMap(Self.yamlFlag), file: "herd.yml")
        }
        if let yaml = reader.text(".ddev/config.yaml").map(Self.flatYAML) {
            let file = ".ddev/config.yaml"
            addNamed(.ddevName, yaml["name"], file: file)
            addNamed(.ddevTLD, yaml["project_tld"], file: file)
            addNamed(.ddevHTTPSPort, yaml["router_https_port"], file: file)
            addNamed(.ddevMailpitHTTPSPort, yaml["mailpit_https_port"], file: file)
        }
        for file in ["inngest.yaml", "inngest.yml"] where named(.inngestPort) == nil {
            guard let yaml = reader.text(file).map(Self.flatYAML) else { continue }
            addNamed(.inngestPort, yaml["port"], file: file)
        }
        if let image = reader.text("cog.yaml").map(Self.flatYAML)?["image"] {
            readReplicateImage(image)
        }
    }

    /// `CopilotSessions.flatYAML`, with each line's comment cut first (`name: shop # the site`); a `#` inside
    /// quotes stays the value's.
    static func flatYAML(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines).map { (line: String) -> String in
            String(ComposeFile.withoutComment(Substring(line)))
        }
        return CopilotSessions.flatYAML(lines.joined(separator: "\n"))
    }

    /// YAML's true and false, in the spellings Herd's file uses.
    static func yamlFlag(_ value: String) -> String? {
        switch value.lowercased() {
        case "true", "yes", "on": return "true"
        case "false", "no", "off": return "false"
        default: return nil
        }
    }

    /// Cog's `image: r8.im/<owner>/<model>`, the model on Replicate; a tag is cut.
    mutating func readReplicateImage(_ image: String) {
        let parts = image.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "r8.im" else { return }
        let model = parts[2].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let owner = String(parts[1])
        let name = String(model)
        guard SafeWebLink.Placeholder.replicateName.accepts(owner),
              SafeWebLink.Placeholder.replicateName.accepts(name) else { return }
        addNamed(.replicateOwner, owner, file: "cog.yaml")
        addNamed(.replicateModel, name, file: "cog.yaml")
    }

    mutating func readTOMLConfigs(_ reader: inout FactReader) {
        if let config = reader.text("supabase/config.toml").flatMap(Self.toml) {
            let file = "supabase/config.toml"
            addNamed(.supabaseDBPort, Self.tomlText(config["db", "port"]), file: file)
            addNamed(.supabaseStudioPort, Self.tomlText(config["studio", "port"]), file: file)
            addNamed(.supabaseInbucketPort, Self.tomlText(config["inbucket", "port"]), file: file)
        }
        if let config = reader.text("fly.toml").flatMap(Self.toml) {
            addNamed(.flyApp, Self.tomlText(config["app"]), file: "fly.toml")
        }
        if let config = reader.text(".streamlit/config.toml").flatMap(Self.toml) {
            addNamed(.streamlitPort, Self.tomlText(config["server", "port"]), file: ".streamlit/config.toml")
        }
    }

    static func toml(_ text: String) -> TOMLValue? {
        guard case .success(let table) = TOMLReader.parse(text) else { return nil }
        return .table(table)
    }

    /// A TOML string, or an integer as its digits.
    static func tomlText(_ value: TOMLValue?) -> String? {
        if let text = value?.string { return text }
        if case .integer(let number)? = value { return String(number) }
        return nil
    }
}

// MARK: - Config written as code

extension ProjectFacts {
    static let viteConfigs = ["ts", "js", "mjs", "mts", "cjs", "cts"].map { (ext: String) -> String in "vite.config." + ext }
    static let astroConfigs = ["mjs", "ts", "js", "mts", "cjs"].map { (ext: String) -> String in "astro.config." + ext }
    static let nuxtConfigs = ["ts", "js", "mjs"].map { (ext: String) -> String in "nuxt.config." + ext }

    /// Port literals in Vite's, Astro's, Nuxt's and Mastra's configs, and Trigger.dev's project ref. The code is
    /// matched by narrow patterns, never run: an expression gives nothing.
    mutating func readCodeConfigs(_ reader: inout FactReader) {
        if let file = Self.viteConfigs.first(where: { (name: String) -> Bool in reader.isFile(name) }),
           let text = reader.text(file) {
            addNamed(.vitePort, Self.portLiteral(in: text, block: "server").map(String.init), file: file)
            if Self.setsHTTPS(in: text) { addNamed(.viteHTTPS, "true", file: file) }
        }
        if let file = Self.astroConfigs.first(where: { (name: String) -> Bool in reader.isFile(name) }),
           let text = reader.text(file) {
            addNamed(.astroPort, Self.portLiteral(in: text, block: "server").map(String.init), file: file)
        }
        if let file = Self.nuxtConfigs.first(where: { (name: String) -> Bool in reader.isFile(name) }),
           let text = reader.text(file) {
            addNamed(.nuxtPort, Self.portLiteral(in: text, block: "devServer").map(String.init), file: file)
        }
        if let text = reader.text("src/mastra/index.ts") {
            addNamed(.mastraPort, Self.portLiteral(in: text, block: "server").map(String.init), file: "src/mastra/index.ts")
        }
        if let text = reader.text("trigger.config.ts") {
            addNamed(.triggerProjectRef, Self.stringLiteral(in: text, key: "project"), file: "trigger.config.ts")
        }
    }

    /// The number written for `port` directly in `block: { … }` (`server: { port: 5174 }`), outside comments and
    /// strings and not inside a nested block (`server.hmr.port` is not the server's). Nil for an expression.
    static func portLiteral(in source: String, block: String) -> Int? {
        let code = codeSkeleton(Array(source))
        guard let body = blockBody(code, named: block) else { return nil }
        let top = topLevel(body)
        guard let value = valueStart(top, key: "port") else { return nil }
        let digits = top[value...].prefix { (c: Character) -> Bool in c >= "0" && c <= "9" }
        let rest = top[(value + digits.count)...].drop { (c: Character) -> Bool in c == " " || c == "\t" }
        let ends: Bool = rest.isEmpty || rest.first == "," || rest.first == "\n" || rest.first == "\r"
        guard ends else { return nil }
        return ComposeFile.portNumber(Substring(String(digits)))
    }

    /// Whether Vite's `server` block sets `https` to `true` or an object.
    static func setsHTTPS(in source: String) -> Bool {
        let code = codeSkeleton(Array(source))
        guard let body = blockBody(code, named: "server") else { return false }
        let top = topLevel(body)
        guard let value = valueStart(top, key: "https") else { return false }
        let rest = String(top[value...].prefix(4))
        return rest == "true" || rest.hasPrefix("{")
    }

    /// The text of a string literal written for `key` (`project: "proj_…"`), outside comments; nil when it is not
    /// a plain literal.
    static func stringLiteral(in source: String, key: String) -> String? {
        let raw = Array(source)
        let code = codeSkeleton(raw)
        guard let value = valueStart(code, key: key), value < raw.count,
              raw[value] == "\"" || raw[value] == "'" || raw[value] == "`" else { return nil }
        let quote = raw[value]
        guard let close = raw[(value + 1)...].firstIndex(of: quote) else { return nil }
        return String(raw[(value + 1)..<close])
    }
}

// MARK: - Scanning code

extension ProjectFacts {
    /// The source with comments and the text of string literals blanked to spaces (quotes and line breaks kept), so
    /// a pattern finds only code, at the same offsets as in the source.
    static func codeSkeleton(_ source: [Character]) -> [Character] {
        var out = source
        var index = 0
        func blank(_ at: Int) { if !source[at].isNewline { out[at] = " " } }
        while index < source.count {
            let c = source[index]
            let next: Character? = index + 1 < source.count ? source[index + 1] : nil
            if c == "/", next == "/" {
                while index < source.count, !source[index].isNewline { blank(index); index += 1 }
            } else if c == "/", next == "*" {
                blank(index)
                blank(index + 1)
                index += 2
                while index < source.count {
                    let closes: Bool = source[index] == "*" && index + 1 < source.count && source[index + 1] == "/"
                    blank(index)
                    if closes { blank(index + 1) }
                    index += closes ? 2 : 1
                    if closes { break }
                }
            } else if c == "\"" || c == "'" || c == "`" {
                index += 1
                while index < source.count, source[index] != c {
                    if source[index] == "\\", index + 1 < source.count { blank(index); index += 1 }
                    blank(index)
                    index += 1
                }
                index += 1
            } else {
                index += 1
            }
        }
        return out
    }

    /// Where the value written for `key:` starts, for `key` as a whole word; the first such place.
    static func valueStart(_ code: [Character], key: String) -> Int? {
        valueStarts(code, key: key).first
    }

    static func valueStarts(_ code: [Character], key: String) -> [Int] {
        let word = Array(key)
        guard !word.isEmpty, code.count > word.count else { return [] }
        var found: [Int] = []
        for start in 0...(code.count - word.count) where code[start] == word[0] {
            let before: Character? = start > 0 ? code[start - 1] : nil
            let joined: Bool = before.map { (c: Character) -> Bool in isIdentifier(c) || c == "." } ?? false
            guard !joined, Array(code[start..<(start + word.count)]) == word else { continue }
            var index = start + word.count
            while index < code.count, code[index] == " " || code[index] == "\t" { index += 1 }
            guard index < code.count, code[index] == ":" else { continue }
            index += 1
            while index < code.count, code[index].isWhitespace { index += 1 }
            if index < code.count { found.append(index) }
        }
        return found
    }

    static func isIdentifier(_ c: Character) -> Bool {
        c == "_" || c == "$" || (c.isASCII && (c.isLetter || c.isNumber))
    }

    /// What is between the braces of `name: { … }`, for the first `name` written with a block.
    static func blockBody(_ code: [Character], named name: String) -> [Character]? {
        for start in valueStarts(code, key: name) where code[start] == "{" {
            var depth = 0
            for index in start..<code.count {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1 }
                if depth == 0 { return Array(code[(start + 1)..<index]) }
            }
            return nil
        }
        return nil
    }

    /// The block's own level: what nested brackets hold is blanked, the brackets that open them kept.
    static func topLevel(_ body: [Character]) -> [Character] {
        var out = body
        var depth = 0
        for index in body.indices {
            let c = body[index]
            let opens: Bool = c == "{" || c == "[" || c == "("
            let closes: Bool = c == "}" || c == "]" || c == ")"
            if closes { depth -= 1 }
            if depth > 0, !c.isNewline { out[index] = " " }
            if opens { depth += 1 }
        }
        return out
    }

    /// JSON with comments (`wrangler.jsonc`) as plain JSON: comments and trailing commas removed, strings kept.
    static func withoutJSONComments(_ text: String) -> String {
        let source = Array(text)
        var out: [Character] = []
        var index = 0
        var inString = false
        while index < source.count {
            let c = source[index]
            let next: Character? = index + 1 < source.count ? source[index + 1] : nil
            if inString {
                out.append(c)
                if c == "\\", let next { out.append(next); index += 1 } else if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "/", next == "/" {
                while index < source.count, !source[index].isNewline { index += 1 }
                continue
            }
            if c == "/", next == "*" {
                index += 2
                while index < source.count {
                    if source[index] == "*", index + 1 < source.count, source[index + 1] == "/" { break }
                    index += 1
                }
                index += 2
                continue
            }
            if c == "," {
                let following = source[(index + 1)...].first { (c: Character) -> Bool in !c.isWhitespace }
                if following == "}" || following == "]" { index += 1; continue }
            }
            if c == "\"" { inString = true }
            out.append(c)
            index += 1
        }
        return String(out)
    }
}
