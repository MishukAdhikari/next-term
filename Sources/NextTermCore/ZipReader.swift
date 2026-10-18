import Compression
import Foundation

/// A reader for one entry of a zip archive, for 1Password's `.1pux` export: it reads the central directory in memory,
/// finds the entry by name, and gives its bytes back, stored or deflated. Nothing is written to disk, and nothing past
/// what the archive's own records say is trusted: an entry larger than `maxEntryBytes`, or claiming more than
/// `maxRatio` times its stored size, is refused before it is inflated, and one that inflates past its claim stops.
/// Zip64, encrypted entries and other compression methods are refused with their reason. The caller wipes the bytes it
/// gets.
public enum ZipReader {
    public static let maxEntryBytes = 50 * 1024 * 1024
    public static let maxRatio = 100

    public enum Failure: Error, Equatable, Sendable {
        case notAZip
        /// A record points past the archive, or the data doesn't match what the records say.
        case damaged
        case zip64
        case encrypted
        /// A compression method other than stored or deflated.
        case method
        case missing
        case tooLarge
        case inflatesTooFar

        public var sentence: String {
            switch self {
            case .notAZip: return "It isn\u{2019}t a zip archive Next Term can read."
            case .damaged: return "The archive is damaged."
            case .zip64: return "The archive is in zip64 form, which Next Term doesn\u{2019}t read."
            case .encrypted: return "The archive is encrypted."
            case .method: return "The archive is compressed in a way Next Term doesn\u{2019}t read."
            case .missing: return "The archive doesn\u{2019}t hold the file Next Term looks for."
            case .tooLarge: return "The archive\u{2019}s data is larger than the 50 MB Next Term reads."
            case .inflatesTooFar: return "The archive\u{2019}s data grows far past its size, so Next Term stopped."
            }
        }
    }

    /// Whether the bytes start as a zip archive does.
    public static func isZip(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
    }

    /// The bytes of the entry named `name`, or why not.
    public static func entry(_ name: String, in bytes: [UInt8]) -> Result<[UInt8], Failure> {
        let archive = ZipArchive(bytes: bytes)
        switch archive.directory() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let directory):
            guard let record = archive.find(Array(name.utf8), in: directory) else { return .failure(.missing) }
            return archive.read(record)
        }
    }
}

// MARK: - Records

/// An entry as the central directory describes it.
struct ZipRecord {
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let storedSize: UInt32
    let size: UInt32
    let offset: UInt32
}

/// An archive's bytes, read with every offset checked against its end.
struct ZipArchive {
    let bytes: [UInt8]

    static let endSignature: UInt32 = 0x0605_4B50
    static let zip64Locator: UInt32 = 0x0706_4B50
    static let directorySignature: UInt32 = 0x0201_4B50
    static let localSignature: UInt32 = 0x0403_4B50

    func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= bytes.count else { return nil }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32? {
        guard let low = u16(at), let high = u16(at + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    /// Where the end record starts: the last signature with room for its 22 bytes, within a comment's reach of the end.
    func endRecord() -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest: Int = max(0, bytes.count - 22 - 0xFFFF)
        var at: Int = bytes.count - 22
        while at >= lowest {
            if bytes[at] == 0x50, bytes[at + 1] == 0x4B, u32(at) == Self.endSignature { return at }
            at -= 1
        }
        return nil
    }

    /// The central directory's range and entry count, from the end record.
    func directory() -> Result<(range: Range<Int>, count: Int), ZipReader.Failure> {
        guard let end = endRecord(), let disk = u16(end + 4), let first = u16(end + 6), let count = u16(end + 10),
              let size = u32(end + 12), let offset = u32(end + 16) else { return .failure(.notAZip) }
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { return .failure(.zip64) }
        if end >= 20, u32(end - 20) == Self.zip64Locator { return .failure(.zip64) }
        guard disk == 0, first == 0 else { return .failure(.damaged) }
        let start = Int(offset)
        let stop: Int = start + Int(size)
        guard stop <= end else { return .failure(.damaged) }
        return .success((start..<stop, Int(count)))
    }
}

// MARK: - Finding and reading an entry

extension ZipArchive {
    /// The central directory's record for `name`, or nil. A record that runs past the directory ends the walk.
    func find(_ name: [UInt8], in directory: (range: Range<Int>, count: Int)) -> ZipRecord? {
        var at: Int = directory.range.lowerBound
        for _ in 0..<directory.count {
            guard at + 46 <= directory.range.upperBound, u32(at) == Self.directorySignature,
                  let flags = u16(at + 8), let method = u16(at + 10), let crc = u32(at + 16),
                  let storedSize = u32(at + 20), let size = u32(at + 24), let nameLength = u16(at + 28),
                  let extraLength = u16(at + 30), let commentLength = u16(at + 32), let offset = u32(at + 42)
            else { return nil }
            let nameStart: Int = at + 46
            let next: Int = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard next <= directory.range.upperBound else { return nil }
            if bytes[nameStart..<(nameStart + Int(nameLength))].elementsEqual(name) {
                return ZipRecord(flags: flags, method: method, crc: crc, storedSize: storedSize, size: size,
                                 offset: offset)
            }
            at = next
        }
        return nil
    }

