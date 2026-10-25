import Darwin
import Foundation

// What `nxtrm secret import` and the app say on the socket: one header line from the importer, which holds no key, then
// the app's reply lines. The piped bytes follow the header only after the app's `ready`, raw, never in a line: the
// socket's line reader keeps what it reads in a buffer it never wipes.

extension SecretImportPipe {
    /// The importer's header: `{"tool": "secret_import", "arguments": {…}}`.
    public struct Request: Codable, Equatable, Sendable {
        /// `--from`'s format, as `formatNames` spells it; nil reads it from the content.
        public var format: String?
        /// How many raw bytes follow `ready`: 1 to `maxBytes` for standard input, 0 for a file.
        public var bytes: Int
        /// The file's absolute path, which the app reads itself; nil for standard input.
        public var path: String?
        /// The importer's working folder.
        public var directory: String
        /// Its own argv, which the app compares with what the kernel says.
        public var argvFull: [String]

        enum CodingKeys: String, CodingKey {
            case format, bytes, path, directory
            case argvFull = "argv_full"
        }

        public init(format: String?, bytes: Int, path: String?, directory: String, argvFull: [String]) {
            self.format = format
            self.bytes = bytes
            self.path = path
            self.directory = directory
            self.argvFull = argvFull
        }

        /// A file or a body, never both or neither; a body within the cap; a known format; an absolute path of at most
        /// 4096 bytes with no control character (C0, DEL or C1), as the sheet's header shows it.
        public var isWellFormed: Bool {
            if let format, SecretImportPipe.format(named: format) == nil { return false }
            guard let path else { return bytes >= 1 && bytes <= maxBytes }
            let plain: Bool = !path.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
                scalar.properties.generalCategory == .control
            }
            return bytes == 0 && path.hasPrefix("/") && path.utf8.count <= 4096 && plain
        }

        /// The header line the importer sends.
        public func line() -> Data? {
            guard let arguments = try? JSONEncoder().encode(self),
                  let object = try? JSONSerialization.jsonObject(with: arguments) else { return nil }
            let request: [String: Any] = ["tool": tool, "arguments": object]
            guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            data.append(0x0A)
            return data
        }

        /// The header in a decoded line's `arguments`.
        public static func decode(_ arguments: [String: Any]) -> Request? {
            guard JSONSerialization.isValidJSONObject(arguments),
                  let data = try? JSONSerialization.data(withJSONObject: arguments) else { return nil }
            return try? JSONDecoder().decode(Request.self, from: data)
        }
    }

    /// The app's lines to the importer: `ready` for the body, then how far it got, then how it ended. Counts only.
    public struct Reply: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            /// Send the body now.
            case ready
            /// The preview is open with this many keys.
            case found
            /// The preview is open, saying why the input couldn't be read.
            case unreadable
            /// The file is an agent's MCP config: the MCP-config import opened for it.
            case moved
            /// The file is an agent's MCP config, given by an agent's run or an untraced one: nothing opened, since
            /// only the user starts a move.
            case moveRefused
            /// The preview closed: this many keys were copied in.
            case imported
            /// The preview closed with none copied in.
            case nothing
            case refused
            /// Secrets is showing another import or sheet.
            case busy
        }

        public var status: Status
        public var count: Int?

        public init(status: Status, count: Int? = nil) {
            self.status = status
            self.count = count
        }

        public func line() -> Data {
            var data: Data = (try? JSONEncoder().encode(self)) ?? Data(#"{"status":"refused"}"#.utf8)
            data.append(0x0A)
            return data
        }

        public static func decode(_ line: Data) -> Reply? {
            try? JSONDecoder().decode(Reply.self, from: line)
        }

        /// Whether it ends the import: nothing more comes after it.
        public var isLast: Bool { ![.ready, .found, .unreadable].contains(status) }
    }

    /// How reading standard input ended.
    public enum ReadEnd: Equatable, Sendable {
        case ended
        /// Over the limit: what was read is wiped, and nothing is kept.
        case tooLarge
        case failed
    }

    /// Reads `fd` to its end into `bytes`, which comes back with exactly what was read, or empty. The buffer is made
    /// once, a byte over `limit`, so no grown copy of the keys is left behind unwiped; over `limit` it is wiped.
    public static func readAll(_ fd: Int32, into bytes: inout [UInt8], limit: Int = maxBytes) -> ReadEnd {
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        var filled = 0
        while filled < buffer.count {
            let count: Int = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base + filled, raw.count - filled)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                SecretBytes.wipe(&buffer)
                bytes = []
                return .failed
            }
            if count == 0 { break }
            filled += count
        }
        guard filled <= limit else {
            SecretBytes.wipe(&buffer)
            bytes = []
            return .tooLarge
        }
        // Shrinking keeps the storage: the bytes cut off were never written.
        buffer.removeLast(buffer.count - filled)
        bytes = buffer
        return .ended
    }
}
