import Foundation

// Password managers' exports for the import: Bitwarden's unencrypted JSON export and `bw list items` (the same items),
// 1Password's `op item get --format json` (one item, an array, or items one after another) and its `.1pux` export's
// `export.data`, and Bitwarden Secrets Manager's `bws secret list`. A manager's value is taken as it is: never a
// reference, a placeholder or a setting. What is read: Bitwarden's login password and hidden fields, and `KEY=value`
// lines in a secure note; 1Password's concealed fields and passwords; a `bws` secret's key and value. What never is:
// usernames, one-time-code seeds, password history, cards and identities, notes' free text, and a `bws` note. Each
// export's purpose names its app, never an item's title, a field's label or a note, which agents would see.

extension SecretSources {
    /// The apps that write the exports, as the purpose and the preview name them.
    static let bitwardenApp = "Bitwarden"
    static let onePasswordApp = "1Password"
    static let bwsApp = "Bitwarden Secrets Manager"

    /// What 1Password's CLI prints in a concealed field's place without `--reveal`.
    static let concealedHead = "[use 'op item get"

    /// A value a password manager holds, judged as a value its source calls secret is: listed and ticked, unless a note
    /// says otherwise. A website's password is ticked only with a key's shape: most are site passwords.
    static func classifyManaged(name: String, value: String, as managed: Managed, now: Date) -> Classified {
        guard !value.isEmpty else { return .none }
        if value.hasPrefix(concealedHead) { return .notKey(.concealed) }
        let shaped: String? = SecretImport.tokenKind(value) ?? providerKind(value)
        let plain: String = managed == .login ? "a website password" : "a secret, by its source"
        let kind: String = shaped ?? plain
        if let refusal = storageRefusal(value) { return .row(kind: kind, ticked: false, note: nil, refusal: refusal) }
        if managed == .login, shaped == nil {
            return .row(kind: kind, ticked: false, note: .websitePassword, refusal: nil)
        }
        let note: Note? = untickingNote(name: name, value: value, now: now)
        return .row(kind: kind, ticked: note == nil, note: note, refusal: nil)
    }

    /// Words in an item's title that say its password is a key: "Groq token", "OpenAI API".
    static let keyTitleWords: Set<String> = ["API", "APIKEY", "APITOKEN", "TOKEN", "KEY"]

    /// Whether an item's title names a key, by its words (`Monkey` and `Keycloak` don't). Inside a word of several
    /// parts, API and TOKEN still count (`GroqApiKey`), but KEY alone is a part of a name (`KeyBank`, `YubiKey`).
    static func titleSaysKey(_ title: String) -> Bool {
        let words: [Substring] = title.split { (character: Character) -> Bool in
            !(character.isLetter || character.isNumber)
        }
        return words.contains { (word: Substring) -> Bool in
            let segments: [String] = SecretName.segments(of: String(word))
            let named: [String] = segments.compactMap(keyTitleWord)
            guard segments.count > 1 else { return !named.isEmpty }
            return named.contains { (keyWord: String) -> Bool in keyWord != "KEY" }
        }
    }

    /// The key word a title's segment is, one or several (`TOKENS` is TOKEN); nil for any other.
    static func keyTitleWord(_ segment: String) -> String? {
        if keyTitleWords.contains(segment) { return segment }
        let single: String = segment.count > 1 && segment.hasSuffix("S") ? String(segment.dropLast()) : segment
        return keyTitleWords.contains(single) ? single : nil
    }

    /// A key's name from an item's title and, for a field other than the item's own password, its label: the label
    /// when it is a key's name already (`LINEAR_API_KEY`), else the title alone or with the label (`fromParts`).
    static func itemName(title: String, label: String?) -> (name: String, fromTitle: Bool) {
        if let label, StoredSecretName.isValid(label) { return (label, false) }
        if label == nil, StoredSecretName.isValid(title) { return (title, true) }
        let parts: [String] = [title] + (label.map { (label: String) -> [String] in [label] } ?? [])
        return (StoredSecretName.fromParts(parts), true)
    }

    /// A site's name for a key's: its host without `www.` and its last label (`api.example.com` is API_EXAMPLE).
    static func siteName(_ address: String) -> String? {
        let full: String = address.contains("://") ? address : "https://" + address
        guard var host = URLComponents(string: full)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var labels: [String] = host.split(separator: ".").map(String.init)
        if labels.count > 1 { labels.removeLast() }
        guard !labels.isEmpty else { return nil }
        return StoredSecretName.fromParts([labels.joined(separator: ".")])
    }

