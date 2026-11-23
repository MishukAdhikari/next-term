import Foundation
import Testing
@testable import NextTermCore

/// What an agent's transcript line says it wrote: a file, a shell command run in a folder, or a worktree it made.
/// Lines are built here by hand, in the shapes Claude Code, Command Code and Codex write.
@Suite struct AgentWritesTests {
    let project = "/Code/xCloud"

    // MARK: line builders

    /// A Claude Code assistant line holding one tool call.
    func claude(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> [String: Any] {
        var line: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]],
        ]
        if sidechain { line["isSidechain"] = true }
        return line
    }

    /// A Command Code assistant line holding one tool call.
    func commandCode(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "message", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]]]
    }

    func codex(_ payload: [String: Any]) -> [String: Any] {
        ["type": "response_item", "payload": payload]
    }

    func signals(_ line: [String: Any], _ agent: LiveChat.Agent = .claude) -> [WriteSignal] {
        AgentWrites.signals(record: line, agent: agent, cwd: project)
    }

    func file(_ path: String) -> WriteSignal { WriteSignal(path: path, kind: .file) }
    func shell(_ path: String) -> WriteSignal { WriteSignal(path: path, kind: .shell) }
    func created(_ path: String) -> WriteSignal { WriteSignal(path: path, kind: .created) }

    // MARK: Claude Code

    @Test func aShellCommandThatOnlyMentionsAnIssueNumberIsNoSignal() {
        #expect(signals(claude("Bash", ["command": "gh issue view 11650"])).isEmpty)
        #expect(signals(claude("Bash", ["command": "npm test"])).isEmpty)
    }

    @Test func aFileWrittenInASiblingWorktree() {
        let path = "/Users/me/Code/xcloud-wt-11650/tests/x.php"
        #expect(signals(claude("Write", ["file_path": path, "content": "<?php"])) == [file(path)])
    }

    @Test func editAndNotebookEditNameTheirFile() {
        #expect(signals(claude("Edit", ["file_path": "/wt/a.swift", "old_string": "a", "new_string": "b"])) == [file("/wt/a.swift")])
        #expect(signals(claude("MultiEdit", ["file_path": "/wt/b.swift", "edits": []])) == [file("/wt/b.swift")])
        #expect(signals(claude("NotebookEdit", ["notebook_path": "/wt/n.ipynb", "new_source": "x"])) == [file("/wt/n.ipynb")])
    }

    @Test func aToolThatOnlyHasAPathArgumentIsNotAWrite() {
        #expect(signals(claude("mcp__xcdev__app_test", ["path": "/wt/tests"])).isEmpty)
        #expect(signals(claude("Read", ["file_path": "/wt/a.swift"])).isEmpty)
        #expect(signals(claude("Grep", ["path": "/wt", "pattern": "x"])).isEmpty)
    }

    @Test func aRelativeFileResolvesAgainstTheCallsFolder() {
        #expect(signals(claude("Write", ["file_path": "src/a.swift"])) == [file("/Code/xCloud/src/a.swift")])
        // With no folder to resolve against there is nothing to say.
        #expect(AgentWrites.signals(record: claude("Write", ["file_path": "src/a.swift"]), agent: .claude, cwd: nil).isEmpty)
    }

    @Test func aSubagentsLinesAreNotTheAgents() {
        #expect(signals(claude("Write", ["file_path": "/wt/a.swift"], sidechain: true)).isEmpty)
    }

    @Test func aCdBeforeACommandIsAShellSignalForThatFolder() {
        #expect(signals(claude("Bash", ["command": "cd /wt && npm test"])) == [shell("/wt")])
    }

    @Test func aCdIsFollowedByLaterRelativeCds() {
        #expect(signals(claude("Bash", ["command": "cd /wt && cd sub && ls"])) == [shell("/wt"), shell("/wt/sub")])
        #expect(signals(claude("Bash", ["command": "cd \"/my wt\" && ls"])) == [shell("/my wt")])
    }

    @Test func aCdWithNoPlaceToGoIsNothing() {
        #expect(signals(claude("Bash", ["command": "cd - && ls"])).isEmpty)
        #expect(signals(claude("Bash", ["command": "cd $WT && ls"])).isEmpty)
    }

    @Test func gitCLookingIsNotAWriteButChangingIsOne() {
        #expect(signals(claude("Bash", ["command": "git -C /wt diff"])).isEmpty)
        #expect(signals(claude("Bash", ["command": "git -C /wt log --oneline"])).isEmpty)
        #expect(signals(claude("Bash", ["command": "git -C /wt status"])).isEmpty)
        #expect(signals(claude("Bash", ["command": "git -C /wt commit -m x"])) == [shell("/wt")])
        #expect(signals(claude("Bash", ["command": "git -C /wt add -A && git -C /wt commit -m x"])) == [shell("/wt"), shell("/wt")])
    }

    @Test func gitWorktreeAddIsACreatedSignalForTheResolvedFolder() {
        let command = "git worktree add -q -b fix ../app-wt origin/dev && cd ../app-wt"
        let result = AgentWrites.signals(record: claude("Bash", ["command": command]), agent: .claude, cwd: "/Code/app")
        #expect(result.first == created("/Code/app-wt"))
        #expect(result.contains(shell("/Code/app-wt")))
    }

    @Test func gitWorktreeAddWithoutBranchOptions() {
        #expect(signals(claude("Bash", ["command": "git worktree add /Code/xcloud-wt-1 main"])) == [created("/Code/xcloud-wt-1")])
        // -C moves where a relative folder starts.
        #expect(signals(claude("Bash", ["command": "git -C /repo worktree add ../wt"])) == [created("/wt")])
        // Listing worktrees makes none.
        #expect(signals(claude("Bash", ["command": "git worktree list"])).isEmpty)
    }

    @Test func aLongWriteLineIsParsedFromItsBytes() throws {
        let body = String(repeating: "x", count: 70_000)
        let line = claude("Write", ["file_path": "/wt/big.txt", "content": body])
        let data = try JSONSerialization.data(withJSONObject: line)
        #expect(data.count > 70_000)
        #expect(AgentWrites.signals(line: data, agent: .claude, cwd: project) == [file("/wt/big.txt")])
    }

    @Test func aLineThatIsNotJSONIsNothing() {
        #expect(AgentWrites.signals(line: Data("{\"type\":\"assis".utf8), agent: .claude, cwd: project).isEmpty)
    }

    // MARK: Command Code

    @Test func commandCodeWritesAndEditsNameTheirFile() {
        #expect(signals(commandCode("write_file", ["file_path": "/wt/a.ts", "content": "x"]), .commandCode) == [file("/wt/a.ts")])
        #expect(signals(commandCode("edit_file", ["file_path": "/wt/b.ts"]), .commandCode) == [file("/wt/b.ts")])
        #expect(signals(commandCode("read_file", ["file_path": "/wt/b.ts"]), .commandCode).isEmpty)
        #expect(signals(commandCode("grep", ["path": "/wt"]), .commandCode).isEmpty)
    }

    @Test func commandCodeShellCommandsUseTheirFolderAndTheShellRules() {
        #expect(signals(commandCode("shell_command", ["command": "npm test", "cwd": "/wt"]), .commandCode) == [shell("/wt")])
        #expect(signals(commandCode("shell_command", ["command": "cd /wt && git diff"]), .commandCode) == [shell("/wt")])
        #expect(signals(commandCode("shell_command", ["command": "gh issue view 11650"]), .commandCode).isEmpty)
    }

    // MARK: Codex

    @Test func codexFunctionCallsNameTheirWorkdir() {
        let call = codex(["type": "function_call", "name": "exec_command", "call_id": "c1",
                          "arguments": "{\"cmd\":\"npm test\",\"workdir\":\"/wt\"}"])
        #expect(signals(call, .codex) == [shell("/wt")])
        let older = codex(["type": "function_call", "name": "shell", "call_id": "c2",
                           "arguments": "{\"command\":[\"bash\",\"-lc\",\"git -C /other commit -m x\"],\"workdir\":\"/wt\"}"])
        #expect(signals(older, .codex) == [shell("/wt"), shell("/other")])
    }

    @Test func codexCmdWithNoWorkdirUsesTheShellRules() {
        let call = codex(["type": "function_call", "name": "exec_command", "call_id": "c1",
                          "arguments": "{\"cmd\":\"cd /wt && npm test\"}"])
        #expect(signals(call, .codex) == [shell("/wt")])
        let look = codex(["type": "function_call", "name": "exec_command", "call_id": "c1",
                          "arguments": "{\"cmd\":\"gh issue view 11650\"}"])
        #expect(signals(look, .codex).isEmpty)
    }

    @Test func aCodexApplyPatchNamesEveryFileItTouches() {
        let patch = "*** Begin Patch\n*** Add File: /wt/a.php\n+x\n*** Update File: /wt/b.php\n@@\n-a\n+b\n*** Delete File: /wt/c.php\n*** End Patch"
        let call = codex(["type": "custom_tool_call", "name": "apply_patch", "call_id": "c1", "input": patch])
        #expect(signals(call, .codex) == [file("/wt/a.php"), file("/wt/b.php"), file("/wt/c.php")])
    }

    @Test func codexExecCodeModeNamesWorkdirCmdAndPatchFiles() {
        let source = #"""
        const r = await tools.exec_command({cmd:"cd /wt && npm test","workdir":"/other"});
        await tools.apply_patch("*** Begin Patch\n*** Add File: /wt/a.php\n+x\n*** Update File: /wt/b.php\n@@\n-a\n+b\n*** Add File: /wt/c.php\n+y\n*** End Patch");
        """#
        let call = codex(["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": source])
        let result = signals(call, .codex)
        #expect(result.contains(shell("/other")))
        #expect(result.contains(shell("/wt")))
        #expect(result.contains(file("/wt/a.php")))
        #expect(result.contains(file("/wt/b.php")))
        #expect(result.contains(file("/wt/c.php")))
        #expect(result.filter { $0.kind == .file }.count == 3)
    }

    @Test func aRelativePatchPathResolvesAgainstTheWorkdir() {
        let source = #"tools.apply_patch("*** Begin Patch\n*** Add File: src/a.php\n+x\n*** End Patch"); tools.exec_command({cmd:"ls",workdir:"/wt"})"#
        let call = codex(["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": source])
        #expect(signals(call, .codex).contains(file("/wt/src/a.php")))
        let direct = codex(["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                            "input": "*** Begin Patch\n*** Add File: src/b.php\n+x\n*** End Patch"])
        #expect(signals(direct, .codex) == [file("/Code/xCloud/src/b.php")])
    }

    @Test func eachCodeModeExecCommandKeepsItsOwnWorkdir() {
        let source = #"tools.exec_command({cmd:"git commit -m a",workdir:"/one"}); tools.exec_command({cmd:"cd sub && ls",workdir:"/two"})"#
        let call = codex(["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": source])
        let result = signals(call, .codex)
        #expect(result.contains(shell("/one")))
        #expect(result.contains(shell("/two")))
        #expect(result.contains(shell("/two/sub")))
    }

    @Test func codexRecordsThatAreNotToolCallsAreNothing() {
        #expect(signals(codex(["type": "message", "role": "assistant", "content": []]), .codex).isEmpty)
        #expect(signals(["type": "event_msg", "payload": ["type": "task_complete"]], .codex).isEmpty)
    }
}
