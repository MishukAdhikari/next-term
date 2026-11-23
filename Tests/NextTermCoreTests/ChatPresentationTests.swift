import Testing
@testable import NextTermCore

/// The chat view's one pass (plan 048): short paths, look-ups grouped, a turn's changes on its closing line, the plan row.
@Suite struct ChatPresentationTests {
    func tool(_ id: String, _ title: String, _ kind: String, _ status: ACPSession.ToolCall.Status = .completed) -> ChatBlock {
        ChatBlock(id: id, content: .tool(ChatTool(callID: id, title: title, kind: kind, status: status, output: "x", expanded: false)))
    }

    func shown(_ blocks: [ChatBlock], expanded: Set<String> = []) -> [ChatBlock] {
        ChatPresentation.shown(blocks, folder: "/proj", home: "/Users/me", expanded: expanded)
    }

    @Test func filePathsAreRelativeToTheFolderButCommandsStayWhole() {
        let out = shown([tool("a", "Read(/proj/Sources/A.swift)", "read", .inProgress),
                         tool("b", "Bash(cd /proj/Sources && ls)", "execute"),
                         tool("c", "Edit(/Users/me/notes/x.md)", "edit")])
        let titles = out.compactMap { if case .tool(let t) = $0.content { return t.title } else { return nil } }
        #expect(titles == ["Read(Sources/A.swift)", "Bash(cd /proj/Sources && ls)", "Edit(~/notes/x.md)"])
    }

    @Test func aSiblingFolderIsNotMadeRelative() {
        let out = shown([tool("a", "Read(/proj2/A.swift)", "read", .inProgress)])
        guard case .tool(let t) = out[0].content else { return #expect(Bool(false)) }
        #expect(t.title == "Read(/proj2/A.swift)")
    }

    @Test func finishedLookUpsInARowAreOneGroupNamingTheFiles() {
        let out = shown([tool("a", "Read(/proj/A.swift)", "read"), tool("b", "Read(/proj/B.swift)", "read"),
                         tool("c", "Grep(foo)", "search"), tool("d", "Edit(/proj/C.swift)", "edit")])
        #expect(out.count == 2)
        guard case .group(let group) = out[0].content else { return #expect(Bool(false)) }
        #expect(out[0].id == "group:a")
        #expect(group.title == "Read 2 files, searched once \u{00B7} A.swift, B.swift")
        #expect(!group.expanded)
    }

    @Test func aFailedOrRunningLookUpSplitsTheGroup() {
        let out = shown([tool("a", "Read(/proj/A.swift)", "read"), tool("b", "Read(/proj/B.swift)", "read", .failed),
                         tool("c", "Read(/proj/C.swift)", "read"), tool("d", "Read(/proj/D.swift)", "read", .inProgress)])
        #expect(out.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func aGroupNamesThreeFilesThenCounts() {
        let reads = (1...5).map { tool("r\($0)", "Read(/proj/F\($0).swift)", "read") }
        guard case .group(let group) = shown(reads)[0].content else { return #expect(Bool(false)) }
        #expect(group.title == "Read 5 files \u{00B7} F1.swift, F2.swift, F3.swift, +2")
        let searches = (1...3).map { tool("s\($0)", "Grep(x\($0))", "search") }
        guard case .group(let only) = shown(searches)[0].content else { return #expect(Bool(false)) }
        #expect(only.title == "Searched 3 times")
    }

    @Test func aGroupUnfoldsByItsOwnIdAndKeepsItWhenItGrows() {
        let two = [tool("a", "Read(/proj/A.swift)", "read"), tool("b", "Read(/proj/B.swift)", "read")]
        let three = two + [tool("c", "Read(/proj/C.swift)", "read")]
        let id = shown(two)[0].id
        guard case .group(let grown) = shown(three, expanded: [id])[0].content else { return #expect(Bool(false)) }
        #expect(shown(three)[0].id == id && grown.expanded && grown.members.count == 3)
    }

    @Test func theTurnsClosingLineSaysWhatItChanged() {
        let blocks: [ChatBlock] = [
            ChatBlock(id: "p", content: .prompt(text: "go")),
            ChatBlock(id: "c1", content: .change(ChatChange(toolID: "e", path: "/proj/A.swift", added: 30, removed: 4, created: false))),
            ChatBlock(id: "c2", content: .change(ChatChange(toolID: "f", path: "/proj/A.swift", added: 1, removed: 0, created: false))),
            ChatBlock(id: "c3", content: .change(ChatChange(toolID: "g", path: "/proj/B.swift", added: 0, removed: 0, created: true))),
            ChatBlock(id: "t", content: .turnEnded(words: "Done in 48 s", usage: nil, reason: .endTurn)),
            ChatBlock(id: "p2", content: .prompt(text: "thanks")),
            ChatBlock(id: "t2", content: .turnEnded(words: "Done in 2 s", usage: nil, reason: .endTurn)),
        ]
        let words = shown(blocks).compactMap { if case .turnEnded(let w, _, _) = $0.content { return w } else { return nil } }
        #expect(words == ["Done in 48 s \u{00B7} 2 files changed +31 \u{2212}4", "Done in 2 s"])
    }

    @Test func thePlanRowShowsWhileStepsAreLeft() {
        let plan = ChatBlock(id: "plan", content: .plan([
            ACPSession.PlanEntry(content: "Read the code", status: .completed),
            ACPSession.PlanEntry(content: "Add the parser", status: .inProgress),
            ACPSession.PlanEntry(content: "Run the tests", status: .pending),
        ]))
        let prompt = ChatBlock(id: "p", content: .prompt(text: "go"))
        #expect(ChatPresentation.planLine([prompt, plan]) == "Plan \u{00B7} 1 of 3 done \u{00B7} Add the parser")
        let done = ChatBlock(id: "plan", content: .plan([ACPSession.PlanEntry(content: "a", status: .completed)]))
        #expect(ChatPresentation.planLine([prompt, done]) == nil)
        #expect(ChatPresentation.planLine([plan, ChatBlock(id: "p2", content: .prompt(text: "next"))]) == nil)
    }
}
