import AppKit
import NextTermCore

/// ⌘-click on Python-shaped references.
extension SelfTest {
    static func linkChecks(_ c: TerminalWindowController) async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-links-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = root.appendingPathComponent("src/agent/graph.py")
        let test = root.appendingPathComponent("tests/test_eval.py")
        try? FileManager.default.createDirectory(at: graph.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
            from langgraph.graph import StateGraph

            def call_model(state):
                raise ValueError("no model")

            def other(state):
                return call_model(state)

            builder = StateGraph(dict)
            graph = builder.compile()
            """.write(to: graph, atomically: true, encoding: .utf8)
        try? "def test_answer():\n    x = 1\n    y = 2\n    assert x == y\n".write(to: test, atomically: true, encoding: .utf8)

        let tab = c.addTab(directory: root.path)
        _ = await wait(20) { tab.status.integrated }
        // The files these checks open are closed again at the end.
        let openBefore = Set(c.editorArea.documents.map(\.path))
        defer { c.editorArea.editors.filter { !openBefore.contains($0.document.path) }.forEach { c.editorArea.close($0) } }

        /// The editor's file and 1-based line after a ⌘-click on `link`, clicked on the row holding `marker`.
        func click(_ link: String, onRowWith marker: String?) async -> (file: String, line: Int)? {
            let terminal = tab.view.getTerminal()
            tab.view.lastClickPoint = nil
            // The first row of the logical line (wrapped rows joined) that holds the marker: a long path
            // wraps, and the marker may be split across rows.
            var start: Int?
            var row = 0
            while start == nil, row < terminal.rows {
                var end = row
                var text = terminal.getLine(row: row)?.translateToString(trimRight: false) ?? ""
                while let next = terminal.getLine(row: end + 1), next.isWrapped {
                    text += next.translateToString(trimRight: false)
                    end += 1
                }
                if let marker, text.contains(marker) { start = row }
                row = end + 1
            }
            if let row = start {
                let height = tab.view.frame.height
                tab.view.lastClickPoint = NSPoint(x: 10, y: height - (CGFloat(row) + 0.5) * height / CGFloat(terminal.rows))
            }
            tab.view.requestOpenLink(source: tab.view, link: link, params: [:])
            _ = await wait(3) { c.editorArea.activeEditor != nil }
            guard let editor = c.editorArea.activeEditor else { return nil }
            let document = editor.document
            return ((document.path as NSString).lastPathComponent, document.lines.line(at: editor.textView.selectedRange().location) + 1)
        }

        // A Python traceback naming the same file twice: the clicked frame's line.
        tab.view.feed(text: "\u{1b}[2J\u{1b}[H")
        tab.view.feed(text: "Traceback (most recent call last):\r\n  File \"\(graph.path)\", line 7, in other\r\n    return call_model(state)\r\n  File \"\(graph.path)\", line 4, in call_model\r\n    raise ValueError(\"no model\")\r\nValueError: no model\r\n")
        let inner = await click(graph.path, onRowWith: "line 4, in call_model")
        check(inner?.file == "graph.py" && inner?.line == 4, "⌘-click on a traceback frame opens the file at that frame's line", "\(String(describing: inner))")
        let outer = await click(graph.path, onRowWith: "line 7, in other")
        check(outer?.line == 7, "and on another frame of the same file, at its own line", "\(String(describing: outer))")

        // pytest and ruff: the line after the path; a langgraph.json graph: the name's definition.
        tab.view.feed(text: "tests/test_eval.py:4: in test_answer\r\n")
        let pytest = await click("tests/test_eval.py", onRowWith: "test_eval.py:4:")
        check(pytest?.file == "test_eval.py" && pytest?.line == 4, "pytest's path:line: opens at the line", "\(String(describing: pytest))")
        tab.view.feed(text: "src/agent/graph.py:9:1: F841 local variable is assigned to but never used\r\n")
        let ruff = await click("src/agent/graph.py", onRowWith: "graph.py:9:1:")
        check(ruff?.line == 9, "ruff's path:line:column: opens at the line", "\(String(describing: ruff))")
        tab.view.feed(text: "  \"graphs\": { \"agent\": \"./src/agent/graph.py:graph\" }\r\n")
        let symbol = await click("./src/agent/graph.py:graph", onRowWith: nil)
        check(symbol?.file == "graph.py" && symbol?.line == 10, "a graph reference (graph.py:graph) opens at the name's definition", "\(String(describing: symbol))")

        c.remove(tab)
    }
}
