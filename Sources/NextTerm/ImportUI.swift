import AppKit
import Carbon.HIToolbox
import NextTermCore

// "Coming from another app?": find the apps a switcher used, show exactly what would change, apply it
// only on Apply, and undo it in one click. Nothing changes for people who never import. The readers for
// each app live in NextTermCore (Import*.swift) and only read; this file is the app's side.

/// The apps on this Mac an import can read, and their plans.
enum ImportSources {
    /// Every app found, most recently used first. Folders and dates only: nothing is parsed yet.
    static func detect() -> [DetectedApp] {
        let found = detectors.flatMap { $0() }
        return found.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    static func plan(for app: DetectedApp) -> ImportPlan {
        planner(app, usesUSKeyboard) ?? ImportPlan(preset: app.preset)
    }

    /// Filled in by the importers (see registerImporters()).
    nonisolated(unsafe) static var detectors: [() -> [DetectedApp]] = []
    nonisolated(unsafe) static var planner: (DetectedApp, Bool) -> ImportPlan? = { _, _ in nil }

    /// Option as Meta is offered ticked only on U.S.-style layouts: elsewhere Option types @ [ ] { }.
    static var usesUSKeyboard: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return true }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id == "com.apple.keylayout.US" || id == "com.apple.keylayout.ABC"
    }
}

/// What the user ticked in the preview.
struct ImportChoice {
    var usePreset: Bool
    var settings: [PlannedSetting]
    var recentProjects: [String]
}

