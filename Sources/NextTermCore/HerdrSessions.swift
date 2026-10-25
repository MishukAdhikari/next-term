import Foundation

// herdr's sessions (`herdr session list --json`) and the tab its focus is in (`herdr tab list`), read as its list of
// agents is (HerdrListing): past noise, unknown fields ignored, and nothing taken from an answer that is not whole.

/// One of herdr's sessions: each is a herdr server of its own, with its own workspaces, tabs, panes and agents.
public struct HerdrSession: Equatable, Sendable {
    public var name: String
    /// herdr's default session: the one bare `herdr` opens.
    public var isDefault: Bool
    /// Its server is running.
    public var running: Bool

    public init(name: String, isDefault: Bool = false, running: Bool = false) {
        self.name = name
        self.isDefault = isDefault
        self.running = running
    }

    /// The most sessions one list gives.
    static let maxSessions = 64

    /// A name herdr's `--session` takes and Next Term passes on: 1 to 64 letters, digits, `_` and `-`. Checked, never
    /// rewritten: a name outside it is not a session Next Term opens.
    public static func isName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// herdr's JSON (`{"sessions": [...]}`, at the top or under `result`); nil when it is not that list (an error, or not
    /// herdr's JSON). The default first, then herdr's order. A session whose name Next Term would not pass on is left out.
    public static func parse(_ output: String) -> [HerdrSession]? {
        HerdrAgent.scan(HerdrAgent.plain(output)) { value, _ -> [HerdrSession]? in
            guard let object = value as? [String: Any], object["error"] == nil else { return nil }
            let body = object["result"] as? [String: Any] ?? object
            guard let list = body["sessions"] as? [Any] else { return nil }
            var sessions: [HerdrSession] = []
            for case let item as [String: Any] in list {
                if sessions.count == maxSessions { break }
                guard let name = HerdrAgent.string(item["name"], max: 80), isName(name) else { continue }
                sessions.append(HerdrSession(name: name, isDefault: HerdrAgent.boolean(item["default"]),
                                             running: HerdrAgent.boolean(item["running"])))
            }
            // A stable sort: herdr's order within each part.
            return sessions.filter(\.isDefault) + sessions.filter { !$0.isDefault }
        }
    }
}

/// herdr's tabs, as `herdr tab list` lists them: only which one has herdr's focus is read.
public enum HerdrTabs {
    /// The tab herdr's focus is in: the first one its list marks focused (`"focused": true`, a boolean); nil when none is,
    /// or when the answer is not herdr's list.
    public static func focusedTab(_ output: String) -> String? {
        HerdrAgent.scan(HerdrAgent.plain(output)) { value, _ -> String?? in
            guard let object = value as? [String: Any], object["error"] == nil else { return nil }
            let body = object["result"] as? [String: Any] ?? object
            guard let tabs = body["tabs"] as? [Any] else { return nil }
            for case let tab as [String: Any] in tabs where HerdrAgent.boolean(tab["focused"]) {
                return .some(HerdrAgent.string(tab["tab_id"], max: 80))
            }
            return .some(nil)
        } ?? nil
    }
}
