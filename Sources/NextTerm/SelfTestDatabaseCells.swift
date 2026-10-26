#if DEBUG
import AppKit
import NextTermCore
import SQLite3

// MARK: - Database cells: one line each, the whole value beside the grid, and editing a SQLite file

extension SelfTest {
    /// An agent's store, made in the self-test's project folder: messages with a full-text index its triggers
    /// keep, a view, settings in a WITHOUT ROWID table, and a table whose columns hide the rowid. A second
    /// connection to it stands in for the app that owns it.
    final class CellStore {
        static let long = String(repeating: "A long message, one of many lines.\n", count: 1429).prefix(50_000).description
        static let toolCall = #"{"name":"read_file","arguments":{"path":"a.md","limit":1.0}}"#
        static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<3064).map { UInt8($0 % 251) })
        /// Row 19's content: paragraphs with blank lines between them.
        static let paragraphs = (1...12).map { "Paragraph \($0) of a long answer, " + String(repeating: "with words ", count: 16) }.joined(separator: "\n\n")
        /// Row 25's content: a lone CR, a line separator and an escape sequence.
        static let controls = "first\rsecond\u{2028}third \u{1B}[0m end"

        let folder: URL
        let path: String
        private var db: OpaquePointer?

        init(in folder: URL, name: String = "agent.db", wal: Bool = false) {
            self.folder = folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            path = canonicalPath(folder.appendingPathComponent(name).path)
            try? FileManager.default.removeItem(atPath: path)
            sqlite3_open(path, &db)
            if wal { exec("PRAGMA journal_mode = WAL") }
            exec("""
                CREATE TABLE messages (id INTEGER PRIMARY KEY, role TEXT, content TEXT COLLATE NOCASE, tool_call TEXT, attachment BLOB, created REAL NOT NULL);
                CREATE VIRTUAL TABLE messages_fts USING fts5(content);
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN INSERT INTO messages_fts (rowid, content) VALUES (new.id, new.content); END;
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN DELETE FROM messages_fts WHERE rowid = old.id; END;
                CREATE TRIGGER messages_au AFTER UPDATE OF content ON messages BEGIN UPDATE messages_fts SET content = new.content WHERE rowid = old.id; END;
                CREATE VIEW recent AS SELECT id, role, content FROM messages ORDER BY created DESC;
                CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
                CREATE TABLE hide (rowid, _rowid_, oid);
                INSERT INTO kv VALUES ('theme', 'dark'), ('font', 'mono');
                INSERT INTO hide VALUES (7, 8, 9);
                BEGIN;
                """)
            for id in 1...80 {
                let content: String
                switch id {
                case 5: content = "Hello"
                case 7: content = "draft"
                case 12: content = Self.long
                case 19: content = Self.paragraphs
                case 25: content = Self.controls
                default: content = "message \(id)"
                }
                insert(id: id, role: id % 2 == 1 ? "user" : "assistant", content: content, toolCall: id == 3 ? Self.toolCall : nil,
                       attachment: id == 3 ? Self.png : nil, created: Double(id))
            }
            exec("COMMIT")
            if wal {
                // As an app leaves its store when it quits: in WAL mode, nothing beside it.
                var keep: Int32 = 0
                sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &keep)
            }
            sqlite3_close(db)
            db = nil
        }

        /// The other app's connection, open until `close`.
        func open() {
            guard db == nil else { return }
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        }

        func close() {
            sqlite3_close(db)
            db = nil
        }

        deinit { close() }

        @discardableResult
        func exec(_ sql: String) -> Bool {
            let opened = db == nil
            if opened { open() }
            defer { if opened { close() } }
            return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }

        func one(_ sql: String) -> String? {
            let opened = db == nil
            if opened { open() }
            defer { if opened { close() } }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }

        private func insert(id: Int, role: String, content: String, toolCall: String?, attachment: Data?, created: Double) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO messages VALUES (?1, ?2, ?3, ?4, ?5, ?6)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(statement, 1, Int64(id))
            sqlite3_bind_text(statement, 2, role, -1, transient)
            sqlite3_bind_text(statement, 3, content, -1, transient)
            if let toolCall { sqlite3_bind_text(statement, 4, toolCall, -1, transient) } else { sqlite3_bind_null(statement, 4) }
            if let attachment {
                _ = attachment.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(attachment.count), transient) }
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_double(statement, 6, created)
            sqlite3_step(statement)
        }
    }

    /// Clicks and keys as a hand makes them while the app is in front; the same methods otherwise.
    @MainActor
    struct CellHand {
        let window: NSWindow
        let byHand: Bool

        /// A click on a cell of `table` (`count` 2: a double-click's second click).
        func click(_ table: NSTableView, row: Int, column: Int, count: Int = 1) {
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(column)
            table.layoutSubtreeIfNeeded()
            // Where a hand would click: the middle of what shows of the cell. A cell wider than the grid (the Lines
            // view's text is 4,000 points) has its own middle off the grid, and off the window.
            let cell = table.frameOfCell(atColumn: column, row: row)
            let shown = cell.intersection(table.visibleRect)
            let rect = shown.isEmpty ? cell : shown
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard byHand else {
                if let grid = table as? DatabaseGridView {
                    let moves = row != grid.selectedRow || column != grid.currentColumn
                    if moves, grid.shouldMoveCurrentCell?(row, column) == false { return }
                    grid.setCurrent(row: row, column: column)
                    grid.onClickCell?(count)
                } else if let action = table.action {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    _ = table.target.map { NSApp.sendAction(action, to: $0, from: table) }
                }
                return
            }
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            // A mouse-up the view did not track (the click was refused) is not left for the next one.
            while NSApp.nextEvent(matching: [.leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        }

        /// A key, to the window's first responder: ↑ 126, ↓ 125, ← 123, → 124, ↩ 36, Space 49, Esc 53.
        func key(_ code: UInt16) {
            let characters: String
            switch code {
            case 126: characters = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case 125: characters = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case 123: characters = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case 124: characters = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case 36: characters = "\r"
            case 49: characters = " "
            case 53: characters = "\u{1B}"
            default: characters = ""
            }
            let flags: NSEvent.ModifierFlags = (123...126).contains(code) ? [.numericPad, .function] : []
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            if byHand { NSApp.sendEvent(event) } else { window.firstResponder?.keyDown(with: event) }
        }

        /// ⌘S, through File › Save.
        func save(_ c: TerminalWindowController) {
            if byHand { SelfTest.pressKey("s", code: 1, [.command], in: window) } else { c.saveDocument(nil) }
        }

        /// ⌘Z, through Edit › Undo.
        func undo() {
            if byHand { SelfTest.pressKey("z", code: 6, [.command], in: window) } else { window.undoManager?.undo() }
        }
    }

    /// The SQLite viewer's cells (AE1–AE15): each draws on one line inside its row; a click shows the whole
    /// value beside the grid, a cut one read once by its key; the keys move the cell; then editing, allowed
    /// after a question that names the process holding the file, writing one checked value per Save, with
    /// Undo, refusals and the other app's own writes.
    static func databaseCellChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window else { return check(false, "database cells: a window") }
        let fm = FileManager.default
        let folder = proj.appendingPathComponent("store")
        let store = CellStore(in: folder)
        // A process of the self-test's own holds the file open, as the agent that owns it would.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["120"]
        holder.standardInput = FileHandle(forReadingAtPath: store.path)
        try? holder.run()
        defer {
            holder.terminate()
            holder.waitUntilExit()
            try? fm.removeItem(at: folder)
        }
        let byHand = await bringToFront(window)
        if !byHand { note("database cells: the app is not frontmost, so the clicks and keys go through the app's own calls (\(notFrontmost(window)))") }
        let hand = CellHand(window: window, byHand: byHand)
        let area = c.editorArea
        let before = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        let stamp = FileStamp(path: store.path)
        area.openDatabase(store.path)
        guard let pane = area.activeDatabase, pane.path == store.path else { return check(false, "database cells: the store opens in the viewer", area.activeName ?? "nothing") }
        defer { if area.panes.contains(where: { $0 === pane }) { pane.closeEditing(); area.closeAll() } }
        check(await wait(5) { pane.isSettled && pane.page != nil }, "database cells: the viewer reads the store", pane.loadError ?? "")
        pane.select(table: "messages")
        check(await wait(5) { pane.isSettled && pane.page?.table == "messages" }, "database cells: messages opens on its first page")
        guard let page = pane.page, let content = page.columns.firstIndex(of: "content"), let toolCall = page.columns.firstIndex(of: "tool_call"),
              let attachment = page.columns.firstIndex(of: "attachment") else { return check(false, "database cells: messages' columns", "\(pane.page?.columns ?? [])") }
        let grid = pane.grid

        // AE1: every cell draws on one line, inside its row.
        func cellsDrawOneLine(_ grid: NSTableView, rows: [Int], column: Int) -> String? {
            for row in rows {
                grid.scrollRowToVisible(row)
                grid.layoutSubtreeIfNeeded()
                guard let cell = grid.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCellView else { return "no cell at row \(row + 1)" }
                cell.layoutSubtreeIfNeeded()
                let text = cell.label.stringValue
                if text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
                    return "row \(row + 1) holds a line break or control character: \(text.prefix(60))"
                }
                if cell.label.frame.height > grid.rowHeight + 0.5 || cell.label.frame.minY < -0.5 || cell.label.frame.maxY > cell.bounds.height + 0.5 {
                    return "row \(row + 1)'s label is \(cell.label.frame) in a cell of \(cell.bounds)"
                }
                if #available(macOS 14, *), !cell.clipsToBounds { return "row \(row + 1)'s cell does not clip" }
            }
            return nil
        }
        check(cellsDrawOneLine(grid, rows: [18, 24] + Array(0..<30), column: content) == nil,
              "AE1: every content cell draws on one line inside its row, clipped", cellsDrawOneLine(grid, rows: [18, 24] + Array(0..<30), column: content) ?? "")
        grid.scrollRowToVisible(18)
        grid.layoutSubtreeIfNeeded()
        let long = (grid.view(atColumn: content, row: 18, makeIfNecessary: true) as? GridCellView)?.label.stringValue ?? ""
        let marks = (grid.view(atColumn: content, row: 24, makeIfNecessary: true) as? GridCellView)?.label.stringValue ?? ""
        check(long.contains(" ⏎  ⏎ ") && long.hasSuffix("…") && long.count == 301, "AE1: row 19's paragraphs show ⏎ marks and end in “…”", String(long.prefix(80)))
        check(marks == "first ⏎ second ⏎ third ␛[0m end", "AE1: row 25's CR, line separator and escape show as marks", marks)

        // AE2: a click on row 3's tool_call shows it as JSON, keys in order and numbers as stored; Copy gives it as stored.
        hand.click(grid, row: 2, column: toolCall)
        check(await wait(3) { pane.isDetailShown && pane.detail.detail?.title == "tool_call" }, "AE2: a click on a cell shows the detail pane beside the grid",
              pane.detail.detail?.title ?? "no detail")
        check(grid.currentCell?.row == 2 && grid.currentCell?.column == toolCall, "AE2: the click makes that cell current")
        let json = pane.detail.detail
        check(json?.kind == "JSON" && json?.body.hasPrefix("{\n  \"name\": \"read_file\",\n  \"arguments\": {") == true && json?.body.contains("\"limit\": 1.0") == true,
              "AE2: tool_call shows as indented JSON, name before arguments and 1.0 kept", json?.body ?? "")
        check(pane.detail.items.count == page.columns.count && pane.detail.items[safe: content]?.text == "message 3", "AE2: the row is listed below, a line a column")
        check(pane.detail.textView.accessibilityLabel() == "Value of tool_call", "AE2: the value says which column it is to VoiceOver")
        let saved = NSPasteboard.general.string(forType: .string)
        pane.detail.copyValue()
        let copied = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        check(copied == CellStore.toolCall, "AE2: Copy puts the stored text on the clipboard, not the indented view", copied ?? "")

        // AE4: a blob is its size and its first bytes in hex; a NULL is NULL; Copy is off for both.
        hand.click(grid, row: 2, column: attachment)
        _ = await wait(2) { pane.detail.detail?.title == "attachment" }
        let blob = pane.detail.detail
        let lines = blob?.body.components(separatedBy: "\n") ?? []
        check(blob?.kind == "BLOB · \(3072.formatted()) bytes" && lines.first == "00000000  89 50 4e 47 0d 0a 1a 0a  00 01 02 03 04 05 06 07  |.PNG............|"
              && lines[safe: 15]?.hasPrefix("000000f0") == true && lines.last == "\(2816.formatted()) more bytes",
              "AE4: the PNG shows as BLOB · 3,072 bytes and its first 256 bytes in hex", blob?.body.prefix(120).description ?? "")
        check(!pane.detail.copyButton.isEnabled, "AE4: Copy is off for a blob")
        hand.click(grid, row: 0, column: toolCall)
        _ = await wait(2) { pane.detail.detail?.isNull == true }
        check(pane.detail.detail?.kind == "NULL" && !pane.detail.copyButton.isEnabled, "AE4: a NULL tool_call shows NULL, and Copy is off")

        // AE3: a 50,000-character content shows whole after one read by its key; arrowing down 50 uncut rows reads nothing.
        let fetchesBefore = pane.fetches
        hand.click(grid, row: 11, column: content)
        check(await wait(5) { pane.detail.detail?.body.count == 50_000 && pane.detail.detail?.note == nil }, "AE3: a value cut on read is read whole by its key",
              "\(pane.detail.detail?.body.count ?? -1) characters, note \(pane.detail.detail?.note ?? "none")")
        check(pane.fetches == fetchesBefore + 1, "AE3: with exactly one read", "\(pane.fetches - fetchesBefore) reads")
        hand.click(grid, row: 12, column: content)
        window.makeFirstResponder(grid)
        for _ in 0..<50 {
            hand.key(125)
            await pause(0.005)
        }
        _ = await wait(2) { pane.detail.detail?.body == "message 63" }
        check(grid.selectedRow == 62 && pane.detail.detail?.body == "message 63", "R8: ↓ moves the row and the detail follows",
              "row \(grid.selectedRow + 1), \(pane.detail.detail?.body.prefix(30) ?? "")")
        check(pane.fetches == fetchesBefore + 1, "AE3: holding ↓ across 50 uncut rows reads nothing", "\(pane.fetches - fetchesBefore - 1) more reads")

        // R6, R8: ←→ move the column, a line of the row list makes its column current, Space hides and shows, ↩ and Esc.
        hand.key(124)
        check(await wait(2) { grid.currentColumn == content + 1 && pane.detail.detail?.title == "tool_call" }, "R8: → moves the current cell's column and the detail follows",
              "column \(grid.currentColumn)")
        hand.key(123)
        check(await wait(2) { grid.currentColumn == content && pane.detail.detail?.title == "content" }, "R8: ← moves it back")
        if hand.byHand { hand.click(pane.detail.rowList, row: 1, column: 1) } else { pane.detail.onSelectColumn?(1) }
        check(await wait(2) { grid.currentColumn == 1 && pane.detail.detail?.title == "role" }, "R6: a line of the row list makes that column current",
              "column \(grid.currentColumn)")
        window.makeFirstResponder(grid)
        hand.key(49)
        check(await wait(2) { !pane.isDetailShown }, "R8: Space hides the detail pane")
        hand.key(49)
        check(await wait(2) { pane.isDetailShown }, "R8: and Space shows it again")
        hand.key(36)
        check(await wait(2) { window.firstResponder === pane.detail.textView }, "R8: ↩ takes the keyboard into the value", String(describing: window.firstResponder))
        hand.key(53)
        check(await wait(2) { window.firstResponder === grid }, "R8: Esc goes back to the grid", String(describing: window.firstResponder))

        // R11: another app adds a row before the current one; after the file is read again the cell is still on its row.
        hand.click(grid, row: 9, column: content)
        _ = await wait(2) { pane.detail.detail?.body == "message 10" }
        store.exec("INSERT INTO messages (id, role, content, created) VALUES (0, 'user', 'message 0', 0)")
        check(await wait(6) {
            pane.refreshIfChanged()
            return pane.isSettled && pane.page?.rows.first?.first == .integer(0)
        }, "R11: the viewer reads the file again when another app writes to it")
        check(await wait(2) { grid.selectedRow == 10 && pane.detail.detail?.body == "message 10" }, "R11: and the current cell stays on its row, by its key",
              "row \(grid.selectedRow + 1), \(pane.detail.detail?.body.prefix(20) ?? "")")
        store.exec("DELETE FROM messages WHERE id = 0")
        _ = await wait(6) {
            pane.refreshIfChanged()
            return pane.isSettled && pane.page?.rows.first?.first == .integer(1)
        }
        check((try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() == before && FileStamp(path: store.path)?.inode == stamp?.inode,
              "database cells: reading leaves the folder as it was")
        await screenshot(c, suffix: "-database-cells")

        await databaseEditChecks(c, pane: pane, store: store, hand: hand, holder: "sleep")
        await endStrayQuestions(after: "the database cell checks")
        // The store goes, and with it its row in the sidebar's Databases group, before the checks after these.
        pane.closeEditing()
        area.closeAll()
        try? fm.removeItem(at: folder)
        _ = await wait(10) { c.sidebar.databasesGroup.items.isEmpty }
    }

    /// AE5–AE15: editing the store, allowed after the question.
    private static func databaseEditChecks(_ c: TerminalWindowController, pane: DatabasePane, store: CellStore, hand: CellHand, holder: String) async {
        let window = hand.window
        let area = c.editorArea
        let grid = pane.grid
        guard let page = pane.page, let role = page.columns.firstIndex(of: "role"), let content = page.columns.firstIndex(of: "content") else { return }
        func tab() -> TabBarItem? { area.tabBar.items[safe: area.panes.firstIndex { $0 === pane } ?? -1] }
        func settle() async -> Bool { await wait(5) { !pane.edit.isSaving && pane.isSettled } }
        func sheet() async -> NSWindow? { await wait(5) { window.attachedSheet != nil } ? window.attachedSheet : nil }
        func answer(_ code: NSApplication.ModalResponse) async {
            guard let sheet = window.attachedSheet else { return }
            window.endSheet(sheet, returnCode: code)
            _ = await wait(2) { window.attachedSheet !== sheet }
        }

        // AE5: read-only, and a double-click opens no editor; ⌘S writes nothing.
        check(pane.summaryText.hasSuffix("read-only") && !pane.isEditingAllowed, "AE5: the viewer opens saying read-only", pane.summaryText)
        let stamp = FileStamp(path: store.path)
        hand.click(grid, row: 0, column: role)
        hand.click(grid, row: 0, column: role, count: 2)
        check(await wait(2) { pane.isDetailShown } && grid.inPlaceField == nil && !pane.detail.textView.isEditable && pane.edit.draft == nil,
              "AE5: a double-click shows the detail, with no editor")
        check(pane.detail.editButton.isHidden, "AE5: and no Edit button while the tab is read-only")
        hand.save(c)
        check(FileStamp(path: store.path) == stamp, "AE5: ⌘S writes nothing")
        // The question names the file and who holds it; Cancel leaves it read-only.
        pane.editingButton.performClick(nil)
        let asked = await sheet().map { _ in sheetText(window) } ?? ""
        check(asked.contains("Allow editing “agent.db”?") && asked.contains("It may belong to an app that is running now (open in “\(holder)”)")
              && asked.contains("only if that value and its row haven’t changed since they were read") && asked.contains("Edit › Undo"),
              "AE5: Allow Editing… asks first, naming the file and the process holding it", asked)
        await answer(.alertSecondButtonReturn)
        check(!pane.isEditingAllowed && pane.summaryText.hasSuffix("read-only"), "AE5: Cancel leaves it read-only")
        pane.editingButton.performClick(nil)
        _ = await sheet()
        await answer(.alertFirstButtonReturn)
        check(pane.isEditingAllowed && pane.summaryText.hasSuffix("editing allowed") && pane.editingButton.title == "Stop Editing",
              "AE5: Allow gives “editing allowed”, and the button reads Stop Editing", pane.summaryText)
        check(tab()?.tooltip.contains("(SQLite, editing allowed)") == true && tab()?.accessibilityStatus.hasPrefix("database, editing allowed") == true,
              "AE5: the tab's tooltip and VoiceOver status say editing is allowed", tab()?.tooltip ?? "")
        check(pane.summaryTip.hasPrefix("Editing is allowed in this tab: Save writes one value to the file."), "AE5: and the summary's tooltip", pane.summaryTip)

        // AE6: role "user" to "assistant" in its cell: nothing written while typing, written by ↩, read again, a notice with Undo.
        hand.click(grid, row: 0, column: role)
        window.makeFirstResponder(grid)
        hand.key(36)
        guard await wait(2, { grid.inPlaceField?.currentEditor() != nil }), let editor = grid.inPlaceField?.currentEditor() as? NSTextView else {
            return check(false, "AE6: ↩ on a short value edits it in its cell", String(describing: window.firstResponder))
        }
        let typed = FileStamp(path: store.path)
        editor.insertText("assistant", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        check(pane.hasDraft && FileStamp(path: store.path) == typed, "AE6: typing changes only the draft")
        check(tab()?.modified == true, "AE6: the tab shows its modified dot with an unsaved value")
        pane.lastOutcome = nil
        GitToast.dismiss()
        if hand.byHand { hand.key(36) } else { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        let answered = await wait(5) { pane.lastOutcome != nil }
        let settled = await settle()
        check(answered && settled, "AE6: ↩ in the cell saves", String(describing: pane.lastOutcome))
        check(store.one("SELECT role || ' ' || typeof(role) FROM messages WHERE id = 1") == "assistant text" && FileStamp(path: store.path) != typed,
              "AE6: the file holds assistant, as text", store.one("SELECT role FROM messages WHERE id = 1") ?? "")
        check(await wait(3) { pane.page?.rows.first?[role] == .text("assistant", truncated: false) } && !pane.hasDraft && tab()?.modified == false,
              "AE6: the page is read again and shows it")
        check(GitToast.text == "Saved “role” in row 1", "AE6: a notice says what was saved, with Undo", GitToast.text ?? "no notice")

        // AE7: another app writes the cell after it was read: Save refuses and shows its value, the draft stays, a second Save writes.
        hand.click(grid, row: 6, column: content)
        _ = await wait(2) { pane.detail.detail?.body == "draft" }
        pane.beginDetailEdit()
        check(await wait(2) { pane.detail.textView.isEditable && window.firstResponder === pane.detail.textView }, "AE7: Edit opens the value in the detail pane")
        pane.detail.textView.insertText("mine", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        check(pane.hasDraft && pane.edit.draft?.text == "mine", "AE7: the detail's typing fills the draft")
        store.exec("UPDATE messages SET content = 'final' WHERE id = 7")
        pane.lastOutcome = nil
        hand.save(c)
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(pane.lastOutcome == .changed(current: .text("final", truncated: false)) && store.one("SELECT content FROM messages WHERE id = 7") == "final",
              "AE7: Save refuses a value changed since it was read, and writes nothing", String(describing: pane.lastOutcome))
        check(pane.detail.editLabel.stringValue == "Changed since it was read. Nothing was saved. Now: final" && pane.edit.draft?.text == "mine"
              && pane.detail.textView.string == "mine", "AE7: it says so with the value now there, and the draft stays", pane.detail.editLabel.stringValue)
        pane.lastOutcome = nil
        hand.save(c)
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT content FROM messages WHERE id = 7") == "mine", "AE7: a second Save, checked against final, writes mine", String(describing: pane.lastOutcome))
        // The same in the NOCASE column, changed only in case.
        hand.click(grid, row: 4, column: content)
        _ = await wait(2) { pane.detail.detail?.body == "Hello" }
        pane.beginDetailEdit()
        pane.detail.textView.insertText("Hello there", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        store.exec("UPDATE messages SET content = 'HELLO' WHERE id = 5")
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(pane.lastOutcome == .changed(current: .text("HELLO", truncated: false)), "AE7: a change only of case counts as a change", String(describing: pane.lastOutcome))

        // AE15: with an unsaved value, a click on another cell asks; Cancel keeps it.
        hand.click(grid, row: 7, column: content)
        let leaving = await sheet().map { _ in sheetText(window) } ?? ""
        check(leaving.contains("Save your change to “content”?"), "AE15: with an unsaved value, a click on another cell asks first", leaving)
        await answer(.alertSecondButtonReturn)
        check(grid.selectedRow == 4 && pane.edit.draft?.text == "Hello there", "AE15: Cancel keeps the cell and its draft")
        hand.click(grid, row: 7, column: content)
        _ = await sheet()
        await answer(.alertThirdButtonReturn)
        check(await wait(2) { grid.selectedRow == 7 && pane.edit.draft == nil }, "AE15: Don’t Save puts it back and moves on")

        // AE8: another app holds BEGIN IMMEDIATE: busy, nothing written, the draft kept; after it lets go, Save writes.
        hand.click(grid, row: 7, column: content)
        pane.beginDetailEdit()
        pane.detail.textView.insertText("while busy", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        store.open()
        store.exec("BEGIN IMMEDIATE")
        let busyBytes = FileManager.default.contents(atPath: store.path)
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(pane.lastOutcome == .busy && pane.detail.editLabel.stringValue == "The file is busy: another app is writing to it. Nothing was saved."
              && FileManager.default.contents(atPath: store.path) == busyBytes && pane.edit.draft?.text == "while busy",
              "AE8: a file another app is writing is busy: nothing written, the draft kept", String(describing: pane.lastOutcome))
        store.exec("ROLLBACK")
        store.close()
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT content FROM messages WHERE id = 8") == "while busy", "AE8: once it lets go, Save writes", String(describing: pane.lastOutcome))

        await inCellUnderWritesChecks(pane: pane, store: store, hand: hand, role: role, content: content)
        await leavingADraftChecks(pane: pane, hand: hand, role: role, content: content)
        await rowGivenOutAgainChecks(pane: pane, store: store, hand: hand, content: content)
        await noticeUndoChecks(pane: pane, store: store, hand: hand, role: role)
        await wholeValueReloadChecks(pane: pane, store: store, hand: hand, content: content)

        // AE10, AE11: what can't be edited says why; an edit to content keeps the full-text index in step.
        hand.click(grid, row: 1, column: content)
        pane.beginDetailEdit()
        pane.detail.textView.insertText("a zebra crossed", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'zebra'") == "2", "AE10: an edit to content is found by the full-text index, its triggers ran")
        func reason(of table: String, column: Int = 0) async -> String? {
            pane.select(table: table)
            _ = await wait(5) { pane.isSettled && pane.page?.table == table }
            hand.click(grid, row: 0, column: column)
            _ = await wait(2) { pane.detail.detail != nil }
            return pane.editReason
        }
        let virtual = await reason(of: "messages_fts")
        check(virtual == "A virtual table, kept by its full-text module: edit messages instead.", "AE10: a virtual table's cells say why they can't be edited", virtual ?? "nil")
        for shadow in ["messages_fts_data", "messages_fts_idx", "messages_fts_content", "messages_fts_docsize", "messages_fts_config"] {
            let why = await reason(of: shadow)
            check(why == "An internal table of messages_fts: changing it would break the index.", "AE10: \(shadow) says it is the index's own", why ?? "nil")
        }
        let view = await reason(of: "recent", column: 2)
        check(view == "A view shows rows from other tables; it can’t be edited here.", "AE11: a view's cells say why they can't be edited", view ?? "nil")
        if let row = pane.page?.rows.firstIndex(where: { $0[safe: 2]?.isTruncated == true }) {
            hand.click(grid, row: row, column: 2)
            _ = await wait(2) { pane.detail.detail?.note != nil }
            check(pane.detail.detail?.note?.hasPrefix("A view’s rows have no key") == true, "AE11: a view's cut value says it can't be read in full", pane.detail.detail?.note ?? "")
        } else {
            check(false, "AE11: the view lists the long message")
        }
        let hidden = await reason(of: "hide")
        check(hidden?.hasPrefix("Its columns named rowid, _rowid_ and oid hide the rowid") == true, "AE11: a table whose columns hide the rowid says why", hidden ?? "nil")

        // AE9: kv by its key; k is the key; ⌘Z writes it back.
        pane.select(table: "kv")
        _ = await wait(5) { pane.isSettled && pane.page?.table == "kv" }
        guard let theme = pane.page?.rows.firstIndex(where: { $0.first == .text("theme", truncated: false) }) else { return check(false, "AE9: kv lists theme") }
        hand.click(grid, row: theme, column: 0)
        _ = await wait(2) { pane.detail.detail?.title == "k" }
        check(pane.editReason == "This column is the row’s key.", "AE9: selecting k says it is the row's key", pane.editReason ?? "nil")
        hand.click(grid, row: theme, column: 1)
        window.makeFirstResponder(grid)
        hand.key(36)
        guard await wait(2, { grid.inPlaceField?.currentEditor() != nil }), let field = grid.inPlaceField?.currentEditor() as? NSTextView else {
            return check(false, "AE9: ↩ edits v in its cell")
        }
        field.insertText("light", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        pane.lastOutcome = nil
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "light", "AE9: a WITHOUT ROWID table's value is written by its key", String(describing: pane.lastOutcome))
        check(window.undoManager?.undoActionName == "Edit Cell", "AE12: the save is one Edit Cell step on Edit › Undo", window.undoManager?.undoActionName ?? "")
        window.makeFirstResponder(grid)
        pane.lastOutcome = nil
        hand.undo()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "dark", "AE9, AE12: ⌘Z writes dark back", String(describing: pane.lastOutcome))
        pane.lastOutcome = nil
        window.undoManager?.redo()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "light", "AE12: ⇧⌘Z writes it again", String(describing: pane.lastOutcome))
        // AE12: after another app changes the cell, ⌘Z refuses and the other value stays.
        store.exec("UPDATE kv SET v = 'theirs' WHERE k = 'theme'")
        GitToast.dismiss()
        pane.lastOutcome = nil
        hand.undo()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await settle()
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "theirs" && GitToast.text == "Changed since your save; nothing was undone",
              "AE12: ⌘Z after another app changed the cell writes nothing and says so", GitToast.text ?? "no notice")
        check(pane.page?.rows[safe: theme]?[safe: 1] == .text("theirs", truncated: false) && shown(grid, row: theme, column: 1) == "theirs",
              "AE12: and the page is read again, so the cell shows the value it was refused for", shown(grid, row: theme, column: 1) ?? "no cell")
        // Stop Editing takes the tab's steps away. The save before it is of the value the page was read again
        // for: one of the value from before would be refused, and leave a draft for Stop Editing to ask about.
        let steps = pane.edit.steps.count
        pane.lastOutcome = nil
        if let again = await openInCell(pane, hand, row: theme, column: 1) {
            again.insertText("blue", replacementRange: NSRange(location: 0, length: (again.string as NSString).length))
            again.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            _ = await wait(5) { pane.lastOutcome != nil }
            _ = await settle()
        }
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "blue" && pane.edit.steps.count == steps + 1 && !pane.hasDraft
              && window.undoManager?.undoActionName == "Edit Cell", "AE12: a save leaves an undo step",
              "\(String(describing: pane.lastOutcome)), \(pane.edit.steps.count - steps) new steps, Undo \(window.undoManager?.undoActionName ?? "")")
        pane.stopEditing()
        check(window.attachedSheet == nil && pane.edit.steps.isEmpty && window.undoManager?.undoActionName != "Edit Cell" && !pane.isEditingAllowed
              && pane.summaryText.hasSuffix("read-only"), "AE12: Stop Editing makes it read-only and takes its undo steps away",
              window.attachedSheet.map { _ in sheetText(window) } ?? window.undoManager?.undoActionName ?? "")
        // A question left up would be taken by the checks after these for their own.
        await endStrayQuestions(after: "AE12's Stop Editing")

        // AE13: no agent path writes it.
        let root = canonicalPath(store.folder.deletingLastPathComponent().path)
        let projects = MCPProjects(open: [root], preferred: root)
        let relative = String(store.path.dropFirst(root.count + 1))
        let write = MCPFileTools.prepareWrite(["path": relative, "content": "x"], in: projects, git: nil)
        let propose = MCPFileTools.prepareProposal(["path": relative, "content": "x"], in: projects, git: nil)
        var refusals: [String] = []
        if case let .failure(error) = write { refusals.append(error.text) }
        if case let .failure(error) = propose { refusals.append(error.text) }
        check(refusals.count == 2 && refusals.allSatisfy { $0.contains("binary") }, "AE13: write_file and propose_edit refuse the database as binary", refusals.joined(separator: " | "))
        let offers = MCPServer.tools.filter { $0.description.range(of: "database", options: .caseInsensitive) != nil && $0.description.range(of: "writ|edit", options: .regularExpression) != nil }
        check(offers.isEmpty, "AE13: no MCP tool offers to write a database", offers.map(\.name).joined(separator: ", "))

        await walEditChecks(c, folder: store.folder, hand: hand)
        await previewDraftChecks(c, store: store, hand: hand)
        await readOnlyFileChecks(c, store: store)
        await closeWhileSavingChecks(c, store: store, hand: hand)
        await closingWithAValueChecks(c, store: store, hand: hand)
    }

    /// The sheet over `window`, once it is up, and its text ("" when none came).
    private static func cellSheet(_ window: NSWindow) async -> String {
        await wait(5) { window.attachedSheet != nil } ? sheetText(window) : ""
    }

    /// Answers the sheet over `window`.
    private static func answerSheet(_ window: NSWindow, _ code: NSApplication.ModalResponse) async {
        guard let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: code)
        _ = await wait(2) { window.attachedSheet !== sheet }
    }

    /// Allow Editing… in `pane`, answered Allow: true once editing is allowed. Only its own question is answered:
    /// a sheet the checks before left up fails them and is ended first, never taken for this one.
    private static func allowEditing(_ pane: DatabasePane, in window: NSWindow, part: String) async -> Bool {
        await endStrayQuestions(after: "the checks before \(part)")
        pane.editingButton.performClick(nil)
        let asked = await cellSheet(window)
        guard asked.contains("Allow editing “\(pane.name)”?") else {
            check(false, "\(part): Allow Editing… asks about “\(pane.name)”", asked)
            await endSheets(over: window, with: .alertSecondButtonReturn)
            return false
        }
        await answerSheet(window, .alertFirstButtonReturn)
        return await wait(2) { pane.isEditingAllowed }
    }

    /// ↩ on (row, column), and the field that opens in its cell.
    private static func openInCell(_ pane: DatabasePane, _ hand: CellHand, row: Int, column: Int) async -> NSTextView? {
        hand.click(pane.grid, row: row, column: column)
        hand.window.makeFirstResponder(pane.grid)
        hand.key(36)
        guard await wait(2, { pane.grid.inPlaceField?.currentEditor() != nil }) else { return nil }
        return pane.grid.inPlaceField?.currentEditor() as? NSTextView
    }

    /// What a grid cell shows.
    private static func shown(_ grid: NSTableView, row: Int, column: Int) -> String? {
        grid.scrollRowToVisible(row)
        grid.layoutSubtreeIfNeeded()
        return (grid.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCellView)?.label.stringValue
    }

    /// A value typed in its cell: Esc leaves the cell as the file has it; Edit takes it to the detail pane at
    /// once; another app's writes don't read the page again under it; a reload that comes anyway moves the
    /// typed text and the keyboard to the detail pane, or opens an unchanged value in its cell again.
    private static func inCellUnderWritesChecks(pane: DatabasePane, store: CellStore, hand: CellHand, role: Int, content: Int) async {
        let window = hand.window, grid = pane.grid
        func replace(_ field: NSTextView, _ text: String) { field.insertText(text, replacementRange: NSRange(location: 0, length: (field.string as NSString).length)) }
        guard let escaped = await openInCell(pane, hand, row: 2, column: role) else { return check(false, "in its cell: ↩ edits row 3's role there") }
        replace(escaped, "typed")
        if hand.byHand { hand.key(53) } else { escaped.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        check(await wait(2) { grid.inPlaceField == nil && pane.edit.draft == nil } && shown(grid, row: 2, column: role) == "user",
              "in its cell: Esc closes the field, and the cell shows the file's value, not what was typed", shown(grid, row: 2, column: role) ?? "no cell")

        guard await openInCell(pane, hand, row: 2, column: role) != nil else { return check(false, "in its cell: ↩ edits it again") }
        pane.detail.editButton.performClick(nil)
        check(await wait(2) { pane.detail.textView.isEditable && !pane.edit.inCell && grid.inPlaceField == nil && pane.edit.draft != nil },
              "in its cell: Edit, with nothing typed, opens the value in the detail pane at once", "in its cell \(pane.edit.inCell), editable \(pane.detail.textView.isEditable)")
        pane.revertDraft()

        guard let typing = await openInCell(pane, hand, row: 2, column: role) else { return check(false, "in its cell: ↩ edits it a third time") }
        replace(typing, "tool")
        let before = pane.page?.rows[safe: 49]?[safe: content]
        store.exec("UPDATE messages SET content = 'message 50, edited' WHERE id = 50")
        for _ in 0..<15 {
            pane.refreshIfChanged()
            await pause(0.1)
        }
        check(pane.edit.inCell && grid.inPlaceField?.currentEditor() === typing && typing.string == "tool" && window.firstResponder === typing
              && pane.page?.rows[safe: 49]?[safe: content] == before,
              "in its cell: another app's write doesn't read the page again under a value being typed; the field keeps it and the keyboard",
              "in its cell \(pane.edit.inCell), responder \(String(describing: window.firstResponder))")
        // A reload that comes anyway (an undo, another page) makes the grid's cells again.
        pane.reloadPage()
        check(await wait(5) { pane.isSettled && !pane.edit.inCell && pane.detail.textView.isEditable && pane.detail.textView.string == "tool"
                              && window.firstResponder === pane.detail.textView },
              "in its cell: a reload under a changed value moves it, and the keyboard, to the detail pane",
              "in its cell \(pane.edit.inCell), text \(pane.detail.textView.string.prefix(20)), responder \(String(describing: window.firstResponder))")
        check(pane.detail.editLabel.stringValue == DatabasePane.movedNote && pane.page?.rows[safe: 49]?[safe: content] == .text("message 50, edited", truncated: false),
              "in its cell: it says why, and the page shows the other app's write", pane.detail.editLabel.stringValue)
        check(shown(grid, row: 2, column: role) == "user", "in its cell: the cell shows the file's value meanwhile", shown(grid, row: 2, column: role) ?? "")
        pane.revertDraft()
        guard await openInCell(pane, hand, row: 2, column: role) != nil else { return check(false, "in its cell: ↩ edits it a fourth time") }
        pane.reloadPage()
        check(await wait(5) { pane.isSettled && pane.edit.inCell && grid.inPlaceField?.currentEditor() != nil },
              "in its cell: an unchanged value open in its cell opens there again after a reload")
        if let field = grid.inPlaceField?.currentEditor() as? NSTextView { field.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        _ = await wait(2) { pane.edit.draft == nil }
    }

    /// A line of the row list, and ⌘A, move the current cell as a click does: a draft is asked about first.
    private static func leavingADraftChecks(pane: DatabasePane, hand: CellHand, role: Int, content: Int) async {
        let window = hand.window, grid = pane.grid
        hand.click(grid, row: 3, column: content)
        _ = await wait(2) { pane.detail.detail?.body == "message 4" }
        pane.beginDetailEdit()
        pane.detail.textView.insertText("changed", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        func pickRole() { if hand.byHand { hand.click(pane.detail.rowList, row: role, column: 1) } else { pane.detail.onSelectColumn?(role) } }
        pickRole()
        let asked = await cellSheet(window)
        check(asked.contains("Save your change to “content”?"), "leaving a draft: a line of the row list asks first", asked)
        await answerSheet(window, .alertSecondButtonReturn)
        check(grid.currentColumn == content && pane.edit.draft?.text == "changed" && pane.detail.textView.string == "changed" && pane.detail.textView.isEditable,
              "leaving a draft: Cancel keeps the cell and its draft in view", "column \(grid.currentColumn)")
        grid.selectAll(nil)
        let all = await cellSheet(window)
        check(all.contains("Save your change to “content”?"), "leaving a draft: ⌘A asks first", all)
        await answerSheet(window, .alertSecondButtonReturn)
        check(grid.selectedRowIndexes == IndexSet(integer: 3) && pane.edit.draft?.text == "changed", "leaving a draft: Cancel keeps the one row")
        pickRole()
        _ = await cellSheet(window)
        await answerSheet(window, .alertThirdButtonReturn)
        check(await wait(2) { grid.currentColumn == role && pane.edit.draft == nil }, "leaving a draft: Don’t Save puts it back and moves to that column")
    }

    /// The other app deletes the last message and writes another as its id: a draft on it says so when the
    /// page is read again, and Save refuses once before it writes to the row now there.
    private static func rowGivenOutAgainChecks(pane: DatabasePane, store: CellStore, hand: CellHand, content: Int) async {
        guard let created = pane.page?.columns.firstIndex(of: "created") else { return check(false, "row given out again: messages' created") }
        hand.click(pane.grid, row: 79, column: content)
        _ = await wait(2) { pane.detail.detail?.body == "message 80" }
        pane.beginDetailEdit()
        pane.detail.textView.insertText("mine", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        store.exec("DELETE FROM messages WHERE id = 80; INSERT INTO messages (id, role, content, created) VALUES (80, 'assistant', 'message 80', 81)")
        check(await wait(6) {
            pane.refreshIfChanged()
            return pane.isSettled && pane.page?.rows[safe: 79]?[safe: created] == .real(81)
        }, "row given out again: the page is read again")
        check(pane.detail.editLabel.stringValue.hasPrefix("Other values in this row changed since it was read") && pane.edit.draft?.text == "mine",
              "row given out again: the draft says its row changed, before any Save", pane.detail.editLabel.stringValue)
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await wait(5) { !pane.edit.isSaving && pane.isSettled }
        var refused = false
        if case .rowChanged? = pane.lastOutcome { refused = true }
        check(refused && store.one("SELECT content FROM messages WHERE id = 80") == "message 80" && pane.edit.draft?.text == "mine",
              "row given out again: Save refuses a key that names another row now, and writes nothing", String(describing: pane.lastOutcome))
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await wait(5) { !pane.edit.isSaving && pane.isSettled }
        check(store.one("SELECT content FROM messages WHERE id = 80") == "mine", "row given out again: a second Save, seeing the row, writes", String(describing: pane.lastOutcome))
    }

    /// The notice's Undo writes the change back once, with no step back left on Edit › Undo.
    private static func noticeUndoChecks(pane: DatabasePane, store: CellStore, hand: CellHand, role: Int) async {
        guard let field = await openInCell(pane, hand, row: 4, column: role) else { return check(false, "notice Undo: ↩ edits row 5's role in its cell") }
        field.insertText("tool", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        GitToast.dismiss()
        pane.lastOutcome = nil
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await wait(5) { !pane.edit.isSaving && pane.isSettled }
        check(store.one("SELECT role FROM messages WHERE id = 5") == "tool" && GitToast.text == "Saved “role” in row 5", "notice Undo: the save's notice", GitToast.text ?? "none")
        let steps = pane.edit.steps.count
        pane.lastOutcome = nil
        GitToast.pressButtonForTest()
        _ = await wait(5) { pane.lastOutcome != nil }
        _ = await wait(5) { !pane.edit.isSaving && pane.isSettled }
        check(store.one("SELECT role FROM messages WHERE id = 5") == "user", "notice Undo: its Undo writes the value back", String(describing: pane.lastOutcome))
        check(pane.edit.steps.count == steps - 1 && !pane.edit.steps.contains { $0.kind == .redo } && hand.window.undoManager?.canRedo != true,
              "notice Undo: no step back is left on Edit › Undo to write it again", "\(pane.edit.steps.map { "\($0.kind)" })")
    }

    /// The page read again after another app's write: the whole value shown is read once again and the pane
    /// keeps it, its selection and scroll; a whole read queued for a cell left before its turn never reads.
    private static func wholeValueReloadChecks(pane: DatabasePane, store: CellStore, hand: CellHand, content: Int) async {
        let grid = pane.grid
        let fetches = pane.fetches
        // The reading queue is busy (a slow count, a large value) while the cut cell is visited and left.
        pane.queue.async { Thread.sleep(forTimeInterval: 0.5) }
        hand.click(grid, row: 11, column: content)
        await pause(0.1)
        hand.click(grid, row: 12, column: content)
        await pause(1)
        check(pane.fetches == fetches && pane.detail.detail?.body == "message 13", "whole values: a read queued for a cell left before its turn never reads",
              "\(pane.fetches - fetches) reads")
        hand.click(grid, row: 11, column: content)
        check(await wait(5) { pane.fetches == fetches + 1 && pane.detail.detail?.body.count == 50_000 }, "whole values: the long message is read whole",
              "\(pane.fetches - fetches) reads")
        let read = pane.fetches
        pane.detail.textView.setSelectedRange(NSRange(location: 20_000, length: 7))
        pane.detail.textView.scrollRangeToVisible(NSRange(location: 20_000, length: 7))
        store.exec("UPDATE messages SET content = 'message 40, edited' WHERE id = 40")
        check(await wait(6) {
            pane.refreshIfChanged()
            return pane.isSettled && pane.page?.rows[safe: 39]?[safe: content] == .text("message 40, edited", truncated: false)
        }, "whole values: the page is read again")
        _ = await wait(3) { pane.fetches > read }
        await pause(0.3)
        check(pane.fetches == read + 1 && pane.detail.detail?.body.count == 50_000 && pane.detail.textView.selectedRange() == NSRange(location: 20_000, length: 7),
              "whole values: read again once, and the pane keeps the value, its selection and its scroll",
              "\(pane.fetches - read) reads, selection \(pane.detail.textView.selectedRange())")
    }

    /// Closing the tab, or Stop Editing, during a save waits for its outcome instead of asking about it.
    private static func closeWhileSavingChecks(_ c: TerminalWindowController, store: CellStore, hand: CellHand) async {
        let window = hand.window, area = c.editorArea
        area.closeAll()
        func open() async -> DatabasePane? {
            area.openDatabase(store.path)
            guard let pane = area.activeDatabase, pane.path == store.path else { return nil }
            _ = await wait(5) { pane.isSettled && pane.page != nil }
            pane.select(table: "messages")
            _ = await wait(5) { pane.isSettled && pane.page?.table == "messages" }
            return await allowEditing(pane, in: window, part: "closing while saving") ? pane : nil
        }
        func draft(_ pane: DatabasePane, row: Int, _ text: String) async {
            guard let content = pane.page?.columns.firstIndex(of: "content") else { return }
            hand.click(pane.grid, row: row, column: content)
            _ = await wait(2) { pane.detail.detail?.body == "message \(row + 1)" }
            pane.beginDetailEdit()
            pane.detail.textView.insertText(text, replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        }
        guard let pane = await open() else { return check(false, "closing while saving: the store opens") }
        await draft(pane, row: 5, "while closing")
        store.open()
        store.exec("BEGIN IMMEDIATE")
        pane.lastOutcome = nil
        pane.save()
        area.close(pane)
        check(window.attachedSheet == nil && area.panes.contains { $0 === pane }, "closing while saving: the tab waits for the save, asking nothing yet")
        _ = await wait(5) { pane.lastOutcome != nil }
        let asked = await cellSheet(window)
        check(pane.lastOutcome == .busy && asked.contains("Save your change to “content” in “agent.db”?") && asked.contains("Nothing has been written to the file."),
              "closing while saving: refused as busy, closing then asks, and says nothing was written", asked)
        await answerSheet(window, .alertSecondButtonReturn)
        store.exec("ROLLBACK")
        store.close()
        check(area.panes.contains { $0 === pane } && pane.hasDraft, "closing while saving: Cancel keeps the tab and its change")
        GitToast.dismiss()
        pane.lastOutcome = nil
        pane.save()
        area.close(pane)
        check(window.attachedSheet == nil, "closing while saving: a save that goes through asks nothing")
        check(await wait(5) { !area.panes.contains { $0 === pane } }, "closing while saving: the tab closes once the value is written")
        check(store.one("SELECT content FROM messages WHERE id = 6") == "while closing" && GitToast.text == "Saved “content” in row 6",
              "closing while saving: the value is in the file, and its notice came up first", GitToast.text ?? "no notice")
        check(window.undoManager?.undoActionName != "Edit Cell", "closing while saving: no step is left on Edit › Undo for the closed tab",
              window.undoManager?.undoActionName ?? "")

        guard let again = await open() else { return check(false, "closing while saving: the store opens again") }
        await draft(again, row: 8, "while stopping")
        again.lastOutcome = nil
        again.save()
        again.stopEditing()
        check(window.attachedSheet == nil, "Stop Editing during a save asks nothing")
        check(await wait(5) { !again.isEditingAllowed && again.lastOutcome != nil }, "Stop Editing during a save stops once it is written")
        check(store.one("SELECT content FROM messages WHERE id = 9") == "while stopping" && again.edit.steps.isEmpty && window.undoManager?.undoActionName != "Edit Cell",
              "Stop Editing during a save: the value is written, and no step is left that could only do nothing", window.undoManager?.undoActionName ?? "")

        // Closing's Save: the value is written and the tab closes, with no step left for it.
        area.closeAll()
        guard let last = await open() else { return check(false, "closing's Save: the store opens again") }
        await draft(last, row: 9, "saved on closing")
        area.close(last)
        let closing = await cellSheet(window)
        check(closing.contains("Save your change to “content” in “agent.db”?"), "closing's Save: closing with an unsaved value asks", closing)
        await answerSheet(window, .alertFirstButtonReturn)
        check(await wait(5) { !area.panes.contains { $0 === last } } && store.one("SELECT content FROM messages WHERE id = 10") == "saved on closing"
              && window.undoManager?.undoActionName != "Edit Cell", "R22: Save writes the value and closes the tab, leaving no step on Edit › Undo",
              window.undoManager?.undoActionName ?? "")
        area.closeAll()
    }

    /// R22: Close Others, Close Tabs to the Right, closing the window and quitting warn about a value not saved yet,
    /// after a text file's own question, with no Save: Cancel (⎋ too) keeps the tab and its value, and Close Anyway
    /// closes it. Nothing is written either way. The quit's questions are answered by a stand-in, never by quitting, and
    /// the window's close is asked of its delegate, which closes nothing itself.
    private static func closingWithAValueChecks(_ c: TerminalWindowController, store: CellStore, hand: CellHand) async {
        let window = hand.window, area = c.editorArea, fm = FileManager.default
        area.closeAll()
        await endStrayQuestions(after: "the checks before R22's closing with a value")
        let keepURL = store.folder.appendingPathComponent("keep.txt"), editedURL = store.folder.appendingPathComponent("edited.txt")
        try? "keep\n".write(to: keepURL, atomically: true, encoding: .utf8)
        try? "one\n".write(to: editedURL, atomically: true, encoding: .utf8)
        defer {
            area.closeAll()
            for url in [keepURL, editedURL] { try? fm.removeItem(at: url) }
        }
        area.open(keepURL)
        area.open(editedURL)
        guard let keep = area.editors.first(where: { $0.document.path == canonicalPath(keepURL.path) }),
              let edited = area.editors.first(where: { $0.document.path == canonicalPath(editedURL.path) }) else {
            return check(false, "R22 closing: the two text files open")
        }
        edited.textView.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        func openWithValue(_ text: String) async -> DatabasePane? {
            area.openDatabase(store.path)
            guard let pane = area.activeDatabase, pane.path == store.path else { return nil }
            _ = await wait(5) { pane.isSettled && pane.page != nil }
            pane.select(table: "messages")
            _ = await wait(5) { pane.isSettled && pane.page?.table == "messages" }
            guard await allowEditing(pane, in: window, part: "R22's closing with a value"), let content = pane.page?.columns.firstIndex(of: "content") else { return nil }
            hand.click(pane.grid, row: 3, column: content)
            _ = await wait(2) { pane.detail.detail?.body == "message 4" }
            pane.beginDetailEdit()
            pane.detail.textView.insertText(text, replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
            return pane.hasDraft ? pane : nil
        }
        guard let pane = await openWithValue("kept, not saved") else { return check(false, "R22 closing: a value typed and not saved") }
        let bytes = fm.contents(atPath: store.path)
        func unwritten() -> Bool { fm.contents(atPath: store.path) == bytes && store.one("SELECT content FROM messages WHERE id = 4") == "message 4" }
        func menu(of tab: NSView) -> NSMenu { area.panes.firstIndex { $0 === tab }.flatMap { c.editorTabMenu(at: $0) } ?? NSMenu() }
        func run(_ title: String, in menu: NSMenu) -> Bool {
            guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        func sheetButtons() -> [NSButton] { window.attachedSheet?.contentView.map { SelfTestRestore.buttons(in: $0) }?.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.title.isEmpty } ?? [] }
        func press(_ title: String) async -> Bool {
            guard await wait(5, { sheetButtons().contains { $0.title == title } }), let button = sheetButtons().first(where: { $0.title == title }) else { return false }
            let sheet = window.attachedSheet
            button.performClick(nil)
            _ = await wait(2) { window.attachedSheet !== sheet }
            return true
        }
        /// The warning's text, and its buttons as "title=key".
        func warning() async -> (text: String, buttons: [String]) {
            let text = await cellSheet(window)
            let keys = sheetButtons().map { "\($0.title)=\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent.isEmpty ? "none" : $0.keyEquivalent)" }
            return (text, keys.sorted())
        }
        let warned = "“agent.db” has a value you haven’t saved."
        let closeButtons = ["Cancel=Return", "Close Anyway=none"]

        // Close Others: the text file's question first, as before; then the warning, which still has to be passed.
        check(run("Close Others", in: menu(of: keep)), "R22: Close Others runs from the text file's tab")
        let first = await cellSheet(window)
        check(first.contains("Save changes to “edited.txt” before closing?") && !first.contains("agent.db"),
              "R22: Close Others asks about the unsaved text file first, as it did", first)
        _ = await press("Don’t Save")
        let others = await warning()
        check(others.text.contains(warned) && others.text.contains("If you close anyway, it is lost and nothing is written.") && others.buttons == closeButtons,
              "R22: then Close Others warns about the database's value: Cancel on Return, or Close Anyway, and no Save",
              "\(others.text) \(others.buttons)")
        // ⎋ is Cancel too.
        if let sheet = window.attachedSheet, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                        windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}",
                                                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(esc)
            _ = await wait(2) { window.attachedSheet !== sheet }
        }
        check(window.attachedSheet == nil && area.panes.contains { $0 === pane } && pane.hasDraft && area.panes.contains { $0 === edited } && edited.document.isDirty
              && unwritten(), "R22: ⎋ on the warning is Cancel: every tab stays, the value and the edits with them, and nothing is written",
              window.attachedSheet.map { _ in sheetText(window) } ?? "\(area.panes.count) tabs, draft \(pane.hasDraft)")
        await endStrayQuestions(after: "R22's Close Others")

        // Quitting: the stand-in answers Don’t Save to the files and Cancel to the warning, so nothing quits or is saved.
        var asked: [(question: QuitQuestion, title: String, info: String, buttons: [String])] = []
        let delegate = AppDelegate.shared!
        let quit = delegate.askBeforeQuitting(update: nil, reason: .user) { (question: QuitQuestion, alert: NSAlert) -> QuitPress in
            asked.append((question, alert.messageText, alert.informativeText, alert.buttons.map { "\($0.title)=\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent.isEmpty ? "none" : $0.keyEquivalent)" }))
            if case .saveChanges = question { return .goOn }
            return .cancel
        }
        let saves = asked.firstIndex { if case .saveChanges = $0.question { return true } else { return false } }
        let values = asked.firstIndex { if case .unsavedValues = $0.question { return true } else { return false } }
        let shown = values.map { asked[$0] }
        check(quit == nil && values != nil && (saves ?? -1) < (values ?? -1) && values == asked.count - 1,
              "R22: the quit's questions ask about the text file, then warn about the database's value, and its Cancel cancels the quit",
              asked.map { "\($0.question): \($0.title)" }.joined(separator: " | "))
        check(shown?.title == warned && shown?.info.contains("If you quit anyway, it is lost and nothing is written.") == true
              && shown?.buttons == ["Cancel=Return", "Quit Anyway=none"],
              "R22: the quit's warning names the file, with Cancel on Return and Quit Anyway, and no Save",
              shown.map { "\($0.title) \($0.info) \($0.buttons)" } ?? "no warning")
        check(!delegate.isTerminating && NSApp.modalWindow == nil && area.panes.contains { $0 === pane } && pane.hasDraft && unwritten(),
              "R22: and the tab keeps its value, written nowhere")

        // The text file goes (Don’t Save); closing the window then warns about the value alone.
        area.close(edited)
        _ = await press("Don’t Save")
        check(await wait(2) { !area.panes.contains { $0 === edited } }, "R22: the edited text file closes with Don’t Save")
        let shouldClose = c.windowShouldClose(window)
        let closing = await warning()
        check(!shouldClose && closing.text.contains(warned) && closing.text.contains("If you close anyway") && closing.buttons == closeButtons,
              "R22: closing the window warns about the database's value: Cancel on Return, or Close Anyway, and no Save", "\(shouldClose) \(closing.text) \(closing.buttons)")
        _ = await press("Cancel")
        check(window.isVisible && window.attachedSheet == nil && area.panes.contains { $0 === pane } && pane.hasDraft && unwritten(),
              "R22: Cancel keeps the window, the tab and its value, and writes nothing")
        // The window's last terminal tab takes the window with it, so closing it asks too.
        if c.tabs.count == 1, let only = c.tabs.first {
            check(c.asksToSave(closing: only), "R22: closing the window's last terminal tab with a value not saved asks first")
        }

        // Close Tabs to the Right, with only the database tab there: the warning alone; Close Anyway closes it unwritten.
        check(run("Close Tabs to the Right", in: menu(of: keep)), "R22: Close Tabs to the Right runs from the text file's tab")
        let right = await warning()
        check(right.text.contains(warned) && !right.text.contains("Save changes") && right.buttons == closeButtons,
              "R22: Close Tabs to the Right warns about the database's value alone", "\(right.text) \(right.buttons)")
        _ = await press("Close Anyway")
        check(await wait(3) { !area.panes.contains { $0 === pane } } && area.panes.contains { $0 === keep } && unwritten(),
              "R22: Close Anyway closes the database tab and writes nothing", "\(area.panes.count) tabs")
        await endStrayQuestions(after: "R22's closing with a value")
    }

    /// AE14: a WAL store with nothing beside it: after a Save and an Undo the folder lists what it did before.
    private static func walEditChecks(_ c: TerminalWindowController, folder: URL, hand: CellHand) async {
        let window = hand.window
        let walFolder = folder.appendingPathComponent("wal")
        let store = CellStore(in: walFolder, name: "wal.db", wal: true)
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: walFolder.path))?.sorted() ?? []
        check(listed == ["wal.db"], "AE14: the WAL store has nothing beside it", listed.joined(separator: ", "))
        c.editorArea.openDatabase(store.path)
        guard let pane = c.editorArea.activeDatabase, pane.path == store.path else { return check(false, "AE14: the WAL store opens") }
        defer { pane.closeEditing(); c.editorArea.close(pane) }
        _ = await wait(5) { pane.isSettled && pane.page != nil }
        pane.select(table: "kv")
        _ = await wait(5) { pane.isSettled && pane.page?.table == "kv" }
        guard await allowEditing(pane, in: window, part: "AE14") else { return check(false, "AE14: editing is allowed on the WAL store") }
        guard let theme = pane.page?.rows.firstIndex(where: { $0.first == .text("theme", truncated: false) }) else { return check(false, "AE14: kv lists theme") }
        hand.click(pane.grid, row: theme, column: 1)
        pane.beginDetailEdit()
        pane.detail.textView.insertText("light", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        pane.lastOutcome = nil
        pane.save()
        _ = await wait(5) { pane.lastOutcome != nil && !pane.edit.isSaving }
        let saved = pane.lastOutcome
        pane.lastOutcome = nil
        window.undoManager?.undo()
        _ = await wait(5) { pane.lastOutcome != nil && !pane.edit.isSaving }
        // Listed before the check reads the file, whose own connection leaves -wal and -shm as Apple's SQLite does.
        let after = (try? FileManager.default.contentsOfDirectory(atPath: walFolder.path))?.sorted() ?? []
        check(saved?.stored == .text("light", truncated: false) && pane.lastOutcome?.stored == .text("dark", truncated: false),
              "AE14: Save and Undo on the WAL store", "save \(String(describing: saved)), undo \(String(describing: pane.lastOutcome))")
        check(after == listed, "AE14: and the folder lists exactly what it did before", after.joined(separator: ", "))
        check(store.one("SELECT v FROM kv WHERE k = 'theme'") == "dark", "AE14: the file holds the value put back")
    }

    /// AE15: a preview tab with an unsaved value is kept when the next file opens as the preview.
    private static func previewDraftChecks(_ c: TerminalWindowController, store: CellStore, hand: CellHand) async {
        let window = hand.window
        let area = c.editorArea
        area.closeAll()
        area.openDatabase(store.path, preview: true)
        guard let pane = area.activeDatabase, area.previewPane === pane else { return check(false, "AE15: the store opens as the preview") }
        _ = await wait(5) { pane.isSettled && pane.page != nil }
        pane.select(table: "kv")
        _ = await wait(5) { pane.isSettled && pane.page?.table == "kv" }
        guard await allowEditing(pane, in: window, part: "AE15's preview") else {
            area.closeAll()
            return check(false, "AE15: editing is allowed in the preview")
        }
        hand.click(pane.grid, row: 0, column: 1)
        pane.beginDetailEdit()
        pane.detail.textView.insertText("unsaved", replacementRange: NSRange(location: 0, length: (pane.detail.textView.string as NSString).length))
        check(pane.hasDraft && area.previewPane !== pane, "AE15: the first edit keeps the preview as an ordinary tab")
        let other = store.folder.appendingPathComponent("notes.txt")
        try? "notes\n".write(to: other, atomically: true, encoding: .utf8)
        area.open(other, preview: true)
        check(area.panes.contains { $0 === pane } && pane.hasDraft, "AE15: the next preview leaves the tab with its unsaved value")
        // Closing it asks; Don't Save closes it and writes nothing.
        let bytes = FileManager.default.contents(atPath: store.path)
        area.close(pane)
        let asked = await wait(3) { window.attachedSheet != nil } ? sheetText(window) : ""
        check(asked.contains("Save your change to “v” in “agent.db”?"), "R22: closing a tab with an unsaved value asks first", asked)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
        check(await wait(2) { !area.panes.contains { $0 === pane } } && FileManager.default.contents(atPath: store.path) == bytes,
              "R22: Don’t Save closes it and writes nothing")
        area.closeAll()
        try? FileManager.default.removeItem(at: other)
    }

    /// AE8: a write-protected copy can't be allowed, and says why.
    private static func readOnlyFileChecks(_ c: TerminalWindowController, store: CellStore) async {
        guard let window = c.window else { return }
        await endStrayQuestions(after: "the checks before AE8's write-protected copy")
        let copy = store.folder.appendingPathComponent("agent-ro.db")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(atPath: store.path, toPath: copy.path)
        chmod(copy.path, 0o444)
        defer {
            chmod(copy.path, 0o644)
            try? FileManager.default.removeItem(at: copy)
        }
        c.editorArea.openDatabase(copy.path)
        guard let pane = c.editorArea.activeDatabase, pane.path == canonicalPath(copy.path) else { return check(false, "AE8: the write-protected copy opens") }
        _ = await wait(5) { pane.isSettled && pane.page != nil }
        pane.editingButton.performClick(nil)
        let said = await wait(3) { window.attachedSheet != nil } ? sheetText(window) : ""
        check(said.contains("“agent-ro.db” can’t be edited") && said.contains("This file can’t be written (it is read-only on disk)."),
              "AE8: Allow Editing… on a write-protected file says why and asks nothing", said)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        _ = await wait(2) { window.attachedSheet == nil }
        check(!pane.isEditingAllowed && pane.summaryText.hasSuffix("read-only"), "AE8: and editing stays off")
        c.editorArea.close(pane)
    }

    /// The data head view's cells (AE1 for CSV and JSON Lines, R10): one line each, the whole value in the same
    /// pane, view-only.
    static func dataCellChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window else { return }
        let fm = FileManager.default
        let csv = proj.appendingPathComponent("cells.csv")
        let jsonl = proj.appendingPathComponent("cells.jsonl")
        defer { for url in [csv, jsonl] { try? fm.removeItem(at: url) } }
        var text = "id,question,answer\n"
        for i in 0..<40 { text += "\(i),\"Row \(i) asks\nover two lines\r\nand a CR\rhere\",\"\(CellStore.controls)\"\n" }
        try? text.write(to: csv, atomically: true, encoding: .utf8)
        var lines = ""
        for i in 0..<40 {
            lines += #"{"id":\#(i),"text":"line one\nline two"# + "\\u2028" + #"three","meta":{"source":"doc-\#(i).md","score":1.50}}"# + "\n"
        }
        try? lines.write(to: jsonl, atomically: true, encoding: .utf8)
        let hand = CellHand(window: window, byHand: NSApp.isActive && window.isKeyWindow)
        let area = c.editorArea
        for url in [csv, jsonl] {
            area.openData(url.path)
            guard let pane = area.activeData, pane.path == canonicalPath(url.path) else { check(false, "data cells: \(url.lastPathComponent) opens in the head view"); continue }
            _ = await wait(10) { pane.isSettled && !pane.records.isEmpty }
            let grid = pane.grid
            var problems: [String] = []
            for row in 0..<min(20, grid.numberOfRows) {
                for column in 1..<grid.numberOfColumns {
                    guard let cell = grid.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCellView else { continue }
                    cell.layoutSubtreeIfNeeded()
                    let shown = cell.label.stringValue
                    if shown.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
                        problems.append("row \(row + 1) column \(column): \(shown.prefix(40))")
                    }
                    if cell.label.frame.height > grid.rowHeight + 0.5 { problems.append("row \(row + 1)'s label is \(cell.label.frame.height) high") }
                }
            }
            check(problems.isEmpty, "AE1: \(url.lastPathComponent)'s cells draw on one line inside their rows", problems.prefix(3).joined(separator: "; "))
            hand.click(grid, row: 0, column: 2)
            check(await wait(3) { pane.isDetailShown && pane.detail.detail != nil }, "R10: a click on \(url.lastPathComponent)'s cell shows its whole value")
            if url == csv {
                check(pane.detail.detail?.body == "Row 0 asks\nover two lines\r\nand a CR\rhere" && pane.detail.detail?.title == "question",
                      "R10: a CSV field shows whole, its line breaks as stored", pane.detail.detail?.body ?? "")
            } else {
                hand.click(grid, row: 0, column: 3)
                _ = await wait(2) { pane.detail.detail?.title == "meta" }
                check(pane.detail.detail?.isJSON == true && pane.detail.detail?.body == "{\n  \"source\": \"doc-0.md\",\n  \"score\": 1.50\n}",
                      "R10: a JSON Lines object shows indented, as written", pane.detail.detail?.body ?? "")
                pane.show(lines: true)
                hand.click(grid, row: 0, column: 1)
                _ = await wait(2) { pane.detail.detail?.isJSON == true && pane.detail.detail?.title.hasPrefix("Line") == true }
                check(pane.detail.detail?.body.hasPrefix("{\n  \"id\": 0,") == true, "R10: in Lines, the whole line, indented",
                      "\(pane.detail.detail.map { "\($0.title): \($0.body.prefix(40))" } ?? "no detail"), current cell \(String(describing: grid.currentCell)), "
                        + "detail shown \(pane.isDetailShown)")
                pane.show(lines: false)
            }
            check(pane.detail.editor == nil && pane.detail.editButton.isHidden && pane.detail.saveButton.isHidden && !pane.detail.textView.isEditable,
                  "AE13: the head view's detail has no edit controls")
            check(pane.detail.items.first?.name != "#", "R10: the row list lists the record's values")
            area.close(pane)
        }
    }
}
#endif
