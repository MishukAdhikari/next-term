#if DEBUG
import AppKit
import NextTermCore

/// A debug build's offscreen picture of the chat view, for checking its look by eye: `NextTerm --chat-snapshot DIR`
/// writes chat-dark.png, chat-light.png and chat-ended.png from a made-up session, then exits. Nothing runs and no
/// agent starts.
enum ChatSnapshot {
    /// A fixed session standing in for a host.
    final class Fixture: ChatViewSource {
        var session = ACPSession()
        var expanded: Set<String> = []
        var thoughtTimes: [Int: TimeInterval] = [2: 12]
        var draft = ""
        var lastPrompt: String?
        var state: ChatHostState = .asking
        var endState: ChatEndState?
        var resumable = true
        var agentName = "Claude Code"
        var folder = "/tmp/proj"
        var offersTerminal = true
        var onChange: ((Bool) -> Void)?

        var header: ChatHeader {
            ChatHeader.make(agent: agentName, model: "stand-in-model", version: "9.9.9", folder: "~/proj", home: NSHomeDirectory(),
                            usage: session.usage, state: state)
        }

        var inputState: ChatInputState {
            ChatInputState.make(session: session, waitingLine: nil, ended: endState != nil, agentName: agentName)
        }

        func send(_ text: String) -> ChatTabHost.SendOutcome { .refused("") }
        func stop() {}
        func choose(_ index: Int) {}
        func moveHighlight(_ step: Int) {}
        func restart() {}
    }

    static func run(_ arguments: [String]) -> Never {
        let folder = arguments.first ?? FileManager.default.currentDirectoryPath
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let asking = fixture()
            try write(asking, appearance: .darkAqua, to: folder + "/chat-dark.png")
            try write(asking, appearance: .aqua, to: folder + "/chat-light.png")
            let ended = fixture()
            ended.session.turnEnded("end_turn")
            ended.session.note("Claude Code quit.")
            ended.state = .ended
            ended.endState = .ended(.quit(status: 1, words: "Error: session expired"))
            try write(ended, appearance: .darkAqua, to: folder + "/chat-ended.png")
            print(folder)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("chat snapshot: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func update(_ fields: [String: Any]) -> ACPWire.Value {
        ACPWire.Value(serialized: ["update": fields]) ?? .null
    }

    static func fixture() -> Fixture {
        let fixture = Fixture()
        var session = ACPSession()
        session.note("Claude Code 9.9.9 \u{00B7} stand-in-model")
        session.prompted("Add a retry to the fetch helper\nand run the tests.")
        session.apply(update: update(["sessionUpdate": "agent_thought_chunk",
                                      "content": ["type": "text", "text": "The helper lives in src/a.swift; a loop with a back-off fits."]]))
        session.apply(update: update(["sessionUpdate": "plan", "entries": [
            ["content": "Read the fetch helper", "status": "completed"],
            ["content": "Add a retry with back-off", "status": "in_progress"],
            ["content": "Run the tests", "status": "pending"],
        ]]))
        session.apply(update: update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read src/a.swift", "kind": "read",
                                      "status": "completed"]))
        session.apply(update: update(["sessionUpdate": "tool_call", "toolCallId": "t2", "title": "Edit src/a.swift", "kind": "edit",
                                      "status": "completed",
                                      "content": [["type": "diff", "path": "src/a.swift", "oldText": "let a = 1\nfetch()",
                                                   "newText": "let a = 1\nfor _ in 0..<3 {\n    if fetch() { break }"]]]))
        session.apply(update: update(["sessionUpdate": "tool_call", "toolCallId": "t3", "title": "Bash(swift test --filter Fetch)",
                                      "kind": "execute", "status": "completed",
                                      "content": [["type": "content", "content": ["type": "text",
                                                                                  "text": "Building for debugging...\nTest Suite 'FetchTests' passed.\n  Executed 4 tests, with 0 failures"]]]]))
        session.apply(update: update(["sessionUpdate": "tool_call", "toolCallId": "t4", "title": "Bash(npm run lint)", "kind": "execute",
                                      "status": "failed"]))
        let reply = """
        Done. The helper now **retries three times** with a short back-off, and `FetchTests` pass.

        ## What changed

        - `fetch()` runs in a loop of three tries
        - a failed try waits 200 ms, then 400 ms

        ```swift
        for attempt in 0..<3 {
            if fetch() { break }
            Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
        }
        ```

        > The lint step failed before the change too; see [the docs](https://example.com/lint).

        | File | Added | Removed |
        |---|---|---|
        | src/a.swift | 2 | 1 |
        """
        session.apply(update: update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": reply]]))
        session.apply(update: update(["sessionUpdate": "usage_update", "used": 1200, "size": 200_000]))
        session.turnEnded("end_turn")
        session.prompted("Remove the build folder")
        _ = session.requested(permission: .number(7), params: ACPWire.Value(serialized: [
            "toolCall": ["toolCallId": "t5", "title": "Bash(rm -rf build)"],
            "options": [
                ["optionId": "a", "name": "Allow once", "kind": "allow_once"],
                ["optionId": "b", "name": "Allow always", "kind": "allow_always"],
                ["optionId": "c", "name": "Reject", "kind": "reject_once"],
            ],
        ] as [String: Any]) ?? .null)
        fixture.session = session
        fixture.expanded = ["tool:t3"]
        fixture.thoughtTimes = [2: 12]
        return fixture
    }

    private static func write(_ fixture: Fixture, appearance: NSAppearance.Name, to path: String) throws {
        let size = NSRect(x: 0, y: 0, width: 900, height: 1150)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let view = ChatView(source: fixture)
        view.frame = size
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.refresh()
        view.layoutSubtreeIfNeeded()
        view.transcript.scrollView.contentView.scroll(to: .zero)
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
