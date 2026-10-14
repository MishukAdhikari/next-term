import CryptoKit
import Foundation

/// Masks the exact values of stored keys in text Next Term gives agents and saves. It holds marks, never values,
/// so it works while the vault is locked, from launch: `SecretsStore.loadMarks()` builds it from `vault.json` and
/// `mask.key` with no crypto beyond two HKDFs.
///
/// - **Forms.** A value is marked as stored, as base64 (padded and unpadded), as base64url (unpadded), and
///   percent-encoded with RFC 3986's unreserved characters kept, when that differs.
/// - **Threshold.** A value under 12 bytes, as stored in UTF-8, gets no marks in any form, so neither it nor its base64
///   is masked. For the ASCII keys services issue, that is 12 characters.
/// - **Marks.** A form's byte length, a 16-bit head (its first 8 bytes as a little-endian `UInt64`, times an odd
///   constant plus an offset, the top 16 bits), and a 16-byte tag (HMAC-SHA256, cut). The constants and the tag's key
///   come from `mask.key` by HKDF.
/// - **Matching** runs over the text's UTF-8 bytes: the head at each position, then the HMAC only where a head matches.
///   Each match becomes "•••"; overlapping matches merge. Rows are matched as one run, so a key split by a wrap is
///   masked in both rows, an agent UI's indent or border between them too (`mask(rows:)`).
///
/// Limits, said in the docs: a value under 12 characters, and a value changed before it is printed (split, reversed,
/// hex, inside a longer base64 run), are missed. Someone with the folder, `mask.key` included, can test guesses of a
/// short value against the marks.
public final class SecretMask: @unchecked Sendable {
    /// The shortest value, in UTF-8 bytes, that gets marks.
    public static let minimumLength = 12
    /// The longest form a value can have: a 16 KB value percent-encoded, three bytes for each. A mark from vault.json
    /// that is longer (or shorter than `minimumLength`) is not a value's and is dropped.
    public static let maximumLength = 3 * SecretVault.maxValueBytes
    static let headInfo = "nextterm mask head/1"
    static let tagInfo = "nextterm mask tag/1"
    static let tagLength = 16

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared = SecretMask()

    /// The mask the app uses: set at launch from the vault's marks, and after every change. It starts empty, and an
    /// empty mask gives back its text at once.
    public static var current: SecretMask {
        get {
            lock.lock()
            defer { lock.unlock() }
            return shared
        }
        set {
            lock.lock()
            shared = newValue
            lock.unlock()
        }
    }

    /// A mask with no marks.
    public static let empty = SecretMask()

    private let multiplier: UInt64
    private let offset: UInt64
    private let tagKey: SymmetricKey?
    private let byHead: [UInt16: [SecretVault.Mark]]
    /// One bit per head: the hot loop's test before any dictionary lookup.
    private let heads: [UInt64]
    private let shortest: Int
    /// The longest form's length in bytes, 0 with no marks: how far past a cut a value that starts before it can reach.
    public let longest: Int
    public let marks: [SecretVault.Mark]

    private init() {
        multiplier = 1
        offset = 0
        tagKey = nil
        byHead = [:]
        heads = []
        shortest = Int.max
        longest = 0
        marks = []
    }

    /// The mask for `marks`, made with the mask key `key` (`mask.key`'s bytes). A mark no value's form could have, by
    /// its length or its tag's, is dropped: vault.json's marks are read with no MAC check.
    public init(key: SymmetricKey, marks: [SecretVault.Mark]) {
        let constants = Self.headConstants(key)
        multiplier = constants.multiplier
        offset = constants.offset
        tagKey = Self.tagKey(key)
        let usable = Array(Set(marks.filter(Self.isPlausible)))
        self.marks = usable
        var byHead: [UInt16: [SecretVault.Mark]] = [:]
        var heads = [UInt64](repeating: 0, count: 1024)
        for mark in usable {
            byHead[mark.head, default: []].append(mark)
            heads[Int(mark.head >> 6)] |= 1 << UInt64(mark.head & 63)
        }
        self.byHead = byHead
        self.heads = heads
        shortest = usable.map(\.length).min() ?? Int.max
        longest = usable.map(\.length).max() ?? 0
    }

    /// A mark some value's form could have: 12 bytes up to `maximumLength`, with a 16-byte tag.
    public static func isPlausible(_ mark: SecretVault.Mark) -> Bool {
        (minimumLength...maximumLength).contains(mark.length) && mark.tag.count == tagLength
    }

    /// The mask for every entry of an index.
    public convenience init(key: SymmetricKey, index: SecretVault.Index) {
        self.init(key: key, marks: index.entries.flatMap(\.marks))
    }

