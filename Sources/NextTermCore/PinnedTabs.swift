import Foundation

/// Pinned tabs (plan 045): a tab the user pins sits first in its window, after the tabs pinned before it, compact and
/// set apart by a divider; bulk closes leave it, ⌘W asks first, and it comes back pinned. The order rules are here, pure;
/// the window keeps the flags on its tabs.
public enum PinnedTabs {
    /// Where a tab at `index` goes when pinned: just after the pinned tabs, the others keeping their order.
    public static func indexWhenPinned(_ index: Int, pinned: [Bool]) -> Int {
        pinned.enumerated().filter { $0.offset != index && $0.element }.count
    }

    /// Where a pinned tab at `index` goes when unpinned: just after the pinned group, first of the others.
    public static func indexWhenUnpinned(_ index: Int, pinned: [Bool]) -> Int {
        pinned.enumerated().filter { $0.offset != index && $0.element }.count
    }

    /// Where a drag from `from` to `to` may land: a pinned tab stays among the pinned ones, any other among the rest.
    public static func clampedMove(from: Int, to: Int, pinned: [Bool]) -> Int {
        let count = pinned.filter { $0 }.count
        return (pinned.indices.contains(from) && pinned[from]) ? min(max(to, 0), max(count - 1, 0)) : max(to, count)
    }

    /// The tabs Close Other Tabs or Close Tabs to the Right may close: never a pinned one.
    public static func closable(_ indices: [Int], pinned: [Bool]) -> [Int] {
        indices.filter { !(pinned.indices.contains($0) && pinned[$0]) }
    }

    /// The confirmation for ⌘W on a pinned tab, with what closing stops when it does.
    public static func closeQuestion(title: String) -> String {
        "Close the pinned tab \u{201C}\(title)\u{201D}?"
    }
}
