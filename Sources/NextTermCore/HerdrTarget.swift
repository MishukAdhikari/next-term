import Foundation

/// A herdr agent as MCP names it: its herdr tab's id in Next Term, a slash, and herdr's pane id ("5c0d…e1/w1:p3"). An
/// agent on one of the machines saved in a herdr that runs on this Mac has the machine's id between them, after an @
/// ("5c0d…e1/@0123…ef/w1:p3"): pane ids are a server's own, so the same one can be on two machines. An agent id goes
/// wherever a tab id goes (read_tab, send_to_tab…), so MCP has no tool of its own for herdr's agents.
public struct HerdrTarget: Equatable, Hashable, Sendable {
    /// The Next Term tab that shows herdr, lowercased as list_tabs gives tab ids.
    public var tabID: String
    /// One of herdr's saved machines (herdr's own id for it, as given); nil for the tab's own herdr server.
    public var machine: String?
    /// herdr's pane id, in herdr's own case.
    public var pane: String

    public init(tabID: String, machine: String? = nil, pane: String) {
        self.tabID = tabID.lowercased()
        self.machine = machine
        self.pane = pane
    }

    /// "<tab id>/<pane id>", or "<tab id>/@<machine id>/<pane id>", split at the slashes; nil without one, or with
    /// nothing on a side. Neither the pane nor the machine is checked here (`isPane`, `isMachine` are): "a/b/c" is the
    /// pane "b/c", which no herdr names.
    public static func parse(_ id: String) -> HerdrTarget? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let tab = String(id[..<slash]).trimmingCharacters(in: .whitespaces)
        var rest = String(id[id.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        var machine: String?
        if rest.hasPrefix("@"), let next = rest.firstIndex(of: "/") {
            machine = String(rest[rest.index(after: rest.startIndex)..<next])
            rest = String(rest[rest.index(after: next)...])
            guard machine?.isEmpty == false else { return nil }
        }
        guard !tab.isEmpty, !rest.isEmpty else { return nil }
        return HerdrTarget(tabID: tab, machine: machine, pane: rest)
    }

    public var id: String {
        guard let machine else { return tabID + "/" + pane }
        return tabID + "/@" + machine + "/" + pane
    }

    // MARK: what Next Term passes to herdr: checked, never rewritten

    /// A pane id as herdr gives it ("w1:p1", or "1-1" and "w64e95948145ed1-1" before 0.5): a letter or digit, then up to
    /// 79 letters, digits and `: . _ -`.
    public static func isPane(_ id: String) -> Bool { isID(id, colon: true) }

    /// A tab id ("w1:t1"), the same rule.
    public static func isTab(_ id: String) -> Bool { isID(id, colon: true) }

    /// One of herdr's saved machines' ids (32 hex digits from herdr, as `machine list --json` gives it): a letter or
    /// digit, then up to 79 letters, digits and `. _ -`. Never a label: a label may hold anything.
    public static func isMachine(_ id: String) -> Bool { isID(id, colon: false) }

    /// A session name for `--session` (HerdrSession.isName).
    public static func isSession(_ name: String) -> Bool { HerdrSession.isName(name) }

    /// An agent's name as herdr allows one: a lower-case letter, then up to 31 lower-case letters, digits, `_` and `-`.
    public static func isAgentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...32).contains(bytes.count), isLower(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isID(_ id: String, colon: Bool) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...80).contains(bytes.count), isLetterOrDigit(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            if colon && byte == UInt8(ascii: ":") { return true }
            return isLetterOrDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static func isLower(_ byte: UInt8) -> Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        isLower(byte) || isDigit(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}
