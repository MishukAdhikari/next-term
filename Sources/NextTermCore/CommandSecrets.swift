import Foundation

/// Secrets in command lines: whether a typed line may be saved, and masking anywhere in text, so a
/// secret line echoed after a prompt in scrollback is masked too. It adds the shapes secrets take on a
/// command line to MCPRedaction's (key formats, URL passwords, long random runs): secret-named
/// assignments, password flags, the tools that take a password or token inline, auth headers, and
/// passwords fed on stdin. Git ids, UUIDs, paths and branch names stay, so `git checkout <sha>` and
/// `cd <long path>` are kept. Each pattern reads a row in one pass, so a crafted row costs its length.
public enum CommandSecrets {
    /// Whether `line` may be written to disk: no secret in it, no leading space (the shells' way of
    /// keeping a line out of history), and no line break, as a line that goes on to another is never put
    /// back the way it was typed.
    public static func mayKeep(_ line: String) -> Bool {
        if line.hasPrefix(" ") || line.hasPrefix("\t") { return false }
        if line.unicodeScalars.contains(where: { (scalar: Unicode.Scalar) -> Bool in scalar == "\n" || scalar == "\r" }) {
            return false
        }
        return mask(line) == line
    }

    /// `text` with each secret replaced by •••, wherever it is in a line. A command continued with a
    /// backslash is read across its lines; scrollback rows a shell continued (its PS2 prompt) are best
    /// joined before they are masked, as a continuation row alone has no tool name to go by.
    public static func mask(_ text: String) -> String {
        mask(text, reading: masked)
    }

    /// As `mask(_:)`, with `read` masking a text, or giving nil when ICU gave up partway (on a run of a
    /// few hundred thousand characters), so would miss what follows. The text is then read line by line
    /// (a command continued with a backslash is one), and each line of one it gives up on is masked whole.
    static func mask(_ text: String, reading read: (String) -> String?) -> String {
        if let masked = read(text) { return masked }
        let lines = logicalLines(text)
        let whole = { (line: String) -> String in
            line.components(separatedBy: "\n").map { (_: String) -> String in MCPRedaction.mask }.joined(separator: "\n")
        }
        guard lines.count > 1 else { return whole(text) }
        return lines.map { (line: String) -> String in read(line) ?? whole(line) }.joined(separator: "\n")
    }

    /// `text` masked, or nil if ICU gave up partway through it.
    static func masked(_ text: String) -> String? {
        var result = text
        var complete = true
        for rule in rules {
            apply(rule, to: &result, complete: &complete)
            if !complete { return nil }
        }
        let redacted = MCPRedaction.redact(result, maskingRun: maskedRun)
        return redacted.complete ? redacted.text : nil
    }

