import Foundation

/// The path a window with no project shows over the home folder's tree while it browses it: Home, then each folder below
/// it down to the folder of the selected row. Made from the path strings the tree already holds, so nothing on disk is
/// read for it; each title is the folder's name as the tree's row shows it.
public enum Breadcrumbs {
    public struct Segment: Equatable, Sendable {
        /// The folder's name on disk (Home's: the home folder's).
        public let title: String
        public let path: String

        public init(title: String, path: String) {
            self.title = title
            self.path = path
        }
    }

    /// Home, then each folder from it down to `folder`. A folder outside `home` gives Home alone: `/Users/adam` is
    /// outside `/Users/ada`. A trailing slash on either is ignored.
    public static func segments(to folder: String, home: String) -> [Segment] {
        let home = trimmed(home), folder = trimmed(folder)
        var segments = [Segment(title: (home as NSString).lastPathComponent, path: home)]
        let prefix = home == "/" ? "/" : home + "/"
        guard folder != home, folder.hasPrefix(prefix) else { return segments }
        var path = home
        for name in folder.dropFirst(prefix.count).split(separator: "/") {
            path = path == "/" ? "/" + name : path + "/" + name
            segments.append(Segment(title: String(name), path: path))
        }
        return segments
    }

    /// Which segments a bar too narrow for all of them leaves out.
    public struct Fit: Equatable, Sendable {
        /// The folders folded into one "…", by index: always after Home and before the last, empty when none fold.
        public var folded: Range<Int>
        /// Home shows its symbol without its name.
        public var homeSymbolOnly: Bool

        public init(folded: Range<Int>, homeSymbolOnly: Bool) {
            self.folded = folded
            self.homeSymbolOnly = homeSymbolOnly
        }
    }

    /// How segments of `widths` (Home's with its symbol and name) fit in `room`, with `separator` between two of them and
    /// `more` the width of the "…" that stands for folded ones. Home and the last segment always show. Until they fit,
    /// the folders after Home fold into the "…", the oldest first, then Home gives up its name for its symbol alone
    /// (`homeSymbolWidth`). What still does not fit is the last segment's to give: its title is cut in the middle.
    /// Widths are in points.
    public static func fit(widths: [Double], homeSymbolWidth: Double, separator: Double, more: Double, room: Double) -> Fit {
        func width(_ fit: Fit) -> Double {
            var total = 0.0, shown = 0
            for (index, segment) in widths.enumerated() where !fit.folded.contains(index) {
                total += index == 0 && fit.homeSymbolOnly ? homeSymbolWidth : segment
                shown += 1
            }
            if !fit.folded.isEmpty {
                total += more
                shown += 1
            }
            return total + Double(max(0, shown - 1)) * separator
        }
        // Folded up to (not including) `end`: 1..<1 is none.
        let lastEnd = max(1, widths.count - 1)
        for end in 1...lastEnd {
            let fit = Fit(folded: 1..<end, homeSymbolOnly: false)
            if width(fit) <= room { return fit }
        }
        return Fit(folded: 1..<lastEnd, homeSymbolOnly: true)
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
