import Foundation
import Testing
@testable import NextTermCore

/// View › Project Color: the nine colours, the glow's strength and fade, the pick (least used, then a rolling counter,
/// never again by itself), the key a worktree shares with its repository, and how they are kept.
@Suite struct ProjectColorTests {
    /// Theme.bar, Theme.text and Theme.textDim (Sources/NextTerm/Theme.swift): the bar the glow is on and its text.
    static let bar: UInt32 = 0x2B2D30
    static let text: UInt32 = 0xDFE1E5
    static let textDim: UInt32 = 0x9DA0A8

    // MARK: the palette

    @Test func nineNamedColoursInTheIDEsOrder() {
        #expect(ProjectColor.allCases.map(\.name) == ["Amber", "Rust", "Olive", "Sky", "Cobalt", "Plum", "Violet", "Ocean", "Grass"])
        // Kept as the index: Sky is 3, as it is in the IDEs' own palette.
        #expect(ProjectColor.sky.rawValue == 3)
        #expect(ProjectColor(id: "cobalt") == .cobalt)
        #expect(ProjectColor(id: "Cobalt") == nil)
        #expect(Set(ProjectColor.allCases.map(\.id)).count == 9)
    }

    @Test func theGlowKeepsTheBarsLightnessAndOnlyAddsHue() {
        let barLightness: Double = OKLab(rgb: Self.bar).l
        #expect(abs(barLightness - 0.296) < 0.001)
        for color in ProjectColor.allCases {
            let exact = OKLab(lightness: barLightness, chroma: ProjectColor.glowChroma, hue: color.hue)
            #expect(exact.inGamut, "\(color.name) is an sRGB colour, not a clipped one")
            let peak = OKLab(rgb: color.glow(on: Self.bar))
            // As near as 8 bits a channel get.
            #expect(abs(peak.l - barLightness) < 0.005, "\(color.name): lightness \(peak.l)")
            #expect(abs(peak.chroma - ProjectColor.glowChroma) < 0.006, "\(color.name): chroma \(peak.chroma)")
        }
    }

    @Test func theBarsTextReadsOnEveryColoursPeak() {
        for color in ProjectColor.allCases {
            let peak: UInt32 = color.glow(on: Self.bar)
            let text: Double = ProjectColor.contrast(Self.text, peak)
            let dim: Double = ProjectColor.contrast(Self.textDim, peak)
            #expect(text >= 4.5, "\(color.name): text \(text):1 on #\(String(peak, radix: 16))")
            #expect(dim >= 4.5, "\(color.name): textDim \(dim):1 on #\(String(peak, radix: 16))")
        }
        // The measure itself: black on white is 21:1, a colour on itself 1:1, either way round.
        #expect(abs(ProjectColor.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
        #expect(ProjectColor.contrast(Self.bar, Self.bar) == 1)
        #expect(ProjectColor.contrast(Self.text, Self.bar) == ProjectColor.contrast(Self.bar, Self.text))
    }

    @Test func theNineAreToldApart() {
        // Every two peaks differ by more than the glow's own steps, and every two swatches clearly.
        let peaks: [OKLab] = ProjectColor.allCases.map { OKLab(rgb: $0.glow(on: Self.bar)) }
        let swatches: [OKLab] = ProjectColor.allCases.map { OKLab(rgb: $0.swatch) }
        func distance(_ x: OKLab, _ y: OKLab) -> Double {
            let dl: Double = x.l - y.l, da: Double = x.a - y.a, db: Double = x.b - y.b
            return (dl * dl + da * da + db * db).squareRoot()
        }
        for i in peaks.indices {
            for j in peaks.indices where j > i {
                #expect(distance(peaks[i], peaks[j]) > 0.015, "\(ProjectColor.allCases[i].name) and \(ProjectColor.allCases[j].name)")
                #expect(distance(swatches[i], swatches[j]) > 0.05)
            }
        }
        for color in ProjectColor.allCases {
            #expect(OKLab(lightness: ProjectColor.swatchLightness, chroma: ProjectColor.swatchChroma, hue: color.hue).inGamut)
            // A dot to see on the Welcome window's dark rows (3:1, as for any mark that is not text).
            #expect(ProjectColor.contrast(color.swatch, 0x1E1F22) >= 3)
        }
    }

