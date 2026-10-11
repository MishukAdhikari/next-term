import AppKit
import NextTermCore

/// Remote access's menu bar icon (R37, KTD16): shown only while Remote access is on, never otherwise. It says On,
/// Connecting, Reconnecting or Waiting, with the calls of the last hour beside it, and holds the off switch: Turn Off
/// Remote Access, and Turn Off and Revoke All. While a Control connection exists, the icon carries the Control mark,
/// and the menu lists each Control connection with Revoke, so one is a click from gone wherever the user is.
///
/// Next Term's own menus are not edited (KTD16): this is a separate `NSStatusItem`. It follows `RemoteAccess.didChange`
/// and, while shown, looks again every 15 seconds for the call count.
@MainActor
final class RemoteAccessStatusItem: NSObject, NSMenuDelegate {
    static let shared = RemoteAccessStatusItem()

    /// The icon's symbol, and the Control mark's (the same mark Settings shows on a Control connection).
    static let symbol = "antenna.radiowaves.left.and.right"
    static let controlMark = "bolt.fill"
    static let recount: TimeInterval = 15

    /// The item while shown.
    private(set) var item: NSStatusItem?
    /// What it shows now.
    private(set) var model: RemoteAccessStatusItemModel?
    private var following = false
    private var timer: Timer?

    /// Starts following Remote access (at launch): the item shows while it is on.
    func follow() {
        guard !following else { return }
        following = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed), name: RemoteAccess.didChange, object: nil)
        update()
    }

    @objc private func changed() {
        update()
    }

    /// Shows, updates or removes the item from Remote access as it is now.
    func update() {
        let model = RemoteAccess.shared.statusItemModel()
        self.model = model
        guard model.visible else { return remove() }
        let item = self.item ?? add()
        guard let button = item.button else { return }
        button.image = Self.image(indicator: model.indicator, controlMark: model.hasControlMark)
        button.imagePosition = .imageLeading
        button.title = model.calls > 0 ? "\(model.calls)" : ""
        button.toolTip = model.toolTip
        button.setAccessibilityLabel(model.toolTip.replacingOccurrences(of: "\n", with: ". "))
    }

    private func add() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        self.item = item
        let timer = Timer(timeInterval: Self.recount, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return item
    }

    private func remove() {
        timer?.invalidate()
        timer = nil
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: the menu

    /// Built fresh each time it opens, from Remote access as it is then.
    func menuNeedsUpdate(_ menu: NSMenu) {
        update()
        fill(menu)
    }

    /// The menu's items: the state, the calls, each Control connection with Revoke, then Settings and the off
    /// switch.
    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        menu.addItem(Self.label(model.title, bold: true))
        menu.addItem(Self.label(model.detail))
        menu.addItem(Self.label(model.callsText))
        if model.hasControlMark {
            menu.addItem(.separator())
            menu.addItem(Self.label(model.controls.count == 1 ? "Control connection" : "Control connections"))
            for row in model.controls {
                let title = RemoteAccessStatusItemModel.revokeTitle(row.name)
                let revoke = NSMenuItem(title: title, action: #selector(revoke(_:)), keyEquivalent: "")
                revoke.target = self
                revoke.representedObject = row.id
                revoke.image = Self.markImage()
                revoke.toolTip = "Ends this connection now. It can run commands on this Mac without asking."
                menu.addItem(revoke)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Remote Access Settings…", #selector(openSettings)))
        menu.addItem(action("Turn Off Remote Access", #selector(turnOff)))
        menu.addItem(action("Turn Off and Revoke All", #selector(turnOffAndRevokeAll)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func label(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            let font = NSFont.menuFont(ofSize: 0)
            let heavy = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: heavy])
        }
        return item
    }

    @objc private func revoke(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let problem = RemoteAccess.shared.revoke(id) { NSLog("Next Term: %@", problem) }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.showSettings(tab: RemoteAccessSettingsView.tabID)
    }

    @objc private func turnOff() {
        RemoteAccess.shared.turnOff()
    }

    @objc private func turnOffAndRevokeAll() {
        RemoteAccess.shared.turnOff(revokeAll: true)
    }

    // MARK: images

    /// The icon, a template image: dimmed while not ready, and followed by the Control mark while a Control
    /// connection exists.
    static func image(indicator: RemoteAccessIndicator, controlMark: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let what = "Remote access: \(indicator.word)"
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: what)?
            .withSymbolConfiguration(configuration) else { return nil }
        let mark = controlMark ? markImage(configuration: configuration) : nil
        let alpha: CGFloat = indicator == .on ? 1 : 0.45
        let gap: CGFloat = 1
        let width = base.size.width + (mark.map { $0.size.width + gap } ?? 0)
        let height = max(base.size.height, mark?.size.height ?? 0)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: (height - base.size.height) / 2, width: base.size.width,
                                 height: base.size.height),
                      from: .zero, operation: .sourceOver, fraction: alpha)
            if let mark {
                let x = base.size.width + gap
                let rect = NSRect(x: x, y: (height - mark.size.height) / 2, width: mark.size.width,
                                  height: mark.size.height)
                mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = controlMark ? what + ", with a Control connection" : what
        return image
    }

    /// The Control mark alone.
    static func markImage(configuration: NSImage.SymbolConfiguration? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: controlMark, accessibilityDescription: "Control")
        guard let configuration else { return image }
        return image?.withSymbolConfiguration(configuration)
    }
}
