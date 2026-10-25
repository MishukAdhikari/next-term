import Foundation

/// A project's colour (View › Project Color): one of nine named hues, shown as a still glow along the top row of its
/// window from the corner behind the traffic lights, and as the dot of its row in the Welcome window. Kept as its index
/// (`rawValue`), so a light palette can later give each index a shade of its own, as the IDEs ship one palette per theme.
public enum ProjectColor: Int, CaseIterable, Sendable {
    case amber, rust, olive, sky, cobalt, plum, violet, ocean, grass

    /// How strong the glow is where it is strongest: its OKLCH chroma, at the bar's own lightness. The one number to tune
    /// once it has been seen: 0.04 is a quarter to a half of what the IDEs' dark headers use. Raise it (up to about 0.06)
    /// rather than the lightness, and the contrast test says whether the bar's text still reads.
    public static let glowChroma: Double = 0.04
    /// The menus' circles and the Welcome window's dots: light enough to be read as the hue on a dark row.
    static let swatchLightness: Double = 0.74
    static let swatchChroma: Double = 0.12

    /// "Amber", as the menus say it.
    public var name: String {
        switch self {
        case .amber: return "Amber"
        case .rust: return "Rust"
        case .olive: return "Olive"
        case .sky: return "Sky"
        case .cobalt: return "Cobalt"
        case .plum: return "Plum"
        case .violet: return "Violet"
        case .ocean: return "Ocean"
        case .grass: return "Grass"
        }
    }

    /// "amber": what a menu item carries, so each has a shortcut id of its own.
    public var id: String { name.lowercased() }

    public init?(id: String) {
        guard let color = Self.allCases.first(where: { (color: ProjectColor) -> Bool in color.id == id }) else { return nil }
        self = color
    }

    /// Its hue, in OKLCH degrees: nine apart enough to tell side by side, in the order the names go round.
    var hue: Double {
        switch self {
        case .amber: return 75
        case .rust: return 35
        case .olive: return 110
        case .sky: return 230
        case .cobalt: return 265
        case .plum: return 340
        case .violet: return 300
        case .ocean: return 190
        case .grass: return 145
        }
    }

    /// The glow's strongest colour on a bar of colour `bar` (0xRRGGBB): the bar's own lightness, so its text reads as it
    /// does on the bar, in this hue at `glowChroma`.
    public func glow(on bar: UInt32) -> UInt32 {
        OKLab(lightness: OKLab(rgb: bar).l, chroma: Self.glowChroma, hue: hue).rgb
    }

    /// The colour as a swatch: a menu item's circle, a Welcome row's dot.
    public var swatch: UInt32 {
        OKLab(lightness: Self.swatchLightness, chroma: Self.swatchChroma, hue: hue).rgb
    }

    /// The contrast ratio of two colours (0xRRGGBB), as WCAG 2 measures it: 1 to 21, 4.5 the least for small text.
    public static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a: Double = OKLab.luminance(first), b: Double = OKLab.luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension ProjectColor {
    /// How the glow fades: all of it at the window's left edge, behind the traffic lights, none from `reach` on. A raised
    /// cosine between, flat at both ends, so it has no edge where it ends and no peak to look at where it starts.
    public enum Glow {
        /// How far in from the window's left edge it reaches, in points.
        public static let reach: Double = 320
        /// How much of it an inactive window keeps (the IDEs' Islands themes keep 0.56).
        public static let inactive: Double = 0.55

        /// How much of the colour shows `x` points in from the window's left edge: 1 at the edge, 0 from `reach` on.
        public static func strength(at x: Double) -> Double {
            guard x > 0 else { return 1 }
            guard x < reach else { return 0 }
            return 0.5 + 0.5 * cos(Double.pi * x / reach)
        }

        /// The fade as a gradient's stops, `count` of them evenly along `reach`: where each is (0 to 1) and how much of
        /// the colour shows there.
        public static func stops(_ count: Int = 9) -> [(location: Double, strength: Double)] {
            let last: Int = max(1, count - 1)
            return (0...last).map { (index: Int) -> (location: Double, strength: Double) in
                let location: Double = Double(index) / Double(last)
                return (location, strength(at: location * reach))
            }
        }
    }
}

/// Every project's colour, kept in Next Term's own defaults under the project's key (`key(forProject:repository:)`): its
/// colour, or None for This Project, and whether the user chose it. A colour is picked once, the first time the project
/// opens, and never again by itself: only View › Project Color changes it. Nothing is written into the project.
public struct ProjectColors: Equatable, Sendable {
    /// Where they are kept.
    public static let key = "projectColors"
    /// Where the next pick starts among the colours used least: it rolls on with each pick.
    public static let nextKey = "projectColorNext"
    /// Show Project Colors: off, no window and no Welcome row shows a colour. Each project keeps its own meanwhile.
    public static let shownKey = "showProjectColors"
    /// Far more projects than anyone opens: the oldest go first past it, never one a window has open.
    public static let limit = 400

