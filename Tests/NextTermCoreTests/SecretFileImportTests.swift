import Foundation
import Testing
@testable import NextTermCore

/// A file the user picked for an import: read through its links, only a regular file and only up to what its reader
/// takes, never written; the MCP-config import's own files go to that import. And what a copy-in says afterwards.
/// Files are made up, under a temporary home.
@Suite struct SecretFileImportTests {
    typealias F = SecretSourcesFixtures
    typealias I = SecretImportFixtures

    static func report(_ picked: SecretSources.Picked) -> SourceReport? {
        if case .copy(let report) = picked { return report }
        return nil
    }

    @Test func aPickedEnvFileIsReadAndLeftAsItWas() throws {
        let home = I.Home()
        defer { home.remove() }
        let path: String = home.write("rag-api/.env", F.ragAPIEnv)
        let before: Data = home.data("rag-api/.env")
        let report = try #require(Self.report(SecretSources.readPicked(path, home: home.path)))
        #expect(report.rows.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"])
        #expect(report.purpose == "From .env in rag-api" && report.footer == "4 other values aren\u{2019}t keys.")
        #expect(home.data("rag-api/.env") == before)
    }

    @Test func aLinkIsReadAsTheFileItPointsAt() throws {
        let home = I.Home()
        defer { home.remove() }
        let target: String = home.write("rag-api/.env", F.ragAPIEnv)
        let link: String = home.file("keys-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let report = try #require(Self.report(SecretSources.readPicked(link, home: home.path)))
        #expect(report.format == .env && report.rows.count == 3 && report.purpose == "From .env in rag-api")
    }

    @Test func aFolderAMissingFileAndAHugeOneAreRefused() throws {
        let home = I.Home()
        defer { home.remove() }
        let folder: String = home.file("rag-api")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(Self.report(SecretSources.readPicked(folder, home: home.path))?.unreadable == .notAFile)
        let missing: String = home.file("rag-api/none.env")
        #expect(Self.report(SecretSources.readPicked(missing, home: home.path))?.unreadable == .cantOpen)
        let huge: String = home.file("rag-api/huge.json")
        FileManager.default.createFile(atPath: huge, contents: Data(count: SecretSources.maxBytes + 1))
        #expect(Self.report(SecretSources.readPicked(huge, home: home.path))?.unreadable == .tooLarge)
        #expect(SecretSources.Unreadable.notAFile.reasonClass == "not a file")
    }

    @Test func anMCPConfigTheMoveImportRewritesGoesToIt() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/triage-agent"
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(I.github)"}}}}"#
        let path: String = home.write("triage-agent/.mcp.json", text)
        guard case .move(let source, let rest) = SecretSources.readPicked(path, home: home.path, projects: [project]) else {
            Issue.record("a project's .mcp.json goes to the MCP-config import")
            return
        }
        #expect(canonicalPath(source.path) == canonicalPath(path) && rest.rows.isEmpty)
        let zed: String = home.write("zed/settings.json", #"{"context_servers": {}}"#)
        #expect(Self.report(SecretSources.readPicked(zed, home: home.path)) != nil)
    }

    @Test func whatACopyInSays() {
        #expect(SecretCopyIn.auditOutcome(count: 3, format: .env) == "copied 3 keys from a .env file")
        #expect(SecretCopyIn.auditOutcome(count: 1, format: .bitwarden) == "copied 1 key from a Bitwarden export")
        let names = ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"]
        let env: String? = SecretCopyIn.doneLine(names: names, file: ".env", format: .env, agent: nil)
        #expect(env == ".env still holds these keys. Start the project with nxtrm secret run OPENAI_API_KEY "
            + "PINECONE_API_KEY LANGSMITH_API_KEY -- <your command>, then delete them from .env.")
        let one: String? = SecretCopyIn.doneLine(names: ["STRIPE_SECRET_KEY"], file: ".env.local", format: .env,
                                                 agent: nil)
        #expect(one == ".env.local still holds this key. Start the project with nxtrm secret run STRIPE_SECRET_KEY "
            + "-- <your command>, then delete it from .env.local.")
        let zed: String? = SecretCopyIn.doneLine(names: ["ZED_KEY"], file: "settings.json", format: .json, agent: "Zed")
        #expect(zed == "settings.json still holds this key; Next Term can\u{2019}t rewrite it yet.")
        #expect(SecretCopyIn.copiedText(3) == "Copied 3 keys into Secrets.")
        #expect(SecretCopyIn.copiedText(1) == "Copied 1 key into Secrets.")
    }

    @Test func aKeyRenamedInThePreviewIsSetAsTheFileNamesIt() {
        let names = ["OPENAI_API_KEY", "PINECONE_API_KEY"]
        // OPENAI_KEY in the file, renamed in the preview; PATH can't be set by secret run, so it is left as it is.
        let readAs: [String: String] = ["OPENAI_API_KEY": "OPENAI_KEY", "PINECONE_API_KEY": "PINECONE_API_KEY"]
        let line: String? = SecretCopyIn.doneLine(names: names, file: ".env", format: .env, agent: nil, readAs: readAs)
        let run: String = "nxtrm secret run OPENAI_API_KEY=OPENAI_KEY PINECONE_API_KEY -- <your command>"
        #expect(line == ".env still holds these keys. Start the project with \(run), then delete them from .env.")
        let refused: String? = SecretCopyIn.doneLine(names: ["SHELL_KEY"], file: ".env", format: .env, agent: nil,
                                                     readAs: ["SHELL_KEY": "PATH"])
        #expect(refused?.contains("nxtrm secret run SHELL_KEY -- <your command>") == true)
        let parsed = SecretRun.parse(["OPENAI_API_KEY=OPENAI_KEY", "PINECONE_API_KEY", "--", "npm", "start"])
        #expect((try? parsed.get())?.map["OPENAI_API_KEY"] == "OPENAI_KEY")
    }

    @Test func aNoteThatWarnsIsToldFromOneThatInforms() {
        #expect(SecretSources.Note.shipsToBrowsers.warns && SecretSources.Note.replaces.warns)
        let informs: [SecretSources.Note] = [.publishable, .shortLived, .publicName, .loaderReadsDollar,
                                             .websitePassword, .reprompt, .stillInFile, .composeInGit,
                                             .setAgain(line: 9, place: "line 9")]
        #expect(!informs.contains { (note: SecretSources.Note) -> Bool in note.warns })
    }

    @Test func whatAnUndoSays() {
        let plan = SecretCopyIn.UndoPlan(deletes: ["A_KEY", "B_KEY"], changed: ["C_KEY"], replaced: ["D_KEY"], gone: [])
        let text: String = plan.text
        #expect(text.hasPrefix("Deleted A_KEY and B_KEY."))
        #expect(text.contains("C_KEY changed since the import, so it stays."))
        #expect(text.contains("D_KEY stays: it replaced a key you had, whose old value is gone."))
        let none = SecretCopyIn.UndoPlan(deletes: [], changed: [], replaced: [], gone: ["A_KEY"])
        #expect(none.text == "Nothing to delete: A_KEY is gone already.")
    }
}
