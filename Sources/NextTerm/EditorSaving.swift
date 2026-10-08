import AppKit
import NextTermCore

// Settings › Editor: clean-up on save (trailing spaces trimmed, a final newline; both off by default) and the
// files the project sidebar hides by pattern (NextTermCore/SaveCleanUp.swift, FileHiding.swift).

extension Preferences {
    static var trimTrailingWhitespace: Bool {
        get { UserDefaults.standard.bool(forKey: "trimTrailingWhitespace") }
        set { UserDefaults.standard.set(newValue, forKey: "trimTrailingWhitespace") }
    }

    static var insertFinalNewline: Bool {
        get { UserDefaults.standard.bool(forKey: "insertFinalNewline") }
        set { UserDefaults.standard.set(newValue, forKey: "insertFinalNewline") }
    }

    /// Patterns the project sidebar hides, as FileHiding reads them.
    static var hiddenFilePatterns: [String] {
        get { UserDefaults.standard.stringArray(forKey: "hiddenFilePatterns") ?? [] }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: "hiddenFilePatterns") }
            else { UserDefaults.standard.set(newValue, forKey: "hiddenFilePatterns") }
        }
    }
}

extension AppDelegate {
    /// Sets the hidden patterns and lists every project sidebar's folders again.
    func setHiddenFilePatterns(_ patterns: [String]) {
        Preferences.hiddenFilePatterns = patterns
        controllers.forEach { $0.sidebar.reloadAll() }
    }
}

extension ProjectSidebarView {
    /// What the tree leaves out by pattern, against the folder it shows (nil: nothing).
    var fileHiding: FileHiding? {
        let patterns = Preferences.hiddenFilePatterns
        guard let root, !patterns.isEmpty else { return nil }
        return FileHiding(patterns: patterns, root: root.path)
    }
}

extension EditorArea {
    /// Settings › Editor › On save, done to the text in the editor before it is written, as one step ⌘Z undoes.
    /// Markdown and patch files keep their trailing spaces. A file no editor shows, or one that can't be edited,
    /// is written as it is.
    func cleanUpBeforeSave(_ document: EditorDocument) {
        let trim = Preferences.trimTrailingWhitespace && SaveCleanUp.trims(fileNamed: document.name)
        let newline = Preferences.insertFinalNewline
        guard trim || newline, let view = editors.first(where: { $0.document === document })?.textView, view.isEditable else { return }
        let replacements = SaveCleanUp.replacements(in: document.storage.mutableString, trimTrailingWhitespace: trim, insertFinalNewline: newline)
        guard !replacements.isEmpty else { return }
        view.applyCleanUp(replacements)
    }
}

extension CodeTextView {
    /// The clean-up's replacements as one undoable step, the caret or selection kept on the text it was on.
    func applyCleanUp(_ replacements: [SaveCleanUp.Replacement]) {
        let selection = selectedRange()
        breakUndoCoalescing()
        let ranges = replacements.map { NSValue(range: $0.range) }
        guard shouldChangeText(inRanges: ranges, replacementStrings: replacements.map(\.text)) else { return }
        for replacement in replacements.reversed() { replaceCharacters(in: replacement.range, with: replacement.text) }
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName("Clean Up")
        let start = SaveCleanUp.location(selection.location, after: replacements)
        let end = SaveCleanUp.location(NSMaxRange(selection), after: replacements)
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }
}

/// Settings › Editor's rows for clean-up on save and the patterns the sidebar hides.
final class EditorSavingControls: NSObject, NSTextFieldDelegate {
    let trim = NSButton(checkboxWithTitle: "Trim trailing spaces", target: nil, action: nil)
    let newline = NSButton(checkboxWithTitle: "End files with a newline", target: nil, action: nil)
    let hidden = NSTextField(string: "")

    override init() {
        super.init()
        trim.target = self
        trim.action = #selector(trimChanged)
        trim.toolTip = "Every line of the file, as you save. Markdown and patch files keep theirs: two spaces end a line in Markdown."
        newline.target = self
        newline.action = #selector(newlineChanged)
        newline.toolTip = "Adds a line break after the last line as you save, unless it is empty."
        hidden.placeholderString = "node_modules, *.log, /build"
        hidden.toolTip = "Patterns as in .gitignore, between commas: a name hides it in every folder, a path from the project’s folder (/build) only there, and a / at the end only folders. Press Return to apply."
        hidden.target = self
        hidden.action = #selector(hiddenChanged)
        hidden.delegate = self
        hidden.widthAnchor.constraint(equalToConstant: 260).isActive = true
    }

    func refresh() {
        trim.state = Preferences.trimTrailingWhitespace ? .on : .off
        newline.state = Preferences.insertFinalNewline ? .on : .off
        if hidden.currentEditor() == nil { hidden.stringValue = FileHiding.text(of: Preferences.hiddenFilePatterns) }
    }

    @objc private func trimChanged() { Preferences.trimTrailingWhitespace = trim.state == .on }
    @objc private func newlineChanged() { Preferences.insertFinalNewline = newline.state == .on }

    @objc private func hiddenChanged() {
        let patterns = FileHiding.patterns(from: hidden.stringValue)
        if patterns != Preferences.hiddenFilePatterns { AppDelegate.shared.setHiddenFilePatterns(patterns) }
        hidden.stringValue = FileHiding.text(of: patterns)
    }

    /// Leaving the field applies it too.
    func controlTextDidEndEditing(_ notification: Notification) { hiddenChanged() }
}
