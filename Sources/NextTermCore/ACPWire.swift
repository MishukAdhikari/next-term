import Foundation

/// The Agent Client Protocol's wire (agentclientprotocol.com, version 1): JSON-RPC 2.0, one message to a line of UTF-8
/// on the agent's stdin and stdout. `nxtrm agent` is the client: it starts the agent, asks, and answers the agent's own
/// requests (a permission, mostly). Plan 030.
public enum ACPWire {
    /// The protocol version Next Term speaks. An agent answering another is refused (R30).
    public static let protocolVersion = 1

    /// A JSON value, as ACP's messages hold them.
    public indirect enum Value: Equatable, Sendable, Codable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let text = try? container.decode(String.self) { self = .string(text) }
            else if let items = try? container.decode([Value].self) { self = .array(items) }
            else if let fields = try? container.decode([String: Value].self) { self = .object(fields) }
            else if let number = try? container.decode(Double.self) { self = .number(number) }
            else { self = .bool(try container.decode(Bool.self)) }
        }

        /// From what JSONSerialization gives, which tells a JSON true from a 1.
        public init?(serialized: Any) {
            switch serialized {
            case is NSNull: self = .null
            case let text as String: self = .string(text)
            case let number as NSNumber:
                self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
            case let items as [Any]:
                var values: [Value] = []
                for item in items {
                    guard let value = Value(serialized: item) else { return nil }
                    values.append(value)
                }
                self = .array(values)
            case let fields as [String: Any]:
                var values: [String: Value] = [:]
                for (key, item) in fields {
                    guard let value = Value(serialized: item) else { return nil }
                    values[key] = value
                }
                self = .object(values)
            default: return nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let flag): try container.encode(flag)
            case .number(let number):
                // Ids and counts are whole: written as integers, as agents expect them back.
                if number.rounded() == number, abs(number) < 9e15 { try container.encode(Int64(number)) } else { try container.encode(number) }
            case .string(let text): try container.encode(text)
            case .array(let items): try container.encode(items)
            case .object(let fields): try container.encode(fields)
            }
        }

        public subscript(key: String) -> Value? {
            if case .object(let fields) = self { return fields[key] }
            return nil
        }

        public var string: String? {
            if case .string(let text) = self { return text }
            return nil
        }

        public var int: Int? {
            if case .number(let number) = self, number.rounded() == number, abs(number) < 9e15 { return Int(number) }
            return nil
        }

        public var bool: Bool? {
            if case .bool(let flag) = self { return flag }
            return nil
        }

        public var array: [Value]? {
            if case .array(let items) = self { return items }
            return nil
        }
    }

    /// A message from the agent.
    public enum Incoming: Equatable, Sendable {
        /// The answer to one of the client's requests: its result, or an error's message.
        case response(id: Value, result: Value?, error: String?)
        /// The agent asks the client something (a permission, a file) and waits for the answer.
        case request(id: Value, method: String, params: Value)
        /// The agent tells the client something (`session/update`).
        case notification(method: String, params: Value)
    }

    /// One line from the agent, or nil for what isn't a JSON-RPC message (a line an agent logged to stdout by mistake).
    public static func decode(_ line: some DataProtocol) -> Incoming? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]),
              let value = Value(serialized: parsed), case .object(let fields) = value else { return nil }
        let id = fields["id"]
        if let method = fields["method"]?.string {
            let params = fields["params"] ?? .null
            if let id, id != .null { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { return nil }
        if let error = fields["error"] {
            let message = error["message"]?.string ?? "an error"
            return .response(id: id, result: nil, error: message)
        }
        return .response(id: id, result: fields["result"] ?? .null, error: nil)
    }

    /// A request to the agent, as a line ending in a newline.
    public static func request(id: Int, method: String, params: Value) -> Data {
        line(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    /// A notification to the agent (`session/cancel`).
    public static func notification(method: String, params: Value) -> Data {
        line(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }

    /// The answer to the agent's request `id`.
    public static func result(id: Value, _ result: Value) -> Data {
        line(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    /// An error answering the agent's request `id`: JSON-RPC's "method not found" (-32601) for a method the client
    /// doesn't offer.
    public static func error(id: Value, code: Int, message: String) -> Data {
        line(["jsonrpc": .string("2.0"), "id": id,
              "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    private static func line(_ fields: [String: Value]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSON never holds a raw newline: strings escape theirs, so the line is one line.
        var data = (try? encoder.encode(Value.object(fields))) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// The client's `initialize`: version 1, and no file system or terminal of the client's (the agent uses its own
    /// tools, and asks before acting through `session/request_permission`).
    public static func initializeParams(version: String) -> Value {
        .object([
            "protocolVersion": .number(Double(protocolVersion)),
            "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                "terminal": .bool(false),
            ]),
            "clientInfo": .object(["name": .string("next-term"), "title": .string("Next Term"), "version": .string(version)]),
        ])
    }

    /// An MCP server given to the agent in `session/new`: a program it starts on stdio.
    public struct StdioServer: Equatable, Sendable {
        public let name: String
        public let command: String
        public let arguments: [String]

        public init(name: String, command: String, arguments: [String]) {
            self.name = name
            self.command = command
            self.arguments = arguments
        }
    }

    /// `session/new` in `cwd`, with Next Term's MCP server when agents may control Next Term (R26).
    public static func newSessionParams(cwd: String, servers: [StdioServer]) -> Value {
        .object([
            "cwd": .string(cwd),
            "mcpServers": .array(servers.map { server in
                .object(["name": .string(server.name), "command": .string(server.command),
                         "args": .array(server.arguments.map(Value.string)), "env": .array([])])
            }),
        ])
    }

    /// `session/prompt` with the user's text.
    public static func promptParams(session: String, text: String) -> Value {
        .object(["sessionId": .string(session), "prompt": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    /// The answer to `session/request_permission`: the option picked, or cancelled (the turn was stopped, or the tab
    /// closed).
    public static func permissionOutcome(optionID: String?) -> Value {
        guard let optionID else { return .object(["outcome": .object(["outcome": .string("cancelled")])]) }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
    }
}