    public struct Entry: Equatable, Sendable {
        /// nil: None for This Project.
        public var color: ProjectColor?
        /// The user chose it (a colour, or None), not the automatic pick.
        public var chosen: Bool
        /// When it was set, in seconds on any one clock (the caller's): the oldest goes first past `limit`.
        public var setAt: Double

        public init(color: ProjectColor?, chosen: Bool, setAt: Double) {
            self.color = color
            self.chosen = chosen
            self.setAt = setAt
        }
    }

    public private(set) var entries: [String: Entry]
    /// The palette index the next pick starts looking from.
    public private(set) var next: Int

    public init(_ entries: [String: Entry] = [:], next: Int = 0) {
        self.entries = entries
        self.next = Self.wrapped(next)
    }

    /// As kept in preferences: a dictionary from key to `index` (-1: None), `chosen` and `setAt`, and the counter. What is
    /// not an entry (not a dictionary, no index that is a number, or one past the palette) is left out.
    public init(propertyList: Any?, next: Any?) {
        var entries: [String: Entry] = [:]
        for (key, value) in propertyList as? [String: Any] ?? [:] {
            guard let fields = value as? [String: Any], let index = (fields["index"] as? NSNumber)?.intValue else { continue }
            let color: ProjectColor? = ProjectColor(rawValue: index)
            guard color != nil || index == -1 else { continue }
            let chosen: Bool = fields["chosen"] as? Bool ?? false
            let setAt: Double = (fields["setAt"] as? NSNumber)?.doubleValue ?? 0
            entries[key] = Entry(color: color, chosen: chosen, setAt: setAt)
        }
        self.init(entries, next: (next as? NSNumber)?.intValue ?? 0)
    }

    /// To keep in preferences, under `key`; `next` goes under `nextKey`.
    public var propertyList: [String: Any] {
        var list: [String: Any] = [:]
        for (key, entry) in entries {
            let fields: [String: Any] = ["index": entry.color?.rawValue ?? -1, "chosen": entry.chosen, "setAt": entry.setAt]
            list[key] = fields
        }
        return list
    }

    public func entry(for key: String) -> Entry? { entries[key] }

    /// Show Project Colors as kept: on unless turned off.
    public static func shown(_ value: Any?) -> Bool { value as? Bool ?? true }

    // MARK: picking

    /// The colour least used by `inUse` (the colours of the open project windows, one per window), and of those the first
    /// at or after `next` in the palette's order, so ties go round the palette instead of always to Amber.
    public static func pick(inUse: [ProjectColor], next: Int) -> ProjectColor {
        var uses: [Int] = Array(repeating: 0, count: ProjectColor.allCases.count)
        for color in inUse { uses[color.rawValue] += 1 }
        let fewest: Int = uses.min() ?? 0
        let start: Int = wrapped(next)
        for step in uses.indices {
            let index: Int = (start + step) % uses.count
            if uses[index] == fewest, let color = ProjectColor(rawValue: index) { return color }
        }
        return .amber
    }

    /// `key`'s colour, picked now if it has none (see `pick`), with the counter moved on past it; one it has is kept as it
    /// is, chosen or not. The colour is nil for None for This Project. `open`: the keys of the open windows, which the
    /// limit never drops.
    public func assigning(_ key: String, inUse: [ProjectColor], now: Double,
                          open: Set<String> = []) -> (colors: ProjectColors, color: ProjectColor?) {
        if let entry = entries[key] { return (self, entry.color) }
        let color: ProjectColor = Self.pick(inUse: inUse, next: next)
        var colors: ProjectColors = setting(Entry(color: color, chosen: false, setAt: now), for: key, open: open)
        colors.next = Self.wrapped(color.rawValue + 1)
        return (colors, color)
    }

    /// The user's choice for `key`: one of the colours, or None for This Project (nil).
    public func choosing(_ color: ProjectColor?, for key: String, now: Double, open: Set<String> = []) -> ProjectColors {
        setting(Entry(color: color, chosen: true, setAt: now), for: key, open: open)
    }

    /// Automatic: a colour the user chose, or None, gives way to a pick made now, as on a first open; an automatic one stays.
    public func automatic(for key: String, inUse: [ProjectColor], now: Double, open: Set<String> = []) -> ProjectColors {
        guard entries[key]?.chosen ?? true else { return self }
        var cleared: ProjectColors = self
        cleared.entries[key] = nil
        return cleared.assigning(key, inUse: inUse, now: now, open: open).colors
    }

