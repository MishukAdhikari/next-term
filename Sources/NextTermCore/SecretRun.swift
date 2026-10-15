import CryptoKit
import Foundation

/// `nxtrm secret run NAME[=ENVNAME]... -- <command> [arguments...]`: the rules both ends share. The
/// wrapper asks the app over its socket; after approval it sets the keys in its environment, removes every other
/// stored key's name, and execs the command. Nothing here holds a value but `Answer.environment`, which travels only
/// in an `allowed` answer, only to a verified wrapper.
public enum SecretRun {
    public static let usage = "usage: nxtrm secret run NAME[=ENVNAME]... -- command [arguments...]"

    /// `nxtrm secret help`: `secret run`, then `secret import`.
    public static let help = runHelp + "\n\n" + SecretImportPipe.help

    static let runHelp = """
        usage: nxtrm secret run NAME[=ENVNAME]... -- command [arguments...]

        Runs the command with keys from Next Term's Secrets in its environment, once you approve in Next Term with \
        Touch ID or your password. NAME is a stored key; ENVNAME, when given, is the variable it is set as. Every \
        other stored key's name is taken out of the command's environment. Nothing is written to standard output.

        For an MCP server, put it in the server's command:
          nxtrm secret run GITHUB_TOKEN -- npx -y @modelcontextprotocol/server-github

        Internal: nxtrm secret run --ticket <id> is the line Next Term types for run_with_secrets.
        """

    /// How long the wrapper waits for an answer: 25 seconds, or 10 minutes for a ticket, whose tab is Next Term's own.
    public static let wait: TimeInterval = 25
    public static let ticketWait: TimeInterval = 600

    // MARK: arguments

    /// What `nxtrm secret run` was asked: the keys and the command, or a ticket.
    public struct Invocation: Equatable, Sendable {
        /// The keys, in the order given.
        public var names: [String]
        /// ENVNAME by NAME (NAME itself when no `=ENVNAME`).
        public var map: [String: String]
        /// The command and its arguments, after `--`.
        public var argv: [String]
        public var ticket: String?
    }

    /// Bad arguments: the usage line, and what was wrong.
    public struct UsageError: Error, Equatable, Sendable {
        public let reason: String
    }

