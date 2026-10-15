import CryptoKit
import Foundation

// Keys copied in from a file of keys: a `.env`, a JSON, TOML or YAML document, an agent's config, a CSV, and password
// managers' exports. Each reader is a pure function from bytes to a report. It runs nothing, follows no `$(…)`, include
// or `source`, and never writes the file. Values go into `SecretBytes` as each reader finds them and are wiped when the
// report goes. A row's value, its place in the file and its last characters are for the preview on the Mac only: what
// an agent learns is `answer(for:)`, names and counts.

/// One key found in a file: what the preview lists, with its tick, note and link. The preview edits its name and tick
/// (R16); it never ticks a row with a refusal.
public struct SourceRow: Sendable, GroupableValue {
    /// The name it would be stored under: a valid key name, editable in the preview.
    public var name: String
    public let value: SecretBytes
    /// "OpenAI key", "a key, by its name".
    public let kind: String
    /// Where it was found, shown on the Mac only: "line 4", "openai.apiKey".
    public let place: String
    /// Its line in the file, when the reader knows it.
    public let line: Int?
    /// The page it came from, from the file itself or suggested from its value or name.
    public internal(set) var link: SecretSources.LinkHint?
    /// Whether it is ticked: it starts so when it looks like a key, and nothing in its note or refusal says otherwise.
    public var ticked: Bool
    public internal(set) var note: SecretSources.Note?
    /// Why it can't be stored; such a row is never ticked.
    public let refusal: SecretSources.Refusal?
    /// The other places the same name held the same value: one row for them all.
    public internal(set) var alsoAt: [String] = []
    /// Its name was made from an item's title or a site: the preview says agents will see it.
    public let fromTitle: Bool
    /// The last 4 characters, for a value of 12 characters or more; nil for a shorter one, which shows as dots. Taken
    /// once, from the text the parse made, so reading it makes no copy of the value.
    public let lastFour: String?
    /// The section it was found in (a JSON object's path, or the file): a name set twice in one section is set again,
    /// in two sections it is two keys.
    let scope: String

    public var groupPlace: AnyHashable { AnyHashable(scope) }

    /// A row for `text`, the value as the parse found it (trimmed), which goes into `SecretBytes` here.
    init(name: String, text: String, kind: String, place: String, line: Int?, link: SecretSources.LinkHint? = nil,
         ticked: Bool, note: SecretSources.Note? = nil, refusal: SecretSources.Refusal? = nil, scope: String,
         fromTitle: Bool = false) {
        self.name = name
        value = SecretBytes(utf8: text)
        self.kind = kind
        self.place = place
        self.line = line
        self.link = link
        self.ticked = ticked && refusal == nil
        self.note = note
        self.refusal = refusal
        lastFour = SecretSources.lastFour(of: text)
        self.scope = scope
        self.fromTitle = fromTitle
    }
}

/// What a file holds: its rows, the values in it that aren't keys, and, for a file that can't be read, why.
/// A class, so the preview releases it once and every value in it is wiped then.
public final class SourceReport: Sendable {
    public let format: SecretSources.Format
    public let rows: [SourceRow]
    public let notKeys: [SecretSources.NotKey]
    public let unreadable: SecretSources.Unreadable?
    /// What each key copied in is for: fixed text from the file's name and folder, or the app that wrote an export,
    /// never from its content.
    public let purpose: String
    /// The app that wrote the export ("Bitwarden", "Chrome"); nil for a project's own file. An export is one to move to
    /// the Trash once its keys are in.
    public let exportedBy: String?
    /// The agent whose config this is ("Zed", "Codex"), when Next Term can't rewrite it: the file still holds the keys
    /// copied in, and each row says so.
    public let agent: String?
    /// What to know about the whole file, for the preview's header: an agent's config still holds the keys copied in
    /// (`stillInFile`, whenever `agent` is set), a Compose file is often in git. A row's own note ("Replaces your key",
    /// "Set again on line 9") takes this one's place on that row, so the header is where it always shows.
    public let fileNote: SecretSources.Note?

