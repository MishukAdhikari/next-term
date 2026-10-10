import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A mask made from one key's marks, as the app makes it from `vault.json` and `mask.key`. Never `SecretMask.current`:
/// tests run in parallel.
private func mask(_ values: [String], key: SymmetricKey = SymmetricKey(size: .bits256)) -> SecretMask {
    SecretMask(key: key, marks: values.flatMap { SecretMask.marks(for: SecretBytes(utf8: $0), key: key) })
}

private let key40 = "Zq8pLmW2vXn4Rt7yKb1sQe5uHj3oAc6dFg9iTw0e" // 40 characters, no known token shape

@Suite struct SecretMaskFormTests {
    @Test func aKeyIsMaskedInEachForm() throws {
        let m = mask([key40])
        let base64 = Data(key40.utf8).base64EncodedString()
        let unpadded = base64.replacingOccurrences(of: "=", with: "")
        let url = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let withSlash = "ab+/cd?&=x" + key40 // a value with characters base64url and percent-encoding change
        let percent = try #require(withSlash.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")))
        let both = mask([key40, withSlash])
        for (label, form, mask) in [("as stored", key40, m), ("base64", base64, m), ("unpadded", unpadded, m), ("base64url", url, m),
                                    ("percent", percent, both)] {
            let text = "before \(form) after"
            #expect(mask.mask(text) == "before ••• after", "\(label)")
        }
        #expect(percent != withSlash && percent.contains("%2B%2F"))
        // A 40-byte value's base64 has padding, so padded and unpadded are two marks; with no + or / in it, base64url
        // is the unpadded form, and percent-encoding changes nothing: three in all.
        #expect(!base64.contains("+") && !base64.contains("/"))
        #expect(SecretMask.marks(for: SecretBytes(utf8: key40), key: SymmetricKey(size: .bits256)).count == 3)
        #expect(SecretMask.marks(for: SecretBytes(utf8: withSlash), key: SymmetricKey(size: .bits256)).count >= 4)
    }

    @Test func aChangedCharacterIsNotMasked() {
        let m = mask([key40])
        var changed = key40
        changed.removeLast()
        changed += "X"
        #expect(m.mask("x \(changed) y") == "x \(changed) y")
        #expect(m.mask(String(key40.dropFirst())) == String(key40.dropFirst()))
    }

    @Test func theTwelveByteThreshold() {
        let key = SymmetricKey(size: .bits256)
        let eleven = "aB3dE5gH7jK"
        let twelve = "aB3dE5gH7jKl"
        #expect(SecretMask.marks(for: SecretBytes(utf8: eleven), key: key).isEmpty)
        let elevenMask = mask([eleven], key: key)
        #expect(elevenMask.isEmpty)
        #expect(elevenMask.mask("\(eleven) \(Data(eleven.utf8).base64EncodedString())") == "\(eleven) \(Data(eleven.utf8).base64EncodedString())")
        let marks = SecretMask.marks(for: SecretBytes(utf8: twelve), key: key)
        #expect(marks.count == 2) // as stored, and base64 (16 characters, no padding); percent-encoding changes nothing
        let twelveMask = mask([twelve], key: key)
        #expect(twelveMask.mask("v=\(twelve)") == "v=•••")
        #expect(twelveMask.mask("b=\(Data(twelve.utf8).base64EncodedString())") == "b=•••")
    }

    @Test func marksAloneMaskWithNoValueInMemory() throws {
        let key = SymmetricKey(size: .bits256)
        let marks = SecretMask.marks(for: SecretBytes(utf8: key40), key: key)
        // What vault.json holds: the marks, round-tripped through JSON, and mask.key's bytes.
        let stored = try JSONDecoder().decode([SecretVault.Mark].self, from: JSONEncoder().encode(marks))
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let fromDisk = SecretMask(key: SymmetricKey(data: keyBytes), marks: stored)
        #expect(fromDisk.mask("token: \(key40)") == "token: •••")
        #expect(!String(decoding: try JSONEncoder().encode(marks), as: UTF8.self).contains(key40.prefix(8)))
        // Another mask key's mask does not match.
        #expect(SecretMask(key: SymmetricKey(size: .bits256), marks: stored).mask(key40) == key40)
    }

