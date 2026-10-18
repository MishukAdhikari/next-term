import Foundation
import Testing
@testable import NextTermCore

/// A value with a reference inside it, not only at its start (`${X}`, `{env:X}`, `{file:x}`): the agent fills it in
/// when it starts the server, so moved, the server would get it unfilled. Such a value is judged by what is left without
/// its references: not listed when that is no key, listed and left with the reason when it is (review finding #20).
/// No value here is a real key.
@Suite struct SecretImportReferenceTests {
    static let url = "postgresql://app:${DB_PASSWORD}@localhost:5432/app"
    static let shaped = "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh"

    @Test func referencesInsideAValueAreTakenOut() {
        #expect(SecretImport.withoutReferences(Self.url) == "postgresql://app:@localhost:5432/app")
        #expect(SecretImport.withoutReferences("x{env:A}y{file:./b}z") == "xyz")
        #expect(SecretImport.withoutReferences("${input:k}tail-${user_config.key}") == "tail-")
        #expect(SecretImport.withoutReferences("Bearer ${GITHUB_TOKEN}") == "Bearer ")
        // No reference: a bare `$X` inside a value is too common in passwords, and an opening never closed is text.
        for value in ["plain-value", "pa$sword-with-$IGN", "unclosed ${ never", "{env: open", "${}", "{notenv:X}"] {
            #expect(SecretImport.withoutReferences(value) == nil, "\(value)")
        }
    }

    @Test func aValueWhoseKeyIsElsewhereIsNotListed() {
        #expect(SecretImport.detect(name: "DATABASE_URL", value: Self.url) == nil)
        #expect(SecretImport.detect(name: "GITHUB_AUTH", value: "Bearer ${GITHUB_TOKEN}") == nil)
        #expect(SecretImport.detect(name: "API_KEY", value: "prefix-{env:API_KEY}") == nil)
    }

    @Test func aKeyBesideAReferenceIsListedAndLeftWithTheReason() {
        let mixed = Self.shaped + "/${SUFFIX}"
        #expect(SecretImport.detect(name: "WHATEVER", value: mixed) == "a key, by its shape")
        #expect(SecretImport.detect(name: "DB_PASSWORD", value: "correct-horse-battery-{env:PEPPER}") == "a key, by its name")
        #expect(SecretImport.detect(name: "WHATEVER", value: "${PREFIX}" + Self.shaped) == "a key, by its shape")
        #expect(SecretImport.detect(name: "API_KEY", value: "${A}$B") == nil)
        #expect(SecretImport.valueRefusal(variable: "WHATEVER", value: mixed) == SecretImport.referenceReason)
        #expect(SecretImport.valueRefusal(variable: "WHATEVER", value: Self.shaped) == nil)
    }

    @Test func theScanLeavesThemInClaudeCodeAndCodex() {
        let home = F.Home()
        defer { home.remove() }
        let env = #"{"DATABASE_URL": "\#(Self.url)", "API_KEY": "\#(Self.shaped)${SUFFIX}", "OTHER_KEY": "\#(Self.shaped)"}"#
        home.write(".claude.json", #"{"mcpServers": {"db": {"command": "db-server", "env": \#(env)}}}"#)
        home.write(".codex/config.toml", """
            [mcp_servers.db]
            command = "db-server"
            env = { DATABASE_URL = "\(Self.url)", API_KEY = "\(Self.shaped){env:SUFFIX}" }

            """)
        let found = SecretImport.scan(F.sources(home))
        let claude = found.findings.filter { $0.source.client == .claudeCode }
        let codex = found.findings.filter { $0.source.client == .codex }
        #expect(!found.findings.contains { $0.variable == "DATABASE_URL" })
        for findings in [claude, codex] {
            let key = findings.first { $0.variable == "API_KEY" }
            #expect(key?.notMovable == SecretImport.referenceReason)
        }
        #expect(claude.first { $0.variable == "OTHER_KEY" }?.movable == true)
    }

    /// The reason holds in every client: Claude Code fills in `${X}` and opencode `{env:X}`, but Codex fills in none, so
    /// it says some agents fill a reference in, not that this one would have.
    @Test func theReasonHoldsInAClientThatFillsInNoReference() {
        let reason = SecretImport.referenceReason
        #expect(reason.contains("some agents fill in"))
        #expect(reason.contains("Secrets would keep it as written"))
        #expect(!reason.contains("not filled in"))
    }

    /// Many openings and no close: read once, not once per opening.
    @Test func aCraftedValueIsReadOnce() {
        let value = "a" + String(repeating: "${", count: 200_000) + "{env:" + String(repeating: "x", count: 100_000)
        let started = Date()
        #expect(SecretImport.withoutReferences(value) == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
