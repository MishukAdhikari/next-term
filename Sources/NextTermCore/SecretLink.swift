import CryptoKit
import Foundation

/// The rules for a key's "Where it came from" link: the provider's page where the key was made and is revoked. One
/// check, run when the link is typed, when the vault is read for a row, and again just before it opens. Only the
/// user's hands set a link; Next Term never fetches it, and opening it is the browser's job.
///
/// In order, stopping at the first refusal:
/// 1. trimmed, one address with no space or control character, at most 2048 characters;
/// 2. `https`, or `http` only to this Mac; no user or password; a plain ASCII host with no `xn--` label; no `.` or `..`
///    step in the path; then `SafeWebLink.isAllowed`, the gate every web link Next Term opens passes;
/// 3. no token shape masking knows (`MCPRedaction.tokens`), as typed, as stored or percent-decoded;
/// 4. no stored value (`mask`, which the app gives as the current mask's finder), and not the value being saved;
/// 5. no query or fragment parameter whose name is a secret's (`SecretName.isSecret`: `token`, `api_key`,
///    `access_token`, but not `authuser`), or is `sig`, `signature`, `code` or `key`.
///
/// A key in the link says so ahead of its parameter's name: `?token=` and a token's shape is "can't hold a key".
public enum SecretLink {
    public static let maxLength = 2048

    /// What a stored link that fails the rules shows in place of its host. It stays editable.
    public static let cantOpen = "This link can\u{2019}t be opened."

    /// Why a link was refused: one plain sentence each, shown under the field.
    public enum Refusal: Error, Equatable, Sendable, CaseIterable, LocalizedError {
        case notALink
        case tooLong
        case scheme
        case userOrPassword
        case host
        case path
        case secretParameter
        case holdsAKey

        public var sentence: String {
            switch self {
            case .notALink: return "Type one web address, starting with https://."
            case .tooLong: return "A link has at most 2,048 characters."
            case .scheme: return "Only https, or http to this Mac."
            case .userOrPassword: return "A link can\u{2019}t hold a user name or password."
            case .host: return "A link\u{2019}s host can use only a\u{2013}z, 0\u{2013}9, dots and hyphens, with no xn-- part."
            case .path: return "A link\u{2019}s path can\u{2019}t hold a . or .. step."
            case .secretParameter: return "A link can\u{2019}t carry a token, key or password after its ? or #."
            case .holdsAKey: return "A link can\u{2019}t hold a key."
            }
        }

        public var errorDescription: String? { sentence }
    }

    /// The link to keep and open, or why not. `mask` says whether a text holds a stored key's value; `value` is the key
    /// being saved with the link, looked for in each form masking knows, when it has 12 bytes or more (as masking
    /// looks for no shorter value).
    public static func check(_ text: String, mask: (String) -> Bool, value: SecretBytes?) -> Result<URL, Refusal> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        switch parsed(typed) {
        case .success(let parsedURL): url = parsedURL
        case .failure(let refusal): return .failure(refusal)
        }
        let written = url.absoluteString
        let decoded = written.removingPercentEncoding ?? written
        var texts: [String] = [typed]
        for candidate in [written, decoded] where !texts.contains(candidate) { texts.append(candidate) }
        let shaped = texts.contains { (candidate: String) -> Bool in holdsTokenShape(candidate) }
        let stored = texts.contains { (candidate: String) -> Bool in mask(candidate) }
        let own: Bool = value.map { (value: SecretBytes) -> Bool in holds(value, in: texts) } ?? false
        if shaped || stored || own { return .failure(.holdsAKey) }
        if hasSecretParameter(url) { return .failure(.secretParameter) }
        return .success(url)
    }

    /// What the link's button and the Page column name: its host, lower-cased, and its port when it has one
    /// (`platform.openai.com`, `localhost:3000`).
    public static func host(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = parts.percentEncodedHost, let host = SafeWebLink.checkedHost(raw) else { return nil }
        guard let port = parts.port else { return host }
        return host + ":" + String(port)
    }

    /// The bytes of vault.json Next Term vouches for: what it last wrote, or last read and MAC-checked in an unlock.
    /// Lists read the index with no MAC check, and any process of the user's can write the file, so a link opens with
    /// no unlock only while the file's bytes are still these.
    public struct Vouch: Equatable, Sendable {
        private let digest: Data

        public init(file: Data) {
            digest = Data(SHA256.hash(data: file))
        }

        public func covers(_ file: Data) -> Bool {
            Vouch(file: file) == self
        }
    }
}

// MARK: - The address

