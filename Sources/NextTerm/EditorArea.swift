import AppKit
import NextTermCore

protocol EditorAreaDelegate: AnyObject {
    /// The last editor closed (hide the area) or the first opened (show it).
    func editorAreaDidChangeDocuments(_ area: EditorArea)
}

/// Open files above the terminal, one tab each, like an IDE's editor area.
final class EditorArea: NSView, TabBarViewDelegate {
    weak var delegate: EditorAreaDelegate?
    let tabBar = TabBarView(frame: .zero)
    private let container = NSView()
    private let banner = EditorBanner()
    private var bannerHeight: NSLayoutConstraint!
    private(set) var editors: [CodeEditorView] = []
    private(set) var activeIndex = 0

    var activeEditor: CodeEditorView? { editors[safe: activeIndex] }
    var documents: [EditorDocument] { editors.map(\.document) }
    var dirtyDocuments: [EditorDocument] { documents.filter(\.isDirty) }
    var isEmpty: Bool { editors.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        tabBar.allowsNewTab = false
        tabBar.allowsRename = false
        tabBar.kind = "file"
        tabBar.delegate = self
        for view in [tabBar, banner, container] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            banner.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            container.topAnchor.constraint(equalTo: banner.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        banner.onReload = { [weak self] in self?.resolveConflict(keepMine: false) }
        banner.onKeep = { [weak self] in self?.resolveConflict(keepMine: true) }
        banner.onClose = { [weak self] in
            guard let self, let editor = self.activeEditor else { return }
            self.remove(editor)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: opening

    enum OpenResult { case opened, notText, tooLarge, failed }

    /// Opens a file (or shows it if open), optionally at a line. Binary and huge files are not opened.
    @discardableResult
    func open(_ url: URL, line: Int? = nil, column: Int = 1, focus: Bool = true) -> OpenResult {
        let path = canonicalPath(url.path)
        if let index = editors.firstIndex(where: { $0.document.path == path }) {
            select(index, focus: focus)
            if let line { editors[index].textView.go(toLine: line, column: column) }
            return .opened
        }
        let document: EditorDocument
        do {
            document = try EditorDocument(url: URL(fileURLWithPath: path))
        } catch EditorDocument.OpenError.notText {
            return .notText
        } catch EditorDocument.OpenError.tooLarge {
            return .tooLarge
        } catch {
            return .failed
        }
        let editor = CodeEditorView(document: document)
        document.onChange = { [weak self] _ in self?.refresh() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: container.topAnchor),
            editor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let insertAt = editors.isEmpty ? 0 : activeIndex + 1
        editors.insert(editor, at: insertAt)
        if editors.count == 1 { delegate?.editorAreaDidChangeDocuments(self) }
        select(insertAt, focus: focus)
        container.layoutSubtreeIfNeeded()
        editor.textView.go(toLine: line ?? 1, column: line == nil ? 1 : column)
        return .opened
    }

    func select(_ index: Int, focus: Bool = true) {
        guard editors.indices.contains(index) else { return }
        activeIndex = index
        for (i, editor) in editors.enumerated() { editor.isHidden = i != index }
        if focus { window?.makeFirstResponder(editors[index].textView) }
        refresh()
    }

    func cycle(by delta: Int) {
        guard !editors.isEmpty else { return }
        select((activeIndex + delta + editors.count) % editors.count)
    }

    // MARK: closing

    /// Closes an editor, asking to save first if it has unsaved changes.
    func requestClose(_ editor: CodeEditorView) {
        guard editor.document.isDirty, let window else { return remove(editor) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(editor.document.name)”?"
        alert.informativeText = "Your changes are lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save(editor.document) { self.remove(editor) }
            case .alertThirdButtonReturn:
                self.remove(editor)
            default:
                break
            }
        }
    }

    func closeActive() {
        if let editor = activeEditor { requestClose(editor) }
    }

    private func remove(_ editor: CodeEditorView) {
        guard let index = editors.firstIndex(where: { $0 === editor }) else { return }
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: editor) == true
        editor.removeFromSuperview()
        editor.document.storage.layoutManagers.forEach { editor.document.storage.removeLayoutManager($0) }
        editors.remove(at: index)
        if editors.isEmpty {
            refresh()
            delegate?.editorAreaDidChangeDocuments(self)
            return
        }
        if index <= activeIndex { activeIndex = max(0, activeIndex - 1) }
        select(activeIndex, focus: hadFocus)
    }

    /// Closes every editor without asking (the window is closing and the user already chose).
    func closeAll() {
        for editor in editors { remove(editor) }
    }

    // MARK: saving

    /// Saves; on failure says why and returns false.
    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "“\(document.name)” could not be saved."
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
    }