    /// The first of an item's addresses that passes the link rules, before the file's own values are known (`linked`
    /// checks it again with them).
    static func firstLink(_ addresses: [String]) -> String? {
        addresses.first { (address: String) -> Bool in
            if case .success = SecretLink.check(address, mask: { (_: String) -> Bool in false }, value: nil) {
                return true
            }
            return false
        }
    }

    /// `KEY=value` lines in an item's notes, read as a `.env` line is (dotenv's way, with no `KEY: value`: notes are
    /// prose), each judged by its look and marked with the item's `note` (one that asks for the master password again).
    /// Lines of prose are skipped by the reader.
    static func noteLines(_ notes: String, title: String, scope: String, link: String?, note: Note? = nil) -> [Found] {
        EnvFile.parse(notes, interpolating: false).map { (entry: EnvEntry) -> Found in
            Found(name: envName(entry.key), value: entry.value, place: "\(title) \u{203A} notes, line \(entry.line)",
                  line: nil, scope: scope, link: link, note: note)
        }
    }
}

// MARK: - Which manager wrote it

extension SecretSources {
    /// The members of a Bitwarden item that say what it is: every item holds one, custom fields or not.
    static let bitwardenParts = ["login", "secureNote", "card", "identity", "fields", "sshKey"]

    /// The member names a manager's JSON holds, one at least: text with none of them is read as any JSON, unparsed
    /// here. `managerShape` decides on the parsed members.
    static let managerMembers: [String] = (["items", "accounts", "projectId", "encrypted"] + bitwardenParts).map {
        (member: String) -> String in "\"" + member + "\""
    }

    /// The report for a password manager's JSON, or nil when `forced` is nil and the text isn't one's. With a format
    /// forced (`--from bitwarden`), text that isn't that app's export is refused with its name.
    static func managerReport(_ text: String, as forced: Format?, stored: Set<String>, now: Date) -> SourceReport? {
        let likely: Bool = managerMembers.contains { (member: String) -> Bool in text.contains(member) }
        guard forced != nil || likely else { return nil }
        guard let documents = jsonDocuments(text) else {
            return forced.map { (format: Format) -> SourceReport in refused(.notJSON, as: format) }
        }
        let shape: Format? = managerShape(documents, forced: forced)
        guard let format = forced ?? shape else { return nil }
        // An empty list is what `bws secret list` and `bw list items` print for an empty vault.
        let empty: Bool = documents.count == 1 && (documents[0] as? [Any])?.isEmpty == true
        guard shape == format || empty else { return refused(.notAnExport(from: app(of: format)), as: format) }
        return managerReport(documents, format: format, stored: stored, now: now)
    }

    /// The rows of a parsed manager export, or its refusal.
    static func managerReport(_ documents: [Any], format: Format, stored: Set<String>, now: Date) -> SourceReport {
        let found: [Found]
        switch format {
        case .bitwarden:
            if isEncryptedBitwarden(documents) { return refused(.encryptedExport, as: format) }
            found = bitwardenFound(bitwardenItems(documents))
        case .onePassword:
            found = onePasswordFound(documents)
        default:
            found = bwsFound(documents.first as? [Any] ?? [])
        }
        guard found.count <= maxValues else { return refused(.tooMany, as: format) }
        return report(found, format: format, purpose: "", stored: stored, now: now, exportedBy: app(of: format))
    }

    static func refused(_ reason: Unreadable, as format: Format) -> SourceReport {
        SourceReport(format: format, unreadable: reason, purpose: "", exportedBy: app(of: format))
    }

    static func app(of format: Format) -> String {
        switch format {
        case .onePassword: return onePasswordApp
        case .bws: return bwsApp
        default: return bitwardenApp
        }
    }