    init(format: SecretSources.Format, rows: [SourceRow] = [], notKeys: [SecretSources.NotKey] = [],
         unreadable: SecretSources.Unreadable? = nil, purpose: String, exportedBy: String? = nil, agent: String? = nil,
         fileNote: SecretSources.Note? = nil) {
        self.format = format
        self.rows = rows
        self.notKeys = notKeys
        self.unreadable = unreadable
        self.exportedBy = exportedBy
        self.agent = agent
        self.fileNote = agent == nil ? fileNote : .stillInFile
        self.purpose = exportedBy.map { (app: String) -> String in "From " + app } ?? purpose
    }

    /// "4 other values aren't keys.", or nil when there are none.
    public var footer: String? {
        switch notKeys.count {
        case 0: return nil
        case 1: return "1 other value isn\u{2019}t a key."
        default: return "\(notKeys.count) other values aren\u{2019}t keys."
        }
    }
}

public enum SecretSources {
    /// The formats a file is read as.
    public enum Format: String, Sendable, CaseIterable {
        case env
        case json
        case toml
        case yaml
        case csv
        case bitwarden
        case onePassword = "1password"
        /// Bitwarden Secrets Manager's `bws secret list`.
        case bws
    }

    /// Where a row's link comes from: the file itself (a URL in the comment above a `.env` key), or a page suggested on
    /// this Mac from the value's head or the name.
    public enum LinkHint: Equatable, Sendable {
        case source(URL)
        case suggested(KeyPage)

        public var url: URL {
            switch self {
            case .source(let url): return url
            case .suggested(let page): return page.url
            }
        }

        public var page: KeyPage? {
            if case .suggested(let page) = self { return page }
            return nil
        }
    }

    /// Why a row starts unticked, or what to know about it.
    public enum Note: Equatable, Sendable {
        /// The file sets the name again further on, and a loader takes the last.
        case setAgain(line: Int?, place: String)
        case replaces
        case publishable
        case shortLived
        /// A key's shape under a name a web framework hands to the browser.
        case shipsToBrowsers
        /// A value under such a name with no key's shape.
        case publicName
        case loaderReadsDollar
        /// A website's sign-in password from a password manager or a browser, with no key's shape.
        case websitePassword
        /// Bitwarden asks for the master password again before it shows the item.
        case reprompt
        /// An agent's config Next Term can't rewrite: the key stays in it after the copy.
        case stillInFile
        /// A Compose file's `environment`: Docker advises against keys there, as the file is often committed.
        case composeInGit

        public var sentence: String {
            switch self {
            case .setAgain(let line, let place):
                return line.map { (line: Int) -> String in "Set again on line \(line)" } ?? "Set again at \(place)"
            case .replaces: return "Replaces your key"
            case .publishable: return "Safe to expose; usually not worth storing"
            case .shortLived: return "Expires within hours"
            case .shipsToBrowsers: return "This name ships the value to browsers."
            case .publicName: return "Its name sends it to browsers, so it isn\u{2019}t secret."
            case .loaderReadsDollar: return "Next.js, Vite and Compose read the $ in it as a variable."
            case .websitePassword: return "A website password; usually not an API key"
            case .reprompt: return "Bitwarden asks for your master password before showing it"
            case .stillInFile: return "This file still holds the key; Next Term can\u{2019}t rewrite it yet"
            case .composeInGit: return "Compose files are often in git"
            }
        }

        /// A note the row starts ticked with: what to know, not a reason to leave it.
        var keepsTick: Bool { self == .loaderReadsDollar || self == .stillInFile || self == .composeInGit }
    }
}

// MARK: - Refusals and values that aren't keys

extension SecretSources {
    /// Why a row can't be stored yet. Each has one plain sentence for the preview.
    public enum Refusal: Equatable, Sendable {
        case lineBreaks
        case tooLong
        case nul
        /// A whole credential file, such as a Google Cloud service-account key.
        case credentialFile
        case encryptedSops
        case encryptedDotenvx
        /// A key with a reference inside it, which the project's loader fills in: stored, it would be kept as written.
        case reference([String])
        /// A part of a YAML file the reader doesn't follow: an alias, a tag, a flow collection over several lines.
        case unreadablePart
        /// A Kubernetes Secret of a type that holds a certificate, an SSH key or a registry's login: "TLS".
        case typedSecret(String)
        /// A Kubernetes Secret's `data` value that isn't base64 of UTF-8 text.
        case notText