    /// The entry's bytes, checked: its form, its sizes, its place, and its CRC once read.
    func read(_ record: ZipRecord) -> Result<[UInt8], ZipReader.Failure> {
        if record.flags & 1 != 0 { return .failure(.encrypted) }
        let sizes: [UInt32] = [record.storedSize, record.size, record.offset]
        if sizes.contains(0xFFFF_FFFF) { return .failure(.zip64) }
        guard record.method == 0 || record.method == 8 else { return .failure(.method) }
        let size = Int(record.size)
        let stored = Int(record.storedSize)
        guard size <= ZipReader.maxEntryBytes else { return .failure(.tooLarge) }
        guard size <= ZipReader.maxRatio * max(stored, 1) else { return .failure(.inflatesTooFar) }
        let at = Int(record.offset)
        guard u32(at) == Self.localSignature, let nameLength = u16(at + 26), let extraLength = u16(at + 28) else {
            return .failure(.damaged)
        }
        let start: Int = at + 30 + Int(nameLength) + Int(extraLength)
        guard start + stored <= bytes.count else { return .failure(.damaged) }
        var out: [UInt8]
        if record.method == 0 {
            guard stored == size else { return .failure(.damaged) }
            out = Array(bytes[start..<(start + stored)])
        } else {
            switch Self.inflate(bytes[start..<(start + stored)], size: size) {
            case .failure(let failure): return .failure(failure)
            case .success(let inflated): out = inflated
            }
        }
        guard ZipReader.crc32(out) == record.crc else {
            SecretBytes.wipe(&out)
            return .failure(.damaged)
        }
        return .success(out)
    }

    /// Raw deflate into room for one byte past `size`: filling that byte means the data grows past its claim.
    static func inflate(_ stored: ArraySlice<UInt8>, size: Int) -> Result<[UInt8], ZipReader.Failure> {
        var out = [UInt8](repeating: 0, count: size + 1)
        var source: [UInt8] = Array(stored)
        defer { SecretBytes.wipe(&source) }
        let written: Int = out.withUnsafeMutableBufferPointer {
            (target: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
            source.withUnsafeBufferPointer { (input: UnsafeBufferPointer<UInt8>) -> Int in
                guard let base = target.baseAddress, let from = input.baseAddress else { return 0 }
                return compression_decode_buffer(base, size + 1, from, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        if written > size {
            SecretBytes.wipe(&out)
            return .failure(.inflatesTooFar)
        }
        guard written == size else {
            SecretBytes.wipe(&out)
            return .failure(.damaged)
        }
        out.removeLast()
        return .success(out)
    }
}

// MARK: - CRC-32

extension ZipReader {
    /// The table for CRC-32 (the reflected polynomial 0xEDB88320, as zip uses).
    static let crcTable: [UInt32] = (0..<256).map { (index: Int) -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