    /// Which manager's JSON the documents are, by their members: Bitwarden's export by `encrypted` with its sealed
    /// form's members or items that are all Bitwarden's, `bw list items` by such items alone; 1Password's `.1pux` data
    /// by its accounts' vaults, `op item get` by items with a `category` and `op`'s fields, one concealed at least
    /// (with `--from 1password`, none needed); `bws` by secrets with a `key`, a `value` and a `projectId`.
    static func managerShape(_ documents: [Any], forced: Format? = nil) -> Format? {
        if documents.count == 1, let object = documents[0] as? [String: Any] {
            if isBitwardenExport(object) { return .bitwarden }
            if let accounts = object["accounts"] as? [[String: Any]], accounts.contains(where: hasVaults) {
                return .onePassword
            }
        }
        let objects: [[String: Any]] = documents.flatMap { (document: Any) -> [[String: Any]] in
            (document as? [[String: Any]]) ?? (document as? [String: Any]).map { [$0] } ?? []
        }
        guard !objects.isEmpty, objects.count == documents.flatMap(elements).count else { return nil }
        let opItems: Bool = objects.allSatisfy(isOpItem)
        let concealed: Bool = forced == .onePassword || objects.contains(where: holdsConcealed)
        if opItems, concealed { return .onePassword }
        if documents.count == 1, documents[0] is [Any] {
            if objects.allSatisfy(isBwsSecret) { return .bws }
            if objects.allSatisfy(isBitwardenItem) { return .bitwarden }
        }
        return nil
    }

    /// Bitwarden's `.json` export: sealed by the account's key (`encKeyValidation_DO_NOT_EDIT`) or a password
    /// (`passwordProtected` with its `data`), or open with `items` that are all Bitwarden's.
    static func isBitwardenExport(_ object: [String: Any]) -> Bool {
        guard object["encrypted"] is Bool else { return false }
        if object["encKeyValidation_DO_NOT_EDIT"] is String { return true }
        if object["passwordProtected"] as? Bool == true, object["data"] is String { return true }
        guard let items = object["items"] as? [[String: Any]] else { return false }
        return items.allSatisfy(isBitwardenItem)
    }

    static func elements(_ document: Any) -> [Any] { (document as? [Any]) ?? [document] }

    static func hasVaults(_ account: [String: Any]) -> Bool { account["vaults"] is [Any] }

    /// An `op` item: a `category`, and fields that each have an `id` and a `type`, as `op` writes them.
    static func isOpItem(_ object: [String: Any]) -> Bool {
        guard object["category"] is String, let fields = object["fields"] as? [[String: Any]] else { return false }
        return fields.allSatisfy { (field: [String: Any]) -> Bool in field["id"] is String && field["type"] is String }
    }

    /// Whether an `op` item has a field 1Password keeps concealed.
    static func holdsConcealed(_ object: [String: Any]) -> Bool {
        let fields: [[String: Any]] = object["fields"] as? [[String: Any]] ?? []
        return fields.contains(where: isOpSecret)
    }

    /// A concealed field, or the item's password.
    static func isOpSecret(_ field: [String: Any]) -> Bool {
        field["type"] as? String == "CONCEALED" || field["purpose"] as? String == "PASSWORD"
    }

    static func isBwsSecret(_ object: [String: Any]) -> Bool {
        object["key"] is String && object["value"] != nil && object["projectId"] != nil
    }

    static func isBitwardenItem(_ object: [String: Any]) -> Bool {
        let typed: Bool = object["type"] is NSNumber && object["name"] is String
        let parts: Bool = bitwardenParts.contains { (part: String) -> Bool in object[part] != nil }
        return typed && (parts || object["object"] as? String == "item")
    }
}

// MARK: - JSON documents one after another

extension SecretSources {
    /// The JSON values in the text: one, or several one after another (as `op item get -` may print items), each parsed
    /// by Foundation's reader. Nil when any of them isn't JSON. The copies of the bytes are wiped once read.
    static func jsonDocuments(_ text: String) -> [Any]? {
        var bytes: [UInt8] = Array(text.utf8)
        defer { SecretBytes.wipe(&bytes) }
        var documents: [Any] = []
        for range in topLevelRanges(bytes) {
            var piece: [UInt8] = Array(bytes[range])
            defer { SecretBytes.wipe(&piece) }
            let parsed: Any? = piece.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Any? in
                guard let base = buffer.baseAddress else { return nil }
                let data = Data(bytesNoCopy: base, count: buffer.count, deallocator: .none)
                return try? JSONSerialization.jsonObject(with: data)
            }
            guard let parsed else { return nil }
            documents.append(parsed)
        }
        return documents.isEmpty ? nil : documents
    }

    /// Where each top-level object or array starts and ends, by its brackets outside strings. Text between them other
    /// than blanks makes the whole text no JSON: one empty range is given, which won't parse.
    static func topLevelRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var depth = 0
        var start = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                guard depth > 0 else { return [0..<0] }
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if depth == 0 { start = index }
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                guard depth >= 0 else { return [0..<0] }
                if depth == 0 { ranges.append(start..<(index + 1)) }
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                continue
            default:
                guard depth > 0 else { return [0..<0] }
            }
        }
        return depth == 0 ? ranges : [0..<0]
    }
}