        public var sentence: String {
            switch self {
            case .lineBreaks: return "It has line breaks, which Secrets can\u{2019}t keep yet"
            case .tooLong: return "It is over 16 KB, more than Secrets keeps"
            case .nul: return "It holds a NUL character"
            case .credentialFile: return "A credential file; not importable yet"
            case .encryptedSops: return "Encrypted by sops; decrypt it to import it"
            case .encryptedDotenvx: return "Encrypted by dotenvx; decrypt it to import it"
            case .reference(let names):
                let built: String = names.isEmpty ? "another value" : names.joined(separator: ", ")
                return "Built from \(built), which your loader fills in; Secrets would keep it as written"
            case .unreadablePart: return "Next Term can\u{2019}t read this part"
            case .typedSecret(let type): return "A Kubernetes \(type) secret; not importable yet"
            case .notText: return "It doesn\u{2019}t decode to text Secrets can keep"
            }
        }
    }

    /// A value in the file that isn't a key: counted in the preview's footer, never a row.
    public struct NotKey: Equatable, Sendable {
        public let name: String
        public let place: String
        public let reason: NotKeyReason
    }

    public enum NotKeyReason: Equatable, Sendable {
        /// It holds `${NAME}`: the key is NAME's, elsewhere.
        case builtFrom([String])
        /// It points at a key kept elsewhere: `${{ secrets.X }}`, `op://…`, `valueFrom`.
        case reference
        case placeholder
        /// A number, a boolean, a URL, a model's name: a setting.
        case setting
        /// 1Password's CLI printed a note in its place, as it does without `--reveal`.
        case concealed

        public var sentence: String {
            switch self {
            case .builtFrom(let names): return "Built from " + names.joined(separator: ", ")
            case .reference: return "A reference to a key kept elsewhere"
            case .placeholder: return "A placeholder"
            case .setting: return "A setting"
            case .concealed: return "Hidden by 1Password\u{2019}s CLI; run it again with --reveal"
            }
        }
    }

    /// Why a whole file can't be read: a sentence for the Mac, and a class of reason, with nothing of the file in it,
    /// for an agent's answer.
    public enum Unreadable: Equatable, Sendable {
        case tooLarge
        /// A `.env` past the editor's size (`EnvFile.maxSize`): no one wrote one by hand, and its reader is slow there.
        case envTooLarge
        case notText
        case notJSON
        case tooMany
        /// A Bitwarden export sealed by the account's key or a password.
        case encryptedExport
        /// Text or an archive that isn't the app's export it was read as.
        case notAnExport(from: String)
        case archive(ZipReader.Failure)
        case csv(CSVReader.Failure)
        /// A CSV whose header names no column Next Term knows.
        case unknownColumns
        /// TOML that doesn't parse, at its line.
        case notTOML(line: Int)
        case notYAML(YAMLSubset.Failure)
        /// A TOML or YAML file past `configMaxBytes`.
        case configTooLarge

        public var sentence: String {
            switch self {
            case .tooLarge: return "It is larger than the 5 MB Next Term reads."
            case .envTooLarge: return "It is larger than the 512 KB Next Term reads in a .env file."
            case .notText: return "It isn\u{2019}t text Next Term can read."
            case .notJSON: return "It isn\u{2019}t JSON Next Term can read."
            case .tooMany: return "It holds more values than Next Term reads."
            case .encryptedExport:
                let again = "Export again as .json (unencrypted), or use Import from Bitwarden\u{2026}"
                return "This export is encrypted. " + again
            case .notAnExport(let app): return "It isn\u{2019}t a \(app) export Next Term can read."
            case .archive(let failure): return failure.sentence
            case .csv(let failure): return failure.sentence
            case .unknownColumns: return "Next Term can\u{2019}t tell which column holds the keys."
            case .notTOML(let line): return "It isn\u{2019}t TOML Next Term can read (line \(line))."
            case .notYAML(let failure): return "It isn\u{2019}t YAML Next Term can read. " + failure.sentence
            case .configTooLarge: return "It is larger than the 2 MB Next Term reads in a TOML or YAML file."
            }
        }

