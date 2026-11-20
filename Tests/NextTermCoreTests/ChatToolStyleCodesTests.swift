import Testing
@testable import NextTermCore

@Suite struct ChatToolStyleCodesTests {
    @Test func dropsWholeEscapeSequences() {
        #expect(ChatTool.withoutStyleCodes("\u{1B}[2mDuration\u{1B}[0m 7.35s") == "Duration 7.35s")
        #expect(ChatTool.withoutStyleCodes("\u{1B}[2K\u{1B}[1Gdone") == "done")
    }

    @Test func dropsCodesWhoseEscapeWasLost() {
        let shown = ChatTool.withoutStyleCodes("[90mTests:[39m    [32;1m52 passed[39;22m[90m (493 assertions)[39m")
        #expect(shown == "Tests:    52 passed (493 assertions)")
    }

    @Test func keepsOrdinaryBrackets() {
        for text in ["array[0]", "grep -E '[0-9]+m'", "[x] done", "a [1] b", "plain"] {
            #expect(ChatTool.withoutStyleCodes(text) == text)
        }
    }

    @Test func unfoldedOutputIsShownWithoutCodes() {
        let tool = ChatTool(callID: "c", title: "Bash(npm test)", kind: "execute", status: .completed,
                            output: "[32mok[39m\nnext", expanded: true)
        #expect(tool.shownOutput(all: false).lines == ["ok", "next"])
        #expect(tool.output.contains("[32m"), "MCP still reads the output as the agent wrote it")
    }
}
