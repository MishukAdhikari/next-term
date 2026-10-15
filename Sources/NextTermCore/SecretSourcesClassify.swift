import Foundation

// Which values in a file look like keys, held as data: each list names where it comes from. A row starts ticked only
// when it looks like a key; a key that is safe to expose, expires within hours, or ships to browsers is listed unticked
// with a note; references, placeholders and settings are only counted.

extension SecretSources {
    /// Name prefixes a web framework hands to the browser. Next.js documents `NEXT_PUBLIC_` and Vite `VITE_`; Create
    /// React App, Expo, SvelteKit, Nuxt and Gatsby use the others the same way.
    static let publicPrefixes = ["NEXT_PUBLIC_", "VITE_", "REACT_APP_", "EXPO_PUBLIC_", "PUBLIC_", "NUXT_PUBLIC_", "GATSBY_"]

    /// Heads of keys their providers call safe to expose: Stripe's and Supabase's publishable keys, Langfuse's public
    /// key.
    static let publishableHeads = ["pk_live_", "pk_test_", "sb_publishable_", "pk-lf-"]

    /// Credentials that last hours: AWS's session token and temporary access key ids (ASIA, from STS), Vercel's OIDC
    /// token (12 hours), and Slack's rotating tokens (`xoxe.`, 12 hours).
    static let shortLivedNames: Set<String> = ["AWS_SESSION_TOKEN", "VERCEL_OIDC_TOKEN"]
    static let shortLivedHeads = ["xoxe."]
    static let temporaryAWSKey = try! NSRegularExpression(pattern: #"^ASIA[0-9A-Z]{16}$"#)

    /// Name endings that hold a setting, not a key, when the value has no key's shape.
    static let settingSuffixes = ["_URL", "_HOST", "_PORT", "_REGION", "_MODEL"]
    static let booleans: Set<String> = ["true", "false", "yes", "no", "on", "off"]

    /// A JSON web token's expiry this close or closer makes it short-lived.
    static let hours: TimeInterval = 24 * 3600
    static let jwtKind = "JSON web token"

    /// What one value is: a row (with its kind, its tick, a note and a refusal), a value that isn't a key, or nothing
    /// (an empty value).
    public enum Classified: Equatable, Sendable {
        case row(kind: String, ticked: Bool, note: Note?, refusal: Refusal?)
        case notKey(NotKeyReason)
        case none
    }

    /// The import's rules for one value, judged without the blanks and line breaks at its ends, as the report keeps it.
    /// `sourceSays` is true when the source marks the value secret (a hidden field, a Kubernetes Secret); `isText` is
    /// false for a number or a boolean in JSON.
    public static func classify(name: String, value: String, sourceSays: Bool = false, isText: Bool = true,
                                now: Date = Date()) -> Classified {
        let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard isText else { return .notKey(.setting) }
        if let encrypted = encryption(of: trimmed) {
            return .row(kind: "an encrypted value", ticked: false, note: nil, refusal: encrypted)
        }
        if let reference = referenceClass(name: name, value: trimmed) { return reference }
        if SecretImport.isPlaceholder(trimmed) { return .notKey(.placeholder) }
        if booleans.contains(trimmed.lowercased()) { return .notKey(.setting) }
        let secretName: Bool = SecretImport.nameLooksSecret(name) || SecretName.isSecret(name)
        if Double(trimmed) != nil, !secretName { return .notKey(.setting) }
        let kind: String
        if sourceSays {
            kind = SecretImport.tokenKind(trimmed) ?? providerKind(trimmed) ?? "a secret, by its source"
        } else {
            if isSetting(name: name, value: trimmed) { return .notKey(.setting) }
            guard let found = keyKind(name: name, value: trimmed, secretName: secretName) else { return .notKey(.setting) }
            kind = found
        }
        if let refusal = storageRefusal(trimmed) { return .row(kind: kind, ticked: false, note: nil, refusal: refusal) }
        let note: Note? = untickingNote(name: name, value: trimmed, now: now)
        // A web token ticks only under a key's name: any signed-in session holds one.
        let anyToken: Bool = kind == jwtKind && !secretName && !sourceSays
        let ticked: Bool = note == nil && !anyToken
        return .row(kind: kind, ticked: ticked, note: note, refusal: nil)
    }

    /// sops's and dotenvx's encrypted values: listed, with how to import them.
    static func encryption(of value: String) -> Refusal? {
        if value.hasPrefix("ENC[") { return .encryptedSops }
        if value.hasPrefix("encrypted:") { return .encryptedDotenvx }
        return nil
    }

    /// A value that points at a key kept elsewhere, or is built from one: counted, or listed and refused when the rest
    /// of it is a key that would be stored with the reference as written.
    static func referenceClass(name: String, value: String) -> Classified? {
        if SecretImport.isReference(value) {
            let names: [String] = referenceNames(in: value)
            return .notKey(names.isEmpty ? .reference : .builtFrom(names))
        }
        guard let rest = SecretImport.withoutReferences(value) else { return nil }
        let names: [String] = referenceNames(in: value)
        if let kind = SecretImport.detect(name: name, value: rest) {
            return .row(kind: kind, ticked: false, note: nil, refusal: .reference(names))
        }
        return .notKey(names.isEmpty ? .reference : .builtFrom(names))
    }

    static let referenceName = try! NSRegularExpression(
        pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|^\$([A-Za-z_][A-Za-z0-9_]*)$"#)

    /// The names in a value's `${NAME}` references, and a whole value's `$NAME`, in order, each once.
    static func referenceNames(in value: String) -> [String] {
        var names: [String] = []
        let range = NSRange(value.startIndex..., in: value)
        for match in referenceName.matches(in: value, range: range) {
            for group in 1...2 {
                guard let found = Range(match.range(at: group), in: value) else { continue }
                let name = String(value[found])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}

// MARK: - Settings, kinds and notes

extension SecretSources {
    static let urlShape = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*://\S+$"#)

    /// A URL without a password, or a value under a setting's name, that has no key's shape and doesn't look random.
    static func isSetting(name: String, value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        let password: Bool = MCPRedaction.urlPassword.firstMatch(in: value, range: range) != nil
        if password || SecretImport.tokenKind(value) != nil || MCPRedaction.looksRandom(value) { return false }
        if urlShape.firstMatch(in: value, range: range) != nil { return true }
        let upper: String = name.uppercased()
        return settingSuffixes.contains { (suffix: String) -> Bool in upper.hasSuffix(suffix) }
    }

    /// What a value is when it looks like a key: a token's kind, a URL with a password, or the provider its head names,
    /// else a key by its shape or name. Nil when it doesn't look like one.
    static func keyKind(name: String, value: String, secretName: Bool) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        if MCPRedaction.urlPassword.firstMatch(in: value, range: range) != nil { return "a URL with a password" }
        let byName: Bool = secretName && value.count >= 8 && MCPRedaction.isValue(value)
        guard let kind = SecretImport.detect(name: name, value: value) ?? (byName ? "a key, by its name" : nil) else {
            return nil
        }
        guard kind == "a key, by its shape" || kind == "a key, by its name" else { return kind }
        return providerKind(value) ?? kind
    }

    /// "Stripe key", when the value's head names a provider (`SecretKeyPages`).
    static func providerKind(_ value: String) -> String? {
        let bytes = SecretBytes(utf8: value)
        return SecretKeyPages.page(forValue: bytes).map { (page: KeyPage) -> String in "\(page.provider) key" }
    }

    /// Why a key can't be stored yet: the vault's own limits.
    static func storageRefusal(_ value: String) -> Refusal? {
        // By scalar: "\r\n" is one Character, equal to neither "\r" nor "\n".
        if value.unicodeScalars.contains(where: { (scalar: Unicode.Scalar) -> Bool in scalar == "\n" || scalar == "\r" }) {
            return .lineBreaks
        }
        if value.utf8.count > SecretVault.maxValueBytes { return .tooLong }
        if value.unicodeScalars.contains("\u{0}") { return .nul }
        return nil
    }

    /// The note a key starts unticked with, first match first: a token past its expiry, safe to expose, short-lived,
    /// sent to browsers. A token past its expiry reads as short-lived, as R15 says: `vercel env pull`'s OIDC token is
    /// one 12 hours on (AE8).
    static func untickingNote(name: String, value: String, now: Date) -> Note? {
        let expiry: Date? = jwtExpiry(value)
        if let expiry, expiry <= now { return .shortLived }
        let upper: String = name.uppercased()
        let segments: [String] = SecretName.segments(of: name)
        let publicKey: Bool = segments.suffix(2) == ["PUBLIC", "KEY"]
        if publicKey || publishableHeads.contains(where: { (head: String) -> Bool in value.hasPrefix(head) }) {
            return .publishable
        }
        let range = NSRange(value.startIndex..., in: value)
        let temporary: Bool = temporaryAWSKey.firstMatch(in: value, range: range) != nil
        let rotating: Bool = shortLivedHeads.contains { (head: String) -> Bool in value.hasPrefix(head) }
        let soon: Bool = expiry.map { (date: Date) -> Bool in date.timeIntervalSince(now) <= hours } ?? false
        if shortLivedNames.contains(upper) || temporary || rotating || soon { return .shortLived }
        guard publicPrefixes.contains(where: { (prefix: String) -> Bool in upper.hasPrefix(prefix) }) else { return nil }
        let shaped: Bool = SecretImport.tokenKind(value) != nil || (value.count >= 20 && MCPRedaction.looksRandom(value))
        return shaped ? .shipsToBrowsers : .publicName
    }

    /// A JSON web token's `exp`, read on this Mac from its middle part. Nil for a value that isn't one, or one whose
    /// middle part doesn't decode or has no numeric `exp`. Nothing of it is kept.
    public static func jwtExpiry(_ value: String) -> Date? {
        let parts: [Substring] = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ") else { return nil }
        var text: String = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.utf8.count % 4 != 0 { text += "=" }
        guard var payload = Data(base64Encoded: text) else { return nil }
        defer { SecretBytes.wipe(&payload) }
        guard let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let exp = claims["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}
