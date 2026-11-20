import Testing
@testable import NextTermCore

/// A chat's tool rows keep their paths (seen live: `Read(•••.md)` for a README in a folder with a UUID in its path).
@Suite struct ChatPathMaskTests {
    @Test func aPathKeepsItsWordsAndMasksOnlyARandomPart() {
        let path = "Read(/private/tmp/claude-501/-Users-someone-Code-app/4a0b6952-16fc-4d60-a87c-11930bb6b53e/scratchpad/agent-check/README.md)"
        let shown = MCPRedaction.redactSparingPaths(path, mask: .empty)
        #expect(shown.contains("scratchpad/agent-check/README.md"))
        // A UUID folder is a name, not a key: kept, as command lines keep it.
        #expect(shown == path)
        // The plain rule masked the whole run, keeping only the extension.
        #expect(MCPRedaction.redact(path, mask: .empty).text.contains("README") == false)
    }

    @Test func aKeyIsStillMasked() {
        let key = "sk-ant-api03-" + String(repeating: "Zq8vX2mN4pL7", count: 6)
        #expect(!MCPRedaction.redactSparingPaths("export KEY=\(key)", mask: .empty).contains(key))
        #expect(!MCPRedaction.redactSparingPaths("token \(key) here", mask: .empty).contains(key))
    }
}
