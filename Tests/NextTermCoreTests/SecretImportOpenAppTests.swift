import Foundation
import Testing
@testable import NextTermCore

/// Whether the Claude app is open is asked again when the move plans and when it writes, not kept from the scan: an app
/// opened since would later save its whole file over the change, putting the key back (review finding #17). No value
/// here is a real key.
@Suite struct SecretImportOpenAppTests {
    static let appFile = "Library/Application Support/Claude/claude_desktop_config.json"
    static let appOpen: (String) -> Bool = { $0 == MCPRegistrar.claudeAppBundle }

    /// The app's GITHUB_TOKEN and Cursor's GH_TOKEN, scanned with the app closed, one move each.
    func scanned(_ home: F.Home) -> [SecretImport.Move] {
        home.write(Self.appFile, F.claudeAppJSON)
        home.write(".cursor/mcp.json", F.cursorJSON)
        let found = SecretImport.scan(F.sources(home), isOpen: { _ in false })
        let app = found.findings.filter { $0.source.client == .claudeApp && $0.variable == "GITHUB_TOKEN" }
        let cursor = found.findings.filter { $0.source.client == .cursor && $0.variable == "GH_TOKEN" }
        return [SecretImport.Move(name: "APP_TOKEN", findings: app), SecretImport.Move(name: "GH_TOKEN", findings: cursor)]
    }

    @Test func anAppOpenedSinceTheScanLeavesItsFileAtThePlan() {
        let home = F.Home()
        defer { home.remove() }
        let moves = scanned(home)
        #expect(moves.allSatisfy { $0.findings.count == 1 && $0.findings[0].movable })
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm, isOpen: Self.appOpen)
        let left = SecretImport.PlanFailure(path: home.file(Self.appFile), reason: SecretImport.claudeAppOpenReason)
        #expect(planned.failures == [left])
        #expect(planned.edits.map(\.path) == [home.file(".cursor/mcp.json")])
        // Its key is not stored: nothing names it.
        #expect(!planned.edits.flatMap(\.names).contains("APP_TOKEN"))
        let closed = SecretImport.plan(moves, nxtrm: F.nxtrm, isOpen: { _ in false })
        #expect(closed.failures.isEmpty && closed.edits.count == 2)
    }

    @Test func anAppOpenedSinceThePlanLeavesItsFileAtTheWrite() {
        let home = F.Home()
        defer { home.remove() }
        let planned = SecretImport.plan(scanned(home), nxtrm: F.nxtrm, isOpen: { _ in false })
        guard let edit = planned.edits.first(where: { $0.source.client == .claudeApp }) else {
            Issue.record("no edit for the Claude app's file")
            return
        }
        #expect(SecretImport.apply(edit, lockWait: 0.3, isOpen: Self.appOpen) == .skipped(SecretImport.claudeAppOpenReason))
        #expect(home.read(Self.appFile) == F.claudeAppJSON)
        #expect(SecretImport.apply(edit, lockWait: 0.3, isOpen: { _ in false }) == .written)
        #expect(!home.read(Self.appFile).contains(F.github))
    }
}
