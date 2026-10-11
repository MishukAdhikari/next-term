import CryptoKit
import Foundation

/// The key routing variables are digested with (KTD5): an HMAC-SHA256 key of 32 random bytes, made once for this copy
/// of the app and kept in its sessions folder as `routing-key`, a 0600 file (SessionFiles), so a digest reads the same
/// after a relaunch. It lives in memory and in that file only: it is never logged, never in an MCP answer, and what
/// describes it shows none of it.
public struct RoutingKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Its file in the sessions folder.
    public static let fileName = "routing-key"
    static let size = 32

    private let bytes: Data

    private init?(bytes: Data) {
        guard bytes.count == Self.size else { return nil }
        self.bytes = bytes
    }

    /// A key made now and kept nowhere.
    public static func random() -> RoutingKey {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Data in Data(buffer) }
        guard let key = RoutingKey(bytes: bytes) else { preconditionFailure("a 256-bit key is 32 bytes") }
        return key
    }

    /// The key kept in `files`, made there on first use. A file that is not one (cut short, a link, open to others) is
    /// replaced by a new key. Nil when the folder can be neither read nor written: this process does not hold its lock.
    public static func load(from files: SessionFiles) -> RoutingKey? {
        let found = Result { try files.read(fileName, maxSize: size) }
        if case .success(let data?) = found, let key = RoutingKey(bytes: data) { return key }
        let key = random()
        let made: Bool
        if case .success(.none) = found {
            made = (try? files.create(fileName, with: key.bytes)) != nil
        } else {
            made = (try? files.replace(fileName, with: key.bytes)) != nil
        }
        return made ? key : nil
    }

    /// `value`'s digest under this key, in base64.
    public func digest(_ value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: bytes))
        return Data(code).base64EncodedString()
    }

    public var description: String { "RoutingKey" }
    public var debugDescription: String { "RoutingKey" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The key a process digests with: the sessions folder's once the app names it (`keep(in:)`), read or made there at
    /// the first digest. It is the same from then until the process ends, as the login shell's digests, made once, are
    /// compared with agents' read later. Used first without a folder (another Next Term holds it, a translocated copy,
    /// the tests), it is a key made for this process only, and a folder named after that gets no file.
    public final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var files: SessionFiles?
        private var chosen: RoutingKey?

        public init() {}

        /// Names the sessions folder this process holds as where the key is kept. Nothing is read or made yet.
        public func keep(in files: SessionFiles) {
            lock.lock()
            defer { lock.unlock() }
            if chosen == nil { self.files = files }
        }

        /// The key, read or made at the first call.
        public var key: RoutingKey {
            lock.lock()
            defer { lock.unlock() }
            if let chosen { return chosen }
            let key = files.flatMap(RoutingKey.load(from:)) ?? .random()
            chosen = key
            files = nil
            return key
        }
    }
}
