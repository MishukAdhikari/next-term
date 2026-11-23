import Foundation

/// The hint triggers waiting for their moment (HintStage): each since when, on the uptime clock. A trigger fired again
/// starts its wait again; one that no longer holds, or has waited `HintWaits.atMost`, is dropped; the ones left are
/// tried in `Hint.allCases` order, so two waiting at once always meet in the same order.
public struct HintWaits: Equatable, Sendable {
    /// How long a trigger waits for its moment.
    public static let atMost: TimeInterval = 10 * 60

    public private(set) var since: [Hint: TimeInterval] = [:]

    public init() {}

    public var isEmpty: Bool { since.isEmpty }
    public func contains(_ hint: Hint) -> Bool { since[hint] != nil }

    /// `hint`'s trigger fired at `now`: it waits from then.
    public mutating func start(_ hint: Hint, now: TimeInterval) { since[hint] = now }

    public mutating func remove(_ hint: Hint) { since[hint] = nil }
    public mutating func removeAll() { since = [:] }

    /// Drops each trigger that has waited longer than `atMost` by `now`, or that `holds` says no longer holds.
    public mutating func drop(now: TimeInterval, atMost: TimeInterval = HintWaits.atMost, holds: (Hint) -> Bool) {
        for (hint, start) in since where now - start > atMost || !holds(hint) { since[hint] = nil }
    }

    /// The waiting hints, in the order they are tried.
    public var order: [Hint] { Hint.allCases.filter { since[$0] != nil } }
}
