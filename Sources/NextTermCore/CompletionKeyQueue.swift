import Foundation

/// The list's keys pressed while it walks (a folder being listed, or a key on a server's screen waiting for what it
/// typed to echo), and the keys typed after the first of them: one queue, in the order pressed (CompletionDrill).
///
/// A key acts once the list it acts on shows its rows. One that comes after keys typed since the walk began waits for
/// the shell's word with them first (the hook's `sync`, or a server's screen at rest), so ⇥ pressed after a letter
/// takes the row that letter narrowed to. Keys typed after a key that waits go to the shell after it. ↓ ↑ move the row
/// the next key takes, as the popup moves its own. CompletionSession drives it, one step at a time.
public struct CompletionKeyQueue {
    /// A list key that waits.
    public enum Key: Equatable, Sendable {
        /// ⇥ or →: into a folder; anything else on the line.
        case tab
        /// ↩︎: the name on the line.
        case enter
        /// ←: back up.
        case left
        /// ↓ ↑ (⌃N ⌃P, ⇧⇥): the chosen row moves by this many, stopping at the ends.
        case move(Int)
    }

    public enum Item: Equatable, Sendable {
        case key(Key)
        /// Keys typed after a list key that waits.
        case typed([UInt8])
    }

    /// What comes next.
    public enum Step: Equatable, Sendable {
        /// Nothing waits.
        case idle
        /// The front waits: for the list's rows, for what is in flight, or for the writes' hold to end.
        case wait
        /// Keys typed went to the shell since the walk began: the shell's word with them comes first. Next Term asks for
        /// it, then calls lineIn.
        case line
        /// These typed keys go to the shell now.
        case send([UInt8])
        /// This key acts now, on `row` of the list showing (for a move, the row it moved to).
        case act(Key, row: Int)
    }

    public private(set) var items: [Item] = []
    /// Keys typed went to the shell since the walk began, and the shell hasn't said its word with them since.
    public private(set) var typedSince = false

    /// The row the keys act on, as they are followed, on the list it was chosen on, with that list's rows then.
    private weak var rowList: CompletionList?
    private var rowGeneration = 0
    private var row = 0

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// A list key that waits. The first notes the row chosen on the list showing (`list` nil: none shows yet).
    public mutating func add(_ key: Key, on list: CompletionList?, row chosen: Int) {
        if items.isEmpty {
            rowList = list
            rowGeneration = list?.generation ?? 0
            row = chosen
        }
        items.append(.key(key))
    }

    /// Keys typed: behind a list key that waits, so they go out after it (true); or none waits and they go on (false).
    public mutating func type(_ bytes: [UInt8]) -> Bool {
        guard !items.isEmpty else { return false }
        items.append(.typed(bytes))
        return true
    }

    /// A walk began (⇥ on a folder): keys typed before it are the list's own already.
    public mutating func walkBegan() { typedSince = false }

    /// Keys typed went to the shell.
    public mutating func typed() { typedSince = true }

    /// The shell said its word with every key typed before (or a server's screen came to rest): the keys that wait act
    /// on the list for it.
    public mutating func lineIn() { typedSince = false }

    /// The list closed: its keys go, and never reach the shell. Returns the keys typed after them, to go out in order.
    public mutating func close() -> [[UInt8]] {
        let typed = items.compactMap { item -> [UInt8]? in
            if case let .typed(bytes) = item { return bytes }
            return nil
        }
        items = []
        rowList = nil
        return typed
    }

    /// The next step, with `list` showing (nil: none, or the Loading row), `busy` while a folder is listed or a key on a
    /// server's screen waits for its echo, and `hold` while writes wait (a folder Next Term lists, ← echoing).
    public mutating func next(list: CompletionList?, busy: Bool, hold: Bool) -> Step {
        guard let first = items.first else { return .idle }
        switch first {
        case let .typed(bytes):
            guard !hold else { return .wait }
            items.removeFirst()
            typedSince = true
            return .send(bytes)
        case let .key(key):
            guard !busy, let list, !list.rows.isEmpty else { return .wait }
            guard !typedSince else { return .line }
            items.removeFirst()
            let at = rowOn(list)
            guard case let .move(delta) = key else { return .act(key, row: at) }
            row = max(0, min(list.rows.count - 1, at + delta))
            return .act(key, row: row)
        }
    }

    /// The row the keys left `list` on; on a list not followed yet (a folder gone into, or back up to), or whose rows
    /// changed since (typing narrowed it), its own: the folder gone back up from, or the first, as the popup chooses.
    private mutating func rowOn(_ list: CompletionList) -> Int {
        if rowList !== list || rowGeneration != list.generation {
            rowList = list
            rowGeneration = list.generation
            row = list.preferredRow ?? 0
        }
        row = max(0, min(list.rows.count - 1, row))
        return row
    }
}