        /// The kind of reason, for an agent: no line, name or part of the file.
        public var reasonClass: String {
            switch self {
            case .tooLarge, .envTooLarge, .configTooLarge: return "too large"
            case .notText: return "not text"
            case .notJSON: return "not valid JSON"
            case .tooMany: return "too many values"
            case .encryptedExport: return "an encrypted Bitwarden export"
            case .notAnExport(let app): return "not a \(app) export"
            case .archive: return "an archive Next Term can\u{2019}t read"
            case .csv: return "not a CSV Next Term can read"
            case .unknownColumns: return "unknown CSV columns"
            case .notTOML: return "not TOML Next Term can read"
            case .notYAML: return "not YAML Next Term can read"
            }
        }
    }

    /// The most a file read for an import may hold, and the most values it may have. A `.env` may hold no more than the
    /// editor reads (`EnvFile.maxSize`, 512 KB).
    public static let maxBytes = 5 * 1024 * 1024
    /// The most an archive (1Password's `.1pux`) may hold: its `export.data` is read from it in memory.
    public static let maxArchiveBytes = ZipReader.maxEntryBytes
    static let maxValues = 50_000

    /// The last 4 characters of a value of 12 characters or more, counted as the preview shows them (a character of
    /// several bytes is one); nil for a shorter value, which shows as dots only (R25).
    static func lastFour(of text: String) -> String? {
        guard text.utf8.count >= 12, text.count >= 12 else { return nil }
        return String(text.suffix(4))
    }

    /// What each key copied from a file is for: "From .env in rag-api". Fixed text from the file's name and folder,
    /// never from what the file holds, since `list_secrets` gives it to agents. At most 200 characters, on one line.
    public static func purpose(file: String, folder: String?) -> String {
        let from: String = folder.map { (folder: String) -> String in "From \(file) in \(folder)" } ?? "From \(file)"
        return StoredSecretName.purpose(fromReason: from)
    }
}

// MARK: - The answer an agent gets

extension SecretSources {
    /// How a copy-in ended, in names and counts only: what `answer(for:)` is built from.
    public enum CopyInOutcome: Equatable, Sendable {
        /// `imported` are the final names stored, `replaced` the ones among them that were keys already.
        case imported([String], replaced: [String], found: Int, format: Format)
        case declined
        case nothingFound(format: Format)
        case unreadable(Unreadable)

        public static func imported(_ names: [String], replaced: [String], from report: SourceReport) -> CopyInOutcome {
            .imported(names, replaced: replaced, found: report.rows.count, format: report.format)
        }
    }

    static let declinedNote = "The user declined, so no key was imported."
    static let nothingFoundNote = "No key was found in it."

    /// An agent's answer for a copy-in: the status, the names imported and replaced, and counts. Nothing else goes in:
    /// no value or part of one, no place in the file, no name that wasn't imported, no path.
    public static func answer(for outcome: CopyInOutcome) -> [String: Any] {
        switch outcome {
        case .imported(let names, let replaced, let found, let format):
            let left: Int = max(0, found - names.count)
            return ["status": "imported", "imported": names, "replaced": replaced, "found": found,
                    "not_imported": left, "format": format.rawValue]
        case .declined:
            return ["status": "declined", "note": declinedNote]
        case .nothingFound(let format):
            return ["status": "nothing_found", "note": nothingFoundNote, "format": format.rawValue]
        case .unreadable(let reason):
            return ["status": "unreadable", "reason": reason.reasonClass]
        }
    }
}

// MARK: - Reading a file

extension SecretSources {
    /// One value as a reader found it, before the rules judge it.
    struct Found {
        var name: String
        var value: String
        var place: String
        var line: Int?
        /// The section it is in: the same name in two is two keys.
        var scope: String = ""
        /// A link the source gives for it, checked before it is kept.
        var link: String?
        var sourceSays = false
        /// False for a JSON number or boolean.
        var isText = true
        /// A reader's own note, kept when the rules give none.
        var note: Note?
        /// A row the reader refuses whole (a credential file), with its kind.
        var refusal: Refusal?
        var kind: String?
        /// It only points at a key kept elsewhere (a `valueFrom`): counted as a reference.
        var reference = false
        /// How a password manager vouches for it; nil for a value judged by its look.
        var managed: Managed?
        /// Its name was made from an item's title or a site.
        var fromTitle = false
    }

