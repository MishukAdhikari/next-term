import AppKit
import NextTermCore

/// Editing in the SQLite viewer, opt-in for one tab. "Allow Editing…" asks first (the file may belong to
/// an app that is running now, named when one has it open) and binds the allowance to the file's device
/// and inode; it ends on Stop Editing, on closing the tab, or when the file is replaced on disk, and is
/// never remembered. Nothing writes until Save: then SQLiteWriter writes one checked value on its own
/// connection, on the reading queue, and the page is read again. A save checks the row as well as the
/// cell, against the row as it was read when the draft opened. Each save is one step on the window's undo
/// manager, written back the same checked way. While a save is under way, closing the tab, Stop Editing
/// and leaving the draft wait for it. No agent or MCP path reaches any of this.
extension DatabasePane {
    /// The file a tab may edit: its device and inode when editing was allowed.
    struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    /// The cell a draft belongs to: its table, its row's key and its column.
    struct EditedCell: Equatable {
        let table: String
        let key: SQLiteRowKey
        let column: String
    }

    /// Editing in one tab: whether it is allowed (and for which file), the draft, and its saves' undo steps.
    struct EditState {
        var allowed: FileIdentity?
        var draft: CellDraft?
        var cell: EditedCell?
        /// The draft's row as read when the draft opened (SQLiteEdit.row).
        var row: [SQLiteColumnValue] = []
        var isSaving = false
        /// What waits for the save under way: closing the tab, Stop Editing, leaving the draft, another write.
        var afterSave: [() -> Void] = []
        /// Editing ends once the save under way is written: Stop Editing or closing the tab waits for it, or
        /// closing's Save wrote it. It leaves no undo step, and its notice no Undo.
        var endsAfterSave = false
        /// The last save's sentence, or why the typed text can't be saved.
        var message: String?
        /// The draft is in the cell's own field rather than the detail pane.
        var inCell = false
        var steps: [CellUndoStep] = []
    }

    /// The current cell as an edit names it, and why it can't be edited (nil: it can).
    struct EditTarget {
        let table: SQLiteTable
        let key: SQLiteRowKey?
        let column: String
        let value: SQLiteValue
        let reason: String?

        var cell: EditedCell? { key.map { EditedCell(table: table.name, key: $0, column: column) } }
    }

    /// What became of a value being typed in its cell when the grid is made again.
    enum InCellAside {
        /// Changed: it is in the detail pane now, which takes the keyboard.
        case moved
        /// Unchanged: closed, to open again in its cell if it is still there.
        case reopen(EditedCell)
    }

    var isEditingAllowed: Bool { edit.allowed != nil }
    /// A draft that would change its cell: the tab shows the modified dot, and File › Save is on.
    var hasDraft: Bool { edit.draft?.isModified == true }

    /// Runs `action` once the save under way has its outcome (at once when there is none). `ending`: the
    /// action stops editing or closes the tab, so a save that goes through leaves no undo step.
    func whenSaved(ending: Bool = false, _ action: @escaping () -> Void) {
        guard edit.isSaving else { return action() }
        if ending { edit.endsAfterSave = true }
        edit.afterSave.append(action)
    }

    // MARK: allowing

    @objc func editingButtonClicked() {
        isEditingAllowed ? stopEditing() : askToAllowEditing()
    }

