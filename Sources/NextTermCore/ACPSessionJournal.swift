import Foundation

/// An agent session's changes, one JSON line each (plan 047 D2): what `nxtrm agent` does to its `ACPSession`, appended
/// as it happens, so the app can replay the same changes into its own `ACPSession` and draw the session as a native chat
/// that streams. The CLI stays the session's only writer and its agent's only client; the app only reads.
///
/// Replay is the same code the CLI ran (each op calls the same `ACPSession` method), so both hold the same session by
/// construction. Reading is lenient: a line not yet whole waits for the rest, and a line of an op it doesn't know (a
/// newer CLI) is skipped.
public enum ACPSessionJournal {
    /// The journal's format. A line of a later version is still read where its op is known.
    public static let version = 1

    /// One change to a session, as the `ACPSession` method that made it.
    public enum Op: Equatable, Sendable {
        case prompted(String)
        case turnEnded(String?)
        case turnFailed(String)
        case note(String)
        case update(ACPWire.Value)
        case requested(id: ACPWire.Value, params: ACPWire.Value, question: Bool)
        case highlight(Int)
        case chose(Int)
        case cancelled
    }

    /// Writes each op as it is recorded, through `write` (a file handle's, in the CLI). Thread-safe.
    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let write: @Sendable (Data) -> Void

        public init(write: @escaping @Sendable (Data) -> Void) { self.write = write }

        public func record(_ op: Op) {
            let data = ACPSessionJournal.line(op)
            lock.lock()
            defer { lock.unlock() }
            write(data)
        }
    }

    /// The op as one line, newline included.
    public static func line(_ op: Op) -> Data {
        var fields: [String: ACPWire.Value] = ["v": .number(Double(version))]
        switch op {
        case .prompted(let text): fields["op"] = .string("prompted"); fields["text"] = .string(text)
        case .turnEnded(let reason):
            fields["op"] = .string("turn_ended")
            if let reason { fields["reason"] = .string(reason) }
        case .turnFailed(let message): fields["op"] = .string("turn_failed"); fields["text"] = .string(message)
        case .note(let text): fields["op"] = .string("note"); fields["text"] = .string(text)
        case .update(let params): fields["op"] = .string("update"); fields["params"] = params
        case .requested(let id, let params, let question):
            fields["op"] = .string("requested"); fields["id"] = id; fields["params"] = params
            fields["question"] = .bool(question)
        case .highlight(let step): fields["op"] = .string("highlight"); fields["index"] = .number(Double(step))
        case .chose(let index): fields["op"] = .string("chose"); fields["index"] = .number(Double(index))
        case .cancelled: fields["op"] = .string("cancelled")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(ACPWire.Value.object(fields))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The op one whole line holds, or nil for a line that isn't one (an unknown op, or not JSON).
    public static func op(line: some DataProtocol) -> Op? {
        guard let value = try? JSONDecoder().decode(ACPWire.Value.self, from: Data(line)),
              let name = value["op"]?.string else { return nil }
        let text = value["text"]?.string
        let index = value["index"]?.int
        switch name {
        case "prompted": return text.map(Op.prompted)
        case "turn_ended": return .turnEnded(value["reason"]?.string)
        case "turn_failed": return text.map(Op.turnFailed)
        case "note": return text.map(Op.note)
        case "update": return value["params"].map(Op.update)
        case "requested":
            guard let id = value["id"], let params = value["params"] else { return nil }
            return .requested(id: id, params: params, question: value["question"]?.bool ?? false)
        case "highlight": return index.map(Op.highlight)
        case "chose": return index.map(Op.chose)
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Reads a journal as it grows: bytes in, whole lines' ops out. A partial last line is kept for the next feed.
    public struct Reader: Sendable {
        private var rest = Data()
        public init() {}

        public mutating func feed(_ data: Data) -> [Op] {
            rest.append(data)
            var ops: [Op] = []
            while let end = rest.firstIndex(of: 0x0A) {
                let line = rest[rest.startIndex..<end]
                if let op = ACPSessionJournal.op(line: line) { ops.append(op) }
                rest = Data(rest[rest.index(after: end)...])
            }
            return ops
        }
    }

    /// Applies `op` to `session`, as the CLI did.
    public static func apply(_ op: Op, to session: inout ACPSession) {
        switch op {
        case .prompted(let text): session.prompted(text)
        case .turnEnded(let reason): session.turnEnded(reason)
        case .turnFailed(let message): session.turnFailed(message)
        case .note(let text): session.note(text)
        case .update(let params): session.apply(update: params)
        case .requested(let id, let params, let question): session.requested(permission: id, params: params, question: question)
        case .highlight(let step): session.moveHighlight(step)
        case .chose(let index): _ = session.choose(index)
        case .cancelled: _ = session.cancelPending()
        }
    }

    /// A session made from a whole journal.
    public static func session(from data: Data) -> ACPSession {
        var reader = Reader()
        var session = ACPSession()
        for op in reader.feed(data) { apply(op, to: &session) }
        return session
    }
}

extension ACPSessionJournal {
    /// The folder journals are kept in: `agent-chat` beside the app's socket, so a self-test's app and CLI use their own.
    public static func folder(socket: String) -> String {
        ((socket as NSString).deletingLastPathComponent as NSString).appendingPathComponent("agent-chat")
    }

    /// A new journal's path for a session of process `pid`.
    public static func newPath(socket: String, pid: Int32, id: UUID = UUID()) -> String {
        (folder(socket: socket) as NSString).appendingPathComponent("\(pid)-\(id.uuidString.lowercased()).jsonl")
    }

    /// Whether `path`, as a session reported it, is a journal in that folder: nothing else is ever read as one.
    public static func isJournal(_ path: String, socket: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        return (standard as NSString).deletingLastPathComponent == (folder(socket: socket) as NSString).standardizingPath
            && standard.hasSuffix(".jsonl") && !(standard as NSString).lastPathComponent.hasPrefix(".")
    }
}
