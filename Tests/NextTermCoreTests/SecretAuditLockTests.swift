import Foundation
import Testing
@testable import NextTermCore

/// The audit log's rotate and append under one lock (review finding #13): two appends that both find the log full
/// rotate it once, and the older megabyte stays.
@Suite struct SecretAuditLockTests {
    @Test func twoAppendsAtTheRotationRotateOnceAndKeepTheOlderHistory() throws {
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = SecretFolder(applicationSupport: base)
        try folder.ensure()
        // audit.log at 1 MB exactly: the next line rotates it.
        let history = Data(repeating: UInt8(ascii: "x"), count: SecretAudit.maxSize - 1) + Data("\n".utf8)
        try folder.appendAudit(history)
        let second = DispatchGroup()
        folder.beforeRotate = {
            folder.beforeRotate = nil
            // Another append, from another thread, while this one is about to rotate. Unlocked, it would rotate too
            // and this one's rename would then put its one line over the older file; locked, it waits its turn.
            second.enter()
            DispatchQueue.global().async {
                try? folder.appendAudit(Data("second\n".utf8))
                second.leave()
            }
            _ = second.wait(timeout: .now() + 0.5)
        }
        try folder.appendAudit(Data("first\n".utf8))
        second.wait()
        let older = try Data(contentsOf: URL(fileURLWithPath: folder.path(SecretFolder.olderAuditName)))
        let current = try Data(contentsOf: URL(fileURLWithPath: folder.path(SecretFolder.auditName)))
        // Compared as one Bool: a failed Data comparison of a megabyte would diff it for minutes.
        let keptHistory = older == history
        #expect(keptHistory, "audit.log.1 holds \(older.count) bytes")
        #expect(String(decoding: current, as: UTF8.self) == "first\nsecond\n")
    }
}