// MARK: - Bitwarden

extension SecretSources {
    /// Bitwarden's item types the import reads (logins and secure notes), and its hidden field's type.
    static let bitwardenLogin = 1
    static let bitwardenNote = 2
    static let bitwardenHidden = 1

    /// An export sealed by the account's key (`encrypted`) or a password (`passwordProtected`).
    static func isEncryptedBitwarden(_ documents: [Any]) -> Bool {
        guard let object = documents.first as? [String: Any] else { return false }
        return object["encrypted"] as? Bool == true || object["passwordProtected"] as? Bool == true
    }

    /// The export's `items`, or `bw list items`' array.
    static func bitwardenItems(_ documents: [Any]) -> [[String: Any]] {
        if let object = documents.first as? [String: Any] { return object["items"] as? [[String: Any]] ?? [] }
        return documents.first as? [[String: Any]] ?? []
    }

    static func bitwardenFound(_ items: [[String: Any]]) -> [Found] {
        var found: [Found] = []
        for (index, item) in items.enumerated() {
            guard found.count <= maxValues else { break }
            found += bitwardenItemFound(item, scope: "items[\(index)]")
        }
        return found
    }

    /// One login's password, named by its title, and the hidden fields of a login or a note; a note's `KEY=value`
    /// lines. The first of the login's addresses that passes the link rules links them all. An item that asks for the
    /// master password again starts unticked.
    static func bitwardenItemFound(_ item: [String: Any], scope: String) -> [Found] {
        let type: Int = (item["type"] as? NSNumber)?.intValue ?? 0
        guard type == bitwardenLogin || type == bitwardenNote, !(item["deletedDate"] is String) else { return [] }
        let title: String = item["name"] as? String ?? ""
        let login: [String: Any] = item["login"] as? [String: Any] ?? [:]
        let uris: [String] = (login["uris"] as? [[String: Any]] ?? []).compactMap { (uri: [String: Any]) -> String? in
            uri["uri"] as? String
        }
        let link: String? = firstLink(uris)
        let note: Note? = (item["reprompt"] as? NSNumber)?.intValue == 1 ? .reprompt : nil
        var found: [Found] = []
        if type == bitwardenLogin, let password = login["password"] as? String {
            let named: (name: String, fromTitle: Bool) = itemName(title: title, label: nil)
            let managed: Managed = titleSaysKey(title) ? .secret : .login
            found.append(Found(name: named.name, value: password, place: "\(title) \u{203A} password", line: nil,
                               scope: scope, link: link, note: note, managed: managed, fromTitle: named.fromTitle))
        }
        for field in item["fields"] as? [[String: Any]] ?? [] {
            guard (field["type"] as? NSNumber)?.intValue == bitwardenHidden, let value = field["value"] as? String
            else { continue }
            let label: String = field["name"] as? String ?? ""
            let named: (name: String, fromTitle: Bool) = itemName(title: title, label: label)
            found.append(Found(name: named.name, value: value, place: "\(title) \u{203A} \(label)", line: nil,
                               scope: scope, link: link, note: note, managed: .secret, fromTitle: named.fromTitle))
        }
        if type == bitwardenNote, let notes = item["notes"] as? String {
            found += noteLines(notes, title: title, scope: scope, link: link, note: note)
        }
        return found
    }

    /// One row of Bitwarden's `.csv` export: a login's password as the JSON's, a note's `KEY=value` lines, and its
    /// custom fields (`name: value` lines, which the CSV writes without saying which were hidden), each by its look.
    static func bitwardenCSVFound(_ row: CSVRow) -> [Found] {
        let title: String = row["name"]
        let scope = "rows[\(row.index)]"
        let link: String? = firstLink(row["login_uri"].split(separator: ",").map(String.init))
        let note: Note? = row["reprompt"] == "1" ? .reprompt : nil
        var found: [Found] = []
        let password: String = row["login_password"]
        if row["type"] == "login", !password.isEmpty {
            let named: (name: String, fromTitle: Bool) = itemName(title: title, label: nil)
            let managed: Managed = titleSaysKey(title) ? .secret : .login
            found.append(Found(name: named.name, value: password, place: "line \(row.line), \(title)", line: row.line,
                               scope: scope, link: link, note: note, managed: managed, fromTitle: named.fromTitle))
        }
        for field in row["fields"].split(whereSeparator: \.isNewline) {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let label = String(field[..<colon]).trimmingCharacters(in: .whitespaces)
            let named: (name: String, fromTitle: Bool) = itemName(title: title, label: label)
            let value = String(field[field.index(after: colon)...])
            found.append(Found(name: named.name, value: value, place: "line \(row.line), \(title) \u{203A} \(label)",
                               line: row.line, scope: scope, link: link, note: note, fromTitle: named.fromTitle))
        }
        if row["type"] == "note" {
            found += noteLines(row["notes"], title: title, scope: scope, link: link, note: note)
        }
        return found
    }
}

