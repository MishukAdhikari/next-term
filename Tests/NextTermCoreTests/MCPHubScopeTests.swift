import Foundation
import Testing
@testable import NextTermCore

/// Which hub servers apply in a folder (the user's list, and the projects' as the skills library finds them), saving a
/// list, and R17: until the user adds a server there is no file and Next Term's MCP answers are as they were.
@Suite struct MCPHubScopeTests {
    let home: String
    let repo: String
    let userFile: String

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made + "/Code/app/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/Code/app/packages/web/src", withIntermediateDirectories: true)
        home = canonicalPath(made)
        repo = home + "/Code/app"
        userFile = MCPHubScope.userPath(home: home)
    }

    func write(_ json: String, to file: String) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try json.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func list(_ servers: [String: String]) -> String {
        "{\"mcpServers\": {" + servers.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "}}"
    }

    func resolved(_ folder: String) -> MCPHubScope.Resolution {
        MCPHubScope.servers(folder: folder, home: home, userFile: userFile)
    }

    func names(_ applied: [MCPHubScope.Applied]) -> [String] { applied.map(\.name) }

    // MARK: no list

    @Test func noFileIsNoServerAndNothingToSay() {
        let found = MCPHubScope.sources(folder: repo, home: home, userFile: userFile)
        #expect(found.user == nil && found.projects.isEmpty)
        #expect(resolved(repo).isEmpty)
        #expect(MCPHubScope.resolve(folder: repo, user: nil, projects: [], home: home).isEmpty)
    }

    @Test func theUsersListIsBesideNextTermsOtherFiles() {
        #expect(MCPHubScope.userPath(home: "/Users/x") == "/Users/x/Library/Application Support/Next Term/mcp.json")
        #expect(MCPHubScope.userPath(home: "/Users/x") == (MCPServer.socketPath(home: "/Users/x") as NSString).deletingLastPathComponent + "/mcp.json")
    }

    // MARK: the user's list

    @Test func aUsersServerAppliesToItsProjects() throws {
        try write(list([
            "everywhere": #"{"command": "a"}"#,
            "app": #"{"command": "b", "nextTerm": {"projects": ["~/Code/app"]}}"#,
            "other": #"{"command": "c", "nextTerm": {"projects": ["~/Code/other"]}}"#,
        ]), to: userFile)
        #expect(names(resolved(repo).servers) == ["app", "everywhere"])
        #expect(names(resolved(repo + "/packages/web/src").servers) == ["app", "everywhere"])
        // A folder whose name starts the same is another folder.
        try FileManager.default.createDirectory(atPath: home + "/Code/app2", withIntermediateDirectories: true)
        #expect(names(resolved(home + "/Code/app2").servers) == ["everywhere"])
        #expect(names(resolved(home).servers) == ["everywhere"])
    }

    /// A project listed through a link, or the link's folder given to an agent, is the same folder.
    @Test func foldersCompareAsTheKernelSpellsThem() throws {
        try FileManager.default.createSymbolicLink(atPath: home + "/app-link", withDestinationPath: repo)
        try write(list(["app": #"{"command": "b", "nextTerm": {"projects": ["~/app-link"]}}"#]), to: userFile)
        #expect(names(resolved(repo).servers) == ["app"])
        #expect(MCPHubScope.contains("/", "/anything", home: home))
        #expect(MCPHubScope.contains("~", home + "/x", home: home))
    }

    // MARK: projects' lists

    @Test func aProjectsListIsFoundAsSkillsAre() throws {
        try write(list(["repo": #"{"command": "a"}"#]), to: repo + "/" + MCPHubScope.projectFile)
        try write(list(["web": #"{"command": "b"}"#]), to: repo + "/packages/web/" + MCPHubScope.projectFile)
        // Above the repository's top, and the home folder's, are never read.
        try write(list(["above": #"{"command": "c"}"#]), to: home + "/Code/" + MCPHubScope.projectFile)
        try write(list(["home": #"{"command": "d"}"#]), to: home + "/" + MCPHubScope.projectFile)
        let found = MCPHubScope.sources(folder: repo + "/packages/web/src", home: home, userFile: userFile)
        #expect(found.projects.map(\.file) == [repo + "/packages/web/.next-term/mcp.json", repo + "/.next-term/mcp.json"])
        #expect(names(resolved(repo + "/packages/web/src").servers) == ["repo", "web"])
        #expect(names(resolved(repo).servers) == ["repo"])
        // Outside every project, the user's list alone.
        #expect(MCPHubScope.sources(folder: nil, home: home, userFile: userFile).projects.isEmpty)
        // Each list has its bytes' digest, for the approval its servers need.
        #expect(found.projects[1].digest == SecretRun.digest(Data(list(["repo": #"{"command": "a"}"#]).utf8)))
    }

    /// A cloned repository's list is read only as a plain file in its own folder.
    @Test func aProjectsListLinkedOutOfItsFolderIsNotRead() throws {
        try write(list(["secret": #"{"command": "a"}"#]), to: home + "/elsewhere.json")
        try FileManager.default.createDirectory(atPath: repo + "/.next-term", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo + "/.next-term/mcp.json", withDestinationPath: home + "/elsewhere.json")
        let found = resolved(repo)
        #expect(found.servers.isEmpty && found.unreadable == [MCPHubScope.Unreadable(file: repo + "/.next-term/mcp.json", problem: .cantRead)])
    }

    // MARK: precedence

    @Test func theUsersOwnForHereComesFirstThenProjectsThenTheUsersForAll() throws {
        try write(list([
            "a": #"{"command": "user-all"}"#,
            "b": #"{"command": "user-here", "nextTerm": {"projects": ["~/Code/app"]}}"#,
            "c": #"{"command": "user-all"}"#,
        ]), to: userFile)
        try write(list(["a": #"{"command": "repo"}"#, "b": #"{"command": "repo"}"#, "d": #"{"command": "repo"}"#]), to: repo + "/" + MCPHubScope.projectFile)
        try write(list(["d": #"{"command": "web"}"#, "a": #"{"command": "web"}"#]), to: repo + "/packages/web/" + MCPHubScope.projectFile)
        let found = resolved(repo + "/packages/web")
        #expect(found.servers.map { "\($0.name)=\($0.server.command)" } == ["a=web", "b=user-here", "c=user-all", "d=web"])
        #expect(found.shadowed.map { "\($0.name)=\($0.server.command)" } == ["a=repo", "b=repo", "d=repo", "a=user-all"])
        #expect(found.servers.first { $0.name == "a" }?.source.place == .project)
    }

    /// The user's own server turned off for this project turns a team's server of that name off, for them.
    @Test func theUsersOffForHereTurnsAProjectsServerOff() throws {
        try write(list(["docs": #"{"command": "mine", "nextTerm": {"enabled": false, "projects": ["~/Code/app"]}}"#]), to: userFile)
        try write(list(["docs": #"{"command": "team"}"#]), to: repo + "/" + MCPHubScope.projectFile)
        let found = resolved(repo)
        #expect(found.servers.isEmpty && names(found.off) == ["docs"] && names(found.shadowed) == ["docs"])
        // Off for all projects, a project's own still applies.
        try write(list(["docs": #"{"command": "mine", "nextTerm": {"enabled": false}}"#]), to: userFile)
        #expect(resolved(repo).servers.map(\.server.command) == ["team"])
    }

    /// A broken server takes no name: the next list's applies, and the broken one is named.
    @Test func aBrokenServerShadowsNothing() throws {
        try write(list(["docs": #"{"command": "user"}"#]), to: userFile)
        try write("""
            {"mcpServers": {"docs": {"url": "javascript:alert(1)"}, "twice": {"command": "a"}, "twice": {"command": "b"}, "ok": {"command": "c"}}}
            """, to: repo + "/" + MCPHubScope.projectFile)
        let found = resolved(repo)
        #expect(found.servers.map { "\($0.name)=\($0.server.command)" } == ["docs=user", "ok=c"])
        #expect(found.issues.map(\.name) == ["docs", "twice"])
        #expect(found.issues[1].reasons == ["It is in the file twice."])
    }

    /// An unreadable list adds nothing and is named; the others still apply.
    @Test func anUnreadableListIsNamed() throws {
        try write(list(["mine": #"{"command": "a"}"#]), to: userFile)
        try write("{\"mcpServers\": {\"x\": {\"command\": \"a\"},}}", to: repo + "/" + MCPHubScope.projectFile)
        let found = resolved(repo)
        #expect(names(found.servers) == ["mine"])
        #expect(found.unreadable == [MCPHubScope.Unreadable(file: repo + "/.next-term/mcp.json", problem: .json(.trailingComma))])
    }

    // MARK: saving

    @Test func savingMakesTheFileOnlyForTheFirstServer() throws {
        let folder = (userFile as NSString).deletingLastPathComponent
        #expect(MCPHubScope.save(.remove("github"), to: userFile, place: .user) == .success(.unchanged))
        #expect(!FileManager.default.fileExists(atPath: folder))
        let refused = MCPHubScope.save(.set(.local("GitHub", command: "x")), to: userFile, place: .user)
        guard case .failure(.refused(.invalid)) = refused else { Issue.record("\(refused)"); return }
        #expect(!FileManager.default.fileExists(atPath: folder))

        #expect(MCPHubScope.save(.set(.local("github", command: "npx")), to: userFile, place: .user) == .success(.written))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: userFile)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0)
        #expect(names(resolved(repo).servers) == ["github"])
        #expect(MCPHubScope.save(.set(.local("github", command: "npx")), to: userFile, place: .user) == .success(.unchanged))
        #expect(MCPHubScope.save(.remove("github"), to: userFile, place: .user) == .success(.written))
        #expect(FileManager.default.fileExists(atPath: userFile) && resolved(repo).isEmpty)
    }

    @Test func aProjectsListIsSavedInTheProject() throws {
        let file = repo + "/" + MCPHubScope.projectFile
        #expect(MCPHubScope.save(.set(.remote("docs", url: "https://docs.example.com/mcp")), to: file, place: .project) == .success(.written))
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(!text.contains("projects"))
        #expect(resolved(repo).servers.map(\.source.place) == [.project])
    }

    @Test func savingNeverOverwritesABrokenFile() throws {
        try write("{\"mcpServers\": {,}}", to: userFile)
        #expect(MCPHubScope.save(.set(.local("github", command: "npx")), to: userFile, place: .user)
            == .failure(.refused(.unreadable(.json(.notJSON)))))
        #expect(try String(contentsOfFile: userFile, encoding: .utf8) == "{\"mcpServers\": {,}}")
    }

    // MARK: R17: until the first server, the hub adds nothing to Next Term's MCP answers

    /// The bytes of `next-term`'s initialize (outside a tab, and in one), tools/list and prompts/list. The hub's catalog
    /// adds nothing to them until a server exists; Next Term's own add_mcp_server and list_mcp_servers are always in
    /// them (the owner's decision). Change this digest only for a change to Next Term's own tools or instructions.
    /// Last changed for switch_view (plan 036 U6) and new_tab's sentence on the view a bare claude or codex opens in.
    @Test func nextTermsAnswersAreUnchangedWithNoServer() throws {
        func answer(_ method: String, instructions: String = MCPServer.instructions) -> [String: Any] {
            MCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": method, "params": ["protocolVersion": "2025-06-18"]],
                              version: "0.0.0", instructions: instructions) { _, _ in MCPServer.CallResult(text: "") } ?? [:]
        }
        let answers: [[String: Any]] = [
            answer("initialize"),
            answer("initialize", instructions: MCPServer.instructions(inTab: true, offeringTabs: true)),
            answer("initialize", instructions: MCPServer.instructions(inTab: true, offeringTabs: false)),
            answer("tools/list"),
            answer("prompts/list"),
        ]
        let data = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(SecretRun.digest(data) == "15099623ffea4e588708d766e69595d143ec3360a524b3786724cb35ea12b7b6")
        // And no hub file was read into them: with none, there is nothing.
        #expect(resolved(repo).isEmpty && !FileManager.default.fileExists(atPath: userFile))
    }
}
