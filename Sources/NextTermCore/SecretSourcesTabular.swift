import Foundation

// CSV files for the import, told apart by their header: browsers' saved passwords (Chrome and the other Chromium
// browsers, Firefox, Apple Passwords), password managers' exports (Bitwarden, 1Password, KeePassXC, LastPass), and a
// plain `name,value` (or `key,value`) file. A browser's row is a site's password: it starts unticked unless the
// password has a key's shape, and its name comes from the site, never from a title that names the account. A
// manager's row is ticked too when its title names a key ("Groq token"). Usernames, one-time codes and notes' prose
// are never read.

/// One CSV record by its header's column names, lower-cased; a column it lacks reads as empty.
struct CSVRow {
    let values: [String: String]
    /// The line it starts on, and its place among the records after the header.
    let line: Int
    let index: Int

    subscript(_ column: String) -> String { values[column] ?? "" }
}

extension SecretSources {
    /// The CSVs Next Term knows.
    enum CSVPreset: Equatable, CaseIterable {
        case bitwarden, lastPass, firefox, keePassXC, onePassword, apple, chrome, plain

        /// The app that wrote it, which names the purpose; nil for a plain file.
        var app: String? {
            switch self {
            case .bitwarden: return bitwardenApp
            case .lastPass: return "LastPass"
            case .firefox: return "Firefox"
            case .keePassXC: return "KeePassXC"
            case .onePassword: return onePasswordApp
            case .apple: return "Apple Passwords"
            case .chrome: return "Chrome"
            case .plain: return nil
            }
        }

        /// A browser's rows are site passwords whose title often names the account.
        var isBrowser: Bool { self == .firefox || self == .apple || self == .chrome }
    }

    /// The preset a header's columns pick, the most particular first: Bitwarden by `login_password`, LastPass by
    /// `extra` and `grouping`, Firefox by `httpRealm`, KeePassXC by `TOTP`, 1Password by `Website` or its `Archived`,
    /// `Favorite` and `Tags`, Apple by a `Title` and a `URL`, Chrome by a `name` and a `url`; then `name,value`.
    static func preset(for header: [String]) -> CSVPreset? {
        let columns = Set(header.map(columnName))
        let has: ([String]) -> Bool = { (names: [String]) -> Bool in names.allSatisfy(columns.contains) }
        let login: Bool = has(["username", "password"])
        if has(["login_password", "name", "type"]) { return .bitwarden }
        if login, has(["url", "extra", "name", "grouping"]) { return .lastPass }
        if login, has(["url", "httprealm"]) || has(["url", "formactionorigin"]) { return .firefox }
        if login, has(["title", "url", "totp"]) { return .keePassXC }
        let marked: Bool = has(["url"]) && (has(["archived"]) || has(["favorite"]) || has(["tags"]))
        if login, has(["title"]), has(["website"]) || marked { return .onePassword }
        if login, has(["title", "url"]) { return .apple }
        if login, has(["name", "url"]) { return .chrome }
        if has(["value"]), has(["name"]) || has(["key"]) { return .plain }
        return nil
    }

    static func columnName(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Whether the text's first line is a header Next Term knows: a CSV file whatever its name.
    static func startsWithKnownHeader(_ text: String) -> Bool {
        let first: Substring = text.prefix(4096).prefix { (character: Character) -> Bool in !character.isNewline }
        guard first.contains(","), case .success(let records) = CSVReader.records(String(first)),
              let header = records.first else { return false }
        return preset(for: header.fields) != nil
    }

    /// The report for a CSV file: its preset's rows, or why it can't be read.
    static func csvReport(_ text: String, purpose: String, stored: Set<String>, now: Date) -> SourceReport {
        let records: [CSVReader.Record]
        switch CSVReader.records(text) {
        case .failure(let failure): return SourceReport(format: .csv, unreadable: .csv(failure), purpose: purpose)
        case .success(let read): records = read
        }
        guard let header = records.first else { return SourceReport(format: .csv, purpose: purpose) }
        guard let preset = preset(for: header.fields) else {
            return SourceReport(format: .csv, unreadable: .unknownColumns, purpose: purpose)
        }
        let names: [String] = header.fields.map(columnName)
        var found: [Found] = []
        for (index, record) in records.dropFirst().enumerated() {
            let pairs: [(String, String)] = Array(zip(names, record.fields))
            let values: [String: String] = Dictionary(pairs, uniquingKeysWith: { (first: String, _: String) -> String in
                first
            })
            found += csvFound(CSVRow(values: values, line: record.line, index: index), preset: preset)
            guard found.count <= maxValues else {
                return SourceReport(format: .csv, unreadable: .tooMany, purpose: purpose)
            }
        }
        return report(found, format: .csv, purpose: purpose, stored: stored, now: now, exportedBy: preset.app)
    }
}

// MARK: - Rows by preset

extension SecretSources {
    /// LastPass writes a secure note as a row whose URL is this.
    static let lastPassNote = "http://sn"

    static func csvFound(_ row: CSVRow, preset: CSVPreset) -> [Found] {
        switch preset {
        case .bitwarden:
            return bitwardenCSVFound(row)
        case .plain:
            return plainFound(row)
        case .lastPass:
            if row["url"] == lastPassNote {
                return noteLines(row["extra"], title: row["name"], scope: "rows[\(row.index)]", link: nil)
            }
            return loginFound(row, title: row["name"], address: row["url"], preset: preset)
        case .firefox:
            guard !row["url"].hasPrefix("chrome://") else { return [] }
            return loginFound(row, title: "", address: row["url"], preset: preset)
        case .onePassword:
            guard row["archived"].lowercased() != "true" else { return [] }
            let address: String = row["url"].isEmpty ? row["website"] : row["url"]
            return loginFound(row, title: row["title"], address: address, preset: preset)
        case .keePassXC, .apple:
            return loginFound(row, title: row["title"], address: row["url"], preset: preset)
        case .chrome:
            return loginFound(row, title: row["name"], address: row["url"], preset: preset)
        }
    }

    /// A `name,value` row, read as a `.env` line is, with its link from a `url`, `website` or `login_uri` column.
    static func plainFound(_ row: CSVRow) -> [Found] {
        let label: String = row["name"].isEmpty ? row["key"] : row["name"]
        let trimmed: String = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let addresses: [String] = [row["url"], row["website"], row["login_uri"]].filter { (text: String) -> Bool in
            !text.isEmpty
        }
        return [Found(name: envName(trimmed), value: row["value"], place: "line \(row.line)", line: row.line,
                      link: addresses.first)]
    }

    /// A site's password. A browser's row is named by its site (a title such as Apple's "github.com (name)" names the
    /// account), a manager's by its title. Each row is its own section: two accounts on one site are two keys.
    static func loginFound(_ row: CSVRow, title: String, address: String, preset: CSVPreset) -> [Found] {
        let password: String = row["password"]
        guard !password.isEmpty else { return [] }
        let site: String? = siteName(address)
        let bare: String = String(title.prefix { (character: Character) -> Bool in character != "(" })
            .trimmingCharacters(in: .whitespaces)
        let name: String
        if preset.isBrowser || bare.isEmpty {
            name = site ?? StoredSecretName.fromParts([bare])
        } else {
            name = itemName(title: bare, label: nil).name
        }
        let managed: Managed = !preset.isBrowser && titleSaysKey(bare) ? .secret : .login
        return [Found(name: name, value: password, place: "line \(row.line)", line: row.line,
                      scope: "rows[\(row.index)]", link: firstLink([address]), managed: managed, fromTitle: true)]
    }
}