/// Applies an import (after a snapshot) and undoes the last one exactly.
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    struct Snapshot: Codable {
        let date: Date
        let source: String
        let summary: String
        /// UserDefaults keys the import touched → their values before (missing: there was none).
        let before: [String: Value]
        let touched: [String]

        enum Value: Codable, Equatable {
            case double(Double), bool(Bool), string(String), strings([String])
        }
    }

    private static let snapshotKey = "importSnapshot"
    static let changed = Notification.Name("NextTermImportChanged")

    var last: Snapshot? {
        get { UserDefaults.standard.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.snapshotKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// How many things an import would change.
    static func count(_ choice: ImportChoice, plan: ImportPlan) -> Int {
        (choice.usePreset && plan.preset != KeyboardShortcuts.shared.preset ? plan.preset.overrides.count : 0)
            + choice.settings.count + (choice.recentProjects.isEmpty ? 0 : 1)
    }

    func apply(_ choice: ImportChoice, plan: ImportPlan, from source: String) {
        let defaults = UserDefaults.standard
        var keys: [String] = []
        if choice.usePreset { keys.append("keymapPreset") }
        keys += choice.settings.map(\.setting.key)
        if !choice.recentProjects.isEmpty { keys.append("recentProjects") }
        var before: [String: Snapshot.Value] = [:]
        for key in Set(keys) {
            switch defaults.object(forKey: key) {
            case let value as Bool where key == "softWrap" || key == "optionAsMeta": before[key] = .bool(value)
            case let value as Double: before[key] = .double(value)
            case let value as String: before[key] = .string(value)
            case let value as [String]: before[key] = .strings(value)
            default: break
            }
        }
        let app = AppDelegate.shared!
        if choice.usePreset { KeyboardShortcuts.shared.preset = plan.preset }
        for planned in choice.settings { app.applyImported(planned.setting) }
        let added = choice.recentProjects.isEmpty ? [] : app.importRecentProjects(choice.recentProjects)
        var parts: [String] = []
        if choice.usePreset { parts.append("\(plan.preset.name) shortcuts") }
        if !choice.settings.isEmpty { parts.append("\(choice.settings.count) setting\(choice.settings.count == 1 ? "" : "s")") }
        if !added.isEmpty { parts.append("\(added.count) project\(added.count == 1 ? "" : "s")") }
        last = Snapshot(date: Date(), source: source, summary: parts.joined(separator: ", "), before: before, touched: Array(Set(keys)))
    }

    /// Puts every key the last import touched back as it was.
    func undo() {
        guard let snapshot = last else { return }
        let app = AppDelegate.shared!
        for key in snapshot.touched {
            let value = snapshot.before[key]
            switch key {
            case "keymapPreset":
                if case .string(let raw)? = value, let preset = KeymapPreset(rawValue: raw) { KeyboardShortcuts.shared.preset = preset }
                else { UserDefaults.standard.removeObject(forKey: key); KeyboardShortcuts.shared.apply() }
            case "recentProjects":
                if case .strings(let paths)? = value { app.setRecentProjects(paths) } else { app.setRecentProjects([]) }
            default:
                app.restoreSetting(key, to: value)
            }
        }
        last = nil
    }
}

extension AppDelegate {
    /// Sets an imported value the way the menus and Settings do, so it applies at once.
    func applyImported(_ setting: ImportedSetting) {
        switch setting {
        case .fontSize(let size): setFontSize(CGFloat(size))
        case .editorLineHeight(let factor): editorLineHeight = CGFloat(factor)
        case .softWrap(let on): if softWrap != on { toggleSoftWrap(nil) }
        case .optionAsMeta(let on): if Preferences.optionAsMeta != on { toggleOptionAsMeta(nil) }
        case .terminalPosition(let raw):
            if let position = TerminalPosition(rawValue: raw) {
                terminalPosition = position
                controllers.forEach { $0.applyLayout() }
            }
        case .sidebarSide(let raw):
            if let side = SidebarSide(rawValue: raw), side != sidebarSide { toggleSidebarSide(nil) }
        }
    }

    /// Undo: a setting back to its value before the import (nil: it had none, so the default returns).
    func restoreSetting(_ key: String, to value: ImportCoordinator.Snapshot.Value?) {
        switch (key, value) {
        case ("fontSize", .double(let size)?): setFontSize(CGFloat(size))
        case ("fontSize", nil): resetFontSize(nil)
        case ("editorLineHeight", .double(let factor)?): editorLineHeight = CGFloat(factor)
        case ("editorLineHeight", nil): editorLineHeight = 1.35
        case ("softWrap", .bool(let on)?): applyImported(.softWrap(on))
        case ("softWrap", nil): applyImported(.softWrap(true))
        case ("optionAsMeta", .bool(let on)?): applyImported(.optionAsMeta(on))
        case ("optionAsMeta", nil): applyImported(.optionAsMeta(false))
        case ("terminalPosition", .string(let raw)?): applyImported(.terminalPosition(raw))
        case ("terminalPosition", nil): applyImported(.terminalPosition(TerminalPosition.bottom.rawValue))
        case ("sidebarSide", .string(let raw)?): applyImported(.sidebarSide(raw))
        case ("sidebarSide", nil): applyImported(.sidebarSide(SidebarSide.left.rawValue))
        default: break
        }
    }

    // MARK: menu

    @objc func showImport(_ sender: Any?) {
        ImportWindowController.shared.showChooser(firstRun: false, completion: nil)
    }
}

// MARK: - the window

/// "Coming from another app?" (the apps found, or keep Next Term's keys), then the preview for one app.
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImportWindowController()

    private var apps: [DetectedApp] = []
    private var completion: ((_ imported: ImportPlan?) -> Void)?
    private var plan: ImportPlan?
    private var app: DetectedApp?
    private var presetBox: NSButton?
    private var settingBoxes: [(NSButton, PlannedSetting)] = []
    private var recentsBox: NSButton?
    private var applyButton: NSButton?
    private var radios: [NSButton] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Import Settings and Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `completion` runs once, when the window closes (with the plan applied, or nil).
    func showChooser(firstRun: Bool, completion: ((_ imported: ImportPlan?) -> Void)?) {
        self.completion = completion
        apps = ImportSources.detect()
        let title = Self.label(firstRun ? "Coming from another app?" : "Bring over your settings and shortcuts", size: 20, weight: .semibold)
        let intro = Self.wrapping("Next Term can use the shortcuts and settings you already have. You’ll see every change first, and one click undoes it.")
        var rows: [NSView] = [title, intro]
        radios = []
        let keep = NSButton(radioButtonWithTitle: "Keep Next Term’s shortcuts", target: self, action: #selector(radioChanged(_:)))
        keep.tag = -1
        radios.append(keep)
        for (index, found) in apps.enumerated() {
            let radio = NSButton(radioButtonWithTitle: found.name + Self.used(found.lastUsed), target: self, action: #selector(radioChanged(_:)))
            radio.tag = index
            radios.append(radio)
        }
        // First run defaults to keeping everything; from the menu, to the app used last.
        let selected = firstRun || apps.isEmpty ? keep : radios[1]
        selected.state = .on
        if apps.isEmpty {
            rows.append(Self.wrapping("No VS Code, Cursor, JetBrains IDE, Zed or iTerm2 settings were found on this Mac.", secondary: true))
        }
        rows += radios.dropFirst() + [keep]
        rows.append(Self.wrapping("Reads files on this Mac only. Never changes the other app. Nothing leaves your Mac.", secondary: true, size: 11))
        let preview = NSButton(title: "Preview…", target: self, action: #selector(previewChosen))
        preview.keyEquivalent = "\r"
        let close = NSButton(title: firstRun ? "Keep Next Term’s Shortcuts" : "Close", target: self, action: #selector(closeWithoutImport))
        close.keyEquivalent = "\u{1b}"
        preview.isEnabled = !apps.isEmpty
        layout(rows, buttons: [close, preview])
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePreviewButton()
    }

    @objc private func radioChanged(_ sender: NSButton) {
        for radio in radios { radio.state = radio === sender ? .on : .off }
        updatePreviewButton()
    }

    private func updatePreviewButton() {
        let chosen = radios.first { $0.state == .on }?.tag ?? -1
        (window?.contentView?.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.last as? NSStackView)?
            .arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Preview…" }?.isEnabled = chosen >= 0
    }

    @objc private func previewChosen() {
        guard let chosen = radios.first(where: { $0.state == .on })?.tag, chosen >= 0, apps.indices.contains(chosen) else {
            return closeWithoutImport()
        }
        showPreview(for: apps[chosen])
    }

    /// The preview: every change with where it came from, each one a checkbox.
    func showPreview(for found: DetectedApp, plan given: ImportPlan? = nil) {
        app = found
        let plan = given ?? ImportSources.plan(for: found)
        self.plan = plan
        settingBoxes = []
        var rows: [NSView] = [Self.label("Bring over from \(found.name)", size: 20, weight: .semibold)]

        // Shortcuts.
        let current = KeyboardShortcuts.shared.preset
        if plan.preset != .nextTerm || current != .nextTerm {
            rows.append(Self.heading("Shortcuts"))
            let box = NSButton(checkboxWithTitle: plan.preset == current ? "Already using \(plan.preset.name) shortcuts"
                               : "Use \(plan.preset.name) shortcuts (\(plan.preset.overrides.count) differ from Next Term’s)",
                               target: self, action: #selector(recount))
            box.state = plan.preset != current ? .on : .off
            box.isEnabled = plan.preset != current
            presetBox = box
            rows.append(box)
            for line in Self.presetLines(plan.preset) { rows.append(Self.wrapping(line, secondary: true, size: 11, indent: true)) }
        } else {
            presetBox = nil
        }

        // Settings.
        if !plan.settings.isEmpty {
            rows.append(Self.heading("Settings"))
            for planned in plan.settings {
                let box = NSButton(checkboxWithTitle: Self.describe(planned.setting), target: self, action: #selector(recount))
                box.state = planned.ticked ? .on : .off
                settingBoxes.append((box, planned))
                rows.append(box)
                let detail = planned.source + (planned.note.map { " — " + $0 } ?? "")
                rows.append(Self.wrapping(detail, secondary: true, size: 11, indent: true))
            }
        }

        // Recent projects.
        let projects = plan.recentProjects.filter { !AppDelegate.shared.recentProjects.contains($0) }
        if !projects.isEmpty {
            rows.append(Self.heading("Recent projects"))
            let box = NSButton(checkboxWithTitle: "Add \(projects.count) recent project\(projects.count == 1 ? "" : "s") to Open Recent and the Welcome window",
                               target: self, action: #selector(recount))
            box.state = .on
            recentsBox = box
            rows.append(box)
            let names = projects.prefix(8).map { RecentProjects.abbreviate($0) }.joined(separator: "\n")
                + (projects.count > 8 ? "\nand \(projects.count - 8) more" : "")
            rows.append(Self.wrapping(names, secondary: true, size: 11, indent: true))
        } else {
            recentsBox = nil
        }

        // Not brought over.
        if !plan.skipped.isEmpty {
            rows.append(Self.heading("Not brought over (\(plan.skipped.count))"))
            let list = plan.skipped.prefix(12).map { "\($0.item): \($0.reason)" }.joined(separator: "\n")
                + (plan.skipped.count > 12 ? "\nand \(plan.skipped.count - 12) more" : "")
            rows.append(Self.wrapping(list, secondary: true, size: 11, indent: true))
            let copy = NSButton(title: "Copy List for Your Agent", target: self, action: #selector(copySkipped))
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            rows.append(copy)
        }
        if plan.settings.isEmpty && projects.isEmpty && presetBox?.isEnabled != true {
            rows.append(Self.wrapping("Already up to date: nothing here differs from Next Term now.", secondary: true))
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWithoutImport))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyChosen))
        apply.keyEquivalent = "\r"
        applyButton = apply
        layout(rows, buttons: [cancel, apply], scrolls: true)
        recount()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var choice: ImportChoice {
        let projects = plan?.recentProjects.filter { !AppDelegate.shared.recentProjects.contains($0) } ?? []
        return ImportChoice(usePreset: presetBox?.isEnabled == true && presetBox?.state == .on,
                            settings: settingBoxes.filter { $0.0.state == .on }.map(\.1),
                            recentProjects: recentsBox?.state == .on ? projects : [])
    }

    @objc private func recount() {
        guard let plan else { return }
        let count = ImportCoordinator.count(choice, plan: plan)
        applyButton?.title = count == 0 ? "Apply" : "Apply \(count) Change\(count == 1 ? "" : "s")"
        applyButton?.isEnabled = count > 0
    }

    @objc private func applyChosen() {
        guard let plan, let app else { return }
        ImportCoordinator.shared.apply(choice, plan: plan, from: app.name)
        finish(with: plan)
    }

    @objc private func copySkipped() {
        guard let plan else { return }
        var text = "Next Term imported settings from \(app?.name ?? "another app"). These were not brought over; help me with them if Next Term has a way:\n"
        text += plan.skipped.map { "- \($0.item): \($0.reason)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWithoutImport() { finish(with: nil) }

    func windowWillClose(_ notification: Notification) {
        let done = completion
        completion = nil
        done?(nil)
    }

    private func finish(with plan: ImportPlan?) {
        let done = completion
        completion = nil
        window?.orderOut(nil)
        done?(plan)
    }

    /// For the self-test: tick state and apply.
    var applyTitle: String { applyButton?.title ?? "" }
    func applyForTest() { applyChosen() }

    // MARK: layout

    private func layout(_ rows: [NSView], buttons: [NSButton], scrolls: Bool = false) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (i, row) in rows.enumerated() where i > 0 && (row.identifier?.rawValue == "heading") {
            stack.setCustomSpacing(16, after: rows[i - 1])
        }
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 16, right: 24)
        let buttonRow = NSStackView(views: [NSView()] + buttons)
        buttonRow.orientation = .horizontal
        buttonRow.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 18, right: 24)
        for button in buttons { button.bezelStyle = .rounded }
        let content = NSView()
        let body: NSView
        if scrolls {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let flipped = FlippedStack()
            flipped.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: flipped.topAnchor),
                stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            ])
            flipped.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = flipped
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            body = scroll
        } else {
            body = stack
        }
        for view in [body, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if !scrolls { stack.widthAnchor.constraint(equalToConstant: 560).isActive = true }
        window?.contentView = content
        if scrolls { window?.setContentSize(NSSize(width: 560, height: 560)) } else { content.layoutSubtreeIfNeeded() }
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    /// A small section heading in capitals, letterspaced so the caps don't crowd.
    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.8,
        ])
        label.identifier = .init("heading")
        return label
    }

    /// Wrapping text; `indent` sets it under a checkbox's title, at a fixed width so it wraps rather than
    /// being cut off.
    private static func wrapping(_ text: String, secondary: Bool = false, size: CGFloat = 13, indent: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        if secondary { label.textColor = .secondaryLabelColor }
        label.preferredMaxLayoutWidth = indent ? 470 : 510
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: indent ? 22 : 0),
            label.widthAnchor.constraint(equalToConstant: indent ? 470 : 510),
            box.trailingAnchor.constraint(equalTo: label.trailingAnchor),
        ])
        return box
    }

    private static func used(_ date: Date?) -> String {
        guard let date else { return "" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        switch days {
        case ..<1: return "  ·  used today"
        case 1: return "  ·  used yesterday"
        case 2..<14: return "  ·  used \(days) days ago"
        case 14..<60: return "  ·  used \(days / 7) weeks ago"
        default: return "  ·  used \(days / 30) months ago"
        }
    }

    /// "Replace in Files  ⇧⌘R → ⇧⌘H" for each command the preset changes.
    static func presetLines(_ preset: KeymapPreset) -> [String] {
        let shortcuts = KeyboardShortcuts.shared
        var lines = preset.overrides.keys.sorted().map { id -> String in
            let from = shortcuts.commands.first { $0.id == id }?.defaultChord?.display ?? "no key"
            let to = preset.overrides[id]!?.display ?? "no key"
            return "\(shortcuts.title(of: id))   \(from) → \(to)"
        }
        if preset.clearsOnlyInTerminal { lines.append("⌘K clears only while a terminal has the keyboard") }
        lines.append("Your own shortcut changes stay as they are")
        return lines
    }

    static func describe(_ setting: ImportedSetting) -> String {
        let app = AppDelegate.shared!
        switch setting {
        case .fontSize(let size): return "Font size \(Int(app.fontSize)) → \(Int(size)) pt"
        case .editorLineHeight(let factor): return String(format: "Line height %.2f× → %.2f×", app.editorLineHeight, factor)
        case .softWrap(let on): return on ? "Wrap long lines" : "Don’t wrap long lines"
        case .optionAsMeta(let on): return on ? "Use Option as Meta in the terminal" : "Option types special characters"
        case .terminalPosition(let raw): return "Terminal on the \(raw)"
        case .sidebarSide(let raw): return "Project sidebar on the \(raw)"
        }
    }
}

