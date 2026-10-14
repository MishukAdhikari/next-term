import AppKit
import NextTermCore

/// The project colours as Next Term keeps them (ProjectColors in Core): in its own defaults, under each project's key, with
/// Show Project Colors beside them. Read when a window takes its project and when a colour or the setting changes, never
/// in a window's refresh.
enum ProjectColorStore {
    /// A project's colour or Show Project Colors changed: every window paints its top row again, the Welcome window its dots.
    static let changed = Notification.Name("NextTermProjectColorsChanged")
    private static var defaults: UserDefaults { .standard }

    /// Show Project Colors (View › Project Color, Settings › General): on unless turned off. Off, the colours are kept.
    static var isShown: Bool {
        get { ProjectColors.shown(defaults.object(forKey: ProjectColors.shownKey)) }
        set {
            guard newValue != isShown else { return }
            defaults.set(newValue, forKey: ProjectColors.shownKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func read() -> ProjectColors {
        ProjectColors(propertyList: defaults.dictionary(forKey: ProjectColors.key), next: defaults.object(forKey: ProjectColors.nextKey))
    }

    /// Kept, without the projects whose folders are gone. One in a protected place is kept unlooked at: a look there is
    /// what macOS asks about, and a project on a disk that is not plugged in keeps its colour for when it is.
    private static func write(_ colors: ProjectColors) {
        let places: ProtectedPlaces = .current
        let kept: ProjectColors = colors.pruned { (key: String) -> Bool in
            places.holds(key) || FileManager.default.fileExists(atPath: key)
        }
        defaults.set(kept.propertyList, forKey: ProjectColors.key)
        defaults.set(kept.next, forKey: ProjectColors.nextKey)
    }

    /// `key`'s colour as kept, or picked now on its first open (the one the other windows' `inUse` use least) and kept
    /// from then on. `open`: the open windows' keys, which the store's limit never drops.
    static func entry(for key: String, inUse: [ProjectColor], open: Set<String>) -> ProjectColors.Entry? {
        let stored: ProjectColors = read()
        if let entry = stored.entry(for: key) { return entry }
        let picked: ProjectColors = stored.assigning(key, inUse: inUse, now: Date().timeIntervalSince1970, open: open).colors
        write(picked)
        return picked.entry(for: key)
    }

    /// A colour the user chose for `key`'s project, or None for This Project (nil).
    static func choose(_ color: ProjectColor?, for key: String, open: Set<String>) {
        write(read().choosing(color, for: key, now: Date().timeIntervalSince1970, open: open))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Automatic: after a choice, a new pick from the colours the other windows leave; an automatic colour stays.
    static func automatic(for key: String, inUse: [ProjectColor], open: Set<String>) {
        let stored: ProjectColors = read()
        let picked: ProjectColors = stored.automatic(for: key, inUse: inUse, now: Date().timeIntervalSince1970, open: open)
        guard picked != stored else { return }
        write(picked)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Each colour's glow on Theme.bar, and its swatch with the circle the menus show, worked out once.
    static let glows: [NSColor] = ProjectColor.allCases.map { (color: ProjectColor) -> NSColor in
        NSColor(hex: color.glow(on: Theme.bar.rgbHex))
    }
    static let swatches: [NSColor] = ProjectColor.allCases.map { (color: ProjectColor) -> NSColor in NSColor(hex: color.swatch) }
    static let swatchImages: [NSImage] = ProjectColor.allCases.map { (color: ProjectColor) -> NSImage in
        let fill: NSColor = swatches[color.rawValue]
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { (rect: NSRect) -> Bool in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.accessibilityDescription = color.name
        return image
    }
}

extension ProjectColor {
    /// The glow's strongest colour, at the window's top-left corner.
    var glowColor: NSColor { ProjectColorStore.glows[rawValue] }
    /// The colour of its menu circle and its Welcome row's dot.
    var swatchColor: NSColor { ProjectColorStore.swatches[rawValue] }
}

extension NSColor {
    /// The colour as 0xRRGGBB in sRGB, as `init(hex:)` takes it.
    var rgbHex: UInt32 {
        guard let srgb = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
    }
}

/// A view along the window's top row that paints its slice of the project's glow.
protocol ProjectGlowing: AnyObject {
    var projectGlow: ProjectGlow { get }
}

/// One bar's slice of its window's project colour: the top row's still glow, strongest at the window's top-left corner
/// behind the traffic lights and gone 320 pt in (ProjectColor.Glow). Each bar of the row (the sidebar's header, the
/// editor's and the terminal's tab bars, a folded terminal's rail) paints the part it covers, placed by where it is in
/// the window, so the glow runs on across whichever bars hold the corner. Painted in the bar's own draw, over the bar's
/// own colour: no layer of its own and no animation; the bar is drawn again only when the colour or the window's activity
/// changes, or it moves within the glow's reach.
final class ProjectGlow {
    private unowned let view: NSView
    /// The colour at the corner; nil, none.
    var peak: NSColor? {
        didSet { if peak != oldValue { changed() } }
    }
    /// The window is not the one in use: the glow at 0.55 of its strength.
    var dimmed = false {
        didSet { if dimmed != oldValue, peak != nil { changed() } }
    }
    /// Where in the window the bar's left edge was when it last drew; nil, not yet.
    private var drawnFrom: CGFloat?
    private var gradient: NSGradient?
    private static let reach = CGFloat(ProjectColor.Glow.reach)

    init(_ view: NSView) {
        self.view = view
    }

    private func changed() {
        gradient = nil
        view.needsDisplay = true
    }

    /// The bar's left edge, in its window.
    private func windowX(of view: NSView) -> CGFloat { view.convert(NSPoint(x: view.bounds.minX, y: view.bounds.minY), to: nil).x }

    /// The bar may have moved in its window (a pane resized, shown or hidden, the sidebar moved): drawn again only if the
    /// glow reaches where it was or where it is.
    func moved() {
        guard peak != nil, view.window != nil, let drawn = drawnFrom else { return }
        let x: CGFloat = windowX(of: view)
        if x != drawn, min(x, drawn) < Self.reach { view.needsDisplay = true }
    }

    /// Paints the bar's slice over `rect`, in its own coordinates, before what the bar draws over its colour.
    func draw(in rect: NSRect) {
        drawnFrom = windowX(of: view)
        paint(rect, in: view)
    }

    /// Paints the glow over `rect` of `target`, a view in the same row (the bar, or a key's backdrop over it), at its place
    /// in the window.
    func paint(_ rect: NSRect, in target: NSView) {
        guard let peak else { return }
        let x: CGFloat = windowX(of: target) - target.bounds.minX
        let start: CGFloat = -x, end: CGFloat = Self.reach - x
        let width: CGFloat = min(rect.maxX, end) - rect.minX
        guard width > 0 else { return }
        let gradient: NSGradient = self.gradient ?? makeGradient(peak)
        self.gradient = gradient
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).clip()
        gradient.draw(from: NSPoint(x: start, y: rect.midY), to: NSPoint(x: end, y: rect.midY), options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func makeGradient(_ peak: NSColor) -> NSGradient {
        let strength: CGFloat = dimmed ? CGFloat(ProjectColor.Glow.inactive) : 1
        let stops = ProjectColor.Glow.stops()
        let colors: [NSColor] = stops.map { (stop: (location: Double, strength: Double)) -> NSColor in
            peak.withAlphaComponent(strength * CGFloat(stop.strength))
        }
        var locations: [CGFloat] = stops.map { (stop: (location: Double, strength: Double)) -> CGFloat in CGFloat(stop.location) }
        return NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB) ?? NSGradient(starting: peak, ending: peak.withAlphaComponent(0))!
    }
}

/// View › Project Color, and the right-click on the window's top row: the nine colours by name (the window's own
/// checked), Automatic (checked while the colour is the one picked for it), None for This Project, and Show Project
/// Colors, for every window. A window's choice is its project's, so every worktree window of its repository takes it.
enum ProjectColorMenu {
    static let title = "Project Color"
    static let automaticID = "automatic"
    static let noneID = "none"

    /// `target`: the window the choices are for; nil, the window in front (the View menu's). `indent`: under a heading.
    static func items(into menu: NSMenu, target: AnyObject?, indent: Int = 0) {
        let action: Selector = #selector(TerminalWindowController.setProjectColor(_:))
        for color in ProjectColor.allCases {
            let item = menu.addItem(withTitle: color.name, action: action, keyEquivalent: "")
            item.representedObject = color.id
            item.image = ProjectColorStore.swatchImages[color.rawValue]
            item.target = target
            item.indentationLevel = indent
        }
        menu.addItem(.separator())
        for (title, id) in [("Automatic", automaticID), ("None for This Project", noneID)] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.representedObject = id
            item.target = target
            item.indentationLevel = indent
        }
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "Show Project Colors", action: #selector(AppDelegate.toggleProjectColors(_:)), keyEquivalent: "")
        show.target = AppDelegate.shared
    }

    /// The View menu's submenu.
    static func submenu() -> NSMenu {
        let menu = NSMenu(title: title)
        items(into: menu, target: nil)
        return menu
    }

    /// The top row's right-click for `controller`'s window: the same, under a heading, as the terminal's ⋯ has its
    /// Move Terminal To.
    static func contextMenu(for controller: TerminalWindowController) -> NSMenu {
        let menu = NSMenu(title: title)
        let heading = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        items(into: menu, target: controller, indent: 1)
        return menu
    }
}
