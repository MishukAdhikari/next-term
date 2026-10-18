/// When a key Copy put on the clipboard is cleared: once, and only while the clipboard still holds it, which its change
/// count tells (the count Copy left). Copy's own timer asks with the count it was set for, so an earlier copy's timer
/// leaves a newer copy alone; Next Term quitting, or the Mac locking or going to sleep, asks for whatever copy is still
/// due, so a key copied just before never outlives the app or waits out the sleep.
public struct SecretCopyClear: Sendable, Equatable {
    /// The change count Copy left, while its clear is due.
    public private(set) var copiedCount: Int?

    public init() {}

    /// Copy wrote a key, and the clipboard's change count is now `count`.
    public mutating func copied(_ count: Int) {
        copiedCount = count
    }

    /// The clear Copy set for `count` came due, with the clipboard at change count `current`. True when the clipboard
    /// is to be cleared: that copy is the one still due and nothing was copied since. Either way it is no longer due.
    public mutating func due(_ count: Int, current: Int) -> Bool {
        guard copiedCount == count else { return false }
        copiedCount = nil
        return current == count
    }

    /// The quit, a lock or a sleep, with the clipboard at change count `current`: true when a copy is still due and the
    /// clipboard still holds it.
    public mutating func now(current: Int) -> Bool {
        guard let count = copiedCount else { return false }
        return due(count, current: current)
    }
}