    /// The arguments after `secret run`.
    public static func parse(_ arguments: [String]) -> Result<Invocation, UsageError> {
        if arguments.first == "--ticket" {
            guard arguments.count == 2, isTicket(arguments[1]) else { return .failure(UsageError(reason: "--ticket takes one id")) }
            return .success(Invocation(names: [], map: [:], argv: [], ticket: arguments[1]))
        }
        guard let dashes = arguments.firstIndex(of: "--") else { return .failure(UsageError(reason: "no -- before the command")) }
        let argv = Array(arguments[(dashes + 1)...])
        guard let program = argv.first, !program.isEmpty else { return .failure(UsageError(reason: "no command after --")) }
        let pairs = arguments[..<dashes]
        guard !pairs.isEmpty else { return .failure(UsageError(reason: "no key named before --")) }
        var names: [String] = []
        var map: [String: String] = [:]
        var envNames = Set<String>()
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            let envName = parts.count == 2 ? parts[1] : name
            guard StoredSecretName.isValid(name) else { return .failure(UsageError(reason: "\(name) is not a key's name")) }
            guard StoredSecretName.isValid(envName) else { return .failure(UsageError(reason: "\(envName) is not a variable's name")) }
            guard !StoredSecretName.isRefusedEnvName(envName) else { return .failure(UsageError(reason: "a key can't be given as \(envName)")) }
            guard map[name] == nil else { return .failure(UsageError(reason: "\(name) is named twice")) }
            guard envNames.insert(envName).inserted else { return .failure(UsageError(reason: "\(envName) is set twice")) }
            names.append(name)
            map[name] = envName
        }
        return .success(Invocation(names: names, map: map, argv: argv, ticket: nil))
    }

    /// A ticket's id: 128 random bits in lowercase base32, 26 characters.
    public static func isTicket(_ text: String) -> Bool {
        text.utf8.count == 26 && text.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x32...0x37).contains($0) }
    }

    /// A new ticket id.
    public static func newTicket() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var generator = SystemRandomNumberGenerator()
        var bits = [UInt8]((0..<17).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        defer { SecretBytes.wipe(&bits) }
        var out = ""
        var buffer = 0
        var count = 0
        for byte in bits {
            buffer = buffer << 8 | Int(byte)
            count += 8
            while count >= 5, out.count < 26 {
                count -= 5
                out.append(alphabet[(buffer >> count) & 31])
            }
        }
        return out
    }

    // MARK: the typed line

    /// Shells whose syntax the typed line can't be written in.
    public static let untypableShells: Set<String> = ["elvish", "xonsh"]

    /// The line Next Term types for a ticket (`<nxtrm> secret run --ticket <id>`), each word quoted for the tab's
    /// shell: single quotes for the sh family, fish and tcsh; `^'…'` for nu's first word; `& '…'` for pwsh. Nil for
    /// elvish and xonsh, a control character, or a word the shell can't quote. An unknown shell gets the sh family's.
    public static func typedLine(_ words: [String], shell: String) -> String? {
        guard let first = words.first, !untypableShells.contains(shell) else { return nil }
        guard !words.contains(where: { $0.unicodeScalars.contains(where: ShellQuote.isControl) }) else { return nil }
        var quoted: [String] = []
        for word in words {
            guard let text = quote(word, shell: shell) else { return nil }
            quoted.append(text)
        }
        switch shell {
        case "nu": quoted[0] = "^" + (isPlainWord(first) ? "'\(first)'" : quoted[0])
        case "pwsh": quoted[0] = "& " + (isPlainWord(first) ? "'\(first)'" : quoted[0])
        default: break
        }
        return quoted.joined(separator: " ")
    }

    static func isPlainWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || "_./-".unicodeScalars.contains(scalar)
        }
    }

    static func quote(_ word: String, shell: String) -> String? {
        if isPlainWord(word) { return word }
        switch shell {
        case "fish":
            return "'" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        case "tcsh", "csh":
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "!", with: "\\!") + "'"
        case "nu":
            return word.contains("'") ? nil : "'" + word + "'"
        case "pwsh":
            return "'" + word.replacingOccurrences(of: "'", with: "''") + "'"
        default:
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    // MARK: the socket messages

    /// The wrapper's one request line: `{"tool": "secret_run", "arguments": {…}}`.
    public struct Request: Codable, Equatable, Sendable {
        public var names: [String]
        public var map: [String: String]
        /// The command after `--`.
        public var argv: [String]
        /// The absolute path the wrapper resolved `argv[0]` to with its own `PATH`.
        public var executable: String
        /// Its working folder.
        public var directory: String
        /// Its own argv, which the app compares with what the kernel says.
        public var argvFull: [String]
        /// The variables that can redirect a command, by name, with a SHA-256 of each value.
        public var warn: [String: String]
        public var ticket: String?

        enum CodingKeys: String, CodingKey {
            case names, map, argv, executable, directory, warn, ticket
            case argvFull = "argv_full"
        }

        public init(names: [String], map: [String: String], argv: [String], executable: String, directory: String,
                    argvFull: [String], warn: [String: String], ticket: String?) {
            self.names = names
            self.map = map
            self.argv = argv
            self.executable = executable
            self.directory = directory
            self.argvFull = argvFull
            self.warn = warn
            self.ticket = ticket
        }

        /// The line the wrapper sends.
        public func line() -> Data? {
            guard let arguments = try? JSONEncoder().encode(self),
                  let object = try? JSONSerialization.jsonObject(with: arguments),
                  var data = try? JSONSerialization.data(withJSONObject: ["tool": "secret_run", "arguments": object]) else { return nil }
            data.append(0x0A)
            return data
        }

        /// The request in a decoded line's `arguments`.
        public static func decode(_ arguments: [String: Any]) -> Request? {
            guard JSONSerialization.isValidJSONObject(arguments), let data = try? JSONSerialization.data(withJSONObject: arguments) else {
                return nil
            }
            return try? JSONDecoder().decode(Request.self, from: data)
        }
    }

    /// The app's answer. Values travel only in `environment`, only with `allowed`.
    public struct Answer: Codable, Sendable {
        public var status: Status
        public var note: String?
        /// ENVNAME → value, for `allowed`.
        public var environment: [String: String]?
        /// The stored keys' names this run did not approve: taken out of the command's environment.
        public var remove: [String]?
        /// For a ticket: the command and folder Next Term holds, never the typed line's.
        public var argv: [String]?
        public var directory: String?
        /// The key that is not stored, for `unknown`.
        public var name: String?
        /// The keys asked for, so a ticket's lines can name them (its typed line holds none).
        public var names: [String]?
        /// For `paused` and `declining`: when asking is possible again, in seconds since 1970.
        public var until: Double?

        public init(status: Status, note: String? = nil, environment: [String: String]? = nil, remove: [String]? = nil,
                    argv: [String]? = nil, directory: String? = nil, name: String? = nil, names: [String]? = nil, until: Double? = nil) {
            self.status = status
            self.note = note
            self.environment = environment
            self.remove = remove
            self.argv = argv
            self.directory = directory
            self.name = name
            self.names = names
            self.until = until
        }

        /// The answer's line.
        public func line() -> Data {
            var data = (try? JSONEncoder().encode(self)) ?? Data(#"{"status":"refused"}"#.utf8)
            data.append(0x0A)
            return data
        }

        public static func decode(_ line: Data) -> Answer? {
            try? JSONDecoder().decode(Answer.self, from: line)
        }
    }

    /// What the wrapper read on its connection.
    public enum Read: Equatable, Sendable {
        /// The answer's line, without its newline.
        case line(Data)
        /// Nothing within the wait: the request still waits in Next Term.
        case timedOut
        /// Next Term closed the connection without an answer (`Ending.closed`).
        case closed
        /// More than the limit with no newline: no answer Next Term writes.
        case tooLong
    }

    /// One line from `fd` within `seconds`. The buffer read into, and a part of a line that never ended, are wiped.
    public static func readAnswer(from fd: Int32, within seconds: TimeInterval, limit: Int = 4 * 1024 * 1024) -> Read {
        let deadline = Date().addingTimeInterval(seconds)
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        defer { SecretBytes.wipe(&buffer) }
        while true {
            if let end = line.firstIndex(of: 0x0A) { return .line(line[..<end]) }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return unanswered(.timedOut, &line) }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(1000, max(1, left * 1000))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return unanswered(.closed, &line) }
            line.append(contentsOf: buffer[0..<count])
            guard line.count <= limit else { return unanswered(.tooLong, &line) }
        }
    }

    private static func unanswered(_ read: Read, _ part: inout Data) -> Read {
        SecretBytes.wipe(&part)
        return read
    }

    /// Whether the wrapper at the far end of the app's `fd` has left, as of now: its end is closed (a read would give
    /// 0) or the connection broke. It reads nothing and never waits.
    public static func peerLeft(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EINTR)
    }

    // MARK: statuses

    /// The app's answers, by status.
    public enum Status: String, Codable, Sendable {
        case allowed, declined, paused, stopped, declining, busy, limited, expired
        /// "Allow once" starts one command, and an identical one waiting on the same panel used it.
        case usedAlready = "used_already"
        case cantOpen = "cant_open"
        case refused
        case valueInCommand = "value_in_command"
        case unknown
    }

    /// Why the wrapper ends without running the command: an answer, or what went wrong before one.
    public enum Ending: Equatable, Sendable {
        case answer(Status, name: String?, until: Date?)
        /// Next Term is not running, or agent control is off.
        case noSocket
        /// The socket's owner is not this copy of Next Term.
        case peerCheck
        case timedOut
        case timedOutTicket
        /// Next Term closed the connection without an answer: it quit, or restarted for an update, while the request
        /// waited, so the request and its card are gone.
        case closed
        case usage
        case notFound(String)
        case cantRun(String)
    }

    /// The wrapper's one line on standard error, and its exit code. `names` and `program` fill the
    /// lines that name them.
    public static func ending(_ ending: Ending, names: [String], program: String, now: Date = Date(),
                              timeZone: TimeZone = .current) -> (line: String, exit: Int32) {
        let keys = keysText(names)
        switch ending {
        case .noSocket:
            return ("nxtrm: Next Term is not running, or “Let agents control Next Term” is off in its Settings. Open Next Term, then restart this command.", 1)
        case .peerCheck:
            return ("nxtrm: the program at Next Term’s socket is not this copy of Next Term, so no key was asked for.", 1)
        case .timedOut:
            return ("nxtrm: \(keys) is waiting for your approval in Next Term. Allow it there, then restart this command.", 1)
        case .timedOutTicket:
            return ("nxtrm: no answer in Next Term within 10 minutes, so no key was given.", 1)
        case .closed:
            return ("nxtrm: Next Term quit before it answered, so no key was given. Restart this command once Next Term is open again.", 1)
        case .usage:
            return (usage, 2)
        case .notFound(let command):
            return ("nxtrm: \(command): command not found", 127)
        case .cantRun(let command):
            return ("nxtrm: \(command): can't run it", 126)
        case .answer(let status, let name, let until):
            return answerLine(status, keys: keys, name: name ?? names.first ?? "", program: program, until: until, now: now, timeZone: timeZone)
        }
    }

    static func answerLine(_ status: Status, keys: String, name: String, program: String, until: Date?, now: Date,
                           timeZone: TimeZone) -> (line: String, exit: Int32) {
        switch status {
        case .allowed: return ("nxtrm: running \(program) with \(keys)", 0)
        case .declined: return ("nxtrm: Next Term declined \(keys) for \(program).", 1)
        case .paused:
            let time = until.map { clock($0, timeZone: timeZone) } ?? "10 minutes from when you declined it"
            return ("nxtrm: you declined this a few minutes ago, so Next Term won’t ask again until \(time).", 1)
        case .stopped:
            return ("nxtrm: you chose Decline and Stop Asking for this command, so Next Term won’t ask again until it quits. Resume it in Settings › Secrets.", 1)
        case .declining:
            let minutes = until.map { max(1, Int(($0.timeIntervalSince(now) / 60).rounded(.up))) } ?? 60
            return ("nxtrm: Next Term is pausing key requests for the next \(minutes) \(minutes == 1 ? "minute" : "minutes").", 1)
        case .busy: return ("nxtrm: too many key requests are waiting in Next Term. Answer them, then restart this command.", 1)
        case .limited: return ("nxtrm: this command has asked too often. Resume it in Settings › Secrets, or restart Next Term.", 1)
        case .expired: return ("nxtrm: this run’s approval expired or was used already, so no key was given.", 1)
        case .usedAlready:
            return ("nxtrm: an identical command used this Allow once, so no key was given. Restart this command to ask again.", 1)
        case .cantOpen: return ("nxtrm: Next Term can’t open Secrets on this Mac. Open Settings › Secrets.", 1)
        case .refused: return ("nxtrm: Next Term refused this request.", 1)
        case .valueInCommand: return ("nxtrm: the command holds a stored key’s value. Use the key’s name instead.", 2)
        case .unknown: return ("nxtrm: no key named \(name) in Next Term’s Secrets (Settings › Secrets).", 2)
        }
    }

    /// The approval panel's line under the command: the keys reach it in its environment, which any program running as
    /// the user can read while it runs (`ps -E`), an agent's own shell tool too.
    public static func environmentNote(keys count: Int) -> String {
        let keys: String = count == 1 ? "this key" : "these keys"
        return "The command, and any program running as you, can read \(keys) while it runs."
    }

    /// "GITHUB_TOKEN", "A and B", or "5 keys" for three or more.
    public static func keysText(_ names: [String]) -> String {
        switch names.count {
        case 0: return "no keys"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) keys"
        }
    }

    /// "4:12 PM", in the local time zone.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    // MARK: the environment

    /// The command's environment: the wrapper's own, with the stored names this run did not approve taken out and
    /// each approved ENVNAME set.
    public static func environment(base: [String: String], answer: Answer) -> [String: String] {
        var environment = base
        for name in answer.remove ?? [] { environment[name] = nil }
        for (name, value) in answer.environment ?? [:] { environment[name] = value }
        return environment
    }

    /// The stored names a run removes: every stored key's name but the ENVNAMEs it approved.
    public static func removed(stored: [String], approved envNames: [String]) -> [String] {
        let approved = Set(envNames)
        return stored.filter { !approved.contains($0) }.sorted()
    }

    // MARK: warnings

    /// Variables that can change what a command runs, by name.
    static let runChangers: Set<String> = [
        "NODE_OPTIONS", "BASH_ENV", "ENV", "PYTHONSTARTUP", "PYTHONPATH", "PERL5OPT", "RUBYOPT", "LD_PRELOAD", "ELECTRON_RUN_AS_NODE",
    ]
    /// Variables that can send a command's traffic, and so a key, elsewhere: proxies (in either case) and CA bundles.
    static let proxies: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
    static let trustChangers: Set<String> = [
        "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED",
    ]

    /// Whether the panel names this variable when it is set.
    public static func isWarned(_ name: String) -> Bool {
        runChangers.contains(name) || proxies.contains(name) || trustChangers.contains(name)
            || name.hasPrefix("DYLD_") || name.hasSuffix("_BASE_URL")
    }

    /// The warned variables an environment has, by name, with a SHA-256 of each value (hex).
    public static func warnings(environment: [String: String]) -> [String: String] {
        var warned: [String: String] = [:]
        for (name, value) in environment where isWarned(name) { warned[name] = digest(Data(value.utf8)) }
        return warned
    }

    /// What the panel says about a warned variable.
    public static func warningText(for name: String) -> String {
        if proxies.contains(name) || trustChangers.contains(name) { return "\(name) is set. The key may pass through that proxy." }
        if name.hasSuffix("_BASE_URL") { return "\(name) is set. The key may go to that address." }
        return "\(name) is set: it can change what this command runs."
    }

    /// The warnings about a wrapper's command, its argv after `--`: an unpinned package, a shell, an agent.
    public static func warnings(argv: [String]) -> [String] {
        commandWarnings(words: argv)
    }

    /// The warnings about a `run_with_secrets` command, for each of its simple commands. Its own `/bin/sh -c` is not
    /// what is checked; the program inside the command is.
    public static func warnings(command: String) -> [String] {
        var found: [String] = []
        for segment in CommandClassifier.segments(command) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for warning in commandWarnings(words: words) where !found.contains(warning) { found.append(warning) }
        }
        return found
    }

    static func commandWarnings(words: [String]) -> [String] {
        var found: [String] = []
        if let unpinned = unpinnedText(words) { found.append(unpinned) }
        let (name, _) = program(of: words)
        if shells.contains(name) { found.append("This command starts a shell (\(name)). Anything it runs gets the key.") }
        if CommandClassifier.agents.contains(name) || words.contains(where: CommandClassifier.containsAgentHint) {
            let agent = name.isEmpty ? "an agent" : name
            found.append("This command starts an agent (\(agent)). The agent and its tools get the key.")
        }
        return found
    }

    /// Shells, by their program's name.
    public static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh"]

    /// The program a command's words run: past assignments, flags and wrappers such as `env`, `sudo` and `npx`.
    static func program(of words: [String]) -> (name: String, args: [String]) {
        for (index, word) in words.enumerated() {
            if word.hasPrefix("-") || isAssignment(word) { continue }
            let base = CommandClassifier.baseName(word)
            if base.isEmpty || CommandClassifier.wrappers.contains(base) { continue }
            return (base, Array(words[(index + 1)...]))
        }
        return ("", [])
    }

    /// Whether `run_with_secrets`' command is one line: no control character but a tab, and no line or paragraph
    /// separator. Checked by scalar, because "\r\n" is one Character, equal to neither "\r" nor "\n", and `/bin/sh`
    /// runs each line it is given.
    public static func isOneLine(_ command: String) -> Bool {
        !command.unicodeScalars.contains { scalar in
            (ShellQuote.isControl(scalar) && scalar != "\t") || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
    }

    /// The program for a panel's title and the Touch ID reason: a command's first word, past set-up such as `cd`.
    public static func programName(ofCommand command: String) -> String {
        for segment in CommandClassifier.segments(command) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first(where: { !isAssignment($0) }) else { continue }
            let base = CommandClassifier.baseName(first)
            if !CommandClassifier.setup.contains(base) { return base }
        }
        return "a command"
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let key = word[..<equals]
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// "npx -y runs the newest @x/y each time, …" for a package with no exact version: npx, bunx, uvx, pnpm dlx and
    /// yarn dlx (`SkillReview.unpinnedPackage`), and `pipx run`.
    static func unpinnedText(_ words: [String]) -> String? {
        let start = words.firstIndex { !isAssignment($0) } ?? words.endIndex
        let command = Array(words[start...])
        guard let first = command.first else { return nil }
        let isPipx = CommandClassifier.baseName(first) == "pipx"
        guard isPipx ? unpinnedPipx(command) != nil : SkillReview.unpinnedPackage(command) else { return nil }
        let package = (isPipx ? unpinnedPipx(command) : command.dropFirst().first { !$0.hasPrefix("-") && $0 != "dlx" }) ?? ""
        let lead = command.prefix { $0 != package }.joined(separator: " ")
        return "\(lead) runs the newest \(package) each time, so code you haven't seen gets the key. Pin a version to avoid this."
    }

    /// `pipx run`'s package when it has no exact version: the value of `--spec` when given, else the first word after
    /// `run` that is not a flag. Pinned only as `name==<exact version>` (`SkillReview.isExactVersion`).
    static func unpinnedPipx(_ words: [String]) -> String? {
        guard words.count >= 3, words[1] == "run" else { return nil }
        var package: String?
        var index = 2
        while index < words.count {
            let word = words[index]
            if word == "--spec", index + 1 < words.count {
                package = words[index + 1]
                break
            }
            if word.hasPrefix("--spec=") {
                package = String(word.dropFirst("--spec=".count))
                break
            }
            if !word.hasPrefix("-") {
                package = word
                break
            }
            index += 1
        }
        guard let package else { return nil }
        if let equals = package.range(of: "=="), SkillReview.isExactVersion(package[equals.upperBound...]) { return nil }
        return package
    }

    // MARK: the folder's .env

    /// A SHA-256 of the folder's `.env` as read, or "none". Any change to that file asks again.
    public static func envFileDigest(directory: String) -> String {
        let path = (directory as NSString).appendingPathComponent(".env")
        guard isRegularFile(path), let data = FileManager.default.contents(atPath: path), data.count <= EnvFile.maxSize else { return "none" }
        return digest(data)
    }

    /// The `.env` warnings: a name that can send the key elsewhere (ending in `_BASE_URL`, `_API_URL`, `_HOST` or
    /// `_ENDPOINT`, or a proxy). Names only; no value is read out.
    public static func envFileWarnings(directory: String) -> [String] {
        let path = (directory as NSString).appendingPathComponent(".env")
        guard let entries = EnvFile.read(path) else { return [] }
        var names: [String] = []
        for entry in entries where !names.contains(entry.key) {
            let key = entry.key
            let redirects = ["_BASE_URL", "_API_URL", "_HOST", "_ENDPOINT"].contains { key.hasSuffix($0) } || proxies.contains(key)
            if redirects { names.append(key) }
        }
        return names.map { ".env in this folder sets \($0). The key may go to that address." }
    }

    /// SHA-256, in lowercase hex.
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the binding

    /// What a wrapper's grant is bound to: the agent's executable and its file, its script under an
    /// interpreter, the resolved executable and its file, the argv, the keys, the folder, the warned variables and
    /// the `.env`.
    public static func binding(request: Request, agentPath: String?, agentScript: String?, program: String,
                               envDigest: String) -> SecretBinding {
        SecretBinding(source: .wrapper, asker: asker(agentPath: agentPath, argv: request.argv), program: program,
                      agentPath: agentPath, agentIdentity: agentPath.flatMap(SecretFileIdentity.of), agentScript: agentScript,
                      executable: request.executable, executableIdentity: SecretFileIdentity.of(request.executable),
                      command: request.argv, keys: request.map, folder: request.directory, warned: request.warn, envDigest: envDigest)
    }

    /// A wrapper's asker: `wrapper:` with the agent's path (or none) and a digest of the command.
    public static func asker(agentPath: String?, argv: [String]) -> String {
        let commandDigest = digest(Data(argv.joined(separator: "\u{0}").utf8)).prefix(16)
        return "wrapper:" + (agentPath ?? "none") + ":" + commandDigest
    }
}
