import Foundation

/// One machine saved in a herdr on this Mac (`herdr machine list --json`, herdr 0.9.0 and later): herdr's own id for it,
/// its label, and whether herdr has it enabled. Its SSH target and session stay herdr's: Next Term keeps neither, and
/// reaches the machine only through that herdr (`herdr --machine <id> agent …`), over herdr's own connection.
public struct HerdrMachine: Equatable, Sendable {
    public var id: String
    public var label: String
    public var enabled: Bool

    public init(id: String, label: String, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.enabled = enabled
    }
}

/// herdr's list of its saved machines, read only: Next Term never adds, renames, enables, disables or removes one, which
/// stays `herdr machine …` in a terminal.
public enum HerdrMachines {
    /// The most of a herdr's machines followed at once: one is read per check, in turn.
    public static let followed = 4

    /// The machines in `text`: herdr's JSON list, at the top or under `machines` or `result`; unknown fields ignored, an
    /// id herdr would not give (HerdrTarget.isMachine) left out, the label cut to 80 characters without control
    /// characters (the id when it has none). nil when `text` is not such a list.
    public static func parse(_ text: String) -> [HerdrMachine]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let rows = list(top) else { return nil }
        return rows.compactMap { row -> HerdrMachine? in
            guard let object = row as? [String: Any], let id = object["id"] as? String, HerdrTarget.isMachine(id) else { return nil }
            let label = HerdrAgent.string(object["label"], max: 80).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let enabled = (object["enabled"] as? Bool) ?? true
            return HerdrMachine(id: id, label: label, enabled: enabled)
        }
    }

    private static func list(_ value: Any) -> [Any]? {
        if let rows = value as? [Any] { return rows }
        guard let object = value as? [String: Any] else { return nil }
        if let rows = object["machines"] as? [Any] { return rows }
        return object["result"].flatMap(list)
    }

    /// The machines followed: the first `followed` enabled ones, in herdr's order; the rest wait for one of them to go.
    public static func followedMachines(_ machines: [HerdrMachine]) -> [HerdrMachine] {
        Array(machines.filter(\.enabled).prefix(followed))
    }

    /// The machine check `tick` reads, one per check, round the followed ones; nil with none.
    public static func machine(at tick: Int, of machines: [HerdrMachine]) -> HerdrMachine? {
        let shown = followedMachines(machines)
        guard !shown.isEmpty else { return nil }
        return shown[max(0, tick) % shown.count]
    }

    /// Reads in a row that failed before one machine is said to be out of reach.
    public static let failuresBeforeUnreachable = 3
}