    func saveActive() {
        guard let document = activeEditor?.document else { return NSSound.beep() }
        save(document)
    }

    /// Saves every file with changes. False if any could not be saved.
    @discardableResult
    func saveAll() -> Bool {
        dirtyDocuments.allSatisfy { save($0) }
    }

    // MARK: disk changes

    /// Picks up changes other programs (agents, git) made to open files. Called about once a second.
    func checkDisk() {
        for editor in editors { editor.document.checkDisk() }
    }

    private func resolveConflict(keepMine: Bool) {
        guard let document = activeEditor?.document else { return }
        if keepMine { document.keepMine() } else if !document.reload() { NSSound.beep() }
        refresh()
    }

    /// A file or folder was renamed or moved in the sidebar: open editors follow it.
    func itemMoved(from old: String, to new: String) {
        for document in documents {
            if document.path == old {
                document.moved(to: URL(fileURLWithPath: new))
            } else if document.path.hasPrefix(old + "/") {
                document.moved(to: URL(fileURLWithPath: new + document.path.dropFirst(old.count)))
            }
        }
        refresh()
    }

    // MARK: display

    func refresh() {
        // Same name twice: add the folder, as editors do.
        let names = Dictionary(grouping: documents, by: \.name)
        let items = documents.map { document -> TabBarItem in
            var title = document.name
            if (names[document.name]?.count ?? 0) > 1 {
                title += " — " + document.url.deletingLastPathComponent().lastPathComponent
            }
            let status = document.isDirty ? "unsaved changes" : "saved"
            return TabBarItem(title: title, state: .idle, tooltip: RecentProjects.abbreviate(document.path),
                              accessibilityStatus: status, icon: FileIcons.icon(for: document.url, size: 16), modified: document.isDirty)
        }
        tabBar.update(items: items, selectedIndex: activeIndex)
        let conflict = activeEditor?.document.conflict
        banner.show(conflict, name: activeEditor?.document.name ?? "")
        bannerHeight.constant = conflict == nil ? 0 : EditorBanner.height
        window?.windowController.map { ($0 as? TerminalWindowController)?.updateTitle() }
    }

    func applyFont() {
        editors.forEach { $0.applyFont() }
    }

    func applyWrap() {
        editors.forEach { $0.applyWrap() }
    }

    // MARK: TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        if let editor = editors[safe: index] { requestClose(editor) }
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        guard editors.indices.contains(from), editors.indices.contains(to) else { return }
        let active = activeEditor
        editors.insert(editors.remove(at: from), at: to)
        activeIndex = active.flatMap { a in editors.firstIndex { $0 === a } } ?? 0
        refresh()
    }

    func tabBar(_ bar: TabBarView, didRename index: Int, to title: String?) {}
    func tabBarDidEndEditing(_ bar: TabBarView) {}
    func tabBarDidRequestNewTab(_ bar: TabBarView) {}
}

/// "This file changed on disk" with what to do about it.
final class EditorBanner: NSView {
    static let height: CGFloat = 34
    private let label = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "Reload from Disk", target: nil, action: nil)
    private let keep = NSButton(title: "Keep My Changes", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x3D3223).cgColor
        clipsToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingTail)
        for button in [reload, keep, close] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
        }
        reload.action = #selector(reloadClicked)
        keep.action = #selector(keepClicked)
        close.action = #selector(closeClicked)
        let stack = NSStackView(views: [label, NSView(), keep, close, reload])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ conflict: EditorDocument.Conflict?, name: String) {
        isHidden = conflict == nil
        switch conflict {
        case .changedOnDisk:
            label.stringValue = "“\(name)” changed on disk while you were editing it."
            reload.isHidden = false
            close.isHidden = true
        case .deletedOnDisk:
            label.stringValue = "“\(name)” was deleted or moved on disk."
            reload.isHidden = true
            close.isHidden = false
        case nil:
            break
        }
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
    @objc private func closeClicked() { onClose?() }
}
