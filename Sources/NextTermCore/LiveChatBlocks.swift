import Foundation

extension LiveChat {
    /// The live chat's items as the chat renderer's blocks (plan 041 U3):
    /// - prompts as prompts and the agent's words as Markdown;
    /// - reasoning folded;
    /// - each tool call as a row with its result's output and its status, then the file it changed, then its plan;
    /// - compactions and errors as notes, and a turn's end as a closing line.
    ///
    /// A result is drawn in its call's row, never alone. A call with no result is running until a later turn end says
    /// the turn is over. `expanded`: the ids of the rows and reasoning the user opened.
    public static func blocks(_ items: [Item], expanded: Set<String> = []) -> [ChatBlock] {
        var results: [String: (output: String, isError: Bool)] = [:]
        var lastTurnEnd = -1
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .result(let id?, let output, let isError): results[id] = (output, isError)
            case .turnEnd: lastTurnEnd = index
            default: break
            }
        }
        var blocks: [ChatBlock] = []
        var waiting: [(id: String, text: String, shown: Bool)] = []
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .user(let text):
                blocks.append(ChatBlock(id: item.id, content: .prompt(text: text)))
            case .text(let text):
                blocks.append(ChatBlock(id: item.id, content: .message(markdown: text, streaming: false)))
            case .thinking(let text):
                let thought = ChatThought(text: text, folded: !expanded.contains(item.id), seconds: nil, thinking: false)
                blocks.append(ChatBlock(id: item.id, content: .thought(thought)))
            case .tool(let call):
                let callID = call.id ?? item.id
                let result = call.id.flatMap { results[$0] }
                let status: ACPSession.ToolCall.Status
                if let result {
                    status = result.isError ? .failed : .completed
                } else {
                    status = index < lastTurnEnd ? .completed : .inProgress
                }
                let tool = ChatTool(callID: callID, title: title(call), kind: toolKind(call.name), status: status,
                                    output: result?.output ?? "", expanded: expanded.contains(item.id))
                blocks.append(ChatBlock(id: item.id, content: .tool(tool)))
                if let diff = call.diff, !diff.lines.isEmpty {
                    let created = diff.removed == 0 && ["write", "write_file", "create_file"].contains(call.name.lowercased())
                    let change = ChatChange(toolID: callID, path: diff.path, added: diff.added, removed: diff.removed, created: created)
                    blocks.append(ChatBlock(id: item.id + "#change", content: .change(change)))
                }
                if let plan = call.plan, !plan.isEmpty {
                    let entries: [ACPSession.PlanEntry] = plan.map { step in
                        let status: ACPSession.PlanEntry.Status
                        switch step.status {
                        case .pending: status = .pending
                        case .active: status = .inProgress
                        case .done: status = .completed
                        }
                        return ACPSession.PlanEntry(content: step.text, status: status)
                    }
                    blocks.append(ChatBlock(id: item.id + "#plan", content: .plan(entries)))
                }
            case .result:
                break
            case .compacted:
                blocks.append(ChatBlock(id: item.id, content: .note(text: "The agent compacted its context here.", tone: .info)))
            case .turnEnd(let durationMs):
                blocks.append(ChatBlock(id: item.id, content: .turnEnded(words: turnWords(durationMs), usage: nil, reason: .endTurn)))
            case .error(let text):
                blocks.append(ChatBlock(id: item.id, content: .note(text: text, tone: .error)))
            case .queued(let text, let shown):
                waiting.append((item.id, text, shown))
            case .unqueued(let text):
                // By its text when given, else the oldest: the queue goes first in, first out.
                if let at = text.map({ text in waiting.firstIndex { $0.text == text } }) ?? (waiting.isEmpty ? nil : 0) {
                    waiting.remove(at: at)
                }
            case .unqueuedAll:
                waiting.removeAll()
            case .unknown:
                break
            }
        }
        // Messages still waiting in the agent's queue, at the foot: the user's words, then one line saying they wait.
        waiting.removeAll { !$0.shown }
        for (id, text, _) in waiting { blocks.append(ChatBlock(id: "queued:" + id, content: .prompt(text: text))) }
        if !waiting.isEmpty {
            let words = waiting.count == 1 ? "Queued: the agent reads it when it finishes this step."
                : "\(waiting.count) queued: the agent reads them when it finishes this step."
            blocks.append(ChatBlock(id: "queued:note:" + (waiting.last?.id ?? ""), content: .note(text: words, tone: .info)))
        }
        return blocks
    }

    /// A tool row's title as the agents' own screens write it: `Bash(npm test)`, or the name alone.
    static func title(_ call: ToolCall) -> String {
        call.summary.isEmpty ? call.name : call.name + "(" + call.summary + ")"
    }

    /// ACP's tool kind for a tool's name, which picks the row's look.
    static func toolKind(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "run_command", "bashoutput": return "execute"
        case "edit", "multiedit", "write", "notebookedit", "apply_patch", "edit_file", "write_file", "create_file", "str_replace": return "edit"
        case "read", "read_file", "view", "notebookread": return "read"
        case "grep", "glob", "search", "find", "ls", "list_directory", "grep_search", "file_search": return "search"
        case "webfetch", "websearch", "web_fetch", "web_search", "fetch": return "fetch"
        case "todowrite", "update_plan", "think": return "think"
        default: return "other"
        }
    }

    /// The closing line of a turn: "Done in 4 s", or "Done".
    static func turnWords(_ durationMs: Int?) -> String {
        guard let durationMs, durationMs > 0 else { return "Done" }
        let seconds = Int((Double(durationMs) / 1000).rounded())
        if seconds < 60 { return "Done in \(max(seconds, 1)) s" }
        return "Done in \(seconds / 60) min \(seconds % 60) s"
    }
}