    /// The window column's badges: two letters in Theme.text read on every colour's badge and the neutral one (4.5:1), each
    /// badge shows against the bar it sits on, and the nine are told apart there too.
    @Test func theBadgesLettersReadOnEveryColour() {
        let badges: [UInt32] = ProjectColor.allCases.map(\.badge) + [ProjectColor.neutralBadge]
        for badge in badges {
            let text: Double = ProjectColor.contrast(Self.text, badge)
            #expect(text >= 4.5, "text \(text):1 on #\(String(badge, radix: 16))")
            #expect(OKLab(rgb: badge).l - OKLab(rgb: Self.bar).l > 0.1, "#\(String(badge, radix: 16)) on the bar")
        }
        for color in ProjectColor.allCases {
            #expect(OKLab(lightness: ProjectColor.badgeLightness, chroma: ProjectColor.badgeChroma, hue: color.hue).inGamut, "\(color.name)")
        }
        let tiles: [OKLab] = ProjectColor.allCases.map { OKLab(rgb: $0.badge) }
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let dl: Double = tiles[i].l - tiles[j].l, da: Double = tiles[i].a - tiles[j].a, db: Double = tiles[i].b - tiles[j].b
                #expect((dl * dl + da * da + db * db).squareRoot() > 0.03, "\(ProjectColor.allCases[i].name) and \(ProjectColor.allCases[j].name)")
            }
        }
    }

    @Test func oklabRoundTrips() {
        for rgb: UInt32 in [0x000000, 0xFFFFFF, 0x2B2D30, 0x3574F0, 0xE55765, 0x5FB865] {
            #expect(OKLab(rgb: rgb).rgb == rgb, "#\(String(rgb, radix: 16))")
        }
        #expect(abs(OKLab(rgb: 0xFFFFFF).l - 1) < 0.0001)
        #expect(OKLab(rgb: 0x000000).l == 0)
    }

    // MARK: the fade

    @Test func theGlowFadesFromTheCornerToNothingAt320() {
        #expect(ProjectColor.Glow.reach == 320)
        #expect(ProjectColor.Glow.inactive == 0.55)
        #expect(ProjectColor.Glow.strength(at: 0) == 1)
        #expect(ProjectColor.Glow.strength(at: -10) == 1)
        #expect(ProjectColor.Glow.strength(at: 320) == 0)
        #expect(ProjectColor.Glow.strength(at: 900) == 0)
        #expect(abs(ProjectColor.Glow.strength(at: 160) - 0.5) < 0.0001)
        // Behind the traffic lights it is nearly all there; it only ever fades going in.
        #expect(ProjectColor.Glow.strength(at: 70) > 0.85)
        var last: Double = 1
        for x in stride(from: 0.0, through: 320, by: 8) {
            let strength: Double = ProjectColor.Glow.strength(at: x)
            #expect(strength <= last)
            last = strength
        }
        let stops = ProjectColor.Glow.stops()
        #expect(stops.count == 9)
        #expect(stops.first?.location == 0 && stops.first?.strength == 1)
        #expect(stops.last?.location == 1 && stops.last?.strength == 0)
        #expect(ProjectColor.Glow.stops(1).count == 2)
    }

    // MARK: the pick

    @Test func aNewProjectGetsTheColourLeastUsed() {
        #expect(ProjectColors.pick(inUse: [], next: 0) == .amber)
        #expect(ProjectColors.pick(inUse: [.amber], next: 0) == .rust)
        #expect(ProjectColors.pick(inUse: [.amber, .rust, .olive], next: 0) == .sky)
        // All nine in use, Amber twice: the next with one window.
        let everyOne: [ProjectColor] = ProjectColor.allCases + [.amber]
        #expect(ProjectColors.pick(inUse: everyOne, next: 0) == .rust)
        // Counted by window: the colour on two windows is used more than the one on one.
        let twice: [ProjectColor] = ProjectColor.allCases + ProjectColor.allCases.filter { $0 != .plum }
        #expect(ProjectColors.pick(inUse: twice, next: 0) == .plum)
    }

    @Test func tiesGoRoundThePaletteByTheCounter() {
        #expect(ProjectColors.pick(inUse: [], next: 4) == .cobalt)
        #expect(ProjectColors.pick(inUse: [.cobalt], next: 4) == .plum)
        #expect(ProjectColors.pick(inUse: [], next: 8) == .grass)
        // Past the end it wraps round, even from a counter out of range.
        #expect(ProjectColors.pick(inUse: [.grass], next: 8) == .amber)
        #expect(ProjectColors.pick(inUse: [], next: 13) == .cobalt)
        #expect(ProjectColors.pick(inUse: [], next: -1) == .grass)

        // Opened one after another with nothing else open, each takes the next colour: the counter rolls on.
        var colors = ProjectColors()
        var picked: [ProjectColor?] = []
        for project in ["/a", "/b", "/c"] {
            let result = colors.assigning(project, inUse: [], now: 1)
            colors = result.colors
            picked.append(result.color)
        }
        #expect(picked == [.amber, .rust, .olive])
        #expect(colors.next == 3)
    }

    @Test func aColourIsNeverPickedAgain() {
        let first = ProjectColors().assigning("/app", inUse: [.amber, .rust], now: 1)
        #expect(first.color == .olive)
        #expect(first.colors.entry(for: "/app") == ProjectColors.Entry(color: .olive, chosen: false, setAt: 1))
        // Opened again with Olive taken by every other window: it stays Olive, and the counter stays.
        let again = first.colors.assigning("/app", inUse: [.olive, .olive], now: 50)
        #expect(again.color == .olive)
        #expect(again.colors == first.colors)
        // A colour the user chose stays too, and None stays none.
        let chosen = first.colors.choosing(.plum, for: "/app", now: 2)
        #expect(chosen.assigning("/app", inUse: [], now: 3).color == .plum)
        let none = first.colors.choosing(nil, for: "/app", now: 2)
        #expect(none.assigning("/app", inUse: [], now: 3).color == nil)
        #expect(none.entry(for: "/app") == ProjectColors.Entry(color: nil, chosen: true, setAt: 2))
    }

    @Test func automaticPicksAgainOnlyForAChoice() {
        let picked = ProjectColors().assigning("/app", inUse: [], now: 1).colors
        // Already automatic: nothing changes.
        #expect(picked.automatic(for: "/app", inUse: [.amber, .rust], now: 2) == picked)
        // Chosen, or None: a new automatic pick, from the colours the other windows leave.
        let chosen = picked.choosing(.sky, for: "/app", now: 2)
        let back = chosen.automatic(for: "/app", inUse: [.amber, .rust], now: 3)
        #expect(back.entry(for: "/app") == ProjectColors.Entry(color: .olive, chosen: false, setAt: 3))
        let none = picked.choosing(nil, for: "/app", now: 2)
        #expect(none.automatic(for: "/app", inUse: [], now: 3).entry(for: "/app")?.color != nil)
        // A key never seen gets its first pick.
        #expect(ProjectColors().automatic(for: "/new", inUse: [], now: 1).entry(for: "/new")?.color == .amber)
    }

    // MARK: keeping them

    @Test func keptAndReadBack() {
        let colors = ProjectColors([
            "/a": .init(color: .ocean, chosen: false, setAt: 10),
            "/b": .init(color: nil, chosen: true, setAt: 20),
            "/c": .init(color: .violet, chosen: true, setAt: 30),
        ], next: 5)
        let read = ProjectColors(propertyList: colors.propertyList, next: colors.next)
        #expect(read == colors)
        #expect(read.entry(for: "/b")?.color == nil && read.entry(for: "/b")?.chosen == true)
        // What is not an entry is left out; nothing at all reads as none.
        let mixed: [String: Any] = ["/ok": ["index": 2], "/far": ["index": 9], "/word": ["index": "two"], "/plain": 3]
        let tolerant = ProjectColors(propertyList: mixed, next: "x")
        #expect(tolerant.entries.keys.sorted() == ["/ok"])
        #expect(tolerant.entry(for: "/ok") == ProjectColors.Entry(color: .olive, chosen: false, setAt: 0))
        #expect(tolerant.next == 0)
        #expect(ProjectColors(propertyList: nil, next: nil) == ProjectColors())
    }

    @Test func throughUserDefaults() throws {
        let (defaults, name) = try TestDefaults.make("project-colors")
        defer { TestDefaults.remove(defaults, name) }
        #expect(ProjectColors.shown(defaults.object(forKey: ProjectColors.shownKey))) // on until turned off
        let first = ProjectColors().assigning("/Users/me/Code/app", inUse: [.amber], now: 7)
        defaults.set(first.colors.propertyList, forKey: ProjectColors.key)
        defaults.set(first.colors.next, forKey: ProjectColors.nextKey)
        defaults.set(false, forKey: ProjectColors.shownKey)
        let read = ProjectColors(propertyList: defaults.dictionary(forKey: ProjectColors.key),
                                 next: defaults.object(forKey: ProjectColors.nextKey))
        #expect(read == first.colors)
        #expect(read.entry(for: "/Users/me/Code/app")?.color == .rust)
        #expect(read.next == ProjectColor.olive.rawValue)
        #expect(!ProjectColors.shown(defaults.object(forKey: ProjectColors.shownKey)))
    }

    @Test func goneFoldersGoAndTheLimitSparesOpenWindows() {
        let colors = ProjectColors(["/here": .init(color: .sky, chosen: false, setAt: 1), "/gone": .init(color: .rust, chosen: true, setAt: 2)])
        #expect(colors.pruned { $0 == "/here" }.entries.keys.sorted() == ["/here"])
        var many = ProjectColors()
        for index in 0..<ProjectColors.limit {
            many = many.choosing(.amber, for: "/p\(index)", now: Double(index))
        }
        #expect(many.entries.count == ProjectColors.limit)
        // One more: the oldest goes, unless a window has it open, then the next oldest.
        let past = many.choosing(.rust, for: "/new", now: 1000, open: ["/p0"])
        #expect(past.entries.count == ProjectColors.limit)
        #expect(past.entry(for: "/p0") != nil && past.entry(for: "/p1") == nil && past.entry(for: "/new")?.color == .rust)
    }

    // MARK: whose colour

    @Test func aWorktreeSharesItsRepositorysColour() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let linked = repo.base + "/xcloud-wt-6960", nested = repo.path + "/.claude/worktrees/side"
        repo.run(["worktree", "add", "-q", "-b", "fix/6960", linked])
        repo.run(["worktree", "add", "-q", "-b", "side", nested])
        let places = ProtectedPlaces(home: repo.base + "/home")
        let main: String? = ProjectColors.key(forProject: repo.path, places: places)
        #expect(main == repo.path)
        // Both worktrees, beside it in another case and inside it, are the repository's.
        #expect(ProjectColors.key(forProject: linked, places: places) == main)
        #expect(ProjectColors.key(forProject: nested, places: places) == main)
        // A folder in the repository opened as a project of its own is its own.
        try FileManager.default.createDirectory(atPath: repo.path + "/docs", withIntermediateDirectories: true)
        #expect(ProjectColors.key(forProject: repo.path + "/docs", places: places) == repo.path + "/docs")
        // Then the colour picked for one is the other's.
        let picked = ProjectColors().assigning(try #require(main), inUse: [], now: 1)
        let fromWorktree = try #require(ProjectColors.key(forProject: linked, places: places))
        #expect(picked.colors.assigning(fromWorktree, inUse: [], now: 2).color == picked.color)
    }

    @Test func noProjectAndTheHomeFolderHaveNoColour() {
        let places = ProtectedPlaces(home: "/Users/me")
        #expect(ProjectColors.key(forProject: nil, repository: nil, places: places) == nil)
        #expect(ProjectColors.key(forProject: "/Users/me", repository: nil, places: places) == nil)
        #expect(ProjectColors.key(forProject: "/Users/me/", repository: nil, places: places) == nil)
        #expect(ProjectColors.key(forProject: "/", repository: nil, places: places) == nil)
        #expect(ProjectColors.key(forProject: "/Users/me/Code/app", repository: nil, places: places) == "/Users/me/Code/app")
        let repository = WorktreeWindow.Repository(name: "xCloud", mainCheckout: "/Users/me/Code/xCloud")
        #expect(ProjectColors.key(forProject: "/Users/me/Code/xcloud-wt-1", repository: repository, places: places) == "/Users/me/Code/xCloud")
    }
}
