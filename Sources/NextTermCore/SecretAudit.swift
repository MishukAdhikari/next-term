import Foundation

/// Secrets' audit log, `audit.log` in the vault's folder: one JSON line per event, 0600, appended. At 1 MB it becomes
/// `audit.log.1`, replacing the older one (`SecretFolder.appendAudit`).
///
/// A line holds the time, the event, the keys' names, who asked (the panel's Asked by facts), the command (at most 300
/// characters), the folder, how it was approved and the outcome; a `replace` line also holds the earlier origin. It
/// has no field for a value, and its text is masked when it is written. "Last used" in Settings and in `list_secrets`
/// is the newest `use` line for a name.
public enum SecretAudit {
    /// When the log becomes `audit.log.1`.
    public static let maxSize = 1 << 20
    /// The longest command a line keeps.
    public static let maxCommand = 300

    public enum Event: String, Codable, Sendable {
        case use, add, edit, replace
        case writeOnly = "write-only"
        case delete, reveal, copy
        case `import`
        case undo, decline, pause, grant
        case grantEnd = "grant-end"
        case refused, tamper
        case startOver = "start-over"
    }

    public enum Approval: String, Codable, Sendable {
        case once
        case fifteenMinutes = "15 minutes"
        case untilLock = "until lock"
        case grant, remote
    }

    public struct Line: Codable, Equatable, Sendable {
        public var time: Date
        public var event: Event
        public var names: [String]
        /// Who asked: the agent, its tab and project, or the remote connection.
        public var who: String?
        public var command: String?
        public var folder: String?
        public var approval: Approval?
        public var outcome: String?
        /// For `replace`: the origin of the key it replaced.
        public var earlierOrigin: String?

        enum CodingKeys: String, CodingKey {
            case time, event, names, who, command, folder, approval, outcome
            case earlierOrigin = "earlier_origin"
        }

        public init(time: Date = Date(), event: Event, names: [String], who: String? = nil, command: String? = nil,
                    folder: String? = nil, approval: Approval? = nil, outcome: String? = nil, earlierOrigin: String? = nil) {
            self.time = time
            self.event = event
            self.names = names
            self.who = who
            self.command = command
            self.folder = folder
            self.approval = approval
            self.outcome = outcome
            self.earlierOrigin = earlierOrigin
        }
    }

    /// One line of the log, ending in a line break: its text masked by `mask` (stored values, `SecretMask`), then the
    /// command cut at 300 characters.
    public static func encode(_ line: Line, masking mask: (String) -> String = { $0 }) -> Data {
        var line = line
        line.who = line.who.map(mask)
        line.folder = line.folder.map(mask)
        line.outcome = line.outcome.map(mask)
        if let command = line.command.map(mask) {
            line.command = command.count > maxCommand ? String(command.prefix(maxCommand - 1)) + "…" : command
        }
        guard let data = try? encoder.encode(line) else { return Data() }
        return data + Data("\n".utf8)
    }

    /// The lines that decode; others are skipped.
    public static func lines(in data: Data) -> [Line] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
    }

    /// For each name, its newest `use` line.
    public static func lastUse(in data: Data) -> [String: Line] {
        var newest: [String: Line] = [:]
        for line in lines(in: data) where line.event == .use {
            for name in line.names where newest[name].map({ $0.time <= line.time }) ?? true {
                newest[name] = line
            }
        }
        return newest
    }

    /// Whether the log becomes `audit.log.1` before `adding` more bytes.
    public static func needsRotation(size: Int, adding: Int) -> Bool {
        size > 0 && size + adding > maxSize
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
