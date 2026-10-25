import Foundation

extension SecretMask {
    /// The bytes to ask a host for (`head -c`) when its text is cut at `maxBytes` by `maskedPrefix`: `longest` past the
    /// cut, so a stored value that starts before the cut comes whole and is left out whole, and one more to tell that the
    /// text was cut.
    public func bytesToRead(forCutAt maxBytes: Int) -> Int { maxBytes + longest + 1 }

    /// The end of `text` for an answer: masked, trimmed of spaces and line ends, then its last `characters` characters.
    /// Masking comes first: cut first, a stored value across where the end starts showed its own end, which no later
    /// mask can match. When `endIsACut` (the text was read up to a limit) its last `longest` + 1 bytes go too, so a
    /// value the limit cut through, which the mask cannot match either, is left out whole.
    public func maskedTail(_ text: String, characters: Int, endIsACut: Bool) -> String {
        let kept = endIsACut && !isEmpty ? text.utf8.count - longest - 1 : text.utf8.count
        let masked = maskedPrefix(text, maxBytes: max(0, kept)).text
        return String(masked.trimmingCharacters(in: .whitespacesAndNewlines).suffix(characters))
    }

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
    /// masks: a stored value or a pattern's match across the cut is left out whole (or taken in whole), and so is a value
    /// masked for its name however long it is (`NamedValues`; the text kept before the cut may end with its name). It
    /// moves `reach` characters at a time, or past such a value, to the text's start or end at most.
    static func cleanCut(_ text: String, at index: String.Index, forward: Bool, mask secrets: SecretMask) -> String.Index {
        let reach = reach(secrets)
        let named = NamedValues(text, mask: secrets)
        var cut = index
        while true {
            if let past = named.clean(cut, keepingAfter: forward) {
                cut = past
                continue
            }
            guard cutsAMask(text, at: cut, reach: reach, mask: secrets) else { return cut }
            let limit = forward ? text.endIndex : text.startIndex
            cut = text.index(cut, offsetBy: forward ? reach : -reach, limitedBy: limit) ?? limit
        }
    }
}

extension MCPRedaction {
    /// `line[window]` redacted, for a search result, with how many values it masked. An edge that would show part of
    /// what `redact` masks moves in, toward `match`, to the nearest clean place (`cutsAMask`), and ••• stands for what it
    /// left out: a run across an edge (an inlined image or font) is never read whole, so the snippet stays within its
    /// window and costs a few small redactions however long the run. An edge in a value masked for its name moves
    /// out of it the same way (`NamedValues`, from `values` when the caller keeps the line's). A window with no clean
    /// place at the match or its far edge is all masked, and is ••• alone.
    static func snippet(_ line: String, window: Range<String.Index>, match: Range<String.Index>,
                        mask secrets: SecretMask, values: NamedValues? = nil) -> (text: String, count: Int) {
        let reach = reach(secrets)
        let named = values ?? NamedValues(line, mask: secrets)
        // The lower edge keeps the text after it, the upper one the text before it.
        func cutsLower(_ index: String.Index) -> Bool {
            named.cuts(index, keepingAfter: true) || cutsAMask(line, at: index, reach: reach, mask: secrets)
        }
        func cutsUpper(_ index: String.Index) -> Bool {
            named.cuts(index, keepingAfter: false) || cutsAMask(line, at: index, reach: reach, mask: secrets)
        }
        let matchStart = min(max(match.lowerBound, window.lowerBound), window.upperBound)
        let matchEnd = min(max(match.upperBound, matchStart), window.upperBound)
        var lower = window.lowerBound
        var upper = window.upperBound
        let movesLower = cutsLower(lower)
        let movesUpper = cutsUpper(upper)
        if movesLower {
            var cutting = lower
            var clean: String.Index?
            for place in [matchStart, matchEnd, upper] where place > cutting {
                if cutsLower(place) { cutting = place } else { clean = place; break }
            }
            guard let clean else {
                return ("…" + mask + (window.upperBound < line.endIndex ? "…" : ""), 1)
            }
            lower = nearestClean(line, from: cutting, to: clean, cuts: cutsLower)
        }
        if movesUpper {
            var cutting = upper
            var clean = lower // clean: where a cut was found clean above, or the window's own clean edge
            for place in [matchEnd, matchStart] where place < cutting && place > lower {
                if cutsUpper(place) { cutting = place } else { clean = place; break }
            }
            upper = nearestClean(line, from: cutting, to: clean, cuts: cutsUpper)
        }
        let lead = lower > line.startIndex ? "…" : ""
        let trail = upper < line.endIndex ? "…" : ""
        guard lower < upper else { return (lead + mask + trail, 1) }
        var body = line[lower..<upper]
        func isSpace(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }
        if !movesLower { body = body.drop(while: isSpace) }
        if !movesUpper { while let last = body.last, isSpace(last) { body = body.dropLast() } }
        let redacted = redact(String(body), mask: secrets)
        let moved = (movesLower ? 1 : 0) + (movesUpper ? 1 : 0)
        let text = lead + (movesLower ? mask : "") + redacted.text + (movesUpper ? mask : "") + trail
        return (text, redacted.count + moved)
    }

    /// A clean place between `cutting`, where a cut shows part of a mask, and `clean`, where none does: the span halved
    /// until they are one character apart, so the place found is next to the mask it leaves out.
    static func nearestClean(_ line: String, from cutting: String.Index, to clean: String.Index,
                             cuts: (String.Index) -> Bool) -> String.Index {
        var bad = cutting
        var good = clean
        while abs(line.distance(from: bad, to: good)) > 1 {
            let middle = line.index(bad, offsetBy: line.distance(from: bad, to: good) / 2)
            if cuts(middle) { bad = middle } else { good = middle }
        }
        return good
    }
}

extension RemoteChanges {
    /// The diff host_changes shows, and the bytes it was cut at (nil: it is whole). It is masked, then cut at `maxBytes`
    /// of the bytes as the host sent them, which `head -c` counted, carriage returns and all; only then is each line's
    /// carriage return dropped, as the other sections' are. `asked` is what `head -c` was asked for. Where the host may
    /// have cut (it sent that much) or the connection did (the script's end never came), the cut is `mask.longest` + 1
    /// bytes before the end at least, so a value that starts before it is there whole and is left out whole. `mask` is
    /// the one at hand when the answer is built: one stored during the run, longer than the margin asked for, is safe too.
    public func shownDiff(cutAt maxBytes: Int, asked: Int, mask: SecretMask) -> (text: String, cutAt: Int?) {
        let sent = diff.utf8.count
        let endIsACut = !ended || sent >= asked
        let cut = max(0, endIsACut ? min(maxBytes, sent - mask.longest - 1) : maxBytes)
        let shown = mask.maskedPrefix(diff, maxBytes: cut)
        return (Self.droppingCarriageReturns(shown.text), shown.cut || !ended ? cut : nil)
    }

    /// `text` without a carriage return at the end of a line, or of the text.
    static func droppingCarriageReturns(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text } // the common case: no copy
        let bytes = Array(text.utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        for index in bytes.indices where bytes[index] != 0x0D || (index + 1 < bytes.count && bytes[index + 1] != 0x0A) {
            kept.append(bytes[index])
        }
        return String(decoding: kept, as: UTF8.self)
    }
}
