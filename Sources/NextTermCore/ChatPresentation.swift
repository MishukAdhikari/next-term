import Foundation

/// Finished look-ups in a row, shown as one row (plan 048 R2): "Read 5 files · A.swift, B.swift, +3". A click unfolds
/// it into its own rows, each still unfolding on its own.
public struct ChatToolGroup: Equatable, Sendable {
    /// The members, in order, with their own block ids.
    public let members: [ChatBlock]
    public let expanded: Bool

    public var tools: [ChatTool] {
        members.compactMap { if case .tool(let tool) = $0.content { return tool } else { return nil } }
    }

    /// The row's words: what was read and searched, then the files read by name, three at most.
    public var title: String {
        let tools = self.tools
        let reads = tools.filter { $0.kind == "read" }
        let searches = tools.count - reads.count
        var parts: [String] = []
        if !reads.isEmpty { parts.append("Read \(reads.count) file" + (reads.count == 1 ? "" : "s")) }
        if searches > 0 {
            let times = searches == 1 ? "once" : searches == 2 ? "twice" : "\(searches) times"
            parts.append((parts.isEmpty ? "Searched " : "searched ") + times)
        }
        var names: [String] = []
        for tool in reads {
            let name = ChatPresentation.fileName(of: tool.shownTitle)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        var line = parts.joined(separator: ", ")
        if !names.isEmpty {
            let shown = names.prefix(3).joined(separator: ", ")
            line += " \u{00B7} " + shown + (names.count > 3 ? ", +\(names.count - 3)" : "")
        }
        return line
    }
}

/// What the chat view shows of a transcript's blocks (plan 048 KD5): one pure pass over the blocks either builder made
/// (`LiveChat.blocks` for a live tab, `ChatTranscript.blocks` for an agent session), so both chats follow one rule.
/// MCP's plain text is built from the builders' blocks, never from this pass: agents read every call whole.
///
/// - R1: a file tool's path is shown relative to the tab's folder (or the home folder as ~).
/// - R2: two or more finished reads and searches in a row are one group row.
/// - R3: a turn's closing line adds the files that turn changed.
public enum ChatPresentation {
    /// The kinds a group gathers.
    static let lookUps: Set<String> = ["read", "search"]

    /// The blocks as the view shows them. `folder`: the tab's folder; `home`: the user's home folder; `expanded`: the
    /// ids the user unfolded (a group's id is `group:` and its first member's id).
    public static func shown(_ blocks: [ChatBlock], folder: String?, home: String?, expanded: Set<String>) -> [ChatBlock] {
        var out: [ChatBlock] = []
        out.reserveCapacity(blocks.count)
        var run: [ChatBlock] = []
        var turnChanges: [ChatChange] = []

        func flush() {
            if run.count >= 2 {
                let id = "group:" + run[0].id
                out.append(ChatBlock(id: id, content: .group(ChatToolGroup(members: run, expanded: expanded.contains(id)))))
            } else {
                out += run
            }
            run = []
        }

        for block in blocks {
            switch block.content {
            case .tool(let tool):
                let shownTool = relative(tool, folder: folder, home: home)
                let shownBlock = ChatBlock(id: block.id, content: .tool(shownTool))
                if lookUps.contains(tool.kind), tool.status == .completed {
                    run.append(shownBlock)
                } else {
                    flush()
                    out.append(shownBlock)
                }
            case .change(let change):
                flush()
                turnChanges.append(change)
                out.append(ChatBlock(id: block.id, content: .change(relative(change, folder: folder, home: home))))
            case .prompt:
                flush()
                turnChanges = []
                out.append(block)
            case .turnEnded(let words, let usage, let reason):
                flush()
                let summary = changesLine(turnChanges)
                turnChanges = []
                out.append(ChatBlock(id: block.id, content: .turnEnded(words: words + (summary.map { " \u{00B7} " + $0 } ?? ""),
                                                                       usage: usage, reason: reason)))
            default:
                flush()
                out.append(block)
            }
        }
        flush()
        return out
    }

    /// "3 files changed +40 −12", "1 file changed +2 −0", or nil when nothing changed.
    public static func changesLine(_ changes: [ChatChange]) -> String? {
        guard !changes.isEmpty else { return nil }
        let files = Set(changes.map(\.path)).count
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }
        return "\(files) file" + (files == 1 ? "" : "s") + " changed +\(added) \u{2212}\(removed)"
    }

    /// The pinned plan row (R4): "Plan · 2 of 7 done · Running the tests", while the latest plan, given after the latest
    /// prompt, has steps left. Nil otherwise.
    public static func planLine(_ blocks: [ChatBlock]) -> String? {
        var entries: [ACPSession.PlanEntry]?
        for block in blocks.reversed() {
            if case .plan(let found) = block.content { entries = found; break }
            if case .prompt = block.content { return nil }
        }
        guard let entries, !entries.isEmpty, entries.contains(where: { $0.status != .completed }) else { return nil }
        let done = entries.filter { $0.status == .completed }.count
        let current = entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending }
        let step = current.map { " \u{00B7} " + $0.content.replacingOccurrences(of: "\n", with: " ") } ?? ""
        return "Plan \u{00B7} \(done) of \(entries.count) done" + step
    }

    /// A tool's title with its paths made short: kept whole for commands, where a path is part of what runs.
    static func relative(_ tool: ChatTool, folder: String?, home: String?) -> ChatTool {
        guard tool.kind != "execute" else { return tool }
        let title = shorten(tool.title, folder: folder, home: home)
        guard title != tool.title else { return tool }
        return ChatTool(callID: tool.callID, title: title, kind: tool.kind, status: tool.status, output: tool.output,
                        expanded: tool.expanded)
    }

    static func relative(_ change: ChatChange, folder: String?, home: String?) -> ChatChange {
        let path = shorten(change.path, folder: folder, home: home)
        guard path != change.path else { return change }
        return ChatChange(toolID: change.toolID, path: path, added: change.added, removed: change.removed, created: change.created)
    }

    /// `text` with the folder's absolute paths made relative to it, and the home folder's written as ~.
    static func shorten(_ text: String, folder: String?, home: String?) -> String {
        var out = text
        if let folder, folder.count > 1 {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            out = out.replacingOccurrences(of: prefix, with: "")
        }
        if let home, home.count > 1 {
            let prefix = home.hasSuffix("/") ? home : home + "/"
            out = out.replacingOccurrences(of: prefix, with: "~/")
        }
        return out
    }

    /// The file a look-up row names: the last path part of what is in its parentheses ("Read(Sources/A.swift)" gives
    /// "A.swift"), or of the whole title.
    static func fileName(of title: String) -> String {
        var inner = title
        if let open = title.firstIndex(of: "("), let close = title.lastIndex(of: ")"), open < close {
            inner = String(title[title.index(after: open)..<close])
        }
        // A read may carry a range after the path ("A.swift:10-40", "A.swift, lines 10–40").
        let path = inner.split(separator: ",").first.map(String.init) ?? inner
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.trimmingCharacters(in: .whitespaces)
    }
}
