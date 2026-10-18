import Foundation
import Testing
@testable import NextTermCore

/// The import's zip reader, for 1Password's `.1pux`: it finds one entry by the central directory, reads it stored or
/// deflated, in memory, and stops at anything it can't trust. Every archive here is made in the test.
@Suite struct ZipReaderTests {
    typealias Z = ZipFixture

    private static let text: [UInt8] = Array(String(repeating: "made-up export data; ", count: 200).utf8)

    private static func failure(_ archive: [UInt8], _ name: String = "export.data") -> ZipReader.Failure? {
        guard case .failure(let failure) = ZipReader.entry(name, in: archive) else { return nil }
        return failure
    }

    @Test func aStoredEntryReadsBackExactly() throws {
        let archive = Z.archive([Z.Entry(name: "export.data", data: Self.text, deflate: false)])
        #expect(ZipReader.isZip(archive))
        #expect(try ZipReader.entry("export.data", in: archive).get() == Self.text)
    }

    @Test func aDeflatedEntryReadsBackExactly() throws {
        let other = Z.Entry(name: "files/attachment.bin", data: Array("not read".utf8))
        let archive = Z.archive([other, Z.Entry(name: "export.data", data: Self.text)])
        #expect(Z.deflated(Self.text).count < Self.text.count)
        #expect(try ZipReader.entry("export.data", in: archive).get() == Self.text)
    }

    @Test func aMissingEntryIsNamed() {
        let archive = Z.archive([Z.Entry(name: "export.attributes", data: Array("{}".utf8))])
        #expect(Self.failure(archive) == .missing)
    }

    @Test func textIsNotAZip() {
        #expect(!ZipReader.isZip(Array("{\"accounts\": []}".utf8)))
        #expect(Self.failure(Array("PK but not a zip".utf8)) == .notAZip)
        #expect(Self.failure([]) == .notAZip)
    }

    @Test func anEntryThatInflatesPastItsClaimStops() {
        let zeros = [UInt8](repeating: 0, count: 1024 * 1024)
        let lying = Z.Entry(name: "export.data", data: zeros, claimedSize: 1024)
        #expect(Self.failure(Z.archive([lying])) == .inflatesTooFar)
        // A claim past 100 times the stored size stops before inflating.
        let honest = Z.Entry(name: "export.data", data: zeros)
        #expect(Self.failure(Z.archive([honest])) == .inflatesTooFar)
    }

    @Test func anEntryPastFiftyMegabytesIsRefusedBeforeInflating() {
        let claim = ZipReader.maxEntryBytes + 1
        let large = Z.Entry(name: "export.data", data: Self.text, claimedSize: claim)
        #expect(Self.failure(Z.archive([large])) == .tooLarge)
        let stored = Z.Entry(name: "export.data", data: Self.text, deflate: false, claimedSize: claim)
        #expect(Self.failure(Z.archive([stored])) == .tooLarge)
    }

    @Test func aDirectoryPastTheEndStops() {
        let entry = Z.Entry(name: "export.data", data: Self.text)
        #expect(Self.failure(Z.archive([entry], bend: Z.Bend(directoryShift: 4096))) == .damaged)
        let truncated = Array(Z.archive([entry]).dropFirst(40))
        #expect(Self.failure(truncated) != nil)
    }

    @Test func zip64AndEncryptedEntriesAreRefused() {
        let entry = Z.Entry(name: "export.data", data: Self.text)
        #expect(Self.failure(Z.archive([entry], bend: Z.Bend(zip64: true))) == .zip64)
        let locked = Z.Entry(name: "export.data", data: Self.text, flags: 1)
        #expect(Self.failure(Z.archive([locked])) == .encrypted)
        let other = Z.Entry(name: "export.data", data: Self.text, deflate: false, method: 12)
        #expect(Self.failure(Z.archive([other])) == .method)
    }

    @Test func aChangedByteFailsTheCheck() {
        var archive = Z.archive([Z.Entry(name: "export.data", data: Self.text, deflate: false)])
        let at = 30 + "export.data".utf8.count + 5
        archive[at] ^= 0x01
        #expect(Self.failure(archive) == .damaged)
    }

    @Test func eachFailureHasASentence() {
        let all: [ZipReader.Failure] = [.notAZip, .damaged, .zip64, .encrypted, .method, .missing, .tooLarge,
                                        .inflatesTooFar]
        for failure in all { #expect(!failure.sentence.isEmpty) }
        #expect(ZipReader.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