    /// How a password manager vouches for a value it holds: taken as it is, never a reference or a setting.
    enum Managed {
        /// A field the manager keeps hidden (Bitwarden's hidden field, 1Password's concealed one), a `bws` secret, or a
        /// password whose item's title names a key: ticked.
        case secret
        /// A website's sign-in password: ticked only when it has a key's shape.
        case login
    }

    /// The format a file is read as. A name ending `.json` or `.jsonc` wins (`.env.json` is JSON), or `.csv`, `.toml`,
    /// `.yaml` or `.yml`; then a `.env` family name, since no `.env` is JSON; then TOML with a table that reads (Cargo's
    /// `credentials`), text that starts as JSON does (past comments), a first line that is a CSV header Next Term
    /// knows, or YAML that nests or starts a document; else the `.env` family. Text that only starts like JSON with no
    /// JSON name is read as a `.env` when it doesn't parse (`read`). A password manager's JSON is told apart once it is
    /// parsed.
    public static func detect(text: String, name: String) -> Format {
        let file: String = (name as NSString).lastPathComponent.lowercased()
        if isJSONName(file) { return .json }
        if file.hasSuffix(".csv") { return .csv }
        if file.hasSuffix(".toml") { return .toml }
        if file.hasSuffix(".yaml") || file.hasSuffix(".yml") { return .yaml }
        if EnvFile.isEnvFile(named: file) || isEnvrc(file) { return .env }
        if looksLikeTOML(text) { return .toml }
        if startsLikeJSON(text) { return .json }
        if startsWithKnownHeader(text) { return .csv }
        return looksLikeYAML(text) ? .yaml : .env
    }

    static func isJSONName(_ file: String) -> Bool { file.hasSuffix(".json") || file.hasSuffix(".jsonc") }

