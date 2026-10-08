import Foundation

/// Secrets in command lines: whether a typed line may be saved, and masking anywhere in text, so a
/// secret line echoed after a prompt in scrollback is masked too. It adds the shapes secrets take on a
/// command line to MCPRedaction's (key formats, URL passwords, long random runs): secret-named
/// assignments, password flags, the few tools that take a password inline, auth headers, and sudo fed
/// on stdin. Git ids, UUIDs and paths stay, so `git checkout <sha>` and `cd <long path>` are kept.
public enum CommandSecrets {
    /// Whether `line` may be written to disk: no secret in it, and no leading space (the shells' way of
    /// keeping a line out of history).
    public static func mayKeep(_ line: String) -> Bool {
        if line.hasPrefix(" ") || line.hasPrefix("\t") { return false }
        return mask(line) == line
    }

    /// `text` with each secret replaced by •••, wherever it is in a line.
    public static func mask(_ text: String) -> String {
        var result = text
        for rule in rules {
            apply(rule, to: &result)
        }
        return MCPRedaction.redact(result, maskingRun: maskedRun).text
    }

    // MARK: rules

    /// A pattern, and how the value it found is masked. The value is the first group that took part.
    struct Rule {
        enum Masking { case whole, afterColon }
        let expression: NSRegularExpression
        let masking: Masking
    }

    static func rule(_ pattern: String, ignoringCase: Bool = false, masking: Rule.Masking = .whole) -> Rule {
        let options: NSRegularExpression.Options = ignoringCase ? [.caseInsensitive] : []
        return Rule(expression: try! NSRegularExpression(pattern: pattern, options: options), masking: masking)
    }

    /// One shell word: quoted parts (to the end of the line when a quote is left open), escapes and
    /// plain characters.
    static let word = #"(?:"(?:[^"\\\n]|\\.)*+"?+|'[^'\n]*+'?+|\\.|[^\s"'\\])++"#
    /// A word that is a value: not the next option, a pipe or a redirection.
    static let value = #"(?![-<>|;&])(\#(word))"#
    /// Not inside a longer name.
    static let start = #"(?<![A-Za-z0-9_.\-])"#
    static let secretWord = #"(?:password|passwd|passphrase|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credentials?)"#