extension SecretLink {
    /// The address checked and tidied: the scheme and host lower-cased, letters from another script in the path, query
    /// or fragment percent-encoded, and `https://` before a bare host with a dot (`dashboard.example.com/apikeys`).
    static func parsed(_ typed: String) -> Result<URL, Refusal> {
        guard !typed.isEmpty else { return .failure(.notALink) }
        guard typed.unicodeScalars.count <= maxLength else { return .failure(.tooLong) }
        let isAddress = typed.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in isAddressScalar(scalar) }
        guard isAddress else { return .failure(.notALink) }
        let scheme: Substring? = SafeWebLink.schemeWritten(in: typed)
        if let scheme {
            guard SafeWebLink.schemes.contains(scheme.lowercased()) else { return .failure(.scheme) }
            guard typed.dropFirst(scheme.count + 1).hasPrefix("//") else { return .failure(.notALink) }
        }
        let full: String = scheme == nil ? "https://" + typed : typed
        guard let start = full.range(of: "://")?.upperBound else { return .failure(.notALink) }
        let end = full[start...].firstIndex { (character: Character) -> Bool in "/?#".contains(character) } ?? full.endIndex
        let authority = full[start..<end]
        guard !authority.contains("@") else { return .failure(.userOrPassword) }
        let asciiHost = authority.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in scalar.isASCII }
        guard asciiHost else { return .failure(.host) }
        guard let rest = String(full[end...]).addingPercentEncoding(withAllowedCharacters: restCharacters) else {
            return .failure(.notALink)
        }
        let encoded = String(full[..<end]) + rest
        guard encoded.utf8.count <= maxLength else { return .failure(.tooLong) }
        guard let parts = URLComponents(string: encoded) else { return .failure(.notALink) }
        return checked(parts, bare: scheme == nil)
    }

    /// The parts read back: no user or password, a host a link may name, a port from 1 to 65535, `http` only to this
    /// Mac, a path that never steps out; then the address written again from them and passed through
    /// `SafeWebLink.isAllowed`.
    private static func checked(_ parts: URLComponents, bare: Bool) -> Result<URL, Refusal> {
        guard parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil else {
            return .failure(.userOrPassword)
        }
        guard let scheme = parts.scheme?.lowercased(), let raw = parts.percentEncodedHost, !raw.isEmpty else {
            return .failure(.notALink)
        }
        guard raw != "0.0.0.0", let host = SafeWebLink.checkedHost(raw) else { return .failure(.host) }
        let named: Bool = host.contains(".") || host == "localhost" || host == "[::1]"
        guard SafeWebLink.isPort(parts.port), !bare || named else { return .failure(.notALink) }
        guard SafeWebLink.mayOpen(scheme: scheme, host: host) else { return .failure(.scheme) }
        let path = parts.percentEncodedPath
        guard !SafeWebLink.isUnsafe(path: path) else { return .failure(.path) }
        var written = scheme + "://" + host
        if let port = parts.port { written += ":" + String(port) }
        written += path
        if let query = parts.percentEncodedQuery { written += "?" + query }
        if let fragment = parts.percentEncodedFragment { written += "#" + fragment }
        guard written.utf8.count <= maxLength else { return .failure(.tooLong) }
        guard let url = URL(string: written), SafeWebLink.isAllowed(url) else { return .failure(.notALink) }
        return .success(url)
    }

    /// A character an address may hold as typed: no space, control or invisible formatting character (a direction
    /// override could make a link read as another).
    static func isAddressScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value <= 0x20 || value == 0x7F { return false }
        if value < 0x80 { return true }
        let invisible: Bool = invisibleCategories.contains(scalar.properties.generalCategory)
        return !invisible && !scalar.properties.isWhitespace
    }

    private static let invisibleCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator,
    ]

    /// What a path, query or fragment keeps as typed: printable ASCII but the characters a URL never holds raw, which
    /// are percent-encoded with any letter from another script.
    private static let restCharacters: CharacterSet = {
        let printable = CharacterSet(charactersIn: Unicode.Scalar(UInt8(0x21))...Unicode.Scalar(UInt8(0x7E)))
        return printable.subtracting(CharacterSet(charactersIn: #""<>\^`{|}[]"#))
    }()
}

// MARK: - Keys in a link

extension SecretLink {
    /// Parameter names refused although no secret word is in them: a signature, an OAuth code, a bare key.
    static let refusedNames: Set<String> = ["sig", "signature", "code", "key"]

    /// Whether the query or the fragment names a parameter as a secret's. Both are read as `name=value` pieces split at
    /// `&`, `;` and `?`, so a hash route's own query (`#/keys?token=…`) and OAuth's `#access_token=…` are read too. A
    /// piece with no `=` (`#/settings/api-keys`) names nothing.
    static func hasSecretParameter(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        let places: [String] = [parts.percentEncodedQuery, parts.percentEncodedFragment].compactMap { $0 }
        return places.contains { (place: String) -> Bool in
            parameterNames(in: place).contains { (name: String) -> Bool in isSecretParameter(name) }
        }
    }

    static func parameterNames(in text: String) -> [String] {
        let pieces = text.split { (character: Character) -> Bool in "&;?".contains(character) }
        return pieces.compactMap { (piece: Substring) -> String? in
            guard let equals = piece.firstIndex(of: "=") else { return nil }
            let raw = String(piece[..<equals])
            return raw.removingPercentEncoding ?? raw
        }
    }

    static func isSecretParameter(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return refusedNames.contains(trimmed.lowercased()) || SecretName.isSecret(trimmed)
    }

    /// Whether a text holds a token shape masking hides.
    static func holdsTokenShape(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return MCPRedaction.tokens.contains { (token: NSRegularExpression) -> Bool in
            token.firstMatch(in: text, range: range) != nil
        }
    }

    /// Whether any of `texts` holds `value`, trimmed as the vault stores it, in a form masking knows: as stored, base64,
    /// base64url or percent-encoded. A value under 12 bytes is not looked for. The forms are wiped after.
    static func holds(_ value: SecretBytes, in texts: [String]) -> Bool {
        let trimmed: SecretBytes = (try? SecretVault.normalized(value, name: "LINK")) ?? value
        guard trimmed.count >= SecretMask.minimumLength else { return false }
        var forms: [[UInt8]] = trimmed.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [[UInt8]] in
            SecretMask.forms(of: [UInt8](buffer))
        }
        defer { for index in forms.indices { SecretBytes.wipe(&forms[index]) } }
        return texts.contains { (text: String) -> Bool in
            let bytes = Array(text.utf8)
            return forms.contains { (form: [UInt8]) -> Bool in contains(bytes, form) }
        }
    }

    private static func contains(_ bytes: [UInt8], _ form: [UInt8]) -> Bool {
        guard let first = form.first, form.count <= bytes.count else { return false }
        for start in 0...(bytes.count - form.count) where bytes[start] == first {
            if bytes[start..<(start + form.count)].elementsEqual(form) { return true }
        }
        return false
    }
}
