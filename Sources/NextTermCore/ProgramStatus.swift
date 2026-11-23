import Foundation

/// OSC 7501, program status (revision 0.4, superlogical.com/rex/docs/build/program-status): a program says what it is
/// doing as `key=value` pairs with `:` between them. `state` is idle, working, done, blocked, error, or clear (which
/// removes records). `id` names a record beneath the root (`a/b`). `kind` goes with blocked: permission, question or
/// auth. `progress` runs 0 to 100. `app` names the program. `title` and `msg` are base64 of one line of UTF-8.
///
/// Claude Code (2.1.295 and later), Codex and OpenCode send it once the terminal answers their query (`?`) saying it
/// takes it. An agent that reports is followed by what it says rather than by the hints on its screen, which a custom
/// status line can hide (Claude Code drops its "esc to interrupt" then). Nothing a report says is written back to the
/// program, and its words are shown only as plain text.
public enum ProgramStatus {
    public static let oscCode = 7501

    public enum State: String, Sendable {
        case idle, working, done, blocked, error, clear
    }

    /// What a blocked program waits for.
    public enum Kind: String, Sendable {
        case permission, question, auth
    }

    public struct Report: Equatable, Sendable {
        public var state: State
        /// Nil for the root record.
        public var id: String?
        public var kind: Kind?
        public var progress: Int?
        public var app: String?
        public var title: String?
        public var message: String?

        public init(state: State, id: String? = nil, kind: Kind? = nil, progress: Int? = nil, app: String? = nil,
                    title: String? = nil, message: String? = nil) {
            self.state = state
            self.id = id
            self.kind = kind
            self.progress = progress
            self.app = app
            self.title = title
            self.message = message
        }
    }

    public enum Parsed: Equatable, Sendable {
        /// `?`: the program asks whether the terminal takes the protocol.
        case query
        case report(Report)
    }

    /// The answer to `?`, the only bytes the protocol writes back: every state and kind, which Next Term takes.
    public static let reply = "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"

    /// The longest payload read: the whole sequence is 4,096 bytes at most, and `ESC ] 7501 ;` and `ESC \` take 9.
    public static let maxPayload = 4096 - 9

    /// A report or the query, or nil for what the protocol discards whole: no state or one it doesn't name, a value
    /// past a limit, base64 that doesn't decode, or words with a control character. A malformed pair (no `=`, an
    /// empty or long key, a byte outside the value set) is skipped, an unknown key ignored, and a repeated key's
    /// last value kept.
    public static func parse(_ payload: some Collection<UInt8>) -> Parsed? {
        guard payload.count <= maxPayload else { return nil }
        let bytes = Array(payload)
        if bytes == [UInt8(ascii: "?")] { return .query }
        var pairs: [String: String] = [:]
        for pair in bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = pair[pair.startIndex..<equals], value = pair[pair.index(after: equals)...]
            guard !key.isEmpty, key.count <= 16, key.allSatisfy({ (0x61...0x7A).contains($0) }), value.allSatisfy(isValueByte) else { continue }
            pairs[String(decoding: key, as: UTF8.self)] = String(decoding: value, as: UTF8.self)
        }
        guard let raw = pairs["state"], let state = State(rawValue: raw) else { return nil }
        var report = Report(state: state)
        if let id = pairs["id"] {
            guard isID(id) else { return nil }
            report.id = id
        }
        if state == .blocked, let kind = pairs["kind"] { report.kind = Kind(rawValue: kind) }
        if state == .working || state == .blocked, let text = pairs["progress"], let value = Int(text), (0...100).contains(value) {
            report.progress = value
        }
        if let app = pairs["app"], (1...32).contains(app.utf8.count), app.utf8.allSatisfy(isNameByte) { report.app = app }
        if let title = pairs["title"] {
            guard title.utf8.count <= 256, let words = decoded(title, limit: 192) else { return nil }
            report.title = words
        }
        if let message = pairs["msg"] {
            guard message.utf8.count <= 2732, let words = decoded(message, limit: 2048) else { return nil }
            report.message = words
        }
        return .report(report)
    }

    /// `[A-Za-z0-9_.,+/=-]`, every byte a value may hold.
    static func isValueByte(_ byte: UInt8) -> Bool {
        isNameByte(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "=")
    }

    /// `[A-Za-z0-9_.+-]`, the bytes of an `app` and of an id's segment.
    static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
        }
    }

    /// One to eight segments of 1 to 32 name bytes, `/` between them, 128 bytes at most.
    static func isID(_ id: String) -> Bool {
        guard id.utf8.count <= 128 else { return false }
        let segments = id.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        return (1...8).contains(segments.count) && segments.allSatisfy { (1...32).contains($0.count) && $0.allSatisfy(isNameByte) }
    }

    /// Base64 of UTF-8 (padding optional), at most `limit` bytes decoded, with no control character in it.
    static func decoded(_ text: String, limit: Int) -> String? {
        let padded = text + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= limit, let words = String(data: data, encoding: .utf8) else { return nil }
        let control = words.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
        return control ? nil : words
    }

    /// What a blocked program waits for, in words, when it gives none of its own.
    public static func words(for kind: Kind?) -> String {
        switch kind {
        case .permission: return "Permission needed"
        case .question: return "A question for you"
        case .auth: return "Sign-in needed"
        case nil: return "Waiting for you"
        }
    }

    /// What the reports say a program does, all its records together.
    public enum Activity: Equatable, Sendable {
        case working
        /// Blocked: what it waits for, and its own words for it, if any.
        case asking(Kind?, String?)
        /// At rest, finished, or stopped on an error: its turn is over.
        case stopped
    }

    /// One terminal's records, by id (the root's is ""), as its program's reports leave them. At most `limit`: the one
    /// updated least recently goes first.
    public struct Records: Sendable {
        public static let limit = 256

        private var records: [String: Report] = [:]
        /// Ids, least recently updated first.
        private var order: [String] = []

        public init() {}

        public var isEmpty: Bool { records.isEmpty }

        public subscript(id: String?) -> Report? { records[id ?? ""] }

        /// A report replaces its record whole; `clear` removes its record and every one beneath it, or every record
        /// when it names none.
        public mutating func apply(_ report: Report) {
            let id = report.id ?? ""
            guard report.state != .clear else {
                if report.id == nil {
                    records = [:]
                    order = []
                } else {
                    let beneath = id + "/"
                    records = records.filter { $0.key != id && !$0.key.hasPrefix(beneath) }
                    order.removeAll { $0 == id || $0.hasPrefix(beneath) }
                }
                return
            }
            records[id] = report
            order.removeAll { $0 == id }
            order.append(id)
            if order.count > Self.limit { records[order.removeFirst()] = nil }
        }

        /// Blocked anywhere waits for the user (the root's first); else working anywhere works; else any record says
        /// it stopped. Nil with no records.
        public var activity: Activity? {
            let all = order.reversed().compactMap { records[$0] } // most recent first
            if let blocked = records[""].flatMap({ $0.state == .blocked ? $0 : nil }) ?? all.first(where: { $0.state == .blocked }) {
                return .asking(blocked.kind, blocked.message)
            }
            if all.contains(where: { $0.state == .working }) { return .working }
            return all.isEmpty ? nil : .stopped
        }
    }
}
