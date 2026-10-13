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
    /// A program's notice this soon after Next Term's own for the tab says less, and is dropped: a decision notice is
    /// never replaced by a vaguer one.
    public static let repeatWindow: TimeInterval = 10

    /// A new tab's environment asks OpenTUI programs for OSC 777, unless the user set the protocol themselves.
    public static func prepare(_ environment: inout [String: String]) {
        if environment[protocolVariable] == nil { environment[protocolVariable] = protocolValue }
    }

    /// Whether an OSC payload asks for the user's attention: OSC 777 with `notify;`, and OSC 9 except `4;`, its
    /// progress reports. It may still say nothing (`parse` is nil), and is then a bare "needs your attention".
    public static func isNotification(code: Int, payload: some Collection<UInt8>) -> Bool {
        switch code {
        case 777: return payload.starts(with: Array("notify;".utf8))
        case 9: return !payload.starts(with: Array("4;".utf8))
        default: return false
        }
    }

    /// The words of a notification, or nil when it is none or says nothing.
    ///
    /// OpenTUI writes `notify;<title>;<message>` when it has a title and `notify;<message>;` when it has none, and turns
    /// semicolons inside its text into spaces. So the first `;` after `notify;` ends the title, and with an empty body
    /// the title's place holds the message. Another program's body may keep semicolons of its own.
    public static func parse(code: Int, payload: some Collection<UInt8>) -> ProgramNotice? {
        guard isNotification(code: code, payload: payload) else { return nil }
        let text = String(decoding: payload, as: UTF8.self)
        guard code == 777 else {
            let body = cleaned(Substring(text))
            return body.isEmpty ? nil : ProgramNotice(title: nil, body: body)
        }
        let rest = text.dropFirst("notify;".count)
        let end = rest.firstIndex(of: ";")
        let title = cleaned(end.map { rest[..<$0] } ?? rest)
        let body = cleaned(end.map { rest[rest.index(after: $0)...] } ?? "")
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

    /// Line breaks and tabs become spaces, other control characters go (an escape sequence leaves only its
    /// printable rest), the ends are trimmed, and what is left is cut at `maxLength` characters.
    private static func cleaned(_ part: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in part.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                scalars.append(" ")
            } else if !ShellQuote.isControl(scalar) {
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxLength))
    }
}