    /// `DB_PASSWORD=…`, `PGPASSWORD=…`, `MYSQL_PWD=…`, `--token=…`, `-Ddb.password=…`, `?access_token=…`.
    /// The secret word ends the name or a part of it, so `TOKENIZERS_PARALLELISM` and `max_tokens` stay.
    static let assignment: Rule = {
        let named = #"[A-Za-z0-9_.\-]*?\#(secretWord)(?:[_.\-][A-Za-z0-9_.\-]*)?"#
        let suffixed = #"[A-Za-z0-9_.\-]*?[A-Za-z0-9](?:[_\-]pwd|[_\-]pass|_key)|sshpass|rediscli_auth"#
        return rule(#"\#(start)(?:\#(named)|\#(suffixed))=(\#(word))"#, ignoringCase: true)
    }()

    /// `--password x`, `--token x`, `--api-key x`, `--client-secret x`; not `--password-stdin`,
    /// `--token-file x` or `--no-password`.
    static let flag = rule(#"\#(start)--(?!no-)[A-Za-z0-9\-]*?\#(secretWord)(?:-key)?[ \t]+\#(value)"#, ignoringCase: true)

    /// The rest of a `tool` command on its line, up to where the same tool starts again, so a long row
    /// that names it many times is read once rather than once per name. (`curl.se` is not a start.)
    static func after(_ tool: String) -> String {
        #"(?:(?!\#(start)\#(tool)[ \t])[^\n])*?"#
    }

    static let mysqlClient = #"(?:mysql[a-z]*|mariadb(?:-[a-z]+)?)"#
    /// `mysql -pS3cret`: the MySQL and MariaDB clients take the password against -p (alone, -p asks).
    static let mysql = rule(#"\#(start)\#(mysqlClient)(?=[ \t])\#(after(mysqlClient))[ \t]-p(\#(word))"#)
    static let sshpass = rule(#"\#(start)sshpass(?=[ \t])\#(after("sshpass"))[ \t]-p[ \t]*\#(value)"#)
    static let redis = rule(#"\#(start)redis-cli(?=[ \t])\#(after("redis-cli"))[ \t](?:-a|--pass)(?:[ \t]+|=)\#(value)"#)
    static let registryLogin: Rule = {
        let login = #"(?:docker|podman|nerdctl)[ \t]+login"#
        return rule(#"\#(start)\#(login)(?=[ \t])\#(after(login))[ \t]-p(?:[ \t]+|=)?\#(value)"#)
    }()
    /// `curl -u user:pass`, `--user`, and the proxy's `-U`: after the colon (without one, curl asks).
    static let curlUser: Rule = {
        let user = #"[ \t](?:-u|--user|-U|--proxy-user)(?:[ \t]+|=)?(?=\S*:)"#
        return rule(#"\#(start)curl(?=[ \t])\#(after("curl"))\#(user)\#(value)"#, masking: .afterColon)
    }()
    /// `openssl … -passin pass:x`. The other forms (env:, file:, fd:) say where the password is.
    static let openssl = rule(#"\#(start)-pass(?:in|out|word)?[ \t]+pass:(\#(word))"#)

    static let sudoStdin = #"[ \t](?:-[A-Za-z]*S|--stdin)(?![^ \t\n])"#
    /// `echo pw | sudo -S …`: what is echoed (read up to the next echo, for the same reason as `after`).
    static let sudoEcho: Rule = {
        let echoed = #"((?:(?!\#(start)(?:echo|printf)[ \t])[^\n|])*?)"#
        return rule(#"\#(start)(?:echo|printf)[ \t]+\#(echoed)[ \t]*\|[ \t]*sudo(?=[ \t])\#(after("sudo"))\#(sudoStdin)"#)
    }()
    /// `sudo -S … <<< pw`. The first -S found is the one: the atomic group never goes back for another.
    static let sudoHereString = rule(#"\#(start)sudo(?=[ \t])(?>\#(after("sudo"))\#(sudoStdin))\#(after("sudo"))<<<[ \t]*(\#(word))"#)

    /// `git -c http.extraHeader=…`, `git config http.<url>.extraheader …`: the whole header.
    static let extraHeader = rule(#"\#(start)http\.(?:[^\s=]*\.)?extraheader(?:=|[ \t]+)\#(value)"#, ignoringCase: true)

    static let headerName = #"(?:(?:proxy-)?authorization|(?:set-)?cookie|(?:x-)?api-?key|x-auth-token|x-access-token|private-token)"#
    /// `Authorization: …`, `Cookie: …`, `X-Api-Key: …`: up to the quote it opened with, or the end of the line.
    static let header: Rule = {
        let doubleQuoted = #""\#(headerName)[ \t]*:[ \t]*([^\s"][^"\n]*)"#
        let singleQuoted = #"'\#(headerName)[ \t]*:[ \t]*([^\s'][^'\n]*)"#
        let bare = #"(?<![A-Za-z0-9\-])\#(headerName)[ \t]*:[ \t]*(\S[^\n]*)"#
        return rule(#"\#(doubleQuoted)|\#(singleQuoted)|\#(bare)"#, ignoringCase: true)
    }()

    /// In order: a git header before the generic header rule, which would otherwise mask inside it.
    static let rules: [Rule] = [
        assignment, flag, mysql, sshpass, redis, registryLogin, curlUser, openssl,
        sudoEcho, sudoHereString, extraHeader, header,
    ]

    static func apply(_ rule: Rule, to text: inout String) {
        _ = MCPRedaction.replace(rule.expression, in: &text) { (match: NSTextCheckingResult, ns: NSString) -> String? in
            let groups = 1..<match.numberOfRanges
            guard let group = groups.first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            let range = match.range(at: group)
            guard let masked = replacement(for: ns.substring(with: range), by: rule.masking) else { return nil }
            let whole = ns.substring(with: match.range) as NSString
            let inner = NSRange(location: range.location - match.range.location, length: range.length)
            return whole.replacingCharacters(in: inner, with: masked)
        }
    }

    /// What `value` becomes, or nil to leave it: masked already, empty quotes, or only a variable
    /// (`$TOKEN`, `"${TOKEN}"`: the shell fills it in, the line holds no secret).
    static func replacement(for value: String, by masking: Rule.Masking) -> String? {
        if value.contains(MCPRedaction.mask) { return nil }
        let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let variable = #"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$"#
        if bare.isEmpty || bare.range(of: variable, options: .regularExpression) != nil { return nil }
        let outer = closesOuterQuote(value) ? String(value.suffix(1)) : ""
        switch masking {
        case .whole:
            return MCPRedaction.mask + outer
        case .afterColon:
            guard let colon = value.firstIndex(of: ":") else { return nil }
            let opening: Character? = value.first
            let quoted = opening == "\"" || opening == "'"
            let ownPair = quoted && value.count > 1 && value.last == opening
            return String(value[...colon]) + MCPRedaction.mask + (ownPair ? String(value.suffix(1)) : outer)
        }
    }

    /// `value` ends with a quote it never opened: the end of a string it sits in, as the `'` after
    /// `token=abc` in `'https://h/?token=abc'`. It stays after the mask.
    static func closesOuterQuote(_ value: String) -> Bool {
        guard let last = value.last, last == "\"" || last == "'" else { return false }
        let quotes = value.filter { (character: Character) -> Bool in character == last }
        return quotes.count % 2 == 1
    }

    // MARK: long runs

    /// A long random-looking run is masked, unless it is a path (`/Users/x/Code/Project2024/Sources`):
    /// then only a name in it that is itself a long random run, as a key in a URL's path.
    static func maskedRun(_ run: String) -> String? {
        guard MCPRedaction.looksRandom(run) else { return nil }
        let names = run.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard names.filter(isWord).count >= 2 else { return MCPRedaction.mask }
        let kept = names.map { (name: String) -> String in
            name.count >= 24 && MCPRedaction.looksRandom(name) ? MCPRedaction.mask : name
        }
        let path = kept.joined(separator: "/")
        return path == run ? nil : path
    }

    /// A folder or file name made of words: `Users`, `Sources`, `node_modules`, `DerivedData`. A random
    /// key split at its slashes rarely has one such part, let alone two.
    static func isWord(_ name: String) -> Bool {
        name.range(of: #"^(?:[A-Z]?[a-z]{2,}+[_\-]?+)++$"#, options: .regularExpression) != nil
    }
}
