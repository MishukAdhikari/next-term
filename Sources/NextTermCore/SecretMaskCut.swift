import Foundation

extension SecretMask {
    /// `text` masked, then cut to at most `maxBytes` UTF-8 bytes, with `cut` when anything was left out. Masking comes
    /// first: a cut through a stored value leaves the value out whole, and never splits a character. Text a host already
    /// cut (`head -c`) should run `longest` bytes past `maxBytes`, so a value that starts before the cut is there whole.
    public func maskedPrefix(_ text: String, maxBytes: Int) -> (text: String, cut: Bool) {
        var copy = text
        return copy.withUTF8 { buffer -> (text: String, cut: Bool) in
            let found = ranges(in: buffer)
            guard buffer.count > maxBytes else {
                return found.isEmpty ? (text, false) : (Self.replacing(found, in: Array(buffer)[...]), false)
            }
            var cut = max(0, maxBytes)
            if let across = found.first(where: { $0.lowerBound < cut && cut < $0.upperBound }) { cut = across.lowerBound }
            while cut > 0, buffer[cut] & 0xC0 == 0x80 { cut -= 1 }
            let kept = found.filter { $0.upperBound <= cut }
            return (Self.replacing(kept, in: Array(buffer[..<cut])[...]), true)
        }
    }
}

extension MCPRedaction {
    /// How far around a cut `cleanCut` looks: the longest stored value's longest form, and at least 512 characters for
    /// what the patterns mask.
    static func reach(_ secrets: SecretMask) -> Int { max(512, secrets.longest) }

    /// Whether cutting `text` at `index` would show part of what `redact` masks: redacting the text around the cut
    /// gives other than redacting each side alone.
    static func cutsAMask(_ text: String, at index: String.Index, reach: Int, mask secrets: SecretMask) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return false }
        let lower = text.index(index, offsetBy: -reach, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(index, offsetBy: reach, limitedBy: text.endIndex) ?? text.endIndex
        let around = String(text[lower..<upper])
        let whole = redact(around, mask: secrets)
        guard whole.count > 0 else { return false } // nothing masked near the cut: the common case, one pass
        let left = redact(String(text[lower..<index]), mask: secrets).text
        let right = redact(String(text[index..<upper]), mask: secrets).text
        return whole.text != left + right
    }

    /// `index`, or the nearest place before it (after it with `forward`) where a cut shows no part of what `redact`
    /// masks: a stored value or a pattern's match across the cut is left out whole (or taken in whole). It moves
    /// `reach` characters at a time, to the text's start or end at most.
    static func cleanCut(_ text: String, at index: String.Index, forward: Bool, mask secrets: SecretMask) -> String.Index {
        let reach = reach(secrets)
        var cut = index
        while cutsAMask(text, at: cut, reach: reach, mask: secrets) {
            let limit = forward ? text.endIndex : text.startIndex
            cut = text.index(cut, offsetBy: forward ? reach : -reach, limitedBy: limit) ?? limit
        }
        return cut
    }
}