    /// Without the keys whose folders are gone.
    public func pruned(exists: (String) -> Bool) -> ProjectColors {
        ProjectColors(entries.filter { (entry: (key: String, value: Entry)) -> Bool in exists(entry.key) }, next: next)
    }

    /// With `entry` for `key`; past `limit`, the least recently set go, except the open windows' keys.
    private func setting(_ entry: Entry, for key: String, open: Set<String>) -> ProjectColors {
        var kept: [String: Entry] = entries
        kept[key] = entry
        guard kept.count > Self.limit else { return ProjectColors(kept, next: next) }
        let oldestFirst: [String] = kept.keys.filter { (other: String) -> Bool in other != key && !open.contains(other) }
            .sorted { (first: String, second: String) -> Bool in
                let a: Double = kept[first]?.setAt ?? 0
                let b: Double = kept[second]?.setAt ?? 0
                return a == b ? first < second : a < b
            }
        for other in oldestFirst.prefix(kept.count - Self.limit) { kept[other] = nil }
        return ProjectColors(kept, next: next)
    }

    private static func wrapped(_ index: Int) -> Int {
        let count: Int = ProjectColor.allCases.count
        return ((index % count) + count) % count
    }

    // MARK: whose colour

    /// The key a project's colour is kept under: for a linked worktree its repository's main checkout, so xCloud and every
    /// xcloud-wt-* window share one colour (their titles and branches tell them apart), else the project's own folder;
    /// as the kernel spells it (canonicalPath), so no spelling or case of it splits one project in two. nil with no
    /// project, or for a folder that is never one (the home folder): those windows have no colour.
    public static func key(forProject project: String?, repository: WorktreeWindow.Repository?,
                           places: ProtectedPlaces = .current) -> String? {
        guard let project, !places.isNeverRoot(project) else { return nil }
        return canonicalPath(repository?.mainCheckout ?? project)
    }

    /// The same, with the repository read from git's own files (no git run).
    public static func key(forProject project: String?, places: ProtectedPlaces = .current) -> String? {
        let repository: WorktreeWindow.Repository? = project.flatMap(WorktreeWindow.repository(ofLinkedWorktree:))
        return key(forProject: project, repository: repository, places: places)
    }
}

/// Colours in OKLab, Björn Ottosson's perceptual space: lightness `l` (0 black, 1 white) and the `a`, `b` axes. Close
/// enough to how the eye sees that a glow of one lightness reads as one brightness whatever its hue.
struct OKLab: Equatable {
    var l, a, b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From OKLCH: lightness, chroma and hue in degrees.
    init(lightness: Double, chroma: Double, hue: Double) {
        let radians: Double = hue * Double.pi / 180
        self.init(l: lightness, a: chroma * cos(radians), b: chroma * sin(radians))
    }

    /// From an sRGB colour, 0xRRGGBB.
    init(rgb: UInt32) {
        let (r, g, b): (Double, Double, Double) = Self.linear(rgb)
        let l: Double = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m: Double = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s: Double = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var chroma: Double { (a * a + b * b).squareRoot() }

    /// In linear sRGB, before any clipping: outside 0...1 the colour is outside sRGB.
    var linearRGB: (r: Double, g: Double, b: Double) {
        let l: Double = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m: Double = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s: Double = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let red: Double = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green: Double = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue: Double = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (red, green, blue)
    }

    /// Within sRGB, so `rgb` is the colour itself, not a clipped one of another hue.
    var inGamut: Bool {
        let rgb = linearRGB
        return [rgb.r, rgb.g, rgb.b].allSatisfy { (value: Double) -> Bool in value >= -0.0005 && value <= 1.0005 }
    }

    /// As an sRGB colour, 0xRRGGBB, clipped to sRGB.
    var rgb: UInt32 {
        let linear = linearRGB
        let channels: [UInt32] = [linear.r, linear.g, linear.b].map { (value: Double) -> UInt32 in
            UInt32((Self.encoded(min(1, max(0, value))) * 255).rounded())
        }
        return channels[0] << 16 | channels[1] << 8 | channels[2]
    }

    /// WCAG 2's relative luminance of an sRGB colour, 0xRRGGBB.
    static func luminance(_ rgb: UInt32) -> Double {
        let (r, g, b): (Double, Double, Double) = linear(rgb)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func linear(_ rgb: UInt32) -> (Double, Double, Double) {
        func channel(_ shift: UInt32) -> Double {
            let value: Double = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return (channel(16), channel(8), channel(0))
    }

    private static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