// MARK: - 1Password

extension SecretSources {
    /// 1Password's categories the import reads, by their `.1pux` number and their `op` name: Login, Password, API
    /// Credential, Database, and Secure Note (its concealed fields). Cards, identities and the rest are never read.
    static let onePasswordCategories: [String: String] = [
        "001": "LOGIN", "005": "PASSWORD", "112": "API_CREDENTIAL", "102": "DATABASE", "003": "SECURE_NOTE",
    ]

    /// `op item get` items (one, an array, or one after another), or a `.1pux` export's data.
    static func onePasswordFound(_ documents: [Any]) -> [Found] {
        if documents.count == 1, let object = documents[0] as? [String: Any],
           let accounts = object["accounts"] as? [[String: Any]] {
            return onePUXFound(accounts)
        }
        let items: [[String: Any]] = documents.flatMap(elements).compactMap { (item: Any) -> [String: Any]? in
            item as? [String: Any]
        }
        var found: [Found] = []
        for (index, item) in items.enumerated() where found.count <= maxValues {
            found += opItemFound(item, scope: "items[\(index)]")
        }
        return found
    }

    /// An `op` item's concealed fields and its password, linked by its primary website first. Only an active item is
    /// read: `op` writes a `state` (`ARCHIVED`, `DELETED`) on any other, as `--include-archive` lists them.
    static func opItemFound(_ item: [String: Any], scope: String) -> [Found] {
        let state: String = (item["state"] as? String ?? "").uppercased()
        guard state.isEmpty || state == "ACTIVE" else { return [] }
        guard let category = item["category"] as? String, onePasswordCategories.values.contains(category) else {
            return []
        }
        let title: String = item["title"] as? String ?? ""
        let urls: [[String: Any]] = item["urls"] as? [[String: Any]] ?? []
        let primary: [[String: Any]] = urls.filter { (url: [String: Any]) -> Bool in url["primary"] as? Bool == true }
        let addresses: [String] = (primary + urls).compactMap { (url: [String: Any]) -> String? in
            url["href"] as? String
        }
        let link: String? = firstLink(addresses)
        var found: [Found] = []
        for field in item["fields"] as? [[String: Any]] ?? [] {
            let purpose: String? = field["purpose"] as? String
            guard isOpSecret(field), let value = field["value"] as? String else { continue }
            let id: String = field["id"] as? String ?? ""
            let label: String = field["label"] as? String ?? id
            let main: Bool = purpose == "PASSWORD" || id == "credential" || id == "password"
            let website: Bool = category == "LOGIN" && purpose == "PASSWORD"
            found.append(onePasswordField(value, title: title, label: label, main: main, website: website,
                                          scope: scope, link: link))
        }
        return found
    }

    /// A `.1pux` export's active items, in every account and vault.
    static func onePUXFound(_ accounts: [[String: Any]]) -> [Found] {
        var found: [Found] = []
        var index = 0
        for account in accounts {
            for vault in account["vaults"] as? [[String: Any]] ?? [] {
                for item in vault["items"] as? [[String: Any]] ?? [] {
                    guard found.count <= maxValues else { return found }
                    found += onePUXItemFound(item, scope: "items[\(index)]")
                    index += 1
                }
            }
        }
        return found
    }