    /// Says why the file can't be edited, or asks first, naming the processes that have it open.
    func askToAllowEditing(holders given: [String]? = nil) {
        guard let window else { return }
        if let problem = SQLiteWriter.writeProblem(at: path) {
            let alert = NSAlert()
            alert.messageText = "“\(name)” can’t be edited"
            alert.informativeText = problem
            alert.beginSheetModal(for: window)
            return
        }
        guard let holders = given else {
            let path = self.path
            queue.async { [weak self] in
                let holders = FileHolders.processes(holding: path)
                DispatchQueue.main.async { self?.askToAllowEditing(holders: holders) }
            }
            return
        }
        Self.allowAlert(name: name, holders: holders).beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.allowEditing()
        }
    }

    /// "Allow editing “agent.db”?", naming who has it open.
    static func allowAlert(name: String, holders: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow editing “\(name)”?"
        let open = holders.isEmpty ? "" : " (open in \(TerminalWindowController.nameList(holders)))"
        alert.informativeText = "It may belong to an app that is running now\(open). Changes are written to the file when you click Save, "
            + "one value at a time, and only if that value and its row haven’t changed since they were read. Edit › Undo puts back your last saved change "
            + "the same way. Editing stays allowed until you close this tab or click Stop Editing."
        alert.addButton(withTitle: "Allow Editing")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// After the sheet's Allow Editing.
    func allowEditing() {
        guard let identity = FileIdentity(path: path) else { return NSSound.beep() }
        edit.allowed = identity
        edit.message = nil
        editingChanged()
    }

    /// Back to read-only: the draft goes (asking first when there is one), and this tab's undo steps. A save
    /// under way is waited for, so what it says comes first; written, it leaves no undo step.
    func stopEditing(asking: Bool = true) {
        guard isEditingAllowed else { return }
        if edit.isSaving { return whenSaved(ending: true) { [weak self] in self?.stopEditing(asking: asking) } }
        if asking, hasDraft, let window, let cell = edit.cell {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Stop editing with an unsaved change to “\(CellText.line(cell.column, limit: 80))”?"
            alert.informativeText = "Your change is lost: nothing is written to the file."
            alert.addButton(withTitle: "Stop Editing")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.stopEditing(asking: false)
            }
            return
        }
        closeEditing()
        editingChanged()
    }

    /// The tab closes, or editing stops: nothing it allowed outlives it, its undo steps included.
    func closeEditing() {
        endDraft()
        for step in edit.steps { window?.undoManager?.removeAllActions(withTarget: step) }
        edit.steps = []
        edit.allowed = nil
        edit.message = nil
    }

    /// The file under the allowance was replaced (another inode at the path): editing stops.
    func checkIdentity() {
        guard let allowed = edit.allowed, FileIdentity(path: path) != allowed else { return }
        closeEditing()
        editingChanged()
        GitToast.show("“\(name)” was replaced on disk, so editing stopped", in: window, isError: true)
    }

    func editingChanged() {
        showSummary()
        showEditButton()
        showCurrentCell()
        onTitleChange?()
        onDraftChange?()
    }

    // MARK: drafts

    var currentEditTarget: EditTarget? {
        guard let page, let current = grid.currentCell, current.row < page.rows.count, current.column < page.columns.count,
              let table = currentTable, let value = currentValue else { return nil }
        let key = current.row < page.keys.count ? page.keys[current.row] : nil
        let column = page.columns[current.column]
        // Cut on the page and not yet read whole: editable once it is, if nothing else stands in the way.
        let pending = value.isTruncated && currentCellKey.map { wholeValues[$0.cell] == nil } ?? true
        let reason = SQLiteEditRules.reason(table: table, info: page.info, column: column, value: pending ? .text("", truncated: false) : value, key: key)
        return EditTarget(table: table, key: key, column: column, value: value, reason: reason ?? (pending ? "Reading the whole value…" : nil))
    }

    /// Why the current cell can't be edited now, for the detail pane's line.
    var editReason: String? { isEditingAllowed ? currentEditTarget?.reason : nil }

    /// ↩ or a double-click with editing allowed: a short value in its cell, anything else in the detail.
    func beginEditing() {
        guard isEditingAllowed, let target = currentEditTarget, let current = grid.currentCell else { return enterValue() }
        if edit.draft != nil, edit.cell == target.cell, !edit.inCell { return enterValue() }
        guard target.reason == nil, !target.value.isTruncated else { return enterValue() }
        if SQLiteEditRules.inCellEditable(target.value) { return beginInCellEdit(row: current.row, column: current.column) }
        beginDetailEdit()
    }

    /// Before a new draft replaces one on another cell: a change there is saved or put back first, and
    /// `then` runs after. True when nothing stands in the way.
    private func mayReplaceDraft(with cell: EditedCell, then: @escaping () -> Void) -> Bool {
        guard edit.draft != nil, edit.cell != cell else { return true }
        return askToLeaveDraft(then: then)
    }

    /// Opens a draft on the current cell (or keeps the one open there), in the detail pane.
    func beginDetailEdit() {
        guard isEditingAllowed, let target = currentEditTarget, target.reason == nil, !target.value.isTruncated,
              let cell = target.cell, let column = page?.info?.column(named: target.column), let current = grid.currentCell else { return NSSound.beep() }
        guard mayReplaceDraft(with: cell, then: { [weak self] in self?.beginDetailEdit() }) else { return }
        if edit.cell != cell || edit.draft == nil {
            edit.draft = CellDraft(original: target.value, column: column)
            edit.cell = cell
            edit.row = rowSnapshot(current.row)
        }
        // From its cell's field: the draft has what was typed there, and the cell shows the file's value again.
        if edit.inCell { grid.endEditInPlace() }
        edit.inCell = false
        // An indented JSON value is edited as stored.
        var json = false
        if case let .text(text, _) = target.value { json = JSONIndent.pretty(text) != nil }
        edit.message = json ? "You are editing the text as stored, not the indented view." : nil
        showDetail(true)
        showCurrentCell()
        detail.focusValue()
    }

    /// The field of the current cell takes the value, for one edit: ↩ saves, Esc cancels.
    func beginInCellEdit(row: Int, column: Int) {
        guard let target = currentEditTarget, let cell = target.cell, let info = page?.info?.column(named: target.column) else { return }
        guard mayReplaceDraft(with: cell, then: { [weak self] in self?.beginEditing() }) else { return }
        let draft = CellDraft(original: target.value, column: info)
        edit.draft = draft
        edit.cell = cell
        edit.row = rowSnapshot(row)
        edit.inCell = true
        edit.message = nil
        grid.editInPlace(row: row, column: column, text: draft.text) { [weak self] end in self?.inCellEnded(end) }
        draftChanged()
    }

    private func inCellEnded(_ end: DatabaseGridView.InPlaceEnd) {
        switch end {
        case let .typed(text):
            edit.draft?.type(text)
            draftChanged()
        case let .save(text):
            edit.draft?.type(text)
            save()
        case .cancel:
            endDraft()
            window?.makeFirstResponder(grid)
        case let .left(text):
            edit.draft?.type(text)
            edit.inCell = false
            guard hasDraft else { return endDraft() }
            // Kept, in the detail pane, where Save and Revert are.
            showDetail(true)
            showCurrentCell()
        }
    }

    /// A draft in its cell that can't be saved goes to the detail pane, where what is wrong can be read.
    func moveDraftToDetail() {
        guard edit.inCell else { return }
        grid.endEditInPlace()
        edit.inCell = false
        showDetail(true)
        showCurrentCell()
    }

    /// The note a changed draft carries when the grid was made again under it.
    static let movedNote = "The file changed while you typed, so your change moved here. Nothing has been written."

    /// Before the grid is made again (the page was read again, or another one shown): a value being typed in
    /// its cell can't stay in a field that goes away. A changed one moves to the detail pane, with the
    /// keyboard and a note; an unchanged one closes, to open again in its cell.
    func moveInCellDraftAside() -> InCellAside? {
        guard edit.inCell else { return nil }
        if let typed = grid.inPlaceText { edit.draft?.type(typed) }
        grid.endEditInPlace(redraw: false)
        edit.inCell = false
        guard hasDraft else {
            let cell = edit.cell
            endDraft()
            return cell.map { .reopen($0) }
        }
        edit.message = Self.movedNote
        showDetail(true)
        onDraftChange?()
        return .moved
    }

    /// The detail's text changed.
    func draftTyped(_ text: String) {
        guard edit.draft != nil, !edit.inCell else { return }
        edit.draft?.type(text)
        edit.message = edit.draft?.error?.message
        draftChanged()
    }

    func setDraftNull() {
        guard edit.draft?.canSetNull == true else { return NSSound.beep() }
        edit.draft?.isNull = true
        edit.message = nil
        draftChanged()
    }

    /// Revert, or Esc in the cell: the draft goes and the cell shows what the file holds.
    func revertDraft() {
        endDraft()
        window?.makeFirstResponder(grid)
    }

    func endDraft() {
        let had = edit.draft != nil
        if edit.inCell { grid.endEditInPlace() }
        edit.draft = nil
        edit.cell = nil
        edit.row = []
        edit.inCell = false
        edit.message = nil
        if had {
            showCurrentCell()
            onDraftChange?()
        }
    }

    func draftChanged() {
        detail.showEditing(editingUI)
        onDraftChange?()
    }

    /// What the detail's edit controls show.
    var editingUI: CellDetailView.Editing? {
        guard isEditingAllowed else { return nil }
        let target = currentEditTarget
        let here = edit.draft != nil && edit.cell != nil && edit.cell == target?.cell && !edit.inCell
        var ui = CellDetailView.Editing()
        ui.reason = here ? nil : editReason
        ui.isEditing = here
        ui.text = here ? edit.draft?.text : nil
        ui.isNull = here && edit.draft?.isNull == true
        ui.isModified = here && hasDraft
        ui.canSetNull = edit.draft?.canSetNull == true
        ui.isSaving = edit.isSaving
        ui.message = here || edit.inCell ? edit.message : nil
        return ui
    }

    // MARK: moving with a draft

    /// Before the current cell moves away from a draft: Save, Don't Save or Cancel.
    func shouldLeaveDraft(to row: Int, column: Int) -> Bool {
        askToLeaveDraft { [weak self] in self?.grid.setCurrent(row: row, column: column) }
    }

    /// True when there is no change to lose; else asks, and `then` runs once it is saved or put back. While a
    /// save is under way it waits for the outcome, then decides again.
    func askToLeaveDraft(then: @escaping () -> Void) -> Bool {
        if edit.isSaving {
            whenSaved { [weak self] in
                guard let self, self.askToLeaveDraft(then: then) else { return }
                then()
            }
            return false
        }
        guard hasDraft, let cell = edit.cell, let window else {
            if edit.draft != nil { endDraft() }
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save your change to “\(CellText.line(cell.column, limit: 80))”?"
        alert.informativeText = "Don’t Save puts the cell back as the file has it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save { saved in if saved { then() } }
            case .alertThirdButtonReturn:
                self.endDraft()
                then()
            default:
                break
            }
        }
        return false
    }

    // MARK: saving

    enum WriteKind { case save, undo, redo }

    /// File › Save, the Save button, ↩ in the cell: writes the draft, one checked value in its row as read.
    /// `ending`: the tab closes once it is written (closing's Save), so it leaves no undo step.
    func save(ending: Bool = false, then done: ((Bool) -> Void)? = nil) {
        guard let draft = edit.draft, let cell = edit.cell, isEditingAllowed, !edit.isSaving else {
            NSSound.beep()
            done?(false)
            return
        }
        guard draft.isModified else {
            endDraft()
            done?(true)
            return
        }
        switch draft.value() {
        case let .failure(error):
            edit.message = error.message
            moveDraftToDetail()
            draftChanged()
            done?(false)
        case let .success(value):
            write(SQLiteEdit(table: cell.table, column: cell.column, key: cell.key, expected: draft.original, value: value, row: edit.row),
                  as: .save, ending: ending, then: done)
        }
    }

    /// Writes on the reading queue, which takes reads and writes in turn; "saving…" meanwhile. `step` is the
    /// undo step registered for it, taken off again if the write is refused. One write at a time: another
    /// waits for the one under way. `ending`: editing ends once it is written.
    func write(_ change: SQLiteEdit, as kind: WriteKind, step: CellUndoStep? = nil, ending: Bool = false, then done: ((Bool) -> Void)? = nil) {
        if edit.isSaving { return whenSaved { [weak self] in self?.write(change, as: kind, step: step, ending: ending, then: done) } }
        guard let allowed = edit.allowed, FileIdentity(path: path) == allowed else {
            if let step { drop(step) }
            checkIdentity()
            done?(false)
            return
        }
        edit.isSaving = true
        edit.endsAfterSave = ending
        if kind == .save { edit.message = "saving…" }
        draftChanged()
        let path = self.path
        queue.async { [weak self] in
            let outcome = SQLiteWriter.save(change, at: path)
            DispatchQueue.main.async { self?.wrote(outcome, change, kind, step: step, then: done) }
        }
    }

    private func wrote(_ outcome: SQLiteSaveOutcome, _ change: SQLiteEdit, _ kind: WriteKind, step: CellUndoStep?, then done: ((Bool) -> Void)?) {
        edit.isSaving = false
        let ending = edit.endsAfterSave
        edit.endsAfterSave = false
        #if DEBUG
        lastOutcome = outcome
        #endif
        defer {
            // What waited for this save decides now, in turn.
            let waiting = edit.afterSave
            edit.afterSave = []
            waiting.forEach { $0() }
        }
        let column = CellText.line(change.column, limit: 60)
        guard case let .saved(stored, row) = outcome else {
            // A refused undo or redo leaves no step behind to try it again.
            if let step { drop(step) }
            if kind == .save {
                edit.message = outcome.message
                if case let .changed(current) = outcome, let draft = edit.draft {
                    // The draft stays, checked next time against the value now there.
                    var again = CellDraft(original: current, column: draft.column)
                    again.text = draft.text
                    again.isNull = draft.isNull
                    edit.draft = again
                }
                // Checked next time against the row as it is now: a second Save is a choice made seeing it.
                if case let .rowChanged(now) = outcome, edit.draft != nil { edit.row = now }
                moveDraftToDetail()
            } else {
                let what = kind == .undo ? "undone" : "redone"
                switch outcome {
                case .changed: GitToast.show("Changed since your save; nothing was \(what)", in: window, isError: true)
                case .rowChanged: GitToast.show("Its row changed since your save; nothing was \(what)", in: window, isError: true)
                default: GitToast.show(outcome.message, in: window, isError: true)
                }
            }
            // Read again, so the cell shows the value it was refused for, not the one the page still has from
            // before: an edit opened on that one would only be refused in turn.
            reloadPage()
            draftChanged()
            done?(false)
            return
        }
        let applied = SQLiteEdit(table: change.table, column: change.column, key: change.key, expected: change.expected, value: stored, row: change.row)
        // The step back from an undo or a redo checks the row as this write left it.
        step?.change = applied.reversed(row: row)
        // The cell's field closes before its row shows the value as stored.
        if kind == .save, edit.inCell {
            grid.endEditInPlace(redraw: false)
            edit.inCell = false
        }
        showSaved(row, table: change.table, key: change.key)
        if kind == .save {
            // Editing ends now that it is written: no step is left that could only do nothing. Nor is one
            // registered to be taken off at once: the undo manager drops a group its last action leaves only
            // once the group is closed, at the end of this turn of the run loop, so a step taken off in the
            // turn it was registered leaves its group behind, empty, still on Edit › Undo as Edit Cell.
            let undo = isEditingAllowed && !ending ? registerStep(applied.reversed(row: row), kind: .undo) : nil
            edit.draft = nil
            edit.cell = nil
            edit.row = []
            edit.inCell = false
            edit.message = nil
            if window?.firstResponder === detail.textView { window?.makeFirstResponder(grid) }
            if let undo {
                GitToast.show("Saved “\(column)” in \(change.key.label)", in: window, button: "Undo") { [weak self, weak undo] in
                    guard let self, let undo, self.edit.steps.contains(where: { $0 === undo }) else { return }
                    // One checked write, with no step back: the notice's Undo and ⌘Z undo it once between them.
                    self.drop(undo)
                    self.write(undo.change, as: .undo)
                }
            } else {
                GitToast.show("Saved “\(column)” in \(change.key.label)", in: window)
            }
        } else {
            let done = kind == .undo ? "Undone" : "Redone"
            GitToast.show("\(done): “\(column)” in \(change.key.label)", in: window)
        }
        reloadPage()
        draftChanged()
        done?(true)
    }

    /// One "Edit Cell" step on the window's undo manager: `change` written by the same checked rule.
    @discardableResult
    func registerStep(_ change: SQLiteEdit, kind: WriteKind) -> CellUndoStep? {
        guard let undo = window?.undoManager else { return nil }
        let step = CellUndoStep(pane: self, change: change, kind: kind)
        edit.steps.append(step)
        undo.registerUndo(withTarget: step) { $0.run() }
        undo.setActionName("Edit Cell")
        return step
    }

    func drop(_ step: CellUndoStep) {
        window?.undoManager?.removeAllActions(withTarget: step)
        edit.steps.removeAll { $0 === step }
    }

    /// The page in view, read again; the current cell stays on its row, by key.
    func reloadPage() {
        guard let table = selectedTable else { return }
        load(table, offset: page?.offset ?? 0)
    }
}

/// One undo (or redo) step of a save, its own target so a refused one can be taken off alone.
final class CellUndoStep: NSObject {
    weak var pane: DatabasePane?
    /// What the step writes. A step back registered before its write ran checks the row as that write
    /// found it, until the write says how it left the row.
    var change: SQLiteEdit
    let kind: DatabasePane.WriteKind

    init(pane: DatabasePane, change: SQLiteEdit, kind: DatabasePane.WriteKind) {
        self.pane = pane
        self.change = change
        self.kind = kind
    }

    /// Writes the change, checked. The step back is registered now, while the undo manager undoes (or
    /// redoes), so it lands on the other side; the write follows on the reading queue.
    func run() {
        guard let pane, pane.isEditingAllowed else { return }
        pane.edit.steps.removeAll { $0 === self }
        let back = pane.registerStep(change.reversed(row: change.row), kind: kind == .undo ? .redo : .undo)
        pane.write(change, as: kind, step: back)
    }
}