    /// The lines of `text`, with a line that ends in a backslash joined to the next.
    static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var continued: String? = nil
        for line in text.components(separatedBy: "\n") {
            let joined = continued.map { (start: String) -> String in start + "\n" + line } ?? line
            let goesOn = line.hasSuffix("\\") || line.hasSuffix("\\\r")
            if goesOn { continued = joined } else { lines.append(joined); continued = nil }
        }
        if let continued { lines.append(continued) }
        return lines
    }

    // MARK: rules

    /// A pattern, how the value it found is masked, and whether that value is a secret. The value is the
    /// last group that took part; when two did, the first is the name it is given to (`DB_PASSWORD`).
    struct Rule {
        enum Masking {
            /// A shell word.
            case whole
            /// A shell word `user:password`: after the colon (without one, curl asks).
            case afterColon
            /// A header's value (`Bearer abc`), inside the quote the match opens with, if any.
            case header
            /// A shell word that is a whole header (`"Authorization: Bearer abc"`).
            case headerWord
        }
        let expression: NSRegularExpression
        let masking: Masking
        let isSecret: (_ name: String, _ value: String) -> Bool
    }

    static func rule(_ pattern: String, ignoringCase: Bool = false, masking: Rule.Masking = .whole,
                     isSecret: @escaping (String, String) -> Bool = { (_: String, _: String) -> Bool in true }) -> Rule {
        Rule(expression: regex(pattern, ignoringCase: ignoringCase), masking: masking, isSecret: isSecret)
    }

    static func regex(_ pattern: String, ignoringCase: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : [])
    }

    /// Blanks between words: spaces, tabs, and a backslash that goes on to the next line.
    static let gap = #"(?:[ \t]|\\\r?\n)"#
    /// One shell word: plain characters, quoted parts and escapes, up to a `|`, `;`, `&`, `<` or `>`. A
    /// quote no later one closes opens a value to the end of the line, unless a blank or the end comes
    /// next: then it closes a string the word sits in (`grep "api_key=" src`), and the word ends before it.
    /// Plain characters are taken a run at a time: ICU keeps a frame for each turn of the loop and gives
    /// up on the whole row past a few hundred thousand.
    static let word = #"(?:[^\s"'\\|;&<>]++|"(?:[^"\\\n]++|\\.)*+"|"(?=\S)(?:[^"\\\n]++|\\.)*+|'[^'\n]*+'|'(?=\S)[^'\n]*+|\\.)++"#
    /// A word that is a value: not the next option, a pipe or a redirection.
    static let value = #"(?![-<>|;&])(\#(word))"#
    /// Not inside a longer name.
    static let start = #"(?<![A-Za-z0-9_.\-])"#

    /// A quoted string, an escape, or one character of a command, which is read in these, so a `|` or a
    /// `-p` in quotes is not taken for one outside. It ends at a `|`, `;` or `&`.
    static let piece = #"(?>"(?:[^"\\\n]++|\\.)*+"|'[^'\n]*+'|\\\r?\n|\\.|[^\n|;&])"#
    /// The rest of a command.
    static let rest = #"\#(piece)*?"#
    /// The rest of a `tool` command, also up to where the same tool starts again, so a long row that
    /// names it many times is read once rather than once per name. (`curl.se` is not a start.)
    static func after(_ tool: String) -> String {
        #"(?:(?!\#(start)\#(tool)\#(gap))\#(piece))*?"#
    }
    /// `option` (holding the value's group) anywhere in a `tool` command.
    static func tool(_ name: String, _ option: String, masking: Rule.Masking = .whole,
                     isSecret: @escaping (String, String) -> Bool = { (_: String, _: String) -> Bool in true }) -> Rule {
        rule(#"\#(start)\#(name)(?=\#(gap))\#(after(name))\#(gap)\#(option)"#, masking: masking, isSecret: isSecret)
    }

    static let secretWord = #"(?:password|passwd|passphrase|secret|token|credentials?|(?:api|access|private|auth|signing|encryption|master)[_\-]?key)"#

    /// `DB_PASSWORD=…`, `PGPASSWORD=…`, `MYSQL_PWD=…`, `--token=…`, `-Ddb.password=…`, `?access_token=…`.
    /// Only a name with a secret part is matched, so the value of another (`msg` in `msg="set token=abc"`)
    /// is still looked into. The secret word ends the name or a part of it, so `TOKENIZERS_PARALLELISM`
    /// and `max_tokens` stay; `isSecretAssignment` has the last word. Each name is read from where it
    /// starts, at most 256 long.
    static let assignment: Rule = {
        let part = #"(?:\#(secretWord)(?:key)?(?![a-z])|[_\-](?:pwd|pw|pass|key)(?![a-z0-9_.\-])|(?:sshpass|rediscli_auth)(?![a-z0-9_.\-]))"#
        let named = #"(?=[A-Za-z0-9_.\-]{0,255}?\#(part))"#
        return rule(#"\#(start)\#(named)([A-Za-z0-9_.\-]{1,256}+)=(\#(word))"#, ignoringCase: true, isSecret: isSecretAssignment)
    }()

    /// `--password x`, `--token x`, `--api-key x`, `--client-secret x`, `--secret-key x`, `--oauth2-bearer
    /// x`: the name ends with a secret word, so not `--password-stdin` or `--token-file` (`isSecretFlag`).
    static let flag: Rule = {
        let named = #"(?=--[A-Za-z0-9\-]{0,255}?(?:\#(secretWord)|bearer)(?:-key)?(?![A-Za-z0-9\-]))"#
        return rule(#"\#(start)\#(named)(--[A-Za-z0-9\-]{1,256}+)\#(gap)++\#(value)"#, ignoringCase: true, isSecret: isSecretFlag)
    }()

    static let mysqlClient = #"(?:mysql[a-z]*|mariadb(?:-[a-z]+)?)"#
    /// `mysql -pS3cret`: the MySQL and MariaDB clients take the password against -p (alone, -p asks).
    static let mysql = tool(mysqlClient, #"-p(\#(word))"#)
    /// `sshpass -p pw ssh h`: the -p among sshpass's own options, before the command it runs (`sshpass -e
    /// ssh -p 2222 h` gives ssh its port).
    static let sshpass: Rule = {
        let option = #"(?:-[fdP]\#(gap)*+(?!-)\#(word)|-(?!p)\S++)"#
        return rule(#"\#(start)sshpass(?>(?:\#(gap)++\#(option))*+)\#(gap)++-p\#(gap)*+\#(value)"#)
    }()
    static let redis = tool("redis-cli", #"(?:-a|--pass)(?:\#(gap)++|=)\#(value)"#)
    static let registryLogin = tool(#"(?:docker|podman|nerdctl)\#(gap)++login"#, #"-p(?:\#(gap)++|=)?+\#(value)"#)
    /// `curl -u user:pass`, `--user`, and the proxy's `-U`: after the colon.
    static let curlUser = tool("curl", #"(?:-u|--user|-U|--proxy-user)(?:\#(gap)++|=)?+(?=\S*:)\#(value)"#, masking: .afterColon)
    /// `curl -b "sid=abc"`: cookies (without an =, -b names a file to read them from).
    static let curlCookie = tool("curl", #"(?:-b|--cookie)(?:\#(gap)++|=)?+\#(value)"#) { (_: String, cookies: String) -> Bool in
        cookies.contains("=")
    }
    /// `openssl … -passin pass:x`. The other forms (env:, file:, fd:) say where the password is.
    static let opensslPass = rule(#"\#(start)-pass(?:in|out|word)?\#(gap)++pass:(\#(word))"#)
    static let opensslKey = tool("openssl", #"-k\#(gap)++\#(value)"#)
    static let mongo = tool(#"mongo(?:sh|dump|restore|export|import|stat|top|files)?"#, #"-p(?:\#(gap)++|=)?+\#(value)"#)
    static let zip = tool(#"(?:zip|unzip)"#, #"-P\#(gap)++\#(value)"#)
    static let sevenZip = tool(#"7z[az]?"#, #"-p(\#(word))"#)
    /// macOS's keychain: `security add-generic-password … -w pw` (a -w at the end asks).
    static let keychain = tool(#"security\#(gap)++add-(?:generic|internet)-password"#, #"-w\#(gap)++\#(value)"#)
    static let ghSecret = tool(#"gh\#(gap)++secret\#(gap)++set"#, #"(?:--body(?:\#(gap)++|=)|-b\#(gap)*+)\#(value)"#)

    /// `vault login s.abc`: the first word after vault's options, unless it is a `key=value` of a login
    /// method (`vault login -method=userpass username=me` asks for the password).
    static let vault: Rule = {
        let takesValue = #"-{1,2}(?:method|path|address|agent-address|ca-cert|ca-path|client-cert|client-key|mfa|namespace|ns|tls-server-name|wrap-ttl|header|field|format)"#
        let option = #"(?>\#(takesValue)\#(gap)++\#(word)|-\S*+)"#
        let token = #"(?![-<>|;&])(?![^\s=]*+=)(\#(word))"#
        return rule(#"\#(start)vault\#(gap)++login(?>(?:\#(gap)++\#(option))*+)\#(gap)++\#(token)"#)
    }()

    /// `htpasswd -b file user pw`, `-nb user pw`: with b among its options, the password is the last word.
    static let htpasswd: Rule = {
        let batch = #"(?=\#(after("htpasswd"))\#(gap)-[A-Za-z]*b[A-Za-z]*(?!\S))"#
        let last = #"(?=\#(gap)*+(?:[\n|;&]|\d*[<>]|\z))"#
        return rule(#"\#(start)htpasswd(?=\#(gap))\#(batch)\#(after("htpasswd"))\#(gap)\#(value)\#(last)"#)
    }()

    /// `redis://:pw@h`, `https://me:p@ss@h`: a URL's password, with or without a user before it. The host
    /// follows the last @.
    static let scheme = #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*+://"#
    static let urlPassword = rule(#"\#(scheme)[^\s:/@]*+:([^\s/?#]+)@"#)
    /// `https://glpat-…@gitlab.com/o/r`: a token given as the user, which has digits in it as a name
    /// rarely does.
    static let urlToken = rule(#"\#(scheme)([^\s:/@?#]{16,}+)@"#) { (_: String, user: String) -> Bool in
        user.filter(\.isNumber).count >= 3 && user.filter(\.isLetter).count >= 3
    }

    static let sudoStdin = #"[ \t](?:-[A-Za-z]*S|--stdin)(?![^ \t\n])"#
    /// Options that read the password or token from stdin.
    static let stdinOption = #"--(?:password-stdin|with-token)"#
    static let stdinFlag = #"\#(stdinOption)(?![^\s])"#
    /// `echo pw | sudo -S …`, `echo pw | docker login --password-stdin`: what is echoed (read up to the
    /// next echo, for the same reason as `after`).
    static let echoed: Rule = {
        let echo = #"(?:echo|printf)"#
        let text = #"((?:(?!\#(start)\#(echo)\#(gap))\#(piece))*?)"#
        let sudo = #"sudo(?=\#(gap))\#(after("sudo"))\#(sudoStdin)"#
        let reader = #"\#(rest)\#(gap)\#(stdinFlag)"#
        let pattern = #"\#(start)\#(echo)\#(gap)++\#(text)\#(gap)*+\|\#(gap)*+(?:\#(sudo)|\#(reader))"#
        return rule(pattern) { (_: String, text: String) -> Bool in echoedHoldsSecret(text) }
    }()
    /// `sudo -S … <<< pw`, `docker login --password-stdin <<< pw`. The first -S found is the one: the
    /// atomic group never goes back for another.
    static let hereString: Rule = {
        let sudo = #"sudo(?=\#(gap))(?>\#(after("sudo"))\#(sudoStdin))\#(after("sudo"))"#
        let reader = #"\#(stdinFlag)\#(after(stdinOption))"#
        return rule(#"\#(start)(?:\#(sudo)|\#(reader))<<<\#(gap)*+(\#(word))"#)
    }()

    /// `git -c http.extraHeader=…`, `git config http.<url>.extraheader …`: the whole header.
    static let extraHeader = rule(#"\#(start)http\.(?:[^\s=]*\.)?extraheader(?:=|\#(gap)++)\#(value)"#,
                                  ignoringCase: true, masking: .headerWord)

    static let knownHeader = #"(?:(?:proxy-)?authorization|(?:set-)?cookie|(?:x-)?api-?key|x-auth-token|x-access-token|private-token)"#
    /// `X-Vault-Token`, `X-Auth-Key`, `X-Client-Secret`: a header whose last parts name a secret.
    static let namedHeader = #"[A-Za-z0-9\-]{0,40}?-(?:token|secret|key|auth|password|passwd|credentials?)(?![A-Za-z0-9])[A-Za-z0-9\-]{0,40}+"#
    /// `Authorization: …`, `Cookie: …`, `X-Api-Key: …`: up to the quote it opened with, or the end of the line.
    static let header: Rule = {
        let name = #"(?:\#(knownHeader)|\#(namedHeader))"#
        let doubleQuoted = #""\#(name)[ \t]*:[ \t]*([^\s"][^"\n]*)"#
        let singleQuoted = #"'\#(name)[ \t]*:[ \t]*([^\s'][^'\n]*)"#
        let bare = #"(?<![A-Za-z0-9\-"'])\#(name)[ \t]*:[ \t]*(\S[^\n]*)"#
        return rule(#"\#(doubleQuoted)|\#(singleQuoted)|\#(bare)"#, ignoringCase: true, masking: .header)
    }()

    /// In order: a git header before the generic header rule, which would otherwise mask inside it.
    static let rules: [Rule] = [
        assignment, flag, mysql, sshpass, redis, registryLogin, curlUser, curlCookie, opensslPass, opensslKey,
        mongo, zip, sevenZip, keychain, ghSecret, vault, htpasswd, urlPassword, urlToken, echoed, hereString,
        extraHeader, header,
    ]

    static func apply(_ rule: Rule, to text: inout String, complete: inout Bool) {
        _ = MCPRedaction.replace(rule.expression, in: &text, complete: &complete) { (match: NSTextCheckingResult, ns: NSString) -> String? in
            let taken = (1..<match.numberOfRanges).filter { (group: Int) -> Bool in match.range(at: group).location != NSNotFound }
            guard let last = taken.last else { return nil }
            let range = match.range(at: last)
            let value = ns.substring(with: range)
            let name = taken.count > 1 ? ns.substring(with: match.range(at: taken[0])) : ""
            guard rule.isSecret(name, value) else { return nil }
            let opening = ns.substring(with: NSRange(location: match.range.location, length: 1))
            guard let masked = replacement(for: value, by: rule.masking, opening: opening) else { return nil }
            let whole = ns.substring(with: match.range) as NSString
            let inner = NSRange(location: range.location - match.range.location, length: range.length)
            return whole.replacingCharacters(in: inner, with: masked)
        }
    }

    /// What `value` becomes, or nil to leave it. `opening`: the first character of the match.
    static func replacement(for value: String, by masking: Rule.Masking, opening: String) -> String? {
        let mask = MCPRedaction.mask
        switch masking {
        case .whole:
            return holdsSecret(word: value) ? mask : nil
        case .afterColon:
            guard let colon = value.firstIndex(of: ":") else { return nil }
            let quote = value.first == "\"" || value.first == "'" ? value.first : nil
            let closing = quote != nil && value.count > 1 && value.last == quote ? String(value.suffix(1)) : ""
            let password = String(value[value.index(after: colon)...].dropLast(closing.count))
            guard holdsSecret(text: password, literal: quote == "'") else { return nil }
            return String(value[...colon]) + mask + closing
        case .header:
            return headerHoldsSecret(value, literal: opening == "'") ? mask : nil
        case .headerWord:
            let inner = unquoted(value)
            let header = inner.firstIndex(of: ":").map { (colon: String.Index) -> String in String(inner[inner.index(after: colon)...]) }
            return headerHoldsSecret(header ?? inner, literal: value.hasPrefix("'")) ? mask : nil
        }
    }

    // MARK: values

    /// Whether a shell word holds a secret: not when it is empty, masked already, or only a variable
    /// (`$TOKEN`, `"${TOKEN}"`: the shell fills it in). In single quotes `$` is a letter like any other.
    static func holdsSecret(word: String) -> Bool {
        holdsSecret(text: unquoted(word), literal: word.hasPrefix("'"))
    }

    /// As `holdsSecret(word:)`, for text already out of its quotes; `literal` when they were single.
    static func holdsSecret(text: String, literal: Bool) -> Bool {
        if text.isEmpty || text == MCPRedaction.mask { return false }
        return literal || !isVariable(text)
    }

    /// A header's value holds a secret unless it is only a scheme (`grep "Authorization: Bearer"`) or,
    /// outside single quotes, only a variable, after a scheme if it has one (`Bearer $TOKEN`).
    static func headerHoldsSecret(_ value: String, literal: Bool) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        if schemes.contains(text.lowercased()) { return false }
        let words = text.split(separator: " ").map(String.init)
        let afterScheme = words.count == 2 && words[0].allSatisfy(\.isLetter)
        guard !literal, let credential = words.last, words.count == 1 || afterScheme else {
            return holdsSecret(text: text, literal: literal)
        }
        return holdsSecret(text: credential, literal: false)
    }

    static let schemes: Set<String> = ["basic", "bearer", "bot", "digest", "negotiate", "token"]

    /// `$NAME` or `${NAME}`.
    static func isVariable(_ text: String) -> Bool {
        variable.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
    static let variable = regex(#"^\$(?:[A-Za-z_][A-Za-z0-9_]*+|\{[A-Za-z_][A-Za-z0-9_]*+\})$"#)

    /// `word` out of the quotes around it, if it has them.
    static func unquoted(_ word: String) -> String {
        guard let quote = word.first, quote == "\"" || quote == "'" else { return word }
        let inner = word.dropFirst()
        return String(inner.last == quote ? inner.dropLast() : inner)
    }

    /// What echo or printf passes on holds a secret unless each word is an option (`-n`), a format
    /// (`'%s\n'`) or a variable.
    static func echoedHoldsSecret(_ text: String) -> Bool {
        let ns = text as NSString
        let words = shellWord.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (match: NSTextCheckingResult) -> String in
            ns.substring(with: match.range)
        }
        return !words.allSatisfy { (word: String) -> Bool in
            word.hasPrefix("-") || found(format, in: word) || !holdsSecret(word: word)
        }
    }
    static let shellWord = regex(word)
    static let format = regex(#"^(["']?+)(?:%[-0-9.]*+[sb]|\\[nt]|[ \t])++\1$"#)

    // MARK: names

    static func found(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A secret word ends the name or a part of it: `DB_PASSWORD`, `PGPASSWORD`, `PASSWORD2`, `SECRETKEY`.
    static let secretName = regex(#"\#(secretWord)(?:key)?(?![a-z])"#)
    /// `MYSQL_PWD`, `DB_PW`, `SMTP_PASS`, and sshpass's and redis-cli's own.
    static let passwordName = regex(#"[a-z0-9][_\-](?:pwd|pw|pass)$|^(?:sshpass|rediscli_auth)$"#)
    /// `TOKEN_FILE`, `--password-file`, `TOKEN_URL`: where the secret is (a password in a URL is the URL
    /// rules' to find).
    static let pathName = regex(#"[_.\-](?:file|path|dir|url|uri)$"#)
    /// BuildKit's `--secret id=npmrc,src=.npmrc`, podman's `--secret name,type=env`: which secret, and
    /// where it is.
    static let secretReference = regex(#"^(?:id|type|src|source|env|target)=|^[A-Za-z0-9_.\-]++,(?:type|target|uid|gid|mode)="#)

    /// Whether `name=value` (a name the pattern found a secret part in) sets a secret: a secret word or a
    /// password's name, or else a name ending in `_KEY` with a value that looks like a key (`CACHE_KEY=v2`
    /// stays). Not when the name says the value is a file or path, or for a container build's
    /// `--secret id=…`.
    static func isSecretAssignment(_ name: String, _ value: String) -> Bool {
        let lower = name.lowercased()
        if isReference(lower, value) || found(pathName, in: lower) { return false }
        if found(secretName, in: lower) || found(passwordName, in: lower) { return true }
        let key = unquoted(value)
        return key.count >= 16 && MCPRedaction.looksRandom(key)
    }

    /// Whether `--name value` passes a secret: not `--no-password`, nor a container build's `--secret id=…`.
    static func isSecretFlag(_ name: String, _ value: String) -> Bool {
        let lower = name.lowercased()
        return !lower.hasPrefix("--no-") && !isReference(lower, value)
    }

    static func isReference(_ name: String, _ value: String) -> Bool {
        name == "--secret" && found(secretReference, in: unquoted(value))
    }

    // MARK: long runs

    /// A long random-looking run is masked, but not one made of words and numbers (a branch named for its
    /// ticket, `PROJ-1234-add-user-settings`). In a path (`/Users/x/Code/Project2024/Sources`) only a
    /// name that is itself a long random run is, as a key in a URL's path.
    static func maskedRun(_ run: String) -> String? {
        guard MCPRedaction.looksRandom(run), !isWordy(run) else { return nil }
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

    /// Three quarters of `run`'s letters and digits are in words or numbers, split at its slashes,
    /// dashes, underscores and pluses: `ABC-1234-fix-login-redirect-for-v2`. A random key's parts are
    /// rarely words; a key with words in it still has its shape (MCPRedaction's tokens).
    static func isWordy(_ run: String) -> Bool {
        var plain = 0, total = 0
        for part in run.split(whereSeparator: { (character: Character) -> Bool in "/-_+".contains(character) }) {
            total += part.count
            if found(plainPart, in: String(part)) { plain += part.count }
        }
        return plain * 4 >= total * 3
    }
    /// `fix`, `PROJ`, `1234`, `AddUserSettingsPage`, `NullPointerInParser2`, `auth0`: digits only at the end.
    static let plainPart = regex(#"^(?:[0-9]++|[A-Z]*+(?:[A-Z]?[a-z]++)*+[0-9]{0,4}+)$"#)
}
