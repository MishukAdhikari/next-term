import AppKit
import NextTermCore

/// One open file: its text, how it is stored on disk, and whether it has unsaved edits.
final class EditorDocument: NSObject, NSTextStorageDelegate {
    enum OpenError: Error {
        case notText, tooLarge, unreadable
    }

    let id = UUID()
    private(set) var url: URL
    var format: TextFormat
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var lines = LineIndex()
    let language: String?
    /// The grammar that colours it: PHP files use the one that also understands the HTML around
    /// `<?php … ?>` (shiki's `php` grammar covers only the code inside the tags).
    var grammar: String? { language == "php" ? SyntaxEngine.shared?.language("blade") ?? language : language }
    let indentUnit: String
    var highlighter: DocumentHighlighter?
    /// What is on disk as of the last load or save.
    private(set) var stamp: FileStamp?
    private var savedHash = 0
    private(set) var isDirty = false
    /// The file on disk changed (or went away) while there were unsaved edits: the user decides.
    var conflict: Conflict?
    var onChange: ((EditorDocument) -> Void)?
    /// Text was replaced from disk (not typed): the editor restyles those lines.
    var onTextReplaced: (() -> Void)?
    /// Lines `old` (0-based, as they were) became lines `old.lowerBound...newLast`, typed or not.
    var onLinesEdited: ((_ old: ClosedRange<Int>, _ newLast: Int) -> Void)?

    enum Conflict: Equatable { case changedOnDisk, deletedOnDisk }

    /// When this file was last brought to the front (agents get the most recent first).
    var lastFocused = Date()

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    init(url: URL) throws {
        self.url = URL(fileURLWithPath: canonicalPath(url.path))
        let data = try Self.read(self.url)
        guard let (text, format) = TextFile.decode(data) else { throw OpenError.notText }
        self.format = format
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let detected = EditorLanguage.id(forFileName: self.url.lastPathComponent, firstLine: firstLine)
        language = SyntaxEngine.shared?.language(detected)
        indentUnit = EditorLanguage.indentUnit(of: text, default: detected == "yaml" ? "  " : "    ")
        super.init()
        stamp = FileStamp(path: self.url.path)
        storage.delegate = self
        isLoading = true
        setText(text)
        isLoading = false
        savedHash = text.hashValue
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo), name: .NSUndoManagerDidUndoChange, object: undoManager)
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo), name: .NSUndoManagerDidRedoChange, object: undoManager)
    }

    private static func read(_ url: URL) throws -> Data {
        guard isRegularFile(url.path) else { throw OpenError.notText } // a named pipe would block forever
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= TextFile.maxEditableSize else { throw OpenError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw OpenError.unreadable }
        return data
    }

    var text: String { storage.string }

    /// Replaces everything (open, reload). Not undoable: undo history is about this text.
    private func setText(_ text: String) {
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.setAttributes(Self.attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Replaces only the part that differs, so the caret, the scroll position and the colours of
    /// everything else stay put when an agent changes a few lines.
    private func replaceChanged(with text: String) {
        let old = storage.string as NSString, new = text as NSString
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        // Never split a surrogate pair or a CRLF.
        while prefix > 0, (prefix < new.length && UTF16.isTrailSurrogate(new.character(at: prefix))) || new.character(at: prefix - 1) == 0x0D { prefix -= 1 }
        while suffix > 0, UTF16.isTrailSurrogate(new.character(at: new.length - suffix)) { suffix -= 1 }
        let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let newRange = NSRange(location: prefix, length: new.length - prefix - suffix)
        guard oldRange.length > 0 || newRange.length > 0 else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: oldRange, with: new.substring(with: newRange))
        storage.setAttributes(Self.attributes, range: NSRange(location: prefix, length: newRange.length))
        storage.endEditing()
    }

    /// Keep the edits in the editor although the file on disk changed or went away: saving writes them.
    func keepMine() {
        stamp = FileStamp(path: url.path)
        conflict = nil
        isDirty = true
        onChange?(self)
    }

    static var font: NSFont { Theme.monoFont(size: AppDelegate.shared?.fontSize ?? Theme.defaultFontSize) }

    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: Theme.terminalForeground]
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let oldFirst = lines.line(at: oldRange.location)
        let oldLast = lines.line(at: oldRange.location + oldRange.length)
        lines.replace(oldRange, with: (textStorage.string as NSString).substring(with: editedRange))
        let newLast = lines.line(at: editedRange.location + editedRange.length)
        highlighter?.textEdited(oldLineRange: oldFirst...oldLast, newLineCount: lines.count, firstLine: oldFirst, lastLineNow: newLast)
        onLinesEdited?(oldFirst...oldLast, newLast)
        let edited = oldFirst...max(oldFirst, newLast)
        indentPending = indentPending.map { min($0.lowerBound, edited.lowerBound)...max($0.upperBound, edited.upperBound) } ?? edited
        if !isDirty, !isLoading {
            isDirty = true
            onChange?(self)
        }
    }

    /// Lines whose wrap indent needs setting again (they were edited).
    private var indentPending: ClosedRange<Int>?

    func takePendingIndentLines() -> ClosedRange<Int>? {
        defer { indentPending = nil }
        guard let pending = indentPending else { return nil }
        let last = lines.count - 1
        guard pending.lowerBound <= last else { return nil }
        return pending.lowerBound...min(pending.upperBound, last)
    }

    /// Text being replaced from disk, which is not an edit.
    private var isLoading = false

    @objc private func undoOrRedo() {
        // Undoing back to what is saved is clean again.
        let dirty = text.hashValue != savedHash
        if dirty != isDirty {
            isDirty = dirty
            onChange?(self)
        }
    }

    // MARK: disk

    func save() throws {
        let data = TextFile.encode(text, as: format)
        try TextFile.write(data, to: url)
        stamp = FileStamp(path: url.path)
        savedHash = text.hashValue
        isDirty = false
        conflict = nil
        onChange?(self)
    }

    /// Loads what is on disk now, dropping unsaved edits. False if it is no longer a readable text file.
    @discardableResult
    func reload() -> Bool {
        guard let data = try? Self.read(url), let (text, format) = TextFile.decode(data) else { return false }
        isLoading = true
        defer { isLoading = false }
        self.format = format
        replaceChanged(with: text)
        onTextReplaced?()
        undoManager.removeAllActions()
        stamp = FileStamp(path: url.path)
        savedHash = text.hashValue
        isDirty = false
        conflict = nil
        onChange?(self)
        return true
    }

    /// Checks the file on disk. A clean document follows it (an agent's edit shows up at once); one with
    /// unsaved edits is marked as conflicting instead, for the user to decide.
    func checkDisk() {
        guard conflict == nil else { return }
        let now = FileStamp(path: url.path)
        guard now != stamp else { return }
        guard now != nil else {
            conflict = .deletedOnDisk
            onChange?(self)
            return
        }
        // Same content (touched, or our own save seen late): nothing to do.
        if let data = try? Self.read(url), let (diskText, _) = TextFile.decode(data), diskText.hashValue == savedHash {
            stamp = now
            return
        }
        if isDirty {
            conflict = .changedOnDisk
            onChange?(self)
        } else if !reload() {
            conflict = .changedOnDisk
            onChange?(self)
        }
    }

    /// The file was renamed or moved in the sidebar.
    func moved(to newURL: URL) {
        url = URL(fileURLWithPath: canonicalPath(newURL.path))
        stamp = FileStamp(path: url.path)
        onChange?(self)
    }

    // MARK: fonts

    func applyFont() {
        storage.beginEditing()
        storage.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }
}