    public var isEmpty: Bool { marks.isEmpty }

    // MARK: marks

    /// The marks of a value's forms, or none for a value under 12 bytes. Made when the value is saved, with it at hand.
    public static func marks(for value: SecretBytes, key: SymmetricKey) -> [SecretVault.Mark] {
        guard value.count >= minimumLength else { return [] }
        let constants = headConstants(key)
        let tagKey = tagKey(key)
        var all = value.withUnsafeBytes { buffer in Self.forms(of: [UInt8](buffer)) }
        defer { for index in all.indices { SecretBytes.wipe(&all[index]) } }
        return all.map { form in
            let head = form.withUnsafeBufferPointer { headOf($0.baseAddress!, constants.multiplier, constants.offset) }
            return SecretVault.Mark(length: form.count, head: head, tag: tag(form[...], key: tagKey))
        }
    }

    /// As stored; base64 padded and unpadded; base64url unpadded; percent-encoded. Each once.
    static func forms(of value: [UInt8]) -> [[UInt8]] {
        let padded = base64(value, alphabet: standardAlphabet)
        var unpadded = padded
        while unpadded.last == UInt8(ascii: "=") { unpadded.removeLast() }
        let url = base64(value, alphabet: urlAlphabet).filter { $0 != UInt8(ascii: "=") }
        let percent = percentEncoded(value)
        var forms = [value]
        for form in [padded, unpadded, url, percent] where !forms.contains(form) { forms.append(form) }
        return forms
    }

    static let standardAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    static let urlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Base64 with padding, made from bytes so the value never becomes a `String`.
    static func base64(_ bytes: [UInt8], alphabet: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 2 < bytes.count {
            let chunk = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            for shift in [18, 12, 6, 0] { out.append(alphabet[Int(chunk >> UInt32(shift) & 63)]) }
            index += 3
        }
        let rest = bytes.count - index
        if rest == 1 {
            let chunk = UInt32(bytes[index]) << 16
            out += [alphabet[Int(chunk >> 18 & 63)], alphabet[Int(chunk >> 12 & 63)], UInt8(ascii: "="), UInt8(ascii: "=")]
        } else if rest == 2 {
            let chunk = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
            out += [alphabet[Int(chunk >> 18 & 63)], alphabet[Int(chunk >> 12 & 63)], alphabet[Int(chunk >> 6 & 63)], UInt8(ascii: "=")]
        }
        return out
    }

