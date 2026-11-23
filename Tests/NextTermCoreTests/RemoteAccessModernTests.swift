import Foundation
import Testing
@testable import NextTermCore

@Suite struct RemoteAccessModernTests {
    typealias Modern = RemoteAccessModern

    func body(_ method: String, version: String? = "2026-07-28", id: Int = 1, name: String? = nil) -> Data {
        var params: [String: Any] = [:]
        if let version { params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version] }
        if let name { params["name"] = name }
        return RemoteAccessCalls.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

    @Test func theEraComesFromMetaOrTheHeader() {
        #expect(Modern.era(body("tools/list"), version: "2026-07-28", method: "tools/list", name: nil) == .modern(method: "tools/list"))
        #expect(Modern.era(body("server/discover", version: nil), version: "2026-07-28", method: nil, name: nil)
                == .modern(method: "server/discover"))
        #expect(Modern.era(body("tools/list", version: nil), version: "2025-06-18", method: nil, name: nil) == .legacy)
        #expect(Modern.era(body("tools/list", version: nil), version: nil, method: nil, name: nil) == .legacy)
        // initialize is always the earlier era: it agrees the version in its body.
        #expect(Modern.era(body("initialize", version: nil), version: "2026-07-28", method: nil, name: nil) == .legacy)
        #expect(Modern.era(Data("not json".utf8), version: "2026-07-28", method: nil, name: nil) == .legacy)
    }

    @Test func anUnknownVersionNamesTheOnesToRetryWith() throws {
        guard case .refused(let data, let reason) = Modern.era(body("tools/list", version: "2099-01-01"), version: nil,
                                                               method: nil, name: nil) else {
            Issue.record("not refused"); return
        }
        let error = try #require(object(data)["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        let details = try #require(error["data"] as? [String: Any])
        #expect(details["supported"] as? [String] == Modern.allVersions && details["requested"] as? String == "2099-01-01")
        #expect(Modern.allVersions.first == "2026-07-28" && Modern.allVersions.contains("2025-11-25"))
        #expect(reason.contains("2099-01-01") && reason.contains("tools/list"))
    }

    @Test func headersThatDisagreeWithTheBodyAreRefused() throws {
        for era in [Modern.era(body("tools/list"), version: "2025-11-25", method: nil, name: nil),
                    Modern.era(body("tools/list"), version: nil, method: "tools/call", name: nil),
                    Modern.era(body("tools/call", name: "list_tabs"), version: nil, method: "tools/call", name: "read_tab")] {
            guard case .refused(let data, _) = era else { Issue.record("not refused: \(era)"); continue }
            #expect((object(data)["error"] as? [String: Any])?["code"] as? Int == -32020)
        }
        let encoded = "=?base64?" + Data("list_tabs".utf8).base64EncodedString() + "?="
        #expect(Modern.era(body("tools/call", name: "list_tabs"), version: nil, method: "tools/call", name: encoded)
                == .modern(method: "tools/call"))
    }

    @Test func discoverListsEveryVersionAndTheCapabilities() throws {
        let answer = object(Modern.discover(id: 7, instructions: "Use list_tabs first.", serverVersion: "1.0.0"))
        #expect(answer["id"] as? Int == 7)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["supportedVersions"] as? [String] == Modern.allVersions)
        #expect(result["resultType"] as? String == "complete" && result["cacheScope"] as? String == "private")
        #expect(result["ttlMs"] as? Int == 0 && result["instructions"] as? String == "Use list_tabs first.")
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil && (capabilities["tools"] as? [String: Any])?["listChanged"] == nil)
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect((meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["version"] as? String == "1.0.0")
    }

    @Test func shapingAddsResultTypeAndCacheHintsAndLeavesErrors() throws {
        let list = RemoteAccessCalls.encode(["jsonrpc": "2.0", "id": 1, "result": ["tools": [Any]()]])
        let listed = try #require(object(Modern.shape(list, method: "tools/list", serverVersion: "1")) ["result"] as? [String: Any])
        #expect(listed["resultType"] as? String == "complete" && listed["ttlMs"] as? Int == 0 && listed["cacheScope"] as? String == "private")
        let call = RemoteAccessCalls.result(id: 2, MCPServer.CallResult(text: "ok"))
        let called = try #require(object(Modern.shape(call, method: "tools/call", serverVersion: "1"))["result"] as? [String: Any])
        #expect(called["resultType"] as? String == "complete" && called["ttlMs"] == nil && called["content"] != nil)
        let error = RemoteAccessCalls.error(id: 3, code: -32602, message: "no")
        #expect(Modern.shape(error, method: "tools/call", serverVersion: "1") == error)
    }
}
