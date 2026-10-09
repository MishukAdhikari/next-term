import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

/// Whether the process at the other end of a socket is this program (KTD13): Next Term's app checks the
/// `nxtrm secret run` wrapper with it, and the wrapper checks the app the same way, before anything is sent.
///
/// - **The requirement.** At launch it reads the code hash of each slice of its own executable
///   (`SecStaticCodeCreateWithPathAndAttributes` with the slice's architecture, then `kSecCodeInfoUnique`) and builds
///   one requirement: `cdhash H"<arm64>" or cdhash H"<x86_64>"`. A wrapper under Rosetta runs the x86_64 slice and
///   still passes.
/// - **The check.** The peer's audit token (`LOCAL_PEERTOKEN`) gives its running code
///   (`SecCodeCopyGuestWithAttributes`), which must meet the requirement (`SecCodeCheckValidity`): the process as it
///   runs, not a file on disk. Its effective user must be this one.
/// - **What it rests on.** The hardened runtime with no exceptions, as the released app is signed: no library
///   injection and no debugger attach could make another program pass as this one.
/// - **The fallback** (`usesPathFallback`, set only if hand check H-l finds the code hash can't be read on the ad-hoc
///   build): the token's pid runs this program's resolved path, the file there has one of this program's slice
///   hashes, and the pid version is unchanged when the answer goes out.
public struct PeerCode: Sendable {
    /// H-l's switch: check by path and hash instead of the running code's hash.
    nonisolated(unsafe) public static var usesPathFallback = false

    /// This program's: its executable's slices.
    public static let current = PeerCode(path: Bundle.main.executablePath ?? CommandLine.arguments[0])

    /// The executable, links resolved.
    public let path: String
    /// One code hash (cdhash) per slice.
    public let hashes: [Data]
    /// `cdhash H"…" or cdhash H"…"`, or nil when no hash could be read.
    public let requirementText: String?

    public init(path: String) {
        let resolved = (path as NSString).resolvingSymlinksInPath
        self.path = resolved
        hashes = Self.sliceHashes(of: resolved)
        requirementText = Self.requirement(for: hashes)
    }

    /// Whether the process behind `token` is this program, run by this user.
    public func isThisProgram(auditToken token: audit_token_t) -> Bool {
        guard Self.effectiveUser(token) == getuid(), Self.pid(token) > 0 else { return false }
        if Self.usesPathFallback { return isThisProgramByPath(token) }
        guard let requirementText else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: Self.data(token)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The fallback: the pid's executable is this program's path, and the file there has one of its hashes.
    func isThisProgramByPath(_ token: audit_token_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Self.pid(token), &buffer, UInt32(buffer.count)) > 0 else { return false }
        let running = (String(cString: buffer) as NSString).resolvingSymlinksInPath
        guard running == path else { return false }
        let onDisk = Self.sliceHashes(of: running)
        return !onDisk.isEmpty && onDisk.allSatisfy(hashes.contains)
    }

    /// Whether the socket's peer is still the process `token` was read from: the same pid and pid version (an exec or
    /// a reused pid changes the version). For the fallback, just before the answer goes out.
    public static func isSameProcess(socket: Int32, as token: audit_token_t) -> Bool {
        guard let now = auditToken(of: socket) else { return false }
        return pid(now) == pid(token) && pidVersion(now) == pidVersion(token)
    }

    // MARK: the hashes

    /// The code hash of each slice of the executable at `path`: one for a thin file, one per architecture for a
    /// universal one. Empty when it is not signed or can't be read.
    public static func sliceHashes(of path: String) -> [Data] {
        let url = URL(fileURLWithPath: path)
        let slices = architectures(of: path)
        guard !slices.isEmpty else { return hash(url, attributes: [:]).map { [$0] } ?? [] }
        var hashes: [Data] = []
        for slice in slices {
            let attributes: [CFString: Any] = [kSecCodeAttributeArchitecture: NSNumber(value: slice.type),
                                               kSecCodeAttributeSubarchitecture: NSNumber(value: slice.subtype)]
            if let hash = hash(url, attributes: attributes), !hashes.contains(hash) { hashes.append(hash) }
        }
        return hashes
    }

    private static func hash(_ url: URL, attributes: [CFString: Any]) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes as CFDictionary, &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
              let fields = info as? [String: Any] else { return nil }
        return fields[kSecCodeInfoUnique as String] as? Data
    }

    /// `cdhash H"<hex>" or cdhash H"<hex>"`.
    public static func requirement(for hashes: [Data]) -> String? {
        guard !hashes.isEmpty else { return nil }
        return hashes.map { "cdhash H\"" + $0.map { String(format: "%02x", $0) }.joined() + "\"" }.joined(separator: " or ")
    }

    /// The CPU type and subtype of each slice in a Mach-O file, from its headers: one for a thin file, each one's for a
    /// universal file.
    static func architectures(of path: String) -> [(type: Int32, subtype: Int32)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard head.count >= 8 else { return [] }
        func big(_ offset: Int) -> UInt32 {
            head[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ offset: Int) -> UInt32 {
            head[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        switch big(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal, its header big-endian
            let count = Int(big(4))
            let stride = big(0) == 0xCAFE_BABF ? 32 : 20
            guard count > 0, count < 16, 8 + count * stride <= head.count else { return [] }
            return (0..<count).map { index in
                let base = 8 + index * stride
                return (Int32(bitPattern: big(base)), Int32(bitPattern: big(base + 4) & 0x00FF_FFFF))
            }
        default:
            switch little(0) {
            case 0xFEED_FACF, 0xFEED_FACE:
                return [(Int32(bitPattern: little(4)), Int32(bitPattern: little(8) & 0x00FF_FFFF))]
            default:
                return []
            }
        }
    }

    // MARK: audit tokens

    /// The audit token of the process at the other end of a connected Unix socket (`LOCAL_PEERTOKEN`).
    public static func auditToken(of socket: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, size == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        return token
    }

    /// The token's process id (its sixth word).
    public static func pid(_ token: audit_token_t) -> pid_t {
        pid_t(bitPattern: token.val.5)
    }

    /// The token's effective user (its second word).
    public static func effectiveUser(_ token: audit_token_t) -> uid_t {
        token.val.1
    }

    /// The token's pid version (its eighth word): a reused pid has another.
    public static func pidVersion(_ token: audit_token_t) -> UInt32 {
        token.val.7
    }

    static func data(_ token: audit_token_t) -> Data {
        withUnsafeBytes(of: token) { Data($0) }
    }
}
