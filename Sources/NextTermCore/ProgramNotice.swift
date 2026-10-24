import Foundation

/// A program's own desktop notification: OSC 777 (rxvt's `notify;<title>;<body>`) or OSC 9 (iTerm2's, the body
/// alone). Its words become the notification's body. The title a program gives is kept here but never shown, since
/// it could say anything: OpenCode's is the session's own title, or none.
public struct ProgramNotice: Equatable, Sendable {
    /// What the program gave as its title, if anything.
    public let title: String?
    /// What the notification says.
    public let body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }

    /// OpenTUI programs (OpenCode among them) send notifications only to terminals they know, or by the protocol this
    /// variable names. OSC 777 carries a title and a body, which OSC 9 lacks.
    public static let protocolVariable = "OPENTUI_NOTIFICATION_PROTOCOL"
    public static let protocolValue = "osc777"
    /// Each part's length at most, as an agent's question is cut.
    public static let maxLength = 200
    /// A payload longer than this (bytes) is not read: no notification is that long, and SwiftTerm sets no limit on an
    /// OSC's length, so reading one whole could hold up the main thread. It still asks for attention, with no words.
    public static let maxPayload = 4096
    /// A program's notice this soon after Next Term's own for the tab says less, and is dropped: a decision notice is
    /// never replaced by a vaguer one.
    public static let repeatWindow: TimeInterval = 10

    /// A new tab's environment asks OpenTUI programs for OSC 777, unless the user set the protocol themselves.
    public static func prepare(_ environment: inout [String: String]) {
        if environment[protocolVariable] == nil { environment[protocolVariable] = protocolValue }
    }

    /// Whether an OSC payload asks for the user's attention: OSC 777 with `notify;`, and OSC 9 except ConEmu's numbered
    /// commands. It may still say nothing (`parse` is nil), and is then a bare "needs your attention".
    public static func isNotification(code: Int, payload: some Collection<UInt8>) -> Bool {
        switch code {
        case 777: return payload.starts(with: Array("notify;".utf8))
        case 9: return !isConEmuCommand(payload)
        default: return false
        }
    }

    /// ConEmu's OSC 9 commands, a number of one or two digits alone or before a `;`: progress (`4;`), the shell's
    /// folder (`9;`, oh-my-posh's osc99), a tab's title (`3;`), a prompt's start (`12`) and the rest. None is a
    /// notification. Words that start with a number ("3 tests failed") are.
    static func isConEmuCommand(_ payload: some Collection<UInt8>) -> Bool {
        let head = Array(payload.prefix(3))
        let digits = head.prefix(while: { (0x30...0x39).contains($0) }).count
        guard (1...2).contains(digits) else { return false }
        return head.count == digits || head[digits] == UInt8(ascii: ";")
    }

    /// The words of a notification, or nil when it is none or says nothing.
    ///
    /// OpenTUI writes `notify;<title>;<message>` when it has a title and `notify;<message>;` when it has none, and turns
    /// semicolons inside its text into spaces. So the first `;` after `notify;` ends the title, and with an empty body
    /// the title's place holds the message. Another program's body may keep semicolons of its own. `mask` masks stored
    /// keys before each part is cut (`SecretMask.current` unless a test passes its own).
    public static func parse(code: Int, payload: some Collection<UInt8>, mask: SecretMask = .current) -> ProgramNotice? {
        guard isNotification(code: code, payload: payload), payload.count <= maxPayload else { return nil }
        let text = String(decoding: payload, as: UTF8.self)
        guard code == 777 else {
            let body = cleaned(Substring(text), mask: mask)
            return body.isEmpty ? nil : ProgramNotice(title: nil, body: body)
        }
        let rest = text.dropFirst("notify;".count)
        let end = rest.firstIndex(of: ";")
        let title = cleaned(end.map { rest[..<$0] } ?? rest, mask: mask)
        let body = cleaned(end.map { rest[rest.index(after: $0)...] } ?? "", mask: mask)
        if body.isEmpty { return title.isEmpty ? nil : ProgramNotice(title: nil, body: title) }
        return ProgramNotice(title: title.isEmpty ? nil : title, body: body)
    }

    /// Whether a program's notice at `now` comes within `repeatWindow` of Next Term's own notice for the same tab
    /// (both in seconds of the same clock).
    public static func isRepeat(lastOwnNoticeAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = lastOwnNoticeAt else { return false }
        let gap = now - at
        return gap >= 0 && gap < repeatWindow
    }

    /// Line breaks, tabs and Unicode's line and paragraph separators become spaces. Other control characters go (an
    /// escape sequence leaves only its printable rest), and so do the bidirectional controls, so the words show in the
    /// order they were sent. Then stored keys are masked, the ends trimmed, and what is left cut at `maxLength`
    /// characters: masked before the cut, as `AgentScreen` masks a question, so a key the cut goes through shows none of
    /// itself.
    private static func cleaned(_ part: Substring, mask: SecretMask) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in part.unicodeScalars {
            if breaks.contains(scalar.value) {
                scalars.append(" ")
            } else if !ShellQuote.isControl(scalar) && !bidiControls.contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        let trimmed = mask.mask(String(scalars)).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxLength))
    }

    /// Line feed, carriage return, tab, line separator and paragraph separator.
    static let breaks: Set<UInt32> = [0x0A, 0x0D, 0x09, 0x2028, 0x2029]
    /// Unicode's bidirectional controls: the marks (ALM, LRM, RLM), embeddings, overrides and isolates.
    static let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}
