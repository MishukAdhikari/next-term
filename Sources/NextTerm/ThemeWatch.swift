import AppKit
import NextTermCore
import SwiftTerm

/// The app's look (plan 049): Settings › General › Appearance sets it (the Mac's own, light or dark), and a change of
/// it, or of the Mac's while Match System is chosen, reaches every window at once: Theme's colours resolve as they are
/// drawn, layers set once take theirs again (ThemeLayers), and every terminal takes its palette again.
@MainActor
enum ThemeWatch {
    /// Posted after the look changed, for views that keep colours of their own.
    static let didChange = Notification.Name("NextTerm.ThemeWatch.didChange")

    private static var observation: NSKeyValueObservation?
    private static var lastDark: Bool?

    /// At launch: the chosen themes and look, and a watch on the app's.
    static func start() {
        Theme.palettes = (ThemePalette.theme(Preferences.lightTheme, dark: false), ThemePalette.theme(Preferences.darkTheme, dark: true))
        apply(Preferences.appearance)
        guard observation == nil else { return }
        lastDark = Theme.isDark(NSApp.effectiveAppearance)
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let dark = Theme.isDark(NSApp.effectiveAppearance)
                    guard dark != lastDark else { return }
                    lastDark = dark
                    changed()
                }
            }
        }
    }

    /// Sets the app's look: nil follows the Mac.
    static func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// One window's look changed, as AppKit changed it (its root view's viewDidChangeEffectiveAppearance): what under
    /// `root` doesn't follow by itself is set again. Each window does this for itself, when its own look changes, so one
    /// behind another, merged behind a tab, on another Space or minimized is right however late AppKit gets to it. The
    /// app-wide pass (`changed`) sets everything at once as well, by the look each part is about to have.
    static func windowChanged(_ root: NSView) {
        ThemeLayers.refresh(in: root)
        for terminal in terminals(in: root) { Theme.applyColours(to: terminal) }
    }

    /// The look changed: what doesn't follow by itself is set again.
    static func changed() {
        ThemeLayers.refresh()
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            for terminal in terminals(in: content) { Theme.applyColours(to: terminal) }
            window.invalidateShadow()
            content.needsDisplay = true
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Every terminal view under `view`.
    static func terminals(in view: NSView) -> [TerminalView] {
        var found: [TerminalView] = []
        var queue: [NSView] = [view]
        while let next = queue.popLast() {
            if let terminal = next as? TerminalView { found.append(terminal) } else { queue.append(contentsOf: next.subviews) }
        }
        return found
    }
}

/// Layers whose colour is set once (in a view's setup) rather than in `updateLayer()`: a CGColor is fixed when it is
/// made, so each such layer is kept here, by its view, with the colour it was given, and is set again when the look
/// changes. Weak: a view gone is gone from here.
@MainActor
enum ThemeLayers {
    private static let backgrounds = NSMapTable<NSView, NSColor>.weakToStrongObjects()
    private static let borders = NSMapTable<NSView, NSColor>.weakToStrongObjects()

    static func setBackground(_ color: NSColor?, of view: NSView) {
        if let color { backgrounds.setObject(color, forKey: view) } else { backgrounds.removeObject(forKey: view) }
        view.layer?.backgroundColor = color.map { resolved($0, for: view) }
    }

    static func setBorder(_ color: NSColor?, of view: NSView) {
        if let color { borders.setObject(color, forKey: view) } else { borders.removeObject(forKey: view) }
        view.layer?.borderColor = color.map { resolved($0, for: view) }
    }

    /// Every such layer set again; with `root`, only those under it (one window, as its look changes).
    static func refresh(in root: NSView? = nil) {
        for view in backgrounds.keyEnumerator().allObjects.compactMap({ $0 as? NSView }) where root.map(view.isDescendant(of:)) ?? true {
            if let color = backgrounds.object(forKey: view) { view.layer?.backgroundColor = resolved(color, for: view) }
        }
        for view in borders.keyEnumerator().allObjects.compactMap({ $0 as? NSView }) where root.map(view.isDescendant(of:)) ?? true {
            if let color = borders.object(forKey: view) { view.layer?.borderColor = resolved(color, for: view) }
        }
    }

    /// `color` as `view` looks now (a dynamic colour's CGColor is otherwise the app's look's, or the last drawn one's),
    /// by the look it is in now, not its `effectiveAppearance`, which lags a change (Theme.appearance(of:)).
    static func resolved(_ color: NSColor, for view: NSView) -> CGColor {
        var cg = color.cgColor
        Theme.appearance(of: view).performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

extension NSView {
    /// The layer's background, set again whenever the look changes. nil clears it.
    func themedBackground(_ color: NSColor?) { ThemeLayers.setBackground(color, of: self) }

    /// The layer's border colour, set again whenever the look changes.
    func themedBorder(_ color: NSColor?) { ThemeLayers.setBorder(color, of: self) }
}

extension Preferences {
    /// Settings › General › Light theme and Dark theme: a theme's id (ThemePalette), nil for Next Term's own.
    static var lightTheme: String? {
        get { UserDefaults.standard.string(forKey: "lightTheme") }
        set {
            UserDefaults.standard.set(newValue, forKey: "lightTheme")
            Theme.palettes.light = ThemePalette.theme(newValue, dark: false)
        }
    }

    static var darkTheme: String? {
        get { UserDefaults.standard.string(forKey: "darkTheme") }
        set {
            UserDefaults.standard.set(newValue, forKey: "darkTheme")
            Theme.palettes.dark = ThemePalette.theme(newValue, dark: true)
        }
    }

    /// Settings › General › Appearance.
    static var appearance: AppAppearance {
        get { AppAppearance(stored: UserDefaults.standard.string(forKey: "appearance")) }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            MainActor.assumeIsolated {
                ThemeWatch.apply(newValue)
                ThemeWatch.changed() // at once, not only when the watch on the app's look reports it
            }
        }
    }
}
