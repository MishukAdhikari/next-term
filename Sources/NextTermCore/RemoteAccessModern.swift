import Foundation

/// MCP 2026-07-28 at the remote door (owner, 2026-11-23: "make it done"). That revision drops the `initialize`
/// handshake: every request carries its protocol version, client identity and capabilities in `_meta`, servers answer
/// `server/discover`, every result carries `resultType`, list results carry cache hints, and Streamable HTTP adds the
/// `Mcp-Method` and `Mcp-Name` headers. The door already reads one message per request with no session (KTD10), so
/// it serves both eras: a request whose version is 2026-07-28 is served this way, `initialize` and the earlier
/// versions as before (MCPServer.supportedVersions), and a version it speaks in neither era gets the revision's
/// `UnsupportedProtocolVersionError`, which names the versions to retry with, instead of a bare 400.
///
/// The hand check that asked for it: ChatGPT opened with `server/discover` on 2026-07-28 and fell back to
/// `initialize` only after a 400.
public enum RemoteAccessModern {
    /// The stateless versions the door speaks.
    public static let versions = ["2026-07-28"]
    /// Every version the door speaks, newest first: what `server/discover` and the version error list.
    public static var allVersions: [String] { versions + MCPServer.supportedVersions }

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    public static let headerMismatch = -32020
    public static let unsupportedVersion = -32022

    /// How the door serves one POST.
    public enum Era: Equatable {
        /// As before: `initialize`, the earlier versions, or a body RemoteAccessCalls.read refuses itself.
        case legacy
        /// Served as 2026-07-28: the request's method, for shaping its answer.
        case modern(method: String)
        /// Refused with a JSON-RPC error body and 400: why, for the audit line.
        case refused(body: Data, reason: String)
    }

    /// The era of a request, from its body and its `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers.
    /// The version comes from `_meta` and the header; when both are there they must match, and so must the method
    /// and tool name headers when they are sent (`HeaderMismatch`). A missing `Mcp-Method` is let through: the
    /// door routes on the body alone, so a client that leaves it out reaches nothing it couldn't otherwise.
    public static func era(_ body: Data, version header: String?, method methodHeader: String?, name nameHeader: String?) -> Era {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .legacy }
        let method = message["method"] as? String ?? ""
        if method == "initialize" { return .legacy }
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = (params["_meta"] as? [String: Any])?[versionKey] as? String
        let id = message["id"]
        if let meta, let header, meta != header {
            return .refused(body: error(id: id, code: headerMismatch,
                                        message: "Header mismatch: MCP-Protocol-Version \(clip(header)) does not match _meta \(clip(meta))."),
                            reason: "MCP-Protocol-Version and _meta name different versions.")
        }
        guard let requested = meta ?? header else { return .legacy }
        if MCPServer.supportedVersions.contains(requested) { return .legacy }
        guard versions.contains(requested) else {
            let body = error(id: id, code: unsupportedVersion, message: "Unsupported protocol version",
                             data: ["supported": allVersions, "requested": clip(requested)])
            return .refused(body: body, reason: "An MCP-Protocol-Version the door does not speak: \(clip(requested))"
                                + (method.isEmpty ? "." : ", on \(clip(method)))."))
        }
        if let methodHeader, methodHeader != method {
            return .refused(body: error(id: id, code: headerMismatch,
                                        message: "Header mismatch: Mcp-Method \(clip(methodHeader)) does not match the body's \(clip(method))."),
                            reason: "Mcp-Method does not match the body.")
        }
        if method == "tools/call", let nameHeader, let name = params["name"] as? String, decoded(nameHeader) != name {
            return .refused(body: error(id: id, code: headerMismatch,
                                        message: "Header mismatch: Mcp-Name does not match the body's tool name."),
                            reason: "Mcp-Name does not match the body.")
        }
        return .modern(method: method)
    }

    /// `server/discover`'s result: every version the door speaks, its capabilities and instructions, as of now.
    /// No `listChanged`: in this revision change notifications need `subscriptions/listen`, which the door doesn't
    /// serve, so a client reads `tools/list` again (its `ttlMs` is 0).
    public static func discover(id: Any, instructions: String, serverVersion: String) -> Data {
        var result: [String: Any] = [
            "supportedVersions": allVersions,
            "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
            "ttlMs": 0,
            "cacheScope": "private",
        ]
        if !instructions.isEmpty { result["instructions"] = instructions }
        return shaped(["jsonrpc": "2.0", "id": id, "result": result], method: "server/discover", serverVersion: serverVersion)
    }

    /// An answer the door made as before, shaped for 2026-07-28: `resultType` on every result, the server's
    /// identity in its `_meta`, and the cache hints on a list (private: every list is the grant's own, and 0 ms,
    /// since its options can change at any time). Errors go out as they are.
    public static func shape(_ answer: Data, method: String, serverVersion: String) -> Data {
        guard let message = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any], message["result"] != nil else {
            return answer
        }
        return shaped(message, method: method, serverVersion: serverVersion)
    }

    static func shaped(_ message: [String: Any], method: String, serverVersion: String) -> Data {
        guard var result = message["result"] as? [String: Any] else { return RemoteAccessCalls.encode(message) }
        result["resultType"] = "complete"
        var meta = result["_meta"] as? [String: Any] ?? [:]
        meta[serverInfoKey] = ["name": "next-term", "title": "Next Term", "version": serverVersion]
        result["_meta"] = meta
        if method.hasSuffix("/list") {
            result["ttlMs"] = 0
            result["cacheScope"] = "private"
        }
        var shaped = message
        shaped["result"] = result
        return RemoteAccessCalls.encode(shaped)
    }

    /// `Mcp-Name` as sent: plain, or `=?base64?…?=` for a value that isn't plain ASCII.
    static func decoded(_ header: String) -> String {
        guard header.hasPrefix("=?base64?"), header.hasSuffix("?="), header.count > 11 else { return header }
        let inner = String(header.dropFirst(9).dropLast(2))
        guard let data = Data(base64Encoded: inner), let text = String(data: data, encoding: .utf8) else { return header }
        return text
    }

    static func error(id: Any?, code: Int, message text: String, data: [String: Any]? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": text]
        if let data { error["data"] = data }
        var message: [String: Any] = ["jsonrpc": "2.0", "error": error]
        message["id"] = id ?? NSNull()
        return RemoteAccessCalls.encode(message)
    }

    /// A value from the client, cut short for an error or an audit line.
    static func clip(_ text: String) -> String { String(text.prefix(32)) }
}