    /// An item's login password fields, its own password (a Password item's), and its sections' concealed fields,
    /// linked by its website. An archived item is skipped.
    static func onePUXItemFound(_ item: [String: Any], scope: String) -> [Found] {
        let state: String = item["state"] as? String ?? "active"
        guard state == "active", let number = item["categoryUuid"] as? String,
              let category = onePasswordCategories[number] else { return [] }
        let overview: [String: Any] = item["overview"] as? [String: Any] ?? [:]
        let details: [String: Any] = item["details"] as? [String: Any] ?? [:]
        let title: String = overview["title"] as? String ?? ""
        let listed: [[String: Any]] = overview["urls"] as? [[String: Any]] ?? []
        let others: [String] = listed.compactMap { (url: [String: Any]) -> String? in url["url"] as? String }
        let first: [String] = (overview["url"] as? String).map { (url: String) -> [String] in [url] } ?? []
        let link: String? = firstLink(first + others)
        var found: [Found] = []
        for field in details["loginFields"] as? [[String: Any]] ?? [] {
            let designation: String? = field["designation"] as? String
            let password: Bool = designation == "password" || field["fieldType"] as? String == "P"
            guard password, let value = field["value"] as? String else { continue }
            let label: String = field["name"] as? String ?? "password"
            found.append(onePasswordField(value, title: title, label: label, main: designation == "password",
                                          website: category == "LOGIN", scope: scope, link: link))
        }
        if let password = details["password"] as? String {
            found.append(onePasswordField(password, title: title, label: "password", main: true, website: false,
                                          scope: scope, link: link))
        }
        for section in details["sections"] as? [[String: Any]] ?? [] {
            for field in section["fields"] as? [[String: Any]] ?? [] {
                guard let value = (field["value"] as? [String: Any])?["concealed"] as? String else { continue }
                let id: String = field["id"] as? String ?? ""
                let label: String = field["title"] as? String ?? id
                let main: Bool = id == "credential" || id == "password"
                found.append(onePasswordField(value, title: title, label: label, main: main, website: false,
                                              scope: scope, link: link))
            }
        }
        return found
    }

    /// One 1Password field: the item's own password or credential is named by the item's title, another by its label
    /// (or the title and the label). A website's password is ticked only with a key's shape, or a title that names one.
    static func onePasswordField(_ value: String, title: String, label: String, main: Bool, website: Bool,
                                 scope: String, link: String?) -> Found {
        let named: (name: String, fromTitle: Bool) = itemName(title: title, label: main ? nil : label)
        let managed: Managed = website && !titleSaysKey(title) ? .login : .secret
        return Found(name: named.name, value: value, place: "\(title) \u{203A} \(label)", line: nil, scope: scope,
                     link: link, managed: managed, fromTitle: named.fromTitle)
    }
}

// MARK: - Bitwarden Secrets Manager, and the 1Password archive

extension SecretSources {
    /// `bws secret list`: each secret's key and value, ticked, since every one is a secret. Its note is free text and
    /// never read. A project is a section: the same key in two projects with two values is two keys.
    static func bwsFound(_ secrets: [Any]) -> [Found] {
        var projects: [String: Int] = [:]
        var found: [Found] = []
        for case let secret as [String: Any] in secrets {
            guard found.count <= maxValues else { break }
            guard let key = secret["key"] as? String, let value = secret["value"] as? String else { continue }
            let project: String = secret["projectId"] as? String ?? ""
            let number: Int = projects[project] ?? projects.count
            projects[project] = number
            let name: String = StoredSecretName.isValid(key) ? key : StoredSecretName.fromParts([key])
            found.append(Found(name: name, value: value, place: key, line: nil, scope: "projects[\(number)]",
                               managed: .secret))
        }
        return found
    }

    /// A `.1pux` export: its `export.data`, read in memory from the archive and wiped once parsed. Attachments under
    /// `files/` are never read.
    static func onePUXReport(_ bytes: [UInt8], stored: Set<String>, now: Date) -> SourceReport {
        guard bytes.count <= maxArchiveBytes else { return refused(.archive(.tooLarge), as: .onePassword) }
        let notOne: Unreadable = .notAnExport(from: onePasswordApp)
        switch ZipReader.entry("export.data", in: bytes) {
        case .failure(.missing):
            return refused(notOne, as: .onePassword)
        case .failure(let failure):
            return refused(.archive(failure), as: .onePassword)
        case .success(var data):
            defer { SecretBytes.wipe(&data) }
            guard let text = String(bytes: data, encoding: .utf8), let documents = jsonDocuments(text),
                  managerShape(documents) == .onePassword else { return refused(notOne, as: .onePassword) }
            return managerReport(documents, format: .onePassword, stored: stored, now: now)
        }
    }
}