private final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings › Import

/// Settings › Import: the shortcuts preset, the apps found, and the last import with Undo.
final class ImportSettingsView: NSView {
    private let presetPopup = NSPopUpButton()
    private let lastLabel = NSTextField(wrappingLabelWithString: "")
    private let undoButton = NSButton(title: "Undo Import", target: nil, action: nil)
    private let appsStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for preset in KeymapPreset.allCases {
            presetPopup.addItem(withTitle: preset.name)
            presetPopup.lastItem?.representedObject = preset.rawValue
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        let presetRow = NSStackView(views: [NSTextField(labelWithString: "Shortcuts from:"), presetPopup])
        let presetNote = NSTextField(wrappingLabelWithString: "VS Code and JetBrains keys for the commands that differ; your own changes in Keyboard Shortcuts stay on top.")
        presetNote.font = .systemFont(ofSize: 11)
        presetNote.textColor = .secondaryLabelColor
        presetNote.preferredMaxLayoutWidth = 520
        let appsTitle = NSTextField(labelWithString: "Bring over settings, shortcuts and recent projects from:")
        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = 6
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded
        lastLabel.textColor = .secondaryLabelColor
        lastLabel.font = .systemFont(ofSize: 12)
        lastLabel.preferredMaxLayoutWidth = 420
        let lastRow = NSStackView(views: [lastLabel, undoButton])
        lastRow.alignment = .centerY
        let stack = NSStackView(views: [presetRow, presetNote, appsTitle, appsStack, lastRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(24, after: presetNote)
        stack.setCustomSpacing(24, after: appsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ImportCoordinator.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc private func refresh() {
        let preset = KeyboardShortcuts.shared.preset
        presetPopup.selectItem(at: KeymapPreset.allCases.firstIndex(of: preset) ?? 0)
        appsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let apps = ImportSources.detect()
        if apps.isEmpty {
            let none = NSTextField(labelWithString: "No VS Code, Cursor, JetBrains IDE, Zed or iTerm2 settings found on this Mac.")
            none.textColor = .secondaryLabelColor
            appsStack.addArrangedSubview(none)
        }
        for (index, app) in apps.enumerated() {
            let button = NSButton(title: "Preview…", target: self, action: #selector(preview(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            let row = NSStackView(views: [NSTextField(labelWithString: app.name), button])
            appsStack.addArrangedSubview(row)
        }
        if let last = ImportCoordinator.shared.last {
            let date = DateFormatter.localizedString(from: last.date, dateStyle: .medium, timeStyle: .none)
            lastLabel.stringValue = "Imported from \(last.source) on \(date): \(last.summary)."
            undoButton.isHidden = false
        } else {
            lastLabel.stringValue = "Nothing imported."
            undoButton.isHidden = true
        }
    }

    @objc private func presetChanged() {
        guard let raw = presetPopup.selectedItem?.representedObject as? String, let preset = KeymapPreset(rawValue: raw) else { return }
        KeyboardShortcuts.shared.preset = preset
        NotificationCenter.default.post(name: ImportCoordinator.changed, object: nil)
    }

    @objc private func preview(_ sender: NSButton) {
        let apps = ImportSources.detect()
        guard apps.indices.contains(sender.tag) else { return }
        ImportWindowController.shared.showPreview(for: apps[sender.tag])
    }

    @objc private func undo() {
        let alert = NSAlert()
        alert.messageText = "Undo the import?"
        alert.informativeText = "The shortcuts, settings and recent projects it changed go back to what they were before."
        alert.addButton(withTitle: "Undo Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ImportCoordinator.shared.undo()
    }
}