    /// Whether a `.env` has more lines that could set a value (with a `=` or a `:` in them) than `maxValues`: refused
    /// unparsed, as its reader looks up to 200 lines ahead from each quote left open.
    static func hasTooManyLines(_ text: String) -> Bool {
        var lines = 0
        var counted = false
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") {
                counted = false
            } else if !counted, byte == UInt8(ascii: "=") || byte == UInt8(ascii: ":") {
                counted = true
                lines += 1
                if lines > maxValues { return true }
            }
        }
        return false
    }

    static func isEnvrc(_ file: String) -> Bool { file == ".envrc" || file.hasSuffix(".envrc") }

    static func startsLikeJSON(_ text: String) -> Bool {
        var rest = Substring(text)
        while true {
            rest = rest.drop { (character: Character) -> Bool in character.isWhitespace || character == "\u{FEFF}" }
            if rest.hasPrefix("//") {
                rest = rest.drop { (character: Character) -> Bool in character != "\n" }
                continue
            }
            if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return false }
                rest = rest[end.upperBound...]
                continue
            }
            return rest.first == "{" || rest.first == "["
        }
    }

    /// The report for a file's bytes, as `format` or as `detect` says. `name` is the file's name, `folder` its folder's,
    /// for the purpose only; an export's purpose names the app that wrote it instead. A zip archive is read as a
    /// 1Password export (`.1pux`), up to `maxArchiveBytes`; any other file up to `maxBytes`. `stored` names the keys
    /// already in the vault: a row of one of those starts unticked. The bytes are wiped before it returns; the strings
    /// the parse makes can't be, and go with it. A file near the limits can take seconds: the app calls this off the main
    /// thread.
    public static func read(_ bytes: inout [UInt8], name: String, folder: String? = nil, format: Format? = nil,
                            stored: Set<String> = [], now: Date = Date()) -> SourceReport {
        readReport(&bytes, name: name, folder: folder, format: format, stored: stored, now: now, leaving: nil)
    }

    /// `read`, leaving out what `leaving` says the MCP-config import moves, when it is set.
    static func readReport(_ bytes: inout [UInt8], name: String, folder: String?, format: Format?, stored: Set<String>,
                           now: Date, leaving: Leaving?) -> SourceReport {
        defer { SecretBytes.wipe(&bytes) }
        let file: String = (name as NSString).lastPathComponent
        let purpose: String = purpose(file: file, folder: folder)
        if format == nil || format == .onePassword, ZipReader.isZip(bytes) {
            return onePUXReport(bytes, stored: stored, now: now)
        }
        guard bytes.count <= maxBytes else {
            return SourceReport(format: format ?? .env, unreadable: .tooLarge, purpose: purpose)
        }
        guard var text = String(bytes: bytes, encoding: .utf8) else {
            return SourceReport(format: format ?? .env, unreadable: .notText, purpose: purpose)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var chosen: Format = format ?? detect(text: text, name: file)
        if chosen == .csv { return csvReport(text, purpose: purpose, stored: stored, now: now) }
        if chosen == .toml || chosen == .yaml {
            return configReport(text, format: chosen, file: file, purpose: purpose, stored: stored, now: now,
                                leaving: leaving)
        }
        let isManager: Bool = chosen == .bitwarden || chosen == .onePassword || chosen == .bws
        if leaving == nil, chosen == .json || isManager {
            let forced: Format? = chosen == .json ? nil : chosen
            if let managed = managerReport(text, as: forced, stored: stored, now: now) { return managed }
            if forced != nil { return SourceReport(format: chosen, unreadable: .notJSON, purpose: purpose) }
        }
        var found: [Found]?
        var agent: String?
        if chosen == .json {
            let read: ConfigFound? = jsonRead(text, file: file)
            found = read.map { (config: ConfigFound) -> [Found] in leaving?.kept(config.values) ?? config.values }
            agent = leaving?.agent ?? read?.agent
            // Text that only started like JSON (an INI file's `[default]`): its `KEY=value` lines, when it has some.
            let guessed: Bool = format == nil && !isJSONName(file.lowercased())
            if found == nil, guessed, bytes.count <= EnvFile.maxSize, !hasTooManyLines(text) {
                let lines: [Found] = envFound(text, file: file)
                if !lines.isEmpty {
                    chosen = .env
                    found = lines
                }
            }
        } else {
            guard bytes.count <= EnvFile.maxSize else {
                return SourceReport(format: .env, unreadable: .envTooLarge, purpose: purpose)
            }
            guard !hasTooManyLines(text) else { return SourceReport(format: .env, unreadable: .tooMany, purpose: purpose) }
            found = envFound(text, file: file)
        }
        guard let found else { return SourceReport(format: chosen, unreadable: .notJSON, purpose: purpose) }
        guard found.count <= maxValues else { return SourceReport(format: chosen, unreadable: .tooMany, purpose: purpose) }
        return report(found, format: chosen, purpose: purpose, stored: stored, now: now, agent: agent)
    }

    /// The rules run over each value, trimmed (a blank or a line break at either end is a copy's, not the key's), then
    /// the links, then the file's own rules: a name set again, the same name in two sections, and a name already in the
    /// vault.
    static func report(_ found: [Found], format: Format, purpose: String, stored: Set<String>, now: Date,
                       exportedBy: String? = nil, agent: String? = nil, fileNote: Note? = nil) -> SourceReport {
        var rows: [SourceRow] = []
        var notKeys: [NotKey] = []
        var sources: [String?] = []
        var unlinked = Set<Int>()
        for item in found {
            if item.reference {
                notKeys.append(NotKey(name: item.name, place: item.place, reason: .reference))
                continue
            }
            let text: String = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let refusal = item.refusal {
                unlinked.insert(rows.count)
                rows.append(SourceRow(name: item.name, text: text, kind: item.kind ?? "a key", place: item.place,
                                      line: item.line, ticked: false, refusal: refusal, scope: item.scope))
                sources.append(nil)
                continue
            }
            let judged: Classified = item.managed.map { (managed: Managed) -> Classified in
                classifyManaged(name: item.name, value: text, as: managed, now: now)
            } ?? classify(name: item.name, value: text, sourceSays: item.sourceSays, isText: item.isText, now: now)
            switch judged {
            case .none:
                continue
            case .notKey(let reason):
                notKeys.append(NotKey(name: item.name, place: item.place, reason: reason))
            case .row(let kind, let ticked, let note, let refusal):
                let extra: Note? = refusal == nil ? item.note : nil
                let keeps: Bool = extra?.keepsTick ?? true
                rows.append(SourceRow(name: item.name, text: text, kind: kind, place: item.place, line: item.line,
                                      ticked: ticked && keeps, note: note ?? extra, refusal: refusal, scope: item.scope,
                                      fromTitle: item.fromTitle))
                sources.append(item.link)
            }
        }
        rows = linked(rows, sources: sources, unlinked: unlinked)
        rows = settingAgain(rows)
        rows = sectioned(rows)
        rows = replacing(rows, stored: stored)
        return SourceReport(format: format, rows: rows, notKeys: notKeys, purpose: purpose, exportedBy: exportedBy,
                            agent: agent, fileNote: fileNote)
    }

    /// Each row's link: the source's own (`sources`, by row) when it passes the link rules and holds no value in the
    /// file, any row's, in a form masking knows (R3); else the page the value's head or the name suggests. A row in
    /// `unlinked` (a whole credential file) gets none. The vault's values aren't known here: saving checks against them.
    static func linked(_ rows: [SourceRow], sources: [String?], unlinked: Set<Int>) -> [SourceRow] {
        let hasSource: Bool = sources.contains { (text: String?) -> Bool in text != nil }
        let file: SecretMask = hasSource ? mask(of: rows) : SecretMask.empty
        let holds: (String) -> Bool = { (text: String) -> Bool in file.masked(text).count > 0 }
        var result: [SourceRow] = rows
        for index in rows.indices where !unlinked.contains(index) {
            let row: SourceRow = rows[index]
            result[index].link = linkHint(sources[index], value: row.value, name: row.name, holds: holds)
        }
        return result
    }

    /// A mask for the values of `rows`, under a key made for it that goes with it.
    static func mask(of rows: [SourceRow]) -> SecretMask {
        let key = SymmetricKey(size: .bits256)
        let marks: [SecretVault.Mark] = rows.flatMap { (row: SourceRow) -> [SecretVault.Mark] in
            SecretMask.marks(for: row.value, key: key)
        }
        return SecretMask(key: key, marks: marks)
    }

    /// The source's own link when it passes the link rules and `holds` finds no value in it, else the suggested page.
    static func linkHint(_ text: String?, value: SecretBytes, name: String, holds: (String) -> Bool) -> LinkHint? {
        if let text, case .success(let url) = SecretLink.check(text, mask: holds, value: value) { return .source(url) }
        return SecretKeyPages.suggest(value: value, name: name).map { (page: KeyPage) -> LinkHint in .suggested(page) }
    }
}

