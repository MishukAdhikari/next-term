import Foundation
import Testing
@testable import NextTermCore

/// add_task: its schema and annotations, its place in the list (after the import tools, before Secrets'), the arguments
/// it refuses before anyone is asked, its answer, and the gate that holds it in safe mode and while an update waits.
@Suite struct MCPTaskToolsTests {
    func schema() throws -> [String: Any] {
        let tool = try #require(MCPServer.tool(named: "add_task"))
        return try #require((try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any])
    }

    @Test func theSchemaTakesATitleAndGrowsOnlyByOptionalFields() throws {
        let schema = try schema()
        #expect(schema["type"] as? String == "object" && schema["required"] as? [String] == ["title"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == MCPServer.taskArguments && Set(properties.keys) == ["title", "notes", "when", "project", "reason"])
        let title = try #require(properties["title"] as? [String: Any])
        #expect(title["minLength"] as? Int == 1 && title["maxLength"] as? Int == MCPServer.taskTitleLength)
        #expect((properties["notes"] as? [String: Any])?["maxLength"] as? Int == MCPServer.taskNotesLength)
        // The pattern as JSON Schema reads it: these words exactly, or a date.
        let pattern = try #require((properties["when"] as? [String: Any])?["pattern"] as? String)
        #expect(pattern == When.pattern)
        let expression = try NSRegularExpression(pattern: pattern)
        func matches(_ text: String) -> Bool { expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil }
        for good in ["today", "tomorrow", "2026-10-16"] { #expect(matches(good), "\(good)") }
        for bad in ["Tomorrow", "next week", "2026-1-6", "someday", " today"] { #expect(!matches(bad), "\(bad)") }
    }

    @Test func itAsksFirstLoadsOnDemandAndNamesNoOtherProduct() throws {
        let tool = try #require(MCPServer.tool(named: "add_task"))
        #expect(tool.scope == .write && !tool.readOnly && !tool.destructive && !tool.idempotent && !tool.openWorld)
        #expect(tool.timeout >= 60 && !tool.alwaysLoad && MCPServer.isDeferred("add_task") && MCPServer.isTaskTool("add_task"))
        #expect(tool.meta["anthropic/alwaysLoad"] == nil && tool.meta["next-term/scope"] as? String == "write")
        #expect(!MCPServer.isControlTool("add_task") && !MCPServer.isImportTool("add_task"))
        #expect(tool.description.contains("asked on the Mac first") && tool.description.contains("todo/") && tool.description.contains("- [ ]"))
        // Its only names are Next Term's: every capitalised word is one of these.
        let capitalised = Set(tool.description.split { !$0.isLetter }.filter { $0.first?.isUppercase == true }.map(String.init))
        #expect(capitalised == ["Adds", "Markdown", "The", "Mac", "Next", "Term", "Each", "Answers"], "\(capitalised.sorted())")
        // After the import tools, before Secrets' five, which end the list.
        let names = MCPServer.tools.map(\.name)
        #expect(names.firstIndex(of: "add_task") == names.firstIndex(of: "undo_import").map { $0 + 1 })
        let last: [String] = Array(names.suffix(6))
        #expect(last == ["add_task", "list_secrets", "request_secret", "store_secret", "run_with_secrets", "import_secrets"])
        #expect(names.filter { $0 == "add_task" }.count == 1)
        // The instructions name it among the tools that ask, and still fit.
        #expect(MCPServer.instructions.contains("apply_import, undo_import and add_task ask the user on the Mac first"))
        for inTab in [false, true] { #expect(MCPServer.instructions(inTab: inTab, offeringTabs: true).utf16.count <= 2048) }
    }

    @Test func theArgumentsAreCheckedBeforeAnyoneIsAsked() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka")!
        let now = Date(timeIntervalSince1970: 1_792_068_127) // 2026-10-15 18:42 in Dhaka
        func refusal(_ arguments: [String: Any]) -> String? {
            guard case .failure(let error) = MCPServer.taskDraft(arguments, now: now, calendar: calendar) else { return nil }
            return error.text
        }
        #expect(refusal(["title": "x", "when": "someday"])?.contains(When.pattern) == true)
        #expect(refusal(["title": "x", "when": "2026-02-30"])?.contains("Nothing was written") == true)
        #expect(refusal(["title": "x", "when": 3]) != nil && refusal([:]) != nil && refusal(["title": "  "]) != nil && refusal(["title": "- [ ]"]) != nil)
        #expect(refusal(["title": String(repeating: "a", count: 301)]) != nil && refusal(["title": "x", "notes": 4]) != nil)
        #expect(refusal(["title": "x", "notes": String(repeating: "n", count: 20_001)]) != nil)
        #expect(refusal(["title": "x", "destination": "todo_folder"])?.contains("destination") == true)
        #expect(refusal(["title": "x", "reason": ["no"]]) != nil)
        // Tomorrow by default; the project as given, for the app to find.
        let made = try MCPServer.taskDraft(["title": "Finish the login fix:", "notes": "- write test\n\nSee PR 512.", "project": "api"],
                                           now: now, calendar: calendar).get()
        #expect(made.draft.title == "Finish the login fix" && made.draft.steps.map(\.text) == ["write test"] && made.draft.notes == "See PR 512.")
        #expect(made.draft.scheduled == .day(TaskDay("2026-10-16")!) && made.project as? String == "api")
        let today = try MCPServer.taskDraft(["title": "x", "when": "today"], now: now, calendar: calendar).get()
        #expect(today.draft.scheduled == .day(TaskDay("2026-10-15")!) && today.project == nil)
        // A stored key in the title or notes is masked before anything sees it.
        let key = "sk-live-7f3c2a9b4d1e"
        let masked = try MCPServer.taskDraft(["title": "Rotate \(key)", "notes": key], now: now, calendar: calendar) {
            $0.replacingOccurrences(of: key, with: "•••")
        }.get()
        #expect(masked.draft.title == "Rotate •••" && masked.draft.notes == "•••" && masked.draft.masked)
    }

    @Test func theAnswerSaysWhereTheTaskWent() throws {
        var draft = try #require(TaskDraft(title: "Finish the login fix", notes: "- one\n- two"))
        draft.scheduled = .day(TaskDay("2026-10-16")!)
        let answer = MCPServer.taskAnswer(approved: "on this Mac", path: "/p/todo/2026-10-15-finish-the-login-fix.md",
                                          relativePath: "todo/2026-10-15-finish-the-login-fix.md", draft: draft, createdFolder: true)
        #expect(answer["destination"] as? String == "todo_folder" && answer["approved"] as? String == "on this Mac")
        #expect(answer["relative_path"] as? String == "todo/2026-10-15-finish-the-login-fix.md" && answer["steps"] as? Int == 2)
        #expect(answer["scheduled"] as? String == "2026-10-16" && answer["created_folder"] as? Bool == true && answer["title"] as? String == draft.title)
        draft.scheduled = .none
        let shared = MCPServer.taskAnswer(approved: "by grant g1", path: "/Notes/x.md", relativePath: nil, draft: draft, createdFolder: false)
        #expect(shared["relative_path"] == nil && shared["scheduled"] == nil && JSONSerialization.isValidJSONObject(shared))
        #expect(MCPServer.taskNeedsProject.contains("Settings › Tasks") && MCPServer.taskNeedsProject.hasSuffix("Nothing was written."))
    }

    @Test func safeModeAndAWaitingUpdateHoldIt() {
        let safe = MCPRestoreGate.refusal(tool: "add_task", tabID: nil, followUp: false, safeMode: true, waitingFor: nil)
        #expect(safe?.contains("safe mode") == true)
        let waiting = MCPRestoreGate.refusal(tool: "add_task", tabID: nil, followUp: MCPRestoreGate.isFollowUp("add_task", ["title": "x"]),
                                             safeMode: false, waitingFor: ["a"])
        #expect(waiting?.hasPrefix("update_pending") == true)
        #expect(!MCPRestoreGate.isFollowUp("add_task", ["request_id": "r1"]))
        #expect(MCPRestoreGate.refusal(tool: "add_task", tabID: nil, followUp: false, safeMode: false, waitingFor: nil) == nil)
    }
}
