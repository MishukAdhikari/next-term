import Compression
import Foundation
@testable import NextTermCore

/// Zip archives made in memory for the tests, as a 1Password export (`.1pux`) is laid out: local headers with their
/// data, a central directory, and its end record. Each can be bent to test one way an archive goes wrong.
enum ZipFixture {
    struct Entry {
        var name: String
        var data: [UInt8]
        var deflate = true
        /// The size the headers claim, when it isn't the data's own.
        var claimedSize: Int?
        var flags: UInt16 = 0
        var method: UInt16?
    }

    /// Ways to bend the archive's end record.
    struct Bend {
        /// Added to the central directory's offset.
        var directoryShift = 0
        /// Writes 0xFFFF as the entry count, as an archive in zip64 form does.
        var zip64 = false
    }

    /// An archive of `entries`, in order.
    static func archive(_ entries: [Entry], bend: Bend = Bend()) -> [UInt8] {
        var out: [UInt8] = []
        var directory: [UInt8] = []
        for entry in entries {
            let offset = out.count
            let stored: [UInt8] = entry.deflate ? deflated(entry.data) : entry.data
            let method: UInt16 = entry.method ?? (entry.deflate ? 8 : 0)
            let size = UInt32(entry.claimedSize ?? entry.data.count)
            let crc: UInt32 = ZipReader.crc32(entry.data)
            let name = Array(entry.name.utf8)
            out += le32(0x0403_4B50) + le16(20) + le16(entry.flags) + le16(method) + le16(0) + le16(0)
            out += le32(crc) + le32(UInt32(stored.count)) + le32(size) + le16(UInt16(name.count)) + le16(0)
            out += name + stored
            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(entry.flags) + le16(method) + le16(0) + le16(0)
            directory += le32(crc) + le32(UInt32(stored.count)) + le32(size) + le16(UInt16(name.count))
            directory += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(offset)) + name
        }
        let start = out.count + bend.directoryShift
        let count: UInt16 = bend.zip64 ? 0xFFFF : UInt16(entries.count)
        out += directory
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count)
        out += le32(UInt32(directory.count)) + le32(UInt32(start)) + le16(0)
        return out
    }

    /// One entry named `export.data` holding `text`, deflated: a 1Password export as it is written.
    static func onePUX(_ text: String) -> [UInt8] {
        let attributes = Entry(name: "export.attributes", data: Array(#"{"version":3}"#.utf8))
        return archive([attributes, Entry(name: "export.data", data: Array(text.utf8))])
    }

    /// Raw deflate, as a zip holds it (Compression's ZLIB is RFC 1951 with no header).
    static func deflated(_ data: [UInt8]) -> [UInt8] {
        let capacity = data.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written: Int = out.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
            data.withUnsafeBufferPointer { (src: UnsafeBufferPointer<UInt8>) -> Int in
                guard let target = dst.baseAddress, let source = src.baseAddress else { return 0 }
                return compression_encode_buffer(target, capacity, source, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Array(out.prefix(written))
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