    /// Every byte but RFC 3986's unreserved characters as `%XX`.
    static func percentEncoded(_ bytes: [UInt8]) -> [UInt8] {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            if isUnreserved(byte) {
                out.append(byte)
            } else {
                out += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 15)]]
            }
        }
        return out
    }

    /// A-Z, a-z, 0-9, "-", ".", "_" and "~".
    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: return true
        default: return false
        }
    }

    static func headConstants(_ key: SymmetricKey) -> (multiplier: UInt64, offset: UInt64) {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(headInfo.utf8), outputByteCount: 16)
        return derived.withUnsafeBytes { raw in
            let multiplier = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) | 1
            let offset = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            return (multiplier, offset)
        }
    }

    static func tagKey(_ key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(tagInfo.utf8), outputByteCount: 32)
    }

    @inline(__always)
    static func headOf(_ start: UnsafePointer<UInt8>, _ multiplier: UInt64, _ offset: UInt64) -> UInt16 {
        let word = UInt64(littleEndian: UnsafeRawPointer(start).loadUnaligned(as: UInt64.self))
        return UInt16(truncatingIfNeeded: (word &* multiplier &+ offset) >> 48)
    }

    static func tag<Bytes: DataProtocol>(_ bytes: Bytes, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key).prefix(tagLength))
    }

    /// Whether `entry` holds `value`, by its marks: no value is read from the vault. The value is trimmed as the vault
    /// trims it, and its form as stored is looked for among the entry's marks. False for a value under 12 bytes, which
    /// has no marks, for one the vault would refuse, and with no mask key. For the import, to use a key an earlier try
    /// stored; the vault checks the value itself before it keeps the key (`SecretVault.holds`).
    public func isHeld(_ value: SecretBytes, by entry: SecretVault.Entry) -> Bool {
        guard let mark = mark(of: value) else { return false }
        return entry.marks.contains(mark)
    }

    /// The mark `value`'s form as stored has, to look for among entries' marks: worked out once for any number of
    /// them. Nil as `isHeld` is false for every entry.
    public func mark(of value: SecretBytes) -> SecretVault.Mark? {
        guard let tagKey, let trimmed = try? SecretVault.normalized(value, name: ""),
              trimmed.count >= Self.minimumLength else { return nil }
        return trimmed.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let head = Self.headOf(bytes.baseAddress!, multiplier, offset)
            return SecretVault.Mark(length: buffer.count, head: head, tag: Self.tag(buffer, key: tagKey))
        }
    }

    // MARK: matching

    /// The byte ranges of `bytes` that are a stored value in one of its forms, sorted, overlapping ones merged.
    public func ranges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        guard let tagKey, let base = bytes.baseAddress, bytes.count >= shortest else { return [] }
        var found: [Range<Int>] = []
        let last = bytes.count - shortest
        var position = 0
        while position <= last {
            let head = Self.headOf(base + position, multiplier, offset)
            if heads[Int(head >> 6)] & (1 << UInt64(head & 63)) != 0, let candidates = byHead[head] {
                // `position <= last` keeps the right side at 0 or more, so this cannot overflow.
                for mark in candidates where mark.length <= bytes.count - position {
                    let candidate = UnsafeBufferPointer(start: base + position, count: mark.length)
                    if Self.tag(UnsafeRawBufferPointer(candidate), key: tagKey) == mark.tag {
                        found.append(position..<position + mark.length)
                    }
                }
            }
            position += 1
        }
        return Self.merged(found)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let previous = merged.last, range.lowerBound < previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `text` with each stored value in it, in any of its forms, replaced by "•••".
    public func mask(_ text: String) -> String {
        masked(text).text
    }

    /// As `mask(_:)`, with how many were masked.
    public func masked(_ text: String) -> (text: String, count: Int) {
        guard !isEmpty, text.utf8.count >= shortest else { return (text, 0) }
        var copy = text
        let (found, bytes) = copy.withUTF8 { buffer in (ranges(in: buffer), Array(buffer)) }
        guard !found.isEmpty else { return (text, 0) }
        return (Self.replacing(found, in: bytes[...]), found.count)
    }

    /// An answer's fields with each string in them masked as `mask(_:)` masks it, in nested objects and lists too, and the
    /// rest as it was. For fields before they become JSON: there a value with a `"`, a `\` or a control character in it is
    /// escaped, so a pass over the answer's text misses it.
    public func mask(fields: [String: Any]) -> [String: Any] {
        guard !isEmpty else { return fields }
        return fields.mapValues(maskValue)
    }

    private func maskValue(_ value: Any) -> Any {
        switch value {
        case let text as String: return mask(text)
        case let object as [String: Any]: return object.mapValues(maskValue)
        case let list as [Any]: return list.map(maskValue)
        default: return value
        }
    }

    /// A whole answer's text, as the MCP socket writes it, masked as `mask(_:)` masks it. When it is JSON with an escape
    /// in it, each string is masked first, as `mask(fields:)` does, and only when one changes is it written again as
    /// `MCPServer.json` writes it: an escaped `"`, `\` or line break would hide a value from the pass over the text.
    public func mask(answer text: String) -> String {
        guard !isEmpty, text.utf8.count >= shortest else { return text }
        return mask(maskedStrings(ofJSON: text) ?? text)
    }

    /// `text`'s JSON with its strings masked, written again; nil when it is not JSON, has no escape (then the pass over
    /// the text sees every string as it is) or has nothing to mask.
    func maskedStrings(ofJSON text: String) -> String? {
        let bytes = text.utf8
        guard bytes.contains(0x5C), let first = bytes.first(where: { $0 > 0x20 }), first == 0x7B || first == 0x5B,
              let parsed = try? JSONSerialization.jsonObject(with: Data(bytes)) else { return nil }
        var count = 0
        let masked = maskStrings(parsed, count: &count)
        return count > 0 ? MCPServer.json(masked) : nil
    }

    private func maskStrings(_ value: Any, count: inout Int) -> Any {
        switch value {
        case let text as String:
            let result = masked(text)
            count += result.count
            return result.text
        case let object as [String: Any]: return object.mapValues { maskStrings($0, count: &count) }
        case let list as [Any]: return list.map { maskStrings($0, count: &count) }
        default: return value
        }
    }

    /// `bytes` with each range (relative to its start) made "•••".
    static func replacing(_ ranges: [Range<Int>], in bytes: ArraySlice<UInt8>) -> String {
        let dots = Array(MCPRedaction.mask.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var cursor = bytes.startIndex
        for range in ranges {
            let lower = bytes.startIndex + range.lowerBound
            out.append(contentsOf: bytes[cursor..<lower])
            out.append(contentsOf: dots)
            cursor = bytes.startIndex + range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return String(decoding: out, as: UTF8.self)
    }
}