    @Test func noMarksGivesTheTextBack() {
        let text = "nothing to hide \(key40)"
        #expect(SecretMask.empty.mask(text) == text)
        #expect(SecretMask.empty.mask(rows: [text, text]) == [text, text])
        #expect(SecretMask.empty.masked(text).count == 0)
    }
}

@Suite struct SecretMaskRowTests {
    @Test func aKeySplitByAWrapIsMaskedInBothRows() {
        let m = mask([key40])
        let split = key40.index(key40.startIndex, offsetBy: 17)
        let rows = ["界 line before 🙂", "左边 \(key40[..<split])", "\(key40[split...]) 右边 👍🏽 after", "next row"]
        let masked = m.mask(rows: rows)
        #expect(masked == ["界 line before 🙂", "左边 •••", "••• 右边 👍🏽 after", "next row"])
        #expect(!masked.joined().contains(key40.prefix(10)) && !masked.joined().contains(key40.suffix(10)))
    }

    @Test func overlappingKeysMergeIntoOne() {
        let first = "AAAAbbbbCCCCdddd1111"
        let second = "dddd1111EEEEffff2222" // starts inside the first
        let m = mask([first, second])
        #expect(m.mask("x AAAAbbbbCCCCdddd1111EEEEffff2222 y") == "x ••• y")
        #expect(m.masked("\(first) and \(second)").count == 2)
    }

    @Test func aMegabyteWithFiftyKeysIsQuick() {
        let keys = (0..<50).map { "Key\($0)-" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        let m = mask(keys)
        var text = String(repeating: "lorem ipsum dolor sit amet, consectetur adipiscing elit 0123456789\n", count: 15_500)
        text += keys[7] + "\n" + keys[42]
        let start = Date()
        let result = m.masked(text)
        let seconds = Date().timeIntervalSince(start)
        #expect(text.utf8.count > 1_000_000)
        #expect(result.count == 2 && !result.text.contains(keys[7]) && !result.text.contains(keys[42]))
        #expect(seconds < 1, "\(seconds) s")
    }
}

@Suite struct SecretMaskChainTests {
    /// A random value no pattern catches: 20 characters, no token prefix, no secret-named assignment.
    let stored = "Rk7vQp2xLm9nWz4cTb8h"

    @Test func theChainMasksAStoredValueThePatternsMiss() {
        let m = mask([stored])
        let text = "the build printed \(stored) on its way"
        #expect(MCPRedaction.redact(text, mask: .empty).text == text) // the patterns alone keep it
        let redacted = MCPRedaction.redact(text, mask: m)
        #expect(redacted.text == "the build printed ••• on its way" && redacted.count == 1)
        #expect(CommandSecrets.mask("curl -d \(stored) https://example.invalid", mask: .empty).contains(stored))
        #expect(CommandSecrets.mask("curl -d \(stored) https://example.invalid", mask: m) == "curl -d ••• https://example.invalid")
        #expect(CommandSecrets.mayKeep("echo \(stored)", mask: .empty))
        #expect(!CommandSecrets.mayKeep("echo \(stored)", mask: m))
    }

    @Test func savedScrollbackIsMaskedAcrossAWrap() {
        // Scrollback saved for an update is masked by logical line: a wrapped row is joined to the row before it first,
        // so a value split by the wrap is still found.
        let m = mask([stored])
        let rows = ["$ printenv OUT", "value: \(stored.prefix(9))", "\(stored.dropFirst(9)) (done)"]
        let joined = rows[0] + "\n" + rows[1] + rows[2]
        let masked = CommandSecrets.mask(joined, mask: m)
        #expect(masked == "$ printenv OUT\nvalue: ••• (done)")
        #expect(!masked.contains(stored.prefix(9)) && !masked.contains(stored.dropFirst(9)))
    }
}