// MARK: - A name set again, in two sections, or already stored

extension SecretSources {
    /// A name set twice in one section: every row listed, the last ticked (a loader reads the last), each earlier one
    /// unticked with where it is set again.
    static func settingAgain(_ rows: [SourceRow]) -> [SourceRow] {
        var result = rows
        var bySection: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() { bySection[row.scope + "\u{0}" + row.name, default: []].append(index) }
        for indices in bySection.values where indices.count > 1 {
            guard let last = indices.last else { continue }
            for index in indices.dropLast() {
                result[index].ticked = false
                result[index].note = .setAgain(line: rows[last].line, place: rows[last].place)
            }
        }
        return result
    }

    /// A row's position, for grouping rows by value.
    struct Placed: GroupableValue {
        let index: Int
        let value: SecretBytes
        let groupPlace: AnyHashable
    }

    /// The same name in two sections (`production` and `staging`): one row when the values are the same, found in each
    /// place; a key for each value when they differ, named as `NameBook` says. Each section's last row is the one
    /// compared. One pass: each name's rows are sorted by section once.
    static func sectioned(_ rows: [SourceRow]) -> [SourceRow] {
        var result = rows
        var removed = Set<Int>()
        var order: [String] = []
        var byName: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            if byName[row.name] == nil { order.append(row.name) }
            byName[row.name, default: []].append(index)
        }
        var book = NameBook(inFile: Set(order))
        for name in order {
            guard let indices = byName[name] else { continue }
            var sections: [String] = []
            var bySection: [String: [Int]] = [:]
            for index in indices {
                let section: String = rows[index].scope
                if bySection[section] == nil { sections.append(section) }
                bySection[section, default: []].append(index)
            }
            guard sections.count > 1 else { continue }
            let placed: [Placed] = sections.compactMap { (section: String) -> Placed? in
                guard let index = bySection[section]?.last else { return nil }
                return Placed(index: index, value: rows[index].value, groupPlace: AnyHashable(section))
            }
            let groups: [[Placed]] = SecretImport.byValue(placed).map {
                (group: (value: SecretBytes, items: [Placed])) -> [Placed] in group.items
            }
            let leaders: [String] = groups.map { (group: [Placed]) -> String in rows[group[0].index].scope }
            let names: [String] = book.names(for: name, sections: leaders)
            for (position, group) in groups.enumerated() {
                let kept: Int = group[0].index
                for member in group {
                    let section: String = rows[member.index].scope
                    for index in bySection[section] ?? [] { result[index].name = names[position] }
                    guard member.index != kept else { continue }
                    removed.insert(member.index)
                    result[kept].alsoAt.append(rows[member.index].place)
                }
            }
        }
        return result.enumerated().compactMap { (pair: (offset: Int, element: SourceRow)) -> SourceRow? in
            removed.contains(pair.offset) ? nil : pair.element
        }
    }

    /// The names the section rule gives a name's groups, one per section that leads one: the name alone for a single
    /// group; else each with its section's last named part (`production` gives `_PRODUCTION`), or, when those are
    /// missing or repeat, the first with the name alone and the others `_2`, `_3`. A name given is never another name
    /// in the file, nor one given already: it takes the next free number (`_PRODUCTION_2`, or `_3` for `_2`).
    struct NameBook {
        let inFile: Set<String>
        var given: Set<String> = []

        func isFree(_ candidate: String, for name: String) -> Bool {
            !given.contains(candidate) && (candidate == name || !inFile.contains(candidate))
        }

        /// `wanted` when it is free, else it with the first free `_2`, `_3`, …; given from then on.
        mutating func take(_ wanted: String, for name: String) -> String {
            var candidate: String = wanted
            var number = 2
            while !isFree(candidate, for: name) {
                candidate = SecretSources.suffixed(wanted, "_\(number)")
                number += 1
            }
            given.insert(candidate)
            return candidate
        }

        mutating func names(for name: String, sections: [String]) -> [String] {
            guard sections.count > 1 else { return [take(name, for: name)] }
            let labels: [String] = sections.map { (section: String) -> String in SecretSources.sectionLabel(section) }
            let distinct: Bool = Set(labels).count == labels.count && !labels.contains("")
            var names: [String] = []
            var next = 2
            for (offset, label) in labels.enumerated() {
                if distinct {
                    names.append(take(SecretSources.suffixed(name, "_" + label), for: name))
                } else if offset == 0 && isFree(name, for: name) {
                    names.append(take(name, for: name))
                } else {
                    var candidate: String = SecretSources.suffixed(name, "_\(next)")
                    while !isFree(candidate, for: name) {
                        next += 1
                        candidate = SecretSources.suffixed(name, "_\(next)")
                    }
                    next += 1
                    names.append(take(candidate, for: name))
                }
            }
            return names
        }
    }

    /// A section's last part that isn't an index, as a name's part: `production` is PRODUCTION; `env[0]` is ENV.
    static func sectionLabel(_ section: String) -> String {
        let parts: [String] = section.split(separator: ".").map { (part: Substring) -> String in
            String(part.prefix { (character: Character) -> Bool in character != "[" })
        }
        guard let last = parts.last(where: { (part: String) -> Bool in !part.isEmpty }) else { return "" }
        return StoredSecretName.fromParts([last])
    }

    static func suffixed(_ name: String, _ suffix: String) -> String {
        String(name.prefix(StoredSecretName.maxLength - suffix.count)) + suffix
    }

    /// A row named as a key the vault holds starts unticked: "Replaces your key". A row set again further on keeps that
    /// note, which says why it isn't the one read.
    static func replacing(_ rows: [SourceRow], stored: Set<String>) -> [SourceRow] {
        rows.map { (row: SourceRow) -> SourceRow in
            guard stored.contains(row.name), row.refusal == nil else { return row }
            var changed = row
            changed.ticked = false
            if case .setAgain = row.note { return changed }
            changed.note = .replaces
            return changed
        }
    }
}
